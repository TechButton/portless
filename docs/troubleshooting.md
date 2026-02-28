# Troubleshooting — portless

## Installation Issues

### "Permission denied" creating the media directory

The installer tries to create the subdirectory structure under your chosen data directory (e.g. `/mnt/data`). If you see:

```
mkdir: cannot create directory '/mnt/data': Permission denied
[ERROR] Failed to create directory: /mnt/data/media/movies
```

This happens because `/mnt` is root-owned. The installer now detects this and offers options — but if you bypassed the prompt or are re-running, you can fix it manually:

```bash
# Option 1 — local disk
sudo mkdir -p /mnt/data
sudo chown $(whoami):$(whoami) /mnt/data

# Option 2 — NFS (example)
sudo apt install nfs-common
sudo mkdir -p /mnt/data
sudo mount -t nfs -o nfsvers=4 192.168.1.10:/tank/media /mnt/data
# Add to /etc/fstab for persistence (see NFS section below)

# Option 3 — SMB/CIFS (example)
sudo apt install cifs-utils
sudo mkdir -p /mnt/data
sudo mount -t cifs //192.168.1.10/media /mnt/data \
  -o credentials=/home/kyle/docker/secrets/.smb_credentials,uid=$(id -u),gid=$(id -g)
```

Then re-run `./install.sh` — it will detect the directory is now accessible and continue.

### NFS mount fails during install

```
NFS mount failed. Verify the server address, export path, and that this host is allowed.
```

Check that:
1. The NFS server is reachable: `ping <server-ip>`
2. The export is published: `showmount -e <server-ip>` (install `nfs-common` first)
3. The server's `/etc/exports` includes your host's IP or subnet
4. The NFS version matches — try version 3 if version 4 fails

```bash
# Test manually
sudo mount -t nfs -o nfsvers=3 192.168.1.10:/tank/media /mnt/data
```

### SMB mount fails during install

```
SMB mount failed. Verify the server address, share name, and credentials.
```

Check that:
1. The server is reachable: `ping <server-ip>`
2. The share name is correct — Windows shares are case-sensitive
3. The user has read/write access to the share
4. `cifs-utils` is installed: `sudo apt install cifs-utils`

```bash
# Test manually
sudo mount -t cifs //192.168.1.10/media /mnt/data \
  -o username=youruser,password=yourpass,uid=$(id -u),gid=$(id -g)
```

### NFS/SMB share not mounting on reboot

If the share was mounted manually but isn't persisting, check `/etc/fstab`. The installer adds the entry automatically, but if it was skipped:

```bash
# NFS entry
192.168.1.10:/tank/media /mnt/data nfs nfsvers=4,defaults,_netdev,nofail 0 0

# SMB entry
//192.168.1.10/media /mnt/data cifs credentials=/home/kyle/docker/secrets/.smb_credentials,uid=1000,gid=1000,iocharset=utf8,_netdev,nofail 0 0
```

The `_netdev` flag tells systemd to wait for the network before mounting. The `nofail` flag allows the system to boot normally if the mount fails (e.g. NAS is offline). **Both are recommended for homelab NAS mounts.**

Test that fstab is correct without rebooting:
```bash
sudo mount -a
```

### "Docker group changes — please re-login"

After the installer adds you to the `docker` group, you must log out and back in. Then re-run `./install.sh`. The installer detects you're already configured and skips to where it left off.

```bash
# Force re-login via newgrp (temporary fix for current session)
newgrp docker
# Then re-run
./install.sh
```

### "jq: command not found"

```bash
sudo apt install jq        # Ubuntu/Debian
sudo pacman -S jq          # Arch
sudo dnf install jq        # Fedora/RHEL
```

### Cloudflare token validation fails

- The wizard will ask if you want to continue anyway — say yes
- Double-check your token at https://dash.cloudflare.com/profile/api-tokens
- Ensure the token has `Zone:DNS:Edit` permission

## Traefik Issues

### Services showing "Bad Gateway" (502)

1. Check the app container is running: `./manage.sh status`
2. Verify the SERVER_IP in your .env matches your actual LAN IP
3. Check the Traefik rule file for the app:
   ```bash
   cat ~/docker/appdata/traefik3/rules/$(hostname)/app-radarr.yml
   ```
4. Verify the port in the rule matches the running container:
   ```bash
   docker ps | grep radarr
   ```

### "Certificate not found" or TLS errors

1. Check acme.json exists and has correct permissions:
   ```bash
   ls -la ~/docker/appdata/traefik3/acme/acme.json
   # Should be -rw------- (600)
   ```
2. Check Traefik logs:
   ```bash
   ./manage.sh logs traefik
   ```
3. Verify Cloudflare DNS is propagated:
   ```bash
   dig @1.1.1.1 radarr.example.com
   ```

### "middlewares-tinyauth not found" error in Traefik logs

The TinyAuth middleware config is missing. Regenerate chain files:
```bash
./manage.sh regen
```

Then check the rules directory:
```bash
ls ~/docker/appdata/traefik3/rules/$(hostname)/
# Should include: chain-tinyauth.yml, middlewares-tinyauth.yml
```

### Redirect loop on TinyAuth-protected services

This usually means the `APP_URL` in TinyAuth doesn't match your domain, or TinyAuth isn't running:
```bash
./manage.sh status
./manage.sh logs tinyauth
```

The URL in `services.*.loadBalancer.servers` should use `http://` (backend). TLS termination happens at Traefik's entrypoint.

## TinyAuth Issues

### "401 Unauthorized" on every request

TinyAuth's `users_file` may be empty or malformed. Check:
```bash
cat ~/docker/appdata/tinyauth/users_file
# Format: email:$2y$...bcrypt_hash
```

