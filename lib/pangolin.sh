#!/usr/bin/env bash
# lib/pangolin.sh — Full Pangolin VPS setup + Newt + resource registration
#
# Based on proven patterns from PANGOLIN_INFRASTRUCTURE.md and THEMEDIA_SETUP.md
# Critical: method must be 'https' and tlsServerName must be set (avoids redirect loop)

[[ -n "$PORTLESS_COMMON_LOADED" ]] || source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
PORTLESS_PANGOLIN_LOADED=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADD_RESOURCE_SCRIPT="${REPO_ROOT}/templates/pangolin/add_resource.cjs"
REPAIR_DB_SCRIPT="${REPO_ROOT}/templates/pangolin/repair_pangolin_db.cjs"
DIAGNOSE_SCRIPT="${REPO_ROOT}/templates/pangolin/diagnose_pangolin.cjs"
FIX_404_SCRIPT="${REPO_ROOT}/templates/pangolin/fix_404.cjs"
VPS_INIT_SCRIPT="${REPO_ROOT}/templates/pangolin/vps-init.sh"
PANGOLIN_COMPOSE_TMPL="${REPO_ROOT}/templates/pangolin/pangolin-compose.yml.tmpl"
PANGOLIN_CONFIG_TMPL="${REPO_ROOT}/templates/pangolin/pangolin-config.yml.tmpl"
PANGOLIN_TRAEFIK_TMPL="${REPO_ROOT}/templates/pangolin/traefik_config.yml.tmpl"
PANGOLIN_DYNAMIC_TMPL="${REPO_ROOT}/templates/pangolin/dynamic_config.yml.tmpl"
PANGOLIN_SETUP_SCRIPT="${REPO_ROOT}/templates/pangolin/setup_pangolin.cjs"

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

