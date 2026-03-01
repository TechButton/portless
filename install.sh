#!/usr/bin/env bash
# install.sh — portless interactive setup wizard
# https://github.com/techbutton/portless
#
# Usage: bash install.sh
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

# ─── Answers file ────────────────────────────────────────────────────────────────
#
# Source portless-answers.sh (or --answers <file>) to pre-fill INSTALL_* variables
# and skip interactive prompts. Any unset variable falls back to the normal prompt.

_load_answers() {
  local file="${ANSWERS_FILE:-}"
  [[ -z "$file" && -f "${SCRIPT_DIR}/portless-answers.sh" ]] && file="${SCRIPT_DIR}/portless-answers.sh"
  [[ -z "$file" ]] && return 0
  if [[ ! -f "$file" ]]; then
    log_warn "Answers file not found: $file"
    return 0
  fi
  log_info "Loading answers from: $file"
  # shellcheck source=/dev/null
  source "$file"
  log_ok "Answers file loaded"
}

# ─── Phase completion tracking ────────────────────────────────────────────────────
#
# Phase markers are written to the state JSON so the installer can resume from
# where it left off after an interruption.

_phase_complete() {
  [[ -f "${STATE_FILE:-}" ]] || return 0
  state_set ".install.phases.$1 = true"
}

