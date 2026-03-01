#!/usr/bin/env bash
# gui.sh — Portless TUI
#
# whiptail-based launcher for install.sh (first run) and manage.sh (ongoing).
#
# Usage:
#   ./gui.sh            — auto-detect first run vs management
#   ./gui.sh --setup    — force setup wizard
#   ./gui.sh --manage   — force management menu
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PORTLESS_VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "0.5.0")"
TITLE="portless v${PORTLESS_VERSION}"

# ─── TUI backend ──────────────────────────────────────────────────────────────

if command -v whiptail &>/dev/null; then
  TUI=whiptail
elif command -v dialog &>/dev/null; then
  TUI=dialog
else
  echo "ERROR: whiptail or dialog is required for the GUI."
  echo "Install: sudo apt-get install whiptail"
  echo "Or use the CLI directly: ./install.sh  or  ./manage.sh"
  exit 1
fi

# Dark color theme — overrides whiptail's default pink/red
export NEWT_COLORS='
root=white,black
window=white,black
border=cyan,black
title=cyan,black
textbox=white,black
listbox=white,black
actlistbox=black,cyan
actsellistbox=black,cyan
button=black,cyan
actbutton=black,white
compactbutton=white,black
checkbox=white,black
actcheckbox=black,cyan
entry=white,black
label=white,black
'

# Dimensions helpers
_W() { echo "${COLUMNS:-80}"; }       # terminal width
_H() { echo "${LINES:-24}"; }         # terminal height
BOX_H=22
BOX_W=76

# ─── TUI primitives ───────────────────────────────────────────────────────────

# _input <title> <prompt> <default>  → captured in $TUI_RESULT
_input() {
  TUI_RESULT=$(
    $TUI --title "$TITLE — $1" --inputbox "$2" 10 $BOX_W "${3:-}" 3>&1 1>&2 2>&3
  ) || return 1
}

# _secret <title> <prompt>  → captured in $TUI_RESULT
_secret() {
  TUI_RESULT=$(
    $TUI --title "$TITLE — $1" --passwordbox "$2" 10 $BOX_W 3>&1 1>&2 2>&3
  ) || return 1
}

# _yesno <title> <prompt> [yes|no default=yes]  → 0=yes 1=no
_yesno() {
  local extra=""
  [[ "${3:-yes}" == "no" ]] && extra="--defaultno"
  # shellcheck disable=SC2086
  $TUI --title "$TITLE — $1" --yesno "$2" 10 $BOX_W $extra 3>&1 1>&2 2>&3
}

# _msg <title> <message>
_msg() {
  $TUI --title "$TITLE — $1" --msgbox "$2" $BOX_H $BOX_W 3>&1 1>&2 2>&3 || true
}

# _info <message>  (no button, 2s auto-dismiss)
_info() {
  $TUI --title "$TITLE" --infobox "$1" 7 $BOX_W 3>&1 1>&2 2>&3 || true
}

