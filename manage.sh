#!/usr/bin/env bash
# manage.sh — portless management CLI
# Usage: ./manage.sh <command> [args]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PORTLESS_VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "0.5.0")"

# Load libraries
source "${SCRIPT_DIR}/lib/common.sh"
PORTLESS_COMMON_LOADED=1
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/traefik.sh"
source "${SCRIPT_DIR}/lib/pangolin.sh"
source "${SCRIPT_DIR}/lib/cloudflare.sh"
source "${SCRIPT_DIR}/lib/tailscale.sh"
source "${SCRIPT_DIR}/lib/headscale.sh"
source "${SCRIPT_DIR}/lib/netbird.sh"

# ─── Resolve state file ───────────────────────────────────────────────────────

_load_state() {
  # Try to find state file
  local candidates=(
    "${DOCKERDIR:-}/.portless-state.json"
    "$HOME/docker/.portless-state.json"
    "/opt/docker/.portless-state.json"
  )
  for f in "${candidates[@]}"; do
    if [[ -n "$f" && -f "$f" ]]; then
      STATE_FILE="$f"
      return 0
    fi
  done
  die "No .portless-state.json found. Run ./install.sh first."
}

_require_app_installed() {
  local app="$1"
  app_is_installed "$app" || die "App '$app' is not installed. Run: ./manage.sh add $app"
}

# Strip 'profiles:' lines from compose file so all included services start
# without needing --profile flags. Safe to run multiple times (idempotent).
_migrate_compose_strip_profiles() {
  local compose_file
  compose_file=$(_compose_file 2>/dev/null) || return 0
  [[ -f "$compose_file" ]] || return 0
  if grep -q "^[[:space:]]*profiles:" "$compose_file" 2>/dev/null; then
    log_sub "Removing docker compose profiles from $(basename "$compose_file") (one-time migration)..."
    sed -i '/^[[:space:]]*profiles:/d' "$compose_file"
    log_ok "Profiles removed — all selected services will now start automatically"
  fi
}

_compose_file() {
  local dockerdir hostname
  dockerdir=$(state_get '.dockerdir')
  hostname=$(state_get '.hostname')
  echo "${dockerdir}/docker-compose-${hostname}.yml"
}