Regenerate a password hash:
```bash
htpasswd -nbB "" "yourpassword" | cut -d: -f2
```

### "Cannot connect to auth server"

The TinyAuth container needs to be on the `t3_proxy` network. Check:
```bash
docker inspect tinyauth | jq '.[].NetworkSettings.Networks'
```

If missing from `t3_proxy`, restart the stack:
```bash
docker compose -f ~/docker/docker-compose-$(hostname).yml up -d tinyauth
```

## App Issues

### App container keeps restarting

```bash
# Check logs
./manage.sh logs <app>

# Common causes:
# 1. Wrong PUID/PGID — check ~/docker/appdata/<app>/ ownership
# 2. Missing required env var — check docker inspect <app>
# 3. Port conflict — check if port is already in use
```

### Port conflict

```bash
# See what's using a port
ss -tlnp | grep :7878

# Change the app's port in state
# Then regen and restart
./manage.sh regen
docker compose -f ~/docker/docker-compose-$(hostname).yml up -d <app>
```

### "Permission denied" on appdata directories

```bash
# Fix ownership
sudo chown -R $(id -u):$(id -g) ~/docker/appdata/<app>
```

## Pangolin Issues

See the dedicated [Pangolin Guide](pangolin-guide.md#troubleshooting).

## Tailscale Issues

### Container starts but can't connect

Check the container logs first:
```bash
./manage.sh logs tailscale
# or
docker logs tailscale
```

Common causes:
- Auth key is expired — generate a new one at `login.tailscale.com/admin/settings/keys` and update `TAILSCALE_AUTH_KEY` in your `.env`
- `/dev/net/tun` doesn't exist on the host — this usually means the kernel module isn't loaded: `sudo modprobe tun`
- The container needs `NET_ADMIN` capability — check your compose snippet hasn't been stripped of `cap_add`

### Subnet routes not working

After starting the Tailscale container, the advertised routes need approval once in the admin console. Go to `login.tailscale.com/admin/machines`, click your server, then "Edit route settings" and enable the routes.

To check what's advertised:
```bash
docker exec tailscale tailscale status
```

### Tailscale IP keeps changing

This is normal if you're using ephemeral keys. Use a reusable, non-expiring auth key, or persist the Tailscale state directory (`${DOCKERDIR}/appdata/tailscale`). The compose snippet already does this.

## Headscale Issues

### Can't generate pre-auth key

The Headscale container needs to be running and healthy on the VPS:
```bash
ssh user@vps "docker ps | grep headscale"
ssh user@vps "docker logs headscale --tail 50"
```

If Headscale started but the API isn't responding, it may still be doing initial setup. Wait 30 seconds and retry.

### Tailscale client says "Login expired" or won't connect

The pre-auth key is valid for 30 days by default. Generate a new one:
```bash
./manage.sh tunnel headscale new-key
```

Then update your compose env and restart the container:
```bash
# Edit TAILSCALE_AUTH_KEY in ~/docker/.env
docker compose -f ~/docker/docker-compose-$(hostname).yml up -d tailscale
```

### Client shows as connected but can't reach services

Check that subnet routing is enabled and the routes are registered in Headscale:
```bash
./manage.sh tunnel headscale nodes
```

The node should show routes like `192.168.90.0/24` as enabled. If they show as pending, approve them:
```bash
ssh user@vps "docker exec headscale headscale routes list"
ssh user@vps "docker exec headscale headscale routes enable -r <route-id>"
```

## Netbird Issues

### Container starts but shows as disconnected

```bash
docker exec netbird netbird status
```

If it shows "Management connection: Disconnected", the management URL may be wrong. Check:
```bash
grep NETBIRD /root/docker/.env    # or wherever your .env lives
```

For Netbird Cloud the URL should be `https://api.wire.netbird.io`. For self-hosted it's `https://your-netbird-domain.com`.

### Setup key invalid

Setup keys in Netbird expire if you set an expiry date, or can be used up if created as "one-time". Generate a new reusable key in the Netbird dashboard (or admin UI for self-hosted) and update `NETBIRD_SETUP_KEY` in your `.env`.

### Self-hosted: management UI not accessible

The nginx + certbot setup needs a few minutes to get TLS certs on first run. Check certbot:
```bash
ssh user@vps "docker logs certbot"
ssh user@vps "docker logs netbird-nginx"
```

Port 80 needs to be open for the ACME HTTP challenge. Check UFW:
```bash
ssh user@vps "ufw status"
```

## State File Issues

### State file is corrupted

The state file is JSON at `~/docker/.homelab-state.json`. If corrupted:

```bash
# Check if it's valid JSON
jq '.' ~/docker/.homelab-state.json

# If not, restore from backup (install.sh creates .bak files)
ls ~/docker/.homelab-state.json.bak.*
cp ~/docker/.homelab-state.json.bak.<timestamp> ~/docker/.homelab-state.json
```

### Manually edit state

```bash
# View current state
cat ~/docker/.homelab-state.json | jq '.'

# Update a value
jq '.domain = "newdomain.com"' ~/docker/.homelab-state.json > /tmp/state.tmp
mv /tmp/state.tmp ~/docker/.homelab-state.json
```

## Getting Help

1. Check the logs: `./manage.sh logs <app>`
2. Check the install log: `cat /tmp/portless-install.log`
3. Open an issue: https://github.com/techbutton/portless/issues

When reporting an issue, include:
- OS and version: `cat /etc/os-release`
- Docker version: `docker --version && docker compose version`
- The error message + relevant logs
- Your `.homelab-state.json` (redact sensitive values)