# _pang_init_ssh_from_state — initialise connection variables from .portless-state.json
# No-op if already connected to the same host.
_pang_init_ssh_from_state() {
  local vps_host ssh_user ssh_auth ssh_key ssh_pass
  vps_host=$(state_get '.tunnel.pangolin.vps_host')
  ssh_user=$(state_get '.tunnel.pangolin.ssh_user')
  ssh_auth=$(state_get '.tunnel.pangolin.ssh_auth')
  ssh_key=$(state_get '.tunnel.pangolin.ssh_key')
  ssh_pass=$(state_get '.tunnel.pangolin.ssh_pass')
  ssh_user="${ssh_user:-root}"
  ssh_auth="${ssh_auth:-key}"
  ssh_key="${ssh_key:-$HOME/.ssh/id_rsa}"

  [[ -n "$vps_host" ]] || die "Pangolin VPS host not in state"

  if [[ -z "$_PANG_VPS_HOST" || "$_PANG_VPS_HOST" != "$vps_host" ]]; then
    if [[ "$ssh_auth" == "password" ]]; then
      _pang_init_connection "$vps_host" "$ssh_user" "password" "$ssh_pass"
    else
      _pang_init_connection "$vps_host" "$ssh_user" "key" "$ssh_key"
    fi
  fi
}

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

  _pang_scp_to "$VPS_INIT_SCRIPT" "/tmp/portless-vps-init.sh" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 || die "Could not copy init script to VPS"

  local init_output
  init_output=$(_pang_ssh "chmod +x /tmp/portless-vps-init.sh && sudo bash /tmp/portless-vps-init.sh" 2>&1) \
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

  # Generate a random secret for this Pangolin instance (min 32 chars, required)
  # Use openssl only — tr+head triggers pipefail (tr gets SIGPIPE when head closes the pipe)
  local pangolin_secret
  pangolin_secret=$(openssl rand -hex 32)

  # Render templates locally
  local tmp_compose; tmp_compose=$(mktemp /tmp/pangolin-compose.XXXXXX.yml)
  local tmp_config;  tmp_config=$(mktemp /tmp/pangolin-config.XXXXXX.yml)
  local tmp_traefik; tmp_traefik=$(mktemp /tmp/pangolin-traefik.XXXXXX.yml)
  local tmp_dynamic; tmp_dynamic=$(mktemp /tmp/pangolin-dynamic.XXXXXX.yml)

  render_template "$PANGOLIN_COMPOSE_TMPL" "$tmp_compose" \
    "PANGOLIN_DOMAIN=${pangolin_domain}"

  render_template "$PANGOLIN_CONFIG_TMPL" "$tmp_config" \
    "PANGOLIN_DOMAIN=${pangolin_domain}" \
    "BASE_DOMAIN=${base_domain}" \
    "ACME_EMAIL=${acme_email}" \
    "SECRET=${pangolin_secret}"

  render_template "$PANGOLIN_TRAEFIK_TMPL" "$tmp_traefik" \
    "ACME_EMAIL=${acme_email}"

  render_template "$PANGOLIN_DYNAMIC_TMPL" "$tmp_dynamic" \
    "PANGOLIN_DOMAIN=${pangolin_domain}"

  # Upload to VPS — use sudo for /opt, then chown so the SSH user can write directly
  _pang_ssh "sudo mkdir -p /opt/pangolin/config/letsencrypt /opt/pangolin/config/traefik/logs && sudo chown -R \$(id -u):\$(id -g) /opt/pangolin" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 \
    || die "Could not create /opt/pangolin on VPS (sudo required)"

  _pang_scp_to "$tmp_compose" "/opt/pangolin/docker-compose.yml" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 || die "Could not upload Pangolin compose file"

  _pang_scp_to "$tmp_config" "/opt/pangolin/config/config.yml" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 || die "Could not upload Pangolin config file"

  _pang_scp_to "$tmp_traefik" "/opt/pangolin/config/traefik/traefik_config.yml" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 || die "Could not upload Traefik config file"

  _pang_scp_to "$tmp_dynamic" "/opt/pangolin/config/traefik/dynamic_config.yml" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 || die "Could not upload Traefik dynamic config file"

  # Set correct permissions on acme.json (Traefik requirement)
  _pang_ssh "touch /opt/pangolin/config/letsencrypt/acme.json && chmod 600 /opt/pangolin/config/letsencrypt/acme.json" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1

  rm -f "$tmp_compose" "$tmp_config" "$tmp_traefik" "$tmp_dynamic"

  # Start the stack — use sudo for docker in case the user's group membership hasn't refreshed
  log_sub "Starting Pangolin stack (docker compose up -d)..."
  _pang_ssh "cd /opt/pangolin && sudo docker compose pull -q 2>/dev/null; sudo docker compose up -d" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 \
    || die "Failed to start Pangolin stack — check ${LOG_FILE:-/tmp/portless-install.log}"
  log_ok "Pangolin stack started"

  # ── 4. Wait for Pangolin API ──────────────────────────────────────────────────
  log_sub "Waiting for Pangolin API to be ready (up to 120s)..."

  # Use a SSH ControlMaster socket so all polls share one connection.
  # If the socket drops we detect it and re-open before the next poll.
  local ctrl_sock elapsed ready ping_result
  ctrl_sock=$(mktemp -u "/tmp/portless-ctrl-XXXXXX")
  elapsed=0
  ready=false

  # Open the persistent master connection
  # shellcheck disable=SC2086
  _pang_ctrl_open() {
    ssh $_PANG_SSH_BASE_OPTS \
        -o ControlMaster=yes -o ControlPath="$ctrl_sock" -o ControlPersist=150s \
        "${_PANG_SSH_USER}@${_PANG_VPS_HOST}" "true" &>/dev/null || true
  }
  _pang_ctrl_open

  while [[ $elapsed -lt 120 ]]; do
    printf "  [%3ds] checking Pangolin API...\r" "$elapsed" >&2

    # Re-open master if it went away (VPS reboot, network blip, etc.)
    if ! ssh -O check -S "$ctrl_sock" "${_PANG_SSH_USER}@${_PANG_VPS_HOST}" &>/dev/null; then
      printf "  [%3ds] SSH disconnected — reconnecting...\r" "$elapsed" >&2
      _pang_ctrl_open
    fi

    # Poll the API through the multiplexed socket
    ping_result=$(ssh -S "$ctrl_sock" \
        "${_PANG_SSH_USER}@${_PANG_VPS_HOST}" \
        "curl -sf --max-time 5 http://localhost:3001/api/v1/ 2>/dev/null || echo FAIL") || true

    if [[ -n "$ping_result" && "$ping_result" != "FAIL" ]]; then
      ready=true
      break
    fi

    # Every 30s print live container status so the user can see what's happening
    if (( elapsed > 0 && elapsed % 30 == 0 )); then
      printf "\r\033[K" >&2
      log_sub "Still waiting (${elapsed}s) — container status:"
      ssh -S "$ctrl_sock" "${_PANG_SSH_USER}@${_PANG_VPS_HOST}" \
          "cd /opt/pangolin && sudo docker compose ps 2>/dev/null" \
          2>/dev/null | while IFS= read -r line; do
            echo -e "  ${DIM}${line}${RESET}"
          done || true
    fi

    sleep 5
    elapsed=$(( elapsed + 5 ))
  done

  # Tear down the control socket cleanly
  ssh -O exit -S "$ctrl_sock" "${_PANG_SSH_USER}@${_PANG_VPS_HOST}" &>/dev/null || true
  rm -f "$ctrl_sock"
  printf "\r\033[K" >&2

  if [[ "$ready" == "true" ]]; then
    log_ok "Pangolin API is ready (${elapsed}s)"
  else
    log_warn "Pangolin API not responding after ${elapsed}s — container logs:"
    local container_logs
    container_logs=$(_pang_ssh \
        "cd /opt/pangolin && sudo docker compose logs --tail=30 pangolin 2>/dev/null") || true
    if [[ -n "$container_logs" ]]; then
      echo "$container_logs" | while IFS= read -r line; do
        echo -e "  ${DIM}${line}${RESET}"
      done
    fi
    log_warn "Continuing — setup will attempt API calls. To check the VPS manually:"
    log_warn "  ssh ${_PANG_SSH_USER:-root}@${vps_ip} 'cd /opt/pangolin && sudo docker compose ps'"
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
# Implementation notes (see docs/pangolin-api-database.md for full reference):
#   - Admin creation uses the one-time setup token via the external API (port 3000)
#   - Org + site creation also go through the external API, running inside the container
#     via docker exec (avoids CSRF and network port issues — port 3000 is only reachable
#     from inside the Docker network, not from the VPS host)
#   - We pre-generate newtId and newtSecret; Pangolin hashes the secret with Argon2
#   - Falls back to manual credential entry if any API call fails
#
pangolin_setup_admin_and_site() {
  local admin_email="$1"
  local admin_password="$2"
  local org_name="$3"
  local site_name="$4"

  log_step "Configuring Pangolin: admin user, organization, and site"

  # ── Derive org_id (URL-safe slug) ─────────────────────────────────────────────
  # Pattern required by Pangolin: ^[a-z0-9_]+(-[a-z0-9_]+)*$
  local org_id
  org_id=$(printf '%s' "$org_name" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-\|-$//g' \
    | cut -c1-32)
  [[ -n "$org_id" ]] || org_id="portless"

  # ── Generate Newt credentials ──────────────────────────────────────────────────
  # We supply these when creating the site.  Pangolin hashes the secret server-side
  # (Argon2 via oslo@1.2.1) and stores the hash in the 'newt' table.
  # We keep the plaintext secret for the Newt client config.
  # Use openssl only — tr+head triggers pipefail (tr gets SIGPIPE when head closes the pipe)
  local newt_id newt_secret
  newt_id=$(openssl rand -hex 8)     # 16 lowercase hex chars
  newt_secret=$(openssl rand -hex 32) # 64 lowercase hex chars

  # ── Get the one-time setup token from container logs ──────────────────────────
  # Pangolin logs: "=== SETUP TOKEN [GENERATED] ===" then "Token: <32-char-alphanum>"
  log_sub "Getting Pangolin setup token from container logs..."
  local setup_token="" attempts=0
  while [[ -z "$setup_token" && $attempts -lt 10 ]]; do
    setup_token=$(_pang_ssh \
      "sudo docker logs pangolin 2>&1 | grep -i 'Token:' | tail -1 | sed 's/.*[Tt]oken:[[:space:]]*//' | awk '{print \$1}'" \
      2>/dev/null || true)
    setup_token="${setup_token//[[:space:]]/}"
    if [[ -z "$setup_token" ]]; then
      sleep 3
      (( attempts++ )) || true
    fi
  done

  if [[ -z "$setup_token" ]]; then
    log_warn "Could not auto-extract setup token from Pangolin logs"
    log_sub "To find it manually: ssh ${_PANG_SSH_USER}@${_PANG_VPS_HOST} 'sudo docker logs pangolin 2>&1 | grep -i Token'"
    prompt_input "Enter the Pangolin setup token" ""
    setup_token="$REPLY"
    [[ -n "$setup_token" ]] || die "Setup token is required to configure Pangolin"
  fi

  # ── Wait for Pangolin DB schema to be ready ───────────────────────────────────
  # Pangolin creates its SQLite tables on first startup. The health check passes
  # before migrations finish, so we poll until the 'users' table exists.
  # Wait for the CURRENT run's setup token to appear in logs.
  # Docker logs persist across restarts, so we grep for the specific token we extracted —
  # it only appears after migrations complete for THIS container run.
  log_sub "Waiting for Pangolin to finish initializing (migrations + token)..."
  local db_ready=0
  for _attempt in $(seq 1 30); do
    if _pang_ssh \
        "sudo docker logs pangolin 2>&1 | grep -qF '${setup_token}'" \
        2>/dev/null; then
      db_ready=1
      break
    fi
    sleep 3
  done
  if [[ "$db_ready" -eq 0 ]]; then
    die "Pangolin did not finish initializing after 90s. Check: sudo docker logs pangolin"
  fi
  log_ok "Pangolin database ready"

  # ── Build config JSON for the setup script ────────────────────────────────────
  # jq handles escaping of all values (passwords, names with special characters, etc.)
  log_sub "Running automated Pangolin setup (admin → org '${org_id}' → site)..."
  local tmp_cfg
  tmp_cfg=$(mktemp /tmp/pangolin-cfg-XXXXXX.json)

  jq -n \
    --arg email      "$admin_email" \
    --arg password   "$admin_password" \
    --arg setupToken "$setup_token" \
    --arg orgId      "$org_id" \
    --arg orgName    "$org_name" \
    --arg siteName   "$site_name" \
    --arg newtId     "$newt_id" \
    --arg newtSecret "$newt_secret" \
    '{email:$email, password:$password, setupToken:$setupToken,
      orgId:$orgId, orgName:$orgName, siteName:$siteName,
      newtId:$newtId, newtSecret:$newtSecret}' > "$tmp_cfg"

  # ── Upload config JSON and setup script to VPS, copy into container ───────────
  _pang_scp_to "$tmp_cfg" "/tmp/pangolin-cfg.json" \
    >> "${LOG_FILE:-/tmp/portless-install.log}" 2>&1 \
    || { rm -f "$tmp_cfg"; die "Could not upload setup config to VPS"; }
  rm -f "$tmp_cfg"

  _pang_scp_to "$PANGOLIN_SETUP_SCRIPT" "/tmp/pangolin-setup.cjs" \
    >> "${LOG_FILE:-/tmp/portless-install.log}" 2>&1 \
    || die "Could not upload Pangolin setup script to VPS"

  # Copy into /app inside the container (not /tmp) so Node can resolve
  # require('better-sqlite3') and import('oslo/password') from /app/node_modules
  _pang_ssh \
    "sudo docker cp /tmp/pangolin-cfg.json pangolin:/tmp/pangolin-cfg.json && \
     sudo docker cp /tmp/pangolin-setup.cjs pangolin:/app/pangolin-setup.cjs && \
     rm -f /tmp/pangolin-cfg.json /tmp/pangolin-setup.cjs" \
    >> "${LOG_FILE:-/tmp/portless-install.log}" 2>&1 \
    || die "Could not copy setup files into Pangolin container"

  local api_result
  api_result=$(_pang_ssh \
    "sudo docker exec pangolin node /app/pangolin-setup.cjs /tmp/pangolin-cfg.json 2>&1" \
    2>/dev/null) || true

  echo "$api_result" >> "${LOG_FILE:-/tmp/portless-install.log}"

  # Clean up
  _pang_ssh \
    "sudo docker exec pangolin rm -f /app/pangolin-setup.cjs /tmp/pangolin-cfg.json 2>/dev/null; true" \
    >> "${LOG_FILE:-/tmp/portless-install.log}" 2>&1 || true

  # ── Parse result ──────────────────────────────────────────────────────────────
  if echo "$api_result" | grep -q "SETUP_RESULT"; then
    local result_line
    result_line=$(echo "$api_result" | grep "SETUP_RESULT")
    PANGOLIN_ORG_ID=$(echo "$result_line"  | grep -o 'org_id=[^ ]*'    | cut -d= -f2)
    PANGOLIN_SITE_ID=$(echo "$result_line" | grep -o 'site_id=[^ ]*'   | cut -d= -f2)
    PANGOLIN_ROLE_ID=$(echo "$result_line" | grep -o 'role_id=[^ ]*'   | cut -d= -f2)
    NEWT_ID=$(echo "$result_line"          | grep -o 'newt_id=[^ ]*'   | cut -d= -f2)
    NEWT_SECRET=$(echo "$result_line"      | grep -o 'newt_secret=[^ ]*' | cut -d= -f2)
    log_ok "Pangolin configured: org=${PANGOLIN_ORG_ID} site=${PANGOLIN_SITE_ID} role=${PANGOLIN_ROLE_ID:-?}"

    # Run the repair script immediately after setup to ensure all access tables are correct
    log_sub "Verifying database access grants..."
    pangolin_repair_db "${admin_email}" || true
  else
    log_warn "Automated Pangolin DB setup failed. Error output:"
    echo "$api_result" | head -20 | while IFS= read -r line; do
      [[ -n "$line" ]] && echo -e "  ${DIM}${line}${RESET}"
    done
    echo ""
    log_warn "Manual setup required. Complete these steps in your browser:"
    echo ""
    echo -e "  ${BOLD}1. Open:${RESET} ${CYAN}https://${PANGOLIN_DOMAIN}/auth/initial-setup${RESET}"
    echo ""
    if [[ -n "${setup_token:-}" ]]; then
      echo -e "  ${BOLD}2. Setup token:${RESET} ${CYAN}${setup_token}${RESET}"
    else
      echo -e "  ${BOLD}2. Get setup token:${RESET}"
      echo -e "     ${DIM}ssh ${_PANG_SSH_USER}@${_PANG_VPS_HOST} 'sudo docker logs pangolin 2>&1 | grep -i Token'${RESET}"
    fi
    echo ""
    echo -e "  ${BOLD}3.${RESET} Create admin account  →  email: ${CYAN}${admin_email}${RESET}"
    echo -e "  ${BOLD}4.${RESET} Create organization   →  name:  ${CYAN}${org_name}${RESET}   id: ${CYAN}${org_id}${RESET}"
    echo -e "  ${BOLD}5.${RESET} Create site           →  type: Newt,  name: ${CYAN}${site_name}${RESET}"
    echo -e "  ${BOLD}6.${RESET} Copy the Newt credentials shown after site creation"
    echo ""
    _pang_prompt_manual_credentials
  fi
}