_env_file() {
  local dockerdir
  dockerdir=$(state_get '.dockerdir')
  echo "${dockerdir}/.env"
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_add() {
  local app="${1:-}"
  [[ -n "$app" ]] || { cmd_help; die "Usage: manage.sh add <app>"; }

  local catalog="${SCRIPT_DIR}/lib/apps/${app}.sh"
  [[ -f "$catalog" ]] || die "Unknown app: '$app'. See lib/apps/ for supported apps."

  app_is_installed "$app" && { log_warn "$app is already installed."; return 0; }

  log_step "Adding: $app"

  # Load app catalog
  # shellcheck source=/dev/null
  source "$catalog"

  # Ask for subdomain customization
  prompt_input "Subdomain for $app" "$APP_DEFAULT_SUBDOMAIN"
  local subdomain="$REPLY"

  prompt_input "Host port for $app" "$APP_DEFAULT_HOST_PORT"
  local port="$REPLY"
  validate_port "$port" || die "Invalid port: $port"

  local domain
  domain=$(state_get '.domain')

  # Update state
  app_state_set_installed "$app" "$port" "$subdomain"
  state_set ".apps[\"$app\"].auth_type = \"${APP_AUTH}\""

  # Copy compose snippet if available
  local hostname
  hostname=$(state_get '.hostname')
  local dockerdir
  dockerdir=$(state_get '.dockerdir')
  local src="${SCRIPT_DIR}/compose/${hostname}/${app}.yml"
  [[ -f "$src" ]] || src="${SCRIPT_DIR}/compose/hs/${app}.yml"
  [[ -f "$src" ]] || src="${SCRIPT_DIR}/compose/${app}.yml"

  if [[ -f "$src" ]]; then
    local compose_file
    compose_file=$(_compose_file)
    log_sub "Adding $app service to compose file..."
    echo "" >> "$compose_file"
    echo "  ########## ${app^^} ##########" >> "$compose_file"
    grep -v "^services:" "$src" \
      | grep -v "^[[:space:]]*profiles:" \
      >> "$compose_file" || true
    log_ok "Added $app to $compose_file"
  else
    log_warn "No compose snippet found for '$app' at $src"
    log_warn "You'll need to add the service manually to $(_compose_file)"
  fi

  # Generate Traefik rule
  traefik_gen_rule "$app" "$subdomain" "$APP_AUTH" "$port"

  # Expose via Pangolin (always on if configured)
  local pangolin_enabled
  pangolin_enabled=$(state_get '.pangolin.enabled')
  if [[ "$pangolin_enabled" == "true" ]]; then
    _pangolin_add_single "$app" "$subdomain" "$port" "${APP_SERVICE_PORT:-$port}"
  else
    log_info "Pangolin not configured — $app is LAN-only."
    log_info "Add remote access later with: ./manage.sh pangolin add $app"
  fi

  # Start the new service
  if prompt_yn "Start $app now?" "Y"; then
    docker compose \
      --env-file "$(_env_file)" \
      -f "$(_compose_file)" \
      up -d --no-deps "$app" 2>&1 || log_warn "Could not start $app automatically"
  fi

  log_ok "$app added successfully → https://${subdomain}.${domain}"
}

cmd_remove() {
  local app="${1:-}"
  [[ -n "$app" ]] || die "Usage: manage.sh remove <app>"
  _require_app_installed "$app"

  log_step "Removing: $app"

  if prompt_yn "Remove $app? This will stop the container and remove its config." "N"; then
    # Remove from Pangolin if configured
    if app_has_pangolin "$app"; then
      local resource_id
      resource_id=$(state_get ".apps[\"$app\"].pangolin_resource_id")
      log_sub "Removing Pangolin resource..."
      pangolin_remove_resource "$resource_id" && \
        app_state_remove_pangolin "$app" && \
        pangolin_restart
    fi

    # Stop container
    log_sub "Stopping container: $app"
    docker compose \
      --env-file "$(_env_file)" \
      -f "$(_compose_file)" \
      stop "$app" 2>/dev/null || true

    docker compose \
      --env-file "$(_env_file)" \
      -f "$(_compose_file)" \
      rm -f "$app" 2>/dev/null || true

    # Remove Traefik rule
    traefik_remove_rule "$app"

    # Remove from state
    app_state_remove "$app"

    log_ok "$app removed"
    log_warn "Note: appdata directory was NOT deleted. Remove manually if desired."
  else
    log_info "Cancelled."
  fi
}

cmd_update() {
  local target="${1:-}"
  log_step "Updating: ${target:-all services}"
  _migrate_compose_strip_profiles

  if [[ -n "$target" ]]; then
    _require_app_installed "$target"
    log_sub "Pulling new image for $target..."
    docker compose \
      --env-file "$(_env_file)" \
      -f "$(_compose_file)" \
      pull "$target" 2>&1 | tail -5

    log_sub "Restarting $target..."
    docker compose \
      --env-file "$(_env_file)" \
      -f "$(_compose_file)" \
      up -d --no-deps "$target" 2>&1
  else
    log_sub "Pulling all images..."
    docker compose \
      --env-file "$(_env_file)" \
      -f "$(_compose_file)" \
      pull 2>&1 | tail -20

    log_sub "Restarting all services..."
    docker compose \
      --env-file "$(_env_file)" \
      -f "$(_compose_file)" \
      up -d --remove-orphans 2>&1
  fi


  log_ok "Update complete"
}

cmd_status() {
  log_step "Stack Status"

  local compose_file env_file
  compose_file=$(_compose_file)
  env_file=$(_env_file)

  echo -e "\n${BOLD}Running containers:${RESET}"
  docker compose \
    --env-file "$env_file" \
    -f "$compose_file" \
    ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null \
  | column -t

  echo ""
  state_summary
}

cmd_logs() {
  local app="${1:-}"
  [[ -n "$app" ]] || die "Usage: manage.sh logs <app>"

  docker compose \
    --env-file "$(_env_file)" \
    -f "$(_compose_file)" \
    logs -f --tail=100 "$app"
}

cmd_regen() {
  log_step "Regenerating configuration from state"

  traefik_regen_all

  log_sub "Regenerating compose file..."
  _cmd_regen_compose

  local dockerdir hostname
  dockerdir=$(state_get '.dockerdir')
  hostname=$(state_get '.hostname')
  log_info "Restart with: docker compose -f ${dockerdir}/docker-compose-${hostname}.yml up -d"
}

# ─── Pangolin subcommands ─────────────────────────────────────────────────────

cmd_pangolin() {
  local subcmd="${1:-}"
  local app="${2:-}"

  case "$subcmd" in
    add)
      [[ -n "$app" ]] || die "Usage: manage.sh pangolin add <app>"
      _require_app_installed "$app"
      app_has_pangolin "$app" && { log_warn "$app already has Pangolin exposure."; return 0; }

      local catalog="${SCRIPT_DIR}/lib/apps/${app}.sh"
      # shellcheck source=/dev/null
      [[ -f "$catalog" ]] && source "$catalog"

      local subdomain port
      subdomain=$(state_get ".apps[\"$app\"].subdomain")
      port=$(state_get ".apps[\"$app\"].port")

      _pangolin_add_single "$app" "$subdomain" "$port" "${APP_SERVICE_PORT:-$port}"
      ;;
    remove)
      [[ -n "$app" ]] || die "Usage: manage.sh pangolin remove <app>"
      _require_app_installed "$app"
      app_has_pangolin "$app" || { log_warn "$app has no Pangolin exposure."; return 0; }

      local resource_id
      resource_id=$(state_get ".apps[\"$app\"].pangolin_resource_id")
      log_step "Removing Pangolin exposure for $app"
      pangolin_remove_resource "$resource_id"
      app_state_remove_pangolin "$app"
      pangolin_restart
      log_ok "Pangolin exposure removed for $app"
      ;;
    setup)
      _cmd_pangolin_setup
      ;;
    repair-db)
      log_step "Repairing Pangolin Database"
      local _repair_email
      _repair_email=$(state_get '.tunnel.pangolin.admin_email' 2>/dev/null || true)
      local _repair_vps_host
      _repair_vps_host=$(state_get '.tunnel.pangolin.vps_host' 2>/dev/null || true)
      [[ -n "$_repair_vps_host" ]] || die "Pangolin not configured. Run: ./manage.sh pangolin setup"
      _pang_init_ssh_from_state
      pangolin_repair_db "${_repair_email:-}"
      ;;
    diagnose)
      log_step "Pangolin Diagnostics"
      pangolin_diagnose
      ;;
    fix-404)
      pangolin_fix_404 "${3:-}"
      ;;
    status)
      echo -e "\n${BOLD}Pangolin Tunnel:${RESET}"
      echo -e "  VPS:     $(state_get '.tunnel.pangolin.vps_host')"
      echo -e "  Domain:  $(state_get '.tunnel.pangolin.domain')"
      echo -e "  Org ID:  $(state_get '.tunnel.pangolin.org_id')"
      echo -e "  Site ID: $(state_get '.tunnel.pangolin.site_id')"
      echo ""
      echo -e "${BOLD}Apps with Pangolin exposure:${RESET}"
      state_get '.apps | to_entries[] | select(.value.pangolin_resource_id != null) | "  \(.key) → resource \(.value.pangolin_resource_id) port \(.value.internal_port)"'
      echo ""
      pangolin_check_tunnel_health
      ;;
    *)
      echo "Usage: manage.sh pangolin <setup|add|remove|status|repair-db> [app]"
      ;;
  esac
}

