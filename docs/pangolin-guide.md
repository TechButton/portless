# Pangolin Tunnel Guide

Pangolin is the self-hosted remote access option in portless. It creates an encrypted WireGuard tunnel between a cheap VPS and your home server — so you can reach every service from anywhere in the world without opening a single port on your router.

## Why Pangolin instead of port forwarding?

| | Port Forwarding | Pangolin |
|---|---|---|
| Works with CGNAT | ✗ | ✓ |
| Works with dynamic IP | Requires DDNS | ✓ |
| Exposes home IP | Yes | No |
| Router changes needed | Yes | No |
| ISP restrictions matter | Yes | No |
| Setup difficulty | Medium | Easy (wizard handles it) |

Many ISPs — especially mobile, cable, and fiber — now use **Carrier-Grade NAT (CGNAT)**, which makes traditional port forwarding impossible. Pangolin works regardless.

## Getting a VPS

You need a small VPS with a public IP to run Pangolin. Any provider works. Minimum specs:

- 1 vCPU
- 512 MB RAM (1 GB recommended)
- Public IP
- A domain or subdomain pointed at it

Popular affordable options: Hetzner, BuyVM, RackNerd, Linode Nanode, Oracle Free Tier (free). Pangolin doesn't need much — even the cheapest tier from any provider is fine.

## Architecture

```
Your phone / laptop
      │
      ▼ HTTPS (port 443)
 ┌────────────────────────────────────┐
 │  Your VPS                          │
 │                                    │
 │  ┌──────────┐   ┌──────────────┐   │
 │  │ Pangolin │   │   Traefik    │   │
 │  │ (tunnel) │   │   (proxy)    │   │
 │  └────┬─────┘   └──────┬───────┘   │
 └───────┼────────────────┼───────────┘
         │ WireGuard      │ routes via tunnel
         ▼
 ┌────────────────────────────────────┐
 │  Your Home Server                  │
 │                                    │
 │  ┌──────┐  ┌──────┐  ┌─────────┐  │
 │  │ Newt │  │Radarr│  │ Sonarr  │  │
 │  │(client) │      │  │         │  │
 │  └──────┘  └──────┘  └─────────┘  │
 │                                    │
 │  No open ports. No exposed IP.     │
 └────────────────────────────────────┘
```

**Newt** (running on your home server) makes an outbound-only WireGuard connection to Pangolin. Your home server never accepts inbound connections from the internet.

## Setup during install

During `./install.sh` Phase 5, choose Pangolin:

```
Remote access method:
  1) Cloudflare Tunnel (free, no VPS, public URLs)
  2) Pangolin on a VPS (~$18/year, self-hosted, public URLs)
  3) Tailscale (free, private VPN, no public URLs)
  4) Headscale (free, self-hosted Tailscale, VPS required)
  5) Netbird (free, WireGuard mesh, cloud or self-hosted)
  6) Skip — LAN only
```

Select **2**, then pick between a fresh install or connecting to an existing Pangolin instance.

**Fresh VPS install:**
- Enter your VPS IP, SSH user, and auth method
- The wizard hardens the VPS (UFW, fail2ban, swap), installs Docker, and deploys Pangolin
- Creates an org, generates Newt credentials, registers all selected apps as tunnel resources

**Existing Pangolin:**
- Enter your VPS host, Pangolin domain, SSH details, org ID, and site ID
- The wizard registers your apps and configures Newt

## Setting up Pangolin after install

```bash
./manage.sh tunnel setup
# or go directly to Pangolin:
./manage.sh pangolin setup
```

## Adding / removing apps

```bash
# Expose a new app via tunnel (automatically called by manage.sh add)
./manage.sh pangolin add radarr

# Remove tunnel access for an app
./manage.sh pangolin remove radarr

# Check what's exposed
./manage.sh pangolin status
```

## DNS configuration

Point your domain at the VPS IP. A wildcard record is simplest:

```
*.example.com  →  A  →  <VPS IP>
```

Or per-service records:
```
movies.example.com  →  A  →  <VPS IP>
tv.example.com      →  A  →  <VPS IP>
plex.example.com    →  A  →  <VPS IP>
```

> **Note:** Cloudflare proxy (orange cloud) should be **disabled** (grey cloud / DNS only) for these records by default. Pangolin handles TLS termination directly. You can enable the proxy later with `./manage.sh tunnel cloudflare-proxy` — but set SSL mode to Full (strict) first.

## Resource authentication (Pangolin SSO)

Pangolin supports a second authentication gate at the VPS level, before traffic reaches Traefik or TinyAuth. This gives you two independent login layers for sensitive apps.

**Recommended for:** Portainer, VS Code, Traefik dashboard
**Leave off for:** Plex, Jellyfin, Overseerr (they need public URL sharing to work with mobile apps)

To enable it:
1. Log into your Pangolin dashboard: `https://pangolin.example.com`
2. Go to your site → **Resources**
3. Click an app → toggle **Enable Authentication**
4. Set type to **Pangolin SSO**

The installer's post-setup guide covers this for the apps that benefit most.

## CrowdSec on the Pangolin VPS

Your VPS is where real public IPs are visible — this is where CrowdSec should run, not on your home server. The portless installer shows step-by-step instructions after Pangolin setup completes.

Quick summary:
1. SSH into your VPS
2. Add CrowdSec + traefik-bouncer to the Pangolin docker compose
3. Generate the bouncer API key: `docker exec crowdsec cscli bouncers add traefik-bouncer`
4. Add the forwardAuth middleware to Pangolin's Traefik dynamic config

Once running:
```bash
# View blocked IPs
docker exec crowdsec cscli decisions list

# View alerts
docker exec crowdsec cscli alerts list

# Install community collections
docker exec crowdsec cscli hub update
docker exec crowdsec cscli collections install crowdsecurity/traefik
```

## Troubleshooting

### Service returns 502 Bad Gateway

1. Check Newt is running: `./manage.sh logs newt`
2. Verify the Pangolin resource exists: `./manage.sh pangolin status`
3. Confirm the internal port in the resource matches the app's actual port
4. Restart Newt: `docker restart newt`

### "Connection refused" from internet but works on LAN

Pangolin is routing but the app isn't reachable through the tunnel.
1. Check the resource's `targetHost` is set to your server's LAN IP
2. Check the resource's `targetPort` matches the app's port
3. Restart Pangolin on the VPS:
   ```bash
   ssh user@vps-ip "cd /opt/pangolin && docker compose restart pangolin"
   ```

### Newt keeps disconnecting

1. Check the Newt ID and secret in your `.env` match what's in the Pangolin dashboard
2. Verify the Pangolin VPS is reachable: `curl https://pangolin.example.com`
3. Check Pangolin logs: `ssh user@vps "docker logs pangolin"`

### TLS certificate errors

Pangolin handles its own TLS via Let's Encrypt. Ensure:
- DNS A record points to the VPS IP (not your home IP)
- Ports 80 and 443 are open on the VPS firewall
- Wait up to 5 minutes after first setup for cert provisioning
