#!/usr/bin/env bash
# lib/common.sh — Colors, logging, prompts, error handling
# shellcheck disable=SC2034

# ─── Terminal colors ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  GREEN='\033[0;32m'
  CYAN='\033[0;36m'
  BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'
  BOLD='\033[1m'
  DIM='\033[2m'
  RESET='\033[0m'
else
  RED='' YELLOW='' GREEN='' CYAN='' BLUE='' MAGENTA='' BOLD='' DIM='' RESET=''
fi

# ─── Logging ────────────────────────────────────────────────────────────────────

# Write a plain-text (no ANSI) line to the log file
_log_to_file() {
  local logfile="${LOG_FILE:-/tmp/portless-install.log}"
  printf '%s\n' "$*" >> "$logfile" 2>/dev/null || true
}

log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*";  _log_to_file "[INFO]  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*";  _log_to_file "[OK]    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; _log_to_file "[WARN]  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; _log_to_file "[ERROR] $*"; }
log_step()    { echo -e "\n${BOLD}${BLUE}══ $* ══${RESET}"; _log_to_file ""; _log_to_file "══ $* ══"; }
log_sub()     { echo -e "  ${DIM}▸${RESET} $*"; _log_to_file "  > $*"; }
log_blank()   { echo ""; }

# Print a banner
banner() {
  local title="$1"
  local width=60
  local line
  line=$(printf '═%.0s' $(seq 1 $width))
  echo -e "${BOLD}${BLUE}"
  echo "╔${line}╗"
  printf "║  %-$((width - 2))s║\n" "$title"
  echo "╚${line}╝"
  echo -e "${RESET}"
}

# ─── Error handling ──────────────────────────────────────────────────────────────
die() {
  log_error "$*"
  exit 1
}

require_root() {
  [[ $EUID -eq 0 ]] || die "This step requires root privileges. Run with sudo."
}

# Run a command, log stdout+stderr to file, die on failure
run_cmd() {
  local desc="$1"; shift
  local logfile="${LOG_FILE:-/tmp/portless-install.log}"
  log_sub "$desc"
  _log_to_file "  \$ $*"
  if "$@" >> "$logfile" 2>&1; then
    log_ok "$desc"
  else
    log_error "$desc — FAILED (see $logfile)"
    return 1
  fi
}

# ─── Prompt helpers ──────────────────────────────────────────────────────────────

# prompt_input <prompt> <default> → sets REPLY
prompt_input() {
  local prompt="$1"
  local default="$2"
  if [[ -n "$default" ]]; then
    echo -ne "${BOLD}${prompt}${RESET} ${DIM}[${default}]${RESET}: "
  else
    echo -ne "${BOLD}${prompt}${RESET}: "
  fi
  read -r REPLY
  if [[ -z "$REPLY" && -n "$default" ]]; then
    REPLY="$default"
  fi
}

# prompt_secret <prompt> → sets REPLY (no echo)
prompt_secret() {
  local prompt="$1"
  echo -ne "${BOLD}${prompt}${RESET}: "
  read -rs REPLY
  echo ""
}

# prompt_yn <prompt> <default Y|N> → returns 0 for yes, 1 for no
prompt_yn() {
  local prompt="$1"
  local default="${2:-N}"
  local choices
  if [[ "${default^^}" == "Y" ]]; then
    choices="Y/n"
  else
    choices="y/N"
  fi
  echo -ne "${BOLD}${prompt}${RESET} ${DIM}[${choices}]${RESET}: "
  read -r REPLY
  if [[ -z "$REPLY" ]]; then
    REPLY="$default"
  fi
  [[ "${REPLY^^}" == "Y" ]]
}

# prompt_select <prompt> <option1> <option2> ... → sets REPLY to chosen option
prompt_select() {
  local prompt="$1"; shift
  local options=("$@")
  echo -e "${BOLD}${prompt}${RESET}"
  local i=1
  for opt in "${options[@]}"; do
    echo -e "  ${CYAN}${i})${RESET} ${opt}"
    ((i++))
  done
  local choice
  while true; do
    echo -ne "Enter choice [1-${#options[@]}]: "
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      REPLY="${options[$((choice - 1))]}"
      return 0
    fi
    log_warn "Please enter a number between 1 and ${#options[@]}"
  done
}

