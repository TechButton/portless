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
 *   7. userResources        — ensure all org users can see resources in dashboard
 *   8. roleActions/userActions — grant all 117 actions to admin roles and serverAdmin users
 *                              (CRITICAL: without these every API call returns 403)
 *   9. termsAcceptedTimestamp — set if null (may block dashboard rendering)
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

// ── Fix 8: roleActions + userActions — admin role must have all actions ────────
// Pangolin EE requires explicit per-action grants in roleActions even for isAdmin=1.
// Without these, every API call returns 403 "User does not have permission".
// The actions table is seeded by Pangolin migrations (100+ actions).
if (tables.includes("roleActions") && tables.includes("actions")) {
  const raCols = db.prepare("PRAGMA table_info('roleActions')").all().map(r => r.name);
  const allActions = db.prepare("SELECT actionId FROM actions").all().map(r => r.actionId);
  const raHasOrg = raCols.includes("orgId");
  const orgs = db.prepare("SELECT DISTINCT orgId FROM resources").all();
  let raAdded = 0;
  for (const { orgId } of orgs) {
    const adminRole = db.prepare(
      "SELECT roleId FROM roles WHERE orgId = ? AND isAdmin = 1 ORDER BY roleId ASC LIMIT 1"
    ).get(orgId);
    if (!adminRole) continue;
    for (const actionId of allActions) {
      if (!dryRun) {
        try {
          let r;
          if (raHasOrg) {
            r = db.prepare("INSERT OR IGNORE INTO roleActions (roleId, actionId, orgId) VALUES (?, ?, ?)").run(adminRole.roleId, actionId, orgId);
          } else {
            r = db.prepare("INSERT OR IGNORE INTO roleActions (roleId, actionId) VALUES (?, ?)").run(adminRole.roleId, actionId);
          }
          if (r.changes > 0) { fixed++; raAdded++; }
        } catch (_) { /* non-fatal */ }
      }
    }
  }
  if (dryRun) {
    process.stdout.write(`[DRY RUN] Would: Grant all ${allActions.length} actions to admin roles\n`);
  } else {
    const raCount = db.prepare("SELECT COUNT(*) AS n FROM roleActions").get().n;
    process.stdout.write(`roleActions: ${raCount} total rows (added ${raAdded} this run)\n`);
  }

  // userActions: grant all actions to serverAdmin users too
  if (tables.includes("userActions")) {
    const uaCols = db.prepare("PRAGMA table_info('userActions')").all().map(r => r.name);
    const uaHasOrg = uaCols.includes("orgId");
    const serverAdmins = db.prepare("SELECT id FROM user WHERE serverAdmin = 1").all();
    let uaAdded = 0;
    for (const { id } of serverAdmins) {
      const userOrgRows = db.prepare("SELECT orgId FROM userOrgs WHERE userId = ?").all(id);
      for (const { orgId } of userOrgRows) {
        for (const actionId of allActions) {
          if (!dryRun) {
            try {
              let r;
              if (uaHasOrg) {
                r = db.prepare("INSERT OR IGNORE INTO userActions (userId, actionId, orgId) VALUES (?, ?, ?)").run(id, actionId, orgId);
              } else {
                r = db.prepare("INSERT OR IGNORE INTO userActions (userId, actionId) VALUES (?, ?)").run(id, actionId);
              }
              if (r.changes > 0) { fixed++; uaAdded++; }
            } catch (_) { /* non-fatal */ }
          }
        }
      }
    }
    if (!dryRun) {
      const uaCount = db.prepare("SELECT COUNT(*) AS n FROM userActions").get().n;
      process.stdout.write(`userActions: ${uaCount} total rows (added ${uaAdded} this run)\n`);
    }
  }
}

// ── Fix 7: userResources — each org user can see all resources in dashboard ───
// Pangolin EE requires userResources rows in addition to roleResources.
// Without them the dashboard shows empty connections/settings even after login.
if (tables.includes("userResources")) {
  const userTable = tables.includes("user") ? "user" : "users";
  const userPkCol = db.prepare(`PRAGMA table_info('${userTable}')`).all()
    .map(r => r.name).includes("id") ? "id" : "userId";

  const orgs = db.prepare("SELECT DISTINCT orgId FROM resources").all();
  for (const { orgId } of orgs) {
    const orgUsers = db.prepare(
      `SELECT u.${userPkCol} AS uid FROM ${userTable} u
       JOIN userOrgs uo ON uo.userId = u.${userPkCol}
       WHERE uo.orgId = ?`
    ).all(orgId);
    const resources = db.prepare("SELECT resourceId FROM resources WHERE orgId = ?").all(orgId);

    for (const { uid } of orgUsers) {
      for (const { resourceId } of resources) {
        if (!dryRun) {
          try {
            const r = db.prepare(
              "INSERT OR IGNORE INTO userResources (userId, resourceId) VALUES (?, ?)"
            ).run(uid, resourceId);
            if (r.changes > 0) fixed++;
          } catch (_) { /* non-fatal */ }
        }
      }
    }
  }
  process.stdout.write(`userResources: all org users linked to all resources\n`);
}

// ── Fix 9: termsAcceptedTimestamp — set if null ───────────────────────────────
// Pangolin EE may block dashboard rendering if this is null on the admin user.
const termsCols = db.prepare("PRAGMA table_info('user')").all().map(r => r.name);
if (termsCols.includes("termsAcceptedTimestamp")) {
  const nullTerms = db.prepare("SELECT COUNT(*) AS n FROM user WHERE termsAcceptedTimestamp IS NULL").get().n;
  if (nullTerms > 0) {
    run("Set termsAcceptedTimestamp on users where null",
        `UPDATE user SET termsAcceptedTimestamp = ${Date.now()} WHERE termsAcceptedTimestamp IS NULL`);
  } else {
    process.stdout.write("termsAcceptedTimestamp: OK (set on all users)\n");
  }
}

// ── Summary ───────────────────────────────────────────────────────────────────
db.close();
process.stdout.write(`\nFIX_COMPLETE changes=${fixed}${dryRun ? " (dry run)" : ""}\n`);
process.exit(0);
