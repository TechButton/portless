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
2. **Basic config** — hostname, Linux user, timezone (auto-detected), Docker directory
3. **Domain & network** — your domain, Cloudflare API token, server LAN IP, Traefik access mode (local vs hybrid), authentication layer (TinyAuth / Basic Auth / None)
4. **App selection** — pick what to run from a categorized checklist
5. **Remote access** — choose how to reach services from outside your home network
6. **Generate & deploy** — writes your `.env`, middleware chain files, and `docker-compose-<hostname>.yml`, runs a staging cert test, then starts everything

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
│   └── tinyauth_secret
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
