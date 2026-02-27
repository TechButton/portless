# References & Credits

portless is built on the shoulders of some excellent open source projects. This page lists every tool that powers the stack, with links to their source code and documentation.

---

## Core Infrastructure

| Project | Role | License | Links |
|---------|------|---------|-------|
| [Traefik](https://traefik.io) | Reverse proxy — TLS termination, routing, middleware chains | MIT | [GitHub](https://github.com/traefik/traefik) · [Docs](https://doc.traefik.io/traefik/) |
| [Docker](https://www.docker.com) | Container runtime | Apache 2.0 | [GitHub](https://github.com/docker/docker-ce) · [Docs](https://docs.docker.com) |
| [Docker Compose](https://docs.docker.com/compose/) | Multi-container orchestration | Apache 2.0 | [GitHub](https://github.com/docker/compose) · [Docs](https://docs.docker.com/compose/) |
| [LinuxServer.io socket-proxy](https://github.com/linuxserver/docker-socket-proxy) | Docker socket proxy — Traefik never touches the socket directly | GPL v3 | [GitHub](https://github.com/linuxserver/docker-socket-proxy) · [Docs](https://docs.linuxserver.io/images/docker-socket-proxy) |

---

## Security & Authentication

| Project | Role | License | Links |
|---------|------|---------|-------|
| [TinyAuth](https://github.com/steveiliop56/tinyauth) | Self-hosted SSO via Traefik ForwardAuth | MIT | [GitHub](https://github.com/steveiliop56/tinyauth) |
| [CrowdSec](https://www.crowdsec.net) | Community-powered intrusion prevention, blocks malicious IPs at the edge | MIT | [GitHub](https://github.com/crowdsecurity/crowdsec) · [Docs](https://docs.crowdsec.net) |
| [CrowdSec Traefik Bouncer](https://github.com/fbonalair/traefik-crowdsec-bouncer) | Blocks decisions from CrowdSec at the Traefik middleware layer | MIT | [GitHub](https://github.com/fbonalair/traefik-crowdsec-bouncer) |

---

## Remote Access

| Project | Role | License | Links |
|---------|------|---------|-------|
| [Cloudflare Tunnel (cloudflared)](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) | Zero-trust tunnel — no open ports, free tier | Apache 2.0 | [GitHub](https://github.com/cloudflare/cloudflared) · [Docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) |
| [Pangolin](https://pangolin.hq.fosrl.dev) | Self-hosted tunnel server with WireGuard backend and resource authentication | AGPL v3 | [GitHub](https://github.com/fosrl/pangolin) · [Docs](https://docs.pangolin.hq.fosrl.dev) |
| [Newt](https://github.com/fosrl/newt) | WireGuard tunnel client — runs on your home server, connects to Pangolin | AGPL v3 | [GitHub](https://github.com/fosrl/newt) |
| [Gerbil](https://github.com/fosrl/gerbil) | WireGuard gateway — runs on the Pangolin VPS | AGPL v3 | [GitHub](https://github.com/fosrl/gerbil) |
| [Tailscale](https://tailscale.com) | WireGuard mesh VPN with managed coordination server | BSD 3-Clause | [GitHub](https://github.com/tailscale/tailscale) · [Docs](https://tailscale.com/kb) |
| [Headscale](https://headscale.net) | Self-hosted Tailscale coordination server | BSD 3-Clause | [GitHub](https://github.com/juanfont/headscale) · [Docs](https://headscale.net/docs/overview/) |
| [headscale-ui](https://github.com/gurucomputing/headscale-ui) | Web UI for Headscale | MIT | [GitHub](https://github.com/gurucomputing/headscale-ui) |
| [Netbird](https://netbird.io) | WireGuard mesh — peers connect directly, cloud or self-hosted | BSD 3-Clause | [GitHub](https://github.com/netbirdio/netbird) · [Docs](https://docs.netbird.io) |
| [Caddy](https://caddyserver.com) | TLS-terminating reverse proxy used with Headscale setup | Apache 2.0 | [GitHub](https://github.com/caddyserver/caddy) · [Docs](https://caddyserver.com/docs/) |

---

## Media

| Project | Role | License | Links |
|---------|------|---------|-------|
| [Plex](https://www.plex.tv) | Media server | Proprietary (free tier) | [Docs](https://support.plex.tv/articles/) |
| [Jellyfin](https://jellyfin.org) | Open source media server | GPL v2 | [GitHub](https://github.com/jellyfin/jellyfin) · [Docs](https://jellyfin.org/docs/) |
| [Radarr](https://radarr.video) | Movie collection manager | GPL v3 | [GitHub](https://github.com/Radarr/Radarr) · [Docs](https://wiki.servarr.com/radarr) |
| [Sonarr](https://sonarr.tv) | TV series collection manager | GPL v3 | [GitHub](https://github.com/Sonarr/Sonarr) · [Docs](https://wiki.servarr.com/sonarr) |
| [Lidarr](https://lidarr.audio) | Music collection manager | GPL v3 | [GitHub](https://github.com/Lidarr/Lidarr) · [Docs](https://wiki.servarr.com/lidarr) |
| [Bazarr](https://www.bazarr.media) | Subtitle manager for Radarr/Sonarr | GPL v3 | [GitHub](https://github.com/morpheus65535/bazarr) · [Docs](https://wiki.bazarr.media) |
| [Prowlarr](https://wiki.servarr.com/prowlarr) | Indexer manager for the \*arr stack | GPL v3 | [GitHub](https://github.com/Prowlarr/Prowlarr) · [Docs](https://wiki.servarr.com/prowlarr) |
| [Overseerr](https://overseerr.dev) | Media request management for Plex | MIT | [GitHub](https://github.com/sct/overseerr) · [Docs](https://docs.overseerr.dev) |
| [Maintainerr](https://github.com/jorenn92/maintainerr) | Plex library cleanup rules | MIT | [GitHub](https://github.com/jorenn92/maintainerr) |
| [Kometa](https://kometa.wiki) | Plex metadata manager (formerly Plex Meta Manager) | GPL v3 | [GitHub](https://github.com/Kometa-Team/Kometa) · [Docs](https://kometa.wiki) |

---

## Downloads

| Project | Role | License | Links |
|---------|------|---------|-------|
| [qBittorrent (linuxserver)](https://github.com/linuxserver/docker-qbittorrent) | BitTorrent client | GPL v2 | [GitHub](https://github.com/qbittorrent/qBittorrent) · [Docs](https://github.com/linuxserver/docker-qbittorrent) |
| [SABnzbd (linuxserver)](https://sabnzbd.org) | Usenet downloader | GPL v2 | [GitHub](https://github.com/sabnzbd/sabnzbd) · [Docs](https://sabnzbd.org/wiki/) |
| [Gluetun](https://github.com/qdm12/gluetun) | VPN client container — routes qBittorrent traffic through a VPN | MIT | [GitHub](https://github.com/qdm12/gluetun) · [Docs](https://github.com/qdm12/gluetun/wiki) |

---

## Management & Monitoring

| Project | Role | License | Links |
|---------|------|---------|-------|
| [Portainer CE](https://www.portainer.io) | Docker container management UI | zlib | [GitHub](https://github.com/portainer/portainer) · [Docs](https://docs.portainer.io) |
| [Dozzle](https://dozzle.dev) | Real-time Docker log viewer | MIT | [GitHub](https://github.com/amir20/dozzle) · [Docs](https://dozzle.dev/guide/what-is-dozzle) |
| [Uptime Kuma](https://uptime.kuma.pet) | Self-hosted uptime monitoring | MIT | [GitHub](https://github.com/louislam/uptime-kuma) · [Docs](https://github.com/louislam/uptime-kuma/wiki) |
| [What's Up Docker (WUD)](https://fmartinou.github.io/whats-up-docker/) | Container image update notifications | MIT | [GitHub](https://github.com/fmartinou/whats-up-docker) · [Docs](https://fmartinou.github.io/whats-up-docker/) |
| [Glances](https://nicolargo.github.io/glances/) | System resource monitor | GPL v3 | [GitHub](https://github.com/nicolargo/glances) · [Docs](https://glances.readthedocs.io) |
| [Notifiarr](https://notifiarr.com) | Unified notification hub for the \*arr stack | MIT | [GitHub](https://github.com/Notifiarr/notifiarr) · [Docs](https://notifiarr.wiki) |
| [deunhealth](https://github.com/qdm12/deunhealth) | Restarts unhealthy containers automatically | MIT | [GitHub](https://github.com/qdm12/deunhealth) |
| [docker-gc](https://github.com/clockworksoul/docker-gc-cron) | Scheduled Docker image/container garbage collection | Apache 2.0 | [GitHub](https://github.com/clockworksoul/docker-gc-cron) |

---

## Utilities & Tools

| Project | Role | License | Links |
|---------|------|---------|-------|
| [code-server](https://coder.com/docs/code-server) | VS Code in the browser | MIT | [GitHub](https://github.com/coder/code-server) · [Docs](https://coder.com/docs/code-server) |
| [IT Tools](https://it-tools.tech) | Collection of online utilities for developers | MIT | [GitHub](https://github.com/CorentinTh/it-tools) |
| [Stirling PDF](https://stirlingtools.com) | Self-hosted PDF manipulation toolkit | MIT | [GitHub](https://github.com/Stirling-Tools/Stirling-PDF) |

---

## LinuxServer.io

Many of the app images used by portless are maintained by the [LinuxServer.io](https://www.linuxserver.io) team. They provide consistently structured, regularly updated images with support for `PUID`/`PGID` for clean permission management. Their work is central to the stability of this project.

- Website: [linuxserver.io](https://www.linuxserver.io)
- GitHub: [github.com/linuxserver](https://github.com/linuxserver)
- Docs: [docs.linuxserver.io](https://docs.linuxserver.io)

---

*If we've missed crediting a project, please [open an issue](https://github.com/techbutton/portless/issues).*
