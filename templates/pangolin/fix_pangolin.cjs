#!/usr/bin/env node
/**
 * fix_pangolin.cjs — Comprehensive Pangolin DB repair
 *
 * Run inside the pangolin container:
 *   node /app/fix_pangolin.cjs [--dry-run]
 *
 * Fixes applied (in order):
 *   1. isShareableSite = 0  — CRITICAL: prevents UI redirect loop between
 *                             /resources/proxy and /resources (Sites tab).
 *                             isShareableSite is NOT an SSO/auth flag — it
 *                             switches a resource to "public shareable site"
 *                             mode, which conflicts with enableProxy=1.
 *   2. enableProxy = 1      — ensure proxy tunnel is active on all resources
 *   3. enabled = 1          — enable all resources and targets
 *   4. targets.method = http — fix TLS handshake failures (plain-HTTP services)
 *   5. domains table        — create missing domain records and link resources
 *   6. roleResources        — ensure admin role can see all resources in dashboard
 */
"use strict";

const Database = require("better-sqlite3");
const fs = require("fs");

const DB_PATH = process.env.PANGOLIN_DB_PATH || "/app/config/db/db.sqlite";
if (!fs.existsSync(DB_PATH)) {
  process.stderr.write(`DB not found: ${DB_PATH}\n`);
  process.exit(1);
}

const dryRun = process.argv.includes("--dry-run");
if (dryRun) process.stdout.write("DRY RUN — no changes will be made\n\n");

const db = new Database(DB_PATH);
const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(r => r.name);
const resCols = db.prepare("PRAGMA table_info('resources')").all().map(r => r.name);

let fixed = 0;

function run(desc, sql, ...params) {
  if (dryRun) {
    process.stdout.write(`[DRY RUN] Would: ${desc}\n`);
    return 0;
  }
  const result = db.prepare(sql).run(...params);
  if (result.changes > 0) {
    process.stdout.write(`FIXED (${result.changes} rows): ${desc}\n`);
    fixed += result.changes;
  } else {
    process.stdout.write(`OK (no change needed): ${desc}\n`);
  }
  return result.changes;
}

// ── Fix 1: isShareableSite → 0 (CRITICAL — stops the UI redirect loop) ───────
// isShareableSite=1 switches a resource into "public shareable site" mode.
// When a resource also has enableProxy=1 the UI flips between /resources/proxy
// and /resources infinitely and may throw a client-side JS exception.
// All resources created by portless are proxy resources — set this to 0.
if (resCols.includes("isShareableSite")) {
  const bad = db.prepare("SELECT COUNT(*) AS n FROM resources WHERE isShareableSite = 1").get().n;
  if (bad > 0) {
    process.stdout.write(`Found ${bad} resource(s) with isShareableSite=1 — this causes the UI redirect loop\n`);
    run("Set isShareableSite = 0 on all resources (proxy mode only)",
        "UPDATE resources SET isShareableSite = 0 WHERE isShareableSite = 1");
  } else {
    process.stdout.write("isShareableSite: OK (already 0 on all resources)\n");
  }
}

// ── Fix 2: enableProxy → 1 ───────────────────────────────────────────────────
if (resCols.includes("enableProxy")) {
  run("Enable proxy on all resources",
      "UPDATE resources SET enableProxy = 1 WHERE enableProxy = 0 OR enableProxy IS NULL");
}

// ── Fix 3: enabled → 1 (resources + targets) ─────────────────────────────────
run("Enable all disabled resources",
    "UPDATE resources SET enabled = 1 WHERE enabled = 0 OR enabled IS NULL");

if (tables.includes("targets")) {
  run("Enable all disabled targets",
      "UPDATE targets SET enabled = 1 WHERE enabled = 0 OR enabled IS NULL");
}

// ── Fix 4: targets.method → http ─────────────────────────────────────────────
if (tables.includes("targets")) {
  const n = db.prepare("SELECT COUNT(*) AS n FROM targets WHERE method = 'https'").get().n;
  if (n > 0) {
    process.stdout.write(`Found ${n} target(s) with method=https — causes TLS handshake failure\n`);
    run("Set targets.method = 'http'",
        "UPDATE targets SET method = 'http' WHERE method = 'https'");
  } else {
    process.stdout.write("targets.method: OK (no https targets)\n");
  }
}