# ─── Manual credential fallback ────────────────────────────────────────────────

_pang_prompt_manual_credentials() {
  echo ""
  prompt_input "Pangolin organization ID" ""
  PANGOLIN_ORG_ID="$REPLY"

  # Auto-detect site ID from the DB — users can't see the integer siteId in the Pangolin web UI
  log_sub "Looking up site ID from Pangolin database..."
  local db_sites site_count
  db_sites=$(_pang_ssh \
    "sudo docker exec pangolin node -e \
     'const db=require(\"/app/node_modules/better-sqlite3\")(\"/app/config/db/db.sqlite\");\
      console.log(JSON.stringify(db.prepare(\"SELECT siteId,name FROM sites WHERE orgId=?\").all(\"${PANGOLIN_ORG_ID}\")));'" \
    2>/dev/null || echo "[]")
  site_count=$(echo "$db_sites" | jq 'length' 2>/dev/null || echo "0")

  if [[ "$site_count" -eq 1 ]]; then
    PANGOLIN_SITE_ID=$(echo "$db_sites" | jq -r '.[0].siteId')
    local found_name
    found_name=$(echo "$db_sites" | jq -r '.[0].name')
    log_ok "Found site '${found_name}' → site ID: ${PANGOLIN_SITE_ID}"
  elif [[ "$site_count" -gt 1 ]]; then
    echo "  Found multiple sites in org '${PANGOLIN_ORG_ID}':"
    echo "$db_sites" | jq -r '.[] | "  [\(.siteId)] \(.name)"'
    prompt_input "Enter the site ID (number) for this installation" ""
    PANGOLIN_SITE_ID="$REPLY"
  else
    log_warn "Could not auto-detect site ID from database. Enter it manually."
    log_sub "Run this to find it: ssh ${_PANG_SSH_USER}@${_PANG_VPS_HOST} \"sudo docker exec pangolin node -e 'const db=require(\\\"/app/node_modules/better-sqlite3\\\")(\\\"/app/config/db/db.sqlite\\\"); console.log(JSON.stringify(db.prepare(\\\"SELECT siteId,name FROM sites\\\").all()));'\""
    prompt_input "Pangolin site ID (integer)" ""
    PANGOLIN_SITE_ID="$REPLY"
  fi

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
      ssh-keygen -t ed25519 -f "$key_path" -N "" -C "portless-$(hostname)" \
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

  log_sub "Registering Pangolin resource: $app_name → $fqdn (tunnel port $internal_port)" >&2

  # Copy the script to the VPS, run it inside the pangolin container
  _pang_scp_to "$ADD_RESOURCE_SCRIPT" "/tmp/add_resource.cjs" \
    >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 \
    || die "Could not copy add_resource.cjs to VPS"

  local resource_id
  resource_id=$(_pang_ssh \
    "sudo docker cp /tmp/add_resource.cjs pangolin:/app/add_resource.cjs && \
     sudo docker exec pangolin node /app/add_resource.cjs \
       --site-id '${site_id}' \
       --name '${app_name}' \
       --subdomain '${fqdn}' \
       --http-port '${internal_port}' \
       --target-port '${service_port}' \
       --target-host '${server_ip}' && \
     sudo docker exec pangolin rm -f /app/add_resource.cjs && \
     rm -f /tmp/add_resource.cjs" 2>/tmp/portless-pangolin-err.log)

  if [[ -z "$resource_id" || ! "$resource_id" =~ ^[0-9]+$ ]]; then
    log_error "Pangolin resource registration failed" >&2
    log_error "stderr: $(cat /tmp/portless-pangolin-err.log 2>/dev/null)" >&2
    return 1
  fi

  log_ok "Pangolin resource registered: $app_name (ID: $resource_id, tunnel port: $internal_port)" >&2
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

  _pang_ssh "sudo docker exec pangolin node -e \"
    const Database = require('/app/node_modules/better-sqlite3');
    const db = new Database('/app/config/db/db.sqlite');
    const result = db.prepare('DELETE FROM resources WHERE rowid = ?').run(${resource_id});
    console.log(result.changes > 0 ? 'deleted' : 'not_found');
    db.close();
  \"" 2>/tmp/portless-pangolin-err.log

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
  _pang_ssh "cd /opt/pangolin && sudo docker compose restart pangolin" \
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

  # ── Non-root user recommendation ────────────────────────────────────────────
  if [[ "$ssh_user" == "root" ]]; then
    echo ""
    log_warn "You are connected as root. Running services as root is a security risk."
    log_info "Best practice: create a dedicated sudo user for all operations."
    if prompt_yn "Create a non-root sudo user on the VPS now?" "Y"; then
      prompt_input "New username" "deploy"
      local new_vps_user="$REPLY"
      new_vps_user="${new_vps_user//[^a-z0-9_-]/}"   # sanitize
      [[ -n "$new_vps_user" ]] || new_vps_user="deploy"

      log_sub "Creating user '${new_vps_user}' on VPS..."
      _pang_ssh "bash -s" << USERADD_SCRIPT
set -e
# Create user if not already there
if ! id '${new_vps_user}' &>/dev/null; then
  useradd -m -s /bin/bash '${new_vps_user}'
fi
# Add to sudo group
usermod -aG sudo '${new_vps_user}'
# Grant passwordless sudo (needed for Docker management + installer)
echo '${new_vps_user} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-portless-${new_vps_user}
chmod 440 /etc/sudoers.d/90-portless-${new_vps_user}
# Copy root's authorized_keys so the same SSH key works for this user
mkdir -p /home/${new_vps_user}/.ssh
cp /root/.ssh/authorized_keys /home/${new_vps_user}/.ssh/authorized_keys 2>/dev/null || true
chmod 700 /home/${new_vps_user}/.ssh
chmod 600 /home/${new_vps_user}/.ssh/authorized_keys
chown -R ${new_vps_user}:${new_vps_user} /home/${new_vps_user}/.ssh
echo "USER_CREATED"
USERADD_SCRIPT

      # Test that the new user can SSH in
      log_sub "Testing SSH as '${new_vps_user}'..."
      local old_user="$ssh_user"
      _pang_init_connection "$vps_ip" "$new_vps_user" "$ssh_auth" "$key_or_pass" "$ssh_port"
      if _pang_test_connection; then
        log_ok "SSH as '${new_vps_user}' confirmed — switching to new user"
        ssh_user="$new_vps_user"
        log_sub "Disabling root SSH login for security..."
        _pang_ssh "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && systemctl reload sshd && echo OK" \
          >> "${LOG_FILE:-/tmp/portless-install.log}" 2>&1 || \
          log_warn "Could not disable root login — do it manually: PermitRootLogin no in /etc/ssh/sshd_config"
        log_ok "Root SSH login disabled"
      else
        log_warn "Could not SSH as '${new_vps_user}' — falling back to root for this install"
        _pang_init_connection "$vps_ip" "$old_user" "$ssh_auth" "$key_or_pass" "$ssh_port"
      fi
    fi
    echo ""
  fi

  # ── Pangolin domain ─────────────────────────────────────────────────────────
  local domain
  domain=$(state_get '.domain')

  prompt_input "Hostname for Pangolin dashboard (DNS must point to VPS)" "pangolin.${domain}"
  local pangolin_domain="$REPLY"

  prompt_input "Email for Let's Encrypt TLS certificates" ""
  local acme_email="$REPLY"
  [[ -n "$acme_email" ]] || die "ACME email is required for TLS certificates"

  # ── Auto-create Cloudflare DNS A record ─────────────────────────────────────
  # If a CF token is already in state, create pangolin_domain → vps_ip automatically.
  # DNS-only (not proxied) — WireGuard UDP ports need direct IP access.
  local cf_token
  cf_token=$(state_get '.cloudflare_api_token' 2>/dev/null || true)
  if [[ -n "$cf_token" && "$cf_token" != "null" ]]; then
    [[ -n "${PORTLESS_CLOUDFLARE_LOADED:-}" ]] || source "${REPO_ROOT}/lib/cloudflare.sh"
    cf_init "$cf_token"
    if cf_get_zone_id "$domain" > /dev/null 2>&1; then
      cf_upsert_a_record "$pangolin_domain" "$vps_ip" false || \
        log_warn "DNS auto-create failed — add manually: ${pangolin_domain} A ${vps_ip}"
    else
      log_warn "Domain '$domain' not in Cloudflare — add DNS manually: ${pangolin_domain} A ${vps_ip}"
    fi
  else
    log_info "No Cloudflare token in state — add DNS manually: ${pangolin_domain} A ${vps_ip}"
  fi

  # ── Admin credentials for Pangolin dashboard ────────────────────────────────
  echo ""
  log_info "These credentials will be used to log into the Pangolin dashboard."
  prompt_input "Pangolin admin email" "$acme_email"
  local admin_email="$REPLY"
  prompt_secret "Pangolin admin password (min 8 chars)"
  local admin_password="$REPLY"
  [[ ${#admin_password} -ge 8 ]] || die "Password must be at least 8 characters"

  # ── Organization and site names ─────────────────────────────────────────────
  prompt_input "Organization name (short, no spaces)" "portless"
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
    .tunnel.pangolin.site_id = \"${PANGOLIN_SITE_ID:-0}\" |
    .tunnel.pangolin.role_id = \"${PANGOLIN_ROLE_ID:-}\" |
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
  echo -e "  ${BOLD}${YELLOW}Enterprise Edition license (free):${RESET}"
  echo -e "  Get a free key at ${CYAN}https://app.pangolin.net${RESET} → Licenses"
  echo -e "  Then activate at   ${CYAN}https://${pangolin_domain}/admin/license${RESET}"
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

    while true; do
      prompt_input "Path to SSH private key" "$HOME/.ssh/id_rsa"
      PANGOLIN_SSH_KEY="$REPLY"

      if [[ -f "$PANGOLIN_SSH_KEY" ]]; then
        break
      fi

      log_warn "SSH key not found: $PANGOLIN_SSH_KEY"
      log_blank
      prompt_select "What would you like to do?" \
        "Generate a new SSH key pair" \
        "Enter a different key path" \
        "Use password authentication instead"

      case "$REPLY" in
        "Generate a new SSH key pair")
          mkdir -p "$(dirname "$PANGOLIN_SSH_KEY")" 2>/dev/null || true
          if ssh-keygen -t ed25519 -f "$PANGOLIN_SSH_KEY" -N "" -C "portless-$(hostname)" \
              >> "${LOG_FILE:-/tmp/portless-install.log}" 2>&1; then
            log_ok "SSH key pair created: $PANGOLIN_SSH_KEY"
            local pub_key
            pub_key=$(cat "${PANGOLIN_SSH_KEY}.pub")
            log_blank
            log_info "Add this public key to your VPS:"
            echo ""
            echo -e "  ${BOLD}${pub_key}${RESET}"
            echo ""
            log_info "How to add it:"
            log_info "  • VPS control panel / dashboard (Vultr, Hetzner, DigitalOcean, etc.)"
            log_info "  • Or paste it into ~/.ssh/authorized_keys on the VPS"
            log_info "  • Or: ssh-copy-id -i ${PANGOLIN_SSH_KEY}.pub ${PANGOLIN_SSH_USER}@<vps-ip>"
            log_blank
            prompt_yn "Press Y once you've added the key to the VPS and are ready to continue" "Y" || true
            break
          else
            log_error "Key generation failed — check permissions on $(dirname "$PANGOLIN_SSH_KEY")"
          fi
          ;;
        "Enter a different key path")
          # Loop back to prompt_input
          ;;
        "Use password authentication instead")
          PANGOLIN_SSH_AUTH="password"
          prompt_secret "SSH password"
          PANGOLIN_SSH_PASS="$REPLY"
          PANGOLIN_SSH_KEY=""
          return 0
          ;;
      esac
    done

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

  # Ensure all resources are accessible to the admin user
  local admin_email
  admin_email=$(state_get '.tunnel.pangolin.admin_email' 2>/dev/null || true)
  log_sub "Verifying database access grants for all resources..."
  pangolin_repair_db "${admin_email:-}" || true
}