# _menu <title> <prompt> <items...>  → captured in $TUI_RESULT
# items: "tag" "description" pairs
_menu() {
  local title="$1" prompt="$2"; shift 2
  local nitems=$(( $# / 2 ))
  TUI_RESULT=$(
    $TUI --title "$TITLE — $title" --menu "$prompt" $BOX_H $BOX_W "$nitems" "$@" 3>&1 1>&2 2>&3
  ) || return 1
}

# _checklist <title> <prompt> <items...>  → captured in $TUI_RESULT (space-separated)
# items: "tag" "description" "on|off" triples
_checklist() {
  local title="$1" prompt="$2"; shift 2
  local nitems=$(( $# / 3 ))
  # Cap list height so the box doesn't overflow and scrollbar appears
  local list_h=$(( nitems < BOX_H - 8 ? nitems : BOX_H - 8 ))
  TUI_RESULT=$(
    $TUI --title "$TITLE — $title" --checklist "$prompt" $BOX_H $BOX_W "$list_h" "$@" 3>&1 1>&2 2>&3
  ) || return 1
}

# _radiolist <title> <prompt> <items...>  → captured in $TUI_RESULT
# items: "tag" "description" "on|off" triples
_radiolist() {
  local title="$1" prompt="$2"; shift 2
  local nitems=$(( $# / 3 ))
  local list_h=$(( nitems < BOX_H - 8 ? nitems : BOX_H - 8 ))
  TUI_RESULT=$(
    $TUI --title "$TITLE — $title" --radiolist "$prompt" $BOX_H $BOX_W "$list_h" "$@" 3>&1 1>&2 2>&3
  ) || return 1
}

# _form <title> <prompt> <fields...>  → captured in $TUI_RESULT (newline-separated)
# fields: "label" row col "default" row col width maxlen tuples (8 values each)
_form() {
  local title="$1" prompt="$2"; shift 2
  TUI_RESULT=$(
    $TUI --title "$TITLE — $title" --form "$prompt" $BOX_H $BOX_W 9 "$@" 3>&1 1>&2 2>&3
  ) || return 1
}

# _run <description> <cmd...>  — clear screen, run command, pause on finish
_run() {
  local desc="$1"; shift
  clear
  echo "╔══════════════════════════════════════════════════════════════╗"
  printf  "║  %-60s  ║\n" "$desc"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  "$@" || true
  echo ""
  echo "────────────────────────────────────────────"
  echo "  Press Enter to return to the menu..."
  read -r
}

# ─── State detection ──────────────────────────────────────────────────────────

_find_state_file() {
  local candidates=(
    "${DOCKERDIR:-}/.portless-state.json"
    "$HOME/docker/.portless-state.json"
    "/opt/docker/.portless-state.json"
  )
  for f in "${candidates[@]}"; do
    [[ -n "$f" && -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

_is_setup_done() {
  local sf
  sf=$(_find_state_file 2>/dev/null) || return 1
  local done
  done=$(jq -r '.install.phases.phase5 // false' "$sf" 2>/dev/null || echo "false")
  [[ "$done" == "true" ]]
}

# ─── State helpers (for management menu) ─────────────────────────────────────

_state_get() {
  local sf
  sf=$(_find_state_file 2>/dev/null) || echo ""
  [[ -n "$sf" ]] && jq -r "${1} // empty" "$sf" 2>/dev/null || true
}

_list_installed_apps() {
  _state_get '.apps | to_entries[] | select(.value.installed == true) | .key'
}

_list_available_apps() {
  ls "${SCRIPT_DIR}/lib/apps/"*.sh 2>/dev/null | xargs -I{} basename {} .sh | sort
}

# ─── First-run wizard ─────────────────────────────────────────────────────────

_wizard_page1_basic() {
  # Detect sensible defaults
  local def_hostname def_user def_tz def_dockerdir def_datadir
  def_hostname=$(hostname -s 2>/dev/null || echo "homeserver")
  def_user=$(id -un 2>/dev/null || echo "$USER")
  def_tz=$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo "America/New_York")
  def_dockerdir="$HOME/docker"
  def_datadir="/mnt/data"

  _form "Setup (1/6) — Basic Configuration" \
"Fill in the fields below. Press Tab to move between fields.
Arrow keys scroll — press Enter when done." \
    "Server nickname:"   1 1 "$def_hostname"   1 24 28 64 \
    "Linux username:"    2 1 "$def_user"        2 24 28 64 \
    "Timezone:"         3 1 "$def_tz"          3 24 28 64 \
    "Docker data dir:"  4 1 "$def_dockerdir"   4 24 28 128 \
    "Media/data dir:"   5 1 "$def_datadir"     5 24 28 128 || return 1

  INSTALL_HOSTNAME=$(echo "$TUI_RESULT" | sed -n '1p')
  INSTALL_USER=$(echo     "$TUI_RESULT" | sed -n '2p')
  INSTALL_TIMEZONE=$(echo "$TUI_RESULT" | sed -n '3p')
  INSTALL_DOCKERDIR=$(echo "$TUI_RESULT" | sed -n '4p')
  INSTALL_DATADIR=$(echo  "$TUI_RESULT" | sed -n '5p')

  # Validate non-empty
  [[ -n "$INSTALL_HOSTNAME" ]] || { _msg "Error" "Hostname cannot be empty."; return 1; }
  [[ -n "$INSTALL_USER"     ]] || { _msg "Error" "Username cannot be empty."; return 1; }
}

_wizard_page2_network() {
  # Auto-detect LAN IP
  local def_ip
  def_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "")

  _form "Setup (2/6) — Network & Domain" \
"Your domain must point to this server for TLS certificates." \
    "Server LAN IP:"   1 1 "${def_ip}"   1 22 30 64 \
    "Domain name:"     2 1 ""            2 22 30 128 || return 1

  INSTALL_SERVER_IP=$(echo "$TUI_RESULT" | sed -n '1p')
  INSTALL_DOMAIN=$(echo    "$TUI_RESULT" | sed -n '2p')

  [[ -n "$INSTALL_DOMAIN" ]] || { _msg "Error" "Domain name is required."; return 1; }

  # DNS provider selection
  _radiolist "Setup (2/6) — DNS Provider" \
"Which DNS provider manages your domain?
(Used for automatic TLS certificates via Let's Encrypt)" \
    "cloudflare" "Cloudflare (recommended — free + fast)" "on" \
    "other"      "Other / manual DNS"                     "off" || return 1
  INSTALL_DNS_PROVIDER="$TUI_RESULT"

  if [[ "$INSTALL_DNS_PROVIDER" == "cloudflare" ]]; then
    _secret "Setup (2/6) — Cloudflare" \
"Cloudflare API token (needs DNS:Edit permission for your zone):" || return 1
    INSTALL_CF_TOKEN="$TUI_RESULT"

    _input "Setup (2/6) — Cloudflare" "Cloudflare account email:" "" || return 1
    INSTALL_CF_EMAIL="$TUI_RESULT"
  fi
}

_wizard_page3_traefik() {
  _radiolist "Setup (3/6) — Traefik Access Mode" \
"How should Traefik handle incoming requests?" \
    "external" "External only — Traefik faces the internet directly"    "off" \
    "hybrid"   "Hybrid — LAN + optional tunnel (recommended)"          "on"  \
    "local"    "Local only — LAN access, no public exposure"            "off" || return 1
  INSTALL_TRAEFIK_MODE="$TUI_RESULT"

  _radiolist "Setup (3/6) — Authentication" \
"How should apps be protected when accessed remotely?" \
    "tinyauth" "TinyAuth — simple built-in SSO (recommended)" "on"  \
    "basic"    "HTTP Basic Auth — username + password prompt"  "off" \
    "none"     "None — no authentication layer"                "off" || return 1
  INSTALL_AUTH_SYSTEM="$TUI_RESULT"
}

_wizard_page4_tunnel() {
  _radiolist "Setup (4/6) — Remote Access Tunnel" \
"How do you want to access your services from outside your home?
(You can change this later with: ./manage.sh tunnel setup)" \
    "cloudflare" "Cloudflare Tunnel — free, no VPS, easiest"      "off" \
    "pangolin"   "Pangolin on a VPS — self-hosted, ~\$18/yr"       "on"  \
    "tailscale"  "Tailscale VPN — private access, enrolled devices only"  "off" \
    "headscale"  "Headscale VPN — self-hosted Tailscale, VPS needed"      "off" \
    "netbird"    "Netbird VPN — WireGuard mesh, cloud or self-hosted"      "off" \
    "none"       "None — LAN only, no external access"              "off" || return 1
  INSTALL_TUNNEL="$TUI_RESULT"
}

_wizard_page5_apps() {
  # Popular defaults
  local popular=(sonarr radarr prowlarr qbittorrent jellyfin portainer homepage)

  # Build checklist items: "app" "description" "on|off"
  local items=()
  local app_name
  while IFS= read -r app_name; do
    local state="off"
    for p in "${popular[@]}"; do [[ "$app_name" == "$p" ]] && state="on"; done
    # Get display name from catalog if available
    local label="$app_name"
    items+=("$app_name" "$label" "$state")
  done < <(_list_available_apps)

  _checklist "Setup (5/6) — Apps to Install" \
"Select apps to install. Space to toggle, Enter when done.
(You can add/remove apps later with: ./manage.sh add/remove <app>)" \
    "${items[@]}" || { INSTALL_APPS=""; return 0; }

  # whiptail returns quoted items — strip quotes and join with commas
  INSTALL_APPS=$(echo "$TUI_RESULT" | tr -d '"' | tr ' ' ',')
}

_wizard_page6_confirm() {
  local summary
  summary="Ready to install with these settings:

  Hostname:    ${INSTALL_HOSTNAME:-?}
  User:        ${INSTALL_USER:-?}
  Timezone:    ${INSTALL_TIMEZONE:-?}
  Docker dir:  ${INSTALL_DOCKERDIR:-?}
  Data dir:    ${INSTALL_DATADIR:-?}
  Domain:      ${INSTALL_DOMAIN:-?}
  Server IP:   ${INSTALL_SERVER_IP:-?}
  DNS:         ${INSTALL_DNS_PROVIDER:-?}
  Traefik:     ${INSTALL_TRAEFIK_MODE:-hybrid}
  Auth:        ${INSTALL_AUTH_SYSTEM:-tinyauth}
  Tunnel:      ${INSTALL_TUNNEL:-none}
  Apps:        ${INSTALL_APPS:-none}

Press OK to start the installation, or Cancel to go back."

  _msg "Setup (6/6) — Confirm" "$summary" || return 1
}

_run_first_install() {
  clear
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║              portless — Running Setup                       ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  The wizard will now run the full installation."
  echo "  Some steps require sudo. You may be prompted for your password."
  echo ""

  # Export all collected variables for install.sh to consume
  export INSTALL_HOSTNAME INSTALL_USER INSTALL_TIMEZONE INSTALL_DOCKERDIR INSTALL_DATADIR
  export INSTALL_DOMAIN INSTALL_DNS_PROVIDER INSTALL_SERVER_IP
  export INSTALL_TRAEFIK_MODE INSTALL_AUTH_SYSTEM INSTALL_TUNNEL INSTALL_APPS
  [[ -n "${INSTALL_CF_TOKEN:-}"  ]] && export INSTALL_CF_TOKEN
  [[ -n "${INSTALL_CF_EMAIL:-}"  ]] && export INSTALL_CF_EMAIL

  bash "${SCRIPT_DIR}/install.sh"
}

_wizard() {
  _wizard_page1_basic    || { _msg "Cancelled" "Setup cancelled at basic config.";   return 1; }
  _wizard_page2_network  || { _msg "Cancelled" "Setup cancelled at network config."; return 1; }
  _wizard_page3_traefik  || { _msg "Cancelled" "Setup cancelled at Traefik config."; return 1; }
  _wizard_page4_tunnel   || { _msg "Cancelled" "Setup cancelled at tunnel config.";  return 1; }
  _wizard_page5_apps     || { _msg "Cancelled" "Setup cancelled at app selection.";  return 1; }
  _wizard_page6_confirm  || { _msg "Cancelled" "Installation cancelled. Run ./gui.sh to restart."; return 1; }
  _run_first_install
}

# ─── Management menu ──────────────────────────────────────────────────────────

_menu_apps() {
  while true; do
    _menu "Apps" "App management:" \
      "add"    "Add an app" \
      "remove" "Remove an app" \
      "update" "Update (pull latest images)" \
      "back"   "← Back" || return 0

    case "$TUI_RESULT" in
      add)    _menu_add_app    ;;
      remove) _menu_remove_app ;;
      update) _menu_update_app ;;
      back)   return 0 ;;
    esac
  done
}

_menu_add_app() {
  # Build checklist of available but not-yet-installed apps
  local installed
  installed=$(_list_installed_apps)
  local items=()
  local app_name
  while IFS= read -r app_name; do
    echo "$installed" | grep -qxF "$app_name" && continue  # already installed
    items+=("$app_name" "$app_name" "off")
  done < <(_list_available_apps)

  [[ "${#items[@]}" -eq 0 ]] && { _msg "All installed" "All available apps are already installed."; return; }

  _checklist "Add Apps" \
"Select apps to add. Space to toggle, Enter when done:" \
    "${items[@]}" || return 0

  local selected
  selected=$(echo "$TUI_RESULT" | tr -d '"')

  for app in $selected; do
    _run "Adding: $app" "${SCRIPT_DIR}/manage.sh" add "$app"
  done
}

_menu_remove_app() {
  local installed
  installed=$(_list_installed_apps)
  [[ -z "$installed" ]] && { _msg "Nothing installed" "No apps are currently installed."; return; }

  local items=()
  while IFS= read -r app; do
    [[ -n "$app" ]] && items+=("$app" "$app" "off")
  done <<< "$installed"

  _checklist "Remove Apps" \
"Select apps to remove. Containers and rules will be removed
(app data directories are NOT deleted):" \
    "${items[@]}" || return 0

  local selected
  selected=$(echo "$TUI_RESULT" | tr -d '"')
  for app in $selected; do
    _run "Removing: $app" "${SCRIPT_DIR}/manage.sh" remove "$app"
  done
}

_menu_update_app() {
  local installed
  installed=$(_list_installed_apps)

  local items=("ALL" "Update all apps" "off")
  while IFS= read -r app; do
    [[ -n "$app" ]] && items+=("$app" "$app" "off")
  done <<< "$installed"

  _radiolist "Update" "Select app to update (or ALL):" "${items[@]}" || return 0

  if [[ "$TUI_RESULT" == "ALL" ]]; then
    _run "Updating all apps" "${SCRIPT_DIR}/manage.sh" update
  else
    _run "Updating: $TUI_RESULT" "${SCRIPT_DIR}/manage.sh" update "$TUI_RESULT"
  fi
}

_menu_tunnel() {
  while true; do
    local method
    method=$(_state_get '.tunnel.method // "none"')

    _menu "Tunnel" "Remote access tunnel (current: ${method}):" \
      "status"    "Status & health check" \
      "setup"     "Set up / switch tunnel method" \
      "repair-db" "Repair Pangolin database (fix admin access)" \
      "cf-proxy"  "Enable Cloudflare proxy on Pangolin DNS" \
      "back"      "← Back" || return 0

    case "$TUI_RESULT" in
      status)    _run "Tunnel status"        "${SCRIPT_DIR}/manage.sh" tunnel status ;;
      setup)     _run "Tunnel setup"         "${SCRIPT_DIR}/manage.sh" tunnel setup ;;
      repair-db) _run "Pangolin DB repair"   "${SCRIPT_DIR}/manage.sh" pangolin repair-db ;;
      cf-proxy)  _run "Cloudflare proxy"     "${SCRIPT_DIR}/manage.sh" tunnel cloudflare-proxy ;;
      back)      return 0 ;;
    esac
  done
}

