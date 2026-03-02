#!/usr/bin/env node
/**
 * add_resource.cjs — Register a Pangolin tunnel resource via direct DB access
 *
 * Run INSIDE the pangolin container (from /app so modules resolve):
 *   node /app/add_resource.cjs \
 *     --site-id <N> \
 *     --name <app-name> \
 *     --subdomain <subdomain.domain.com> \
 *     --http-port <internal_proxy_port> \
 *     --target-port <service_port> \
 *     --target-host <server_lan_ip> \
 *     [--method http|https]   (default: http — use https only when target serves TLS)
 *     [--sso 1]               (enable Pangolin SSO auth for this resource)
 *
 * Outputs: the new resourceId (integer autoincrement) on stdout
 *
 * Schema notes (Pangolin EE):
 *   - resources table no longer has siteId/targetPort/targetHost/method
 *   - those fields moved to the new `targets` table (resourceId + siteId + ip + port + method)
 *   - resources.resourceId is now INTEGER AUTOINCREMENT (not text)
 *   - resources.resourceGuid is a new required UUID field
 *   - resources.enableProxy replaces proxyEnabled
 *   - resources.niceId is a required slug field
 *   - After insert, admin role is linked via roleResources/resourceRoles (if table exists)
 */

"use strict";

const Database = require("better-sqlite3");
const crypto = require("crypto");
const fs = require("fs");

// ─── Argument parsing ──────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const opts = {};
for (let i = 0; i < args.length; i += 2) {
  opts[args[i].replace(/^--/, "").replace(/-([a-z])/g, (_, c) => c.toUpperCase())] =
    args[i + 1];
}

const required = ["siteId", "name", "subdomain", "httpPort", "targetPort", "targetHost"];
for (const key of required) {
  if (!opts[key]) {
    process.stderr.write(`Missing required argument: --${key.replace(/([A-Z])/g, "-$1").toLowerCase()}\n`);
    process.exit(1);
  }
}

// --method defaults to 'http' — most home services are plain HTTP.
// Use 'https' only when the target backend itself serves TLS (e.g., Traefik port 443).
const targetMethod = (opts.method || "http").toLowerCase();
const ssoEnabled   = opts.sso === "1" || opts.sso === "true";

// ─── Database path ─────────────────────────────────────────────────────────────
const DB_PATH = process.env.PANGOLIN_DB_PATH || "/app/config/db/db.sqlite";

if (!fs.existsSync(DB_PATH)) {
  process.stderr.write(`Database not found at: ${DB_PATH}\n`);
  process.exit(1);
}

// ─── Insert resource + target ─────────────────────────────────────────────────
const db = new Database(DB_PATH);

