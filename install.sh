#!/usr/bin/env bash
# install.sh — portless interactive setup wizard
# https://github.com/techbutton/portless
#
# Usage: bash install.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load libraries
source "${SCRIPT_DIR}/lib/common.sh"
HOMELAB_COMMON_LOADED=1
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/traefik.sh"
source "${SCRIPT_DIR}/lib/pangolin.sh"
source "${SCRIPT_DIR}/lib/cloudflare.sh"
source "${SCRIPT_DIR}/lib/mount.sh"
source "${SCRIPT_DIR}/lib/tailscale.sh"
source "${SCRIPT_DIR}/lib/headscale.sh"
source "${SCRIPT_DIR}/lib/netbird.sh"

LOG_FILE="/tmp/portless-install.log"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
echo "=== portless install started $(date) ===" >> "$LOG_FILE"

# ─── Error trap ──────────────────────────────────────────────────────────────────
_on_error() {
  local exit_code=$?
  local line_no="${BASH_LINENO[0]}"
  echo "" >&2
  log_error "Setup failed on line ${line_no} (exit code: ${exit_code})"
  log_error "Review the full log for details:"
  echo -e "  ${BOLD}cat ${LOG_FILE}${RESET}" >&2
  echo "" >&2
}
trap '_on_error' ERR

# ─── Entry point ─────────────────────────────────────────────────────────────────

main() {
  banner "portless Setup Wizard"
  echo -e "  Works with ${BOLD}any ISP${RESET} — no port forwarding or firewall changes needed."
  echo -e "  Choose your remote access method: ${BOLD}Cloudflare Tunnel${RESET} (free, easiest),"
  echo -e "  ${BOLD}Pangolin${RESET} or ${BOLD}Headscale${RESET} (self-hosted VPS), ${BOLD}Tailscale${RESET} or ${BOLD}Netbird${RESET} (VPN mesh)."
  echo -e "  Your home IP is ${BOLD}never exposed${RESET} to the internet."
  echo ""
  echo -e "  ${DIM}Logs → ${LOG_FILE}${RESET}"
  echo ""

  phase1_system_check
  phase2_basic_config
  phase3_domain_network
  phase4_app_selection
  phase5_remote_access
  traefik_ask_crowdsec   # after tunnel is known — behaviour changes based on tunnel type
  phase6_generate_deploy

  echo ""
  log_ok "Setup complete! Your homelab is up and running."
  state_summary
  echo ""
  echo -e "${DIM}To manage your stack later: ${BOLD}./manage.sh --help${RESET}"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — SYSTEM CHECK
# ══════════════════════════════════════════════════════════════════════════════

phase1_system_check() {
  log_step "Phase 1: System Check"

  detect_os
  log_info "Detected OS: $OS_NAME ($OS_FAMILY)"

  if [[ "$OS_FAMILY" == "unknown" ]]; then
    log_error "Unsupported OS: $OS_NAME"
    log_error "Supported: Ubuntu, Debian, Arch Linux, RHEL/CentOS/Fedora"
    log_error "Please install Docker manually, then re-run this script."
    exit 1
  fi

  # Docker
  if docker_is_installed; then
    log_ok "Docker is installed"
    if ! docker_running; then
      log_warn "Docker daemon is not running. Starting it..."
      sudo systemctl start docker || die "Could not start Docker daemon."
    fi
  else
    log_warn "Docker is not installed."
    if prompt_yn "Install Docker now?" "Y"; then
      install_docker
      if [[ "${DOCKER_GROUP_ADDED:-0}" == "1" ]]; then
        echo ""
        log_warn "Please log out and back in for Docker group changes to take effect."
        log_warn "Then re-run this script."
        exit 0
      fi
    else
      die "Docker is required. Install it manually: https://docs.docker.com/engine/install/"
    fi
  fi

  ensure_compose_v2

  # Required tools
  local missing_tools=()
  for tool in git curl jq; do
    if check_command "$tool"; then
      log_ok "$tool is available"
    else
      missing_tools+=("$tool")
    fi
  done

  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    log_warn "Missing tools: ${missing_tools[*]}"
    if prompt_yn "Install missing tools now?" "Y"; then
      detect_os
      case "$OS_FAMILY" in
        debian)  sudo apt-get install -y -qq "${missing_tools[@]}" ;;
        arch)    sudo pacman -Sy --noconfirm "${missing_tools[@]}" ;;
        rhel)    sudo dnf install -y "${missing_tools[@]}" ;;
      esac
    else
      die "Required tools must be installed: ${missing_tools[*]}"
    fi
  fi

  log_ok "System check passed"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — BASIC CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════

