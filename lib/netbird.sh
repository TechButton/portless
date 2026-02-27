#!/usr/bin/env bash
# lib/netbird.sh — Netbird WireGuard mesh VPN setup
#
# Netbird creates an end-to-end encrypted peer-to-peer WireGuard mesh.
# Traffic routes directly between peers; the management server only handles
# coordination (peer discovery, ACL policy). Two options:
#
#   Cloud:       Use Netbird's hosted management at app.netbird.io (free tier)
#   Self-hosted: Run the full Netbird management stack on your own VPS
#
# Self-hosted VPS requirements: 1 vCPU · 1 GB RAM · public IP · domain
#

[[ -n "$HOMELAB_COMMON_LOADED" ]] || source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
HOMELAB_NETBIRD_LOADED=1

# ─── SSH helpers ──────────────────────────────────────────────────────────────

_nb_init_ssh() {
  NB_VPS_HOST=$(state_get '.tunnel.netbird.vps_host')
  NB_SSH_USER=$(state_get '.tunnel.netbird.ssh_user')
  NB_SSH_AUTH=$(state_get '.tunnel.netbird.ssh_auth')
  NB_SSH_KEY=$(state_get '.tunnel.netbird.ssh_key')
  NB_SSH_PASS=$(state_get '.tunnel.netbird.ssh_pass')

  if [[ "$NB_SSH_AUTH" == "password" ]]; then
    if ! check_command sshpass; then
      log_sub "Installing sshpass..."
      sudo apt-get install -y sshpass 2>/dev/null \
        || die "Could not install sshpass — please install it manually"
    fi
  fi
}

_nb_ssh() {
  local cmd="$1"
  if [[ "$NB_SSH_AUTH" == "password" ]]; then
    SSHPASS="$NB_SSH_PASS" sshpass -e \
      ssh -o StrictHostKeyChecking=accept-new \
          -o ConnectTimeout=15 \
          "${NB_SSH_USER}@${NB_VPS_HOST}" "$cmd"
  else
    ssh -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=15 \
        -i "$NB_SSH_KEY" \
        "${NB_SSH_USER}@${NB_VPS_HOST}" "$cmd"
  fi
}

_nb_scp_to() {
  local local_path="$1"
  local remote_path="$2"
  if [[ "$NB_SSH_AUTH" == "password" ]]; then
    SSHPASS="$NB_SSH_PASS" sshpass -e \
      scp -o StrictHostKeyChecking=accept-new \
          "$local_path" "${NB_SSH_USER}@${NB_VPS_HOST}:${remote_path}"
  else
    scp -o StrictHostKeyChecking=accept-new \
        -i "$NB_SSH_KEY" \
        "$local_path" "${NB_SSH_USER}@${NB_VPS_HOST}:${remote_path}"
  fi
}

# ─── Main wizard ──────────────────────────────────────────────────────────────

netbird_wizard() {
  log_step "Netbird WireGuard Mesh VPN Setup"

  cat <<EOF

  ${BOLD}Netbird${RESET} builds a direct WireGuard mesh between all your devices.
  Traffic is end-to-end encrypted; after the initial handshake no data
  passes through any server — peers connect directly.

  ${BOLD}Choose your management option:${RESET}

  ${CYAN}1) Netbird Cloud${RESET}  — FREE · No VPS · Setup in minutes
     Use Netbird's hosted management at ${CYAN}app.netbird.io${RESET}
     Free tier: unlimited peers, 5 users, 100 Mb/s per peer

  ${CYAN}2) Self-hosted${RESET}   — Full control · VPS required
     Run the full Netbird management stack on your own VPS.
     No data ever touches Netbird's servers.

EOF

  prompt_select "Netbird setup:" \
    "Netbird Cloud (free, no VPS, quickest setup)" \
    "Self-hosted Netbird on a VPS (full control)"

  if [[ "$REPLY" == Netbird* ]]; then
    netbird_wizard_cloud
  else
    netbird_wizard_selfhosted
  fi
}

# ─── Cloud wizard ─────────────────────────────────────────────────────────────

netbird_wizard_cloud() {
  log_step "Netbird Cloud Setup"

  cat <<EOF

  ${BOLD}How to get your Setup Key:${RESET}
  1. Open ${CYAN}https://app.netbird.io${RESET} and sign in (or create a free account)
  2. Go to ${CYAN}Setup Keys${RESET} in the left sidebar
  3. Click ${CYAN}Create Setup Key${RESET}
  4. Name: "homeserver" | Type: Reusable | Expiry: Never (or 30 days)
  5. Copy the key and paste it below

  ${DIM}The setup key authenticates this server to your Netbird network.
  All other devices also need Netbird installed with this same key.
  Download for your devices: https://netbird.io/download${RESET}

EOF

  prompt_input "Netbird setup key (netbird_setup_key_...)" ""
  local setup_key="$REPLY"
  [[ -n "$setup_key" ]] || die "Setup key is required"

  state_set "
    .tunnel.method = \"netbird\" |
    .tunnel.netbird.self_hosted = false |
    .tunnel.netbird.management_url = \"https://api.wire.netbird.io\" |
    .tunnel.netbird.setup_key = \"${setup_key}\"
  "

  log_ok "Netbird Cloud configured"
  log_info "Dashboard: https://app.netbird.io"
  log_info "After deployment, connected peers appear in the Netbird dashboard automatically"
}

