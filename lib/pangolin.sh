#!/usr/bin/env bash
# lib/pangolin.sh — Full Pangolin VPS setup + Newt + resource registration
#
# Based on proven patterns from PANGOLIN_INFRASTRUCTURE.md and THEMEDIA_SETUP.md
# Critical: method must be 'https' and tlsServerName must be set (avoids redirect loop)

[[ -n "$HOMELAB_COMMON_LOADED" ]] || source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
HOMELAB_PANGOLIN_LOADED=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADD_RESOURCE_SCRIPT="${REPO_ROOT}/templates/pangolin/add_resource.cjs"
VPS_INIT_SCRIPT="${REPO_ROOT}/templates/pangolin/vps-init.sh"
PANGOLIN_COMPOSE_TMPL="${REPO_ROOT}/templates/pangolin/pangolin-compose.yml.tmpl"
PANGOLIN_CONFIG_TMPL="${REPO_ROOT}/templates/pangolin/pangolin-config.yml.tmpl"

# ─── SSH connection state ──────────────────────────────────────────────────────
# Set by _pang_init_connection(); used by _pang_ssh() and _pang_scp_to()
_PANG_VPS_HOST=""
_PANG_SSH_USER="root"
_PANG_SSH_AUTH="key"         # 'key' or 'password'
_PANG_SSH_KEY=""
_PANG_SSH_PASS=""
_PANG_SSH_PORT="22"
# Built once by _pang_init_connection
_PANG_SSH_BASE_OPTS=""

# ─── Connection setup ──────────────────────────────────────────────────────────

# _pang_init_connection — call once to configure the SSH session variables
# Usage: _pang_init_connection <host> <user> <auth> <key_or_pass> [port]
#   auth: 'key' or 'password'
_pang_init_connection() {
  _PANG_VPS_HOST="$1"
  _PANG_SSH_USER="$2"
  _PANG_SSH_AUTH="$3"
  local key_or_pass="$4"
  _PANG_SSH_PORT="${5:-22}"

  if [[ "$_PANG_SSH_AUTH" == "key" ]]; then
    _PANG_SSH_KEY="$key_or_pass"
    _PANG_SSH_BASE_OPTS="-i ${_PANG_SSH_KEY} -p ${_PANG_SSH_PORT} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes"
  else
    _PANG_SSH_PASS="$key_or_pass"
    _pang_require_sshpass
    _PANG_SSH_BASE_OPTS="-p ${_PANG_SSH_PORT} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o PasswordAuthentication=yes -o PubkeyAuthentication=no"
  fi
}

# _pang_require_sshpass — ensure sshpass is installed for password-based SSH
_pang_require_sshpass() {
  if ! command -v sshpass &>/dev/null; then
    log_warn "sshpass is required for password-based SSH"
    if command -v apt-get &>/dev/null; then
      log_sub "Installing sshpass..."
      sudo apt-get install -y -q sshpass >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 || \
        die "Cannot install sshpass. Install it manually: sudo apt-get install sshpass"
    elif command -v brew &>/dev/null; then
      brew install sshpass >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 || \
        die "Cannot install sshpass. Install it manually."
    else
      die "sshpass not found. Install it with your package manager, or use an SSH key instead."
    fi
    log_ok "sshpass installed"
  fi
}

# _pang_ssh <cmd> — run a command on the VPS via SSH
_pang_ssh() {
  local cmd="$*"
  if [[ "$_PANG_SSH_AUTH" == "password" ]]; then
    # shellcheck disable=SC2086
    SSHPASS="$_PANG_SSH_PASS" sshpass -e \
      ssh $_PANG_SSH_BASE_OPTS "${_PANG_SSH_USER}@${_PANG_VPS_HOST}" "$cmd"
  else
    # shellcheck disable=SC2086
    ssh $_PANG_SSH_BASE_OPTS "${_PANG_SSH_USER}@${_PANG_VPS_HOST}" "$cmd"
  fi
}

# _pang_ssh_script — pipe a heredoc/script to bash on the VPS
# Usage: _pang_ssh_script << 'EOF' ... EOF
_pang_ssh_script() {
  if [[ "$_PANG_SSH_AUTH" == "password" ]]; then
    # shellcheck disable=SC2086
    SSHPASS="$_PANG_SSH_PASS" sshpass -e \
      ssh $_PANG_SSH_BASE_OPTS "${_PANG_SSH_USER}@${_PANG_VPS_HOST}" bash -s
  else
    # shellcheck disable=SC2086
    ssh $_PANG_SSH_BASE_OPTS "${_PANG_SSH_USER}@${_PANG_VPS_HOST}" bash -s
  fi
}

# _pang_scp_to <local_file> <remote_path> — copy a file to the VPS
_pang_scp_to() {
  local local_file="$1"
  local remote_path="$2"
  if [[ "$_PANG_SSH_AUTH" == "password" ]]; then
    # shellcheck disable=SC2086
    SSHPASS="$_PANG_SSH_PASS" sshpass -e \
      scp -P "${_PANG_SSH_PORT}" -o StrictHostKeyChecking=accept-new \
        -o PasswordAuthentication=yes -o PubkeyAuthentication=no \
        "$local_file" "${_PANG_SSH_USER}@${_PANG_VPS_HOST}:${remote_path}"
  else
    # shellcheck disable=SC2086
    scp -P "${_PANG_SSH_PORT}" -i "${_PANG_SSH_KEY}" -o StrictHostKeyChecking=accept-new \
      "$local_file" "${_PANG_SSH_USER}@${_PANG_VPS_HOST}:${remote_path}"
  fi
}