_phase_is_done() {
  [[ -f "${STATE_FILE:-}" ]] || return 1
  [[ "$(state_get ".install.phases.$1 // false")" == "true" ]]
}

# ─── Resume support ───────────────────────────────────────────────────────────────
#
# On startup, look for an existing state file at the default Docker directory.
# If an in-progress install is found, offer to restore all config and skip done phases.

_check_resume() {
  local default_dockerdir="${INSTALL_DOCKERDIR:-$HOME/docker}"
  local candidate="${default_dockerdir}/.portless-state.json"
  [[ -f "$candidate" ]] || return 0

  # Only offer resume if at least one phase was completed
  local phases_done
  phases_done=$(jq -r '.install.phases // {} | to_entries | map(select(.value == true)) | length' \
    "$candidate" 2>/dev/null || echo "0")
  [[ "$phases_done" -gt 0 ]] || return 0

  # If all five phases are done this is a complete install — don't offer resume
  local all_done
  all_done=$(jq -r '
    (.install.phases.phase2 == true) and
    (.install.phases.phase3 == true) and
    (.install.phases.phase4 == true) and
    (.install.phases.phase5 == true)
  ' "$candidate" 2>/dev/null || echo "false")
  if [[ "$all_done" == "true" ]]; then
    log_info "A completed install was found. Starting a fresh install will overwrite it."
    prompt_yn "Start fresh anyway?" "N" || true
    if [[ "${REPLY^^}" != "Y" ]]; then
      log_info "Use ./manage.sh to manage your existing stack."
      exit 0
    fi
    return 0
  fi

  local hostname domain
  hostname=$(jq -r '.hostname // "unknown"' "$candidate" 2>/dev/null)
  domain=$(jq -r '.domain // "not yet set"' "$candidate" 2>/dev/null)

  echo ""
  log_info "Found an in-progress installation:"
  echo -e "  Hostname: ${CYAN}${hostname}${RESET}"
  echo -e "  Domain:   ${CYAN}${domain}${RESET}"
  echo -e "  State:    ${CYAN}${candidate}${RESET}"
  echo ""
  prompt_yn "Resume from where you left off?" "Y" || true
  [[ "${REPLY^^}" == "Y" ]] && _restore_cfg_from_state "$candidate"
}

_restore_cfg_from_state() {
  local sf="$1"
  CFG_DOCKERDIR=$(jq -r '.dockerdir // empty' "$sf" 2>/dev/null)
  [[ -n "$CFG_DOCKERDIR" ]] || { log_warn "Could not read dockerdir from state — starting fresh"; return 1; }

  CFG_HOSTNAME=$(jq -r '.hostname // empty' "$sf" 2>/dev/null)
  CFG_USER=$(jq -r '.install.user // empty' "$sf" 2>/dev/null)
  CFG_PUID=$(jq -r '.install.puid // 1000' "$sf" 2>/dev/null)
  CFG_PGID=$(jq -r '.install.pgid // 1000' "$sf" 2>/dev/null)
  CFG_TIMEZONE=$(jq -r '.install.timezone // empty' "$sf" 2>/dev/null)
  CFG_DATADIR=$(jq -r '.install.datadir // empty' "$sf" 2>/dev/null)
  CFG_DOMAIN=$(jq -r '.domain // empty' "$sf" 2>/dev/null)
  CFG_CF_EMAIL=$(jq -r '.install.cf_email // empty' "$sf" 2>/dev/null)
  CFG_SERVER_IP=$(jq -r '.server_ip // empty' "$sf" 2>/dev/null)
  CFG_DNS_PROVIDER=$(jq -r '.install.dns_provider // empty' "$sf" 2>/dev/null)
  CFG_DOWNLOADSDIR=$(jq -r '.install.downloadsdir // empty' "$sf" 2>/dev/null)
  TRAEFIK_ACCESS_MODE=$(jq -r '.traefik.access_mode // empty' "$sf" 2>/dev/null)
  TRAEFIK_AUTH_SYSTEM=$(jq -r '.traefik.auth_system // empty' "$sf" 2>/dev/null)
  TUNNEL_METHOD=$(jq -r '.tunnel.method // empty' "$sf" 2>/dev/null)
  mapfile -t CFG_SELECTED_APPS < <(jq -r '.install.selected_apps // [] | .[]' "$sf" 2>/dev/null)

  # Reconnect to the existing state file
  state_init "$CFG_DOCKERDIR"

  log_ok "Resumed from previous installation"
  log_info "  Hostname: ${CFG_HOSTNAME}  |  User: ${CFG_USER}  |  Domain: ${CFG_DOMAIN:-not yet set}"
}

# ─── Migration from old server ───────────────────────────────────────────────────
#
# Called after phase 2 (so CFG_DOCKERDIR is known) but before phase 3.
# Offers two paths: SSH pull (automatic) or manual drop folder.
# Tracked in state so it never asks again after the first answer.

_migrate_from_old_server() {
  # Skip if already answered (prevents re-prompting on resume)
  if [[ "$(state_get '.install.migration_done // false')" == "true" ]]; then
    return 0
  fi

  log_blank
  prompt_yn "Are you migrating from an existing server?" "N" || true
  if [[ "${REPLY^^}" != "Y" ]]; then
    state_set ".install.migration_done = true"
    return 0
  fi

  log_step "Migration: Copy Data from Old Server"
  echo -e "  ${DIM}Stop containers on the old server first to avoid database corruption.${RESET}"
  echo ""

  # ── Ensure rsync is available ───────────────────────────────────────────────
  if ! command -v rsync &>/dev/null; then
    log_sub "Installing rsync..."
    sudo apt-get install -y -q rsync >> "$LOG_FILE" 2>&1 \
      || die "rsync not found and could not be installed. Install it manually: sudo apt-get install rsync"
    log_ok "rsync installed"
  fi

  prompt_select "How do you want to transfer files?" \
    "Pull automatically via SSH from the old server" \
    "Copy files manually to a drop folder on this server"

  if [[ "$REPLY" == Pull* ]]; then
    _migrate_via_ssh
  else
    _migrate_via_drop_folder
  fi
}

_migrate_via_ssh() {
  echo -e "  ${DIM}rsync will pull your old appdata and secrets directly over SSH.${RESET}"
  echo ""

  prompt_input "Old server hostname or IP" ""
  local old_host="$REPLY"
  [[ -n "$old_host" ]] || { log_warn "No host entered — skipping migration"; state_set ".install.migration_done = true"; return 0; }

  prompt_input "SSH username on old server" "$CFG_USER"
  local old_user="$REPLY"

  prompt_input "SSH port" "22"
  local old_port="$REPLY"

  prompt_input "Path to SSH private key" "$HOME/.ssh/id_rsa"
  local old_key="$REPLY"

  if [[ ! -f "$old_key" ]]; then
    log_warn "Key not found: $old_key"
    log_info "To set up key access from this server:"
    log_info "  ssh-keygen -t ed25519 -f $HOME/.ssh/id_rsa"
    log_info "  ssh-copy-id -i ${old_key}.pub ${old_user}@${old_host}"
    log_blank
    prompt_select "What would you like to do?" \
      "Switch to manual drop folder instead" \
      "Skip migration for now"
    case "$REPLY" in
      Switch*) _migrate_via_drop_folder; return ;;
      *)       state_set ".install.migration_done = true"; return 0 ;;
    esac
  fi

  local ssh_opts="-i ${old_key} -p ${old_port} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

  log_sub "Testing SSH connection to ${old_user}@${old_host}..."
  # shellcheck disable=SC2086
  if ! ssh $ssh_opts "${old_user}@${old_host}" "echo OK" &>/dev/null; then
    log_error "Cannot connect to ${old_user}@${old_host}:${old_port} with key ${old_key}"
    log_warn "From the OLD server, run:"
    log_warn "  ssh-copy-id -i ${old_key}.pub ${old_user}@$(hostname -I | awk '{print $1}')"
    log_blank
    prompt_select "What would you like to do?" \
      "Switch to manual drop folder instead" \
      "Skip migration for now"
    case "$REPLY" in
      Switch*) _migrate_via_drop_folder; return ;;
      *)       state_set ".install.migration_done = true"; return 0 ;;
    esac
  fi
  log_ok "SSH connection successful"

  prompt_input "Docker directory on old server" "~/docker"
  local old_dockerdir="$REPLY"

  echo ""
  log_info "Will copy from ${old_user}@${old_host}:${old_dockerdir} → ${CFG_DOCKERDIR}:"
  echo -e "  ${DIM}appdata/  — app databases, Plex metadata, Sonarr/Radarr libraries${RESET}"
  echo -e "  ${DIM}secrets/  — Cloudflare token, auth credentials${RESET}"
  echo -e "  ${DIM}(Plex Cache and Codecs are skipped — they regenerate automatically)${RESET}"
  echo ""

  prompt_yn "Start copying now? (can take a while for large Plex libraries)" "Y" || true
  if [[ "${REPLY^^}" != "Y" ]]; then
    log_sub "Migration skipped"
    state_set ".install.migration_done = true"
    return 0
  fi

  log_sub "Copying appdata... (progress in ${LOG_FILE})"
  if rsync -avz --progress \
      -e "ssh $ssh_opts" \
      --exclude 'plex/Library/Application Support/Plex Media Server/Cache/' \
      --exclude 'plex/Library/Application Support/Plex Media Server/Codecs/' \
      "${old_user}@${old_host}:${old_dockerdir}/appdata/" \
      "${CFG_DOCKERDIR}/appdata/" \
      >> "$LOG_FILE" 2>&1; then
    log_ok "appdata copied"
  else
    log_warn "appdata rsync completed with some errors — check ${LOG_FILE}"
  fi

  log_sub "Copying secrets..."
  if rsync -avz \
      -e "ssh $ssh_opts" \
      "${old_user}@${old_host}:${old_dockerdir}/secrets/" \
      "${CFG_DOCKERDIR}/secrets/" \
      >> "$LOG_FILE" 2>&1; then
    log_ok "Secrets copied"
  else
    log_warn "Secrets rsync had errors — check ${LOG_FILE}"
  fi

  _migrate_finish
}