_menu_security() {
  while true; do
    _menu "Security" "Security settings:" \
      "auth"     "Change authentication layer (TinyAuth / Basic Auth)" \
      "crowdsec" "Set up CrowdSec bouncer API key" \
      "back"     "← Back" || return 0

    case "$TUI_RESULT" in
      auth)     _run "Auth setup"    "${SCRIPT_DIR}/manage.sh" security auth ;;
      crowdsec) _run "CrowdSec setup" "${SCRIPT_DIR}/manage.sh" security crowdsec-setup ;;
      back)     return 0 ;;
    esac
  done
}

_menu_logs() {
  local installed
  installed=$(_list_installed_apps)
  local all_containers
  all_containers=$(docker ps --format '{{.Names}}' 2>/dev/null | sort || true)

  # Build menu from installed apps + running containers
  local items=()
  local seen=()
  while IFS= read -r app; do
    [[ -n "$app" ]] && { items+=("$app" "$app"); seen+=("$app"); }
  done <<< "$installed"
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    local found=false
    for s in "${seen[@]:-}"; do [[ "$c" == "$s" ]] && found=true; done
    "$found" || items+=("$c" "$c (container)")
  done <<< "$all_containers"

  [[ "${#items[@]}" -eq 0 ]] && { _msg "No containers" "No running containers found."; return; }

  items+=("back" "← Back")

  _menu "Logs" "Select container to view logs:" "${items[@]}" || return 0
  [[ "$TUI_RESULT" == "back" ]] && return 0

  _run "Logs: $TUI_RESULT" "${SCRIPT_DIR}/manage.sh" logs "$TUI_RESULT"
}

