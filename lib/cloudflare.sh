#!/usr/bin/env bash
# lib/cloudflare.sh — Cloudflare Tunnel automation via the Cloudflare API
#
# Creates and manages a Cloudflare Tunnel so homelab services are reachable
# from the internet without a VPS or port forwarding.
#
# Traffic flow:
#   Internet → Cloudflare Edge → cloudflared container → Traefik → services
#
# API docs:
#   https://developers.cloudflare.com/api/
#   https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/

[[ -n "$HOMELAB_COMMON_LOADED" ]] || source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
HOMELAB_CLOUDFLARE_LOADED=1

# ─── API helpers ───────────────────────────────────────────────────────────────

CF_API="https://api.cloudflare.com/client/v4"
_CF_TOKEN=""       # set by cf_init
_CF_ACCOUNT_ID=""  # set by cf_get_account_id
_CF_ZONE_ID=""     # set by cf_get_zone_id

# cf_init <api_token>
cf_init() {
  _CF_TOKEN="$1"
  [[ -n "$_CF_TOKEN" ]] || die "Cloudflare API token is required"
}

# _cf_api <method> <endpoint> [body]
# Calls the Cloudflare API; returns the raw JSON response
_cf_api() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"

  local args=( -sf -X "$method" "${CF_API}${endpoint}"
    -H "Authorization: Bearer ${_CF_TOKEN}"
    -H "Content-Type: application/json" )

  [[ -n "$body" ]] && args+=( -d "$body" )

  curl "${args[@]}"
}

# _cf_check <response> <context>
# Dies if the CF response has success:false
_cf_check() {
  local resp="$1"
  local ctx="$2"
  local success
  success=$(echo "$resp" | jq -r '.success')
  if [[ "$success" != "true" ]]; then
    local errors
    errors=$(echo "$resp" | jq -r '.errors[]?.message // "unknown error"')
    die "Cloudflare API error ($ctx): $errors"
  fi
}

# ─── Account + Zone resolution ─────────────────────────────────────────────────

# cf_get_account_id
# Sets _CF_ACCOUNT_ID and prints it
cf_get_account_id() {
  log_sub "Looking up Cloudflare account ID..."
  local resp
  resp=$(_cf_api GET "/accounts?per_page=1")
  _cf_check "$resp" "list accounts"

  _CF_ACCOUNT_ID=$(echo "$resp" | jq -r '.result[0].id // empty')
  [[ -n "$_CF_ACCOUNT_ID" ]] || die "Could not find a Cloudflare account for this token"
  log_ok "Cloudflare account: $_CF_ACCOUNT_ID"
  echo "$_CF_ACCOUNT_ID"
}

# cf_get_zone_id <domain>
# Sets _CF_ZONE_ID and prints it
cf_get_zone_id() {
  local domain="$1"
  log_sub "Looking up Cloudflare zone for: $domain"

  local resp
  resp=$(_cf_api GET "/zones?name=${domain}&per_page=1")
  _cf_check "$resp" "lookup zone"

  _CF_ZONE_ID=$(echo "$resp" | jq -r '.result[0].id // empty')
  if [[ -z "$_CF_ZONE_ID" ]]; then
    # Try the apex domain (strip any subdomain)
    local apex_domain
    apex_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
    if [[ "$apex_domain" != "$domain" ]]; then
      resp=$(_cf_api GET "/zones?name=${apex_domain}&per_page=1")
      _CF_ZONE_ID=$(echo "$resp" | jq -r '.result[0].id // empty')
    fi
  fi

  [[ -n "$_CF_ZONE_ID" ]] || die "Zone not found for domain: $domain — is it added to Cloudflare?"
  log_ok "Cloudflare zone: $_CF_ZONE_ID"
  echo "$_CF_ZONE_ID"
}

# ─── Tunnel lifecycle ──────────────────────────────────────────────────────────

