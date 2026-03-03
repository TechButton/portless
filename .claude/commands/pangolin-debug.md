# Pangolin Debug & Repair Skill

You are an expert on the Pangolin EE self-hosted tunnel server as used in the portless project. When invoked, diagnose and fix Pangolin issues using the knowledge below.

## Environment

- **VPS**: `linuxuser@108.61.119.92` via `ssh -i ~/.ssh/portless-deploy`
- **Homeserver**: `kyle@192.168.13.250` via `ssh -i ~/.ssh/portless-deploy`
- **Pangolin container**: `pangolin` on the VPS
- **DB path inside container**: `/app/config/db/db.sqlite`
- **Config**: `/opt/pangolin/config/config.yml` on VPS host
- **Scripts run from `/app`** inside the container (required for node module resolution)
- **Copy scripts**: `docker cp /tmp/script.cjs pangolin:/app/script.cjs && docker exec pangolin node /app/script.cjs`

---

## Pangolin EE Schema (critical differences from CE)

| Table/Field | Notes |
|---|---|
| `user` | Singular (not `users`). PK is `id` (not `userId`) |
| `user.id` → child FKs | FK columns in child tables are always `userId` even though PK is `id` |
| `resources.resourceId` | INTEGER AUTOINCREMENT (not text `res_<timestamp>`) |
| `resources` | No longer has `siteId`/`targetPort`/`targetHost`/`method` — moved to `targets` |
| `targets` | `targetId, resourceId, siteId, ip, method, port, internalPort, enabled, priority` |
| `resources` new fields | `resourceGuid` (UUID), `niceId` (slug), `fullDomain`, `enableProxy` |
| `roleActions` | `(roleId, actionId, orgId)` — **must** be populated for ALL 117 actions even for `isAdmin=1` |
| `userActions` | `(userId, actionId, orgId)` — grant to `serverAdmin` users |
| `session.id` | SHA256 hash of the raw cookie token (Lucia auth pattern) |
| `termsAcceptedTimestamp` | Must not be NULL or dashboard may be blocked |

---

## Known Issues & Fixes

### 1. Dashboard shows empty sites and resources (403 on all API calls)
**Cause**: `roleActions` table is empty. Pangolin EE requires all 117 actions explicitly granted even for `isAdmin=1` roles.
**Fix**:
```javascript
const allActions = db.prepare("SELECT actionId FROM actions").all().map(r => r.actionId);
const adminRoles = db.prepare("SELECT roleId, orgId FROM roles WHERE isAdmin = 1").all();
for (const { roleId, orgId } of adminRoles) {
  for (const actionId of allActions) {
    db.prepare("INSERT OR IGNORE INTO roleActions (roleId, actionId, orgId) VALUES (?, ?, ?)").run(roleId, actionId, orgId);
  }
}
// Also grant userActions to serverAdmin users
const admins = db.prepare("SELECT id FROM user WHERE serverAdmin = 1").all();
for (const { id } of admins) {
  const orgs = db.prepare("SELECT orgId FROM userOrgs WHERE userId = ?").all(id);
  for (const { orgId } of orgs) {
    for (const actionId of allActions) {
      db.prepare("INSERT OR IGNORE INTO userActions (userId, actionId, orgId) VALUES (?, ?, ?)").run(id, actionId, orgId);
    }
  }
}
```
**Automated fix**: `./manage.sh pangolin repair-db`

---

### 2. "You're not allowed to access this resource" on SSO
**Cause A**: `roleResources` is empty — admin role not linked to resources.
**Cause B**: `sso=1` on resources that should bypass SSO (column defaults to 1 in Pangolin EE — must always be written explicitly in INSERT).
**Fix A**: Run `fix_pangolin.cjs` (Fix 6).
**Fix B**: `UPDATE resources SET sso = 0 WHERE niceId IN ('portainer', 'seerr', 'arrmate', 'readmeabook');`

---

### 3. All resources return 404
**Cause**: `resources.domainId` is NULL. Pangolin skips routing for resources without a `domainId`.
**Fix**:
```javascript
const domains = db.prepare("SELECT domainId, baseDomain FROM domains").all();
for (const d of domains) {
  db.prepare("UPDATE resources SET domainId = ? WHERE fullDomain LIKE ? AND domainId IS NULL")
    .run(d.domainId, `%.${d.baseDomain}`);
}
```

