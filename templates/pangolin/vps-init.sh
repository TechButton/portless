#!/usr/bin/env bash
# vps-init.sh — VPS hardening + Docker install
#
# Runs ON the VPS via SSH. Expects Ubuntu/Debian (other distros partially supported).
# Must be run as root or a user with passwordless sudo.
#
# What this script does:
#   1. Updates system packages
#   2. Installs essential tools (curl, jq, ufw, fail2ban, unattended-upgrades)
#   3. Creates a 2GB swap file (if no swap exists)
#   4. Configures UFW firewall (allow SSH/80/443/51820udp, deny rest)
#   5. Configures fail2ban (SSH protection)
#   6. Enables automatic security updates
#   7. Installs Docker CE + Compose v2
#   8. Sets correct timezone
#   9. Prints VPS_INIT_DONE on success
#
# Usage: bash /tmp/homelab-vps-init.sh
#
# Environment variables (optional):
#   VPS_SSH_PORT   — SSH port to allow in firewall (default: 22)
#   VPS_TIMEZONE   — timezone to set (default: UTC)
#   VPS_SWAP_SIZE  — swap size in GB (default: 2, set to 0 to skip)
#   SKIP_UFW       — set to 1 to skip UFW setup
#   SKIP_FAIL2BAN  — set to 1 to skip fail2ban setup
#   SKIP_DOCKER    — set to 1 to skip Docker install (if already installed)
#

set -euo pipefail

VPS_SSH_PORT="${VPS_SSH_PORT:-22}"
VPS_TIMEZONE="${VPS_TIMEZONE:-UTC}"
VPS_SWAP_SIZE="${VPS_SWAP_SIZE:-2}"
SKIP_UFW="${SKIP_UFW:-0}"
SKIP_FAIL2BAN="${SKIP_FAIL2BAN:-0}"
SKIP_DOCKER="${SKIP_DOCKER:-0}"

