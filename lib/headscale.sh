#!/usr/bin/env bash
# lib/headscale.sh — Headscale (self-hosted Tailscale control plane) setup
#
# Headscale replaces the Tailscale coordination server with one you control.
# Devices still use the Tailscale client — they just point at your VPS instead
# of tailscale.com. No data ever leaves your infrastructure.
#
# VPS requirements: 1 vCPU · 512 MB RAM · public IP · domain pointing to it
#

[[ -n "$HOMELAB_COMMON_LOADED" ]] || source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
HOMELAB_HEADSCALE_LOADED=1

# ─── SSH helpers ──────────────────────────────────────────────────────────────

_hs_init_connection() {
  HEADSCALE_VPS_HOST=$(state_get '.tunnel.headscale.vps_host')
  HEADSCALE_SSH_USER=$(state_get '.tunnel.headscale.ssh_user')
  HEADSCALE_SSH_AUTH=$(state_get '.tunnel.headscale.ssh_auth')
  HEADSCALE_SSH_KEY=$(state_get '.tunnel.headscale.ssh_key')
  HEADSCALE_SSH_PASS=$(state_get '.tunnel.headscale.ssh_pass')

  if [[ "$HEADSCALE_SSH_AUTH" == "password" ]]; then
    if ! check_command sshpass; then
      log_sub "Installing sshpass for password-based SSH..."
      sudo apt-get install -y sshpass 2>/dev/null \
        || die "Could not install sshpass — please install it manually"
    fi
  fi
}

_hs_ssh() {
  local cmd="$1"
  if [[ "$HEADSCALE_SSH_AUTH" == "password" ]]; then
    SSHPASS="$HEADSCALE_SSH_PASS" sshpass -e \
      ssh -o StrictHostKeyChecking=accept-new \
          -o ConnectTimeout=15 \
          "${HEADSCALE_SSH_USER}@${HEADSCALE_VPS_HOST}" "$cmd"
  else
    ssh -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=15 \
        -i "$HEADSCALE_SSH_KEY" \
        "${HEADSCALE_SSH_USER}@${HEADSCALE_VPS_HOST}" "$cmd"
  fi
}

_hs_scp_to() {
  local local_path="$1"
  local remote_path="$2"
  if [[ "$HEADSCALE_SSH_AUTH" == "password" ]]; then
    SSHPASS="$HEADSCALE_SSH_PASS" sshpass -e \
      scp -o StrictHostKeyChecking=accept-new \
          "$local_path" \
          "${HEADSCALE_SSH_USER}@${HEADSCALE_VPS_HOST}:${remote_path}"
  else
    scp -o StrictHostKeyChecking=accept-new \
        -i "$HEADSCALE_SSH_KEY" \
        "$local_path" \
        "${HEADSCALE_SSH_USER}@${HEADSCALE_VPS_HOST}:${remote_path}"
  fi
}

# ─── Wizards ──────────────────────────────────────────────────────────────────

headscale_wizard_fresh() {
  log_step "Headscale VPS Setup"

  cat <<EOF

  ${BOLD}Headscale${RESET} is a fully self-hosted Tailscale control plane. Your devices
  use the standard Tailscale client but connect to your own coordination
  server instead of tailscale.com. Zero Tailscale account required.

  ${BOLD}Recommended VPS specs:${RESET}
  ${CYAN}  1 vCPU · 512 MB RAM · public IP · domain pointed at it${RESET}

  ${BOLD}You need:${RESET}
  • A VPS with a public IP
  • A subdomain pointed at the VPS (e.g. headscale.yourdomain.com)
  • SSH access to the VPS (key or password)

EOF

  prompt_input "VPS IP address or hostname" ""
  local vps_host="$REPLY"
  [[ -n "$vps_host" ]] || die "VPS host is required"

  prompt_input "Headscale domain (e.g. headscale.yourdomain.com)" ""
  local hs_domain="$REPLY"
  [[ -n "$hs_domain" ]] || die "Headscale domain is required"
  validate_domain "$hs_domain" || log_warn "Domain format looks unusual — continuing anyway"

  prompt_input "Admin email (for Let's Encrypt TLS certs)" ""
  local admin_email="$REPLY"

  prompt_input "SSH username" "root"
  local ssh_user="$REPLY"

  prompt_select "SSH authentication method:" \
    "SSH key (recommended)" \
    "Password"

  local ssh_auth ssh_key="" ssh_pass=""
  if [[ "$REPLY" == SSH* ]]; then
    prompt_input "Path to SSH private key" "$HOME/.ssh/id_rsa"
    ssh_key="$REPLY"
    [[ -f "$ssh_key" ]] || die "SSH key not found: $ssh_key"
    ssh_auth="key"
  else
    prompt_secret "SSH password"
    ssh_pass="$REPLY"
    ssh_auth="password"
  fi

  prompt_input "Headscale username/namespace (e.g. 'homelab')" "homelab"
  local hs_username="$REPLY"

  # Save to state
  state_set "
    .tunnel.method = \"headscale\" |
    .tunnel.headscale.vps_host = \"${vps_host}\" |
    .tunnel.headscale.server_url = \"https://${hs_domain}\" |
    .tunnel.headscale.domain = \"${hs_domain}\" |
    .tunnel.headscale.admin_email = \"${admin_email}\" |
    .tunnel.headscale.ssh_user = \"${ssh_user}\" |
    .tunnel.headscale.ssh_auth = \"${ssh_auth}\" |
    .tunnel.headscale.ssh_key = \"${ssh_key}\" |
    .tunnel.headscale.ssh_pass = \"${ssh_pass}\" |
    .tunnel.headscale.username = \"${hs_username}\"
  "

  HEADSCALE_VPS_HOST="$vps_host"
  HEADSCALE_SSH_USER="$ssh_user"
  HEADSCALE_SSH_AUTH="$ssh_auth"
  HEADSCALE_SSH_KEY="${ssh_key:-}"
  HEADSCALE_SSH_PASS="${ssh_pass:-}"

  if [[ "$ssh_auth" == "password" ]]; then
    check_command sshpass \
      || { log_sub "Installing sshpass..."; sudo apt-get install -y sshpass 2>/dev/null; }
  fi

  headscale_install_vps "$vps_host" "$hs_domain" "$admin_email"
  headscale_create_user "$hs_username"
  headscale_get_preauth_key "$hs_username"

  # Don't persist SSH password in state
  if [[ "$ssh_auth" == "password" ]]; then
    state_set ".tunnel.headscale.ssh_pass = \"\""
    log_warn "SSH password not saved to state. Set up SSH key access for future management."
  fi

  log_ok "Headscale installed on VPS"
  log_info "Admin UI (headscale-ui):  https://${hs_domain}/web"
  log_info "Headscale API:            https://${hs_domain}"
}

