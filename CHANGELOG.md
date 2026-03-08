# Changelog

## [0.8.11] — 2026-03-07

### Security — SDL + STRIDE/PASTA threat-model review

Full Security Development Lifecycle audit followed by STRIDE and PASTA threat modelling. 19 findings resolved across 7 files.

#### SDL findings (11)

- **`lib/state.sh` — jq key injection** — `state_set_num()` and `state_set_bool()` now validate the key argument against `^[a-zA-Z0-9._]+$` before interpolating it into a jq filter string. Unsanitised keys could have escaped the jq expression.
- **`lib/state.sh` — port range exhaustion** — `pangolin_next_port()` now emits a warning at port ≥ 65500 and dies at ≥ 65535, preventing silent wrap-around or invalid port allocation.
- **`lib/state.sh` — state file permissions** — `state_init()` now runs `chmod 600` on the state file immediately after creation so credentials stored there are not world-readable before the first write.
- **`lib/common.sh` — log file permissions** — `_log_to_file()` creates the log file with `install -m 600 /dev/null` on first write, preventing a window where the file is world-readable.
- **`lib/cloudflare.sh` — `noTLSVerify: true`** — `cf_configure_tunnel_wildcard()` had `"noTLSVerify": true` in the Cloudflare ingress config. Changed to `false` so origin TLS is always verified.
- **`lib/cloudflare.sh` — tunnel token in compose env** — `TUNNEL_TOKEN` was written inline in the docker-compose `environment:` block (visible via `docker inspect`). Now written to `secrets/cloudflared.env` (chmod 600) and referenced via `env_file:`.
- **`lib/pangolin.sh` — SSH host key TOFU** — all three SSH init functions (`_pang_init_connection`, `_nb_init_ssh`, `_hs_init_connection`) now emit an explicit warning when `StrictHostKeyChecking=accept-new` is active so operators know the first connection is TOFU and can verify fingerprints manually.
- **`lib/pangolin.sh` — sed log redaction metacharacter injection** — log redaction of `admin_password` and `newt_secret` used raw string interpolation in `sed`. Added `_pang_sed_escape()` to escape all sed metacharacters before substitution.
- **`lib/pangolin.sh` — org ID shell injection** — `PANGOLIN_ORG_ID` is interpolated into SSH remote commands. Both entry points (`_pang_prompt_manual_credentials`, `pangolin_wizard_existing`) now validate the value against `^[a-z0-9][a-z0-9_-]*$` before use.
- **`lib/pangolin.sh` — resource ID injection** — `pangolin_remove_resource()` validates `resource_id` against `^[0-9]+$` before passing it to the API.
- **`lib/pangolin.sh` — SSH authorized_keys command injection** — `pangolin_copy_ssh_key()` piped the public key content via a variable expansion into a remote command. Replaced with `printf '%s\n' "$pub_key_content" | _pang_ssh "cat >> ~/.ssh/authorized_keys"` so the key value never touches the remote shell command line.

#### STRIDE / PASTA findings (8)

- **`lib/pangolin.sh` — `AllowTcpForwarding yes`** (Elevation of Privilege) — SSH hardening block changed to `AllowTcpForwarding local`, restricting TCP forwards to loopback. Prevents the VPS from being used as a general-purpose jump host.
- **`lib/pangolin.sh` — Pangolin config file permissions** — `chmod 600` added for `/opt/pangolin/config/config.yml` on the VPS. The config contains secrets (DB passwords, JWT keys).
- **`lib/pangolin.sh` — Newt secrets in compose env** — `NEWT_SECRET`, `NEWT_ID`, and `PANGOLIN_ENDPOINT` were written inline in the Newt docker-compose `environment:` block. Moved to `secrets/newt.env` (chmod 600) referenced via `env_file:`.
- **`templates/pangolin/pangolin-compose.yml.tmpl` — mutable image tags** — Added comment block documenting that `ee-latest` and `latest` tags are mutable; advises pinning images to SHA digests for production use with instructions on how to verify digests.
- **`lib/state.sh` — `state_set_bool()` value validation** — enforces only `true` or `false` as valid values, preventing boolean fields from being set to arbitrary strings.
- **`lib/state.sh` — `state_set_num()` integer validation** — enforces non-negative integer values, preventing numeric fields from being set to negative numbers or non-numeric strings.
- **`lib/common.sh` — `render_template()` single-pass substitution** — added comment documenting that template rendering is single-pass and template variable names must not contain content matching other variable patterns.
- **`lib/state.sh` — `state_init()` permissions race** — `chmod 600` is now called immediately after the heredoc write (before any further state operations) to minimise the window during which the file is world-readable.