# prompt_checklist <prompt> <option1> <option2> ... → sets SELECTED_ITEMS array
# User enters comma-separated numbers or 'all'
prompt_checklist() {
  local prompt="$1"; shift
  local options=("$@")
  SELECTED_ITEMS=()

  echo -e "${BOLD}${prompt}${RESET}"
  echo -e "  ${DIM}Enter numbers separated by spaces, or 'all' for everything${RESET}"
  local i=1
  for opt in "${options[@]}"; do
    echo -e "  ${CYAN}${i})${RESET} ${opt}"
    ((i++))
  done
  echo -ne "Selection: "
  read -r selection

  if [[ "${selection,,}" == "all" ]]; then
    SELECTED_ITEMS=("${options[@]}")
    return 0
  fi

  for num in $selection; do
    if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#options[@]} )); then
      SELECTED_ITEMS+=("${options[$((num - 1))]}")
    fi
  done
}

# ─── Validation helpers ──────────────────────────────────────────────────────────

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]
}

validate_ip() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

# ─── System detection ────────────────────────────────────────────────────────────

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="${ID,,}"
    OS_ID_LIKE="${ID_LIKE,,}"
    OS_VERSION="${VERSION_ID}"
    OS_NAME="${NAME}"
  else
    OS_ID="unknown"
    OS_ID_LIKE=""
    OS_VERSION=""
    OS_NAME="Unknown"
  fi

  # Normalize to family
  if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" || "$OS_ID_LIKE" =~ "debian" ]]; then
    OS_FAMILY="debian"
  elif [[ "$OS_ID" == "arch" || "$OS_ID_LIKE" =~ "arch" ]]; then
    OS_FAMILY="arch"
  elif [[ "$OS_ID" =~ ^(rhel|centos|fedora|rocky|almalinux)$ || "$OS_ID_LIKE" =~ "rhel" ]]; then
    OS_FAMILY="rhel"
  else
    OS_FAMILY="unknown"
  fi
}

# Detect current user's PUID/PGID
detect_user_ids() {
  DETECTED_USER=$(whoami)
  DETECTED_PUID=$(id -u)
  DETECTED_PGID=$(id -g)
}

# Auto-detect timezone
detect_timezone() {
  if command -v timedatectl &>/dev/null; then
    DETECTED_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || timedatectl | grep "Time zone" | awk '{print $3}')
  elif [[ -f /etc/timezone ]]; then
    DETECTED_TZ=$(cat /etc/timezone)
  else
    DETECTED_TZ="America/New_York"
  fi
}

# Auto-detect LAN IP
detect_lan_ip() {
  DETECTED_LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}' | tr -d '[:space:]')
  # Fallback
  if [[ -z "$DETECTED_LAN_IP" ]]; then
    DETECTED_LAN_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "")
  fi
}

# ─── Dependency checks ───────────────────────────────────────────────────────────

check_command() {
  command -v "$1" &>/dev/null
}

require_command() {
  local cmd="$1"
  local pkg="${2:-$cmd}"
  if ! check_command "$cmd"; then
    die "'$cmd' is required but not installed. Install with: sudo apt install $pkg"
  fi
}

# Check if Docker compose v2 is available
check_compose_v2() {
  docker compose version &>/dev/null 2>&1
}

# ─── Port utilities ──────────────────────────────────────────────────────────────

port_in_use() {
  local port="$1"
  ss -tlnp "sport = :${port}" 2>/dev/null | grep -q ":${port}" || \
  netstat -tlnp 2>/dev/null | grep -q ":${port} "
}

# ─── File utilities ──────────────────────────────────────────────────────────────

ensure_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || mkdir -p "$dir" || die "Failed to create directory: $dir"
}

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cp "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
    log_sub "Backed up ${file}"
  fi
}

# Template substitution: replace {KEY} with value in template file → output file
render_template() {
  local template="$1"
  local output="$2"
  shift 2
  # Remaining args: KEY=VALUE pairs
  local content
  content=$(cat "$template") || die "Cannot read template: $template"
  while [[ $# -gt 0 ]]; do
    local key="${1%%=*}"
    local value="${1#*=}"
    content="${content//\{${key}\}/${value}}"
    shift
  done
  echo "$content" > "$output" || die "Cannot write to: $output"
}
