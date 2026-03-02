# Pangolin API & Database Reference

Documented while building the automated Pangolin setup in `lib/pangolin.sh` and
`templates/pangolin/setup_pangolin.cjs`.  Covers the community edition (fosrl/pangolin).

---

## API Overview

Pangolin exposes **three API surfaces** on different ports:

| Port | Router file   | Used by                    |
|------|---------------|----------------------------|
| 3000 | `external.ts` | Public API (Traefik routes here externally) |
| 3001 | `internal.ts` | Gerbil (WireGuard manager), health checks   |
| 3003 | `integration.ts` | API-key-based external integrations       |

**Critical**: Port 3000 is the API port used by the web UI and all setup endpoints.
It is only accessible *inside* the Docker network (not mapped to the VPS host).
We call it via `docker exec pangolin node ...` which runs inside the container.

Port 3001 is mapped to `127.0.0.1:3001` on the VPS host (added in compose template)
so the installer can health-check Pangolin without going through Traefik.

---

## Endpoints Used by the Installer

All paths below are prefixed with `/api/v1`.

### Initial Setup (setup token — one-time)

```
PUT /auth/set-server-admin
Body: { email, password, setupToken }
Returns: 200 OK on success
```

The setup token is a 32-character alphanumeric string generated at container startup
and logged as:
```
=== SETUP TOKEN [GENERATED] ===
Token: <32-char-token>
Use this token on the initial setup page
```

Extract with: `docker logs pangolin 2>&1 | grep -i 'Token:' | tail -1 | sed 's/.*Token:[[:space:]]*//' | awk '{print $1}'`

There is also `POST /auth/validate-setup-token` (`{ token }`) that returns
`{ valid: bool, message: string }` — useful for sanity-checking before proceeding.

Once used, the token is marked as consumed in the DB (`setupTokens` table) and
cannot be reused.

### Login

```
POST /auth/login
Body: { email, password }
Returns: 200 + Set-Cookie session header
```

The session cookie must be captured and replayed as `Cookie: ...` in subsequent
requests.  Pangolin uses session cookies, not Bearer tokens, for the external API.

### Org Subnet Defaults

```
GET /pick-org-defaults
Cookie: <session>
Returns: { data: { subnet: "x.x.x.x/16", utilitySubnet: "x.x.x.x/16" } }
```

Pangolin allocates non-overlapping /16 blocks from `config.yml → orgs.subnet_group`
and `orgs.utility_subnet_group`.  Use this instead of hardcoding subnets to avoid
conflicts if the user runs multiple orgs.

### Create Organization

```
PUT /org
Cookie: <session>
Body: { orgId, name, subnet, utilitySubnet }
  orgId: 1–32 chars, pattern ^[a-z0-9_]+(-[a-z0-9_]+)*$
  subnet/utilitySubnet: non-overlapping IPv4 CIDR (e.g., "10.100.0.0/16")
Returns: 201 Created + org object
```

DB inserts performed by Pangolin: `orgs`, plus an admin `role` for the org,
plus `userOrgs` linking the new admin user to the org.

### Create Site (Newt type)

```
PUT /org/:orgId/site
Cookie: <session>
Body: { name, type: "newt", newtId, secret }
  newtId: string (we generate this — 16 lowercase alphanumeric chars)
  secret: plaintext (Pangolin hashes with Argon2 before storing)
Returns: 201 Created + site object (includes siteId)
```

DB inserts performed by Pangolin: `sites`, `roleSites`, `userSites`, `newt`.

**Important**: The response does NOT return the newtId or secret — only the site
record.  We must pre-generate the credentials ourselves and pass them in the request
body.  The plaintext secret is stored by the installer for the Newt client.

---

## Why API Instead of Direct DB