phase2_basic_config() {
  log_step "Phase 2: Basic Configuration"

  detect_user_ids
  detect_timezone

  # Hostname / server nickname
  local default_hostname
  default_hostname=$(hostname -s 2>/dev/null || echo "homelab")
  prompt_input "Server nickname (used in file/folder names)" "$default_hostname"
  CFG_HOSTNAME="${REPLY,,}"  # lowercase
  CFG_HOSTNAME="${CFG_HOSTNAME//[^a-z0-9-]/-}"  # sanitize

  # Linux user
  prompt_input "Linux username" "$DETECTED_USER"
  CFG_USER="$REPLY"
  CFG_PUID=$(id -u "$CFG_USER" 2>/dev/null || echo "$DETECTED_PUID")
  CFG_PGID=$(id -g "$CFG_USER" 2>/dev/null || echo "$DETECTED_PGID")
  log_info "PUID=$CFG_PUID  PGID=$CFG_PGID"

  # Timezone
  prompt_input "Timezone" "$DETECTED_TZ"
  CFG_TIMEZONE="$REPLY"

  # Docker directory
  local default_dockerdir="/home/${CFG_USER}/docker"
  prompt_input "Docker data directory (will be created if needed)" "$default_dockerdir"
  CFG_DOCKERDIR="$REPLY"

  # Data directory (for media files)
  prompt_input "Media/data directory (where your movies, TV, etc. live)" "/mnt/data"
  CFG_DATADIR="$REPLY"

  # Initialize state
  state_init "$CFG_DOCKERDIR"
  state_set_kv "hostname" "$CFG_HOSTNAME"
  state_set_kv "dockerdir" "$CFG_DOCKERDIR"

  # Create Docker directory structure first — secrets dir must exist before
  # setup_data_dir runs so SMB credentials can be written there.
  log_sub "Creating directory structure in $CFG_DOCKERDIR..."
  ensure_dir "$CFG_DOCKERDIR"
  ensure_dir "$CFG_DOCKERDIR/secrets"
  ensure_dir "$CFG_DOCKERDIR/appdata/traefik3/acme"
  ensure_dir "$CFG_DOCKERDIR/appdata/traefik3/rules/${CFG_HOSTNAME}"
  ensure_dir "$CFG_DOCKERDIR/compose/${CFG_HOSTNAME}"

  # Set up data directory — handles NFS/SMB mounts and sudo-create for
  # paths like /mnt/data that are under root-owned mount points.
  if setup_data_dir "$CFG_DATADIR" "$CFG_USER" "$CFG_DOCKERDIR"; then
    # For NFS per-share mounts these dirs already exist and ensure_dir is a no-op.
    # For local/sudo/SMB setups they are created here.
    log_sub "Creating subdirectories under $CFG_DATADIR..."
    ensure_dir "${CFG_DATADIR}/movies"
    ensure_dir "${CFG_DATADIR}/tv"
    ensure_dir "${CFG_DATADIR}/music"
    ensure_dir "${CFG_DATADIR}/books"
    ensure_dir "${CFG_DATADIR}/audiobooks"
    ensure_dir "${CFG_DATADIR}/comics"
    ensure_dir "${CFG_DATADIR}/downloads"
    ensure_dir "${CFG_DATADIR}/usenet/incomplete"
    ensure_dir "${CFG_DATADIR}/usenet/complete"
    ensure_dir "${CFG_DATADIR}/torrents/incomplete"
    ensure_dir "${CFG_DATADIR}/torrents/complete"
  fi

  # Create acme.json for Traefik TLS
  local acme_file="${CFG_DOCKERDIR}/appdata/traefik3/acme/acme.json"
  if [[ ! -f "$acme_file" ]]; then
    touch "$acme_file" && chmod 600 "$acme_file"
    log_sub "Created acme.json (permissions: 600)"
  fi

  log_ok "Basic configuration complete"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — DOMAIN & NETWORK
# ══════════════════════════════════════════════════════════════════════════════

phase3_domain_network() {
  log_step "Phase 3: Domain & Network"

  # Domain name
  while true; do
    prompt_input "Your domain name (e.g. example.com)" ""
    CFG_DOMAIN="$REPLY"
    if validate_domain "$CFG_DOMAIN"; then
      break
    fi
    log_warn "Invalid domain format. Example: example.com or mydomain.co.uk"
  done

  # DNS provider
  echo ""
  prompt_select "DNS provider for Traefik automatic TLS:" \
    "Cloudflare (recommended — automatic wildcard certs)" \
    "Manual / Other (you'll manage DNS yourself)"
  CFG_DNS_PROVIDER="$REPLY"

  if [[ "$CFG_DNS_PROVIDER" == Cloudflare* ]]; then
    echo ""
    echo -e "${DIM}You need a Cloudflare API token with Zone:DNS:Edit permission.${RESET}"
    echo -e "${DIM}Create one at: https://dash.cloudflare.com/profile/api-tokens${RESET}"
    echo ""
    while true; do
      prompt_secret "Cloudflare API Token"
      CFG_CF_TOKEN="$REPLY"
      if [[ ${#CFG_CF_TOKEN} -gt 10 ]]; then
        # Quick validation
        log_sub "Validating Cloudflare token..."
        local cf_status
        cf_status=$(curl -sf -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
          -H "Authorization: Bearer ${CFG_CF_TOKEN}" \
          -H "Content-Type: application/json" 2>/dev/null | jq -r '.result.status // empty')
        if [[ "$cf_status" == "active" ]]; then
          log_ok "Cloudflare token is valid"
          break
        else
          log_warn "Token validation failed (or no internet). Continue anyway? "
          prompt_yn "Use this token anyway?" "N" && break
        fi
      else
        log_warn "Token seems too short. Please re-enter."
      fi
    done

    prompt_input "Cloudflare account email" ""
    CFG_CF_EMAIL="$REPLY"
  else
    CFG_CF_TOKEN="CHANGE_ME"
    CFG_CF_EMAIL="CHANGE_ME"
    log_warn "Manual DNS: you will need to create DNS records and obtain TLS certs yourself."
    log_warn "Update CF_API_TOKEN and CLOUDFLARE_EMAIL in your .env once ready."
  fi

  # Server LAN IP
  detect_lan_ip
  echo ""
  prompt_input "Server LAN IP address" "$DETECTED_LAN_IP"
  CFG_SERVER_IP="$REPLY"
  while ! validate_ip "$CFG_SERVER_IP"; do
    log_warn "Invalid IP address format"
    prompt_input "Server LAN IP address" "$DETECTED_LAN_IP"
    CFG_SERVER_IP="$REPLY"
  done

  # Save to state
  state_set_kv "domain" "$CFG_DOMAIN"
  state_set_kv "server_ip" "$CFG_SERVER_IP"

  log_ok "Domain & network configured"

  # ── Traefik access mode and auth system ──────────────────────────────────────
  # Note: traefik_ask_crowdsec is called AFTER phase5 (remote access) so we
  # know the tunnel type and can give appropriate advice.
  traefik_setup_wizard
  traefik_select_auth
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — APP SELECTION
# ══════════════════════════════════════════════════════════════════════════════

phase4_app_selection() {
  log_step "Phase 4: App Selection"

  echo -e "${DIM}Select which services to deploy. Core services are always included.${RESET}"
  echo ""
  echo -e "  ${BOLD}[CORE — always included]${RESET}"
  echo -e "  ${GREEN}✓${RESET} Traefik (reverse proxy + automatic HTTPS)"
  echo -e "  ${GREEN}✓${RESET} Socket Proxy (secure Docker socket access)"
  echo -e "  ${GREEN}✓${RESET} Newt (Pangolin tunnel client)"
  echo ""

  # Define categories
  declare -A CATEGORY_APPS
  CATEGORY_APPS["MEDIA"]="plex jellyfin"
  CATEGORY_APPS["ARR"]="sonarr radarr lidarr bazarr prowlarr"
  CATEGORY_APPS["DOWNLOADS"]="sabnzbd qbittorrent-vpn"
  CATEGORY_APPS["MANAGEMENT"]="portainer vscode dozzle wud uptime-kuma it-tools"
  CATEGORY_APPS["REQUESTS"]="overseerr"
  CATEGORY_APPS["OTHER"]="stirling-pdf maintainerr notifiarr"

  CFG_SELECTED_APPS=()

  for category in MEDIA ARR DOWNLOADS MANAGEMENT REQUESTS OTHER; do
    echo -e "  ${BOLD}[${category}]${RESET}"
    local apps_in_cat
    read -ra apps_in_cat <<< "${CATEGORY_APPS[$category]}"

    local display_names=()
    for app in "${apps_in_cat[@]}"; do
      local desc=""
      local catalog="${SCRIPT_DIR}/lib/apps/${app}.sh"
      if [[ -f "$catalog" ]]; then
        # shellcheck source=/dev/null
        APP_DESCRIPTION=""
        source "$catalog"
        desc="$APP_DESCRIPTION"
      fi
      display_names+=("${app} — ${desc}")
    done

    prompt_checklist "Select ${category} apps (or press Enter to skip):" "${display_names[@]}"

    for selected in "${SELECTED_ITEMS[@]}"; do
      # Extract app name (before ' — ')
      local app_name="${selected%% —*}"
      app_name="${app_name%% }"  # trim trailing space
      CFG_SELECTED_APPS+=("$app_name")
    done
    echo ""
  done

  # Assign ports, check for conflicts
  log_sub "Checking port assignments..."
  declare -A ASSIGNED_PORTS
  local used_ports=()

  for app in "${CFG_SELECTED_APPS[@]}"; do
    local catalog="${SCRIPT_DIR}/lib/apps/${app}.sh"
    [[ -f "$catalog" ]] || continue

    # Reset app vars
    APP_DEFAULT_HOST_PORT=""
    APP_DEFAULT_SUBDOMAIN=""
    APP_AUTH="none"
    APP_PORT_VAR=""
    # shellcheck source=/dev/null
    source "$catalog"

    local port="$APP_DEFAULT_HOST_PORT"

    # Check for conflict
    if [[ " ${used_ports[*]} " =~ " ${port} " ]]; then
      log_warn "Port $port for $app conflicts — incrementing..."
      while [[ " ${used_ports[*]} " =~ " ${port} " ]]; do
        ((port++))
      done
    fi
    used_ports+=("$port")
    ASSIGNED_PORTS["$app"]="$port"

    # Persist to state
    app_state_set_installed "$app" "$port" "$APP_DEFAULT_SUBDOMAIN"
    state_set ".apps[\"$app\"].auth_type = \"${APP_AUTH}\""

    log_sub "  ${app}: port ${port} → https://${APP_DEFAULT_SUBDOMAIN}.${CFG_DOMAIN}"
  done

  log_ok "App selection complete: ${#CFG_SELECTED_APPS[@]} apps selected"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — PANGOLIN SETUP
# ══════════════════════════════════════════════════════════════════════════════

phase5_remote_access() {
  log_step "Phase 5: Remote Access"

  cat <<EOF

  ${BOLD}Remote access lets you reach your homelab from anywhere — phone, laptop,${RESET}
  ${BOLD}anywhere in the world — without opening a single port on your router.${RESET}

  ${GREEN}✓${RESET}  Works with ${BOLD}any ISP${RESET}, including those with CGNAT
  ${GREEN}✓${RESET}  ${BOLD}Zero port forwarding${RESET} — your router is never touched
  ${GREEN}✓${RESET}  Your home IP is ${BOLD}never exposed${RESET}

  ${BOLD}Public URL access${RESET} (e.g. movies.yourdomain.com from any browser):

  ${CYAN}1) Cloudflare Tunnel${RESET}  — FREE · No VPS · Easiest setup
     Traffic: Internet → Cloudflare Edge → this server → services
     Fully automated using your Cloudflare account.

  ${CYAN}2) Pangolin on a VPS${RESET}  — ~\$18/year · Self-hosted · Full control
     Traffic: Internet → your VPS (Pangolin) → WireGuard tunnel → here
     ${DIM}Any VPS with 1 vCPU / 512 MB RAM and a public IP will work.${RESET}
     ${DIM}+ Add Cloudflare proxy (orange cloud) on top for free DDoS protection.${RESET}

  ${BOLD}Private VPN access${RESET} (from enrolled devices only, no public URLs):

  ${CYAN}3) Tailscale${RESET}          — FREE · No VPS · WireGuard mesh VPN
     Devices connect via Tailscale client. Access via Tailscale IP/MagicDNS.
     Uses Tailscale's free coordination servers (tailscale.com).

  ${CYAN}4) Headscale${RESET}          — FREE · VPS required · Self-hosted Tailscale
     Same Tailscale client, but your VPS is the coordination server.
     100% self-hosted — no Tailscale account needed.

  ${CYAN}5) Netbird${RESET}            — FREE · No VPS needed · WireGuard mesh VPN
     Direct peer-to-peer WireGuard. Cloud tier free for unlimited peers.
     Self-hosted option available for complete control.

  ${CYAN}6) Skip${RESET}               — LAN access only
     Services accessible on your home network only.
     Add remote access later: ${BOLD}./manage.sh tunnel setup${RESET}

EOF

  prompt_select "Remote access method:" \
    "Cloudflare Tunnel (free, no VPS, public URLs)" \
    "Pangolin on a VPS (~\$18/year, self-hosted, public URLs)" \
    "Tailscale (free, private VPN, no public URLs)" \
    "Headscale (free, self-hosted Tailscale, VPS required)" \
    "Netbird (free, WireGuard mesh, cloud or self-hosted)" \
    "Skip — LAN only"
  local choice="$REPLY"

  case "$choice" in

    Cloudflare*)
      TUNNEL_METHOD="cloudflare"
      prompt_select "Cloudflare Tunnel setup:" \
        "Set up a new tunnel (recommended)" \
        "Connect to an existing tunnel"
      if [[ "$REPLY" == Set* ]]; then
        cf_wizard_fresh
      else
        cf_wizard_existing
      fi
      log_ok "Cloudflare Tunnel configured — remote access ready"
      ;;

    Pangolin*)
      TUNNEL_METHOD="pangolin"
      prompt_select "Pangolin setup:" \
        "Install Pangolin on a fresh VPS (recommended)" \
        "Connect to an existing Pangolin instance"
      if [[ "$REPLY" == Install* ]]; then
        pangolin_wizard_fresh
      else
        pangolin_wizard_existing
        state_set "
          .tunnel.method = \"pangolin\" |
          .tunnel.pangolin.enabled = true |
          .tunnel.pangolin.vps_host = \"${PANGOLIN_VPS_HOST:-}\" |
          .tunnel.pangolin.org_id = \"${PANGOLIN_ORG_ID:-}\" |
          .tunnel.pangolin.site_id = ${PANGOLIN_SITE_ID:-0} |
          .tunnel.pangolin.newt_id = \"${NEWT_ID:-}\" |
          .tunnel.pangolin.newt_secret = \"${NEWT_SECRET:-}\" |
          .tunnel.pangolin.ssh_user = \"${PANGOLIN_SSH_USER:-root}\" |
          .tunnel.pangolin.ssh_auth = \"${PANGOLIN_SSH_AUTH:-key}\" |
          .tunnel.pangolin.ssh_key = \"${PANGOLIN_SSH_KEY:-}\"
        "
      fi
      log_ok "Pangolin configured — remote access ready"
      ;;

    Tailscale*)
      TUNNEL_METHOD="tailscale"
      tailscale_wizard
      ;;

    Headscale*)
      TUNNEL_METHOD="headscale"
      prompt_select "Headscale setup:" \
        "Install Headscale on a fresh VPS (recommended)" \
        "Connect to an existing Headscale instance"
      if [[ "$REPLY" == Install* ]]; then
        headscale_wizard_fresh
      else
        headscale_wizard_existing
      fi
      log_ok "Headscale configured — private VPN access ready"
      ;;

    Netbird*)
      TUNNEL_METHOD="netbird"
      netbird_wizard
      log_ok "Netbird configured — private VPN access ready"
      ;;

    Skip*)
      TUNNEL_METHOD="none"
      state_set ".tunnel.method = \"none\""
      log_warn "Skipping remote access — services will only be accessible on your LAN."
      log_warn "Add remote access later: ./manage.sh tunnel setup"
      ;;
  esac
}


# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6 — GENERATE & DEPLOY
# ══════════════════════════════════════════════════════════════════════════════

phase6_generate_deploy() {
  log_step "Phase 6: Generating Configuration & Deploying"

  _gen_env_file
  _scaffold_traefik_chains
  _gen_traefik_rules
  _gen_compose_file
  _create_secrets
  _setup_docker_networks

  local tunnel_method="${TUNNEL_METHOD:-$(state_get '.tunnel.method')}"
  case "$tunnel_method" in
    cloudflare)
      _configure_cloudflared
      ;;
    pangolin)
      _configure_newt
      pangolin_register_all_apps
      ;;
    tailscale)
      _configure_tailscale
      ;;
    headscale)
      _configure_headscale
      ;;
    netbird)
      _configure_netbird
      ;;
  esac

  # Staging cert validation (only when using Cloudflare DNS)
  if [[ "${CFG_DNS_PROVIDER:-}" == Cloudflare* ]]; then
    local _acme_json="${CFG_DOCKERDIR}/appdata/traefik3/acme/acme.json"
    traefik_cert_staging_test "$CFG_COMPOSE_FILE" "${CFG_DOCKERDIR}/.env" "$_acme_json"
  fi

  _deploy_stack

  # Post-install auth guide
  traefik_show_auth_guide

  log_ok "Deployment complete"
}