# cf_create_tunnel <name>
# Creates a named tunnel; sets CF_TUNNEL_ID, CF_TUNNEL_TOKEN
cf_create_tunnel() {
  local name="$1"

  log_sub "Creating Cloudflare Tunnel: $name"

  # Generate a random 32-byte tunnel secret (base64-encoded)
  local secret
  secret=$(openssl rand -base64 32 2>/dev/null || dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64)

  local resp
  resp=$(_cf_api POST "/accounts/${_CF_ACCOUNT_ID}/cfd_tunnel" \
    "{\"name\": \"${name}\", \"tunnel_secret\": \"${secret}\"}")
  _cf_check "$resp" "create tunnel"

  CF_TUNNEL_ID=$(echo "$resp" | jq -r '.result.id')
  [[ -n "$CF_TUNNEL_ID" ]] || die "Tunnel creation returned no ID"

  log_ok "Tunnel created: $CF_TUNNEL_ID"
}

# cf_get_tunnel_token <tunnel_id>
# Sets CF_TUNNEL_TOKEN
cf_get_tunnel_token() {
  local tunnel_id="${1:-$CF_TUNNEL_ID}"

  log_sub "Fetching tunnel token..."
  local resp
  resp=$(_cf_api GET "/accounts/${_CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/token")
  _cf_check "$resp" "get tunnel token"

  CF_TUNNEL_TOKEN=$(echo "$resp" | jq -r '.result')
  [[ -n "$CF_TUNNEL_TOKEN" ]] || die "Could not retrieve tunnel token"
  log_ok "Tunnel token obtained"
}

# cf_list_tunnels
# Prints existing tunnels as JSON array
cf_list_tunnels() {
  local resp
  resp=$(_cf_api GET "/accounts/${_CF_ACCOUNT_ID}/cfd_tunnel?per_page=50&is_deleted=false")
  _cf_check "$resp" "list tunnels"
  echo "$resp" | jq '.result'
}

# cf_delete_tunnel <tunnel_id>
cf_delete_tunnel() {
  local tunnel_id="$1"
  log_sub "Deleting tunnel: $tunnel_id"
  local resp
  resp=$(_cf_api DELETE "/accounts/${_CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}")
  _cf_check "$resp" "delete tunnel"
  log_ok "Tunnel deleted"
}

# ─── Tunnel ingress configuration ─────────────────────────────────────────────

# cf_configure_tunnel_wildcard <tunnel_id> <domain>
#
# Sets a wildcard ingress rule that routes *.domain → Traefik.
# This means zero per-app configuration in Cloudflare — Traefik handles routing.
#
cf_configure_tunnel_wildcard() {
  local tunnel_id="${1:-$CF_TUNNEL_ID}"
  local domain="$2"

  log_sub "Configuring tunnel ingress: *.${domain} → Traefik"

  local body
  body=$(jq -n \
    --arg domain "$domain" \
    '{
      "config": {
        "ingress": [
          {
            "hostname": ("*." + $domain),
            "service": "http://traefik:80",
            "originRequest": {
              "noTLSVerify": true,
              "httpHostHeader": ""
            }
          },
          {
            "service": "http_status:404"
          }
        ]
      }
    }')

  local resp
  resp=$(_cf_api PUT \
    "/accounts/${_CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" \
    "$body")
  _cf_check "$resp" "configure tunnel ingress"
  log_ok "Tunnel ingress configured: *.${domain} → traefik"
}

# ─── DNS record management ─────────────────────────────────────────────────────

