#!/usr/bin/env bash
# lib/traefik.sh — Traefik setup wizard, compose generation, and dynamic rule generation

[[ -n "$HOMELAB_COMMON_LOADED" ]] || source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
HOMELAB_TRAEFIK_LOADED=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Reference templates (used by manage.sh regen for manual rule creation)
TRAEFIK_TMPL_NOAUTH="${REPO_ROOT}/templates/traefik/app-noauth.yml.tmpl"
TRAEFIK_TMPL_TINYAUTH="${REPO_ROOT}/templates/traefik/app-tinyauth.yml.tmpl"
TRAEFIK_TMPL_BASICAUTH="${REPO_ROOT}/templates/traefik/app-basic-auth.yml.tmpl"

# Defaults — overridden from state during setup
TRAEFIK_ACCESS_MODE="${TRAEFIK_ACCESS_MODE:-hybrid}"
TRAEFIK_AUTH_SYSTEM="${TRAEFIK_AUTH_SYSTEM:-tinyauth}"
TRAEFIK_CROWDSEC_ENABLED="${TRAEFIK_CROWDSEC_ENABLED:-false}"

# ══════════════════════════════════════════════════════════════════════════════
# WIZARD — Access mode, auth system, CrowdSec
# ══════════════════════════════════════════════════════════════════════════════

#
# traefik_setup_wizard — ask user for access mode (local vs hybrid)
# Sets: TRAEFIK_ACCESS_MODE, writes to state
#
traefik_setup_wizard() {
  echo ""
  log_step "Traefik Access Mode"

  cat <<EOF

  ${BOLD}How will you access your services?${RESET}

  ${CYAN}1) Hybrid — LAN + remote (recommended)${RESET}
     • LAN access on port ${BOLD}443${RESET}  (fast, direct, always works)
     • Remote access on port ${BOLD}444${RESET} via your tunnel (Pangolin / Cloudflare)
     • Apps can be restricted to LAN-only or available both ways
     • ${DIM}This is what most homelabs use${RESET}

  ${CYAN}2) Local only${RESET}
     • LAN access on port ${BOLD}443${RESET} only
     • No external entrypoint — add remote access later
     • ${DIM}Good if you only need access inside your home network${RESET}

EOF

  prompt_select "Access mode:" \
    "Hybrid — LAN + remote access (recommended)" \
    "Local only — LAN access only"

  if [[ "$REPLY" == Hybrid* ]]; then
    TRAEFIK_ACCESS_MODE="hybrid"
    state_set ".traefik.access_mode = \"hybrid\""
    log_ok "Hybrid mode: LAN (:443) + remote (:444)"
    log_info "Tunnel provider will connect to port 444 on this server."
  else
    TRAEFIK_ACCESS_MODE="local"
    state_set ".traefik.access_mode = \"local\""
    log_ok "Local only mode: LAN (:443)"
    log_info "Remote access can be added later with: ./manage.sh tunnel setup"
  fi
}

#
# traefik_select_auth — choose authentication system
# Sets: TRAEFIK_AUTH_SYSTEM, writes to state
#
traefik_select_auth() {
  echo ""
  log_step "Authentication Layer"

  cat <<EOF

  An authentication layer protects all your services with a single login.
  Without one, anyone who can reach a URL can access the app behind it.

  ${CYAN}1) TinyAuth (recommended)${RESET}
     • Self-hosted single sign-on — one login protects all apps
     • Local user accounts + optional GitHub/Google OAuth
     • Optional 2FA support
     • Lightweight: single container, ~50 MB RAM
     • ${DIM}Docs: https://tinyauth.app${RESET}

  ${CYAN}2) Basic Auth${RESET}
     • Username/password prompt built into Traefik
     • Simple but no SSO — each browser session prompts separately
     • No extra container required

  ${CYAN}3) None${RESET}
     • No authentication layer added
     • ${YELLOW}Only safe for LAN-only setups or apps with built-in auth${RESET}

EOF

  prompt_select "Authentication system:" \
    "TinyAuth — self-hosted SSO (recommended)" \
    "Basic Auth — simple username/password" \
    "None — no auth layer"

  case "$REPLY" in
    TinyAuth*)
      TRAEFIK_AUTH_SYSTEM="tinyauth"
      state_set ".traefik.auth_system = \"tinyauth\""
      log_ok "TinyAuth selected"
      ;;
    Basic*)
      TRAEFIK_AUTH_SYSTEM="basic"
      state_set ".traefik.auth_system = \"basic\""
      log_ok "Basic Auth selected"
      if [[ "${TRAEFIK_ACCESS_MODE}" == "hybrid" ]]; then
        log_warn "Basic Auth credentials will be asked for every new browser session."
        log_warn "Consider upgrading to TinyAuth for a better experience."
      fi
      ;;
    None*)
      TRAEFIK_AUTH_SYSTEM="none"
      state_set ".traefik.auth_system = \"none\""
      if [[ "${TRAEFIK_ACCESS_MODE}" == "hybrid" ]]; then
        log_warn "No auth selected with remote access enabled."
        log_warn "Your apps will be publicly accessible to anyone with the URL!"
        log_warn "You can add TinyAuth later: ./manage.sh security auth"
      fi
      ;;
  esac
}