_cmd_pangolin_setup() {
  log_step "Pangolin Setup"

  local already_enabled
  already_enabled=$(state_get '.pangolin.enabled')
  if [[ "$already_enabled" == "true" ]]; then
    log_warn "Pangolin is already configured."
    echo ""
    echo -e "  ${BOLD}Current Pangolin config:${RESET}"
    echo -e "  VPS:     $(state_get '.pangolin.vps_host')"
    echo -e "  Domain:  $(state_get '.pangolin.domain')"
    echo -e "  Org ID:  $(state_get '.pangolin.org_id')"
    echo -e "  Site ID: $(state_get '.pangolin.site_id')"
    echo ""
    if ! prompt_yn "Reconfigure?" "N"; then
      return 0
    fi
  fi

  cat <<EOF

  ${BOLD}Remote access with Pangolin (self-hosted on a VPS):${RESET}

  ${CYAN}  Any VPS with 1 vCPU / 512 MB RAM and a public IP will work.${RESET}

  Works with any ISP, including CGNAT. Zero port forwarding needed.

EOF

  prompt_select "Pangolin VPS:" \
    "Install Pangolin on a fresh VPS (recommended)" \
    "Connect to an existing Pangolin instance"

  if [[ "$REPLY" == Install* ]]; then
    # Full wizard — handles state persistence internally
    pangolin_wizard_fresh
  else
    # Existing instance
    pangolin_wizard_existing
    state_set "
      .pangolin.enabled = true |
      .pangolin.vps_host = \"${PANGOLIN_VPS_HOST:-}\" |
      .pangolin.org_id = \"${PANGOLIN_ORG_ID:-}\" |
      .pangolin.site_id = ${PANGOLIN_SITE_ID:-0} |
      .pangolin.newt_id = \"${NEWT_ID:-}\" |
      .pangolin.newt_secret = \"${NEWT_SECRET:-}\" |
      .pangolin.ssh_user = \"${PANGOLIN_SSH_USER:-root}\" |
      .pangolin.ssh_auth = \"${PANGOLIN_SSH_AUTH:-key}\" |
      .pangolin.ssh_key = \"${PANGOLIN_SSH_KEY:-}\"
    "
  fi

  # Register all already-installed apps with Pangolin
  log_sub "Registering all installed apps with Pangolin..."
  pangolin_register_all_apps

  # Add/update Newt service in compose and start it
  local dockerdir hostname compose_file
  dockerdir=$(state_get '.dockerdir')
  hostname=$(state_get '.hostname')
  compose_file="${dockerdir}/docker-compose-${hostname}.yml"

  local newt_id newt_secret pangolin_endpoint
  newt_id=$(state_get '.pangolin.newt_id')
  newt_secret=$(state_get '.pangolin.newt_secret')
  pangolin_endpoint=$(state_get '.pangolin.domain')
  [[ -n "$pangolin_endpoint" ]] || pangolin_endpoint=$(state_get '.pangolin.vps_host')

  if [[ -n "$newt_id" && -n "$newt_secret" && -f "$compose_file" ]]; then
    pangolin_setup_newt "$newt_id" "$newt_secret" "$pangolin_endpoint" "$compose_file"

    docker compose \
      --env-file "$(_env_file)" \
      -f "$compose_file" \
      up -d newt 2>/dev/null || log_warn "Could not start Newt — check compose file"

    log_ok "Newt tunnel client started"
  fi

  log_ok "Pangolin configured. All services now accessible remotely via tunnel."
}