# cf_create_tunnel_dns <tunnel_id> <domain>
#
# Creates a wildcard CNAME DNS record: *.domain → <tunnel-id>.cfargotunnel.com
# This is a proxied record (orange cloud = Cloudflare processes the traffic)
#
cf_create_tunnel_dns() {
  local tunnel_id="${1:-$CF_TUNNEL_ID}"
  local domain="$2"

  local tunnel_cname="${tunnel_id}.cfargotunnel.com"

  log_sub "Creating wildcard DNS: *.${domain} → ${tunnel_cname}"

  # Check if record already exists
  local existing
  existing=$(_cf_api GET "/zones/${_CF_ZONE_ID}/dns_records?type=CNAME&name=*.${domain}")
  local existing_id
  existing_id=$(echo "$existing" | jq -r '.result[0].id // empty')

  if [[ -n "$existing_id" ]]; then
    log_sub "Wildcard CNAME already exists — updating..."
    local resp
    resp=$(_cf_api PUT "/zones/${_CF_ZONE_ID}/dns_records/${existing_id}" \
      "{\"type\": \"CNAME\", \"name\": \"*\", \"content\": \"${tunnel_cname}\", \"proxied\": true, \"ttl\": 1}")
    _cf_check "$resp" "update wildcard DNS"
  else
    local resp
    resp=$(_cf_api POST "/zones/${_CF_ZONE_ID}/dns_records" \
      "{\"type\": \"CNAME\", \"name\": \"*\", \"content\": \"${tunnel_cname}\", \"proxied\": true, \"ttl\": 1}")
    _cf_check "$resp" "create wildcard DNS"
  fi

  CF_TUNNEL_DNS="${tunnel_cname}"
  log_ok "DNS record set: *.${domain} → ${tunnel_cname}"
}

# cf_delete_tunnel_dns <domain>
cf_delete_tunnel_dns() {
  local domain="$1"
  local existing
  existing=$(_cf_api GET "/zones/${_CF_ZONE_ID}/dns_records?type=CNAME&name=*.${domain}")
  local record_id
  record_id=$(echo "$existing" | jq -r '.result[0].id // empty')
  [[ -n "$record_id" ]] || { log_warn "No wildcard CNAME found for *.${domain}"; return 0; }

  _cf_api DELETE "/zones/${_CF_ZONE_ID}/dns_records/${record_id}" > /dev/null
  log_ok "DNS record removed: *.${domain}"
}

# ─── Newt-equivalent: cloudflared compose service ─────────────────────────────

# cf_setup_cloudflared <tunnel_token> <compose_file>
#
# Appends (or updates) the cloudflared service in the local docker-compose file.
# cloudflared must be on the t3_proxy network to reach Traefik by service name.
#
cf_setup_cloudflared() {
  local tunnel_token="$1"
  local compose_file="$2"

  log_sub "Configuring cloudflared container..."

  if grep -q "container_name: cloudflared" "$compose_file" 2>/dev/null; then
    log_sub "cloudflared already in compose — updating token..."
    sed -i "s|TUNNEL_TOKEN=.*|TUNNEL_TOKEN=${tunnel_token}|g" "$compose_file"
    return 0
  fi

  cat >> "$compose_file" <<EOF

  ########## CLOUDFLARE TUNNEL ##########
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=${tunnel_token}
    networks:
      - t3_proxy
    security_opt:
      - no-new-privileges:true
EOF

  log_ok "cloudflared service added to compose file"
}

# ─── Interactive wizard ────────────────────────────────────────────────────────