_gen_env_file() {
  log_sub "Generating .env file..."

  local env_file="${CFG_DOCKERDIR}/.env"
  backup_file "$env_file"

  # Prompt for downloads directory (may differ from media dir on some setups)
  prompt_input "Downloads directory" "${CFG_DATADIR}/downloads"
  CFG_DOWNLOADSDIR="$REPLY"

  render_template "${SCRIPT_DIR}/templates/env.template" "$env_file" \
    "GENERATED_DATE=$(date '+%Y-%m-%d %H:%M:%S')" \
    "HOSTNAME=${CFG_HOSTNAME}" \
    "PUID=${CFG_PUID}" \
    "PGID=${CFG_PGID}" \
    "TIMEZONE=${CFG_TIMEZONE}" \
    "LINUX_USER=${CFG_USER}" \
    "DOCKERDIR=${CFG_DOCKERDIR}" \
    "DOMAINNAME_1=${CFG_DOMAIN}" \
    "SERVER_LAN_IP=${CFG_SERVER_IP}" \
    "CF_EMAIL=${CFG_CF_EMAIL:-CHANGE_ME}" \
    "DOWNLOADSDIR=${CFG_DOWNLOADSDIR}" \
    "DATADIR=${CFG_DATADIR}" \
    "MOVIES_DIR=${CFG_DATADIR}/movies" \
    "TV_DIR=${CFG_DATADIR}/tv" \
    "MUSIC_DIR=${CFG_DATADIR}/music" \
    "BOOKS_DIR=${CFG_DATADIR}/books" \
    "AUDIOBOOKS_DIR=${CFG_DATADIR}/audiobooks" \
    "COMICS_DIR=${CFG_DATADIR}/comics" \
    "NEWT_ID=${NEWT_ID:-}" \
    "NEWT_SECRET=${NEWT_SECRET:-}" \
    "PANGOLIN_HOST=${PANGOLIN_VPS_HOST:-}" \
    "PANGOLIN_SITE_ID=${PANGOLIN_SITE_ID:-0}"

  chmod 600 "$env_file"
  log_ok "Generated: $env_file"
}

