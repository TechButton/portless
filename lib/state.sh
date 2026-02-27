#!/usr/bin/env bash
# lib/state.sh — Read/write .homelab-state.json via jq

[[ -n "$HOMELAB_COMMON_LOADED" ]] || source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
HOMELAB_STATE_LOADED=1

# Default state file location (can be overridden)
STATE_FILE="${DOCKERDIR:-$HOME/docker}/.homelab-state.json"

# ─── Initialization ──────────────────────────────────────────────────────────────

state_init() {
  local dockerdir="${1:-$HOME/docker}"
  STATE_FILE="${dockerdir}/.homelab-state.json"

  if [[ ! -f "$STATE_FILE" ]]; then
    log_sub "Initializing state file: $STATE_FILE"
    ensure_dir "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" <<'EOF'
{
  "hostname": "",
  "domain": "",
  "server_ip": "",
  "dockerdir": "",
  "auth_method": "",
  "cloudflare_api_token": "",
  "tunnel": {
    "method": "none",
    "cloudflare": {
      "account_id": "",
      "zone_id": "",
      "tunnel_id": "",
      "tunnel_name": "",
      "tunnel_token": ""
    },
    "pangolin": {
      "enabled": false,
      "vps_host": "",
      "domain": "",
      "org_id": "",
      "site_id": null,
      "newt_id": "",
      "newt_secret": "",
      "ssh_user": "root",
      "ssh_auth": "key",
      "ssh_key": "",
      "ssh_pass": "",
      "admin_email": "",
      "next_internal_port": 65400
    },
    "tailscale": {
      "auth_key": "",
      "hostname": "",
      "subnet_router": false
    },
    "headscale": {
      "vps_host": "",
      "server_url": "",
      "domain": "",
      "admin_email": "",
      "ssh_user": "root",
      "ssh_auth": "key",
      "ssh_key": "",
      "ssh_pass": "",
      "username": "",
      "preauth_key": ""
    },
    "netbird": {
      "self_hosted": false,
      "management_url": "",
      "setup_key": "",
      "vps_host": "",
      "domain": "",
      "admin_email": "",
      "ssh_user": "root",
      "ssh_auth": "key",
      "ssh_key": "",
      "ssh_pass": ""
    }
  },
  "apps": {}
}
EOF
  fi
}

# ─── Core read/write ─────────────────────────────────────────────────────────────

# state_get <jq_path>  e.g. state_get '.hostname'
state_get() {
  local path="$1"
  require_command jq
  jq -r "$path // empty" "$STATE_FILE" 2>/dev/null
}

# state_set <jq_filter>  e.g. state_set '.hostname = "themedia"'
state_set() {
  local filter="$1"
  require_command jq
  local tmp
  tmp=$(mktemp)
  jq "$filter" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE" || {
    rm -f "$tmp"
    die "Failed to update state file with filter: $filter"
  }
}

# state_set_kv <key> <value>  — sets top-level string key
state_set_kv() {
  local key="$1"
  local value="$2"
  state_set ".${key} = $(jq -n --arg v "$value" '$v')"
}

# state_set_num <key> <number>
state_set_num() {
  local key="$1"
  local value="$2"
  state_set ".${key} = ${value}"
}

# state_set_bool <key> true|false
state_set_bool() {
  local key="$1"
  local value="$2"
  state_set ".${key} = ${value}"
}

# ─── Pangolin state ──────────────────────────────────────────────────────────────

pangolin_state_enable() {
  local vps_host="$1"
  local org_id="$2"
  local site_id="$3"
  state_set "
    .tunnel.method = \"pangolin\" |
    .tunnel.pangolin.enabled = true |
    .tunnel.pangolin.vps_host = \"$vps_host\" |
    .tunnel.pangolin.org_id = \"$org_id\" |
    .tunnel.pangolin.site_id = $site_id
  "
}

pangolin_next_port() {
  local current
  current=$(state_get '.tunnel.pangolin.next_internal_port')
  current="${current:-65400}"
  local next=$((current + 1))
  state_set ".tunnel.pangolin.next_internal_port = $next"
  echo "$current"
}

tunnel_method() {
  state_get '.tunnel.method'
}

# ─── App state ───────────────────────────────────────────────────────────────────