# _pang_test_connection — returns 0 if SSH works
_pang_test_connection() {
  _pang_ssh "echo OK" &>/dev/null
}

# ─── VPS Installation ──────────────────────────────────────────────────────────
#
# pangolin_install_vps <vps_ip> <ssh_user> <ssh_auth> <key_or_pass> <domain> <acme_email>
#
# Full install:
#   1. Test SSH, detect sudo ability
#   2. Run vps-init.sh (hardening + Docker)
#   3. Deploy Pangolin docker-compose stack
#   4. Wait for Pangolin API
#
pangolin_install_vps() {
  local vps_ip="$1"
  local ssh_user="$2"
  local ssh_auth="$3"       # 'key' or 'password'
  local key_or_pass="$4"
  local pangolin_domain="$5"
  local acme_email="$6"

  _pang_init_connection "$vps_ip" "$ssh_user" "$ssh_auth" "$key_or_pass"

  log_step "Installing Pangolin on VPS: ${vps_ip}"

  # ── 1. Test SSH ──────────────────────────────────────────────────────────────
  log_sub "Testing SSH connection..."
  if ! _pang_test_connection; then
    die "Cannot SSH to ${ssh_user}@${vps_ip}. Check credentials and that the VPS is reachable."
  fi
  log_ok "SSH connection successful"

  # ── 2. Harden + install Docker ───────────────────────────────────────────────
  log_sub "Running VPS initialization (hardening + Docker)..."
  log_sub "  This will take 2-5 minutes. Progress logged to ${LOG_FILE:-/tmp/portless-install.log}"

  _pang_scp_to "$VPS_INIT_SCRIPT" "/tmp/homelab-vps-init.sh" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 || die "Could not copy init script to VPS"

  local init_output
  init_output=$(_pang_ssh "chmod +x /tmp/homelab-vps-init.sh && sudo bash /tmp/homelab-vps-init.sh" 2>&1) \
    || { echo "$init_output" >> ${LOG_FILE:-/tmp/portless-install.log}; die "VPS init script failed — see ${LOG_FILE:-/tmp/portless-install.log}"; }

  echo "$init_output" >> ${LOG_FILE:-/tmp/portless-install.log}
  if ! echo "$init_output" | grep -q "VPS_INIT_DONE"; then
    log_warn "VPS init completed with warnings — check ${LOG_FILE:-/tmp/portless-install.log}"
    log_warn "Continuing with Pangolin setup..."
  else
    log_ok "VPS hardening and Docker install complete"
  fi

  # ── 3. Deploy Pangolin stack ──────────────────────────────────────────────────
  log_sub "Deploying Pangolin docker-compose stack..."

  # Extract base domain (strip first subdomain: pangolin.example.com → example.com)
  local base_domain
  base_domain=$(echo "$pangolin_domain" | cut -d. -f2-)

  # Render templates locally
  local tmp_compose; tmp_compose=$(mktemp /tmp/pangolin-compose.XXXXXX.yml)
  local tmp_config;  tmp_config=$(mktemp /tmp/pangolin-config.XXXXXX.yml)

  render_template "$PANGOLIN_COMPOSE_TMPL" "$tmp_compose" \
    "PANGOLIN_DOMAIN=${pangolin_domain}" \
    "BASE_DOMAIN=${base_domain}" \
    "ACME_EMAIL=${acme_email}"

  render_template "$PANGOLIN_CONFIG_TMPL" "$tmp_config" \
    "PANGOLIN_DOMAIN=${pangolin_domain}" \
    "BASE_DOMAIN=${base_domain}" \
    "ACME_EMAIL=${acme_email}"

  # Upload to VPS
  _pang_ssh "mkdir -p /opt/pangolin/config /opt/pangolin/config/letsencrypt" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1

  _pang_scp_to "$tmp_compose" "/opt/pangolin/docker-compose.yml" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 || die "Could not upload Pangolin compose file"

  _pang_scp_to "$tmp_config" "/opt/pangolin/config/pangolin.config.yml" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 || die "Could not upload Pangolin config file"

  # Set correct permissions on acme.json (Traefik requirement)
  _pang_ssh "touch /opt/pangolin/config/letsencrypt/acme.json && chmod 600 /opt/pangolin/config/letsencrypt/acme.json" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1

  rm -f "$tmp_compose" "$tmp_config"

  # Start the stack
  log_sub "Starting Pangolin stack (docker compose up -d)..."
  _pang_ssh "cd /opt/pangolin && docker compose pull -q 2>/dev/null; docker compose up -d" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 \
    || die "Failed to start Pangolin stack — check ${LOG_FILE:-/tmp/portless-install.log}"
  log_ok "Pangolin stack started"

  # ── 4. Wait for Pangolin API ──────────────────────────────────────────────────
  log_sub "Waiting for Pangolin API to be ready (up to 90s)..."
  local attempts=0
  local ready=false
  while (( attempts < 18 )); do
    local ping_result
    ping_result=$(_pang_ssh "curl -sf --max-time 5 http://localhost:3001/api/v1/ping 2>/dev/null || echo FAIL")
    if [[ "$ping_result" != "FAIL" && -n "$ping_result" ]]; then
      ready=true
      break
    fi
    sleep 5
    (( attempts++ ))
  done

  if [[ "$ready" == "true" ]]; then
    log_ok "Pangolin API is ready"
  else
    log_warn "Pangolin API not responding yet — it may still be initializing."
    log_warn "Check VPS: ssh ${ssh_user}@${vps_ip} 'cd /opt/pangolin && docker compose logs'"
    log_warn "Continuing setup — API calls will retry..."
  fi

  PANGOLIN_VPS_HOST="$vps_ip"
  PANGOLIN_DOMAIN="$pangolin_domain"
}