# ─── Repair Pangolin database access grants ────────────────────────────────────
#
# pangolin_repair_db [admin_email]
#
# Runs repair_pangolin_db.cjs inside the Pangolin container to fix missing
# access-control entries (userOrgs, roleSites, userSites, roleResources).
# Safe to run multiple times — all operations are INSERT OR IGNORE / UPDATE.
#
pangolin_repair_db() {
  local admin_email="${1:-}"

  local vps_host ssh_user ssh_auth ssh_key ssh_pass
  vps_host=$(state_get '.tunnel.pangolin.vps_host')
  ssh_user=$(state_get '.tunnel.pangolin.ssh_user')
  ssh_auth=$(state_get '.tunnel.pangolin.ssh_auth')
  ssh_key=$(state_get '.tunnel.pangolin.ssh_key')
  ssh_pass=$(state_get '.tunnel.pangolin.ssh_pass')
  ssh_user="${ssh_user:-root}"
  ssh_auth="${ssh_auth:-key}"
  ssh_key="${ssh_key:-$HOME/.ssh/id_rsa}"

  [[ -n "$vps_host" ]] || { log_warn "Pangolin VPS not configured — skipping DB repair"; return 0; }

  if [[ -z "$_PANG_VPS_HOST" || "$_PANG_VPS_HOST" != "$vps_host" ]]; then
    if [[ "$ssh_auth" == "password" ]]; then
      _pang_init_connection "$vps_host" "$ssh_user" "password" "$ssh_pass"
    else
      _pang_init_connection "$vps_host" "$ssh_user" "key" "$ssh_key"
    fi
  fi

  [[ -f "$REPAIR_DB_SCRIPT" ]] || { log_warn "repair_pangolin_db.cjs not found at $REPAIR_DB_SCRIPT"; return 1; }

  # Upload repair script to VPS then copy into container
  _pang_scp_to "$REPAIR_DB_SCRIPT" "/tmp/repair_pangolin_db.cjs" \
    >> "${LOG_FILE:-/tmp/portless-install.log}" 2>&1 \
    || { log_warn "Could not upload DB repair script to VPS"; return 1; }

  local email_arg=""
  [[ -n "$admin_email" ]] && email_arg="--email '${admin_email}'"

  local repair_output
  repair_output=$(_pang_ssh \
    "sudo docker cp /tmp/repair_pangolin_db.cjs pangolin:/app/repair_pangolin_db.cjs && \
     sudo docker exec pangolin node /app/repair_pangolin_db.cjs ${email_arg} 2>&1; \
     sudo docker exec pangolin rm -f /app/repair_pangolin_db.cjs; \
     rm -f /tmp/repair_pangolin_db.cjs" 2>/dev/null) || true

  echo "$repair_output" >> "${LOG_FILE:-/tmp/portless-install.log}"

  # Display results with colour-coded prefixes
  local had_fix=false
  while IFS= read -r line; do
    case "$line" in
      FIXED:*)          log_ok    "${line#FIXED: }"; had_fix=true ;;
      WARNING:*)        log_warn  "${line#WARNING: }" ;;
      "ERROR: "*)       log_error "${line#ERROR: }" ;;
      INFO:*)           log_sub   "${line#INFO: }" ;;
      REPAIR_COMPLETE*) ;;
    esac
  done <<< "$repair_output"

  local summary
  summary=$(echo "$repair_output" | grep "^REPAIR_COMPLETE" || true)
  if [[ -n "$summary" ]]; then
    local n_fixed n_issues
    n_fixed=$(echo  "$summary" | grep -o 'fixed=[0-9]*'  | cut -d= -f2)
    n_issues=$(echo "$summary" | grep -o 'issues=[0-9]*' | cut -d= -f2)
    if [[ "$n_fixed" -gt 0 ]]; then
      log_ok "DB repair: ${n_fixed} issue(s) fixed, ${n_issues} remaining"
    elif [[ "$n_issues" -gt 0 ]]; then
      log_warn "DB repair: ${n_issues} issue(s) could not be fixed automatically"
    else
      log_ok "DB repair: no issues found"
    fi
  else
    log_warn "DB repair script did not complete cleanly — check ${LOG_FILE:-/tmp/portless-install.log}"
  fi
}