_pangolin_add_single() {
  local app="$1"
  local subdomain="$2"
  local host_port="$3"
  local service_port="${4:-$host_port}"

  local internal_port
  internal_port=$(pangolin_alloc_port)

  local resource_id
  resource_id=$(pangolin_register_resource "$app" "$subdomain" "$service_port" "$internal_port")
  if [[ $? -eq 0 && -n "$resource_id" ]]; then
    app_state_set_pangolin "$app" "$resource_id" "$internal_port"
    pangolin_restart
    pangolin_restart_newt
    local domain
    domain=$(state_get '.domain')
    log_ok "$app exposed via Pangolin → https://${subdomain}.${domain}"
  else
    log_error "Failed to register $app with Pangolin"
  fi
}

# ─── Tunnel command (unified entry point for all tunnel methods) ───────────────

cmd_tunnel() {
  local subcmd="${1:-status}"
  shift || true

  local method
  method=$(state_get '.tunnel.method')

  case "$subcmd" in
    setup)
      # Re-run the tunnel wizard, regardless of current method
      local current_method
      current_method=$(state_get '.tunnel.method')
      [[ -n "$current_method" && "$current_method" != "none" ]] && \
        log_warn "Current method: ${current_method}. Reconfiguring will replace it."
      echo ""

      cat <<EOF
  ${BOLD}Public URL access${RESET} (services reachable from any browser):

  ${CYAN}1) Cloudflare Tunnel${RESET}  — FREE · No VPS · Easiest
  ${CYAN}2) Pangolin on a VPS${RESET}  — ~\$18/year · Self-hosted
     ${DIM}(+ add Cloudflare proxy on top for free DDoS protection)${RESET}

  ${BOLD}Private VPN access${RESET} (enrolled devices only):

  ${CYAN}3) Tailscale${RESET}          — FREE · WireGuard mesh · No VPS
  ${CYAN}4) Headscale${RESET}          — FREE · Self-hosted Tailscale · VPS required
  ${CYAN}5) Netbird${RESET}            — FREE · WireGuard mesh · Cloud or self-hosted