# ─── Self-hosted wizard ───────────────────────────────────────────────────────

netbird_wizard_selfhosted() {
  log_step "Self-hosted Netbird VPS Setup"

  cat <<EOF

  ${BOLD}Self-hosted Netbird${RESET} runs the following on your VPS:
  • ${CYAN}Management server${RESET}  — API, policy engine, peer registry
  • ${CYAN}Signal server${RESET}      — WebRTC signaling for peer discovery
  • ${CYAN}Relay server${RESET}       — Fallback relay for strict NAT
  • ${CYAN}Coturn${RESET}             — STUN/TURN for NAT traversal
  • ${CYAN}Nginx${RESET}              — TLS termination + reverse proxy

  ${BOLD}Recommended VPS specs:${RESET}
  ${CYAN}  1 vCPU · 1 GB RAM · public IP · domain pointed at it${RESET}

EOF

  prompt_input "VPS IP address" ""
  local vps_host="$REPLY"
  [[ -n "$vps_host" ]] || die "VPS host is required"

  prompt_input "Netbird domain (e.g. netbird.yourdomain.com)" ""
  local nb_domain="$REPLY"
  [[ -n "$nb_domain" ]] || die "Netbird domain is required"
  validate_domain "$nb_domain" || log_warn "Domain format looks unusual — continuing anyway"

  prompt_input "Admin email (for initial login + Let's Encrypt)" ""
  local admin_email="$REPLY"

  prompt_input "SSH username" "root"
  local ssh_user="$REPLY"

  prompt_select "SSH authentication:" \
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

  state_set "
    .tunnel.method = \"netbird\" |
    .tunnel.netbird.self_hosted = true |
    .tunnel.netbird.vps_host = \"${vps_host}\" |
    .tunnel.netbird.domain = \"${nb_domain}\" |
    .tunnel.netbird.management_url = \"https://${nb_domain}\" |
    .tunnel.netbird.admin_email = \"${admin_email}\" |
    .tunnel.netbird.ssh_user = \"${ssh_user}\" |
    .tunnel.netbird.ssh_auth = \"${ssh_auth}\" |
    .tunnel.netbird.ssh_key = \"${ssh_key}\" |
    .tunnel.netbird.ssh_pass = \"${ssh_pass}\"
  "

  NB_VPS_HOST="$vps_host"
  NB_SSH_USER="$ssh_user"
  NB_SSH_AUTH="$ssh_auth"
  NB_SSH_KEY="${ssh_key:-}"
  NB_SSH_PASS="${ssh_pass:-}"

  if [[ "$ssh_auth" == "password" ]]; then
    check_command sshpass || { log_sub "Installing sshpass..."; sudo apt-get install -y sshpass 2>/dev/null; }
  fi

  netbird_install_vps "$vps_host" "$nb_domain" "$admin_email"
  netbird_get_setup_key "$nb_domain"

  # Don't persist SSH password in state
  if [[ "$ssh_auth" == "password" ]]; then
    state_set ".tunnel.netbird.ssh_pass = \"\""
    log_warn "SSH password not saved to state. Set up SSH key access for future management."
  fi
}

# ─── VPS installation ─────────────────────────────────────────────────────────

netbird_install_vps() {
  local vps_host="$1"
  local nb_domain="$2"
  local admin_email="$3"

  log_step "Installing Netbird on VPS (${vps_host})"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

  # Generate secrets needed for Netbird compose
  local turn_secret management_secret
  turn_secret=$(openssl rand -hex 32)
  management_secret=$(openssl rand -hex 32)

  # Render compose template
  local tmp_compose
  tmp_compose=$(mktemp /tmp/netbird-compose.XXXXXX.yml)
  render_template "${script_dir}/templates/netbird/netbird-compose.yml.tmpl" "$tmp_compose" \
    "NETBIRD_DOMAIN=${nb_domain}" \
    "ACME_EMAIL=${admin_email}" \
    "TURN_SECRET=${turn_secret}" \
    "MANAGEMENT_SECRET=${management_secret}"

  log_sub "Sending configuration to VPS..."
  _nb_ssh "mkdir -p /opt/netbird"
  _nb_scp_to "$tmp_compose" "/opt/netbird/docker-compose.yml"
  rm -f "$tmp_compose"

  log_sub "Installing Docker and starting Netbird stack..."
  local done_marker
  # shellcheck disable=SC2087
  done_marker=$(_nb_ssh 'bash -s' <<'REMOTE'
set -euo pipefail

# Install Docker if missing
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

# Firewall
if command -v ufw &>/dev/null; then
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 3478/udp   # STUN
  ufw allow 10000/udp  # Netbird relay / signal
  ufw allow 49152:65535/udp  # TURN dynamic ports
  ufw --force enable
fi

cd /opt/netbird
docker compose pull -q 2>/dev/null || true
docker compose up -d

sleep 8
echo "NETBIRD_STARTED"
REMOTE
)

  echo "$done_marker" | grep -q "NETBIRD_STARTED" \
    || die "Netbird failed to start on VPS — check the VPS logs"

  log_ok "Netbird management stack started"
  log_info "Dashboard:  https://${nb_domain}"
  log_warn "TLS certs may take 60–90 seconds to provision"
}