# ─── Diagnose Pangolin routing (404 debugging) ────────────────────────────────
#
# pangolin_diagnose
#
pangolin_diagnose() {
  _pang_init_ssh_from_state

  [[ -f "$DIAGNOSE_SCRIPT" ]] || { log_warn "diagnose_pangolin.cjs not found"; return 1; }

  _pang_scp_to "$DIAGNOSE_SCRIPT" "/tmp/diagnose_pangolin.cjs" \
    >> "${LOG_FILE:-/tmp/portless-install.log}" 2>&1 || { log_warn "Could not upload diagnose script"; return 1; }

  local output
  output=$(_pang_ssh \
    "sudo docker cp /tmp/diagnose_pangolin.cjs pangolin:/app/diagnose_pangolin.cjs && \
     sudo docker exec pangolin node /app/diagnose_pangolin.cjs 2>&1; \
     sudo docker exec pangolin rm -f /app/diagnose_pangolin.cjs; \
     rm -f /tmp/diagnose_pangolin.cjs" 2>/dev/null) || true

  echo "$output"
}

# ─── Fix 404 errors on Pangolin resources ──────────────────────────────────────
#
# pangolin_fix_404 [--dry-run]
#
# Fixes: method=https→http, enableProxy, enabled, domain linking
#
pangolin_fix_404() {
  local dry_run="${1:-}"
  local extra_arg=""
  [[ "$dry_run" == "--dry-run" ]] && extra_arg="--dry-run"

  _pang_init_ssh_from_state

  [[ -f "$FIX_404_SCRIPT" ]] || { log_warn "fix_404.cjs not found"; return 1; }

  log_step "Fixing 404 causes in Pangolin database${extra_arg:+ (dry run)}"

  _pang_scp_to "$FIX_404_SCRIPT" "/tmp/fix_404.cjs" \
    >> "${LOG_FILE:-/tmp/portless-install.log}" 2>&1 || { log_warn "Could not upload fix_404 script"; return 1; }

  local output
  output=$(_pang_ssh \
    "sudo docker cp /tmp/fix_404.cjs pangolin:/app/fix_404.cjs && \
     sudo docker exec pangolin node /app/fix_404.cjs ${extra_arg} 2>&1; \
     sudo docker exec pangolin rm -f /app/fix_404.cjs; \
     rm -f /tmp/fix_404.cjs" 2>/dev/null) || true

  echo "$output" >> "${LOG_FILE:-/tmp/portless-install.log}"

  while IFS= read -r line; do
    case "$line" in
      "FIXED "*)       log_ok   "${line#FIXED }" ;;
      WARNING:*)       log_warn "${line#WARNING: }" ;;
      "DRY RUN"*)      log_info "$line" ;;
      FIX_COMPLETE*)
        local changes
        changes=$(echo "$line" | grep -o 'changes=[0-9]*' | cut -d= -f2)
        [[ "$changes" -gt 0 ]] && log_ok "Applied ${changes} fix(es)" || log_ok "No changes needed"
        ;;
      "")              ;;
      *)               log_sub "$line" ;;
    esac
  done <<< "$output"

  if [[ -z "$dry_run" ]]; then
    log_sub "Restarting Pangolin to pick up changes..."
    pangolin_restart
    log_ok "Done — try accessing your apps again"
  fi
}

