#!/usr/bin/env node
/**
 * fix_404.cjs — Fix the most common causes of 404 on Pangolin tunnel resources
 *
 * Run inside the pangolin container:
 *   node /app/fix_404.cjs [--dry-run]
 *
 * Fixes applied:
 *   1. targets.method = 'http'  (was 'https' — caused TLS handshake failure = 404)
 *   2. resources.enableProxy = 1  (ensure proxy is active)
 *   3. resources.enabled = 1      (ensure resource is active)
 *   4. targets.enabled = 1        (ensure target is active)
 *   5. Populate domains table if empty and resources have no domainId (EE requirement)
 */
"use strict";

const Database = require("better-sqlite3");
const fs = require("fs");

const DB_PATH = process.env.PANGOLIN_DB_PATH || "/app/config/db/db.sqlite";
if (!fs.existsSync(DB_PATH)) { process.stderr.write(`DB not found: ${DB_PATH}\n`); process.exit(1); }

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
  }
  return result.changes;
}

// ── Fix 1: targets.method → http ─────────────────────────────────────────────
if (tables.includes("targets")) {
  const n = db.prepare("SELECT COUNT(*) AS n FROM targets WHERE method = 'https'").get().n;
  if (n > 0) {
    process.stdout.write(`Found ${n} target(s) with method=https — fixing to http\n`);
    run("Set targets.method = 'http' (was 'https')",
        "UPDATE targets SET method = 'http' WHERE method = 'https'");
  } else {
    process.stdout.write("targets.method: OK (no https targets)\n");
  }
}

// ── Fix 2: Enable all resources ───────────────────────────────────────────────
run("Enable all disabled resources",
    "UPDATE resources SET enabled = 1 WHERE enabled = 0");

if (resCols.includes("enableProxy")) {
  run("Enable proxy on all resources",
      "UPDATE resources SET enableProxy = 1 WHERE enableProxy = 0 OR enableProxy IS NULL");
}

// ── Fix 3: Enable all targets ─────────────────────────────────────────────────
if (tables.includes("targets")) {
  run("Enable all disabled targets",
      "UPDATE targets SET enabled = 1 WHERE enabled = 0");
}

// ── Fix 4: domains table (Pangolin EE) ────────────────────────────────────────
// In Pangolin EE, each resource must link to a domain record.
// If the domains table is empty, create one entry per unique base domain
// and link all matching resources to it.
if (tables.includes("domains")) {
  const domainCols = db.prepare("PRAGMA table_info('domains')").all().map(r => r.name);
  const existing = db.prepare("SELECT COUNT(*) AS n FROM domains").get().n;

  if (existing === 0) {
    // Gather all distinct base domains from resources.fullDomain
    const resources = db.prepare(
      "SELECT DISTINCT orgId, fullDomain FROM resources WHERE fullDomain IS NOT NULL"
    ).all();

    const baseDomains = new Map(); // baseDomain → orgId
    for (const r of resources) {
      // Extract base domain: last two parts (e.g. "galaxybutton.tech" from "app.galaxybutton.tech")
      const parts = r.fullDomain.split(".");
      const base = parts.length >= 2 ? parts.slice(-2).join(".") : r.fullDomain;
      if (!baseDomains.has(base)) baseDomains.set(base, r.orgId);
    }

    for (const [baseDomain, orgId] of baseDomains) {
      process.stdout.write(`Domains table empty — creating domain record for ${baseDomain}\n`);
      if (!dryRun) {
        try {
          // domain table columns vary — try common patterns
          let insertSql;
          if (domainCols.includes("domainId") && domainCols.includes("baseDomain")) {
            insertSql = "INSERT OR IGNORE INTO domains (domainId, baseDomain, orgId) VALUES (?, ?, ?)";
            db.prepare(insertSql).run(baseDomain, baseDomain, orgId);
          } else if (domainCols.includes("domain")) {
            insertSql = "INSERT OR IGNORE INTO domains (domain, orgId) VALUES (?, ?)";
            db.prepare(insertSql).run(baseDomain, orgId);
          } else {
            process.stdout.write(`  WARNING: Unknown domains schema: ${domainCols.join(", ")} — skipping\n`);
            continue;
          }

          // Link resources to this domain
          if (resCols.includes("domainId")) {
            const idRow = db.prepare("SELECT domainId FROM domains WHERE domainId = ? OR baseDomain = ? OR domain = ?")
              .get(baseDomain, baseDomain, baseDomain);
            if (idRow) {
              const upd = db.prepare(
                `UPDATE resources SET domainId = ? WHERE fullDomain LIKE ? AND domainId IS NULL`
              ).run(idRow.domainId, `%.${baseDomain}`);
              process.stdout.write(`  Linked ${upd.changes} resource(s) to domain ${baseDomain}\n`);
              fixed += upd.changes;
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

    // Ensure all resources have a domainId if the column exists
    if (resCols.includes("domainId")) {
      const unlinked = db.prepare(
        "SELECT COUNT(*) AS n FROM resources WHERE domainId IS NULL"
      ).get().n;
      if (unlinked > 0) {
        process.stdout.write(`${unlinked} resource(s) have no domainId — attempting to link\n`);
        if (!dryRun) {
          const domains = db.prepare("SELECT * FROM domains").all();
          const domainIdCol = domainCols.includes("baseDomain") ? "baseDomain" : "domain";
          for (const d of domains) {
            const domainVal = d[domainIdCol] || d.domainId;
            if (!domainVal) continue;
            const upd = db.prepare(
              `UPDATE resources SET domainId = ? WHERE fullDomain LIKE ? AND domainId IS NULL`
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
}

// ── Summary ───────────────────────────────────────────────────────────────────
db.close();
process.stdout.write(`\nFIX_COMPLETE changes=${fixed}${dryRun ? " (dry run)" : ""}\n`);
process.exit(0);