# Mark app as installed with its config
# app_state_set_installed <name> <port> [subdomain]
app_state_set_installed() {
  local app="$1"
  local port="$2"
  local subdomain="${3:-$app}"
  local domain
  domain=$(state_get '.domain')

  state_set "
    .apps[\"$app\"].installed = true |
    .apps[\"$app\"].port = $port |
    .apps[\"$app\"].subdomain = \"$subdomain\" |
    .apps[\"$app\"].domain = \"${subdomain}.${domain}\"
  "
}

# Record Pangolin resource for an app
# app_state_set_pangolin <name> <resource_id> <internal_port>
app_state_set_pangolin() {
  local app="$1"
  local resource_id="$2"
  local internal_port="$3"

  state_set "
    .apps[\"$app\"].pangolin_resource_id = $resource_id |
    .apps[\"$app\"].internal_port = $internal_port
  "
}

app_state_remove_pangolin() {
  local app="$1"
  state_set "
    del(.apps[\"$app\"].pangolin_resource_id) |
    del(.apps[\"$app\"].internal_port)
  "
}

app_state_remove() {
  local app="$1"
  state_set "del(.apps[\"$app\"])"
}

app_is_installed() {
  local app="$1"
  local installed
  installed=$(state_get ".apps[\"$app\"].installed")
  [[ "$installed" == "true" ]]
}

app_has_pangolin() {
  local app="$1"
  local rid
  rid=$(state_get ".apps[\"$app\"].pangolin_resource_id")
  [[ -n "$rid" && "$rid" != "null" ]]
}

app_list_installed() {
  state_get '.apps | to_entries[] | select(.value.installed == true) | .key'
}

# ─── Load full state into env vars ───────────────────────────────────────────────

state_load() {
  STATE_HOSTNAME=$(state_get '.hostname')
  STATE_DOMAIN=$(state_get '.domain')
  STATE_SERVER_IP=$(state_get '.server_ip')
  STATE_DOCKERDIR=$(state_get '.dockerdir')
  STATE_AUTH_METHOD=$(state_get '.auth_method')
  STATE_TUNNEL_METHOD=$(state_get '.tunnel.method')
  STATE_PANGOLIN_ENABLED=$(state_get '.tunnel.pangolin.enabled')
  STATE_PANGOLIN_VPS=$(state_get '.tunnel.pangolin.vps_host')
  STATE_PANGOLIN_ORG=$(state_get '.tunnel.pangolin.org_id')
  STATE_PANGOLIN_SITE=$(state_get '.tunnel.pangolin.site_id')
  STATE_CF_TUNNEL_ID=$(state_get '.tunnel.cloudflare.tunnel_id')
  STATE_TS_HOSTNAME=$(state_get '.tunnel.tailscale.hostname')
  STATE_HEADSCALE_URL=$(state_get '.tunnel.headscale.server_url')
  STATE_NETBIRD_MODE=$(state_get '.tunnel.netbird.self_hosted')
  STATE_NETBIRD_URL=$(state_get '.tunnel.netbird.management_url')
}

# ─── Display state summary ───────────────────────────────────────────────────────

state_summary() {
  state_load
  echo -e "\n${BOLD}Current Configuration:${RESET}"
  echo -e "  Hostname:     ${CYAN}${STATE_HOSTNAME}${RESET}"
  echo -e "  Domain:       ${CYAN}${STATE_DOMAIN}${RESET}"
  echo -e "  Server IP:    ${CYAN}${STATE_SERVER_IP}${RESET}"
  echo -e "  Docker Dir:   ${CYAN}${STATE_DOCKERDIR}${RESET}"
  echo -e "  Auth:         ${CYAN}${STATE_AUTH_METHOD}${RESET}"

  local tunnel_method="${STATE_TUNNEL_METHOD:-none}"
  case "$tunnel_method" in
    cloudflare) echo -e "  Remote:       ${CYAN}Cloudflare Tunnel (${STATE_CF_TUNNEL_ID})${RESET}" ;;
    pangolin)   echo -e "  Remote:       ${CYAN}Pangolin (${STATE_PANGOLIN_VPS})${RESET}" ;;
    tailscale)  echo -e "  Remote:       ${CYAN}Tailscale (${STATE_TS_HOSTNAME:-device})${RESET}" ;;
    headscale)  echo -e "  Remote:       ${CYAN}Headscale — ${STATE_HEADSCALE_URL}${RESET}" ;;
    netbird)
      if [[ "$STATE_NETBIRD_MODE" == "true" ]]; then
        echo -e "  Remote:       ${CYAN}Netbird (self-hosted — ${STATE_NETBIRD_URL})${RESET}"
      else
        echo -e "  Remote:       ${CYAN}Netbird Cloud (app.netbird.io)${RESET}"
      fi
      ;;
    none)       echo -e "  Remote:       ${DIM}LAN only${RESET}" ;;
    *)          echo -e "  Remote:       ${CYAN}${tunnel_method}${RESET}" ;;
  esac

  local apps
  apps=$(app_list_installed)
  if [[ -n "$apps" ]]; then
    echo -e "\n  ${BOLD}Installed apps:${RESET}"
    while IFS= read -r app; do
      local domain
      domain=$(state_get ".apps[\"$app\"].domain")
      local pangolin=""
      app_has_pangolin "$app" && pangolin=" [pangolin]"
      echo -e "    ${GREEN}✓${RESET} ${app} → https://${domain}${pangolin}"
    done <<< "$apps"
  fi
}