#
# traefik_ask_crowdsec — offer CrowdSec intrusion prevention
# Sets: TRAEFIK_CROWDSEC_ENABLED, writes to state
#
# Behaviour varies by tunnel type:
#   pangolin/cloudflare — home server only sees tunnel IP, not real attacker IPs.
#                         CrowdSec is more useful on the VPS. Shown as optional/off.
#   tailscale/headscale/netbird — private VPN mesh, no public exposure at all.
#                         CrowdSec provides no benefit here; silently skipped.
#   none (local only)  — if someone is doing direct port-forwarding, real IPs are
#                         visible and CrowdSec is genuinely useful. Prompted normally.
#
traefik_ask_crowdsec() {
  # Read tunnel method — set by phase5 before this is called
  local tunnel_method="${TUNNEL_METHOD:-$(state_get '.tunnel.method // "none"')}"

  # ── VPN mesh: no public ports at all — CrowdSec adds nothing ─────────────────
  if [[ "$tunnel_method" == "tailscale" || "$tunnel_method" == "headscale" || "$tunnel_method" == "netbird" ]]; then
    TRAEFIK_CROWDSEC_ENABLED="false"
    state_set ".traefik.crowdsec_enabled = false"
    return 0
  fi

  echo ""
  log_step "Intrusion Prevention (CrowdSec)"

  # ── Proxy tunnel (Pangolin/Cloudflare): better on the VPS ────────────────────
  if [[ "$tunnel_method" == "pangolin" || "$tunnel_method" == "cloudflare" ]]; then

    if [[ "$tunnel_method" == "pangolin" ]]; then
      cat <<EOF

  ${BOLD}You're using Pangolin — your home server has no direct internet exposure.${RESET}

  All traffic arrives through the WireGuard tunnel from your VPS. This means
  Traefik on this home server only sees the ${BOLD}tunnel IP${RESET}, not real attacker IPs.
  CrowdSec on this machine would have nothing meaningful to block.

  ${BOLD}CrowdSec is much more effective on your Pangolin VPS${RESET}, where the real public
  IPs are visible. See the post-install notes for how to add it there.

  ${DIM}You can still install CrowdSec here for defence-in-depth (e.g. if you ever
  add direct port-forwards later), but it's not recommended for this setup.${RESET}

EOF
    else
      # Cloudflare Tunnel
      cat <<EOF

  ${BOLD}You're using Cloudflare Tunnel — Cloudflare already handles edge protection.${RESET}

  Cloudflare's network blocks bots, DDoS, and known malicious IPs before
  traffic ever reaches your server. CrowdSec on this home server would only
  see Cloudflare's edge IPs, not real attacker IPs — so it can't act on them.

  ${DIM}You can still install CrowdSec here for defence-in-depth, but it's not
  recommended or useful for this setup.${RESET}

EOF
    fi

    if prompt_yn "Install CrowdSec on this home server anyway? (not recommended)" "N"; then
      TRAEFIK_CROWDSEC_ENABLED="true"
      state_set ".traefik.crowdsec_enabled = true"
      log_ok "CrowdSec will be installed"
      log_info "After deploy, run: ./manage.sh security crowdsec-setup"
    else
      TRAEFIK_CROWDSEC_ENABLED="false"
      state_set ".traefik.crowdsec_enabled = false"
      log_ok "CrowdSec skipped (recommended for this setup)"
    fi
    return 0
  fi

  # ── No tunnel / local only: real IPs visible — CrowdSec is genuinely useful ──
  cat <<EOF

  ${BOLD}CrowdSec${RESET} is a free, open-source intrusion prevention system.
  It watches your Traefik access logs and automatically blocks IPs that
  match known attack patterns — using threat intelligence from millions
  of servers worldwide.

  ${GREEN}✓${RESET}  Blocks bots, scanners, and brute-force attacks automatically
  ${GREEN}✓${RESET}  Community-sourced blocklist (updated continuously)
  ${GREEN}✓${RESET}  Free and open-source — no account required for basic use
  ${DIM}   Adds ~100 MB RAM. Requires a one-time API key setup after install.${RESET}

EOF

  if prompt_yn "Enable CrowdSec intrusion prevention?" "Y"; then
    TRAEFIK_CROWDSEC_ENABLED="true"
    state_set ".traefik.crowdsec_enabled = true"
    log_ok "CrowdSec will be installed"
    log_info "After deploy, run: ./manage.sh security crowdsec-setup  (generates API key)"
  else
    TRAEFIK_CROWDSEC_ENABLED="false"
    state_set ".traefik.crowdsec_enabled = false"
    log_info "CrowdSec skipped — add later with: ./manage.sh security crowdsec"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# COMPOSE SERVICE GENERATION
# ══════════════════════════════════════════════════════════════════════════════

#
# traefik_write_compose_service <compose_file> [access_mode] [auth_system]
#
# Appends socket-proxy + traefik service blocks to the compose file.
# Entrypoints depend on access_mode: local (443/80 only) or hybrid (443/80 + 444/81).
#
traefik_write_compose_service() {
  local compose_file="$1"
  local access_mode="${2:-${TRAEFIK_ACCESS_MODE:-hybrid}}"
  local auth_system="${3:-${TRAEFIK_AUTH_SYSTEM:-tinyauth}}"

  local traefik_chain
  case "$auth_system" in
    tinyauth) traefik_chain="chain-tinyauth" ;;
    basic)    traefik_chain="chain-basic-auth" ;;
    *)        traefik_chain="chain-no-auth" ;;
  esac

  log_sub "Generating socket-proxy and Traefik service definitions..."

  # ── Socket Proxy ────────────────────────────────────────────────────────────
  cat >> "$compose_file" <<'EOF'

  ########## SOCKET PROXY ##########
  socket-proxy:
    container_name: socket-proxy
    image: lscr.io/linuxserver/socket-proxy:latest
    security_opt:
      - no-new-privileges:true
    restart: unless-stopped
    networks:
      socket_proxy:
        ipv4_address: 192.168.91.254
    environment:
      - CONTAINERS=1
      - POST=0
      - NETWORKS=1
      - SERVICES=0
      - TASKS=0
      - IMAGES=0
      - INFO=0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    tmpfs:
      - /run