_scaffold_traefik_chains() {
  log_sub "Scaffolding Traefik chain files..."
  traefik_scaffold_chains "$CFG_HOSTNAME" "$CFG_DOCKERDIR"
}

_gen_traefik_rules() {
  log_sub "Generating Traefik app rules..."
  for app in "${CFG_SELECTED_APPS[@]}"; do
    local subdomain auth port
    subdomain=$(state_get ".apps[\"$app\"].subdomain")
    auth=$(state_get ".apps[\"$app\"].auth_type")
    port=$(state_get ".apps[\"$app\"].port")
    traefik_gen_rule "$app" "$subdomain" "$auth" "$port"
  done
}

_gen_compose_file() {
  log_sub "Generating docker-compose-${CFG_HOSTNAME}.yml..."

  local compose_out="${CFG_DOCKERDIR}/docker-compose-${CFG_HOSTNAME}.yml"
  backup_file "$compose_out"

  # Start with header
  cat > "$compose_out" <<EOF
# docker-compose-${CFG_HOSTNAME}.yml
# Generated by portless install.sh on $(date)
# Manage with: ./manage.sh

name: ${CFG_HOSTNAME}

########################### NETWORKS
networks:
  default:
    driver: bridge
  socket_proxy:
    name: socket_proxy
    driver: bridge
    ipam:
      config:
        - subnet: 192.168.91.0/24
  t3_proxy:
    name: t3_proxy
    driver: bridge
    ipam:
      config:
        - subnet: 192.168.90.0/24

########################### SECRETS
secrets:
  basic_auth_credentials:
    file: \${DOCKERDIR}/secrets/basic_auth_credentials
  cf_dns_api_token:
    file: \${DOCKERDIR}/secrets/cf_dns_api_token
  tinyauth_secret:
    file: \${DOCKERDIR}/secrets/tinyauth_secret
  plex_claim:
    file: \${DOCKERDIR}/secrets/plex_claim

########################### SERVICES
services:
EOF

  # Write socket-proxy + Traefik using the new wizard-aware writer
  local _access_mode="${TRAEFIK_ACCESS_MODE:-$(state_get '.traefik.access_mode // "hybrid"')}"
  local _auth_system="${TRAEFIK_AUTH_SYSTEM:-$(state_get '.traefik.auth_system // "tinyauth"')}"
  local _crowdsec="${TRAEFIK_CROWDSEC_ENABLED:-$(state_get '.traefik.crowdsec_enabled // "false"')}"
  traefik_write_compose_service "$compose_out" "$_access_mode" "$_auth_system"

  # CrowdSec + bouncer
  if [[ "$_crowdsec" == "true" ]]; then
    crowdsec_write_compose_service "$compose_out"
  fi

  # TinyAuth SSO
  if [[ "$_auth_system" == "tinyauth" ]]; then
    tinyauth_write_compose_service "$compose_out"
  fi

  # Include selected apps
  for app in "${CFG_SELECTED_APPS[@]}"; do
    _include_service_if_exists "$compose_out" "$app"
  done

  # Add newt if pangolin enabled
  if [[ "${PANGOLIN_ENABLED:-false}" == "true" ]]; then
    cat >> "$compose_out" <<'EOF'

  ########## PANGOLIN TUNNEL ##########
  newt:
    image: fosrl/newt:latest
    container_name: newt
    restart: unless-stopped
    environment:
      - PANGOLIN_ENDPOINT=https://${PANGOLIN_HOST}
      - NEWT_ID=${NEWT_ID}
      - NEWT_SECRET=${NEWT_SECRET}
    networks:
      - socket_proxy
EOF
  fi

  log_ok "Generated: $compose_out"
  CFG_COMPOSE_FILE="$compose_out"
}

