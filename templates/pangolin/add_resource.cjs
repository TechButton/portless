#!/usr/bin/env node
/**
 * add_resource.cjs — Register a Pangolin tunnel resource via direct DB access
 *
 * Usage (run inside the pangolin container):
 *   node add_resource.cjs \
 *     --site-id <N> \
 *     --name <app-name> \
 *     --subdomain <subdomain.domain.com> \
 *     --http-port <internal_port> \
 *     --target-port <service_port> \
 *     --target-host <server_lan_ip>
 *
 * Outputs: the new resource ID (integer) on stdout
 *
 * Critical notes (from PANGOLIN_INFRASTRUCTURE.md):
 *   - method must be 'https' (NOT 'http') to avoid redirect loops
 *   - tlsServerName must be set to the subdomain (for cert verification)
 *   - proxyEnabled must be 1 (true)
 */

"use strict";

const Database = require("better-sqlite3");
const path = require("path");

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
    console.error(`Missing required argument: --${key.replace(/([A-Z])/g, "-$1").toLowerCase()}`);
    process.exit(1);
  }
}

// ─── Database path ─────────────────────────────────────────────────────────────
// Pangolin stores its DB at /app/config/db.sqlite3 inside the container
const DB_PATH = process.env.PANGOLIN_DB_PATH || "/app/config/db.sqlite3";

if (!require("fs").existsSync(DB_PATH)) {
  console.error(`Database not found at: ${DB_PATH}`);
  console.error("Set PANGOLIN_DB_PATH env var if it's in a different location.");
  process.exit(1);
}

// ─── Insert resource ──────────────────────────────────────────────────────────
const db = new Database(DB_PATH);

try {
  // Generate a short unique resource ID token
  const resourceId = `res_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;

  const stmt = db.prepare(`
    INSERT INTO resources (
      resourceId,
      siteId,
      orgId,
      name,
      subdomain,
      http,
      protocol,
      proxyPort,
      targetPort,
      targetHost,
      method,
      tlsServerName,
      proxyEnabled,
      isBaseDomain,
      createdAt,
      updatedAt
    ) VALUES (
      @resourceId,
      @siteId,
      (SELECT orgId FROM sites WHERE siteId = @siteId),
      @name,
      @subdomain,
      1,
      'tcp',
      @httpPort,
      @targetPort,
      @targetHost,
      'https',
      @subdomain,
      1,
      0,
      @now,
      @now
    )
  `);

  const result = stmt.run({
    resourceId,
    siteId: parseInt(opts.siteId, 10),
    name: opts.name,
    subdomain: opts.subdomain,
    httpPort: parseInt(opts.httpPort, 10),
    targetPort: parseInt(opts.targetPort, 10),
    targetHost: opts.targetHost,
    now: new Date().toISOString(),
  });

  if (result.changes === 0) {
    console.error("Insert failed — no rows changed");
    process.exit(1);
  }

  // Return the new rowid so the caller can store it
  console.log(result.lastInsertRowid);
  process.exit(0);
} catch (err) {
  console.error("DB error:", err.message);
  process.exit(1);
} finally {
  db.close();
}