EOF

  # ── Traefik — entrypoints vary by access mode ───────────────────────────────
  local ports_block entrypoint_cmds forwardedheaders_cmds tls_cmds

  if [[ "$access_mode" == "hybrid" ]]; then
    ports_block='    ports:
      - "80:80"
      - "81:81"
      - "443:443"
      - "444:444"'
    entrypoint_cmds='      - --entrypoints.web-internal.address=:80
      - --entrypoints.web-external.address=:81
      - --entrypoints.websecure-internal.address=:443
      - --entrypoints.websecure-external.address=:444
      - --entrypoints.web-internal.http.redirections.entrypoint.to=websecure-internal
      - --entrypoints.web-internal.http.redirections.entrypoint.scheme=https
      - --entrypoints.web-internal.http.redirections.entrypoint.permanent=true
      - --entrypoints.web-external.http.redirections.entrypoint.to=websecure-external
      - --entrypoints.web-external.http.redirections.entrypoint.scheme=https
      - --entrypoints.web-external.http.redirections.entrypoint.permanent=true'
    forwardedheaders_cmds='      - --entrypoints.websecure-internal.forwardedHeaders.trustedIPs=${CLOUDFLARE_IPS},${LOCAL_IPS}
      - --entrypoints.websecure-external.forwardedHeaders.trustedIPs=${CLOUDFLARE_IPS},${LOCAL_IPS}'
    tls_cmds='      - --entrypoints.websecure-internal.http.tls=true
      - --entrypoints.websecure-internal.http.tls.certresolver=dns-cloudflare
      - --entrypoints.websecure-internal.http.tls.options=tls-opts@file
      - --entrypoints.websecure-internal.http.tls.domains[0].main=${DOMAINNAME_1}
      - --entrypoints.websecure-internal.http.tls.domains[0].sans=*.${DOMAINNAME_1}
      - --entrypoints.websecure-external.http.tls=true
      - --entrypoints.websecure-external.http.tls.certresolver=dns-cloudflare
      - --entrypoints.websecure-external.http.tls.options=tls-opts@file
      - --entrypoints.websecure-external.http.tls.domains[0].main=${DOMAINNAME_1}
      - --entrypoints.websecure-external.http.tls.domains[0].sans=*.${DOMAINNAME_1}'
  else
    # local mode — single entrypoint pair
    ports_block='    ports:
      - "80:80"
      - "443:443"'
    entrypoint_cmds='      - --entrypoints.web-internal.address=:80
      - --entrypoints.websecure-internal.address=:443
      - --entrypoints.web-internal.http.redirections.entrypoint.to=websecure-internal
      - --entrypoints.web-internal.http.redirections.entrypoint.scheme=https
      - --entrypoints.web-internal.http.redirections.entrypoint.permanent=true'
    forwardedheaders_cmds='      - --entrypoints.websecure-internal.forwardedHeaders.trustedIPs=${CLOUDFLARE_IPS},${LOCAL_IPS}'
    tls_cmds='      - --entrypoints.websecure-internal.http.tls=true
      - --entrypoints.websecure-internal.http.tls.certresolver=dns-cloudflare
      - --entrypoints.websecure-internal.http.tls.options=tls-opts@file
      - --entrypoints.websecure-internal.http.tls.domains[0].main=${DOMAINNAME_1}
      - --entrypoints.websecure-internal.http.tls.domains[0].sans=*.${DOMAINNAME_1}'
  fi

  cat >> "$compose_file" <<EOF

  ########## TRAEFIK ##########
  traefik:
    container_name: traefik
    image: traefik:\${TRAEFIK_VERSION_PIN:-3.3}
    security_opt:
      - no-new-privileges:true
    restart: unless-stopped
    depends_on:
      - socket-proxy
    networks:
      t3_proxy:
        ipv4_address: 192.168.90.254
      socket_proxy:
${ports_block}
    command:
      - --global.checkNewVersion=true
      - --global.sendAnonymousUsage=false
      - --api=true
      - --api.dashboard=true
      - --log=true
      - --log.filePath=/logs/traefik.log
      - --log.level=INFO
      - --accessLog=true
      - --accessLog.filePath=/logs/access.log
      - --accessLog.bufferingSize=100
      - --accessLog.filters.statusCodes=204-299,400-499,500-599
      - --providers.docker=true
      - --providers.docker.endpoint=tcp://socket-proxy:2375
      - --providers.docker.exposedByDefault=false
      - --providers.docker.network=t3_proxy
      - --providers.file.directory=/rules
      - --providers.file.watch=true
      - --certificatesResolvers.dns-cloudflare.acme.storage=/acme.json
      - --certificatesResolvers.dns-cloudflare.acme.dnsChallenge.provider=cloudflare
      - --certificatesResolvers.dns-cloudflare.acme.dnsChallenge.resolvers=1.1.1.1:53,1.0.0.1:53
      - --certificatesResolvers.dns-cloudflare.acme.dnsChallenge.delayBeforeCheck=120
${entrypoint_cmds}
${forwardedheaders_cmds}
${tls_cmds}
    volumes:
      - \${DOCKERDIR}/appdata/traefik3/rules/\${HOSTNAME}:/rules
      - \${DOCKERDIR}/appdata/traefik3/acme/acme.json:/acme.json
      - \${DOCKERDIR}/logs/\${HOSTNAME}/traefik:/logs
    environment:
      - TZ=\${TZ}
      - CF_DNS_API_TOKEN_FILE=/run/secrets/cf_dns_api_token
      - DOMAINNAME_1
      - DOCKER_API_VERSION=\${DOCKER_API_VERSION:-1.41}
    secrets:
      - cf_dns_api_token
      - basic_auth_credentials
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-rtr.entrypoints=websecure-internal"
      - "traefik.http.routers.traefik-rtr.rule=Host(\`traefik.\${DOMAINNAME_1}\`)"
      - "traefik.http.routers.traefik-rtr.service=api@internal"
      - "traefik.http.routers.traefik-rtr.middlewares=${traefik_chain}@file"