EOF
      prompt_select "Remote access method:" \
        "Cloudflare Tunnel (free, no VPS, public URLs)" \
        "Pangolin on a VPS (~\$18/year, self-hosted, public URLs)" \
        "Tailscale (private VPN, no public URLs)" \
        "Headscale (self-hosted Tailscale, VPS required)" \
        "Netbird (WireGuard mesh, cloud or self-hosted)"

      local dockerdir hostname compose_file
      dockerdir=$(state_get '.dockerdir')
      hostname=$(state_get '.hostname')
      compose_file="${dockerdir}/docker-compose-${hostname}.yml"

      case "$REPLY" in
        Cloudflare*)
          prompt_select "Cloudflare Tunnel:" \
            "Set up a new tunnel" \
            "Connect to an existing tunnel"
          if [[ "$REPLY" == Set* ]]; then
            cf_wizard_fresh
          else
            cf_wizard_existing
          fi
          local tunnel_token
          tunnel_token=$(state_get '.tunnel.cloudflare.tunnel_token')
          if [[ -n "$tunnel_token" && -f "$compose_file" ]]; then
            cf_setup_cloudflared "$tunnel_token" "$compose_file"
            docker compose --env-file "$(_env_file)" -f "$compose_file" \
              up -d cloudflared 2>/dev/null || log_warn "Could not start cloudflared"
          fi
          log_ok "Cloudflare Tunnel active — all services accessible remotely"
          ;;

        Pangolin*)
          _cmd_pangolin_setup
          ;;

        Tailscale*)
          tailscale_wizard
          if [[ -f "$compose_file" ]]; then
            tailscale_setup_compose "$compose_file"
            tailscale_write_env "$(_env_file)"
            docker compose --env-file "$(_env_file)" -f "$compose_file" \
              up -d tailscale 2>/dev/null || log_warn "Could not start tailscale container"
            log_ok "Tailscale VPN active"
          fi
          ;;

        Headscale*)
          prompt_select "Headscale setup:" \
            "Install Headscale on a fresh VPS" \
            "Connect to an existing Headscale instance"
          if [[ "$REPLY" == Install* ]]; then
            headscale_wizard_fresh
          else
            headscale_wizard_existing
          fi
          if [[ -f "$compose_file" ]]; then
            headscale_setup_compose "$compose_file"
            docker compose --env-file "$(_env_file)" -f "$compose_file" \
              up -d tailscale 2>/dev/null || log_warn "Could not start Headscale client"
            log_ok "Headscale VPN active"
          fi
          ;;

        Netbird*)
          netbird_wizard
          if [[ -f "$compose_file" ]]; then
            netbird_setup_compose "$compose_file"
            netbird_write_env "$(_env_file)"
            docker compose --env-file "$(_env_file)" -f "$compose_file" \
              up -d netbird 2>/dev/null || log_warn "Could not start Netbird container"
            log_ok "Netbird VPN active"
          fi
          ;;
      esac
      ;;

    status)
      local current_method
      current_method=$(state_get '.tunnel.method')
      echo -e "\n${BOLD}Remote Access:${RESET} ${current_method:-none}"
      echo ""
      case "$current_method" in
        cloudflare)
          echo -e "  Tunnel ID:   $(state_get '.tunnel.cloudflare.tunnel_id')"
          echo -e "  Tunnel Name: $(state_get '.tunnel.cloudflare.tunnel_name')"
          echo ""
          log_sub "Checking tunnel connectivity..."
          cf_status 2>/dev/null || log_warn "Could not reach Cloudflare API"
          ;;
        pangolin)
          echo -e "  VPS:     $(state_get '.tunnel.pangolin.vps_host')"
          echo -e "  Domain:  $(state_get '.tunnel.pangolin.domain')"
          echo -e "  Org ID:  $(state_get '.tunnel.pangolin.org_id')"
          echo -e "  Site ID: $(state_get '.tunnel.pangolin.site_id')"
          echo ""
          echo -e "${BOLD}Apps with Pangolin exposure:${RESET}"
          state_get '.apps | to_entries[] | select(.value.pangolin_resource_id != null) | "  \(.key) → resource \(.value.pangolin_resource_id) port \(.value.internal_port)"'
          echo ""
          log_sub "Checking tunnel connectivity..."
          pangolin_check_tunnel_health
          ;;
        tailscale)
          tailscale_status
          ;;
        headscale)
          headscale_status
          ;;
        netbird)
          netbird_status
          ;;
        none|"")
          log_warn "No remote access configured."
          log_info "Set it up: ./manage.sh tunnel setup"
          ;;
      esac
      ;;

    cloudflare-proxy)
      # Enable Cloudflare proxy (orange cloud) on top of existing Pangolin DNS records
      local cf_token
      cf_token=$(state_get '.cloudflare_api_token')
      [[ -n "$cf_token" && "$cf_token" != "null" ]] || {
        prompt_secret "Cloudflare API token"
        cf_token="$REPLY"
      }
      cf_init "$cf_token"
      local domain
      domain=$(state_get '.domain')
      cf_get_zone_id "$domain" > /dev/null
      cf_enable_proxy_on_pangolin "$domain"
      echo ""
      log_info "Next: set SSL/TLS mode to 'Full (strict)' in Cloudflare dashboard"
      log_info "→ dash.cloudflare.com/${domain}/ssl-tls"
      ;;

    tailscale)
      # Quick Tailscale subcommand
      local ts_sub="${1:-status}"
      case "$ts_sub" in
        status) tailscale_status ;;
        funnel)
          log_info "Enable Funnel for public HTTPS access:"
          log_info "  docker exec tailscale tailscale funnel 443"
          log_info "  (Requires Tailscale account with Funnel enabled)"
          ;;
        *) echo "Usage: manage.sh tunnel tailscale <status|funnel>" ;;
      esac
      ;;

    headscale)
      # Quick Headscale subcommand
      local hs_sub="${1:-status}"
      case "$hs_sub" in
        status) headscale_status ;;
        nodes)
          log_sub "Listing nodes registered in Headscale..."
          _hs_init_connection
          _hs_ssh "docker exec headscale headscale nodes list" || log_warn "Could not connect to VPS"
          ;;
        new-key)
          local hs_username
          hs_username=$(state_get '.tunnel.headscale.username')
          log_sub "Generating new pre-auth key for '${hs_username}'..."
          _hs_init_connection
          headscale_get_preauth_key "$hs_username"
          local new_key
          new_key=$(state_get '.tunnel.headscale.preauth_key')
          log_ok "New pre-auth key: ${new_key}"
          log_info "Use on new device: tailscale up --login-server=$(state_get '.tunnel.headscale.server_url') --auth-key=${new_key}"
          ;;
        *) echo "Usage: manage.sh tunnel headscale <status|nodes|new-key>" ;;
      esac
      ;;

    netbird)
      # Quick Netbird subcommand
      local nb_sub="${1:-status}"
      case "$nb_sub" in
        status) netbird_status ;;
        *) echo "Usage: manage.sh tunnel netbird <status>" ;;
      esac
      ;;

    *)
      echo "Usage: manage.sh tunnel <setup|status|cloudflare-proxy|tailscale|headscale|netbird>"
      ;;
  esac
}

