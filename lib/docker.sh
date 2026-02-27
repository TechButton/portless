#!/usr/bin/env bash
# lib/docker.sh — Docker + Docker Compose v2 installation helpers

# shellcheck source=lib/common.sh
[[ -n "$HOMELAB_COMMON_LOADED" ]] || source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
HOMELAB_DOCKER_LOADED=1

# ─── Detection ──────────────────────────────────────────────────────────────────

docker_is_installed() {
  command -v docker &>/dev/null
}

docker_compose_v2_available() {
  docker compose version &>/dev/null 2>&1
}

docker_running() {
  docker info &>/dev/null 2>&1
}

# ─── Installation ────────────────────────────────────────────────────────────────

install_docker() {
  log_step "Installing Docker"

  detect_os

  case "$OS_FAMILY" in
    debian)
      _install_docker_debian
      ;;
    arch)
      _install_docker_arch
      ;;
    rhel)
      _install_docker_rhel
      ;;
    *)
      die "Unsupported OS: $OS_NAME. Please install Docker manually: https://docs.docker.com/engine/install/"
      ;;
  esac

  _post_install_docker
}

_install_docker_debian() {
  log_sub "Installing Docker via official apt repository (Debian/Ubuntu)"

  # Remove old versions
  sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

  # Dependencies
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

  # Add Docker GPG key
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  # Determine correct repo for Ubuntu vs Debian
  local distro
  if [[ "$OS_ID" == "ubuntu" ]]; then
    distro="ubuntu"
  else
    distro="debian"
  fi

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${distro} \
$(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  log_ok "Docker installed successfully"
}

_install_docker_arch() {
  log_sub "Installing Docker via pacman (Arch Linux)"
  sudo pacman -Sy --noconfirm docker docker-compose
  log_ok "Docker installed successfully"
}

_install_docker_rhel() {
  log_sub "Installing Docker via official yum/dnf repository (RHEL/CentOS/Fedora)"

  # Remove old versions
  sudo dnf remove -y docker docker-client docker-client-latest docker-common \
    docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true

  sudo dnf -y install dnf-plugins-core
  sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  log_ok "Docker installed successfully"
}

_post_install_docker() {
  # Enable + start Docker service
  sudo systemctl enable docker --now

  # Add current user to docker group
  if ! groups | grep -q docker; then
    sudo usermod -aG docker "$USER"
    log_warn "Added $USER to the 'docker' group."
    log_warn "You must log out and back in (or run 'newgrp docker') for this to take effect."
    log_warn "After re-login, re-run this installer."
    export DOCKER_GROUP_ADDED=1
  fi

  # Verify
  if docker_running; then
    log_ok "Docker daemon is running"
  else
    log_warn "Docker was installed but the daemon isn't running yet."
    log_warn "Try: sudo systemctl start docker"
  fi
}

# ─── Compose v2 check / install ──────────────────────────────────────────────────

ensure_compose_v2() {
  if docker_compose_v2_available; then
    local version
    version=$(docker compose version --short 2>/dev/null || docker compose version | grep -oP 'v[\d.]+')
    log_ok "Docker Compose v2 available: $version"
    return 0
  fi

  log_warn "Docker Compose v2 plugin not found."

  # Try to install docker-compose-plugin
  detect_os
  case "$OS_FAMILY" in
    debian)
      log_sub "Installing docker-compose-plugin..."
      sudo apt-get install -y -qq docker-compose-plugin && \
        log_ok "docker-compose-plugin installed" || \
        log_warn "Could not auto-install. See: https://docs.docker.com/compose/install/"
      ;;
    arch)
      sudo pacman -Sy --noconfirm docker-compose
      ;;
    rhel)
      sudo dnf install -y docker-compose-plugin
      ;;
  esac

  if ! docker_compose_v2_available; then
    die "Docker Compose v2 is required but could not be installed. Please install it manually."
  fi
}

# ─── Docker network helpers ──────────────────────────────────────────────────────

ensure_docker_network() {
  local network="$1"
  local subnet="${2:-}"

  if ! docker network ls --format '{{.Name}}' | grep -qx "$network"; then
    log_sub "Creating Docker network: $network"
    if [[ -n "$subnet" ]]; then
      docker network create --subnet="$subnet" "$network" >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 || \
        log_warn "Could not create network $network with subnet $subnet"
    else
      docker network create "$network" >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 || \
        log_warn "Could not create network $network"
    fi
  else
    log_sub "Docker network '$network' already exists"
  fi
}

# ─── Container utilities ─────────────────────────────────────────────────────────

container_running() {
  local name="$1"
  docker ps --filter "name=^${name}$" --filter "status=running" --format '{{.Names}}' | grep -qx "$name"
}

container_exists() {
  local name="$1"
  docker ps -a --filter "name=^${name}$" --format '{{.Names}}' | grep -qx "$name"
}

pull_image() {
  local image="$1"
  log_sub "Pulling image: $image"
  docker pull "$image" >> ${LOG_FILE:-/tmp/portless-install.log} 2>&1 || log_warn "Could not pull $image"
}