EOF

  log_ok "Traefik service added (mode: ${access_mode}, auth: ${auth_system})"
}

#
# crowdsec_write_compose_service <compose_file>
#
# Appends CrowdSec + traefik-bouncer service blocks to the compose file.
#
crowdsec_write_compose_service() {
  local compose_file="$1"

  log_sub "Adding CrowdSec + Traefik bouncer services..."

  cat >> "$compose_file" <<'EOF'

  ########## CROWDSEC ##########
  crowdsec:
    container_name: crowdsec
    image: crowdsecurity/crowdsec:latest
    security_opt:
      - no-new-privileges:true
    restart: unless-stopped
    networks:
      - default
      - t3_proxy
    environment:
      - COLLECTIONS=crowdsecurity/traefik crowdsecurity/http-cve crowdsecurity/whitelist-good-actors crowdsecurity/linux
      - GID=${PGID}
      - CUSTOM_HOSTNAME=${HOSTNAME}
    volumes:
      - ${DOCKERDIR}/logs/${HOSTNAME}:/logs/${HOSTNAME}:ro
      - /var/log:/var/log:ro
      - ${DOCKERDIR}/appdata/crowdsec/data:/var/lib/crowdsec/data
      - ${DOCKERDIR}/appdata/crowdsec/config:/etc/crowdsec

  ########## CROWDSEC TRAEFIK BOUNCER ##########
  traefik-bouncer:
    container_name: traefik-bouncer
    image: fbonalair/traefik-crowdsec-bouncer:latest
    security_opt:
      - no-new-privileges:true
    restart: unless-stopped
    networks:
      - default
      - t3_proxy
    environment:
      - GIN_MODE=release
      - CROWDSEC_BOUNCER_API_KEY=${CROWDSEC_TRAEFIK_BOUNCER_API_KEY}
      - CROWDSEC_AGENT_HOST=crowdsec:8080
      - CROWDSEC_BOUNCER_LOG_LEVEL=2
EOF

  log_ok "CrowdSec + bouncer services added"
}

#
# tinyauth_write_compose_service <compose_file>
#
# Appends TinyAuth SSO service block to the compose file.
#
tinyauth_write_compose_service() {
  local compose_file="$1"
  local domain
  domain=$(state_get '.domain')

  log_sub "Adding TinyAuth SSO service..."

  cat >> "$compose_file" <<EOF

  ########## TINYAUTH ##########
  tinyauth:
    container_name: tinyauth
    image: ghcr.io/steveiliop56/tinyauth:\${TINYAUTH_VERSION_PIN:-v3}
    security_opt:
      - no-new-privileges:true
    restart: unless-stopped
    networks:
      - default
      - t3_proxy
    volumes:
      - \${DOCKERDIR}/appdata/tinyauth/users_file:/tinyauth/users_file
    environment:
      - SECRET_FILE=/run/secrets/tinyauth_secret
      - APP_URL=https://auth.\${DOMAINNAME_1}
      - USERS_FILE=users_file
      - LOG_LEVEL=0
      - LOGIN_MAX_RETRIES=3
      - LOGIN_TIMEOUT=300
      - DISABLE_CONTINUE=true
    secrets:
      - tinyauth_secret
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.tinyauth-rtr.entrypoints=websecure-internal"
      - "traefik.http.routers.tinyauth-rtr.rule=Host(\`auth.\${DOMAINNAME_1}\`)"
      - "traefik.http.routers.tinyauth-rtr.middlewares=chain-no-auth@file"
      - "traefik.http.routers.tinyauth-rtr.service=tinyauth-svc"
      - "traefik.http.services.tinyauth-svc.loadbalancer.server.port=3000"
EOF

  log_ok "TinyAuth service added"
}

# ══════════════════════════════════════════════════════════════════════════════
# MIDDLEWARE / CHAIN FILE GENERATION
# ══════════════════════════════════════════════════════════════════════════════

#
# traefik_scaffold_chains <hostname> <dockerdir>
#
# Generates all middleware and chain YAML files in the Traefik rules directory.
# Uses state for auth_system and crowdsec_enabled if not passed.
#
traefik_scaffold_chains() {
  local hostname="$1"
  local dockerdir="$2"
  local auth_system="${TRAEFIK_AUTH_SYSTEM:-$(state_get '.traefik.auth_system // "tinyauth"')}"
  local crowdsec_enabled="${TRAEFIK_CROWDSEC_ENABLED:-$(state_get '.traefik.crowdsec_enabled // false')}"

  local dst_dir="${dockerdir}/appdata/traefik3/rules/${hostname}"
  ensure_dir "$dst_dir"

  log_sub "Writing Traefik middleware and chain files..."
  _traefik_write_chains "$dst_dir" "$auth_system" "$crowdsec_enabled"

  # Create log directories and files
  local log_dir="${dockerdir}/logs/${hostname}/traefik"
  ensure_dir "$log_dir"
  touch "${log_dir}/traefik.log" "${log_dir}/access.log"
  log_sub "Created Traefik log files: ${log_dir}"

  log_ok "Traefik chain files scaffolded in: ${dst_dir}"
}

