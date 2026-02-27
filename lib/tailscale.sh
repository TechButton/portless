#!/usr/bin/env bash
# lib/tailscale.sh — Tailscale VPN setup and management
#
# Tailscale creates an encrypted WireGuard mesh between your devices.
# Services are accessible at Tailscale IPs from any enrolled device.
# Optional subnet routing exposes Docker networks to all Tailscale peers.
#

[[ -n "$HOMELAB_COMMON_LOADED" ]] || source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
HOMELAB_TAILSCALE_LOADED=1

# ─── Wizard ───────────────────────────────────────────────────────────────────

tailscale_wizard() {
  log_step "Tailscale Setup"

  cat <<EOF

  ${BOLD}Tailscale${RESET} creates an encrypted WireGuard mesh between your devices.
  All services become accessible from any device with Tailscale installed —
  no port forwarding, no VPS, no open ports on your router.

  ${BOLD}What you need:${RESET}
  • Free Tailscale account at ${CYAN}tailscale.com${RESET}
  • Auth key from ${CYAN}login.tailscale.com/admin/settings/keys${RESET}
  • Tailscale installed on devices you want access from

  ${DIM}Note: Services are accessible at Tailscale IPs (100.x.x.x) or MagicDNS
  hostnames — NOT via public URLs like movies.yourdomain.com.
  For public URL access, choose Cloudflare Tunnel or Pangolin.${RESET}

EOF

  prompt_input "Tailscale auth key (tskey-auth-...)" ""
  local ts_auth_key="$REPLY"
  [[ -n "$ts_auth_key" ]] || die "Tailscale auth key is required"

  local default_hostname
  default_hostname=$(hostname -s 2>/dev/null || echo "homelab")
  prompt_input "Device hostname in Tailscale admin console" "$default_hostname"
  local ts_hostname="$REPLY"

  echo ""
  echo -e "  ${BOLD}Subnet routing${RESET} exposes your Docker networks to all Tailscale peers."
  echo -e "  ${DIM}Advertises 192.168.90.0/24 and 192.168.91.0/24 — your t3_proxy and${RESET}"
  echo -e "  ${DIM}socket_proxy networks. Peers can reach containers by IP address.${RESET}"
  echo ""
  local subnet_router=false
  if prompt_yn "Enable subnet routing?" "Y"; then
    subnet_router=true
    echo ""
    log_info "After deployment, approve routes in the Tailscale admin console:"
    log_info "  https://login.tailscale.com/admin/machines"
    log_info "  Click your device → Edit route settings → enable advertised routes"
  fi

  # Persist to state
  state_set "
    .tunnel.method = \"tailscale\" |
    .tunnel.tailscale.auth_key = \"${ts_auth_key}\" |
    .tunnel.tailscale.hostname = \"${ts_hostname}\" |
    .tunnel.tailscale.subnet_router = ${subnet_router}
  "

  log_ok "Tailscale configured"
  echo ""
  log_info "Your Tailscale IP will be shown after deployment: tailscale ip -4"
  log_info "MagicDNS hostname: ${ts_hostname}"
}

# ─── Compose integration ──────────────────────────────────────────────────────

# Append tailscale service block to compose file
tailscale_setup_compose() {
  local compose_file="$1"

  local ts_hostname subnet_router
  ts_hostname=$(state_get '.tunnel.tailscale.hostname')
  subnet_router=$(state_get '.tunnel.tailscale.subnet_router')

  local ts_extra_args=""
  if [[ "$subnet_router" == "true" ]]; then
    ts_extra_args="--advertise-routes=192.168.90.0/24,192.168.91.0/24 --accept-routes"
  fi

  cat >> "$compose_file" <<EOF

  ########## TAILSCALE ##########
  tailscale:
    image: tailscale/tailscale:latest
    container_name: tailscale
    restart: unless-stopped
    hostname: ${ts_hostname}
    environment:
      - TS_AUTHKEY=\${TAILSCALE_AUTH_KEY}
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_USERSPACE=false
      - TS_ACCEPT_DNS=false
      - TS_EXTRA_ARGS=${ts_extra_args}
    volumes:
      - \${DOCKERDIR}/appdata/tailscale:/var/lib/tailscale
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
      - NET_RAW
    networks:
      - t3_proxy
      - socket_proxy
    security_opt:
      - no-new-privileges:true
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
EOF

  log_sub "Tailscale container added to compose"
}

# Write Tailscale env vars to .env file
tailscale_write_env() {
  local env_file="$1"
  local auth_key
  auth_key=$(state_get '.tunnel.tailscale.auth_key')

  if ! grep -q "^TAILSCALE_AUTH_KEY=" "$env_file" 2>/dev/null; then
    {
      echo ""
      echo "# Tailscale"
      echo "TAILSCALE_AUTH_KEY=${auth_key}"
    } >> "$env_file"
  fi
}

# ─── Status ───────────────────────────────────────────────────────────────────

tailscale_status() {
  local ts_hostname subnet_router
  ts_hostname=$(state_get '.tunnel.tailscale.hostname')
  subnet_router=$(state_get '.tunnel.tailscale.subnet_router')

  echo -e "  Hostname:      ${CYAN}${ts_hostname:-not set}${RESET}"
  echo -e "  Subnet router: ${CYAN}${subnet_router:-false}${RESET}"
  echo ""

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^tailscale$'; then
    log_sub "Tailscale peer status:"
    docker exec tailscale tailscale status 2>/dev/null \
      || log_warn "Could not get Tailscale status (container may still be starting)"
    echo ""
    log_sub "Tailscale IP:"
    docker exec tailscale tailscale ip -4 2>/dev/null || true
  else
    log_warn "Tailscale container is not running"
    log_info "Start it: docker compose up -d tailscale"
  fi
}