_menu_advanced() {
  while true; do
    _menu "Advanced" "Advanced options:" \
      "status"  "Full stack status (all containers)" \
      "regen"   "Regenerate compose + Traefik config from state" \
      "version" "Show version" \
      "back"    "← Back" || return 0

    case "$TUI_RESULT" in
      status)  _run "Stack status"     "${SCRIPT_DIR}/manage.sh" status ;;
      regen)   _run "Regen config"     "${SCRIPT_DIR}/manage.sh" regen ;;
      version) _msg "Version"          "portless v${PORTLESS_VERSION}" ;;
      back)    return 0 ;;
    esac
  done
}

_management_menu() {
  local hostname domain method
  hostname=$(_state_get '.hostname // "?"')
  domain=$(_state_get   '.domain   // "?"')
  method=$(_state_get   '.tunnel.method // "none"')

  while true; do
    _menu "Management" \
"Server: ${hostname}   Domain: ${domain}   Tunnel: ${method}

Choose an action:" \
      "status"   "📊  Stack status — running containers + URLs" \
      "apps"     "📦  App management — add / remove / update" \
      "tunnel"   "🌐  Tunnel — ${method} health, setup, repair" \
      "security" "🔒  Security — auth, CrowdSec" \
      "logs"     "📋  Logs — tail container output" \
      "advanced" "⚙️   Advanced — regen, version" \
      "exit"     "✗   Exit" || break

    case "$TUI_RESULT" in
      status)   _run "Stack status"  "${SCRIPT_DIR}/manage.sh" status ;;
      apps)     _menu_apps ;;
      tunnel)   _menu_tunnel ;;
      security) _menu_security ;;
      logs)     _menu_logs ;;
      advanced) _menu_advanced ;;
      exit)     break ;;
    esac

    # Refresh dynamic values after each action
    hostname=$(_state_get '.hostname // "?"')
    domain=$(_state_get   '.domain   // "?"')
    method=$(_state_get   '.tunnel.method // "none"')
  done
}

# ─── Entry point ──────────────────────────────────────────────────────────────

_welcome() {
  $TUI --title "$TITLE" --msgbox \
"Welcome to portless!

portless sets up a complete self-hosted homelab with:
  • Docker + Traefik reverse proxy
  • Automatic TLS certificates (Let's Encrypt)
  • Secure remote access via tunnel (Pangolin/Cloudflare/Tailscale)
  • Optional authentication layer (TinyAuth)
  • 100+ pre-configured apps

This wizard will guide you through initial setup." \
    $BOX_H $BOX_W 3>&1 1>&2 2>&3 || return 1
}

_main() {
  local mode="${1:-auto}"

  case "$mode" in
    --setup)  _welcome && _wizard; return ;;
    --manage) _management_menu;    return ;;
  esac

  # Auto-detect
  if _is_setup_done 2>/dev/null; then
    _management_menu
  else
    # Check for partial install
    if _find_state_file &>/dev/null; then
      if _yesno "Resume?" \
"A previous installation was found.

  Resume the existing install? (recommended)

  Choose No to start a fresh install." "yes"; then
        _run "Resuming install" bash "${SCRIPT_DIR}/install.sh"
        return
      fi
    fi
    _welcome && _wizard
  fi
}

_main "${1:-auto}"
