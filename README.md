# portless

An interactive setup wizard and management CLI for a self-hosted media stack. No port forwarding, no exposed home IP, no router changes required.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-yellow?logo=buy-me-a-coffee)](https://buymeacoffee.com/techbutton)

---

## What it does

Run `./install.sh` and walk through everything: Docker, wildcard TLS certs, authentication, app selection, and remote access. When it's done, all your services are behind HTTPS with Traefik, protected by a single login, and reachable from anywhere — without touching your router.

Works with any ISP including CGNAT.

---

## Quick Start

```bash
git clone https://github.com/techbutton/portless.git
cd portless
chmod +x install.sh manage.sh
./install.sh
```

The wizard is fully interactive. It detects your OS, offers to install Docker if missing, and steps you through everything one question at a time.

---

## Remote Access — pick one

| Method | Cost | VPS needed | Public URLs | Setup |
|--------|------|-----------|-------------|-------|
| **Cloudflare Tunnel** | Free | No | Yes | ~5 min |
| **Pangolin** | ~$18/yr | Yes | Yes | ~15 min |
| **Tailscale** | Free | No | No | ~3 min |
| **Headscale** | ~$18/yr | Yes | No | ~20 min |
| **Netbird** | Free | No (cloud) | No | ~3 min |

All methods avoid port forwarding and work with CGNAT. Your home IP is never exposed. See [Remote Access Guide](docs/remote-access.md) for the full comparison.

---

## Security

### Authentication
Every service is protected by a single login — pick one during setup:

| Option | Description |
|--------|-------------|
| **TinyAuth** *(recommended)* | Self-hosted SSO. One login covers all apps. Optional GitHub/Google OAuth and TOTP 2FA. Runs as a single lightweight container. |
| **Basic Auth** | Username/password built into Traefik. Simple, no extra container. No SSO — each browser session prompts separately. |
| **None** | No auth layer. Only safe if all your apps have their own login (Plex, Portainer, etc.) and you're LAN-only. |

### Middleware chains
Traefik applies a chain of middleware to every request:

```
[CrowdSec bouncer] → rate limit → secure headers → [auth]
```

Three named chains are always available:
- `chain-no-auth` — rate limit + secure headers only (for apps with built-in auth)
- `chain-tinyauth` — + TinyAuth SSO gate
- `chain-basic-auth` — + HTTP Basic Auth prompt
- `chain-default` — alias for whichever auth system you chose at install

### CrowdSec
CrowdSec intrusion prevention is available but **placement matters**:

- **Behind Pangolin or Cloudflare Tunnel** — CrowdSec on your home server sees only the tunnel IP, not real attacker IPs. It's more effective on your Pangolin VPS (the installer shows you how after setup). Cloudflare Tunnel users already get edge protection from Cloudflare's WAF for free.
- **No tunnel / direct exposure** — CrowdSec on the home server makes sense and is offered as the default during install.
- **Tailscale / Headscale / Netbird** — private VPN only, no public exposure at all. CrowdSec is skipped.

### Pangolin resource authentication (double lock)
If you use Pangolin, you can enable a second login gate at the VPS level — before traffic even reaches Traefik or TinyAuth. Recommended for sensitive apps (Portainer, VS Code, Traefik dashboard). See the post-install guidance for steps.

---

## Access modes

Choose during install how Traefik listens:

| Mode | Ports | Use case |
|------|-------|----------|
| **Hybrid** *(recommended)* | 443 (LAN) + 444 (tunnel) | Fast local access plus remote via tunnel |
| **Local only** | 443 (LAN) | Home network only — add remote later |

In hybrid mode, apps can be restricted to LAN-only or made available on both entrypoints. The tunnel provider connects to port 444.

---

## TLS certificates

Portless uses Cloudflare's DNS-01 challenge for automatic wildcard certs (`*.yourdomain.com`) via Let's Encrypt. This works even without any open ports.

Before switching to production certs, the installer runs a **staging certificate test** to verify your Cloudflare token and DNS are correct. Let's Encrypt's rate limits won't punish you for configuration mistakes.

---

## Included apps

| Category | Apps |
|----------|------|
| Core | Traefik, Socket Proxy, TinyAuth |
| Security | CrowdSec (optional) |
| Media | Plex, Jellyfin, Emby |
| *Arr | Sonarr, Radarr, Lidarr, Bazarr, Prowlarr |
| Books / Comics | Kavita, Komga, Calibre-Web, Mylar3 |
| Music | Navidrome |
| Audiobooks | Audiobookshelf |
| Downloads | SABnzbd, qBittorrent+VPN (Gluetun) |
| Management | Portainer, VS Code, Dozzle, WUD, Uptime Kuma, IT-Tools, Glances |
| Requests | Overseerr, Jellyseerr |
| Media Tools | Kometa, Maintainerr, Notifiarr, Tautulli |
| Other | Stirling PDF, and 90+ more optional apps |

---

## Management

```bash
# Apps
./manage.sh add jellyfin            # Add an app
./manage.sh remove jellyfin         # Stop and remove
./manage.sh update                  # Pull latest images and restart all
./manage.sh update radarr           # Update one app
./manage.sh status                  # Running containers + URLs
./manage.sh logs sonarr             # Tail container logs
./manage.sh regen                   # Regenerate compose + Traefik rules from state

# Security
./manage.sh security crowdsec-setup # Generate CrowdSec bouncer API key
./manage.sh security auth           # Change auth layer (TinyAuth / Basic Auth)

# Remote access
./manage.sh tunnel setup            # Set up or switch remote access method
./manage.sh tunnel status           # Show current tunnel config
./manage.sh tunnel cloudflare-proxy # Enable Cloudflare proxy on Pangolin DNS

# Pangolin
./manage.sh pangolin add radarr     # Expose specific app via Pangolin
./manage.sh pangolin remove radarr  # Remove Pangolin exposure
./manage.sh pangolin status         # Show config and exposed apps
```

---

## Project structure

```
portless/
├── install.sh                    # Interactive setup wizard
├── manage.sh                     # Management CLI
├── lib/
│   ├── common.sh                 # Logging, prompts, helpers
│   ├── docker.sh                 # Docker installer
│   ├── mount.sh                  # NFS / SMB / local data directory setup
│   ├── traefik.sh                # Traefik wizard, compose gen, rule generator
│   ├── state.sh                  # State file (JSON via jq)
│   ├── cloudflare.sh             # Cloudflare Tunnel + DNS API
│   ├── pangolin.sh               # Pangolin VPS tunnel
│   ├── tailscale.sh              # Tailscale VPN
│   ├── headscale.sh              # Headscale (self-hosted Tailscale)
│   ├── netbird.sh                # Netbird WireGuard mesh
│   └── apps/                     # Per-app catalog (21 apps)
│       ├── crowdsec.sh
│       ├── tinyauth.sh
│       └── ...
├── compose/hs/                   # Docker Compose service snippets
├── templates/
│   ├── env.template              # .env template
│   ├── traefik/                  # Traefik rule templates
│   │   ├── app-noauth.yml.tmpl
│   │   ├── app-tinyauth.yml.tmpl
│   │   └── app-basic-auth.yml.tmpl
│   ├── pangolin/                 # Pangolin VPS setup scripts
│   ├── headscale/                # Headscale VPS setup
│   └── netbird/                  # Netbird management stack
└── docs/
    ├── getting-started.md
    ├── remote-access.md
    ├── pangolin-guide.md
    ├── adding-apps.md
    └── troubleshooting.md
```

---

## Documentation

- [Getting Started](docs/getting-started.md)
- [Remote Access Guide](docs/remote-access.md) — pick the right method for your situation
- [Pangolin Guide](docs/pangolin-guide.md)
- [Adding Apps](docs/adding-apps.md)
- [Troubleshooting](docs/troubleshooting.md)
- [References & Credits](docs/references.md) — every open source project that powers the stack

---

## Credits

portless builds on a lot of great open source work. See [docs/references.md](docs/references.md) for the full list with links and licenses.

Highlights:
- [Traefik](https://traefik.io/) — reverse proxy
- [TinyAuth](https://github.com/steveiliop56/tinyauth) — self-hosted SSO
- [Pangolin](https://github.com/fosrl/pangolin) — self-hosted tunnel server
- [CrowdSec](https://github.com/crowdsecurity/crowdsec) — community IPS
- [Headscale](https://github.com/juanfont/headscale) — self-hosted Tailscale control plane
- [LinuxServer.io](https://linuxserver.io/) — container images

---

## Support

If portless saves you time, you can support the project here:

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-buymeacoffee.com%2Ftechbutton-yellow?logo=buy-me-a-coffee&logoColor=white)](https://buymeacoffee.com/techbutton)

---

## License

MIT — see [LICENSE](LICENSE) for details.