---

## [0.8.6] — 2026-03-05

### Security — `setup_pangolin.cjs` audit and hardening

- **Path traversal fix** — `cfgPath` (from `process.argv[2]`) is now resolved with `path.resolve()` and rejected unless it starts with `/tmp/`. This prevents arbitrary file reads and deletes if the argument is attacker-controlled.
- **SQL injection hardening** — `getColumns()` now validates `tableName` against an explicit `ALLOWED_TABLES` allowlist before issuing the `PRAGMA table_info(...)` query. Dynamic column names in INSERT statements are documented as derived from hardcoded ternary pairs with no user input path.
- **`newtSecret` plaintext exposure** — Removed `newt_secret=…` from the `SETUP_RESULT` stdout line; the secret no longer appears in Docker logs or the install log file. `pangolin.sh` now assigns `NEWT_SECRET` from its local variable instead of parsing it back from output. The log write in `pangolin.sh` is also piped through `sed` to redact `admin_password` and `newt_secret`.
- **Input validation** — All eight config fields (`email`, `password`, `setupToken`, `orgId`, `orgName`, `siteName`, `newtId`, `newtSecret`) are validated for presence, string type, max length, and email format before any database operations begin.

---

## [0.8.5] — 2026-03-02

### Fixed — Pangolin dashboard empty (critical)

- **`roleActions` / `userActions` missing** (`setup_pangolin.cjs`, `fix_pangolin.cjs`)
  Pangolin EE enforces permissions via the `roleActions` table for every API call, even
  for roles with `isAdmin = 1`. Without rows in `roleActions`, every request returns
  403 "User does not have permission perform this action", so the dashboard renders with
  empty sites and resources. `setup_pangolin.cjs` now populates `roleActions` and
  `userActions` with all 117 actions immediately after the admin role is created.
  `fix_pangolin.cjs` gains Fix 8 to backfill both tables on existing installs.

- **`termsAcceptedTimestamp` null** (`fix_pangolin.cjs`)
  Pangolin EE may block dashboard rendering if the admin user's `termsAcceptedTimestamp`
  is null. The field is now set during initial DB setup in `setup_pangolin.cjs` and
  backfilled by `fix_pangolin.cjs`.

---

## [0.7.0] — 2026-03-02

### Fixed — Pangolin tunnel (critical)

- **WireGuard endpoint split** (`pangolin-config.yml.tmpl`, `pangolin.sh`)
  Cloudflare proxy only forwards TCP; WireGuard uses UDP. Using the same hostname for
  both the dashboard and the WireGuard endpoint prevented the tunnel from connecting.
  Fix: `pangolin.<domain>` stays Cloudflare-proxied (HTTPS/dashboard), a new
  `wg.<domain>` DNS-only A record is created for the WireGuard endpoint.
  DNS records are now created automatically during VPS setup.

- **`sso` column defaults to 1 in Pangolin EE** (`add_resource.cjs`)
  Resources registered without `--sso 1` still got `sso=1` from the column default,
  causing every resource to demand a Pangolin login. `add_resource.cjs` now always
  writes `sso` explicitly (0 or 1) so the default is never used.

- **`domainId` null** (`add_resource.cjs`)
  Resources with a null `domainId` are silently ignored by Pangolin's routing engine —
  no Traefik rules are generated, so every request returns 404. The script now
  auto-discovers the correct `domainId` by matching the resource's full domain against
  the `domains` table.

- **`sites.pubKey` must be NULL for Newt** (`setup_pangolin.cjs`, documented)
  If a non-null public key is stored in `sites.pubKey` before Newt connects, Pangolin
  logs "Public key mismatch" and overwrites with the old key. Newt has no corresponding
  private key and the WireGuard handshake fails silently. The key must be left NULL so
  Pangolin accepts whatever key Newt presents on first connect.

- **Newt container capabilities** (`install.sh`, `pangolin.sh`)
  Added `cap_add: [NET_ADMIN]` and `sysctls: net.ipv4.conf.all.src_valid_mark=1` to
  the Newt compose snippet. Required for userspace WireGuard to function inside Docker.