_migrate_via_drop_folder() {
  local drop_dir="/tmp/portless-migration"
  local new_server_ip
  new_server_ip=$(hostname -I | awk '{print $1}')

  echo ""
  log_info "Drop folder: ${BOLD}${drop_dir}${RESET}"
  echo ""
  echo -e "  Copy your old ${BOLD}appdata/${RESET} and ${BOLD}secrets/${RESET} folders into ${CYAN}${drop_dir}${RESET} on this server."
  echo -e "  The structure should look like:"
  echo -e ""
  echo -e "  ${DIM}${drop_dir}/${RESET}"
  echo -e "  ${DIM}├── appdata/${RESET}"
  echo -e "  ${DIM}└── secrets/${RESET}"
  echo ""
  echo -e "  ${BOLD}Ways to get files here:${RESET}"
  echo ""
  echo -e "  ${BOLD}From the old server${RESET} (run on the old server):"
  echo -e "  ${CYAN}  rsync -avz ~/docker/appdata/ ${CFG_USER}@${new_server_ip}:${drop_dir}/appdata/${RESET}"
  echo -e "  ${CYAN}  rsync -avz ~/docker/secrets/ ${CFG_USER}@${new_server_ip}:${drop_dir}/secrets/${RESET}"
  echo ""
  echo -e "  ${BOLD}USB drive${RESET} (run on this server after plugging in the drive):"
  echo -e "  ${CYAN}  mkdir -p ${drop_dir}${RESET}"
  echo -e "  ${CYAN}  cp -r /media/usb/appdata /media/usb/secrets ${drop_dir}/${RESET}"
  echo ""
  echo -e "  ${BOLD}SCP from old server${RESET}:"
  echo -e "  ${CYAN}  scp -r ~/docker/appdata ~/docker/secrets ${CFG_USER}@${new_server_ip}:${drop_dir}/${RESET}"
  echo ""
  echo -e "  ${DIM}Leave this installer running — it will wait for you.${RESET}"
  echo ""

  prompt_yn "Press Y once the files are in place and ready to import" "Y" || true
  if [[ "${REPLY^^}" != "Y" ]]; then
    log_warn "Migration skipped — re-run the installer to try again."
    state_set ".install.migration_done = true"
    return 0
  fi

  prompt_input "Drop folder path" "$drop_dir"
  drop_dir="${REPLY%/}"

  if [[ ! -d "$drop_dir" ]]; then
    log_error "Folder not found: $drop_dir"
    log_warn "Migration skipped — re-run the installer once the files are in place."
    state_set ".install.migration_done = true"
    return 0
  fi

  local found_something=0

  if [[ -d "${drop_dir}/appdata" ]]; then
    log_sub "Copying appdata..."
    if rsync -a --progress \
        --exclude 'plex/Library/Application Support/Plex Media Server/Cache/' \
        --exclude 'plex/Library/Application Support/Plex Media Server/Codecs/' \
        "${drop_dir}/appdata/" \
        "${CFG_DOCKERDIR}/appdata/" \
        >> "$LOG_FILE" 2>&1; then
      log_ok "appdata copied"
      (( found_something++ )) || true
    else
      log_warn "appdata copy completed with some errors — check ${LOG_FILE}"
    fi
  else
    log_warn "No appdata/ folder found in ${drop_dir} — skipped"
  fi

  if [[ -d "${drop_dir}/secrets" ]]; then
    log_sub "Copying secrets..."
    if rsync -a \
        "${drop_dir}/secrets/" \
        "${CFG_DOCKERDIR}/secrets/" \
        >> "$LOG_FILE" 2>&1; then
      log_ok "Secrets copied"
      (( found_something++ )) || true
    else
      log_warn "Secrets copy had errors — check ${LOG_FILE}"
    fi
  else
    log_warn "No secrets/ folder found in ${drop_dir} — skipped"
  fi

  if (( found_something > 0 )); then
    _migrate_finish
    prompt_yn "Delete the drop folder now that files are imported?" "Y" || true
    [[ "${REPLY^^}" == "Y" ]] && rm -rf "$drop_dir" && log_sub "Drop folder removed"
  else
    log_warn "Nothing was copied — check that appdata/ and secrets/ exist in ${drop_dir}."
    log_warn "Re-run the installer to try again."
    state_set ".install.migration_done = true"
  fi
}