# ─── Create admin, org, and site via Pangolin API ─────────────────────────────
#
# pangolin_setup_admin_and_site <admin_email> <admin_password> <org_name> <site_name>
#
# Must be called AFTER pangolin_install_vps (connection already initialized)
#
# Sets: PANGOLIN_ORG_ID, PANGOLIN_SITE_ID, NEWT_ID, NEWT_SECRET
#
pangolin_setup_admin_and_site() {
  local admin_email="$1"
  local admin_password="$2"
  local org_name="$3"
  local site_name="$4"

  log_step "Configuring Pangolin: admin user, organization, and site"

  # Run all API calls in a single SSH session to preserve the cookie jar
  local api_result
  api_result=$(_pang_ssh "bash -s" << REMOTE_API_SCRIPT
set -euo pipefail

API="http://localhost:3001"
COOKIES="/tmp/pangolin-cookies-\$\$.txt"
LOG="/tmp/pangolin-api-\$\$.log"
touch "\$COOKIES"

# Helper: curl with cookie jar
api_call() {
  local method="\$1"; shift
  local endpoint="\$1"; shift
  curl -sf -b "\$COOKIES" -c "\$COOKIES" \
    -X "\$method" "\${API}\${endpoint}" \
    -H "Content-Type: application/json" \
    "\$@" 2>> "\$LOG"
}

echo "=== Step 1: Create initial admin user ===" | tee -a "\$LOG"
SIGNUP=\$(api_call POST /api/v1/auth/signup -d "{\"email\": \"${admin_email}\", \"password\": \"${admin_password}\"}" 2>&1 || true)
echo "Signup response: \$SIGNUP" | tee -a "\$LOG"

# Check if signup succeeded or if user already exists (both are OK)
if echo "\$SIGNUP" | grep -qi '"error"'; then
  if echo "\$SIGNUP" | grep -qi 'already exists\|duplicate\|conflict'; then
    echo "Admin user already exists — proceeding to login"
  else
    echo "SIGNUP_FAILED: \$SIGNUP" | tee -a "\$LOG"
    # Don't fail here — might need login instead
  fi
fi

echo "=== Step 2: Login ===" | tee -a "\$LOG"
LOGIN=\$(api_call POST /api/v1/auth/login -d "{\"email\": \"${admin_email}\", \"password\": \"${admin_password}\"}" 2>&1)
echo "Login response: \$LOGIN" | tee -a "\$LOG"

if ! echo "\$LOGIN" | grep -qi '"token"\|"userId"\|success\|"user"'; then
  echo "LOGIN_FAILED: \$LOGIN" | tee -a "\$LOG"
  cat "\$LOG"
  exit 1
fi

# Extract bearer token if present (some Pangolin versions use token-based auth)
TOKEN=\$(echo "\$LOGIN" | grep -o '"token":"[^"]*"' | cut -d'"' -f4 || true)

echo "=== Step 3: Create organization ===" | tee -a "\$LOG"
if [[ -n "\$TOKEN" ]]; then
  ORG_RESP=\$(curl -sf -b "\$COOKIES" -c "\$COOKIES" \
    -X POST "\${API}/api/v1/org" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer \$TOKEN" \
    -d "{\"name\": \"${org_name}\"}" 2>> "\$LOG")
else
  ORG_RESP=\$(api_call POST /api/v1/org -d "{\"name\": \"${org_name}\"}")
fi
echo "Org response: \$ORG_RESP" | tee -a "\$LOG"

# Extract org ID from various possible response shapes
ORG_ID=\$(echo "\$ORG_RESP" | grep -o '"orgId":"[^"]*"' | cut -d'"' -f4 || true)
[[ -z "\$ORG_ID" ]] && ORG_ID=\$(echo "\$ORG_RESP" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
[[ -z "\$ORG_ID" ]] && ORG_ID=\$(echo "\$ORG_RESP" | grep -o '"org":{[^}]*"orgId":"[^"]*"' | grep -o '"orgId":"[^"]*"' | cut -d'"' -f4 || true)

if [[ -z "\$ORG_ID" ]]; then
  echo "ORG_CREATE_FAILED: \$ORG_RESP" | tee -a "\$LOG"
  cat "\$LOG"
  exit 2
fi

echo "Organization ID: \$ORG_ID" | tee -a "\$LOG"

echo "=== Step 4: Create site ===" | tee -a "\$LOG"
if [[ -n "\$TOKEN" ]]; then
  SITE_RESP=\$(curl -sf -b "\$COOKIES" -c "\$COOKIES" \
    -X POST "\${API}/api/v1/org/\${ORG_ID}/site" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer \$TOKEN" \
    -d "{\"name\": \"${site_name}\", \"type\": \"newt\"}" 2>> "\$LOG")
else
  SITE_RESP=\$(api_call POST "/api/v1/org/\${ORG_ID}/site" -d "{\"name\": \"${site_name}\", \"type\": \"newt\"}")
fi
echo "Site response: \$SITE_RESP" | tee -a "\$LOG"

# Parse site response
SITE_ID=\$(echo "\$SITE_RESP" | grep -o '"siteId":[0-9]*' | cut -d: -f2 || true)
NEWT_ID=\$(echo "\$SITE_RESP" | grep -o '"newtId":"[^"]*"' | cut -d'"' -f4 || true)
NEWT_SECRET=\$(echo "\$SITE_RESP" | grep -o '"newtSecret":"[^"]*"' | cut -d'"' -f4 || true)

if [[ -z "\$SITE_ID" || -z "\$NEWT_ID" || -z "\$NEWT_SECRET" ]]; then
  echo "SITE_CREATE_FAILED: \$SITE_RESP" | tee -a "\$LOG"
  cat "\$LOG"
  exit 3
fi

# Output structured result for parsing on local machine
echo "PANGOLIN_RESULT_START"
echo "ORG_ID=\${ORG_ID}"
echo "SITE_ID=\${SITE_ID}"
echo "NEWT_ID=\${NEWT_ID}"
echo "NEWT_SECRET=\${NEWT_SECRET}"
echo "PANGOLIN_RESULT_END"

rm -f "\$COOKIES" "\$LOG"
REMOTE_API_SCRIPT
  ) 2>&1

  # Parse output
  local result_block
  result_block=$(echo "$api_result" | sed -n '/PANGOLIN_RESULT_START/,/PANGOLIN_RESULT_END/p' | grep -v "PANGOLIN_RESULT")

  if [[ -z "$result_block" ]]; then
    log_error "Pangolin API setup failed. Output:"
    echo "$api_result" >&2
    echo "$api_result" >> ${LOG_FILE:-/tmp/portless-install.log}
    log_warn ""
    log_warn "You can complete setup manually via the Pangolin dashboard:"
    log_warn "  https://${PANGOLIN_DOMAIN}"
    log_warn ""
    _pang_prompt_manual_credentials
    return 0
  fi

  PANGOLIN_ORG_ID=$(echo "$result_block" | grep "^ORG_ID=" | cut -d= -f2)
  PANGOLIN_SITE_ID=$(echo "$result_block" | grep "^SITE_ID=" | cut -d= -f2)
  NEWT_ID=$(echo "$result_block" | grep "^NEWT_ID=" | cut -d= -f2)
  NEWT_SECRET=$(echo "$result_block" | grep "^NEWT_SECRET=" | cut -d= -f2)

  log_ok "Pangolin organization created: $PANGOLIN_ORG_ID"
  log_ok "Pangolin site created: ID $PANGOLIN_SITE_ID"
  log_ok "Newt credentials obtained"
}

# ─── Manual credential fallback ────────────────────────────────────────────────

_pang_prompt_manual_credentials() {
  log_warn "Switching to manual credential entry..."
  echo ""
  echo -e "  ${BOLD}Please open the Pangolin dashboard and:${RESET}"
  echo -e "  1. Create an organization"
  echo -e "  2. Create a site (type: Newt/WireGuard)"
  echo -e "  3. Copy the Newt credentials shown"
  echo ""

  prompt_input "Pangolin organization ID" ""
  PANGOLIN_ORG_ID="$REPLY"

  prompt_input "Pangolin site ID (number)" ""
  PANGOLIN_SITE_ID="$REPLY"

  prompt_input "Newt client ID" ""
  NEWT_ID="$REPLY"

  prompt_secret "Newt secret"
  NEWT_SECRET="$REPLY"
}

# ─── SSH hardening (optional, called after key-based auth is confirmed) ─────────
#
# pangolin_harden_ssh <vps_ip> <ssh_user> [--disable-password-auth]
#
# Call this AFTER confirming SSH key access works, to optionally disable passwords
#
pangolin_harden_ssh() {
  local disable_pw="${1:---keep-password}"

  log_step "SSH Hardening"

  _pang_ssh "bash -s" << 'SSH_HARDEN'
set -euo pipefail

# Backup sshd_config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d)

# Settings to apply
declare -A SETTINGS=(
  ["MaxAuthTries"]="3"
  ["LoginGraceTime"]="30"
  ["X11Forwarding"]="no"
  ["AllowTcpForwarding"]="yes"
  ["PermitEmptyPasswords"]="no"
)

for key in "${!SETTINGS[@]}"; do
  val="${SETTINGS[$key]}"
  if grep -qE "^#?${key}" /etc/ssh/sshd_config; then
    sed -i "s|^#\?${key}.*|${key} ${val}|" /etc/ssh/sshd_config
  else
    echo "${key} ${val}" >> /etc/ssh/sshd_config
  fi
done

echo "[OK] SSH settings hardened"
SSH_HARDEN
  log_ok "Basic SSH hardening applied"

  if [[ "$disable_pw" == "--disable-password-auth" ]]; then
    log_sub "Disabling SSH password authentication..."
    _pang_ssh "bash -s" << 'DISABLE_PW'
sed -i 's|^#\?PasswordAuthentication.*|PasswordAuthentication no|' /etc/ssh/sshd_config
sed -i 's|^#\?ChallengeResponseAuthentication.*|ChallengeResponseAuthentication no|' /etc/ssh/sshd_config
sed -i 's|^#\?PermitRootLogin.*|PermitRootLogin prohibit-password|' /etc/ssh/sshd_config
systemctl reload sshd && echo "[OK] Password auth disabled — key-only access enforced"
DISABLE_PW
    log_ok "SSH password authentication disabled"
    log_warn "Make sure your SSH key is in ~/.ssh/authorized_keys on the VPS!"
  fi
}

# ─── Copy SSH public key to VPS (when connecting via password) ─────────────────
#
# pangolin_copy_ssh_key <public_key_path>
#
pangolin_copy_ssh_key() {
  local pub_key_path="${1:-$HOME/.ssh/id_rsa.pub}"

  if [[ ! -f "$pub_key_path" ]]; then
    log_warn "SSH public key not found: $pub_key_path"
    if prompt_yn "Generate a new SSH key pair now?" "Y"; then
      local key_path="${pub_key_path%.pub}"
      ssh-keygen -t ed25519 -f "$key_path" -N "" -C "homelab-$(hostname)" \
        >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1
      pub_key_path="${key_path}.pub"
      log_ok "SSH key pair created: $key_path"
    else
      return 1
    fi
  fi

  local pub_key_content
  pub_key_content=$(cat "$pub_key_path")

  log_sub "Copying SSH public key to VPS..."
  _pang_ssh "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\n' '${pub_key_content}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo OK"
  log_ok "SSH public key installed on VPS"
  log_info "Key file: ${pub_key_path%.pub}"
}

# ─── Setup Newt locally ────────────────────────────────────────────────────────
#
# pangolin_setup_newt <newt_id> <newt_secret> <pangolin_host> <compose_file>
#
# Appends (or updates) the newt service in the local docker-compose file
#
pangolin_setup_newt() {
  local newt_id="$1"
  local newt_secret="$2"
  local pangolin_host="$3"
  local compose_file="$4"

  log_sub "Configuring Newt tunnel client..."

  # Check if newt service already exists in compose
  if grep -q "container_name: newt" "$compose_file" 2>/dev/null; then
    log_sub "Newt service already present — updating credentials..."
    sed -i "s|NEWT_ID=.*|NEWT_ID=${newt_id}|g" "$compose_file"
    sed -i "s|NEWT_SECRET=.*|NEWT_SECRET=${newt_secret}|g" "$compose_file"
    sed -i "s|PANGOLIN_ENDPOINT=.*|PANGOLIN_ENDPOINT=https://${pangolin_host}|g" "$compose_file"
    return 0
  fi

  # Append newt service to compose file
  cat >> "$compose_file" <<EOF

  ########## PANGOLIN TUNNEL ##########
  newt:
    image: fosrl/newt:latest
    container_name: newt
    restart: unless-stopped
    environment:
      - PANGOLIN_ENDPOINT=https://${pangolin_host}
      - NEWT_ID=${newt_id}
      - NEWT_SECRET=${newt_secret}
    networks:
      - socket_proxy
EOF

  log_ok "Newt service added to compose file"
}

# ─── Register a resource in Pangolin ──────────────────────────────────────────
#
# pangolin_register_resource <app_name> <subdomain> <service_port> <internal_port>
#   Returns: resource row ID via stdout, 0 on success
#
pangolin_register_resource() {
  local app_name="$1"
  local subdomain="$2"
  local service_port="$3"      # The app's actual service port (inside docker)
  local internal_port="$4"     # The pangolin tunnel internal port (65400+)

  local vps_host ssh_user ssh_key ssh_auth ssh_pass server_ip domain site_id
  vps_host=$(state_get '.tunnel.pangolin.vps_host')
  ssh_user=$(state_get '.tunnel.pangolin.ssh_user')
  ssh_auth=$(state_get '.tunnel.pangolin.ssh_auth')
  ssh_key=$(state_get '.tunnel.pangolin.ssh_key')
  ssh_pass=$(state_get '.tunnel.pangolin.ssh_pass')
  server_ip=$(state_get '.server_ip')
  domain=$(state_get '.domain')
  site_id=$(state_get '.tunnel.pangolin.site_id')

  [[ -n "$vps_host" ]]  || die "Pangolin VPS host not in state"
  [[ -n "$site_id" ]]   || die "Pangolin site_id not in state"
  [[ -n "$server_ip" ]] || die "Server IP not in state"

  ssh_user="${ssh_user:-root}"
  ssh_auth="${ssh_auth:-key}"
  ssh_key="${ssh_key:-$HOME/.ssh/id_rsa}"

  local fqdn="${subdomain}.${domain}"

  # Initialize connection using state (if not already initialized this session)
  if [[ -z "$_PANG_VPS_HOST" || "$_PANG_VPS_HOST" != "$vps_host" ]]; then
    if [[ "$ssh_auth" == "password" ]]; then
      _pang_init_connection "$vps_host" "$ssh_user" "password" "$ssh_pass"
    else
      _pang_init_connection "$vps_host" "$ssh_user" "key" "$ssh_key"
    fi
  fi

  log_sub "Registering Pangolin resource: $app_name → $fqdn (tunnel port $internal_port)"

  # Copy the script to the VPS, run it inside the pangolin container
  _pang_scp_to "$ADD_RESOURCE_SCRIPT" "/tmp/add_resource.cjs" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 \
    || die "Could not copy add_resource.cjs to VPS"

  local resource_id
  resource_id=$(_pang_ssh \
    "docker cp /tmp/add_resource.cjs pangolin:/tmp/add_resource.cjs && \
     docker exec pangolin node /tmp/add_resource.cjs \
       --site-id '${site_id}' \
       --name '${app_name}' \
       --subdomain '${fqdn}' \
       --http-port '${internal_port}' \
       --target-port '${service_port}' \
       --target-host '${server_ip}'" 2>/tmp/homelab-pangolin-err.log)

  if [[ -z "$resource_id" || ! "$resource_id" =~ ^[0-9]+$ ]]; then
    log_error "Pangolin resource registration failed"
    log_error "stderr: $(cat /tmp/homelab-pangolin-err.log 2>/dev/null)"
    return 1
  fi

  log_ok "Pangolin resource registered: $app_name (ID: $resource_id, tunnel port: $internal_port)"
  echo "$resource_id"
}

# ─── Remove a resource from Pangolin ──────────────────────────────────────────

pangolin_remove_resource() {
  local resource_id="$1"

  local vps_host ssh_user ssh_auth ssh_key ssh_pass
  vps_host=$(state_get '.tunnel.pangolin.vps_host')
  ssh_user=$(state_get '.tunnel.pangolin.ssh_user')
  ssh_auth=$(state_get '.tunnel.pangolin.ssh_auth')
  ssh_key=$(state_get '.tunnel.pangolin.ssh_key')
  ssh_pass=$(state_get '.tunnel.pangolin.ssh_pass')
  ssh_user="${ssh_user:-root}"
  ssh_auth="${ssh_auth:-key}"
  ssh_key="${ssh_key:-$HOME/.ssh/id_rsa}"

  [[ -n "$vps_host" ]]    || die "Pangolin VPS host not in state"
  [[ -n "$resource_id" ]] || die "resource_id is required"

  if [[ -z "$_PANG_VPS_HOST" || "$_PANG_VPS_HOST" != "$vps_host" ]]; then
    if [[ "$ssh_auth" == "password" ]]; then
      _pang_init_connection "$vps_host" "$ssh_user" "password" "$ssh_pass"
    else
      _pang_init_connection "$vps_host" "$ssh_user" "key" "$ssh_key"
    fi
  fi

  log_sub "Removing Pangolin resource ID: $resource_id"

  _pang_ssh "docker exec pangolin node -e \"
    const Database = require('better-sqlite3');
    const db = new Database('/app/config/db.sqlite3');
    const result = db.prepare('DELETE FROM resources WHERE rowid = ?').run(${resource_id});
    console.log(result.changes > 0 ? 'deleted' : 'not_found');
    db.close();
  \"" 2>/tmp/homelab-pangolin-err.log

  log_ok "Pangolin resource $resource_id removed"
}

# ─── Restart Pangolin after changes ───────────────────────────────────────────

pangolin_restart() {
  local vps_host ssh_user ssh_auth ssh_key ssh_pass
  vps_host=$(state_get '.tunnel.pangolin.vps_host')
  ssh_user=$(state_get '.tunnel.pangolin.ssh_user')
  ssh_auth=$(state_get '.tunnel.pangolin.ssh_auth')
  ssh_key=$(state_get '.tunnel.pangolin.ssh_key')
  ssh_pass=$(state_get '.tunnel.pangolin.ssh_pass')
  ssh_user="${ssh_user:-root}"
  ssh_auth="${ssh_auth:-key}"
  [[ -n "$vps_host" ]] || return 0

  if [[ -z "$_PANG_VPS_HOST" || "$_PANG_VPS_HOST" != "$vps_host" ]]; then
    if [[ "$ssh_auth" == "password" ]]; then
      _pang_init_connection "$vps_host" "$ssh_user" "password" "$ssh_pass"
    else
      _pang_init_connection "$vps_host" "$ssh_user" "key" "${ssh_key:-$HOME/.ssh/id_rsa}"
    fi
  fi

  log_sub "Restarting Pangolin on VPS..."
  _pang_ssh "cd /opt/pangolin && docker compose restart pangolin" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 && log_ok "Pangolin restarted"
}

# ─── Restart local Newt ────────────────────────────────────────────────────────

pangolin_restart_newt() {
  local dockerdir hostname compose_file
  dockerdir=$(state_get '.dockerdir')
  hostname=$(state_get '.hostname')
  compose_file="${dockerdir}/docker-compose-${hostname}.yml"

  if [[ -f "$compose_file" ]] && grep -q "container_name: newt" "$compose_file" 2>/dev/null; then
    log_sub "Restarting Newt..."
    docker compose -f "$compose_file" restart newt >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 \
      && log_ok "Newt restarted"
  fi
}

# ─── Port allocation ────────────────────────────────────────────────────────────

pangolin_alloc_port() {
  pangolin_next_port  # from state.sh — increments and returns current
}

# ─── Interactive wizard: existing Pangolin ─────────────────────────────────────

pangolin_wizard_existing() {
  log_step "Connecting to Existing Pangolin Instance"

  prompt_input "Pangolin VPS hostname or IP" ""
  PANGOLIN_VPS_HOST="$REPLY"

  _pang_prompt_ssh_credentials

  prompt_input "Pangolin organization ID" ""
  PANGOLIN_ORG_ID="$REPLY"

  prompt_input "Pangolin site ID (integer)" ""
  PANGOLIN_SITE_ID="$REPLY"
  [[ "$PANGOLIN_SITE_ID" =~ ^[0-9]+$ ]] || die "Site ID must be a number"

  prompt_input "Newt client ID" ""
  NEWT_ID="$REPLY"
  prompt_secret "Newt secret"
  NEWT_SECRET="$REPLY"
}

# ─── Interactive wizard: fresh Pangolin install ────────────────────────────────
#
# Sets: PANGOLIN_VPS_HOST, PANGOLIN_SSH_USER, PANGOLIN_SSH_AUTH, PANGOLIN_SSH_KEY
#       PANGOLIN_ORG_ID, PANGOLIN_SITE_ID, NEWT_ID, NEWT_SECRET
#
pangolin_wizard_fresh() {
  log_step "Setting Up Pangolin on a Fresh VPS"

  echo -e "  ${DIM}You need a VPS with a public IP and your domain's DNS pointed to it.${RESET}"
  echo -e "  ${DIM}Any VPS with 1 vCPU / 512 MB RAM and a public IP will work (~\$18-24/year).${RESET}"
  echo ""

  # ── VPS connection details ──────────────────────────────────────────────────
  prompt_input "VPS public IP address" ""
  local vps_ip="$REPLY"
  validate_ip "$vps_ip" || die "Invalid IP address: $vps_ip"

  prompt_input "SSH port" "22"
  local ssh_port="$REPLY"

  _pang_prompt_ssh_credentials
  local ssh_auth="$PANGOLIN_SSH_AUTH"
  local ssh_user="$PANGOLIN_SSH_USER"
  local key_or_pass
  if [[ "$ssh_auth" == "key" ]]; then
    key_or_pass="$PANGOLIN_SSH_KEY"
  else
    key_or_pass="$PANGOLIN_SSH_PASS"
  fi

  # ── Initialize connection ───────────────────────────────────────────────────
  _pang_init_connection "$vps_ip" "$ssh_user" "$ssh_auth" "$key_or_pass" "$ssh_port"

  log_sub "Testing SSH connection..."
  if ! _pang_test_connection; then
    die "Cannot connect to ${ssh_user}@${vps_ip}:${ssh_port}. Check credentials and firewall."
  fi
  log_ok "SSH connection successful"

  # ── Pangolin domain ─────────────────────────────────────────────────────────
  local domain
  domain=$(state_get '.domain')

  prompt_input "Hostname for Pangolin dashboard (DNS must point to VPS)" "pangolin.${domain}"
  local pangolin_domain="$REPLY"

  prompt_input "Email for Let's Encrypt TLS certificates" ""
  local acme_email="$REPLY"
  [[ -n "$acme_email" ]] || die "ACME email is required for TLS certificates"

  # ── Admin credentials for Pangolin dashboard ────────────────────────────────
  echo ""
  log_info "These credentials will be used to log into the Pangolin dashboard."
  prompt_input "Pangolin admin email" "$acme_email"
  local admin_email="$REPLY"
  prompt_secret "Pangolin admin password (min 8 chars)"
  local admin_password="$REPLY"
  [[ ${#admin_password} -ge 8 ]] || die "Password must be at least 8 characters"

  # ── Organization and site names ─────────────────────────────────────────────
  prompt_input "Organization name (short, no spaces)" "homelab"
  local org_name="$REPLY"

  local hostname
  hostname=$(state_get '.hostname')
  prompt_input "Site name (your server name)" "${hostname:-homeserver}"
  local site_name="$REPLY"

  PANGOLIN_VPS_HOST="$vps_ip"

  # ── Optional: copy SSH key to VPS (if connecting via password) ──────────────
  if [[ "$ssh_auth" == "password" ]]; then
    echo ""
    log_info "You're connecting via password. SSH keys are more secure."
    if prompt_yn "Copy an SSH key to the VPS for future access?" "Y"; then
      prompt_input "Path to SSH public key" "$HOME/.ssh/id_rsa.pub"
      pangolin_copy_ssh_key "$REPLY"
    fi
  fi

  # ── Install Pangolin ────────────────────────────────────────────────────────
  pangolin_install_vps "$vps_ip" "$ssh_user" "$ssh_auth" "$key_or_pass" "$pangolin_domain" "$acme_email"

  # ── Create admin user, org, and site ───────────────────────────────────────
  pangolin_setup_admin_and_site "$admin_email" "$admin_password" "$org_name" "$site_name"

  # Validate we got the credentials
  if [[ -z "${PANGOLIN_SITE_ID:-}" || -z "${NEWT_ID:-}" || -z "${NEWT_SECRET:-}" ]]; then
    log_warn "Could not obtain Newt credentials automatically."
    _pang_prompt_manual_credentials
  fi

  # ── Save everything to state ────────────────────────────────────────────────
  state_set "
    .tunnel.method = \"pangolin\" |
    .tunnel.pangolin.enabled = true |
    .tunnel.pangolin.vps_host = \"${vps_ip}\" |
    .tunnel.pangolin.domain = \"${pangolin_domain}\" |
    .tunnel.pangolin.org_id = \"${PANGOLIN_ORG_ID:-}\" |
    .tunnel.pangolin.site_id = ${PANGOLIN_SITE_ID:-0} |
    .tunnel.pangolin.newt_id = \"${NEWT_ID:-}\" |
    .tunnel.pangolin.newt_secret = \"${NEWT_SECRET:-}\" |
    .tunnel.pangolin.ssh_user = \"${ssh_user}\" |
    .tunnel.pangolin.ssh_auth = \"${ssh_auth}\" |
    .tunnel.pangolin.ssh_key = \"${key_or_pass}\" |
    .tunnel.pangolin.admin_email = \"${admin_email}\"
  "

  # If connecting via password, don't store the password in plaintext
  if [[ "$ssh_auth" == "password" ]]; then
    state_set ".tunnel.pangolin.ssh_key = \"\""
    state_set ".tunnel.pangolin.ssh_pass = \"\""
    log_warn "Note: SSH password not saved to state. Set up SSH key access for future management."
  fi

  log_ok "Pangolin setup complete"
  echo ""
  echo -e "  ${BOLD}Dashboard:${RESET} https://${pangolin_domain}"
  echo -e "  ${BOLD}Admin:${RESET}     ${admin_email}"
  echo -e "  ${BOLD}Org ID:${RESET}    ${PANGOLIN_ORG_ID:-manual}"
  echo -e "  ${BOLD}Site ID:${RESET}   ${PANGOLIN_SITE_ID:-manual}"
  echo ""

  _pangolin_crowdsec_tip "$vps_ip" "$pangolin_domain"
}

#
# _pangolin_crowdsec_tip — post-setup tip for adding CrowdSec to the Pangolin VPS
# Called after Pangolin install completes. Non-blocking — just prints guidance.
#
_pangolin_crowdsec_tip() {
  local vps_ip="$1"
  local pangolin_domain="$2"

  cat <<EOF

  ${BOLD}${BLUE}── Optional: CrowdSec on your Pangolin VPS ──${RESET}

  Your Pangolin VPS is the real public-facing entry point — ${BOLD}this${RESET} is where
  CrowdSec should run, not your home server. It sees real attacker IPs and
  can block them before traffic ever enters the tunnel.

  Pangolin already runs Traefik internally, so CrowdSec integrates naturally.

  ${BOLD}To add CrowdSec to your Pangolin VPS:${RESET}

  1. SSH into your VPS:
     ${CYAN}ssh ${_PANG_SSH_USER:-root}@${vps_ip}${RESET}

  2. Add CrowdSec to the Pangolin compose:
     ${CYAN}cd /opt/pangolin${RESET}

     Add to docker-compose.yml:
     ${DIM}crowdsec:
       image: crowdsecurity/crowdsec:latest
       restart: unless-stopped
       volumes:
         - /opt/pangolin/logs:/logs:ro
         - /var/log:/var/log:ro
         - crowdsec_data:/var/lib/crowdsec/data
         - crowdsec_config:/etc/crowdsec
       environment:
         - COLLECTIONS=crowdsecurity/traefik crowdsecurity/http-cve crowdsecurity/linux
     traefik-bouncer:
       image: fbonalair/traefik-crowdsec-bouncer:latest
       restart: unless-stopped
       environment:
         - CROWDSEC_BOUNCER_API_KEY=\${CROWDSEC_BOUNCER_API_KEY}
         - CROWDSEC_AGENT_HOST=crowdsec:8080${RESET}

  3. Generate the bouncer key and wire it in:
     ${CYAN}docker compose up -d crowdsec
     docker exec crowdsec cscli bouncers add traefik-bouncer${RESET}
     Then add the key to your .env and restart traefik-bouncer.

  4. Add the bouncer middleware to Pangolin's Traefik dynamic config.

  ${DIM}Skip this if you're using Cloudflare as your tunnel — Cloudflare's WAF
  already provides equivalent (and better) edge protection for free.${RESET}

EOF
}

# ─── Prompt for SSH credentials (sets PANGOLIN_SSH_* globals) ─────────────────

_pang_prompt_ssh_credentials() {
  prompt_select "SSH authentication method:" \
    "SSH key (recommended)" \
    "Username and password"

  if [[ "$REPLY" == SSH\ key* ]]; then
    PANGOLIN_SSH_AUTH="key"
    prompt_input "SSH username" "root"
    PANGOLIN_SSH_USER="$REPLY"
    prompt_input "Path to SSH private key" "$HOME/.ssh/id_rsa"
    PANGOLIN_SSH_KEY="$REPLY"
    [[ -f "$PANGOLIN_SSH_KEY" ]] || die "SSH key not found: $PANGOLIN_SSH_KEY"
    PANGOLIN_SSH_PASS=""
  else
    PANGOLIN_SSH_AUTH="password"
    prompt_input "SSH username" "root"
    PANGOLIN_SSH_USER="$REPLY"
    prompt_secret "SSH password"
    PANGOLIN_SSH_PASS="$REPLY"
    PANGOLIN_SSH_KEY=""
  fi
}

# ─── Add all installed apps to Pangolin ───────────────────────────────────────

pangolin_register_all_apps() {
  local apps
  apps=$(app_list_installed)
  [[ -n "$apps" ]] || return 0

  log_step "Registering apps with Pangolin"

  while IFS= read -r app; do
    local subdomain service_port
    subdomain=$(state_get ".apps[\"$app\"].subdomain")
    service_port=$(state_get ".apps[\"$app\"].port")

    local internal_port
    internal_port=$(pangolin_alloc_port)

    local resource_id
    if resource_id=$(pangolin_register_resource "$app" "$subdomain" "$service_port" "$internal_port"); then
      app_state_set_pangolin "$app" "$resource_id" "$internal_port"
    else
      log_warn "Skipping Pangolin registration for $app (retry with: ./manage.sh pangolin add $app)"
    fi
  done <<< "$apps"

  # Restart Pangolin + Newt to pick up new resources
  pangolin_restart
}