# Include a service compose snippet from the repo compose/ dir
_include_service_if_exists() {
  local compose_out="$1"
  local service="$2"

  local src="${SCRIPT_DIR}/compose/${CFG_HOSTNAME}/${service}.yml"
  if [[ ! -f "$src" ]]; then
    # Try generic (non-hostname-specific)
    src="${SCRIPT_DIR}/compose/${service}.yml"
  fi

  if [[ -f "$src" ]]; then
    echo "" >> "$compose_out"
    echo "  ########## ${service^^} ##########" >> "$compose_out"
    # Append service block (skip the 'services:' header line if present)
    grep -v "^services:" "$src" >> "$compose_out" 2>/dev/null || true
  else
    log_sub "  No compose snippet for '$service' — skipping include"
  fi
}

_create_secrets() {
  log_sub "Creating Docker secrets files..."
  local secrets_dir="${CFG_DOCKERDIR}/secrets"
  ensure_dir "$secrets_dir"

  # Create empty placeholder files if they don't exist
  local secrets=(
    "cf_dns_api_token"
    "basic_auth_credentials"
    "tinyauth_secret"
    "plex_claim"
  )

  for secret in "${secrets[@]}"; do
    local sf="${secrets_dir}/${secret}"
    if [[ ! -f "$sf" ]]; then
      touch "$sf"
      chmod 600 "$sf"
    fi
  done

  # Pre-fill Cloudflare token
  [[ -n "${CFG_CF_TOKEN:-}" ]] && printf '%s' "$CFG_CF_TOKEN" > "${secrets_dir}/cf_dns_api_token"

  # Auth-system specific credential setup
  local _auth_system="${TRAEFIK_AUTH_SYSTEM:-$(state_get '.traefik.auth_system // "none"')}"
  case "$_auth_system" in
    tinyauth)
      tinyauth_setup_secret "$CFG_DOCKERDIR"
      tinyauth_setup_user "$CFG_DOCKERDIR"
      ;;
    basic)
      traefik_setup_basic_auth "$CFG_DOCKERDIR"
      ;;
    none)
      # Write placeholder so Traefik doesn't fail to load the secret file
      if [[ ! -s "${secrets_dir}/basic_auth_credentials" ]]; then
        printf 'admin:$2y$05$placeholder-not-used-change-me\n' > "${secrets_dir}/basic_auth_credentials"
      fi
      ;;
  esac

  chmod 600 "${secrets_dir}"/*
  log_ok "Secrets created in $secrets_dir"
}

_setup_docker_networks() {
  log_sub "Setting up Docker networks..."
  ensure_docker_network "socket_proxy" "192.168.91.0/24"
  ensure_docker_network "t3_proxy" "192.168.90.0/24"
}

_configure_cloudflared() {
  local tunnel_token="${CF_TUNNEL_TOKEN:-}"
  [[ -n "$tunnel_token" ]] || tunnel_token=$(state_get '.tunnel.cloudflare.tunnel_token')

  if [[ -z "$tunnel_token" ]]; then
    log_warn "Cloudflare Tunnel token not found — skipping cloudflared setup"
    log_warn "Configure later: ./manage.sh tunnel setup"
    return 0
  fi

  log_sub "Adding cloudflared tunnel client to compose file..."
  cf_setup_cloudflared "$tunnel_token" "$CFG_COMPOSE_FILE"

  # Write CLOUDFLARE_TUNNEL_TOKEN to .env if not already there
  local env_file="${CFG_DOCKERDIR}/.env"
  if [[ -f "$env_file" ]] && ! grep -q "^CLOUDFLARE_TUNNEL_TOKEN=" "$env_file"; then
    echo "" >> "$env_file"
    echo "CLOUDFLARE_TUNNEL_TOKEN=${tunnel_token}" >> "$env_file"
  fi
}

_configure_newt() {
  # Pull Newt credentials — from wizard variables or state
  local newt_id="${NEWT_ID:-}"
  local newt_secret="${NEWT_SECRET:-}"
  local pangolin_host
  pangolin_host=$(state_get '.tunnel.pangolin.vps_host')
  local pangolin_domain
  pangolin_domain=$(state_get '.tunnel.pangolin.domain')
  local newt_endpoint="${pangolin_domain:-$pangolin_host}"

  [[ -n "$newt_id" ]]     || newt_id=$(state_get '.tunnel.pangolin.newt_id')
  [[ -n "$newt_secret" ]] || newt_secret=$(state_get '.tunnel.pangolin.newt_secret')

  if [[ -z "$newt_id" || -z "$newt_secret" ]]; then
    log_warn "Newt credentials not found — skipping Newt service setup"
    log_warn "Configure later: ./manage.sh tunnel setup"
    return 0
  fi

  if [[ -z "$newt_endpoint" ]]; then
    log_warn "Pangolin host not configured — Newt service will need manual configuration"
    return 0
  fi

  log_sub "Adding Newt tunnel client to compose file..."
  pangolin_setup_newt "$newt_id" "$newt_secret" "$newt_endpoint" "$CFG_COMPOSE_FILE"
}

_configure_tailscale() {
  local ts_auth_key
  ts_auth_key=$(state_get '.tunnel.tailscale.auth_key')

  if [[ -z "$ts_auth_key" || "$ts_auth_key" == "null" ]]; then
    log_warn "Tailscale auth key not found — skipping Tailscale setup"
    log_warn "Configure later: ./manage.sh tunnel setup"
    return 0
  fi

  log_sub "Adding Tailscale VPN client to compose file..."
  tailscale_setup_compose "$CFG_COMPOSE_FILE"
  tailscale_write_env "${CFG_DOCKERDIR}/.env"
}

_configure_headscale() {
  local preauth_key
  preauth_key=$(state_get '.tunnel.headscale.preauth_key')

  if [[ -z "$preauth_key" || "$preauth_key" == "null" ]]; then
    log_warn "Headscale pre-auth key not found — skipping client setup"
    log_warn "Configure later: ./manage.sh tunnel setup"
    return 0
  fi

  log_sub "Adding Headscale client (Tailscale) to compose file..."
  headscale_setup_compose "$CFG_COMPOSE_FILE"
}

_configure_netbird() {
  local setup_key
  setup_key=$(state_get '.tunnel.netbird.setup_key')

  if [[ -z "$setup_key" || "$setup_key" == "null" ]]; then
    log_warn "Netbird setup key not found — skipping Netbird client setup"
    log_warn "Configure later: ./manage.sh tunnel setup"
    return 0
  fi

  log_sub "Adding Netbird WireGuard client to compose file..."
  netbird_setup_compose "$CFG_COMPOSE_FILE"
  netbird_write_env "${CFG_DOCKERDIR}/.env"
}

_deploy_stack() {
  echo ""
  log_sub "Ready to start the stack."
  echo ""
  echo -e "  Compose file: ${CYAN}${CFG_COMPOSE_FILE}${RESET}"
  echo -e "  Env file:     ${CYAN}${CFG_DOCKERDIR}/.env${RESET}"
  echo ""

  if prompt_yn "Start the stack now?" "Y"; then
    log_sub "Running: docker compose up -d"
    docker compose \
      --env-file "${CFG_DOCKERDIR}/.env" \
      -f "$CFG_COMPOSE_FILE" \
      up -d --remove-orphans 2>&1 | tee -a "$LOG_FILE" || {
        log_error "docker compose up failed — check $LOG_FILE"
        log_error "You can start manually: docker compose --env-file ${CFG_DOCKERDIR}/.env -f ${CFG_COMPOSE_FILE} up -d"
        return 1
      }
    log_ok "Stack started"

    # Summary table
    echo ""
    echo -e "${BOLD}Service URLs:${RESET}"
    printf "  %-20s %-45s\n" "SERVICE" "URL"
    printf "  %-20s %-45s\n" "-------" "---"
    for app in "${CFG_SELECTED_APPS[@]}"; do
      local subdomain domain
      subdomain=$(state_get ".apps[\"$app\"].subdomain")
      domain=$(state_get '.domain')
      printf "  %-20s %-45s\n" "$app" "https://${subdomain}.${domain}"
    done
    echo ""
    local _tm="${TUNNEL_METHOD:-$(state_get '.tunnel.method')}"
    case "$_tm" in
      cloudflare)
        echo -e "  ${GREEN}✓${RESET} Remote access active via Cloudflare Tunnel"
        echo -e "  ${DIM}All URLs above are accessible from anywhere — no VPN needed${RESET}"
        ;;
      pangolin)
        echo -e "  ${GREEN}✓${RESET} Remote access active via Pangolin tunnel"
        echo -e "  ${DIM}All URLs above are accessible from anywhere — no VPN needed${RESET}"
        ;;
      tailscale)
        echo -e "  ${GREEN}✓${RESET} Tailscale VPN active — services reachable from Tailscale devices"
        echo -e "  ${DIM}Install Tailscale on your other devices: tailscale.com/download${RESET}"
        ;;
      headscale)
        echo -e "  ${GREEN}✓${RESET} Headscale VPN active — services reachable from enrolled devices"
        local _hs_url
        _hs_url=$(state_get '.tunnel.headscale.server_url')
        echo -e "  ${DIM}Enroll devices by pointing Tailscale client to: ${_hs_url}${RESET}"
        ;;
      netbird)
        echo -e "  ${GREEN}✓${RESET} Netbird WireGuard mesh active — services reachable from peer devices"
        echo -e "  ${DIM}Install Netbird on other devices: netbird.io/download${RESET}"
        ;;
      *)
        echo -e "  ${YELLOW}⚠${RESET}  LAN access only. Add remote access later:"
        echo -e "  ${DIM}./manage.sh tunnel setup${RESET}"
        ;;
    esac
  else
    echo ""
    log_info "Skipped. Start manually with:"
    echo -e "  ${CYAN}docker compose --env-file ${CFG_DOCKERDIR}/.env -f ${CFG_COMPOSE_FILE} up -d${RESET}"
  fi
}

main "$@"
