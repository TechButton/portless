#!/usr/bin/env node
/**
 * repair_pangolin_db.cjs — Repair Pangolin database access control
 *
 * Run INSIDE the pangolin container (from /app so modules resolve):
 *   node /app/repair_pangolin_db.cjs [--email admin@example.com] [--org-id <orgId>]
 *
 * What it fixes:
 *   1. serverAdmin flag missing on admin user
 *   2. Missing userOrgs / isOwner entry for admin
 *   3. Missing admin role (isAdmin=1) for org
 *   4. Missing roleSites entries linking admin role to sites
 *   5. Missing userSites entries linking admin user to sites
 *   6. Missing roleResources/resourceRoles entries (EE: admin must be linked per-resource)
 *   7. Warns about resources with no matching target row
 *
 * Outputs lines prefixed with INFO:, FIXED:, WARNING:, ERROR:
 * Final line: REPAIR_COMPLETE fixed=N issues=N
 * Exit 0 on success (or nothing to fix), non-zero on hard error.
 */

"use strict";

const Database = require("better-sqlite3");
const fs = require("fs");

// ─── Config ────────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const opts = {};
for (let i = 0; i < args.length; i += 2) {
  opts[args[i].replace(/^--/, "").replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = args[i + 1];
}

const DB_PATH = process.env.PANGOLIN_DB_PATH || "/app/config/db/db.sqlite";

if (!fs.existsSync(DB_PATH)) {
  process.stderr.write(`FAIL DB not found: ${DB_PATH}\n`);
  process.exit(1);
}

// ─── Helpers ───────────────────────────────────────────────────────────────────

const db = new Database(DB_PATH);

function getColumns(tbl) {
  return db.prepare(`PRAGMA table_info('${tbl}')`).all().map(r => r.name);
}

const allTables = db.prepare(
  "SELECT name FROM sqlite_master WHERE type='table'"
).all().map(r => r.name);

function tableExists(name) { return allTables.includes(name); }

let fixed   = 0;
let issues  = 0;

function info(msg)    { process.stdout.write(`INFO: ${msg}\n`); }
function warn(msg)    { process.stdout.write(`WARNING: ${msg}\n`); issues++; }
function tryFix(desc, fn) {
  try {
    fn();
    process.stdout.write(`FIXED: ${desc}\n`);
    fixed++;
  } catch (e) {
    process.stdout.write(`ERROR: Could not fix "${desc}": ${e.message}\n`);
    issues++;
  }
}

// ─── Discover schema ───────────────────────────────────────────────────────────

const userTable    = allTables.find(t => t === "user")  ||
                     allTables.find(t => t === "users") || null;
if (!userTable) {
  process.stderr.write(`FAIL No user/users table found. Tables: ${allTables.join(", ")}\n`);
  db.close();
  process.exit(1);
}

const userCols      = getColumns(userTable);
const userPkCol     = userCols.includes("id")           ? "id"           : "userId";
const serverAdminCol= userCols.includes("serverAdmin")  ? "serverAdmin"  : "isServerAdmin";
const emailVerCol   = userCols.includes("emailVerified")? "emailVerified": "emailVerified";

info(`User table: ${userTable}  PK: ${userPkCol}  serverAdmin col: ${serverAdminCol}`);

// ─── Find admin user ───────────────────────────────────────────────────────────

let adminUser;
if (opts.email) {
  adminUser = db.prepare(
    `SELECT * FROM ${userTable} WHERE LOWER(email) = ?`
  ).get(opts.email.toLowerCase());
  if (!adminUser) {
    process.stderr.write(`FAIL No user found with email: ${opts.email}\n`);
    db.close();
    process.exit(1);
  }
} else {
  // Auto-detect: first user with serverAdmin=1, or fall back to the first user
  adminUser = db.prepare(
    `SELECT * FROM ${userTable} WHERE ${serverAdminCol} = 1 ORDER BY ${userPkCol} LIMIT 1`
  ).get();
  if (!adminUser) {
    adminUser = db.prepare(
      `SELECT * FROM ${userTable} ORDER BY ${userPkCol} LIMIT 1`
    ).get();
  }
}

if (!adminUser) {
  process.stderr.write(`FAIL No users found in database.\n`);
  db.close();
  process.exit(1);
}

const userId     = adminUser[userPkCol] || adminUser.id || adminUser.userId;
const adminEmail = adminUser.email;
info(`Admin user: ${adminEmail} (${userPkCol}=${userId})`);

// ─── 1. Ensure serverAdmin = 1 ────────────────────────────────────────────────

if (!adminUser[serverAdminCol]) {
  tryFix(`Set ${serverAdminCol}=1 for ${adminEmail}`, () => {
    db.prepare(
      `UPDATE ${userTable} SET ${serverAdminCol} = 1 WHERE ${userPkCol} = ?`
    ).run(userId);
  });
} else {
  info(`${serverAdminCol} already 1 ✓`);
}

// ─── 2. Ensure emailVerified = 1 ──────────────────────────────────────────────

if (userCols.includes(emailVerCol) && !adminUser[emailVerCol]) {
  tryFix(`Set ${emailVerCol}=1 for ${adminEmail}`, () => {
    db.prepare(
      `UPDATE ${userTable} SET ${emailVerCol} = 1 WHERE ${userPkCol} = ?`
    ).run(userId);
  });
}

// ─── Loop over orgs ───────────────────────────────────────────────────────────

const targetOrgId = opts.orgId || null;
const orgs = targetOrgId
  ? db.prepare("SELECT * FROM orgs WHERE orgId = ?").all(targetOrgId)
  : db.prepare("SELECT * FROM orgs").all();

info(`Found ${orgs.length} org(s)${targetOrgId ? ` (filtered to ${targetOrgId})` : ""}`);

for (const org of orgs) {
  const orgId = org.orgId;
  info(`─── Org: ${orgId} (${org.name}) ───`);

  // ── 3. Ensure admin role exists ─────────────────────────────────────────────

  let adminRole = db.prepare(
    "SELECT * FROM roles WHERE orgId = ? AND isAdmin = 1 ORDER BY roleId ASC LIMIT 1"
  ).get(orgId);

  if (!adminRole) {
    warn(`Org ${orgId} has no admin role — creating one`);
    tryFix(`Create admin role for org ${orgId}`, () => {
      const r = db.prepare(
        "INSERT INTO roles (orgId, isAdmin, name, description) VALUES (?, 1, 'Admin', 'Organization administrator')"
      ).run(orgId);
      adminRole = db.prepare("SELECT * FROM roles WHERE roleId = ?").get(r.lastInsertRowid);
    });
  } else {
    info(`Admin role: roleId=${adminRole.roleId} ✓`);
  }

  const roleId = adminRole ? adminRole.roleId : null;

  // ── 4. Ensure userOrgs entry (with isOwner=1) ───────────────────────────────

  const userOrgsCols = getColumns("userOrgs");
  const userOrg = db.prepare(
    "SELECT * FROM userOrgs WHERE userId = ? AND orgId = ?"
  ).get(userId, orgId);

  if (!userOrg) {
    warn(`userOrgs entry missing for admin in org ${orgId}`);
    if (roleId) {
      tryFix(`Add userOrgs entry: ${adminEmail} → ${orgId} (owner, roleId=${roleId})`, () => {
        const autoProvPart = userOrgsCols.includes("autoProvisioned") ? ", autoProvisioned" : "";
        const autoProvVals = userOrgsCols.includes("autoProvisioned") ? ", 0"             : "";
        db.prepare(
          `INSERT OR IGNORE INTO userOrgs (userId, orgId, roleId, isOwner${autoProvPart})
           VALUES (?, ?, ?, 1${autoProvVals})`
        ).run(userId, orgId, roleId);
      });
    }
  } else {
    if (!userOrg.isOwner) {
      tryFix(`Set isOwner=1 for ${adminEmail} in org ${orgId}`, () => {
        db.prepare("UPDATE userOrgs SET isOwner = 1 WHERE userId = ? AND orgId = ?").run(userId, orgId);
      });
    } else {
      info(`userOrgs entry: isOwner=1, roleId=${userOrg.roleId} ✓`);
    }
    // If roleId is wrong, update it
    if (roleId && userOrg.roleId !== roleId) {
      tryFix(`Update userOrgs roleId to ${roleId} for ${adminEmail} in ${orgId}`, () => {
        db.prepare("UPDATE userOrgs SET roleId = ? WHERE userId = ? AND orgId = ?").run(roleId, userId, orgId);
      });
    }
  }

  // ── 5. Sites: roleSites + userSites ──────────────────────────────────────────

  const sites = db.prepare("SELECT * FROM sites WHERE orgId = ?").all(orgId);
  info(`Sites in org ${orgId}: ${sites.length}`);

  for (const site of sites) {
    const siteId = site.siteId;

    if (roleId) {
      const roleSite = db.prepare(
        "SELECT 1 FROM roleSites WHERE roleId = ? AND siteId = ?"
      ).get(roleId, siteId);
      if (!roleSite) {
        tryFix(`Add roleSites: roleId=${roleId} → siteId=${siteId}`, () => {
          db.prepare("INSERT OR IGNORE INTO roleSites (roleId, siteId) VALUES (?, ?)").run(roleId, siteId);
        });
      }
    }

    const userSite = db.prepare(
      "SELECT 1 FROM userSites WHERE userId = ? AND siteId = ?"
    ).get(userId, siteId);
    if (!userSite) {
      tryFix(`Add userSites: admin → siteId=${siteId}`, () => {
        db.prepare("INSERT OR IGNORE INTO userSites (userId, siteId) VALUES (?, ?)").run(userId, siteId);
      });
    }
  }

  // ── 6. Resources: roleResources / resourceRoles ──────────────────────────────

  if (!tableExists("resources")) { continue; }

  const resources = db.prepare(
    "SELECT resourceId FROM resources WHERE orgId = ?"
  ).all(orgId);
  info(`Resources in org ${orgId}: ${resources.length}`);

  // Find the role-resource junction table (name varies by EE version)
  const rrTable = allTables.find(t => t === "roleResources") ||
                  allTables.find(t => t === "resourceRoles") || null;

  if (rrTable && roleId) {
    const rrCols = getColumns(rrTable);
    if (rrCols.includes("roleId") && rrCols.includes("resourceId")) {
      for (const { resourceId } of resources) {
        const existing = db.prepare(
          `SELECT 1 FROM ${rrTable} WHERE roleId = ? AND resourceId = ?`
        ).get(roleId, resourceId);
        if (!existing) {
          tryFix(`Add ${rrTable}: roleId=${roleId} → resourceId=${resourceId}`, () => {
            db.prepare(
              `INSERT OR IGNORE INTO ${rrTable} (roleId, resourceId) VALUES (?, ?)`
            ).run(roleId, resourceId);
          });
        }
      }
    } else {
      info(`${rrTable} schema differs — cols: ${rrCols.join(", ")} (skipping)`);
    }
  } else if (!rrTable) {
    info("No roleResources/resourceRoles table — isAdmin=1 grants implicit access (OK)");
  }

  // ── 7. Warn about resources with no target row ───────────────────────────────

  if (tableExists("targets")) {
    for (const { resourceId } of resources) {
      const target = db.prepare("SELECT 1 FROM targets WHERE resourceId = ?").get(resourceId);
      if (!target) {
        warn(`Resource ${resourceId} in org ${orgId} has no targets row — it will 404`);
      }
    }
  }
}

// ─── Done ─────────────────────────────────────────────────────────────────────

db.close();
process.stdout.write(`\nREPAIR_COMPLETE fixed=${fixed} issues=${issues}\n`);
process.exit(issues > 0 && fixed === 0 ? 2 : 0);