#
# _traefik_write_chains <rules_dir> <auth_system> <crowdsec_enabled>
#
# Writes all middleware and chain YAML files.
# auth_system: tinyauth | basic | none
# crowdsec_enabled: true | false
#
_traefik_write_chains() {
  local rules_dir="$1"
  local auth_system="${2:-tinyauth}"
  local crowdsec_enabled="${3:-false}"

  # ── TLS options ──────────────────────────────────────────────────────────────
  cat > "${rules_dir}/tls-opts.yml" <<'EOF'
tls:
  options:
    tls-opts:
      minVersion: VersionTLS12
      cipherSuites:
        - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
        - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
        - TLS_AES_128_GCM_SHA256
        - TLS_AES_256_GCM_SHA384
        - TLS_CHACHA20_POLY1305_SHA256
        - TLS_FALLBACK_SCSV
      curvePreferences:
        - CurveP521
        - CurveP384
      sniStrict: true
EOF

  # ── Secure headers ───────────────────────────────────────────────────────────
  cat > "${rules_dir}/middlewares-secure-headers.yml" <<'EOF'
http:
  middlewares:
    middlewares-secure-headers:
      headers:
        accessControlAllowMethods:
          - GET
          - OPTIONS
          - PUT
        accessControlMaxAge: 100
        hostsProxyHeaders:
          - "X-Forwarded-Host"
        stsSeconds: 63072000
        stsIncludeSubdomains: true
        stsPreload: true
        forceSTSHeader: true
        customFrameOptionsValue: SAMEORIGIN
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: "same-origin"
        permissionsPolicy: "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
        customResponseHeaders:
          X-Robots-Tag: "none,noindex,nofollow,noarchive,nosnippet,notranslate,noimageindex"
          server: ""
        customRequestHeaders:
          X-Forwarded-Proto: https
EOF

  # ── Rate limit ───────────────────────────────────────────────────────────────
  cat > "${rules_dir}/middlewares-rate-limit.yml" <<'EOF'
http:
  middlewares:
    middlewares-rate-limit:
      rateLimit:
        average: 100
        burst: 50
EOF

  # ── Buffering ────────────────────────────────────────────────────────────────
  cat > "${rules_dir}/middlewares-buffering.yml" <<'EOF'
http:
  middlewares:
    middlewares-buffering:
      buffering:
        maxResponseBodyBytes: 2000000
        maxRequestBodyBytes: 10485760
        memRequestBodyBytes: 2097152
        memResponseBodyBytes: 2097152
        retryExpression: "IsNetworkError() && Attempts() <= 2"
EOF

  # ── Basic auth ───────────────────────────────────────────────────────────────
  cat > "${rules_dir}/middlewares-basic-auth.yml" <<'EOF'
http:
  middlewares:
    middlewares-basic-auth:
      basicAuth:
        usersFile: "/run/secrets/basic_auth_credentials"
        realm: "Homelab"
EOF

  # ── TinyAuth forwardAuth ─────────────────────────────────────────────────────
  cat > "${rules_dir}/middlewares-tinyauth.yml" <<'EOF'
http:
  middlewares:
    middlewares-tinyauth:
      forwardAuth:
        address: "http://tinyauth:3000/api/auth/traefik"
        trustForwardHeader: true
        authResponseHeaders:
          - "Remote-User"
          - "Remote-Groups"
          - "Remote-Email"
          - "Remote-Name"
EOF

  # ── CrowdSec bouncer (written only if enabled) ───────────────────────────────
  if [[ "$crowdsec_enabled" == "true" ]]; then
    cat > "${rules_dir}/middlewares-crowdsec-bouncer.yml" <<'EOF'
http:
  middlewares:
    middlewares-crowdsec-bouncer:
      forwardAuth:
        address: "http://traefik-bouncer:8080/api/v1/forwardAuth"
        trustForwardHeader: true
EOF
  fi

  # ── Build chain middleware lists based on options ────────────────────────────
  # Chains always include: [crowdsec-bouncer? →] rate-limit → secure-headers → [auth?]
  local bouncer_entry=""
  [[ "$crowdsec_enabled" == "true" ]] && bouncer_entry="          - middlewares-crowdsec-bouncer"

  # chain-no-auth
  {
    echo "http:"
    echo "  middlewares:"
    echo "    chain-no-auth:"
    echo "      chain:"
    echo "        middlewares:"
    [[ -n "$bouncer_entry" ]] && echo "$bouncer_entry"
    echo "          - middlewares-rate-limit"
    echo "          - middlewares-secure-headers"
  } > "${rules_dir}/chain-no-auth.yml"

  # chain-tinyauth
  {
    echo "http:"
    echo "  middlewares:"
    echo "    chain-tinyauth:"
    echo "      chain:"
    echo "        middlewares:"
    [[ -n "$bouncer_entry" ]] && echo "$bouncer_entry"
    echo "          - middlewares-rate-limit"
    echo "          - middlewares-secure-headers"
    echo "          - middlewares-tinyauth"
  } > "${rules_dir}/chain-tinyauth.yml"

  # chain-basic-auth
  {
    echo "http:"
    echo "  middlewares:"
    echo "    chain-basic-auth:"
    echo "      chain:"
    echo "        middlewares:"
    [[ -n "$bouncer_entry" ]] && echo "$bouncer_entry"
    echo "          - middlewares-rate-limit"
    echo "          - middlewares-secure-headers"
    echo "          - middlewares-basic-auth"
  } > "${rules_dir}/chain-basic-auth.yml"

  # chain-default — points to whichever auth system was selected
  local default_auth_middleware
  case "$auth_system" in
    tinyauth) default_auth_middleware="middlewares-tinyauth" ;;
    basic)    default_auth_middleware="middlewares-basic-auth" ;;
    *)        default_auth_middleware="" ;;
  esac

  {
    echo "# chain-default is an alias for the selected auth system: ${auth_system}"
    echo "# Swap this to chain-tinyauth or chain-basic-auth to change auth for all apps at once."
    echo "http:"
    echo "  middlewares:"
    echo "    chain-default:"
    echo "      chain:"
    echo "        middlewares:"
    [[ -n "$bouncer_entry" ]] && echo "$bouncer_entry"
    echo "          - middlewares-rate-limit"
    echo "          - middlewares-secure-headers"
    [[ -n "$default_auth_middleware" ]] && echo "          - ${default_auth_middleware}"
  } > "${rules_dir}/chain-default.yml"

  log_ok "Middleware files written (auth: ${auth_system}, crowdsec: ${crowdsec_enabled})"

  if [[ "$crowdsec_enabled" == "true" ]]; then
    log_sub "  Chains: no-auth, tinyauth, basic-auth, default → all include CrowdSec bouncer"
  else
    log_sub "  Chains: no-auth, tinyauth, basic-auth, default"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# BASIC AUTH CREDENTIAL SETUP