- **`SEERR_PORT` / `READMEABOOK_PORT` missing** (`templates/env.template`)
  Added the missing port variables so containers start without `.env` warnings.

- **`userResources` missing** (`add_resource.cjs`, `fix_pangolin.cjs`)
  Pangolin EE requires a row in `userResources` for each (user, resource) pair in
  addition to `roleResources`. Without it the dashboard shows empty connections and
  settings even after successful login. `add_resource.cjs` now populates `userResources`
  for every org user on each new resource insert.

### Added — new `fix_pangolin.cjs` repair script (`templates/pangolin/`)

A comprehensive DB repair script that can be run at any time to fix common issues:
1. Clear `isShareableSite=1` (causes UI redirect loop with `enableProxy=1`)
2. Ensure `enableProxy=1` on all resources
3. Enable all resources and targets
4. Reset `targets.method` from `https` to `http` (prevents TLS handshake failures)
5. Create missing `domains` table records and link resources
6. Link admin role to all resources via `roleResources`
7. Populate `userResources` for all org users (dashboard visibility)

Run manually:
```bash
./manage.sh pangolin repair-db
```

---

## [0.6.0] — 2026-02-28

### Added

- **Headless / non-interactive install** — `install.sh` can now be driven by a
  pre-written answers file. Use `portless-answers.sh.example` as a template.
- **Pangolin SSO per-resource** — `./manage.sh pangolin sso <app> on|off` to toggle
  Pangolin's login gate on individual resources.
- **Compose auto-regen** — if an installed app's compose snippet is missing from the
  generated file (e.g. after adding a new app), `manage.sh` re-adds it automatically.
- **New apps**: Seerr (Jellyseerr wrapper), Readmeabook (audiobook manager)
- **`fix_404.cjs`** — targeted repair for the 404-on-all-resources bug caused by null
  `domainId`.
- **Pangolin DB schema reference** (`docs/pangolin-api-database.md`) — field-by-field
  notes on the Pangolin EE SQLite schema.
- **Migration guide** (`docs/migrating.md`) — steps to move an existing stack to a new
  server.
- **Whiptail GUI** (`gui.sh`) — optional TUI wrapper around the install wizard and
  management commands.

### Fixed

- Pangolin `setup_pangolin.cjs` now outputs `role_id` in `SETUP_RESULT` so it is
  stored in state for later use by repair scripts.
- Strip Docker `profiles:` from compose snippets at startup to avoid service selection
  issues.
- Various prompt/readline fixes for headless install mode.

---

## [0.5.x] — 2026-02-20

### Added

- **Pangolin VPS tunnel** — full automated setup: VPS init, Pangolin/Gerbil/Traefik
  stack, Newt sidecar, and per-app resource registration via direct SQLite access
  (no API calls, bypasses CSRF issues).
- **`setup_pangolin.cjs`** — zero-API initial setup: admin user, org, role, site, newt
  record — all written directly to the SQLite DB via Argon2id password hashing.
- **`add_resource.cjs`** — register HTTP resources in Pangolin's DB, creating both the
  `resources` and `targets` rows in one transaction.
- **Per-resource auth control** (`set_resource_auth.cjs`) — enable/disable Pangolin SSO
  per resource without touching the dashboard.
- **NFS per-share mounts** — each NFS export can be mounted to its own subfolder
  (`/mnt/data/movies`, `/mnt/data/tv`, etc.) using `showmount` discovery.

---

## [0.2.0] — 2026-02-10

### Added

- Initial Pangolin DB setup automation
- CrowdSec placement guidance (home server vs VPS)
- TinyAuth SSO integration

### Fixed

- Pangolin 404 repair tooling
- SSO configuration for arr stack

---

## [0.1.0] — 2026-01

Initial release:
- Interactive install wizard (6 phases)
- Traefik reverse proxy with wildcard TLS via Cloudflare DNS-01
- App catalog: Plex, Sonarr, Radarr, Lidarr, Bazarr, Prowlarr, SABnzbd, Portainer,
  and 90+ optional apps
- Remote access: Cloudflare Tunnel, Tailscale, Headscale, Netbird
- TinyAuth / Basic Auth / None authentication options
- CrowdSec intrusion prevention