# ─── Security subcommands ─────────────────────────────────────────────────────

cmd_security() {
  local subcmd="${1:-help}"
  shift || true

  case "$subcmd" in
    crowdsec-setup)
      _cmd_crowdsec_setup
      ;;
    auth)
      _cmd_auth_setup
      ;;
    *)
      echo "Usage: manage.sh security <crowdsec-setup|auth>"
      echo ""
      echo "  crowdsec-setup    Generate CrowdSec bouncer API key and configure Traefik bouncer"
      echo "  auth              Add or change the authentication layer (TinyAuth / Basic Auth)"
      ;;
  esac
}

_cmd_crowdsec_setup() {
  log_step "CrowdSec Bouncer API Key Setup"

  local dockerdir
  dockerdir=$(state_get '.dockerdir')

  # Check CrowdSec is running
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^crowdsec$'; then
    log_warn "CrowdSec container is not running."
    log_info "Start it first: docker compose up -d crowdsec"
    log_info "Then wait ~30 seconds for it to initialize, and run this command again."
    return 1
  fi

  log_sub "Generating Traefik bouncer API key from CrowdSec..."
  local api_key
  api_key=$(docker exec crowdsec cscli bouncers add traefik-bouncer -o raw 2>/dev/null) \
    || api_key=$(docker exec crowdsec cscli bouncers add traefik-bouncer --output raw 2>/dev/null) \
    || { log_error "Could not generate bouncer key — check CrowdSec logs: docker logs crowdsec"; return 1; }

  if [[ -z "$api_key" ]]; then
    # Maybe bouncer already exists — delete and recreate
    log_sub "Bouncer may already exist — recreating..."
    docker exec crowdsec cscli bouncers delete traefik-bouncer 2>/dev/null || true
    api_key=$(docker exec crowdsec cscli bouncers add traefik-bouncer -o raw 2>/dev/null || echo "")
  fi

  [[ -n "$api_key" ]] || { log_error "Failed to generate CrowdSec bouncer API key"; return 1; }

  # Write to .env file
  local env_file="${dockerdir}/.env"
  if grep -q "^CROWDSEC_TRAEFIK_BOUNCER_API_KEY=" "$env_file" 2>/dev/null; then
    sed -i "s|^CROWDSEC_TRAEFIK_BOUNCER_API_KEY=.*|CROWDSEC_TRAEFIK_BOUNCER_API_KEY=${api_key}|" "$env_file"
  else
    printf '\nCROWDSEC_TRAEFIK_BOUNCER_API_KEY=%s\n' "$api_key" >> "$env_file"
  fi

  log_ok "CrowdSec bouncer API key written to .env"
  log_sub "Restarting traefik-bouncer..."
  docker compose --env-file "$env_file" -f "$(_compose_file)" restart traefik-bouncer 2>/dev/null \
    || log_warn "Could not restart traefik-bouncer automatically"

  log_ok "CrowdSec is active — Traefik requests now run through the bouncer"

  echo ""
  echo -e "  ${BOLD}Next steps (optional):${RESET}"
  echo -e "  • Install community scenarios: ${CYAN}docker exec crowdsec cscli hub update && cscli collections install crowdsecurity/traefik${RESET}"
  echo -e "  • View ban list:               ${CYAN}docker exec crowdsec cscli decisions list${RESET}"
  echo -e "  • View alerts:                 ${CYAN}docker exec crowdsec cscli alerts list${RESET}"
  echo ""
}