# ─── Helpers ───────────────────────────────────────────────────────────────────

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*" >&2; }
step()  { echo ""; echo "=== $* ==="; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

has_cmd() { command -v "$1" &>/dev/null; }

# Detect if running as root or use sudo
if [[ $EUID -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
  $SUDO -n true 2>/dev/null || die "Need passwordless sudo. Run as root or configure sudo NOPASSWD."
fi

# ─── Detect OS ─────────────────────────────────────────────────────────────────

step "Detecting OS"
if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  source /etc/os-release
  OS_ID="${ID,,}"
  OS_ID_LIKE="${ID_LIKE,,}"
  info "OS: ${PRETTY_NAME:-$ID}"
else
  die "Cannot detect OS — /etc/os-release not found"
fi

if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" || "$OS_ID_LIKE" =~ "debian" ]]; then
  PKG_MGR="apt-get"
  PKG_UPDATE="$SUDO apt-get update -qq"
  PKG_INSTALL="$SUDO apt-get install -y -q"
elif [[ "$OS_ID" =~ ^(rhel|centos|fedora|rocky|almalinux)$ || "$OS_ID_LIKE" =~ "rhel" ]]; then
  PKG_MGR="dnf"
  PKG_UPDATE="$SUDO dnf check-update -q || true"
  PKG_INSTALL="$SUDO dnf install -y -q"
else
  warn "Unsupported OS: ${OS_ID}. Proceeding with apt-get — results may vary."
  PKG_MGR="apt-get"
  PKG_UPDATE="$SUDO apt-get update -qq"
  PKG_INSTALL="$SUDO apt-get install -y -q"
fi

# ─── 1. System update ──────────────────────────────────────────────────────────

step "Updating system packages"
$PKG_UPDATE
$PKG_INSTALL \
  curl wget git jq ca-certificates gnupg lsb-release \
  apt-transport-https software-properties-common 2>/dev/null || true
ok "System packages updated"

# ─── 2. Timezone ───────────────────────────────────────────────────────────────

step "Setting timezone: ${VPS_TIMEZONE}"
if has_cmd timedatectl; then
  $SUDO timedatectl set-timezone "$VPS_TIMEZONE" && ok "Timezone set to $VPS_TIMEZONE"
elif [[ -f "/usr/share/zoneinfo/${VPS_TIMEZONE}" ]]; then
  $SUDO ln -sf "/usr/share/zoneinfo/${VPS_TIMEZONE}" /etc/localtime
  ok "Timezone set to $VPS_TIMEZONE"
else
  warn "Could not set timezone — skipping"
fi

# ─── 3. Swap ───────────────────────────────────────────────────────────────────

step "Configuring swap"
if [[ "${VPS_SWAP_SIZE}" -gt 0 ]]; then
  if swapon --show | grep -q .; then
    info "Swap already configured — skipping"
    swapon --show
  else
    info "Creating ${VPS_SWAP_SIZE}GB swap file..."
    SWAP_PATH="/swapfile"
    $SUDO fallocate -l "${VPS_SWAP_SIZE}G" "$SWAP_PATH" 2>/dev/null || \
      $SUDO dd if=/dev/zero of="$SWAP_PATH" bs=1M count="$((VPS_SWAP_SIZE * 1024))" status=none
    $SUDO chmod 600 "$SWAP_PATH"
    $SUDO mkswap "$SWAP_PATH" -q
    $SUDO swapon "$SWAP_PATH"

    # Persist across reboots
    if ! grep -q "$SWAP_PATH" /etc/fstab; then
      echo "${SWAP_PATH} none swap sw 0 0" | $SUDO tee -a /etc/fstab > /dev/null
    fi

    # Tune swappiness for low-memory VPS
    $SUDO sysctl vm.swappiness=10 > /dev/null
    if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
      echo "vm.swappiness=10" | $SUDO tee -a /etc/sysctl.conf > /dev/null
    fi
    ok "Swap created: ${VPS_SWAP_SIZE}GB at $SWAP_PATH"
  fi
else
  info "Swap setup skipped (VPS_SWAP_SIZE=0)"
fi

# ─── 4. UFW Firewall ───────────────────────────────────────────────────────────

if [[ "${SKIP_UFW}" != "1" ]]; then
  step "Configuring UFW firewall"
  $PKG_INSTALL ufw

  # Disable (reset) first so we start clean, but only if we're about to re-enable
  $SUDO ufw --force reset > /dev/null 2>&1 || true

  # Default policies
  $SUDO ufw default deny incoming  > /dev/null
  $SUDO ufw default allow outgoing > /dev/null

  # SSH — detect actual port from sshd config
  SSH_CFG_PORT=$(grep -E '^Port\s' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || true)
  SSH_CFG_PORT="${SSH_CFG_PORT:-${VPS_SSH_PORT}}"
  $SUDO ufw allow "${SSH_CFG_PORT}/tcp" comment 'SSH' > /dev/null
  info "Allowed SSH on port ${SSH_CFG_PORT}"

  # Pangolin / Traefik
  $SUDO ufw allow 80/tcp  comment 'HTTP (Let'\''s Encrypt)' > /dev/null
  $SUDO ufw allow 443/tcp comment 'HTTPS (Pangolin)'        > /dev/null

  # Gerbil WireGuard tunnel
  $SUDO ufw allow 51820/udp comment 'WireGuard (Gerbil)'   > /dev/null
  $SUDO ufw allow 51821/udp comment 'WireGuard (Gerbil 2)'  > /dev/null

  # Enable
  $SUDO ufw --force enable > /dev/null
  $SUDO ufw status numbered
  ok "UFW enabled"
fi

# ─── 5. fail2ban ───────────────────────────────────────────────────────────────

if [[ "${SKIP_FAIL2BAN}" != "1" ]]; then
  step "Configuring fail2ban"
  $PKG_INSTALL fail2ban

  $SUDO tee /etc/fail2ban/jail.local > /dev/null << 'FAIL2BAN_CONF'
[DEFAULT]
# Ban for 1 hour
bantime  = 3600
# Watch over 10-minute windows
findtime = 600
# Allow 3 attempts before ban
maxretry = 3
# Use systemd backend for Ubuntu 22.04+
backend  = systemd

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
maxretry = 5
FAIL2BAN_CONF

  $SUDO systemctl enable fail2ban > /dev/null 2>&1 || true
  $SUDO systemctl restart fail2ban
  ok "fail2ban configured and running"
fi

# ─── 6. Automatic security updates ─────────────────────────────────────────────

step "Enabling automatic security updates"
if [[ "$PKG_MGR" == "apt-get" ]]; then
  $PKG_INSTALL unattended-upgrades
  # Configure to auto-apply security updates only
  $SUDO tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null << 'UA_CONF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
  "${distro_id}ESMApps:${distro_codename}-apps-security";
  "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Automatic-Reboot "false";
UA_CONF

  # Enable the periodic update check
  $SUDO tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << 'AUG_CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
AUG_CONF

  ok "Automatic security updates enabled"
else
  info "Skipping unattended-upgrades on non-Debian system"
fi

# ─── 7. Docker CE ──────────────────────────────────────────────────────────────

step "Installing Docker CE"

if [[ "${SKIP_DOCKER}" == "1" ]] || has_cmd docker; then
  info "Docker already installed — skipping"
  docker --version
else
  if [[ "$PKG_MGR" == "apt-get" ]]; then
    # Official Docker install via convenience script (handles all Debian-family distros)
    curl -fsSL https://get.docker.com | $SUDO sh
  elif [[ "$PKG_MGR" == "dnf" ]]; then
    $SUDO dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    $PKG_INSTALL docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  $SUDO systemctl enable docker
  $SUDO systemctl start docker
  ok "Docker CE installed"
fi

# Add current user to docker group if not root
if [[ $EUID -ne 0 ]]; then
  if ! groups | grep -q docker; then
    $SUDO usermod -aG docker "$USER"
    warn "Added $USER to docker group — SSH session will reflect this next login"
  fi
fi

# Verify Docker Compose v2
if docker compose version &>/dev/null; then
  COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "unknown")
  ok "Docker Compose v2 available: ${COMPOSE_VER}"
else
  warn "Docker Compose v2 not found — installing plugin..."
  if [[ "$PKG_MGR" == "apt-get" ]]; then
    $PKG_INSTALL docker-compose-plugin
  fi
fi

# ─── 8. System kernel settings for WireGuard ───────────────────────────────────

step "Applying kernel settings for WireGuard/Gerbil"
$SUDO tee /etc/sysctl.d/99-pangolin.conf > /dev/null << 'SYSCTL_CONF'
# Required for Gerbil (Pangolin WireGuard tunnel manager)
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
SYSCTL_CONF

$SUDO sysctl -p /etc/sysctl.d/99-pangolin.conf > /dev/null
ok "Kernel settings applied"

# ─── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "====================================="
echo "VPS_INIT_DONE"
echo "====================================="
echo ""
echo "System is ready for Pangolin deployment."
echo "Docker: $(docker --version 2>/dev/null || echo 'not found')"
echo "UFW:    $(ufw status 2>/dev/null | head -1 || echo 'not installed')"
