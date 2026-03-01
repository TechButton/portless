#!/usr/bin/env node
/**
 * setup_pangolin.cjs — Automated Pangolin initial setup, 100% via database
 *
 * Run INSIDE the pangolin container (from /app so modules resolve):
 *   node /app/setup_pangolin.cjs /tmp/setup_config.json
 *
 * Config JSON fields:
 *   email, password, setupToken, orgId, orgName, siteName, newtId, newtSecret
 *
 * All steps use the SQLite database directly — no API calls.
 *
 * DB path: /app/config/db/db.sqlite
 * Table names: Pangolin EE uses 'user' (singular), not 'users'
 */

"use strict";

const fs     = require("fs");
const crypto = require("crypto");

// ─── Config ────────────────────────────────────────────────────────────────────

const cfgPath = process.argv[2] || "/tmp/pangolin-setup-config.json";
let cfg;
try {
  cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
} catch (err) {
  process.stderr.write(`Cannot read config (${cfgPath}): ${err.message}\n`);
  process.exit(1);
}

const { email, password, setupToken, orgId, orgName, siteName, newtId, newtSecret } = cfg;

const DB_PATH = "/app/config/db/db.sqlite";

// ─── Helpers ───────────────────────────────────────────────────────────────────

// Return column names for a table
function getColumns(db, tableName) {
  return db.prepare(`PRAGMA table_info('${tableName}')`).all().map(r => r.name);
}