# ══════════════════════════════════════════════════════════════════════════════

#
# traefik_setup_basic_auth <dockerdir>
#
# Generates hashed basic auth credentials and writes to secrets.
# Requires htpasswd (apache2-utils).
#
traefik_setup_basic_auth() {
  local dockerdir="$1"
  local secrets_dir="${dockerdir}/secrets"

  echo ""
  log_sub "Setting up Basic Auth credentials..."
  echo -e "  ${DIM}These are used to protect Traefik dashboard and apps using chain-basic-auth.${RESET}"
  echo ""

  if ! command -v htpasswd &>/dev/null; then
    log_sub "Installing apache2-utils for htpasswd..."
    sudo apt-get install -y -q apache2-utils >> "${LOG_FILE:-/tmp/portless-install.log}" 2>&1 \
      || die "Could not install apache2-utils. Run: sudo apt-get install apache2-utils"
  fi

  prompt_input "Basic Auth username" "admin"
  local ba_user="$REPLY"

  prompt_secret "Basic Auth password"
  local ba_pass="$REPLY"

  local hashed
  hashed=$(htpasswd -nbB "$ba_user" "$ba_pass") \
    || die "htpasswd failed — check apache2-utils is installed"

  ensure_dir "$secrets_dir"
  printf '%s\n' "$hashed" > "${secrets_dir}/basic_auth_credentials"
  chmod 600 "${secrets_dir}/basic_auth_credentials"
  log_ok "Basic Auth credentials written to ${secrets_dir}/basic_auth_credentials"
}

# ══════════════════════════════════════════════════════════════════════════════
# TINYAUTH INITIAL USER SETUP
# ══════════════════════════════════════════════════════════════════════════════