# ─── Setup key retrieval ──────────────────────────────────────────────────────

netbird_get_setup_key() {
  local nb_domain="$1"

  echo ""
  log_info "Waiting for Netbird to become available (up to 2 minutes)..."
  local retries=0
  while [[ $retries -lt 12 ]]; do
    if curl -sf "https://${nb_domain}/api/setup-keys" &>/dev/null; then
      break
    fi
    sleep 10
    ((retries++)) || true
  done

  echo ""
  echo -e "  ${BOLD}Complete the Netbird initial setup:${RESET}"
  log_info "1. Open: ${CYAN}https://${nb_domain}${RESET}"
  log_info "2. Create your admin account and complete the setup wizard"
  log_info "3. Navigate to ${CYAN}Setup Keys${RESET} in the left sidebar"
  log_info "4. Click ${CYAN}Create Setup Key${RESET} — type: Reusable, expiry: Never"
  log_info "5. Copy the key and paste it below"
  echo ""

  prompt_input "Netbird setup key" ""
  local setup_key="$REPLY"
  [[ -n "$setup_key" ]] || die "Setup key is required"

  state_set ".tunnel.netbird.setup_key = \"${setup_key}\""
  log_ok "Netbird setup key saved"
}

# ─── Compose integration ──────────────────────────────────────────────────────

# Append Netbird client container to compose file
netbird_setup_compose() {
  local compose_file="$1"

  local setup_key mgmt_url hostname
  setup_key=$(state_get '.tunnel.netbird.setup_key')
  mgmt_url=$(state_get '.tunnel.netbird.management_url')
  hostname=$(state_get '.hostname')

  # Default to cloud if not set
  : "${mgmt_url:=https://api.wire.netbird.io}"

  cat >> "$compose_file" <<EOF

  ########## NETBIRD ##########
  netbird:
    image: netbirdio/netbird:latest
    container_name: netbird
    restart: unless-stopped
    environment:
      - NB_SETUP_KEY=\${NETBIRD_SETUP_KEY}
      - NB_MANAGEMENT_URL=\${NETBIRD_MANAGEMENT_URL}
      - NB_HOSTNAME=${hostname}
    volumes:
      - \${DOCKERDIR}/appdata/netbird:/etc/netbird
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN
      - SYS_RESOURCE
    devices:
      - /dev/net/tun
    networks:
      - t3_proxy
      - socket_proxy
    security_opt:
      - no-new-privileges:true
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
EOF

  log_sub "Netbird client container added to compose"
}

# Write Netbird env vars to .env file
netbird_write_env() {
  local env_file="$1"
  local setup_key mgmt_url
  setup_key=$(state_get '.tunnel.netbird.setup_key')
  mgmt_url=$(state_get '.tunnel.netbird.management_url')

  if ! grep -q "^NETBIRD_SETUP_KEY=" "$env_file" 2>/dev/null; then
    {
      echo ""
      echo "# Netbird"
      echo "NETBIRD_SETUP_KEY=${setup_key}"
      echo "NETBIRD_MANAGEMENT_URL=${mgmt_url:-https://api.wire.netbird.io}"
    } >> "$env_file"
  fi
}

# ─── Status ───────────────────────────────────────────────────────────────────

netbird_status() {
  local self_hosted mgmt_url
  self_hosted=$(state_get '.tunnel.netbird.self_hosted')
  mgmt_url=$(state_get '.tunnel.netbird.management_url')

  if [[ "$self_hosted" == "true" ]]; then
    echo -e "  Mode:         ${CYAN}Self-hosted${RESET}"
    echo -e "  Domain:       ${CYAN}$(state_get '.tunnel.netbird.domain')${RESET}"
    echo -e "  VPS:          ${CYAN}$(state_get '.tunnel.netbird.vps_host')${RESET}"
  else
    echo -e "  Mode:         ${CYAN}Netbird Cloud (app.netbird.io)${RESET}"
  fi
  echo -e "  Management:   ${CYAN}${mgmt_url}${RESET}"
  echo ""

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^netbird$'; then
    log_sub "Netbird peer status:"
    docker exec netbird netbird status 2>/dev/null \
      || log_warn "Could not get status (container may still be starting)"
  else
    log_warn "Netbird container is not running"
    log_info "Start it: docker compose up -d netbird"
  fi
}