---

### 4. Resources return 502 / TLS handshake failure
**Cause**: `targets.method = 'https'` for plain-HTTP backends.
**Fix**: `UPDATE targets SET method = 'http' WHERE method = 'https';`

---

### 5. Pangolin dashboard UI redirect loop
**Cause**: `resources.isShareableSite = 1` with `enableProxy = 1` causes infinite redirect between `/resources/proxy` and `/resources`.
**Fix**: `UPDATE resources SET isShareableSite = 0;`

---

### 6. WireGuard / Newt tunnel not connecting
**Cause A**: `pangolin.<domain>` is behind Cloudflare proxy — WireGuard uses UDP and cannot go through CF proxy.
**Fix A**: WireGuard endpoint must use `wg.<domain>` DNS-only A record. `pangolin.<domain>` stays CF-proxied (HTTPS dashboard only).
**Cause B**: `sites.pubKey` is pre-populated. Newt generates its own key on first connect; a pre-set key causes "Public key mismatch".
**Fix B**: `UPDATE sites SET pubKey = NULL WHERE siteId = ?;`
**Cause C**: Newt container missing capabilities.
**Fix C**: Add to Newt compose snippet:
```yaml
cap_add: [NET_ADMIN]
sysctls:
  net.ipv4.conf.all.src_valid_mark: "1"
```

---

### 7. Pangolin dashboard shows empty connections/settings after login
**Cause**: `userResources` table is missing rows. Pangolin EE requires both `roleResources` AND `userResources` for dashboard visibility.
**Fix**:
```javascript
const orgUsers = db.prepare(
  "SELECT u.id AS uid FROM user u JOIN userOrgs uo ON uo.userId = u.id WHERE uo.orgId = ?"
).all(orgId);
const resources = db.prepare("SELECT resourceId FROM resources WHERE orgId = ?").all(orgId);
for (const { uid } of orgUsers) {
  for (const { resourceId } of resources) {
    db.prepare("INSERT OR IGNORE INTO userResources (userId, resourceId) VALUES (?, ?)").run(uid, resourceId);
  }
}
```

---

### 8. termsAcceptedTimestamp null blocks dashboard
**Fix**: `UPDATE user SET termsAcceptedTimestamp = ${Date.now()} WHERE termsAcceptedTimestamp IS NULL;`

---

### 9. Pangolin Integration API returns 401
**Cause A**: `flags.enable_integration_api: true` missing from `/opt/pangolin/config/config.yml`.
**Cause B**: Integration API is on port 3003, not 3000. Use `/v1/` prefix (not `/api/v1/`).
**Auth format**: `Authorization: Bearer <id>.<secret>`

---

### 10. API calls from curl always return 403 CSRF error
**Cause**: Pangolin uses CSRF protection. All mutating requests need:
`X-CSRF-Token: x-csrf-protection`
Session IDs in the DB are SHA256 hashes — do not use them directly as cookie values.

---

## Permission Tables Required Per Resource

| Table | Purpose | Required |
|---|---|---|
| `roleResources (roleId, resourceId)` | SSO auth check | Yes |
| `userResources (userId, resourceId)` | Dashboard visibility | Yes |
| `roleActions (roleId, actionId, orgId)` | API permission enforcement | Yes (all 117) |
| `userActions (userId, actionId, orgId)` | Per-user API permissions | Yes for serverAdmin |
| `roleSites (roleId, siteId)` | Site access for role | Yes |
| `userSites (userId, siteId)` | Site access for user | Yes |

---

## Automated Repair

Run on the VPS to fix all known issues in one pass:
```bash
# From homeserver (portless project):
./manage.sh pangolin repair-db

# Or directly on VPS:
sudo docker cp /path/to/fix_pangolin.cjs pangolin:/app/fix_pangolin.cjs
sudo docker exec pangolin node /app/fix_pangolin.cjs
sudo docker exec pangolin node /app/fix_pangolin.cjs --dry-run  # preview only
```

