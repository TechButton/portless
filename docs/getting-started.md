# Getting Started

## Prerequisites

- Linux server (Ubuntu 22.04+ recommended, 4 GB RAM minimum)
- A domain name managed by Cloudflare — needed for automatic wildcard TLS certs
- Optionally, a small VPS if you want Pangolin or Headscale for remote access

You don't need a VPS if you choose Cloudflare Tunnel, Tailscale, or Netbird.

## Quick Start

```bash
git clone https://github.com/techbutton/portless.git
cd portless
chmod +x install.sh manage.sh
./install.sh
```

## What the wizard does

The installer runs through six phases and asks questions as it goes:

1. **System check** — confirms Docker is installed (offers to install if missing), checks for jq, curl, git
2. **Basic config** — hostname, Linux user, timezone (auto-detected), Docker directory, media/data directory
3. **Domain & network** — your domain, Cloudflare API token, server LAN IP, Traefik access mode (local vs hybrid), authentication layer (TinyAuth / Basic Auth / None)
4. **App selection** — pick what to run from a categorized checklist
5. **Remote access** — choose how to reach services from outside your home network
6. **Generate & deploy** — writes your `.env`, middleware chain files, and `docker-compose-<hostname>.yml`, runs a staging cert test, then starts everything

### Media directory setup (Phase 2)

After entering your data directory (default `/mnt/data`), the installer checks whether the path exists and is writable. If it isn't — which is common since `/mnt` is root-owned — it offers four options:

```
How would you like to set up /mnt/data?

  1) Create locally (sudo mkdir + chown)
     Creates the directory with sudo and sets ownership to your user.
     Use this for a local disk or partition mounted at a root-owned path.

  2) Mount an NFS share
     Prompts for server, export path, and NFS version. Installs nfs-common
     if needed, test-mounts, and adds a persistent fstab entry.

  3) Mount an SMB/CIFS share
     Prompts for server, share name, and credentials. Installs cifs-utils,
     stores credentials in $DOCKERDIR/secrets/.smb_credentials (chmod 600),
     test-mounts, and adds a persistent fstab entry.

  4) Skip — I will set it up manually
     Continues the install without creating subdirectories. You must create
     the directory and set ownership before starting containers.
```

