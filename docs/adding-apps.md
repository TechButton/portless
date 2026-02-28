# Adding Apps to the portless Catalog

Want to add a new app that isn't in the default catalog? This guide explains how.

## Step 1: Create the App Catalog File

Create `lib/apps/<appname>.sh`:

```bash
#!/usr/bin/env bash
# App catalog: MyApp
APP_NAME="myapp"
APP_DESCRIPTION="What this app does"
APP_CATEGORY="management"   # core | media | arr | downloads | management | requests | other
APP_PORT_VAR="MYAPP_PORT"
APP_DEFAULT_HOST_PORT="8123"
APP_SERVICE_PORT="8123"
APP_DEFAULT_SUBDOMAIN="myapp"
APP_AUTH="tinyauth"         # tinyauth | none | basic
APP_PROFILES="management,all"
APP_IMAGE="vendor/myapp:latest"
APP_COMPOSE_FILE="compose/{HOSTNAME}/myapp.yml"
APP_APPDATA_DIR="appdata/myapp"
APP_REQUIRES_VOLUMES="appdata"
```

### Field Reference

| Field | Description | Example |
|-------|-------------|---------|
| `APP_NAME` | Lowercase slug, matches filename | `radarr` |
| `APP_DESCRIPTION` | One-line description for the wizard | `Movie manager` |
| `APP_CATEGORY` | Category group for wizard display | `arr` |
| `APP_PORT_VAR` | Variable name in .env | `RADARR_PORT` |
| `APP_DEFAULT_HOST_PORT` | Default host port | `7878` |
| `APP_SERVICE_PORT` | Internal container port | `7878` |
| `APP_DEFAULT_SUBDOMAIN` | Default subdomain prefix | `movies` |
| `APP_AUTH` | Auth middleware to use | `tinyauth` |
| `APP_PROFILES` | Comma-separated Docker Compose profiles | `arr,all` |
| `APP_IMAGE` | Docker image | `lscr.io/linuxserver/radarr:latest` |
| `APP_APPDATA_DIR` | Config dir relative to DOCKERDIR | `appdata/radarr` |

### Auth Types

- `tinyauth` — Protected by TinyAuth SSO (chain-tinyauth middleware) — recommended
- `none` — No auth middleware (app has its own login, e.g. Plex, Portainer, Jellyfin)
- `basic` — HTTP basic auth via Traefik (chain-basic-auth middleware)

## Step 2: Create the Compose Snippet

Create `compose/<hostname>/<appname>.yml` (or `compose/<appname>.yml` for any hostname):

```yaml
  ########## MYAPP ##########
  myapp:
    image: vendor/myapp:latest
    container_name: myapp
    restart: unless-stopped
    networks:
      - default
    security_opt:
      - no-new-privileges:true
    volumes:
      - ${DOCKERDIR}/appdata/myapp:/config
      - /etc/localtime:/etc/localtime:ro
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    ports:
      - "${MYAPP_PORT}:8123"
    labels:
      - "traefik.enable=true"
```

**Important:** The compose snippet should NOT include the `services:` header — it's just the service block. The portless `manage.sh add` command appends it to your main compose file.

### Using media directories

The `.env` exposes named variables for each media type. Use these in your compose snippet instead of hardcoded paths:

| Variable | Default path | Use for |
|---|---|---|
| `$MOVIES_DIR` | `$DATADIR/movies` | Movie libraries (Radarr, Plex, Jellyfin) |
| `$TV_DIR` | `$DATADIR/tv` | TV libraries (Sonarr, Plex, Jellyfin) |
| `$MUSIC_DIR` | `$DATADIR/music` | Music libraries (Lidarr, Navidrome) |
| `$BOOKS_DIR` | `$DATADIR/books` | E-books (Calibre-Web, Kavita) |
| `$AUDIOBOOKS_DIR` | `$DATADIR/audiobooks` | Audiobooks (Audiobookshelf) |
| `$COMICS_DIR` | `$DATADIR/comics` | Comics & manga (Komga, Mylar3, Kavita) |
| `$DOWNLOADSDIR` | `$DATADIR/downloads` | Download clients (SABnzbd, qBittorrent) |
| `$DATADIR` | `/mnt/data` | Root data directory (VS Code, general access) |

Example — a music streaming app:
```yaml
    volumes:
      - ${DOCKERDIR}/appdata/myapp:/config
      - $MUSIC_DIR:/music:ro
      - /etc/localtime:/etc/localtime:ro
```

Example — a media server that needs everything:
```yaml
    volumes:
      - ${DOCKERDIR}/appdata/myapp:/config
      - $MOVIES_DIR:/data/movies
      - $TV_DIR:/data/tv
      - $MUSIC_DIR:/data/music
      - $DOWNLOADSDIR:/data/downloads
```

## Step 3: Add to .env Template (Optional)

If you want the port to appear in the .env template, add it to `templates/env.template`:

```bash
# Management
MYAPP_PORT=8123
```

If your app generates an API key that other services need, add a placeholder in the **App API Keys** section of `templates/env.template`:

```bash
# ── App API Keys ──────────────────────────────────────────────────────────────
MYAPP_API_KEY=CHANGE_ME
```

If your app supports setting its own API key via environment variable (the LinuxServer `APP__Auth__ApiKey` pattern), wire it in the compose snippet:

```yaml
    environment:
      TZ: $TZ
      PUID: $PUID
      PGID: $PGID
      MYAPP__Auth__ApiKey: $MYAPP_API_KEY
```

This lets you choose the API key value before first launch, making it predictable for integrations.

## Step 4: Test It

```bash
./manage.sh add myapp
```

The wizard will:
1. Load your catalog file
2. Ask for subdomain and port confirmation
3. Add the service to your compose file
4. Generate a Traefik rule
5. Optionally expose via Pangolin
6. Start the container

## Best Practices

### Linuxserver.io Images

Most apps should use `lscr.io/linuxserver/<app>:latest` — these images:
- Support `PUID`/`PGID` env vars for permission management
- Use `/config` as the config directory consistently
- Are regularly updated and well-documented

### Security

Always include:
```yaml
security_opt:
  - no-new-privileges:true
```

For apps that need Docker socket access (like Portainer, Dozzle):
```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock:ro
# Or better — connect to socket-proxy:
networks:
  - socket_proxy
```

### Multiple Ports

If your app exposes multiple ports:
```yaml
ports:
  - "${MYAPP_PORT}:8123"
  - "${MYAPP_EXTRA_PORT}:9123"
```

Add both to your `.env` template and catalog file.

## Contributing

If you've added an app that would be useful to others, please submit a pull request! Include:
- `lib/apps/<appname>.sh`
- `compose/<appname>.yml` (generic, no hostname-specific paths)
- A brief description in your PR
