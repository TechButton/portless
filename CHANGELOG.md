# Changelog

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
