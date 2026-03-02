# Migrating to a New Server

This guide covers moving a Portless homelab stack from an old server to a new one — transferring app configs, secrets, and optionally media.

## What needs to move

| What | Where | Notes |
|---|---|---|
| App config (databases, settings) | `~/docker/appdata/` | The most important thing to transfer |
| Environment file | `~/docker/.env` | All your ports, API keys, paths |
| Secrets | `~/docker/secrets/` | Cloudflare token, auth credentials |
| State file | `~/docker/.portless-state.json` | Lets Portless know what's installed |
| Media files | `/mnt/data/` or NAS | Skip if already on a NAS — just remount |

---

## Before you start

**On the old server — stop all containers** before transferring. Copying a live database risks corruption.

```bash
# On old server
cd ~/docker
docker compose -f docker-compose-$(hostname).yml down
```

---

## Step 1 — Run Portless on the new server first

Install and configure Portless on the new server through Phase 6 (deploy) before transferring any data. This generates a clean `.env`, creates all the `appdata/` subdirectories, and starts the containers once so every app initialises its database structure.

```bash
git clone https://github.com/techbutton/portless.git
cd portless
./install.sh
```

Then stop everything again before copying old data over it:

```bash
docker compose -f ~/docker/docker-compose-$(hostname).yml down
```

---

## Step 2 — Transfer appdata

Use `rsync` over SSH. This is resumable if the connection drops, skips unchanged files on re-runs, and preserves permissions.

```bash
# Run from the OLD server — push appdata to the new one
rsync -avz --progress \
  ~/docker/appdata/ \
  newuser@new-server-ip:~/docker/appdata/
```

Or pull from the new server:

```bash
# Run from the NEW server — pull from the old one
rsync -avz --progress \
  olduser@old-server-ip:~/docker/appdata/ \
  ~/docker/appdata/
```

### App-specific notes

**Plex** — The metadata/database lives in `appdata/plex`. It can be very large (10–50 GB if you have a big library). Transfer it or let Plex re-scan — rescanning loses watch history and custom artwork. If you want to keep history, transfer it:

```bash
rsync -avz --progress \
  olduser@old-server-ip:~/docker/appdata/plex/ \
  ~/docker/appdata/plex/
```

**Sonarr / Radarr / Lidarr** — Transfer the database or your series/movie/artist list will be empty. Watch history, custom quality profiles, and indexer config all live here.

**SABnzbd / qBittorrent** — If you have active downloads in progress, transfer these too. Otherwise you can skip and reconfigure from scratch.

**TinyAuth** — `appdata/tinyauth/users_file` holds all your user accounts. Transfer it to keep existing logins.

---

## Step 3 — Transfer secrets and .env

```bash
# From the old server
rsync -avz \
  ~/docker/.env \
  ~/docker/secrets/ \
  ~/docker/.portless-state.json \
  newuser@new-server-ip:~/docker/
```

After transfer, open `.env` on the new server and update any values that changed:

```bash
nano ~/docker/.env
```

Things to check:
- `SERVER_LAN_IP` — update to the new server's LAN IP
- `DOCKERDIR` — update if the path differs
- `DATADIR` / `MOVIES_DIR` / `TV_DIR` etc. — update if mount points differ

---

## Step 4 — Transfer media (if not on a NAS)

If your media lives on a NAS (NFS/SMB), skip this — just remount the shares on the new server the same way you did during install, or re-run the installer and choose "Mount NFS/SMB" when prompted.

If media is on local disk:

```bash
# This can take hours for large libraries — run it in a tmux/screen session
rsync -avz --progress \
  /mnt/data/ \
  newuser@new-server-ip:/mnt/data/
```

For very large transfers (multi-TB), a physical drive swap or local network copy is faster than SSH.

---

## Step 5 — Start the stack on the new server

```bash
cd ~/docker
docker compose -f docker-compose-$(hostname).yml up -d
```

Check that containers came up:

```bash
docker ps
```

---

## Step 6 — Update app integrations

After migration, apps that talk to each other need their URLs updated to the new server's address. Log into each app's settings and update:

| App | What to update |
|---|---|
| Sonarr / Radarr / Lidarr | Settings → Download Clients (SABnzbd/qBittorrent URL) |
| Prowlarr | Settings → Apps (Sonarr/Radarr URL + API key) |
| Seerr / Arrmate | Settings → point to Sonarr/Radarr on new IP |
| Tautulli | Settings → Plex Media Server URL |
| Notifiarr | Update server URLs |

If you kept the same hostname and domain, most HTTPS-based integrations will continue working without changes.

---

## Useful rsync flags

| Flag | What it does |
|---|---|
| `-a` | Archive mode — preserves permissions, timestamps, symlinks |
| `-v` | Verbose — shows files as they transfer |
| `-z` | Compress during transfer (saves bandwidth, slower on fast LAN) |
| `--progress` | Per-file progress bar |
| `--exclude` | Skip paths: `--exclude 'plex/Library/Application Support/Plex Media Server/Cache'` |
| `-n` | Dry run — shows what would be transferred without doing it |
| `--delete` | Delete files on destination that no longer exist on source |

### Skip Plex cache (saves time, it's regenerated automatically)

```bash
rsync -avz --progress \
  --exclude 'plex/Library/Application Support/Plex Media Server/Cache/' \
  --exclude 'plex/Library/Application Support/Plex Media Server/Codecs/' \
  ~/docker/appdata/ \
  newuser@new-server-ip:~/docker/appdata/
```

---

## Troubleshooting

**Container starts but app is empty / asks for first-time setup**
The appdata transfer likely didn't complete or went to the wrong path. Check that the directory names match exactly between old and new servers.

**Permission denied errors in container logs**
Ownership mismatch after rsync. Fix with:
```bash
sudo chown -R $USER:$USER ~/docker/appdata/
```

**Plex doesn't see the library after migration**
Plex binds its database to the server's hostname and sometimes the machine ID. If you changed the hostname, go to Plex Settings → Troubleshooting → Clean Bundles + Empty Trash, then let it re-scan. Watch history may be lost.

**Traefik certificate errors after moving**
`acme.json` transfers fine — certs are tied to the domain, not the server. If you see errors, check that `acme.json` has `chmod 600` permissions:
```bash
chmod 600 ~/docker/appdata/traefik3/acme/acme.json
```