_cmd_auth_setup() {
  log_step "Authentication Setup"

  local current_auth
  current_auth=$(state_get '.traefik.auth_system // "none"')
  log_info "Current auth system: ${current_auth}"
  echo ""

  # Re-use the same wizard
  traefik_select_auth

  local new_auth="${TRAEFIK_AUTH_SYSTEM}"
  local dockerdir hostname
  dockerdir=$(state_get '.dockerdir')
  hostname=$(state_get '.hostname')

  # Regenerate chain files with new auth selection
  local crowdsec_enabled
  crowdsec_enabled=$(state_get '.traefik.crowdsec_enabled // "false"')
  traefik_scaffold_chains "$hostname" "$dockerdir"

  # Set up credentials for new auth system
  case "$new_auth" in
    tinyauth)
      tinyauth_setup_secret "$dockerdir"
      if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^tinyauth$'; then
        log_info "TinyAuth container is not in your compose file yet."
        log_info "Add it by running: ./manage.sh regen"
      else
        tinyauth_setup_user "$dockerdir"
        docker compose --env-file "$(_env_file)" -f "$(_compose_file)" restart tinyauth 2>/dev/null || true
      fi
      ;;
    basic)
      traefik_setup_basic_auth "$dockerdir"
      ;;
  esac

  # Traefik picks up chain file changes automatically (file provider watches)
  log_ok "Auth chains updated — Traefik will reload automatically"
  traefik_show_auth_guide
}

# ─── cmd_regen — updated to use new compose writers ──────────────────────────

_cmd_regen_compose() {
  local dockerdir hostname
  dockerdir=$(state_get '.dockerdir')
  hostname=$(state_get '.hostname')
  local compose_file="${dockerdir}/docker-compose-${hostname}.yml"
  backup_file "$compose_file"

  local access_mode auth_system crowdsec_enabled
  access_mode=$(state_get '.traefik.access_mode // "hybrid"')
  auth_system=$(state_get '.traefik.auth_system // "tinyauth"')
  crowdsec_enabled=$(state_get '.traefik.crowdsec_enabled // "false"')

  cat > "$compose_file" <<EOF
# docker-compose-${hostname}.yml
# Regenerated by portless manage.sh on $(date)
# Manage with: ./manage.sh

name: ${hostname}

networks:
  default:
    driver: bridge
  socket_proxy:
    name: socket_proxy
    external: true
  t3_proxy:
    name: t3_proxy
    external: true

secrets:
  basic_auth_credentials:
    file: \${DOCKERDIR}/secrets/basic_auth_credentials
  cf_dns_api_token:
    file: \${DOCKERDIR}/secrets/cf_dns_api_token
  tinyauth_secret:
    file: \${DOCKERDIR}/secrets/tinyauth_secret
  plex_claim:
    file: \${DOCKERDIR}/secrets/plex_claim

services:
EOF

  # Core: socket-proxy + Traefik (wizard-aware)
  traefik_write_compose_service "$compose_file" "$access_mode" "$auth_system"

  [[ "$crowdsec_enabled" == "true" ]] && crowdsec_write_compose_service "$compose_file"
  [[ "$auth_system" == "tinyauth" ]]  && tinyauth_write_compose_service "$compose_file"

  # Installed apps
  local SCRIPT_DIR
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local apps
  apps=$(app_list_installed)
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    local src="${SCRIPT_DIR}/compose/${hostname}/${app}.yml"
    [[ -f "$src" ]] || src="${SCRIPT_DIR}/compose/hs/${app}.yml"
    [[ -f "$src" ]] || src="${SCRIPT_DIR}/compose/${app}.yml"
    if [[ -f "$src" ]]; then
      echo "" >> "$compose_file"
      echo "  ########## ${app^^} ##########" >> "$compose_file"
      grep -v "^services:" "$src" \
        | grep -v "^[[:space:]]*profiles:" \
        >> "$compose_file" || true
    fi
  done <<< "$apps"

  log_ok "Compose file regenerated: $compose_file"
}