// ── Fix 5: domains table ──────────────────────────────────────────────────────
if (tables.includes("domains")) {
  const domainCols = db.prepare("PRAGMA table_info('domains')").all().map(r => r.name);
  const existing = db.prepare("SELECT COUNT(*) AS n FROM domains").get().n;

  if (existing === 0) {
    const resources = db.prepare(
      "SELECT DISTINCT orgId, fullDomain FROM resources WHERE fullDomain IS NOT NULL"
    ).all();

    const baseDomains = new Map();
    for (const r of resources) {
      const parts = r.fullDomain.split(".");
      const base = parts.length >= 2 ? parts.slice(-2).join(".") : r.fullDomain;
      if (!baseDomains.has(base)) baseDomains.set(base, r.orgId);
    }

    for (const [baseDomain, orgId] of baseDomains) {
      process.stdout.write(`Domains table empty — creating record for ${baseDomain}\n`);
      if (!dryRun) {
        try {
          if (domainCols.includes("domainId") && domainCols.includes("baseDomain")) {
            db.prepare("INSERT OR IGNORE INTO domains (domainId, baseDomain, orgId) VALUES (?, ?, ?)")
              .run(baseDomain, baseDomain, orgId);
          } else if (domainCols.includes("domain")) {
            db.prepare("INSERT OR IGNORE INTO domains (domain, orgId) VALUES (?, ?)")
              .run(baseDomain, orgId);
          } else {
            process.stdout.write(`  WARNING: Unknown domains schema: ${domainCols.join(", ")} — skipping\n`);
            continue;
          }

          if (resCols.includes("domainId")) {
            const idRow = db.prepare(
              "SELECT domainId FROM domains WHERE domainId = ? OR baseDomain = ? OR domain = ?"
            ).get(baseDomain, baseDomain, baseDomain);
            if (idRow) {
              const upd = db.prepare(
                "UPDATE resources SET domainId = ? WHERE fullDomain LIKE ? AND domainId IS NULL"
              ).run(idRow.domainId, `%.${baseDomain}`);
              if (upd.changes > 0) {
                process.stdout.write(`  Linked ${upd.changes} resource(s) to domain ${baseDomain}\n`);
                fixed += upd.changes;
              }
            }
          }
          fixed++;
        } catch (e) {
          process.stdout.write(`  WARNING: Could not insert domain: ${e.message}\n`);
        }
      }
    }
  } else {
    process.stdout.write(`domains table: ${existing} record(s) present\n`);
    // Link any unlinked resources
    if (resCols.includes("domainId")) {
      const unlinked = db.prepare("SELECT COUNT(*) AS n FROM resources WHERE domainId IS NULL").get().n;
      if (unlinked > 0 && !dryRun) {
        const domainIdCol = domainCols.includes("baseDomain") ? "baseDomain" : "domain";
        for (const d of db.prepare("SELECT * FROM domains").all()) {
          const domainVal = d[domainIdCol] || d.domainId;
          if (!domainVal) continue;
          const upd = db.prepare(
            "UPDATE resources SET domainId = ? WHERE fullDomain LIKE ? AND domainId IS NULL"
          ).run(d.domainId, `%.${domainVal}`);
          if (upd.changes > 0) {
            process.stdout.write(`  Linked ${upd.changes} resource(s) to domain ${domainVal}\n`);
            fixed += upd.changes;
          }
        }
      }
    }
  }
}

// ── Fix 6: roleResources — admin role can see all resources ───────────────────
const rrTable = tables.find(t => t === "roleResources") || tables.find(t => t === "resourceRoles");
if (rrTable) {
  const rrCols = db.prepare(`PRAGMA table_info('${rrTable}')`).all().map(r => r.name);
  if (rrCols.includes("roleId") && rrCols.includes("resourceId")) {
    const orgs = db.prepare("SELECT DISTINCT orgId FROM resources").all();
    for (const { orgId } of orgs) {
      const adminRole = db.prepare(
        "SELECT roleId FROM roles WHERE orgId = ? AND isAdmin = 1 ORDER BY roleId ASC LIMIT 1"
      ).get(orgId);
      if (!adminRole) continue;

      const resources = db.prepare("SELECT resourceId FROM resources WHERE orgId = ?").all(orgId);
      for (const { resourceId } of resources) {
        if (!dryRun) {
          try {
            const r = db.prepare(
              `INSERT OR IGNORE INTO ${rrTable} (resourceId, roleId) VALUES (?, ?)`
            ).run(resourceId, adminRole.roleId);
            if (r.changes > 0) fixed++;
          } catch (_) { /* non-fatal */ }
        }
      }
    }
    process.stdout.write(`roleResources: admin role linked to all resources\n`);
  }
}

// ── Summary ───────────────────────────────────────────────────────────────────
db.close();
process.stdout.write(`\nFIX_COMPLETE changes=${fixed}${dryRun ? " (dry run)" : ""}\n`);
process.exit(0);