// ─── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  process.chdir("/app");

  // Auto-discover DB path
  let resolvedDbPath = DB_PATH;
  if (!fs.existsSync(resolvedDbPath)) {
    const candidates = [
      "/app/config/db/db.sqlite",
      "/app/config/db.sqlite",
      "/app/db/db.sqlite",
      "/app/db.sqlite",
    ];
    resolvedDbPath = candidates.find(p => fs.existsSync(p)) || "";
    if (!resolvedDbPath) {
      process.stderr.write(`FAIL DB not found. Tried: ${candidates.join(", ")}\n`);
      process.exit(1);
    }
  }

  const Database = require("better-sqlite3");
  const db  = new Database(resolvedDbPath);
  const now = new Date().toISOString();

  // Verify schema and detect table names (EE uses 'user' not 'users')
  const tables = db.prepare(
    "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
  ).all().map(r => r.name);

  const userTable = tables.includes("user") ? "user"
                  : tables.includes("users") ? "users"
                  : null;
  if (!userTable) {
    process.stderr.write(`FAIL No user table found. Tables: ${tables.join(", ")}\n`);
    db.close();
    process.exit(1);
  }

  // Log column names for the tables we'll write to (helps diagnose schema changes)
  const userCols = getColumns(db, userTable);
  const orgCols  = getColumns(db, "orgs");
  const newtCols = getColumns(db, "newt");
  process.stderr.write(`INFO ${userTable} cols: ${userCols.join(", ")}\n`);
  process.stderr.write(`INFO orgs cols: ${orgCols.join(", ")}\n`);
  process.stderr.write(`INFO newt cols: ${newtCols.join(", ")}\n`);

  // ── Step 1: Hash password ─────────────────────────────────────────────────────
  let passwordHash;
  try {
    const { Argon2id } = await import("oslo/password");
    const hasher = new Argon2id();
    passwordHash = await hasher.hash(password);
  } catch (err) {
    process.stderr.write(`FAIL Argon2id hash (password): ${err.message}\n`);
    db.close();
    process.exit(1);
  }

  // ── Step 2: Generate userId ───────────────────────────────────────────────────
  const userId = crypto.randomBytes(8).toString("hex");

  // ── Step 3: Mark setup token used ────────────────────────────────────────────
  const tokenRow = db
    .prepare("SELECT tokenId FROM setupTokens WHERE token = ? AND used = 0")
    .get(setupToken);
  if (tokenRow) {
    db.prepare(
      "UPDATE setupTokens SET used = 1, dateUsed = ? WHERE tokenId = ?"
    ).run(now, tokenRow.tokenId);
  }

  // ── Step 4: Insert admin user ─────────────────────────────────────────────────
  // user table PK: 'id' in EE, 'userId' in older CE — introspect to find it
  // NOTE: FK columns in userOrgs/userSites are always 'userId' regardless of PK name
  const userPkCol      = userCols.includes("id")           ? "id"           : "userId";
  const passwordCol    = userCols.includes("passwordHash")  ? "passwordHash"  : "password";
  const serverAdminCol = userCols.includes("serverAdmin")   ? "serverAdmin"   : "isServerAdmin";
  const emailVerCol    = userCols.includes("emailVerified") ? "emailVerified" : "emailVerified";

  const username = email.split("@")[0];
  db.prepare(`
    INSERT INTO ${userTable}
      (${userPkCol}, email, username, name, type, ${passwordCol},
       twoFactorEnabled, ${emailVerCol}, dateCreated, ${serverAdminCol})
    VALUES (?, ?, ?, ?, 'internal', ?, 0, 1, ?, 1)
  `).run(userId, email.toLowerCase(), username, username, passwordHash, now);

  // ── Steps 5–7: Org, role, site, newt ─────────────────────────────────────────
  let siteId;
  let roleId;

  db.transaction(() => {
    // 5a. Organization — only include columns that exist
    const orgInsertCols = ["orgId", "name", "createdAt"].filter(c => orgCols.includes(c));
    const orgOptional = {
      subnet:                          "10.100.0.0/16",
      utilitySubnet:                   "10.200.0.0/16",
      settingsLogRetentionDaysRequest: 7,
      settingsLogRetentionDaysAccess:  0,
      settingsLogRetentionDaysAction:  0,
    };
    const extraCols = Object.keys(orgOptional).filter(c => orgCols.includes(c));
    const allOrgCols = [...orgInsertCols, ...extraCols];
    const allOrgVals = [orgId, orgName, now, ...extraCols.map(c => orgOptional[c])];

    db.prepare(
      `INSERT INTO orgs (${allOrgCols.join(", ")}) VALUES (${allOrgCols.map(() => "?").join(", ")})`
    ).run(...allOrgVals);

    // 5b. Admin role
    const roleResult = db.prepare(`
      INSERT INTO roles (orgId, isAdmin, name, description)
      VALUES (?, 1, 'Admin', 'Organization administrator')
    `).run(orgId);
    roleId = roleResult.lastInsertRowid;

    // 5c. Link user to org
    // userOrgs FK column is always 'userId' even when user table PK is 'id'
    db.prepare(`
      INSERT INTO userOrgs (userId, orgId, roleId, isOwner)
      VALUES (?, ?, ?, 1)
    `).run(userId, orgId, roleId);

    // 6a. Create site
    const niceId = (siteName || orgId)
      .toLowerCase()
      .replace(/[^a-z0-9]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "") || `${orgId}-site`;

    const siteResult = db.prepare(`
      INSERT INTO sites (orgId, niceId, name, type, online, dockerSocketEnabled)
      VALUES (?, ?, ?, 'newt', 0, 1)
    `).run(orgId, niceId, siteName);
    siteId = siteResult.lastInsertRowid;

    // 6b. Grant access
    db.prepare("INSERT INTO roleSites (roleId, siteId) VALUES (?, ?)").run(roleId, siteId);
    // userSites FK column is always 'userId'
    db.prepare(`INSERT INTO userSites (userId, siteId) VALUES (?, ?)`).run(userId, siteId);
  })();

  // ── Step 7: Newt record ───────────────────────────────────────────────────────
  let secretHash;
  try {
    const { Argon2id } = await import("oslo/password");
    const hasher = new Argon2id();
    secretHash = await hasher.hash(newtSecret);
  } catch (err) {
    process.stderr.write(`FAIL Argon2id hash (newtSecret): ${err.message}\n`);
    db.close();
    process.exit(1);
  }

  // newt table PK is 'id' (newtId) in all known schema versions
  const newtIdCol     = newtCols.includes("id")         ? "id"         : "newtId";
  const newtSecretCol = newtCols.includes("secretHash")  ? "secretHash"  : "secret";
  const newtDateCol   = newtCols.includes("dateCreated") ? "dateCreated" : "createdAt";

  db.prepare(`
    INSERT INTO newt (${newtIdCol}, ${newtSecretCol}, ${newtDateCol}, siteId)
    VALUES (?, ?, ?, ?)
  `).run(newtId, secretHash, now, siteId);

  db.close();

  try { fs.unlinkSync(cfgPath); } catch (_) {}

  process.stdout.write(
    `SETUP_RESULT org_id=${orgId} site_id=${siteId} role_id=${roleId} newt_id=${newtId} newt_secret=${newtSecret}\n`
  );
}

main().catch((err) => {
  process.stderr.write(`SETUP_ERROR: ${err.message}\n`);
  process.exit(1);
});