# ─── Help ─────────────────────────────────────────────────────────────────────

cmd_help() {
  cat <<EOF

${BOLD}portless v${PORTLESS_VERSION} — manage.sh${RESET}

${BOLD}USAGE:${RESET}
  ./manage.sh <command> [args]

${BOLD}COMMANDS:${RESET}
  ${CYAN}add <app>${RESET}                   Add a new app to the stack
  ${CYAN}remove <app>${RESET}                Stop and remove an app
  ${CYAN}update [app]${RESET}                Pull latest images and restart (all or one)
  ${CYAN}status${RESET}                      Show running containers + URLs
  ${CYAN}logs <app>${RESET}                  Tail container logs
  ${CYAN}regen${RESET}                       Regenerate compose + Traefik rules from state

  ${CYAN}security crowdsec-setup${RESET}     Generate CrowdSec bouncer API key
  ${CYAN}security auth${RESET}               Change or configure the auth layer (TinyAuth / Basic Auth)

  ${CYAN}tunnel setup${RESET}                Set up or switch remote access method
  ${CYAN}tunnel status${RESET}               Show current tunnel config and connectivity
  ${CYAN}tunnel cloudflare-proxy${RESET}     Enable Cloudflare proxy on Pangolin DNS records
  ${CYAN}tunnel tailscale status${RESET}     Show Tailscale peer status
  ${CYAN}tunnel tailscale funnel${RESET}     Instructions for Tailscale Funnel (public URLs)
  ${CYAN}tunnel headscale status${RESET}     Show Headscale peer status
  ${CYAN}tunnel headscale nodes${RESET}      List nodes registered in Headscale
  ${CYAN}tunnel headscale new-key${RESET}    Generate a new Headscale pre-auth key
  ${CYAN}tunnel netbird status${RESET}       Show Netbird peer status

  ${CYAN}pangolin setup${RESET}              (Re)configure Pangolin tunnel
  ${CYAN}pangolin add <app>${RESET}          Expose a specific app via Pangolin
  ${CYAN}pangolin remove <app>${RESET}       Remove Pangolin exposure for an app
  ${CYAN}pangolin status${RESET}             Show Pangolin config, exposed apps, tunnel health
  ${CYAN}pangolin repair-db${RESET}          Fix admin access grants + resource visibility
  ${CYAN}pangolin diagnose${RESET}           Dump routing state (sites, resources, targets)
  ${CYAN}pangolin fix-404${RESET}            Fix 404s: method, enableProxy, domain linking
  ${CYAN}pangolin fix-404 --dry-run${RESET}  Preview fixes without applying

${BOLD}SUPPORTED APPS:${RESET}
$(ls "${SCRIPT_DIR}/lib/apps/"*.sh 2>/dev/null | xargs -I{} basename {} .sh | sed 's/^/  /')

${BOLD}EXAMPLES:${RESET}
  ./manage.sh add radarr
  ./manage.sh security crowdsec-setup
  ./manage.sh security auth
  ./manage.sh tunnel setup
  ./manage.sh tunnel cloudflare-proxy
  ./manage.sh update radarr
  ./manage.sh status
  ./manage.sh logs sonarr

EOF
}

# ─── Main dispatcher ──────────────────────────────────────────────────────────

_load_state

case "${1:-help}" in
  add)         shift; cmd_add "$@" ;;
  remove|rm)   shift; cmd_remove "$@" ;;
  update)      shift; cmd_update "$@" ;;
  status|ps)   cmd_status ;;
  logs)        shift; cmd_logs "$@" ;;
  regen)       cmd_regen ;;
  tunnel)      shift; cmd_tunnel "$@" ;;
  pangolin)    shift; cmd_pangolin "$@" ;;
  security)    shift; cmd_security "$@" ;;
  help|--help|-h) cmd_help ;;
  version|--version|-V) echo "portless v${PORTLESS_VERSION}" ;;
  *)
    log_error "Unknown command: ${1:-}"
    cmd_help
    exit 1
    ;;
esac