NFS and SMB fstab entries are written with `_netdev,nofail`:
- `_netdev` — delays the mount until the network is up (prevents boot failure if the NAS isn't immediately reachable)
- `nofail` — allows the server to boot normally even if the mount fails (NAS down, wrong credentials, etc.)

Once the directory is accessible, the installer creates this subdirectory layout:

```
/mnt/data/
├── media/
│   ├── movies/
│   ├── tv/
│   ├── music/
│   ├── books/
│   ├── audiobooks/
│   └── comics/
├── downloads/
├── usenet/
│   ├── incomplete/
│   └── complete/
└── torrents/
    ├── incomplete/
    └── complete/
```

Each subdirectory is exposed to the relevant containers as a named variable in your `.env` (`MOVIES_DIR`, `TV_DIR`, `MUSIC_DIR`, `BOOKS_DIR`, `AUDIOBOOKS_DIR`, `COMICS_DIR`). See [Data directories in .env](#data-directories-in-env) below.

### Traefik access mode (Phase 3)

```
How will you access your services?

  1) Hybrid — LAN + remote (recommended)
     • LAN access on port 443  (fast, direct, always works)
     • Remote access on port 444 via your tunnel
     • Apps can be restricted to LAN-only or available both ways

  2) Local only
     • LAN access on port 443 only
     • Add remote access later with: ./manage.sh tunnel setup
```

### Authentication (Phase 3)

```
Authentication system:

  1) TinyAuth — self-hosted SSO (recommended)
     One login covers all apps. Optional 2FA.

  2) Basic Auth — simple username/password
     No SSO — each browser session prompts separately.

  3) None — no auth layer
     Only safe for LAN-only setups or apps with built-in auth.
```

### Remote access (Phase 5)

```
1) Cloudflare Tunnel  — free, no VPS, public URLs
2) Pangolin on a VPS  — ~$18/year, self-hosted, public URLs
3) Tailscale          — free, private VPN, no public URLs
4) Headscale          — free, self-hosted Tailscale, needs a VPS
5) Netbird            — free, WireGuard mesh, cloud or self-hosted
6) Skip               — LAN only for now
```

If you're not sure, Cloudflare Tunnel is the easiest starting point. See [Remote Access Guide](remote-access.md) for a full comparison.

### CrowdSec (after Phase 5)

Portless asks about CrowdSec intrusion prevention **after** you pick your tunnel, because the right answer depends on your setup:

- **Pangolin / Cloudflare Tunnel** — your home server only sees the tunnel IP, not real attacker IPs. CrowdSec is more useful on the Pangolin VPS (instructions shown after install) or handled by Cloudflare's WAF. Skipped by default.
- **No tunnel / direct** — real IPs are visible, CrowdSec is genuinely useful. Prompted with Yes as default.
- **Tailscale / Headscale / Netbird** — private VPN only, no public exposure. Silently skipped.

## What gets created

```
~/docker/
├── .env                              # All config variables
├── .homelab-state.json               # State tracking (don't delete this)
├── docker-compose-<hostname>.yml     # Your full stack
├── secrets/                          # Credential files (chmod 600)
│   ├── cf_dns_api_token
│   ├── basic_auth_credentials
│   ├── tinyauth_secret
│   └── .smb_credentials              # Written only if SMB mount was chosen
└── appdata/
    ├── tinyauth/
    │   └── users_file                # TinyAuth user accounts
    └── traefik3/
        ├── acme/acme.json            # TLS certificates
        └── rules/<hostname>/         # Traefik dynamic config
            ├── tls-opts.yml
            ├── middlewares-secure-headers.yml
            ├── middlewares-rate-limit.yml
            ├── middlewares-tinyauth.yml
            ├── chain-no-auth.yml
            ├── chain-tinyauth.yml
            ├── chain-basic-auth.yml
            ├── chain-default.yml     # Alias for chosen auth system
            └── app-radarr.yml        # Per-app routing rules
```

## Data directories in .env

The generated `.env` contains named variables for each media type. All paths default to subdirectories under your chosen data directory:

```bash
DATADIR=/mnt/data            # Root data directory

MOVIES_DIR=/mnt/data/media/movies
TV_DIR=/mnt/data/media/tv
MUSIC_DIR=/mnt/data/media/music
BOOKS_DIR=/mnt/data/media/books
AUDIOBOOKS_DIR=/mnt/data/media/audiobooks
COMICS_DIR=/mnt/data/media/comics

DOWNLOADSDIR=/mnt/data/downloads
```

These are mounted directly into the relevant containers — Radarr gets `$MOVIES_DIR`, Sonarr gets `$TV_DIR`, Lidarr gets `$MUSIC_DIR`, Audiobookshelf gets `$AUDIOBOOKS_DIR`, and so on. Media servers (Plex, Jellyfin, Emby) receive all three of movies/tv/music.

You can edit these paths in `.env` after install if your library is organised differently.

## App API keys in .env

The `.env` also contains placeholders for API keys that tie the stack together. Some are applied automatically; others need to be filled in after first launch.

### Pre-applied at startup (arr stack)

Radarr, Sonarr, Lidarr, and Prowlarr read their own API key from the environment variable on first start. Set these to any value you choose before launching — a UUID works well:

```bash
RADARR_API_KEY=your-chosen-key
SONARR_API_KEY=your-chosen-key
LIDARR_API_KEY=your-chosen-key
PROWLARR_API_KEY=your-chosen-key
```

Because you control the value, you can configure Prowlarr, Overseerr, Notifiarr, and other integrations without hunting for keys in each app's UI after the fact.

### Fill in after first launch

These apps generate their own API keys internally. Look them up in each app's **Settings → General** page and paste them into `.env`:

| Variable | App | Where to find it |
|---|---|---|
| `SABNZBD_API_KEY` | SABnzbd | Config → General → API Key |
| `BAZARR_API_KEY` | Bazarr | Settings → General → API Key |
| `PLEX_TOKEN` | Plex | [support.plex.tv/articles/204059436](https://support.plex.tv/articles/204059436) |
| `JELLYFIN_API_KEY` | Jellyfin | Dashboard → API Keys |
| `OVERSEERR_API_KEY` | Overseerr | Settings → General → API Key |
| `TAUTULLI_API_KEY` | Tautulli | Settings → Web Interface → API Key |
| `TMDB_API_KEY` | TMDB | [themoviedb.org/settings/api](https://www.themoviedb.org/settings/api) |

After updating `.env`, restart affected containers:
```bash
docker compose --env-file ~/docker/.env -f ~/docker/docker-compose-$(hostname).yml up -d
```

## Accessing services

With Cloudflare Tunnel or Pangolin, each service gets a public HTTPS URL:

| Service   | URL                               |
|-----------|-----------------------------------|
| TinyAuth  | `https://auth.example.com`        |
| Plex      | `https://plex.example.com`        |
| Radarr    | `https://movies.example.com`      |
| Sonarr    | `https://tv.example.com`          |
| Portainer | `https://portainer.example.com`   |

With Tailscale or Netbird, services are accessible via your device's VPN IP or hostname — only from enrolled devices.

## Day-to-day

```bash
./manage.sh add jellyfin            # Add an app post-install
./manage.sh status                  # Show containers and their URLs
./manage.sh update                  # Pull new images and restart
./manage.sh logs radarr             # Follow logs for one container
./manage.sh tunnel status           # Check remote access configuration
./manage.sh security crowdsec-setup # Wire up CrowdSec bouncer API key
./manage.sh security auth           # Change auth layer
```

## Cloudflare setup

You need Cloudflare managing your domain for automatic TLS certs (DNS-01 challenge).

1. Sign up at [cloudflare.com](https://cloudflare.com) and add your domain
2. Create an API token at [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
   - Use the **Edit zone DNS** template
   - Scope it to your specific zone
3. Enter the token during Phase 3 of the install

The installer validates the token against the Cloudflare API before saving it, then runs a staging cert test to confirm everything works before issuing real certificates.

## Switching remote access later

```bash
./manage.sh tunnel setup
```

This runs the full tunnel wizard and updates your running stack.

## Next steps

- [Remote Access Guide](remote-access.md) — detailed comparison of all five methods
- [Pangolin Guide](pangolin-guide.md) — VPS setup, DNS config, troubleshooting
- [Adding Apps](adding-apps.md) — add apps not in the default catalog
- [Troubleshooting](troubleshooting.md)