_migrate_finish() {
  # Fix permissions on anything we just copied in
  chmod 600 "${CFG_DOCKERDIR}/secrets/"* 2>/dev/null || true
  local acme_json="${CFG_DOCKERDIR}/appdata/traefik3/acme/acme.json"
  [[ -f "$acme_json" ]] && chmod 600 "$acme_json"
  sudo chown -R "${CFG_USER}:${CFG_USER}" "${CFG_DOCKERDIR}/appdata/" 2>/dev/null || true
  sudo chown -R "${CFG_USER}:${CFG_USER}" "${CFG_DOCKERDIR}/secrets/" 2>/dev/null || true

  state_set ".install.migration_done = true"
  log_ok "Migration complete"
  echo ""
  log_info "Your old app data is now in place. The installer will continue configuring"
  log_info "this server. After install, update SERVER_LAN_IP in ~/docker/.env if it changed."
  log_blank
}

# ─── Entry point ─────────────────────────────────────────────────────────────────

main() {
  # ── Argument parsing ────────────────────────────────────────────────────────
  ANSWERS_FILE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --answers=*) ANSWERS_FILE="${1#--answers=}"; shift ;;
      --answers)   ANSWERS_FILE="${2:-}"; shift 2 ;;
      *)           shift ;;
    esac
  done

  _load_answers

  banner "portless Setup Wizard  v${PORTLESS_VERSION}"
  echo -e "  Works with ${BOLD}any ISP${RESET} — no port forwarding or firewall changes needed."
  echo -e "  Choose your remote access method: ${BOLD}Cloudflare Tunnel${RESET} (free, easiest),"
  echo -e "  ${BOLD}Pangolin${RESET} or ${BOLD}Headscale${RESET} (self-hosted VPS), ${BOLD}Tailscale${RESET} or ${BOLD}Netbird${RESET} (VPN mesh)."
  echo -e "  Your home IP is ${BOLD}never exposed${RESET} to the internet."
  echo ""
  echo -e "  ${DIM}Logs → ${LOG_FILE}${RESET}"
  echo ""

  _check_resume

  # ── Phase 1 — always run (system checks, no interactive questions) ──────────
  phase1_system_check

  # ── Phase 2 ─────────────────────────────────────────────────────────────────
  if _phase_is_done "phase2"; then
    log_step "Phase 2: Basic Configuration"
    log_ok "Already complete — hostname: ${CFG_HOSTNAME}  user: ${CFG_USER}"
    state_init "$CFG_DOCKERDIR"   # reconnect state
  else
    phase2_basic_config
    _phase_complete "phase1"      # state now exists; retroactively mark phase1
    _phase_complete "phase2"
  fi

  # ── Migration (one-time prompt before phase 3 runs) ─────────────────────────
  if ! _phase_is_done "phase3"; then
    _migrate_from_old_server
  fi

  # ── Phase 3 ─────────────────────────────────────────────────────────────────
  if _phase_is_done "phase3"; then
    log_step "Phase 3: Domain & Network"
    log_ok "Already complete — domain: ${CFG_DOMAIN}  IP: ${CFG_SERVER_IP}"
  else
    phase3_domain_network
    _phase_complete "phase3"
  fi

  # ── Phase 4 ─────────────────────────────────────────────────────────────────
  if _phase_is_done "phase4"; then
    log_step "Phase 4: App Selection"
    mapfile -t CFG_SELECTED_APPS < <(state_get '.install.selected_apps // [] | .[]' 2>/dev/null)
    log_ok "Already complete — ${#CFG_SELECTED_APPS[@]} app(s): ${CFG_SELECTED_APPS[*]:-none}"
  else
    phase4_app_selection
    _phase_complete "phase4"
  fi

  # ── Phase 5 ─────────────────────────────────────────────────────────────────
  if _phase_is_done "phase5"; then
    log_step "Phase 5: Remote Access"
    TUNNEL_METHOD="${TUNNEL_METHOD:-$(state_get '.tunnel.method')}"
    log_ok "Already complete — method: ${TUNNEL_METHOD}"
  else
    phase5_remote_access
    _phase_complete "phase5"
  fi

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
  default_hostname=$(hostname -s 2>/dev/null || echo "portless")
  ans_prompt_input "HOSTNAME" "Server nickname (used in file/folder names)" "$default_hostname"
  CFG_HOSTNAME="${REPLY,,}"  # lowercase
  CFG_HOSTNAME="${CFG_HOSTNAME//[^a-z0-9-]/-}"  # sanitize

  # Linux user
  ans_prompt_input "USER" "Linux username" "$DETECTED_USER"
  CFG_USER="$REPLY"
  CFG_PUID=$(id -u "$CFG_USER" 2>/dev/null || echo "$DETECTED_PUID")
  CFG_PGID=$(id -g "$CFG_USER" 2>/dev/null || echo "$DETECTED_PGID")
  log_info "PUID=$CFG_PUID  PGID=$CFG_PGID"

  # Timezone
  ans_prompt_input "TIMEZONE" "Timezone" "$DETECTED_TZ"
  CFG_TIMEZONE="$REPLY"

  # Docker directory
  local default_dockerdir="/home/${CFG_USER}/docker"
  ans_prompt_input "DOCKERDIR" "Docker data directory (will be created if needed)" "$default_dockerdir"
  CFG_DOCKERDIR="$REPLY"

  # Data directory (for media files)
  ans_prompt_input "DATADIR" "Media/data directory (where your movies, TV, etc. live)" "/mnt/data"
  CFG_DATADIR="${REPLY%/}"   # strip trailing slash to avoid double-slash in paths

  # Initialize state
  state_init "$CFG_DOCKERDIR"
  state_set_kv "hostname" "$CFG_HOSTNAME"
  state_set_kv "dockerdir" "$CFG_DOCKERDIR"
  # Save phase 2 vars for resume
  state_set "
    .install.user     = \"$CFG_USER\" |
    .install.puid     = $CFG_PUID |
    .install.pgid     = $CFG_PGID |
    .install.timezone = \"$CFG_TIMEZONE\" |
    .install.datadir  = \"$CFG_DATADIR\"
  "

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
    # Create any subdirs that weren't already mounted (NFS per-share mounts skip existing dirs).
    # Use sudo because the data root (e.g. /media, /mnt/data) is often root-owned.
    log_sub "Creating subdirectories under ${CFG_DATADIR}..."
    local subdir
    for subdir in movies tv music books audiobooks comics downloads \
                  usenet/incomplete usenet/complete \
                  torrents/incomplete torrents/complete; do
      local full_path="${CFG_DATADIR}/${subdir}"
      if [[ ! -d "$full_path" ]]; then
        sudo mkdir -p "$full_path" || log_warn "Could not create ${full_path}"
        sudo chown "${CFG_USER}:${CFG_USER}" "$full_path" 2>/dev/null || true
      fi
    done
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
  if [[ -n "${INSTALL_DOMAIN:-}" ]]; then
    CFG_DOMAIN="$INSTALL_DOMAIN"
    log_sub "Domain: $CFG_DOMAIN  ${DIM}(answers file)${RESET}"
    validate_domain "$CFG_DOMAIN" || die "INSTALL_DOMAIN='$CFG_DOMAIN' is not a valid domain name"
  else
    while true; do
      prompt_input "Your domain name (e.g. example.com)" ""
      CFG_DOMAIN="$REPLY"
      validate_domain "$CFG_DOMAIN" && break
      log_warn "Invalid domain format. Example: example.com or mydomain.co.uk"
    done
  fi

  # DNS provider
  echo ""
  ans_prompt_select "DNS_PROVIDER" "DNS provider for Traefik automatic TLS:" \
    "Cloudflare (recommended — automatic wildcard certs)" \
    "Manual / Other (you'll manage DNS yourself)"
  CFG_DNS_PROVIDER="$REPLY"

  if [[ "$CFG_DNS_PROVIDER" == Cloudflare* ]]; then
    # Cloudflare API token
    if [[ -n "${INSTALL_CF_TOKEN:-}" ]]; then
      CFG_CF_TOKEN="$INSTALL_CF_TOKEN"
      log_sub "Cloudflare token: ***  ${DIM}(answers file)${RESET}"
    else
      echo ""
      echo -e "${DIM}You need a Cloudflare API token with Zone:DNS:Edit permission.${RESET}"
      echo -e "${DIM}Create one at: https://dash.cloudflare.com/profile/api-tokens${RESET}"
      echo ""
      while true; do
        prompt_secret "Cloudflare API Token"
        CFG_CF_TOKEN="$REPLY"
        if [[ ${#CFG_CF_TOKEN} -gt 10 ]]; then
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
    fi

    ans_prompt_input "CF_EMAIL" "Cloudflare account email" ""
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
  ans_prompt_input "SERVER_IP" "Server LAN IP address" "$DETECTED_LAN_IP"
  CFG_SERVER_IP="$REPLY"
  while ! validate_ip "$CFG_SERVER_IP"; do
    log_warn "Invalid IP address format"
    prompt_input "Server LAN IP address" "$DETECTED_LAN_IP"
    CFG_SERVER_IP="$REPLY"
  done

  # Save to state
  state_set_kv "domain" "$CFG_DOMAIN"
  state_set_kv "server_ip" "$CFG_SERVER_IP"
  state_set "
    .install.cf_email     = \"${CFG_CF_EMAIL:-}\" |
    .install.dns_provider = \"$CFG_DNS_PROVIDER\"
  "

  log_ok "Domain & network configured"

  # ── Traefik access mode ───────────────────────────────────────────────────────
  # If INSTALL_TRAEFIK_MODE is set, skip the interactive wizard.
  if [[ -n "${INSTALL_TRAEFIK_MODE:-}" ]]; then
    case "${INSTALL_TRAEFIK_MODE,,}" in
      hybrid) TRAEFIK_ACCESS_MODE="hybrid" ;;
      local)  TRAEFIK_ACCESS_MODE="local" ;;
      *)      TRAEFIK_ACCESS_MODE="hybrid"
              log_warn "Unknown INSTALL_TRAEFIK_MODE='$INSTALL_TRAEFIK_MODE' — defaulting to hybrid" ;;
    esac
    state_set ".traefik.access_mode = \"$TRAEFIK_ACCESS_MODE\""
    log_sub "Traefik mode: $TRAEFIK_ACCESS_MODE  ${DIM}(answers file)${RESET}"
  else
    traefik_setup_wizard
  fi

  # ── Auth system ───────────────────────────────────────────────────────────────
  # Note: traefik_ask_crowdsec is called AFTER phase5 so we know the tunnel type.
  if [[ -n "${INSTALL_AUTH_SYSTEM:-}" ]]; then
    case "${INSTALL_AUTH_SYSTEM,,}" in
      tinyauth) TRAEFIK_AUTH_SYSTEM="tinyauth" ;;
      basic)    TRAEFIK_AUTH_SYSTEM="basic" ;;
      none)     TRAEFIK_AUTH_SYSTEM="none" ;;
      *)        TRAEFIK_AUTH_SYSTEM="tinyauth"
                log_warn "Unknown INSTALL_AUTH_SYSTEM='$INSTALL_AUTH_SYSTEM' — defaulting to tinyauth" ;;
    esac
    state_set ".traefik.auth_system = \"$TRAEFIK_AUTH_SYSTEM\""
    log_sub "Auth system: $TRAEFIK_AUTH_SYSTEM  ${DIM}(answers file)${RESET}"
  else
    traefik_select_auth
  fi
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

  if [[ -n "${INSTALL_APPS:-}" ]]; then
    # Non-interactive: parse comma-separated app list from answers file
    log_sub "Apps from answers file: $INSTALL_APPS"
    IFS=',' read -ra _ans_apps <<< "$INSTALL_APPS"
    for _app in "${_ans_apps[@]}"; do
      _app="${_app//[[:space:]]/}"
      [[ -n "$_app" ]] && CFG_SELECTED_APPS+=("$_app")
    done
  else
    # Interactive: category-by-category checklist
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
  fi

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

  # Save to state for resume
  local _apps_json
  _apps_json=$(printf '%s\n' "${CFG_SELECTED_APPS[@]}" | jq -R . | jq -s .)
  state_set ".install.selected_apps = ${_apps_json}"

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

  ans_prompt_select "TUNNEL" "Remote access method:" \
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

  # Downloads directory (may differ from media dir on some setups)
  ans_prompt_input "DOWNLOADSDIR" "Downloads directory" "${CFG_DATADIR}/downloads"
  CFG_DOWNLOADSDIR="$REPLY"
  state_set ".install.downloadsdir = \"$CFG_DOWNLOADSDIR\""

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
    external: true
  t3_proxy:
    name: t3_proxy
    external: true

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
    # Try the shared hs/ snippets directory
    src="${SCRIPT_DIR}/compose/hs/${service}.yml"
  fi
  if [[ ! -f "$src" ]]; then
    # Try generic (non-hostname-specific)
    src="${SCRIPT_DIR}/compose/${service}.yml"
  fi

  if [[ -f "$src" ]]; then
    echo "" >> "$compose_out"
    echo "  ########## ${service^^} ##########" >> "$compose_out"
    # Append service block — skip the 'services:' header and strip 'profiles:'
    # lines (profiles are not needed since we selectively include snippets)
    grep -v "^services:" "$src" \
      | grep -v "^[[:space:]]*profiles:" \
      >> "$compose_out" 2>/dev/null || true
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