#
# tinyauth_setup_user <dockerdir>
#
# Creates TinyAuth users_file with first admin user.
# Hashes password with bcrypt via htpasswd.
#
tinyauth_setup_user() {
  local dockerdir="$1"
  local appdata_dir="${dockerdir}/appdata/tinyauth"
  ensure_dir "$appdata_dir"

  echo ""
  log_sub "Setting up TinyAuth admin account..."
  echo -e "  ${DIM}This is the login you'll use at https://auth.yourdomain.com${RESET}"
  echo ""

  if ! command -v htpasswd &>/dev/null; then
    log_sub "Installing apache2-utils for password hashing..."
    sudo apt-get install -y -q apache2-utils >> "${LOG_FILE:-/tmp/portless-install.log}" 2>&1 \
      || die "Could not install apache2-utils. Run: sudo apt-get install apache2-utils"
  fi

  prompt_input "TinyAuth admin email" ""
  local ta_email="$REPLY"
  [[ -n "$ta_email" ]] || die "Email is required"

  prompt_secret "TinyAuth admin password (min 8 chars)"
  local ta_pass="$REPLY"
  [[ ${#ta_pass} -ge 8 ]] || die "Password must be at least 8 characters"

  local hashed_pass
  hashed_pass=$(htpasswd -nbB "" "$ta_pass" | cut -d: -f2) \
    || die "Password hashing failed"

  printf '%s:%s\n' "$ta_email" "$hashed_pass" > "${appdata_dir}/users_file"
  chmod 600 "${appdata_dir}/users_file"
  log_ok "TinyAuth user created: ${ta_email}"
  log_info "Login at: https://auth.$(state_get '.domain')"
}

#
# tinyauth_setup_secret <dockerdir>
#
# Generates TinyAuth session secret and writes to Docker secrets.
#
tinyauth_setup_secret() {
  local dockerdir="$1"
  local secrets_dir="${dockerdir}/secrets"
  ensure_dir "$secrets_dir"

  if [[ ! -f "${secrets_dir}/tinyauth_secret" ]]; then
    openssl rand -hex 32 > "${secrets_dir}/tinyauth_secret"
    chmod 600 "${secrets_dir}/tinyauth_secret"
    log_sub "TinyAuth session secret generated"
  else
    log_sub "TinyAuth secret already exists — keeping"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# STAGING CERTIFICATE VALIDATION
# ══════════════════════════════════════════════════════════════════════════════

#
# traefik_cert_staging_test <compose_file> <env_file> <acme_json>
#
# Temporarily enables the Let's Encrypt staging server to validate the
# Cloudflare DNS challenge works, then switches to production.
# Based on deployrr's proven staging → production pattern.
#
traefik_cert_staging_test() {
  local compose_file="$1"
  local env_file="$2"
  local acme_json="$3"
  local domain
  domain=$(state_get '.domain')

  echo ""
  log_step "Traefik Certificate Validation (Staging)"

  cat <<EOF

  ${BOLD}Why staging first?${RESET}
  Let's Encrypt has strict rate limits. If your DNS or Cloudflare token isn't
  configured correctly, repeated failed attempts will lock you out for hours.
  We'll use a staging certificate first (safe, unlimited retries), confirm it
  works, then switch to a real production certificate.

  ${DIM}This step may take up to 5 minutes while DNS propagates.${RESET}

EOF

  if ! prompt_yn "Run staging certificate test before production?" "Y"; then
    log_warn "Skipping staging test — going straight to production."
    log_warn "If cert fails, empty acme.json and restart Traefik."
    return 0
  fi

  local docker_dir
  docker_dir=$(state_get '.dockerdir')
  local hostname
  hostname=$(state_get '.hostname')

  log_sub "Enabling staging CA in compose file..."
  # Enable the staging CA server line (uncomment it)
  sed -i 's|#.*--certificatesResolvers.dns-cloudflare.acme.caServer=https://acme-staging.*|      - --certificatesResolvers.dns-cloudflare.acme.caServer=https://acme-staging-v02.api.letsencrypt.org/directory|' \
    "$compose_file" 2>/dev/null || true

  # If not present, append staging flag to traefik command
  if ! grep -q "acme-staging" "$compose_file" 2>/dev/null; then
    log_sub "Adding staging CA flag to Traefik command..."
    sed -i '/certificatesResolvers.dns-cloudflare.acme.dnsChallenge.delayBeforeCheck/a\      - --certificatesResolvers.dns-cloudflare.acme.caServer=https://acme-staging-v02.api.letsencrypt.org/directory' \
      "$compose_file" 2>/dev/null || true
  fi

  log_sub "Clearing acme.json for fresh start..."
  > "$acme_json"

  log_sub "Starting Traefik with staging CA..."
  docker compose --env-file "$env_file" -f "$compose_file" up -d traefik \
    >> "${LOG_FILE:-/tmp/portless-install.log}" 2>&1 \
    || { log_error "Traefik failed to start — check ${LOG_FILE:-/tmp/portless-install.log}"; return 1; }

  log_sub "Waiting for staging certificate (up to 5 minutes)..."
  local attempts=0
  local cert_found=false
  while (( attempts < 30 )); do
    sleep 10
    (( attempts++ ))
    local cert_count
    cert_count=$(jq -r '[.. | .certificate? // empty] | length' "$acme_json" 2>/dev/null || echo 0)
    if (( cert_count > 0 )); then
      cert_found=true
      break
    fi
    log_sub "  Still waiting... (${attempts}/30)"
  done

  if [[ "$cert_found" == "true" ]]; then
    log_ok "Staging certificate obtained for ${domain}!"
    echo ""
    echo -e "  ${GREEN}✓${RESET}  DNS challenge working"
    echo -e "  ${GREEN}✓${RESET}  Cloudflare token valid"
    echo -e "  ${GREEN}✓${RESET}  Certificate issued (staging)"
    echo ""
    log_sub "Switching to production certificates..."

    # Remove staging CA line
    sed -i '/acme-staging-v02.api.letsencrypt.org/d' "$compose_file" 2>/dev/null || true

    # Clear staging cert so production one is fetched fresh
    > "$acme_json"

    log_sub "Restarting Traefik with production CA..."
    docker compose --env-file "$env_file" -f "$compose_file" up -d traefik \
      >> "${LOG_FILE:-/tmp/portless-install.log}" 2>&1

    log_ok "Traefik restarted — fetching production certificate now"
    log_info "Production cert may take 2-5 minutes. Check: https://traefik.${domain}"

  else
    log_error "Staging certificate not obtained after 5 minutes."
    log_error "Common causes:"
    log_error "  • Cloudflare token doesn't have Zone:DNS:Edit permission"
    log_error "  • Domain doesn't have a DNS A record yet"
    log_error "  • DNS hasn't propagated (wait 5 min and try again)"
    echo ""
    log_warn "Continuing without cert validation. Check Traefik logs:"
    log_warn "  docker logs traefik"
    log_warn "  cat ${docker_dir}/logs/${hostname}/traefik/traefik.log"
    # Remove staging CA so we don't stay on staging
    sed -i '/acme-staging-v02.api.letsencrypt.org/d' "$compose_file" 2>/dev/null || true
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# POST-INSTALL GUIDANCE
# ══════════════════════════════════════════════════════════════════════════════

#
# traefik_show_auth_guide — post-install guidance for the selected auth system
#
traefik_show_auth_guide() {
  local auth_system="${TRAEFIK_AUTH_SYSTEM:-$(state_get '.traefik.auth_system // "none"')}"
  local domain
  domain=$(state_get '.domain')

  echo ""
  echo -e "${BOLD}${BLUE}══ Authentication Setup Guide ══${RESET}"
  echo ""

  case "$auth_system" in
    tinyauth)
      cat <<EOF
  ${BOLD}TinyAuth is running at:${RESET} https://auth.${domain}

  ${BOLD}First login:${RESET}
  1. Open ${CYAN}https://auth.${domain}${RESET}
  2. Log in with the email and password you set during install

  ${BOLD}Adding more users:${RESET}
  Edit ${CYAN}\${DOCKERDIR}/appdata/tinyauth/users_file${RESET}
  Each line: email:bcrypt_hashed_password
  Generate hash: ${CYAN}htpasswd -nbB "" "yourpassword" | cut -d: -f2${RESET}

  ${BOLD}Enabling 2FA:${RESET}
  Log in to TinyAuth → Settings → Enable TOTP

  ${BOLD}Protecting apps:${RESET}
  Apps using chain-tinyauth@file are automatically protected.
  Apps using chain-no-auth@file are unprotected (e.g. Plex has its own auth).
EOF
      traefik_show_pangolin_auth_guide
      ;;
    basic)
      cat <<EOF
  ${BOLD}Basic Auth is enabled.${RESET}
  Your credentials are in: \${DOCKERDIR}/secrets/basic_auth_credentials

  ${BOLD}Apps protected by chain-basic-auth@file${RESET} will prompt for username/password.

  ${BOLD}To change credentials:${RESET}
  htpasswd -nbB "newuser" "newpassword" > \${DOCKERDIR}/secrets/basic_auth_credentials
  Then restart Traefik: docker compose restart traefik
EOF
      ;;
    none)
      cat <<EOF
  ${YELLOW}[WARN]${RESET}  No authentication layer is configured.
  Apps accessible via their URLs have no login protection.

  ${BOLD}To add TinyAuth later:${RESET}
  ./manage.sh security auth
EOF
      ;;
  esac
  echo ""
}

#
# traefik_show_pangolin_auth_guide — guidance for enabling auth via Pangolin
#
traefik_show_pangolin_auth_guide() {
  local tunnel_method
  tunnel_method=$(state_get '.tunnel.method // "none"')
  [[ "$tunnel_method" != "pangolin" ]] && return 0

  local pangolin_domain
  pangolin_domain=$(state_get '.tunnel.pangolin.domain // ""')

  cat <<EOF

  ${BOLD}Pangolin Resource Authentication (Extra Security Layer):${RESET}
  ${DIM}Since you're using Pangolin, you can add a second login at the tunnel level.
  This protects apps even before Traefik or TinyAuth sees the request.${RESET}

  ${BOLD}Recommended for high-sensitivity apps${RESET} (Portainer, VS Code, Traefik dashboard):
  1. Log into your Pangolin dashboard: ${CYAN}https://${pangolin_domain:-pangolin.yourdomain.com}${RESET}
  2. Go to your site → ${BOLD}Resources${RESET}
  3. Click the app → toggle ${BOLD}Enable Authentication${RESET}
  4. Set the authentication type to ${BOLD}Pangolin SSO${RESET}

  ${BOLD}Result:${RESET} Visitors must log into Pangolin first, THEN pass TinyAuth.
  Two independent authentication gates for maximum protection.

  ${BOLD}Leave Pangolin auth OFF for${RESET}: Plex, Overseerr, Jellyfin (they have built-in auth
  and need public URL sharing to work with mobile apps).

EOF
}

# ══════════════════════════════════════════════════════════════════════════════
# DYNAMIC RULE GENERATION (app routing)
# ══════════════════════════════════════════════════════════════════════════════

#
# traefik_gen_rule <app_name> <subdomain> <auth_type> <host_port>
#   auth_type: tinyauth | basic | none
#
traefik_gen_rule() {
  local app="$1"
  local subdomain="$2"
  local auth_type="${3:-tinyauth}"
  local host_port="$4"

  local domain server_ip hostname dockerdir access_mode
  domain=$(state_get '.domain')
  server_ip=$(state_get '.server_ip')
  hostname=$(state_get '.hostname')
  dockerdir=$(state_get '.dockerdir')
  access_mode=$(state_get '.traefik.access_mode // "hybrid"')

  [[ -n "$domain" ]]    || die "Domain not set in state."
  [[ -n "$server_ip" ]] || die "Server IP not set in state."
  [[ -n "$hostname" ]]  || die "Hostname not set in state."
  [[ -n "$dockerdir" ]] || die "DOCKERDIR not set in state."

  # Determine which entrypoints to use
  local entrypoints
  if [[ "$access_mode" == "hybrid" ]]; then
    entrypoints="websecure-internal,websecure-external"
  else
    entrypoints="websecure-internal"
  fi

  # Determine chain
  local chain
  case "$auth_type" in
    tinyauth) chain="chain-tinyauth" ;;
    basic)    chain="chain-basic-auth" ;;
    none|*)   chain="chain-no-auth" ;;
  esac

  local rules_dir="${dockerdir}/appdata/traefik3/rules/${hostname}"
  ensure_dir "$rules_dir"
  local output="${rules_dir}/app-${app}.yml"

  cat > "$output" <<EOF
