# Remote Access Guide

There's no universally right answer. Pick based on what you need and what you already have.

## Quick comparison

| | Cloudflare Tunnel | Pangolin | Tailscale | Headscale | Netbird |
|--|--|--|--|--|--|
| **Cost** | Free | ~$18/yr VPS | Free | ~$18/yr VPS | Free |
| **VPS required** | No | Yes | No | Yes | No (cloud) |
| **Public URLs** | Yes | Yes | No | No | No |
| **Your own domain** | Needed | Needed | Not needed | Not needed | Not needed |
| **Fully self-hosted** | No | Yes | No | Yes | Optional |
| **Works with CGNAT** | Yes | Yes | Yes | Yes | Yes |
| **Setup time** | ~5 min | ~15 min | ~3 min | ~20 min | ~3 min |
| **Edge protection** | Cloudflare WAF | CrowdSec on VPS | N/A | N/A | N/A |

## The methods

### Cloudflare Tunnel

Traffic goes: browser → Cloudflare's network → cloudflared container on your server → app.

You get public HTTPS URLs (`movies.example.com`) that work from any browser. Cloudflare handles DDoS mitigation and bot filtering at the edge — free. The cloudflared container makes an outbound connection to Cloudflare, so no ports need to be open.

**What you need:**
- Domain managed by Cloudflare (free)
- Cloudflare API token with Zone:DNS:Edit permission

**What the installer does:**
- Creates a tunnel via the Cloudflare API
- Configures a wildcard ingress rule (`*.yourdomain.com → Traefik`)
- Adds the cloudflared container to your compose
- Creates the DNS CNAME automatically

**Limitations:**
- Cloudflare can see your traffic (it terminates TLS at their edge)
- Free plan has some rate limits for very high traffic
- You're dependent on Cloudflare's service

**CrowdSec:** Not recommended — Cloudflare's WAF already handles edge protection. Home server only sees Cloudflare's IPs anyway.

---

### Pangolin

Pangolin is a self-hosted tunnel server. It runs on a VPS you control, using WireGuard for the encrypted tunnel between the VPS and your home server.

Traffic goes: browser → your VPS (Pangolin + Traefik) → WireGuard tunnel → Newt on your server → app.

You get public HTTPS URLs, Let's Encrypt certs managed on the VPS, and nothing touches Cloudflare. Your VPS IP goes in DNS — your home IP is never exposed.

**What you need:**
- A VPS with a public IP (~$18/year, any provider — 1 vCPU / 512 MB RAM is enough)
- A domain (e.g. `pangolin.example.com` pointed at the VPS)
- SSH access to the VPS

**What the installer does:**
- Hardens the VPS (UFW, fail2ban, swap)
- Installs Docker and deploys Pangolin via docker compose
- Creates an org, site, and Newt credentials via the Pangolin API
- Adds the Newt container to your local compose
- Registers each of your apps as a Pangolin resource
- Shows you how to add CrowdSec to the VPS after install

**CrowdSec:** Install on the **VPS**, not your home server. The VPS sees real public IPs and can block at the edge. The installer walks you through this after Pangolin is set up.

**Optional: Cloudflare proxy on top of Pangolin**

Put Cloudflare's proxy (orange cloud) in front of Pangolin for DDoS protection and CDN caching with no changes to Pangolin itself. Set SSL mode to "Full (strict)" in Cloudflare.

```bash
./manage.sh tunnel cloudflare-proxy
```

This flips your existing DNS records to proxied. Then set SSL/TLS → Full (strict) in your Cloudflare dashboard.

---

### Tailscale

Tailscale creates a WireGuard mesh between devices. Your home server becomes a node in your Tailscale network. Other enrolled devices can reach it directly.

You won't get `movies.example.com` — instead, services are accessible at your server's Tailscale IP (like `100.64.x.x`) or via MagicDNS (`homeserver`). Works well for personal access when you control all the devices.

**What you need:**
- Free account at [tailscale.com](https://tailscale.com)
- An auth key from the admin console
- Tailscale installed on devices you want to connect from

**What the installer does:**
- Adds the tailscale container to your compose
- Configures subnet routing for your Docker networks

After deployment, approve the advertised subnet routes in the Tailscale admin console once: Machines → your server → Edit route settings.

**Tailscale Funnel** (public URLs):
Funnel can expose specific ports as public HTTPS URLs but requires per-service setup — more manual than Cloudflare Tunnel. Not configured automatically by portless.

**CrowdSec:** Not applicable — private VPN only, no public exposure.

---

### Headscale

Headscale is a drop-in replacement for the Tailscale coordination server. Your devices still use the Tailscale client, but authenticate against your VPS instead of tailscale.com. No Tailscale account needed.

Works exactly like Tailscale from the user perspective — same WireGuard mesh, same MagicDNS — but everything runs on infrastructure you own.

**What you need:**
- A VPS (~$18/year, 1 vCPU / 512 MB RAM)
- A subdomain for Headscale (e.g. `headscale.example.com`)
- SSH access to the VPS

**What the installer does:**
- Deploys Headscale + Caddy (for TLS) + headscale-ui on your VPS
- Creates a user/namespace
- Generates a pre-auth key
- Adds the Tailscale client container to your compose, pointed at your Headscale server

**Enrolling additional devices:**

```bash
# On each device, install Tailscale and run:
tailscale up --login-server=https://headscale.example.com --auth-key=<key>

# Generate a new key anytime:
./manage.sh tunnel headscale new-key

# List connected devices:
./manage.sh tunnel headscale nodes
```

**Note:** Headscale doesn't support Tailscale Funnel — that requires Tailscale's infrastructure. For public URLs, use Pangolin or Cloudflare Tunnel instead.

**CrowdSec:** Not applicable — private VPN only, no public exposure.

---

### Netbird

Netbird builds a direct WireGuard mesh between peers. After the initial handshake via the management server, peers connect directly — traffic doesn't route through any central relay unless both sides are behind symmetric NAT.

**Cloud (recommended to start):** Sign up at [app.netbird.io](https://app.netbird.io), create a setup key, paste it into the installer. Management server hosted by Netbird, free for unlimited peers.

**Self-hosted:** Deploy the full Netbird management stack (management + signal + relay + coturn + nginx) on a VPS. The installer handles this automatically if you choose it.

**What you need (cloud):**
- Free account at [app.netbird.io](https://app.netbird.io)
- A setup key (Reusable type, from the Setup Keys section)

**What the installer does:**
- Adds the netbird container to your compose
- Configures it with your setup key and management URL

**CrowdSec:** Not applicable — private VPN only, no public exposure.

---

## Switching methods later

```bash
./manage.sh tunnel setup
```

Runs the full wizard again. Previous config is kept in state but overwritten when you complete the new setup.

## Mixing methods

You can't run two proxy methods simultaneously, but you can switch freely. One practical combination: Pangolin for public URL access, plus Tailscale for direct SSH and management access — but you'd manage the Tailscale piece outside of portless.
