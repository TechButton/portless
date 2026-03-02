#!/usr/bin/env node
/**
 * set_resource_auth.cjs — Enable or disable Pangolin SSO auth on a resource
 *
 * Run inside the pangolin container:
 *   node /app/set_resource_auth.cjs --resource-id <N> --sso <0|1>
 *
 * --sso 1  → resource requires Pangolin login before access
 * --sso 0  → resource is publicly accessible (no Pangolin login)
 *
 * Supports Pangolin EE column variants: isShareableSite, sso, requireAuth
 */
"use strict";

const Database = require("better-sqlite3");
const fs = require("fs");

const DB_PATH = process.env.PANGOLIN_DB_PATH || "/app/config/db/db.sqlite";
if (!fs.existsSync(DB_PATH)) {
  process.stderr.write(`DB not found: ${DB_PATH}\n`);
  process.exit(1);
}

const args = process.argv.slice(2);
const opts = {};
for (let i = 0; i < args.length; i += 2) {
  opts[args[i].replace(/^--/, "").replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = args[i + 1];
}

const resourceId = parseInt(opts.resourceId, 10);
if (!resourceId || isNaN(resourceId)) {
  process.stderr.write("Missing or invalid --resource-id\n");
  process.exit(1);
}

const ssoVal = (opts.sso === "1" || opts.sso === "true") ? 1 : 0;

const db = new Database(DB_PATH);

// Check resource exists
const resRow = db.prepare("SELECT resourceId, name FROM resources WHERE resourceId = ?").get(resourceId);
if (!resRow) {
  process.stderr.write(`Resource not found: resourceId=${resourceId}\n`);
  db.close();
  process.exit(1);
}

const resCols = db.prepare("PRAGMA table_info('resources')").all().map(r => r.name);

// Try each known SSO/auth column in priority order.
// NOTE: isShareableSite is intentionally excluded — it is NOT an auth flag.
// Setting isShareableSite=1 switches a resource to "public shareable site" mode
// which conflicts with enableProxy=1 and causes the UI redirect loop.
const ssoCol = ["sso", "requireAuth"].find(c => resCols.includes(c));

if (!ssoCol) {
  // No SSO column — not supported in this build, exit cleanly
  process.stdout.write(
    `AUTH_SET resourceId=${resourceId} name="${resRow.name}" sso_col=none status=unsupported\n`
  );
  db.close();
  process.exit(0);
}

const result = db.prepare(
  `UPDATE resources SET ${ssoCol} = ? WHERE resourceId = ?`
).run(ssoVal, resourceId);

db.close();

process.stdout.write(
  `AUTH_SET resourceId=${resourceId} name="${resRow.name}" ${ssoCol}=${ssoVal} changes=${result.changes}\n`
);
process.exit(0);