# cf_wizard_fresh
#
# Full interactive setup:
#   - Validates the CF API token (already collected in Phase 3)
#   - Creates the tunnel
#   - Configures wildcard ingress
#   - Creates wildcard DNS
#   - Saves to state
#
# Sets: CF_TUNNEL_ID, CF_TUNNEL_TOKEN, CF_ACCOUNT_ID, CF_ZONE_ID
#
cf_wizard_fresh() {
  log_step "Setting Up Cloudflare Tunnel"

  echo ""
  echo -e "  ${BOLD}What you need:${RESET}"
  echo -e "  ${GREEN}✓${RESET}  Cloudflare account (free — cloudflare.com)"
  echo -e "  ${GREEN}✓${RESET}  Your domain on Cloudflare"
  echo -e "  ${GREEN}✓${RESET}  Cloudflare API token (with Tunnel + DNS permissions)"
  echo ""
  echo -e "  ${DIM}If you already entered your CF token in Phase 3, we'll reuse it."
  echo -e "  Make sure the token has 'Cloudflare Tunnel: Edit' permission.${RESET}"
  echo ""

  # Reuse existing CF API token from state if available
  local cf_token
  cf_token=$(state_get '.cloudflare_api_token')
  if [[ -n "$cf_token" && "$cf_token" != "null" ]]; then
    log_info "Reusing Cloudflare API token from Phase 3"
  else
    echo -e "  ${BOLD}API Token permissions needed:${RESET}"
    echo -e "  • Zone → DNS → Edit"
    echo -e "  • Account → Cloudflare Tunnel → Edit"
    echo ""
    echo -e "  Create at: ${CYAN}dash.cloudflare.com/profile/api-tokens${RESET}"
    echo ""
    prompt_secret "Cloudflare API token"
    cf_token="$REPLY"
  fi

  [[ -n "$cf_token" ]] || die "Cloudflare API token is required"
  cf_init "$cf_token"

  # Get account + zone IDs
  local domain
  domain=$(state_get '.domain')

  cf_get_account_id
  cf_get_zone_id "$domain"

  # Tunnel name based on hostname
  local hostname
  hostname=$(state_get '.hostname')
  local tunnel_name="${hostname:-homelab}-tunnel"

  # Check if a tunnel with this name already exists
  log_sub "Checking for existing tunnel: $tunnel_name"
  local existing_tunnels
  existing_tunnels=$(cf_list_tunnels 2>/dev/null || echo "[]")
  local existing_id
  existing_id=$(echo "$existing_tunnels" | jq -r --arg name "$tunnel_name" '.[] | select(.name == $name) | .id' 2>/dev/null || true)

  if [[ -n "$existing_id" ]]; then
    log_warn "Tunnel '$tunnel_name' already exists (ID: $existing_id)"
    if prompt_yn "Reuse this existing tunnel?" "Y"; then
      CF_TUNNEL_ID="$existing_id"
      cf_get_tunnel_token "$CF_TUNNEL_ID"
    else
      tunnel_name="${tunnel_name}-$(date +%Y%m%d)"
      cf_create_tunnel "$tunnel_name"
      cf_get_tunnel_token
    fi
  else
    cf_create_tunnel "$tunnel_name"
    cf_get_tunnel_token
  fi

  # Configure tunnel ingress (wildcard → Traefik)
  cf_configure_tunnel_wildcard "$CF_TUNNEL_ID" "$domain"

  # Create wildcard DNS record
  cf_create_tunnel_dns "$CF_TUNNEL_ID" "$domain"

  # Save to state
  state_set "
    .tunnel.method = \"cloudflare\" |
    .tunnel.cloudflare.account_id = \"${_CF_ACCOUNT_ID}\" |
    .tunnel.cloudflare.zone_id = \"${_CF_ZONE_ID}\" |
    .tunnel.cloudflare.tunnel_id = \"${CF_TUNNEL_ID}\" |
    .tunnel.cloudflare.tunnel_name = \"${tunnel_name}\" |
    .tunnel.cloudflare.tunnel_token = \"${CF_TUNNEL_TOKEN}\" |
    .cloudflare_api_token = \"${cf_token}\"
  "

  log_ok "Cloudflare Tunnel ready"
  echo ""
  echo -e "  ${BOLD}Tunnel:${RESET}   $tunnel_name"
  echo -e "  ${BOLD}Domain:${RESET}   *.${domain} → ${CF_TUNNEL_DNS:-tunnel}"
  echo -e "  ${BOLD}Routing:${RESET}  All subdomains → Traefik (zero per-app config!)"
  echo ""
}

# cf_wizard_existing
#
# Connect to an already-created Cloudflare Tunnel (user has the token)
#
cf_wizard_existing() {
  log_step "Connecting to Existing Cloudflare Tunnel"

  prompt_input "Cloudflare API token" "$(state_get '.cloudflare_api_token')"
  local cf_token="$REPLY"
  cf_init "$cf_token"

  local domain
  domain=$(state_get '.domain')
  cf_get_account_id
  cf_get_zone_id "$domain"

  prompt_input "Tunnel ID (from Cloudflare dashboard)" ""
  CF_TUNNEL_ID="$REPLY"

  prompt_secret "Tunnel token"
  CF_TUNNEL_TOKEN="$REPLY"

  state_set "
    .tunnel.method = \"cloudflare\" |
    .tunnel.cloudflare.account_id = \"${_CF_ACCOUNT_ID}\" |
    .tunnel.cloudflare.zone_id = \"${_CF_ZONE_ID}\" |
    .tunnel.cloudflare.tunnel_id = \"${CF_TUNNEL_ID}\" |
    .tunnel.cloudflare.tunnel_token = \"${CF_TUNNEL_TOKEN}\" |
    .cloudflare_api_token = \"${cf_token}\"
  "
}