# Traefik dynamic config — ${app}
# Generated by portless install — regenerate: ./manage.sh regen
http:
  routers:
    ${app}-rtr:
      entryPoints:
$(for ep in ${entrypoints//,/ }; do echo "        - ${ep}"; done)
      rule: "Host(\`${subdomain}.${domain}\`)"
      middlewares:
        - ${chain}@file
      service: ${app}-svc
      tls:
        certResolver: dns-cloudflare
        options: tls-opts@file

  services:
    ${app}-svc:
      loadBalancer:
        servers:
          - url: "http://${server_ip}:${host_port}"
        passHostHeader: true
EOF

  log_ok "Traefik rule: ${app} → https://${subdomain}.${domain} [${chain}]"
  echo "$output"
}

#
# traefik_remove_rule <app_name>
#
traefik_remove_rule() {
  local app="$1"
  local hostname dockerdir
  hostname=$(state_get '.hostname')
  dockerdir=$(state_get '.dockerdir')

  local rule_file="${dockerdir}/appdata/traefik3/rules/${hostname}/app-${app}.yml"
  if [[ -f "$rule_file" ]]; then
    rm "$rule_file"
    log_ok "Removed Traefik rule: $rule_file"
  else
    log_warn "Traefik rule not found (nothing to remove): $rule_file"
  fi
}

#
# traefik_regen_all — regenerate all app rules from state
#
traefik_regen_all() {
  log_step "Regenerating all Traefik rules"

  local apps
  apps=$(app_list_installed)
  if [[ -z "$apps" ]]; then
    log_warn "No installed apps in state — nothing to regenerate"
    return 0
  fi

  while IFS= read -r app; do
    local subdomain port auth
    subdomain=$(state_get ".apps[\"$app\"].subdomain")
    port=$(state_get ".apps[\"$app\"].port")
    auth=$(state_get ".apps[\"$app\"].auth_type // \"none\"")
    traefik_gen_rule "$app" "$subdomain" "$auth" "$port"
  done <<< "$apps"

  log_ok "All Traefik rules regenerated"
}

# ── Utility ───────────────────────────────────────────────────────────────────

traefik_health_check() {
  local server_ip
  server_ip=$(state_get '.server_ip')
  if curl -sf --max-time 5 "http://${server_ip}/ping" &>/dev/null; then
    log_ok "Traefik is responding"
    return 0
  else
    log_warn "Traefik ping failed — it may still be starting up"
    return 1
  fi
}

traefik_app_url() {
  local subdomain="$1"
  local domain
  domain=$(state_get '.domain')
  echo "https://${subdomain}.${domain}"
}