try {
  const siteId    = parseInt(opts.siteId, 10);
  const httpPort  = parseInt(opts.httpPort, 10);
  const targetPort = parseInt(opts.targetPort, 10);
  const targetHost = opts.targetHost;
  const name      = opts.name;
  const fullDomain = opts.subdomain;  // passed as full FQDN (e.g., app.example.com)

  // Derive subdomain part (everything before the first dot)
  const subdomainPart = fullDomain.split(".")[0];

  // Slug for niceId
  const niceId = name.toLowerCase().replace(/[^a-z0-9]/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "");

  // UUID for resourceGuid (36-char format)
  const resourceGuid = crypto.randomUUID ? crypto.randomUUID()
    : `${crypto.randomBytes(4).toString("hex")}-${crypto.randomBytes(2).toString("hex")}-4${crypto.randomBytes(2).toString("hex").slice(1)}-${(parseInt(crypto.randomBytes(1).toString("hex"), 16) & 0x3f | 0x80).toString(16)}${crypto.randomBytes(1).toString("hex")}-${crypto.randomBytes(6).toString("hex")}`;

  // Get orgId from site
  const siteRow = db.prepare("SELECT orgId FROM sites WHERE siteId = ?").get(siteId);
  if (!siteRow) {
    process.stderr.write(`Site not found: siteId=${siteId}\n`);
    process.exit(1);
  }
  const orgId = siteRow.orgId;

  // Discover available tables and columns for EE compatibility
  const allTables = db.prepare(
    "SELECT name FROM sqlite_master WHERE type='table'"
  ).all().map(r => r.name);

  const resCols = db.prepare("PRAGMA table_info('resources')").all().map(r => r.name);

  // Find domainId by matching baseDomain against the fullDomain suffix
  // e.g. fullDomain='plex.example.com' → look for baseDomain='example.com'
  let domainId = null;
  if (allTables.includes("domains")) {
    const allDomains = db.prepare("SELECT domainId, baseDomain FROM domains").all();
    // Sort by length desc so more-specific domains match first
    allDomains.sort((a, b) => b.baseDomain.length - a.baseDomain.length);
    for (const d of allDomains) {
      if (fullDomain === d.baseDomain || fullDomain.endsWith("." + d.baseDomain)) {
        domainId = d.domainId;
        break;
      }
    }
  }

  const result = db.transaction(() => {
    // Insert resource (EE schema: no siteId/targetPort/targetHost/method in resources)
    // NOTE: 'sso' column defaults to 1 in Pangolin EE, so we must always set it explicitly.
    const ssoVal = ssoEnabled ? 1 : 0;
    const resResult = db.prepare(`
      INSERT INTO resources (
        resourceGuid,
        orgId,
        niceId,
        name,
        subdomain,
        fullDomain,
        domainId,
        ssl,
        http,
        protocol,
        proxyPort,
        tlsServerName,
        enabled,
        enableProxy,
        sso
      ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, 1, 'tcp', ?, ?, 1, 1, ?)
    `).run(resourceGuid, orgId, niceId, name, subdomainPart, fullDomain, domainId, httpPort, fullDomain, ssoVal);

    const resourceId = resResult.lastInsertRowid;

    // Insert target linking resource to site with backend details.
    // method defaults to 'http' — most home services are plain HTTP.
    // Using 'https' against an HTTP-only backend causes TLS handshake failures (404/502).
    db.prepare(`
      INSERT INTO targets (
        resourceId,
        siteId,
        ip,
        method,
        port,
        internalPort,
        enabled,
        priority
      ) VALUES (?, ?, ?, ?, ?, ?, 1, 100)
    `).run(resourceId, siteId, targetHost, targetMethod, targetPort, httpPort);

    // ── Admin role + user access grants ────────────────────────────────────
    // Pangolin EE requires explicit entries in BOTH roleResources AND userResources
    // for resources to appear in the dashboard and be accessible via SSO.

    // roleResources: admin role → resource
    const rrTable = allTables.find(t => t === "roleResources") ||
                    allTables.find(t => t === "resourceRoles") || null;
    if (rrTable) {
      const rrCols = db.prepare(`PRAGMA table_info('${rrTable}')`).all().map(r => r.name);
      if (rrCols.includes("roleId") && rrCols.includes("resourceId")) {
        const adminRole = db.prepare(
          "SELECT roleId FROM roles WHERE orgId = ? AND isAdmin = 1 ORDER BY roleId ASC LIMIT 1"
        ).get(orgId);
        if (adminRole) {
          try {
            db.prepare(
              `INSERT OR IGNORE INTO ${rrTable} (resourceId, roleId) VALUES (?, ?)`
            ).run(resourceId, adminRole.roleId);
          } catch (_) { /* non-fatal */ }
        }
      }
    }

    // userResources: each org user → resource (required for dashboard visibility)
    if (allTables.includes("userResources")) {
      const userTable = allTables.includes("user") ? "user" : "users";
      const userPkCol = db.prepare(`PRAGMA table_info('${userTable}')`).all()
        .map(r => r.name).includes("id") ? "id" : "userId";
      const orgUsers = db.prepare(
        `SELECT u.${userPkCol} AS uid FROM ${userTable} u
         JOIN userOrgs uo ON uo.userId = u.${userPkCol}
         WHERE uo.orgId = ?`
      ).all(orgId);
      for (const { uid } of orgUsers) {
        try {
          db.prepare("INSERT OR IGNORE INTO userResources (userId, resourceId) VALUES (?, ?)")
            .run(uid, resourceId);
        } catch (_) { /* non-fatal */ }
      }
    }

    return resourceId;
  })();

  // Output the resourceId for the caller to store
  process.stdout.write(`${result}\n`);
  process.exit(0);
} catch (err) {
  process.stderr.write(`DB error: ${err.message}\n`);
  process.exit(1);
} finally {
  db.close();
}