For the initial setup sequence (admin → org → site), the API is cleaner because:
- Admin creation requires the setup token to be validated and consumed atomically
- Org creation involves subnet allocation logic (handled by Pangolin internally)
- Site creation triggers multiple DB inserts including role/user association
- Pangolin handles Argon2 password hashing internally (we don't need to replicate it)

For resource registration after setup, direct DB access is used (see `add_resource.cjs`)
because the resource creation API has a known bug (GitHub issue #1344) and some
endpoint variants require CSRF tokens in browser sessions.

---

## Database Schema (SQLite at `/app/config/db/db.sqlite`)

### `user` (was `users` in older CE builds)

| Column              | Type    | Notes                              |
|---------------------|---------|------------------------------------|
| userId              | text PK | Short random ID                    |
| email               | text    |                                    |
| username            | text    | NOT NULL                           |
| name                | text    |                                    |
| type                | text    | "internal" or "oidc"               |
| passwordHash        | text    | **Argon2** hash (via oslo@1.2.1)   |
| twoFactorEnabled    | integer | boolean 0/1                        |
| emailVerified       | integer | boolean 0/1, default false         |
| dateCreated         | text    | ISO 8601                           |
| serverAdmin         | integer | boolean 0/1, default false         |
| lastPasswordChange  | integer |                                    |

### `orgs`

| Column              | Type    | Notes                              |
|---------------------|---------|------------------------------------|
| orgId               | text PK | Slug (^[a-z0-9_]+(-[a-z0-9_]+)*$) |
| name                | text    | NOT NULL                           |
| subnet              | text    | WireGuard overlay /16              |
| utilitySubnet       | text    | Utility addresses /16              |
| createdAt           | text    | ISO 8601                           |
| requireTwoFactor    | integer |                                    |
| maxSessionLengthHours | integer |                                  |
| passwordExpiryDays  | integer |                                    |
| settingsLogRetentionDaysRequest | integer | default 7           |
| settingsLogRetentionDaysAccess  | integer | default 0           |
| settingsLogRetentionDaysAction  | integer | default 0           |
| sshCaPrivateKey     | text    |                                    |
| sshCaPublicKey      | text    |                                    |
| isBillingOrg        | integer | CE: unused                         |
| billingOrgId        | text    | CE: unused                         |

### `roles`

| Column              | Type    | Notes                              |
|---------------------|---------|------------------------------------|
| roleId              | int PK  | AUTO_INCREMENT                     |
| orgId               | text FK | → orgs.orgId CASCADE               |
| isAdmin             | integer | boolean 0/1                        |
| name                | text    | NOT NULL (e.g., "Admin")           |
| description         | text    |                                    |
| requireDeviceApproval | integer | default false                    |
| sshSudoMode         | text    | default "none"                     |
| sshSudoCommands     | text    | JSON array, default "[]"           |
| sshCreateHomeDir    | integer | default true                       |
| sshUnixGroups       | text    | JSON array, default "[]"           |

### `userOrgs`

| Column         | Type    | Notes                              |
|----------------|---------|------------------------------------|
| userId         | text FK | → users.userId CASCADE             |
| orgId          | text FK | → orgs.orgId CASCADE               |
| roleId         | int FK  | → roles.roleId                     |
| isOwner        | integer | boolean 0/1, default false         |
| autoProvisioned | integer |                                   |
| pamUsername    | text    |                                    |

### `sites`

| Column              | Type    | Notes                              |
|---------------------|---------|------------------------------------|
| siteId              | int PK  | AUTO_INCREMENT                     |
| orgId               | text FK | → orgs.orgId CASCADE               |
| niceId              | text    | NOT NULL — human-readable slug     |
| exitNodeId          | int FK  | Optional                           |
| name                | text    | NOT NULL                           |
| pubKey              | text    | WireGuard public key               |
| subnet              | text    | Site subnet (within org /16)       |
| megabytesIn         | integer | default 0                          |
| megabytesOut        | integer | default 0                          |
| lastBandwidthUpdate | text    |                                    |
| type                | text    | "newt", "wireguard", or "local"    |
| online              | integer | boolean 0/1, default false         |
| address             | text    |                                    |
| endpoint            | text    |                                    |
| publicKey           | text    |                                    |
| listenPort          | integer |                                    |
| dockerSocketEnabled | integer | boolean 0/1, default true          |

### `newt` (table name is singular)

| Column      | Type    | Notes                              |
|-------------|---------|------------------------------------|
| id          | text PK | The newtId we generate             |
| secretHash  | text    | NOT NULL — Argon2 hash of secret   |
| dateCreated | text    | NOT NULL — ISO 8601                |
| version     | text    |                                    |
| siteId      | int FK  | → sites.siteId CASCADE             |

### `roleSites`

| Column  | Type   | Notes                 |
|---------|--------|-----------------------|
| roleId  | int FK | → roles.roleId CASCADE |
| siteId  | int FK | → sites.siteId CASCADE |

### `userSites`

| Column  | Type    | Notes                  |
|---------|---------|------------------------|
| userId  | text FK | → users.userId CASCADE  |
| siteId  | int FK  | → sites.siteId CASCADE  |

### `setupTokens`

| Column      | Type    | Notes                              |
|-------------|---------|------------------------------------|
| tokenId     | text PK | Primary key                        |
| token       | text    | NOT NULL — the 32-char token value |
| used        | integer | boolean 0/1, default false         |
| dateCreated | text    | ISO 8601                           |
| dateUsed    | text    | ISO 8601, nullable                 |

Pangolin skips setup token generation if a user with `serverAdmin=1` exists in `users`.
Mark the token used when inserting the admin user for cleanliness.

### `resources` (for reference — see `add_resource.cjs`)

**Note**: In Pangolin EE, `resources` no longer stores siteId/targetPort/targetHost/method.
Those moved to the new `targets` table. `resourceId` is now INTEGER AUTOINCREMENT (not text).

| Column        | Type       | Notes                                       |
|---------------|------------|---------------------------------------------|
| resourceId    | int PK     | AUTOINCREMENT                               |
| resourceGuid  | text(36)   | UUID, NOT NULL                              |
| orgId         | text FK    | → orgs.orgId CASCADE                        |
| niceId        | text       | NOT NULL — URL-safe slug                    |
| name          | text       | NOT NULL — display name                     |
| subdomain     | text       | Subdomain part only (e.g., `app`)           |
| fullDomain    | text       | Full FQDN (e.g., `app.example.com`)         |
| domainId      | text FK    | → domains.domainId, nullable                |
| ssl           | integer    | boolean, default false                      |
| http          | integer    | boolean, default true                       |
| protocol      | text       | NOT NULL — "tcp"                            |
| proxyPort     | integer    | Internal Pangolin tunnel port (65xxx)       |
| tlsServerName | text       | Must match fullDomain for TLS               |
| enabled       | integer    | boolean, default true                       |
| enableProxy   | integer    | boolean, default true (replaces proxyEnabled)|

### `targets` (new in EE — links resources to sites)

| Column        | Type    | Notes                                        |
|---------------|---------|----------------------------------------------|
| targetId      | int PK  | AUTOINCREMENT                                |
| resourceId    | int FK  | → resources.resourceId CASCADE               |
| siteId        | int FK  | → sites.siteId CASCADE                       |
| ip            | text    | NOT NULL — target host IP                    |
| method        | text    | **"https"** (connect to target via HTTPS)    |
| port          | integer | NOT NULL — target service port               |
| internalPort  | integer | Internal tunnel port (same as proxyPort)     |
| enabled       | integer | boolean, default true                        |
| priority      | integer | default 100                                  |

---

## Password Hashing

Pangolin uses **Argon2** via the `oslo` package (`oslo@1.2.1`, by Pilcrow).
Inside the container, it's accessible at `/app/node_modules/oslo`.

```javascript
// Inside the Pangolin container (Node.js 18+)
process.chdir('/app');
const { Argon2id } = await import('oslo/password');
const hasher = new Argon2id();
const hash = await hasher.hash(plaintext);
const valid = await hasher.verify(hash, plaintext);
```

This is used for both user passwords (`users.passwordHash`) and Newt secrets
(`newt.secretHash`).

---

## Database Path

```
/app/config/db/db.sqlite
```

Derived from: `APP_PATH = path.join("config")` in `server/lib/consts.ts`, relative to
the container workdir `/app`. Pangolin calls `bootstrapVolume()` at startup to create
`/app/config/db/` if it does not exist.

Set `PANGOLIN_DB_PATH` env var to override if the path ever changes.

---

## Direct DB Operations (via docker exec)

Pattern established in `PANGOLIN_INFRASTRUCTURE.md`:

```bash
# Run a Node.js script inside the container — copy to /app, NOT /tmp
# Scripts must run from /app so require('better-sqlite3') and import('oslo/password')
# resolve from /app/node_modules. From /tmp there are no node_modules.
ssh <vps> "sudo docker cp /tmp/script.cjs pangolin:/app/script.cjs && \
           sudo docker exec pangolin node /app/script.cjs && \
           sudo docker exec pangolin rm /app/script.cjs"

# Or inline for simple queries — use absolute module path (node -e has no __dirname context)
ssh <vps> "sudo docker exec pangolin node -e \"
  const db = require('/app/node_modules/better-sqlite3')('/app/config/db/db.sqlite');
  const rows = db.prepare('SELECT siteId, name FROM sites').all();
  console.log(JSON.stringify(rows, null, 2));
\""
```

### Rule: Use DB for all mutations — zero API calls during setup

**Confirmed from testing:** The Pangolin API returns 403 CSRF errors even for the initial
setup endpoint (`PUT /auth/set-server-admin`) when called from non-browser clients.
All mutations go through the database directly.

The Pangolin API history of issues:
- `PUT /auth/set-server-admin` — 403 CSRF error from non-browser clients
- `PUT /org/:id/resource` — broken, GitHub issue #1344
- `PUT /org/:id/site` (and POST variants) — CSRF token required
- API response bodies omit credentials created (e.g., newtId/secret not returned)

The installer uses **zero API calls**:
- Admin user: Argon2id hash via oslo, direct INSERT into `users` with `serverAdmin=1`
- Setup token: UPDATE `setupTokens` SET `used=1` to mark as consumed
- Org, role, user-org: direct INSERT
- Site, roleSites, userSites: direct INSERT
- Newt: Argon2id hash of secret, direct INSERT into `newt` table

---

## Known API Quirks

| Endpoint                | Issue                                      | Workaround          |
|-------------------------|--------------------------------------------|---------------------|
| `PUT /org/:id/resource` | Broken (GitHub issue #1344)               | Direct DB insert    |
| `POST /org/:id/site`    | May require CSRF token in browser context | Use PUT or DB       |
| `GET /pick-org-defaults`| Requires authenticated session            | Call after login    |
| `PUT /org/:id/site`     | Returns site object without newtId/secret | Pre-generate creds  |

---

## Resource Creation (Critical Settings)

**Always set these or resources get 404**:

```javascript
// In resources table:
//   tlsServerName MUST match fullDomain for TLS verification
//   enableProxy must be 1 (true)
//   proxyPort must be unique across all resources

// In targets table:
//   method MUST be 'https' if the backend uses TLS (e.g., HTTPS service)
//   ip = backend server IP
//   port = backend service port
//   internalPort = same as resources.proxyPort (65400+)
```

See `templates/pangolin/add_resource.cjs` for the full resource creation script.

The script creates both the `resources` row and a `targets` row in one transaction.
The site link (`siteId`) lives in `targets`, not `resources` (changed in Pangolin EE).