headscale_wizard_existing() {
  log_step "Connect to Existing Headscale Instance"

  prompt_input "Headscale server URL (e.g. https://headscale.yourdomain.com)" ""
  local server_url="$REPLY"
  [[ -n "$server_url" ]] || die "Headscale server URL is required"

  prompt_input "VPS IP or hostname (for SSH access)" ""
  local vps_host="$REPLY"

  prompt_input "SSH username" "root"
  local ssh_user="$REPLY"

  prompt_select "SSH authentication:" \
    "SSH key (recommended)" \
    "Password"

  local ssh_auth ssh_key="" ssh_pass=""
  if [[ "$REPLY" == SSH* ]]; then
    prompt_input "Path to SSH private key" "$HOME/.ssh/id_rsa"
    ssh_key="$REPLY"
    ssh_auth="key"
  else
    prompt_secret "SSH password"
    ssh_pass="$REPLY"
    ssh_auth="password"
  fi

  prompt_input "Headscale username/namespace" "homelab"
  local hs_username="$REPLY"

  state_set "
    .tunnel.method = \"headscale\" |
    .tunnel.headscale.server_url = \"${server_url}\" |
    .tunnel.headscale.vps_host = \"${vps_host}\" |
    .tunnel.headscale.ssh_user = \"${ssh_user}\" |
    .tunnel.headscale.ssh_auth = \"${ssh_auth}\" |
    .tunnel.headscale.ssh_key = \"${ssh_key}\" |
    .tunnel.headscale.ssh_pass = \"${ssh_pass}\" |
    .tunnel.headscale.username = \"${hs_username}\"
  "

  HEADSCALE_VPS_HOST="$vps_host"
  HEADSCALE_SSH_USER="$ssh_user"
  HEADSCALE_SSH_AUTH="$ssh_auth"
  HEADSCALE_SSH_KEY="${ssh_key:-}"
  HEADSCALE_SSH_PASS="${ssh_pass:-}"

  if [[ "$ssh_auth" == "password" ]]; then
    check_command sshpass || sudo apt-get install -y sshpass 2>/dev/null
  fi

  log_sub "Creating user '${hs_username}' if it doesn't exist..."
  _hs_ssh "docker exec headscale headscale users create ${hs_username} 2>/dev/null || true" || true

  headscale_get_preauth_key "$hs_username"

  log_ok "Connected to existing Headscale at ${server_url}"
}

# ─── VPS installation ─────────────────────────────────────────────────────────