# ─── Tunnel health check ───────────────────────────────────────────────────────
#
# pangolin_check_tunnel_health
#
# Checks: local Newt container, Pangolin VPS reachability, site online status
#
pangolin_check_tunnel_health() {
  log_step "Pangolin Tunnel Health"

  local vps_host domain site_id
  vps_host=$(state_get '.tunnel.pangolin.vps_host')
  domain=$(state_get '.tunnel.pangolin.domain')
  site_id=$(state_get '.tunnel.pangolin.site_id')

  # 1. Local Newt container
  echo -e "\n  ${BOLD}Newt tunnel client (local):${RESET}"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^newt$'; then
    local newt_status
    newt_status=$(docker inspect --format '{{.State.Status}}' newt 2>/dev/null || echo "unknown")
    log_ok "  Newt container: ${newt_status}"
  else
    log_error "  Newt container: NOT running"
    log_info "  Fix: docker compose -f <compose_file> up -d newt"
    local dockerdir hostname compose_file
    dockerdir=$(state_get '.dockerdir')
    hostname=$(state_get '.hostname')
    compose_file="${dockerdir}/docker-compose-${hostname}.yml"
    [[ -f "$compose_file" ]] && log_info "  File: $compose_file"
  fi

  # 2. Pangolin VPS reachability
  echo ""
  echo -e "  ${BOLD}Pangolin VPS:${RESET}"
  if [[ -n "$domain" ]]; then
    if curl -sf --max-time 8 "https://${domain}/api/v1/" &>/dev/null 2>&1; then
      log_ok "  Pangolin API reachable at https://${domain}"
    else
      log_warn "  Pangolin API unreachable at https://${domain}"
      log_info "  Check DNS, firewall, and Pangolin container status on VPS"
    fi
  elif [[ -n "$vps_host" ]]; then
    if curl -sf --max-time 8 "http://${vps_host}:3001/api/v1/" &>/dev/null 2>&1; then
      log_ok "  Pangolin health endpoint reachable on VPS ${vps_host}"
    else
      log_warn "  Cannot reach Pangolin health endpoint on ${vps_host}:3001"
    fi
  fi

  # 3. Site online status (via SSH)
  echo ""
  echo -e "  ${BOLD}Site connectivity:${RESET}"
  if [[ -n "$site_id" && -n "$vps_host" ]]; then
    local ssh_user ssh_auth ssh_key ssh_pass
    ssh_user=$(state_get '.tunnel.pangolin.ssh_user')
    ssh_auth=$(state_get '.tunnel.pangolin.ssh_auth')
    ssh_key=$(state_get '.tunnel.pangolin.ssh_key')
    ssh_pass=$(state_get '.tunnel.pangolin.ssh_pass')
    ssh_user="${ssh_user:-root}"
    ssh_auth="${ssh_auth:-key}"
    ssh_key="${ssh_key:-$HOME/.ssh/id_rsa}"

    if [[ -z "$_PANG_VPS_HOST" || "$_PANG_VPS_HOST" != "$vps_host" ]]; then
      if [[ "$ssh_auth" == "password" ]]; then
        _pang_init_connection "$vps_host" "$ssh_user" "password" "$ssh_pass"
      else
        _pang_init_connection "$vps_host" "$ssh_user" "key" "$ssh_key"
      fi
    fi

    local online_status
    online_status=$(_pang_ssh \
      "sudo docker exec pangolin node -e \"
        const db=require('/app/node_modules/better-sqlite3')('/app/config/db/db.sqlite');
        const row=db.prepare('SELECT name,online FROM sites WHERE siteId=?').get(${site_id});
        console.log(row ? (row.online ? 'online' : 'offline') + ':' + row.name : 'not_found');
        db.close();
      \"" 2>/dev/null || echo "error")

    case "$online_status" in
      online:*)
        log_ok "  Site '${online_status#online:}' (id=${site_id}): ONLINE — tunnel active"
        ;;
      offline:*)
        log_error "  Site '${online_status#offline:}' (id=${site_id}): OFFLINE — Newt not connected"
        log_info "  Check: docker logs newt"
        log_info "  Check: ssh ${ssh_user}@${vps_host} 'sudo docker logs pangolin | tail -20'"
        ;;
      not_found)
        log_warn "  Site id=${site_id} not found in Pangolin DB — re-run setup"
        ;;
      *)
        log_warn "  Could not query site status (SSH error or Pangolin not running)"
        ;;
    esac
  fi

  echo ""
}
