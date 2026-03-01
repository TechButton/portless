#!/usr/bin/env node
/**
 * diagnose_pangolin.cjs — Dump Pangolin routing state for 404 debugging
 *
 * Run inside the pangolin container:
 *   node /app/diagnose_pangolin.cjs
 *
 * Shows: sites, resources, targets, domains — everything Pangolin uses to route.
 */
"use strict";

const Database = require("better-sqlite3");
const fs = require("fs");

const DB_PATH = process.env.PANGOLIN_DB_PATH || "/app/config/db/db.sqlite";
if (!fs.existsSync(DB_PATH)) { process.stderr.write(`DB not found: ${DB_PATH}\n`); process.exit(1); }

const db = new Database(DB_PATH, { readonly: true });
const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(r => r.name);

function hr(char = "─", len = 70) { return char.repeat(len); }
function p(s) { process.stdout.write(s + "\n"); }

p(hr("═"));
p("  PANGOLIN ROUTING DIAGNOSTICS");
p(hr("═"));
p("");

// ── Sites ──────────────────────────────────────────────────────────────────────
p("SITES:");
p(hr());
const sites = db.prepare("SELECT siteId, name, type, online, orgId FROM sites").all();
for (const s of sites) {
  const status = s.online ? "🟢 ONLINE" : "🔴 OFFLINE";
  p(`  siteId=${s.siteId}  name=${s.name}  type=${s.type}  org=${s.orgId}  ${status}`);
}
p("");

// ── Resources ─────────────────────────────────────────────────────────────────
p("RESOURCES:");
p(hr());
const resCols = db.prepare("PRAGMA table_info('resources')").all().map(r => r.name);
const res = db.prepare("SELECT * FROM resources ORDER BY resourceId").all();
for (const r of res) {
  p(`  resourceId=${r.resourceId}  name=${r.name}`);
  p(`    fullDomain=${r.fullDomain}  subdomain=${r.subdomain}`);
  p(`    proxyPort=${r.proxyPort}  enabled=${r.enabled}  enableProxy=${r.enableProxy}`);
  p(`    tlsServerName=${r.tlsServerName}  ssl=${r.ssl}  http=${r.http}`);
  if (resCols.includes("isShareableSite")) p(`    isShareableSite=${r.isShareableSite}`);
  if (resCols.includes("sso"))            p(`    sso=${r.sso}`);
  p("");
}

// ── Targets ───────────────────────────────────────────────────────────────────
if (tables.includes("targets")) {
  p("TARGETS:");
  p(hr());
  const targets = db.prepare("SELECT * FROM targets ORDER BY resourceId").all();
  for (const t of targets) {
    const warning = t.method === "https" ? "  ⚠️  method=https may cause 404 for plain-HTTP services!" : "";
    p(`  targetId=${t.targetId}  resourceId=${t.resourceId}  siteId=${t.siteId}`);
    p(`    ip=${t.ip}  port=${t.port}  method=${t.method}  internalPort=${t.internalPort}  enabled=${t.enabled}${warning}`);
    p("");
  }
}

// ── Domains ───────────────────────────────────────────────────────────────────
if (tables.includes("domains")) {
  p("DOMAINS:");
  p(hr());
  const domains = db.prepare("SELECT * FROM domains").all();
  if (domains.length === 0) {
    p("  (empty — resources without a domainId row may not route correctly in EE)");
  } else {
    for (const d of domains) {
      p(`  ${JSON.stringify(d)}`);
    }
  }
  p("");
}

// ── Resource ↔ Target mapping ─────────────────────────────────────────────────
if (tables.includes("targets")) {
  p("RESOURCE → TARGET MAPPING:");
  p(hr());
  const joined = db.prepare(`
    SELECT r.resourceId, r.name, r.fullDomain, r.proxyPort,
           t.targetId, t.siteId, t.ip, t.method, t.port, t.enabled
    FROM resources r
    LEFT JOIN targets t ON t.resourceId = r.resourceId
    ORDER BY r.resourceId
  `).all();
  for (const row of joined) {
    const ok = row.targetId ? "✓" : "✗ NO TARGET";
    const methodWarn = row.method === "https" ? " ⚠️  HTTPS→HTTP mismatch" : "";
    p(`  [${ok}] ${row.name} (${row.fullDomain})`);
    if (row.targetId) {
      p(`        → ${row.ip}:${row.port} via ${row.method}${methodWarn}  [site ${row.siteId}]`);
    }
  }
  p("");
}

// ── Summary / suggestions ─────────────────────────────────────────────────────
p("SUGGESTIONS:");
p(hr());

const offlineSites = sites.filter(s => !s.online);
if (offlineSites.length > 0) {
  p(`  ⚠️  ${offlineSites.length} site(s) OFFLINE — Newt is not connected to Pangolin.`);
  p("      Check: docker logs newt  (on your home server)");
  p("      Check: docker logs pangolin  (on VPS)");
}

if (tables.includes("targets")) {
  const httpsTargets = db.prepare("SELECT COUNT(*) AS n FROM targets WHERE method = 'https'").get();
  if (httpsTargets.n > 0) {
    p(`  ⚠️  ${httpsTargets.n} target(s) use method=https — this causes 404 for plain-HTTP services.`);
    p("      Fix: UPDATE targets SET method='http' WHERE method='https'");
  }

  const noTarget = db.prepare(`
    SELECT COUNT(*) AS n FROM resources r
    WHERE NOT EXISTS (SELECT 1 FROM targets t WHERE t.resourceId = r.resourceId)
  `).get();
  if (noTarget.n > 0) {
    p(`  ⚠️  ${noTarget.n} resource(s) have no target row — they will always 404.`);
  }
}

if (tables.includes("domains") && db.prepare("SELECT COUNT(*) AS n FROM domains").get().n === 0) {
  const resWithNullDomain = db.prepare(
    "SELECT COUNT(*) AS n FROM resources WHERE domainId IS NULL"
  ).get();
  if (resWithNullDomain.n > 0) {
    p(`  ⚠️  domains table is empty but ${resWithNullDomain.n} resource(s) have no domainId.`);
    p("      In some Pangolin EE versions, resources must be linked to a domain record.");
    p("      Run fix_domains to populate this table.");
  }
}

p("");
p("To fix method and restart: run apply_fixes.cjs or use manage.sh pangolin repair-db");
p(hr("═"));

db.close();