headscale_install_vps() {
  local vps_host="$1"
  local hs_domain="$2"
  local admin_email="$3"

  log_step "Installing Headscale on VPS (${vps_host})"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

  # Render config + compose templates
  local tmp_compose tmp_config
  tmp_compose=$(mktemp /tmp/headscale-compose.XXXXXX.yml)
  tmp_config=$(mktemp /tmp/headscale-config.XXXXXX.yaml)

  render_template "${script_dir}/templates/headscale/headscale-compose.yml.tmpl" "$tmp_compose" \
    "HEADSCALE_DOMAIN=${hs_domain}"

  render_template "${script_dir}/templates/headscale/headscale.yaml.tmpl" "$tmp_config" \
    "HEADSCALE_DOMAIN=${hs_domain}" \
    "ACME_EMAIL=${admin_email}"

  local tmp_caddyfile
  tmp_caddyfile=$(mktemp /tmp/headscale-Caddyfile.XXXXXX)
  render_template "${script_dir}/templates/headscale/Caddyfile.tmpl" "$tmp_caddyfile" \
    "HEADSCALE_DOMAIN=${hs_domain}" \
    "ACME_EMAIL=${admin_email}"

  log_sub "Sending configuration to VPS..."
  _hs_ssh "mkdir -p /opt/headscale/config /opt/headscale/data /opt/headscale/caddy/data /opt/headscale/caddy/config"
  _hs_scp_to "$tmp_compose"    "/opt/headscale/docker-compose.yml"
  _hs_scp_to "$tmp_config"     "/opt/headscale/config/config.yaml"
  _hs_scp_to "$tmp_caddyfile"  "/opt/headscale/caddy/Caddyfile"
  rm -f "$tmp_compose" "$tmp_config" "$tmp_caddyfile"

  log_sub "Installing Docker and starting Headscale..."
  local done_marker
  # shellcheck disable=SC2087
  done_marker=$(_hs_ssh 'bash -s' <<'REMOTE'
set -euo pipefail

# Install Docker if missing
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

# Basic firewall rules
if command -v ufw &>/dev/null; then
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 41641/udp  # Headscale WireGuard / DERP
  ufw --force enable
fi

# Start Headscale
cd /opt/headscale
docker compose pull -q 2>/dev/null || true
docker compose up -d

sleep 5
echo "HEADSCALE_STARTED"
REMOTE
)

  echo "$done_marker" | grep -q "HEADSCALE_STARTED" \
    || die "Headscale failed to start on VPS — check the VPS logs"

  log_ok "Headscale started on VPS"
}

# ─── User and key management ──────────────────────────────────────────────────

headscale_create_user() {
  local username="$1"
  log_sub "Creating Headscale user '${username}'..."
  _hs_ssh "docker exec headscale headscale users create ${username} 2>/dev/null || true"
  log_ok "User '${username}' ready"
}

headscale_get_preauth_key() {
  local username="$1"
  log_sub "Generating pre-auth key for '${username}'..."

  local preauth_key
  preauth_key=$(_hs_ssh "docker exec headscale headscale preauthkeys create \
    --user ${username} \
    --reusable \
    --expiration 720h \
    --output json" | jq -r '.key // empty')

  [[ -n "$preauth_key" ]] \
    || die "Failed to generate pre-auth key — check Headscale is running on VPS"

  state_set ".tunnel.headscale.preauth_key = \"${preauth_key}\""
  HEADSCALE_PREAUTH_KEY="$preauth_key"
  log_ok "Pre-auth key generated (valid 30 days)"
}

# ─── Compose integration ──────────────────────────────────────────────────────

# Append Tailscale client (pointing at self-hosted Headscale) to compose file
headscale_setup_compose() {
  local compose_file="$1"

  local server_url preauth_key hostname
  server_url=$(state_get '.tunnel.headscale.server_url')
  preauth_key=$(state_get '.tunnel.headscale.preauth_key')
  hostname=$(state_get '.hostname')

  cat >> "$compose_file" <<EOF

  ########## HEADSCALE CLIENT (Tailscale → self-hosted control plane) ##########
  tailscale:
    image: tailscale/tailscale:latest
    container_name: tailscale
    restart: unless-stopped
    hostname: ${hostname}
    environment:
      - TS_AUTHKEY=${preauth_key}
      - TS_LOGIN_SERVER=${server_url}
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_USERSPACE=false
      - TS_ACCEPT_DNS=false
      - TS_EXTRA_ARGS=--advertise-routes=192.168.90.0/24,192.168.91.0/24 --accept-routes
    volumes:
      - \${DOCKERDIR}/appdata/tailscale:/var/lib/tailscale
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
      - NET_RAW
    networks:
      - t3_proxy
      - socket_proxy
    security_opt:
      - no-new-privileges:true
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
EOF

  log_sub "Headscale client (tailscale) container added to compose"
}

# ─── Status ───────────────────────────────────────────────────────────────────

headscale_status() {
  local server_url vps_host username
  server_url=$(state_get '.tunnel.headscale.server_url')
  vps_host=$(state_get '.tunnel.headscale.vps_host')
  username=$(state_get '.tunnel.headscale.username')

  echo -e "  Server URL:  ${CYAN}${server_url:-not set}${RESET}"
  echo -e "  VPS Host:    ${CYAN}${vps_host:-not set}${RESET}"
  echo -e "  Username:    ${CYAN}${username:-not set}${RESET}"
  echo ""

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^tailscale$'; then
    log_sub "Connected peers (via Headscale):"
    docker exec tailscale tailscale status 2>/dev/null \
      || log_warn "Could not get status (container may still be starting)"
    echo ""
    log_sub "Headscale IP:"
    docker exec tailscale tailscale ip -4 2>/dev/null || true
  else
    log_warn "Tailscale/Headscale client container is not running"
    log_info "Start it: docker compose up -d tailscale"
  fi

  echo ""
  log_info "Manage peers on VPS: docker exec headscale headscale nodes list"
  log_info "Generate new key:    docker exec headscale headscale preauthkeys create --user ${username} --reusable"
}