# ─── Status ────────────────────────────────────────────────────────────────────

cf_status() {
  local tunnel_id
  tunnel_id=$(state_get '.tunnel.cloudflare.tunnel_id')
  [[ -n "$tunnel_id" && "$tunnel_id" != "null" ]] || { log_warn "No Cloudflare Tunnel configured"; return 1; }

  local cf_token
  cf_token=$(state_get '.cloudflare_api_token')
  cf_init "$cf_token"
  cf_get_account_id > /dev/null

  local resp
  resp=$(_cf_api GET "/accounts/${_CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}")
  echo "$resp" | jq '{
    name: .result.name,
    id: .result.id,
    status: .result.status,
    connections: (.result.connections // []) | length
  }'
}

# ─── Note on Cloudflare Proxy + Pangolin ───────────────────────────────────────
#
# You can run both Pangolin AND Cloudflare Proxy together:
#
#   Traffic: User → Cloudflare Edge → VPS (Pangolin) → tunnel → Traefik
#
# To enable:
#   1. In Cloudflare DNS, flip your records from "grey cloud" (DNS only) to
#      "orange cloud" (proxied). Records should point to your VPS IP as type A.
#   2. In Cloudflare SSL/TLS settings, set mode to "Full (strict)" — this ensures
#      Cloudflare validates Pangolin's Let's Encrypt cert and encrypts the
#      Cloudflare-to-VPS leg of the connection.
#   3. No changes needed to Pangolin or Traefik.
#
# Benefits of this combination:
#   ✓ DDoS protection (Cloudflare absorbs attacks before they hit your VPS)
#   ✓ Your VPS IP is hidden (Cloudflare's IPs are shown publicly)
#   ✓ Free CDN caching for static content
#   ✓ Cloudflare WAF rules (free tier covers OWASP Top 10)
#
# cf_enable_proxy_on_pangolin <domain>
#
# Updates existing Pangolin DNS A records to be proxied.
# Requires _CF_ZONE_ID to be set (call cf_get_zone_id first).
#
cf_enable_proxy_on_pangolin() {
  local domain="$1"

  log_sub "Enabling Cloudflare proxy (orange cloud) on existing DNS records..."

  local resp
  resp=$(_cf_api GET "/zones/${_CF_ZONE_ID}/dns_records?type=A&per_page=100")
  _cf_check "$resp" "list DNS records"

  local count=0
  while IFS= read -r record_id; do
    local record_name record_content
    record_name=$(echo "$resp" | jq -r --arg id "$record_id" '.result[] | select(.id == $id) | .name')
    record_content=$(echo "$resp" | jq -r --arg id "$record_id" '.result[] | select(.id == $id) | .content')

    # Skip root domain — only proxy service subdomains
    if [[ "$record_name" == "@" || "$record_name" == "$domain" ]]; then
      continue
    fi

    _cf_api PATCH "/zones/${_CF_ZONE_ID}/dns_records/${record_id}" \
      '{"proxied": true}' > /dev/null && ((count++))
  done < <(echo "$resp" | jq -r '.result[].id')

  if (( count > 0 )); then
    log_ok "Enabled Cloudflare proxy on $count A records"
    log_info "Set SSL/TLS mode to 'Full (strict)' in your Cloudflare dashboard"
    log_info "→ dash.cloudflare.com/$(state_get '.domain')/ssl-tls"
  else
    log_warn "No A records found to proxy. Add them in Cloudflare first."
  fi
}