`fix_pangolin.cjs` applies 9 fixes in order:
1. `isShareableSite = 0` — prevents UI redirect loop
2. `enableProxy = 1` — ensure proxy tunnel active
3. `enabled = 1` — enable all resources and targets
4. `targets.method = http` — fix TLS handshake failures
5. `domains` table — create missing records, link resources
6. `roleResources` — link admin role to all resources
7. `userResources` — link all org users to all resources
8. `roleActions` / `userActions` — grant all 117 actions to admin roles and serverAdmin users
9. `termsAcceptedTimestamp` — set if null

---

## Diagnostic Checklist

When investigating a Pangolin issue, run this script inside the container:

```javascript
// Save as /tmp/diag.cjs, docker cp to /app, node /app/diag.cjs
"use strict";
const Database = require('better-sqlite3');
const db = new Database('/app/config/db/db.sqlite');

const checks = {
  users:          db.prepare("SELECT id, email, serverAdmin, termsAcceptedTimestamp FROM user").all(),
  orgs:           db.prepare("SELECT orgId, name FROM orgs").all(),
  roles:          db.prepare("SELECT roleId, orgId, isAdmin, name FROM roles").all(),
  sites:          db.prepare("SELECT siteId, name, online, pubKey FROM sites").all(),
  resources:      db.prepare("SELECT resourceId, name, sso, domainId, enableProxy, enabled FROM resources").all(),
  targets:        db.prepare("SELECT targetId, resourceId, ip, port, method, enabled FROM targets").all(),
  userOrgs:       db.prepare("SELECT * FROM userOrgs").all(),
  userSites:      db.prepare("SELECT * FROM userSites").all(),
  userResources:  db.prepare("SELECT COUNT(*) as n FROM userResources").get(),
  roleResources:  db.prepare("SELECT COUNT(*) as n FROM roleResources").get(),
  roleActions:    db.prepare("SELECT COUNT(*) as n FROM roleActions").get(),
  userActions:    db.prepare("SELECT COUNT(*) as n FROM userActions").get(),
  domains:        db.prepare("SELECT * FROM domains").all(),
  sessions:       db.prepare("SELECT id, userId, expiresAt FROM session").all(),
};
console.log(JSON.stringify(checks, null, 2));
db.close();
```

**Healthy state** (9 resources):
- `roleResources`: 9 rows
- `userResources`: 9 rows
- `roleActions`: 117 rows
- `userActions`: 117 rows
- `domains`: ≥ 1 row
- `resources`: all have `domainId` not null, `enableProxy=1`, `enabled=1`
- `targets`: all have `method=http` (unless backend serves TLS)
- `sites`: `pubKey` set (after Newt connects), `online=true`

---

## Port Layout

| Port | Service |
|------|---------|
| 3000 | External API (session auth, `/api/v1/`) |
| 3001 | Internal API |
| 3002 | Next.js dashboard frontend |
| 3003 | Integration API (API key auth, `/v1/`) |

---

## Cloudflare DNS Requirements

Two records required for Pangolin:
1. `pangolin.<domain>` → VPS IP, **CF-proxied** (HTTPS/WebSocket dashboard)
2. `wg.<domain>` → VPS IP, **DNS-only** (WireGuard UDP port 21820, must bypass CF)

`gerbil.base_endpoint` in `config.yml` must use `wg.<domain>`, not `pangolin.<domain>`.

---

## Procedure: Adding a new user to Pangolin via DB

```javascript
const { execSync } = require('child_process');
const crypto = require('crypto');
const hash = execSync(
  `node --input-type=module -e "const {Argon2id}=await import('oslo/password');process.stdout.write(await new Argon2id().hash('PASSWORD'))"`,
  { cwd: '/app' }
).toString().trim();

const userId = crypto.randomBytes(8).toString('hex');
const orgId = 'portless'; // your org
const roleId = 1;         // admin role

db.prepare(`INSERT INTO user (id, email, username, name, type, passwordHash, emailVerified, termsAcceptedTimestamp, serverAdmin, dateCreated)
  VALUES (?, ?, ?, ?, 'internal', ?, 1, ?, 0, ?)`
).run(userId, 'user@example.com', 'username', 'Display Name', hash, Date.now(), new Date().toISOString());

db.prepare("INSERT OR IGNORE INTO userOrgs (userId, orgId, roleId, isOwner, autoProvisioned) VALUES (?, ?, ?, 0, 0)").run(userId, orgId, roleId);

// Then populate userSites, userResources, userActions for the new user
```
