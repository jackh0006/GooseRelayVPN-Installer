#!/usr/bin/env bash
set -Eeuo pipefail

# GooseForge - guided GooseRelayVPN server installer and manager.
# Target: Debian/Ubuntu VPS with systemd.

APP_NAME="GooseForge"
PROJECT_URL="https://github.com/Kianmhz/GooseRelayVPN"
DEFAULT_DOWNLOAD_URL="https://github.com/Kianmhz/GooseRelayVPN/releases/download/v1.7.1/GooseRelayVPN-server-v1.7.1-linux-amd64.tar.gz"

STATE_DIR="/etc/gooseforge"
STATE_FILE="${STATE_DIR}/state.conf"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
HAPROXY_CERT_DIR="/etc/haproxy/certs"
GOOSE_UNIT="/etc/systemd/system/goose-relay.service"
GOOSE_BIN="/root/goose-server"
GOOSE_CONFIG="/root/server_config.json"
GOOSE_KEY_FILE="/root/goose_tunnel_key.txt"
MANAGED_BEGIN="# BEGIN GooseForge managed GooseRelayVPN"
MANAGED_END="# END GooseForge managed GooseRelayVPN"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

export DEBIAN_FRONTEND=noninteractive

info() { printf "%s[INFO]%s %s\n" "$CYAN" "$RESET" "$*"; }
ok() { printf "%s[ OK ]%s %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "$YELLOW" "$RESET" "$*"; }
fail() { printf "%s[FAIL]%s %s\n" "$RED" "$RESET" "$*"; }

pause() {
  printf "\n%sPress Enter to continue...%s " "$DIM" "$RESET"
  read -r _ || true
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Run this script with sudo: sudo bash $0"
    exit 1
  fi
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

save_state() {
  sudo mkdir -p "$STATE_DIR"
  sudo chmod 700 "$STATE_DIR"
  sudo tee "$STATE_FILE" >/dev/null <<EOF
GOOSE_DOMAIN="${GOOSE_DOMAIN:-}"
GOOSE_MODE="${GOOSE_MODE:-http}"
GOOSE_PUBLIC_PORT="${GOOSE_PUBLIC_PORT:-8443}"
GOOSE_BACKEND_PORT="${GOOSE_BACKEND_PORT:-8443}"
GOOSE_DOWNLOAD_URL="${GOOSE_DOWNLOAD_URL:-$DEFAULT_DOWNLOAD_URL}"
GOOSE_INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
  sudo chmod 600 "$STATE_FILE"
}

ask_yes_no() {
  local prompt="$1"
  local answer
  while true; do
    read -r -p "$prompt [y/N]: " answer
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no|"") return 1 ;;
      *) warn "Please type yes or no." ;;
    esac
  done
}

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_step() {
  local title="$1"
  shift
  local log
  log="$(mktemp)"
  printf "\n%s==>%s %s\n" "$MAGENTA" "$RESET" "$title"
  if "$@" >"$log" 2>&1; then
    ok "$title"
    if [[ -s "$log" ]]; then
      tail -n 12 "$log" | sed 's/^/  /'
    fi
    rm -f "$log"
    return 0
  fi
  fail "$title"
  tail -n 40 "$log" | sed 's/^/  /'
  rm -f "$log"
  return 1
}

banner() {
  clear || true
  printf "%s" "$CYAN"
  cat <<'EOF'
   ____                         _____
  / ___| ___   ___  ___  ___   |  ___|__  _ __ __ _  ___
 | |  _ / _ \ / _ \/ __|/ _ \  | |_ / _ \| '__/ _` |/ _ \
 | |_| | (_) | (_) \__ \  __/  |  _| (_) | | | (_| |  __/
  \____|\___/ \___/|___/\___|  |_|  \___/|_|  \__, |\___|
                                               |___/
EOF
  printf "%s" "$RESET"
  printf "%s%s%s\n" "$BOLD" "GooseForge - GooseRelayVPN server installer" "$RESET"
  printf "%s%s%s\n\n" "$DIM" "Install, HAProxy, TLS certificates, ports, health checks." "$RESET"
}

install_haproxy_prompt() {
  if ask_yes_no "Install HAProxy now with: sudo apt update && sudo apt install haproxy -y ?"; then
    run_step "Installing HAProxy" bash -c 'sudo apt update && sudo apt install haproxy -y'
  else
    warn "Skipped HAProxy installation. Continuing to the next question."
  fi
}

install_certbot_prompt() {
  if ask_yes_no "Install Certbot now with: sudo apt update && sudo apt install certbot -y ?"; then
    run_step "Installing Certbot" bash -c 'sudo apt update && sudo apt install certbot -y'
  else
    warn "Skipped Certbot installation. Certificate steps will be skipped unless certbot already exists."
  fi
}

install_basic_tools() {
  run_step "Installing required tools" bash -c 'sudo apt update && sudo apt install wget tar openssl ca-certificates curl file sed gawk -y'
}

open_firewall_ports() {
  local ports=("22" "$GOOSE_PUBLIC_PORT")
  if [[ "${GOOSE_MODE:-http}" == "tls" ]]; then
    ports+=("80" "443" "9443" "51820" "1194" "10605")
  fi

  if command_exists ufw; then
    for port in "${ports[@]}"; do
      sudo ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    done
    sudo ufw --force enable >/dev/null 2>&1 || true
    sudo ufw reload >/dev/null 2>&1 || true
    ok "UFW rules checked for TCP ports: ${ports[*]}"
  else
    warn "ufw is not installed. Open TCP ports in your VPS/cloud firewall: ${ports[*]}"
  fi
}

request_certificate() {
  local domain="$1"
  if [[ -z "$domain" ]]; then
    return 0
  fi
  if ! command_exists certbot; then
    warn "certbot is not installed, so no certificate can be requested."
    return 1
  fi
  if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" && -f "/etc/letsencrypt/live/${domain}/privkey.pem" ]]; then
    ok "Existing Let's Encrypt certificate found for ${domain}; reusing it."
    return 0
  fi
  if command_exists systemctl && sudo systemctl is-active --quiet haproxy 2>/dev/null; then
    warn "Stopping HAProxy for standalone certbot, then it will be started again later."
    sudo systemctl stop haproxy || true
  fi
  run_step "Getting Let's Encrypt certificate for ${domain}" \
    sudo certbot certonly --standalone -d "$domain"
}

build_haproxy_pem() {
  local domain="$1"
  local live="/etc/letsencrypt/live/${domain}"
  if [[ ! -f "${live}/fullchain.pem" || ! -f "${live}/privkey.pem" ]]; then
    fail "Certificate files are missing for ${domain}."
    return 1
  fi
  sudo mkdir -p "$HAPROXY_CERT_DIR"
  sudo bash -c "cat '${live}/fullchain.pem' '${live}/privkey.pem' > '${HAPROXY_CERT_DIR}/${domain}.pem'"
  sudo chmod 600 "${HAPROXY_CERT_DIR}/${domain}.pem"
  ok "HAProxy PEM ready: ${HAPROXY_CERT_DIR}/${domain}.pem"
}

write_default_haproxy_base() {
  local domain="$1"
  sudo mkdir -p "$(dirname "$HAPROXY_CFG")"
  sudo tee "$HAPROXY_CFG" >/dev/null <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 4096

defaults
    log global
    mode tcp
    timeout connect 10s
    timeout client  1m
    timeout server  1m

# ================================================================
#  FRONTEND: 443 - Standard HTTPS (10 domains)
# ================================================================
frontend https_in
    bind *:443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }

    use_backend h1  if { req.ssl_sni -i h1.example.com }
    use_backend h2  if { req.ssl_sni -i h2.example.com }
    use_backend h3  if { req.ssl_sni -i h3.example.com }
    use_backend h4  if { req.ssl_sni -i h4.example.com }
    use_backend h5  if { req.ssl_sni -i h5.example.com }
    use_backend h6  if { req.ssl_sni -i h6.example.com }
    use_backend h7  if { req.ssl_sni -i h7.example.com }
    use_backend h8  if { req.ssl_sni -i h8.example.com }
    use_backend h9  if { req.ssl_sni -i h9.example.com }
    use_backend h10 if { req.ssl_sni -i h10.example.com }

    default_backend h1

# ================================================================
#  FRONTEND: 9443 - Relay Port
# ================================================================
frontend relay_in
    bind *:9443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }

    use_backend relay1  if { req.ssl_sni -i relay1.example.com }
    use_backend relay2  if { req.ssl_sni -i relay2.example.com }
    use_backend relay3  if { req.ssl_sni -i relay3.example.com }
    use_backend relay4  if { req.ssl_sni -i relay4.example.com }
    use_backend relay5  if { req.ssl_sni -i relay5.example.com }
    use_backend relay6  if { req.ssl_sni -i relay6.example.com }
    use_backend relay7  if { req.ssl_sni -i relay7.example.com }
    use_backend relay8  if { req.ssl_sni -i relay8.example.com }
    use_backend relay9  if { req.ssl_sni -i relay9.example.com }
    use_backend relay10 if { req.ssl_sni -i relay10.example.com }

    default_backend relay1

# ================================================================
#  FRONTEND: 51820 - WireGuard
# ================================================================
frontend wireguard_in
    bind *:51820
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }

    use_backend wg1  if { req.ssl_sni -i wg1.example.com }
    use_backend wg2  if { req.ssl_sni -i wg2.example.com }
    use_backend wg3  if { req.ssl_sni -i wg3.example.com }
    use_backend wg4  if { req.ssl_sni -i wg4.example.com }
    use_backend wg5  if { req.ssl_sni -i wg5.example.com }
    use_backend wg6  if { req.ssl_sni -i wg6.example.com }
    use_backend wg7  if { req.ssl_sni -i wg7.example.com }
    use_backend wg8  if { req.ssl_sni -i wg8.example.com }
    use_backend wg9  if { req.ssl_sni -i wg9.example.com }
    use_backend wg10 if { req.ssl_sni -i wg10.example.com }

    default_backend wg1

# ================================================================
#  FRONTEND: 1194 - OpenVPN
# ================================================================
frontend openvpn_in
    bind *:1194
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }

    use_backend ovpn1  if { req.ssl_sni -i ovpn1.example.com }
    use_backend ovpn2  if { req.ssl_sni -i ovpn2.example.com }
    use_backend ovpn3  if { req.ssl_sni -i ovpn3.example.com }
    use_backend ovpn4  if { req.ssl_sni -i ovpn4.example.com }
    use_backend ovpn5  if { req.ssl_sni -i ovpn5.example.com }
    use_backend ovpn6  if { req.ssl_sni -i ovpn6.example.com }
    use_backend ovpn7  if { req.ssl_sni -i ovpn7.example.com }
    use_backend ovpn8  if { req.ssl_sni -i ovpn8.example.com }
    use_backend ovpn9  if { req.ssl_sni -i ovpn9.example.com }
    use_backend ovpn10 if { req.ssl_sni -i ovpn10.example.com }

    default_backend ovpn1

# ================================================================
#  FRONTEND: 10605 - Custom Port
# ================================================================
frontend custom_in
    bind *:10605
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }

    use_backend c1  if { req.ssl_sni -i c1.example.com }
    use_backend c2  if { req.ssl_sni -i c2.example.com }
    use_backend c3  if { req.ssl_sni -i c3.example.com }
    use_backend c4  if { req.ssl_sni -i c4.example.com }
    use_backend c5  if { req.ssl_sni -i c5.example.com }
    use_backend c6  if { req.ssl_sni -i c6.example.com }
    use_backend c7  if { req.ssl_sni -i c7.example.com }
    use_backend c8  if { req.ssl_sni -i c8.example.com }
    use_backend c9  if { req.ssl_sni -i c9.example.com }
    use_backend c10 if { req.ssl_sni -i c10.example.com }

    default_backend c1

backend h1
    server s1  127.0.0.1:10000
backend h2
    server s2  127.0.0.1:10001
backend h3
    server s3  127.0.0.1:10002
backend h4
    server s4  127.0.0.1:10003
backend h5
    server s5  127.0.0.1:10004
backend h6
    server s6  127.0.0.1:10005
backend h7
    server s7  127.0.0.1:10006
backend h8
    server s8  127.0.0.1:10007
backend h9
    server s9  127.0.0.1:10008
backend h10
    server s10 127.0.0.1:10009

backend d1
    server s11 127.0.0.1:10010
backend d2
    server s12 127.0.0.1:10011
backend d3
    server s13 127.0.0.1:10012
backend d4
    server s14 127.0.0.1:10013
backend d5
    server s15 127.0.0.1:10014
backend d6
    server s16 127.0.0.1:10015
backend d7
    server s17 127.0.0.1:10016
backend d8
    server s18 127.0.0.1:10017
backend d9
    server s19 127.0.0.1:10018
backend d10
    server s20 127.0.0.1:10019

backend relay1
    server s21 127.0.0.1:10020
backend relay2
    server s22 127.0.0.1:10021
backend relay3
    server s23 127.0.0.1:10022
backend relay4
    server s24 127.0.0.1:10023
backend relay5
    server s25 127.0.0.1:10024
backend relay6
    server s26 127.0.0.1:10025
backend relay7
    server s27 127.0.0.1:10026
backend relay8
    server s28 127.0.0.1:10027
backend relay9
    server s29 127.0.0.1:10028
backend relay10
    server s30 127.0.0.1:10029

backend wg1
    server s31 127.0.0.1:10030
backend wg2
    server s32 127.0.0.1:10031
backend wg3
    server s33 127.0.0.1:10032
backend wg4
    server s34 127.0.0.1:10033
backend wg5
    server s35 127.0.0.1:10034
backend wg6
    server s36 127.0.0.1:10035
backend wg7
    server s37 127.0.0.1:10036
backend wg8
    server s38 127.0.0.1:10037
backend wg9
    server s39 127.0.0.1:10038
backend wg10
    server s40 127.0.0.1:10039

backend ovpn1
    server s41 127.0.0.1:10040
backend ovpn2
    server s42 127.0.0.1:10041
backend ovpn3
    server s43 127.0.0.1:10042
backend ovpn4
    server s44 127.0.0.1:10043
backend ovpn5
    server s45 127.0.0.1:10044
backend ovpn6
    server s46 127.0.0.1:10045
backend ovpn7
    server s47 127.0.0.1:10046
backend ovpn8
    server s48 127.0.0.1:10047
backend ovpn9
    server s49 127.0.0.1:10048
backend ovpn10
    server s50 127.0.0.1:10049

backend c1
    server s51 127.0.0.1:10050
backend c2
    server s52 127.0.0.1:10051
backend c3
    server s53 127.0.0.1:10052
backend c4
    server s54 127.0.0.1:10053
backend c5
    server s55 127.0.0.1:10054
backend c6
    server s56 127.0.0.1:10055
backend c7
    server s57 127.0.0.1:10056
backend c8
    server s58 127.0.0.1:10057
backend c9
    server s59 127.0.0.1:10058
backend c10
    server s60 127.0.0.1:10059
EOF
  append_or_replace_goose_haproxy_block "$domain" "8443" "9444"
}

managed_haproxy_block() {
  local domain="$1"
  local public_port="$2"
  local backend_port="$3"
  cat <<EOF
$MANAGED_BEGIN

# GooseRelayVPN with TLS terminated by HAProxy.
# Public URL: https://${domain}:${public_port}/tunnel
frontend goose_tls_in
    bind *:${public_port} ssl crt ${HAPROXY_CERT_DIR}/${domain}.pem
    mode http
    default_backend goose_back

backend goose_back
    mode http
    server goose 127.0.0.1:${backend_port}

$MANAGED_END
EOF
}

append_or_replace_goose_haproxy_block() {
  local domain="$1"
  local public_port="${2:-8443}"
  local backend_port="${3:-9444}"
  local block tmp clean
  block="$(managed_haproxy_block "$domain" "$public_port" "$backend_port")"
  tmp="$(mktemp)"
  clean="$(mktemp)"

  if [[ -f "$HAPROXY_CFG" ]]; then
    sudo cp -f "$HAPROXY_CFG" "${HAPROXY_CFG}.bak.$(date +%Y%m%d-%H%M%S)"
    if grep -qF "$MANAGED_BEGIN" "$HAPROXY_CFG"; then
      awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" -v block="$block" '
        $0 == begin { print block; skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
      ' "$HAPROXY_CFG" > "$tmp"
    else
      remove_legacy_goose_haproxy_block "$HAPROXY_CFG" > "$clean"
      cat "$clean" > "$tmp"
      printf "\n%s\n" "$block" >> "$tmp"
    fi
    sudo cp "$tmp" "$HAPROXY_CFG"
    rm -f "$tmp" "$clean"
  else
    write_default_haproxy_base "$domain"
  fi
}

remove_legacy_goose_haproxy_block() {
  local file="$1"
  awk '
    $1 == "frontend" && $2 == "goose_tls_in" { skip=1; next }
    $1 == "backend" && $2 == "goose_back" { skip=1; next }
    skip && ($1 == "frontend" || $1 == "backend") { skip=0 }
    !skip { print }
  ' "$file"
}

validate_and_reload_haproxy() {
  if ! command_exists haproxy; then
    warn "HAProxy is not installed. Skipping HAProxy validation."
    return 0
  fi
  run_step "Validating HAProxy config" sudo haproxy -c -f "$HAPROXY_CFG"
  run_step "Restarting HAProxy" sudo systemctl restart haproxy
  sudo systemctl enable haproxy >/dev/null 2>&1 || true
}

configure_haproxy_for_domain() {
  local domain="$1"
  if [[ -z "$domain" ]]; then
    warn "No domain was provided. GooseRelayVPN will run in HTTP mode without HAProxy TLS."
    return 0
  fi
  if [[ -f "$HAPROXY_CFG" ]]; then
    append_or_replace_goose_haproxy_block "$domain" "8443" "9444"
  else
    write_default_haproxy_base "$domain"
  fi
  validate_and_reload_haproxy
}

download_and_install_goose() {
  local url="$1"
  local workdir tarball topdir extracted server_bin config_example key
  workdir="$(mktemp -d)"
  tarball="${workdir}/$(basename "$url")"

  run_step "Downloading GooseRelayVPN server with wget" sudo wget -O "$tarball" "$url"
  run_step "Testing archive integrity" tar -tzf "$tarball"

  tar -tzf "$tarball" > "${workdir}/archive.list"
  sudo tar -xzf "$tarball" -C "$workdir"
  topdir="$(awk -F/ 'NF {print $1; exit}' "${workdir}/archive.list")"
  extracted="${workdir}/${topdir}"
  [[ -d "$extracted" ]] || extracted="$workdir"

  server_bin="$(find "$extracted" -maxdepth 2 -type f -name 'goose-server' | head -n 1)"
  if [[ -z "$server_bin" ]]; then
    fail "Could not find goose-server inside the archive."
    find "$extracted" -maxdepth 2 -type f | sed 's/^/  /'
    return 1
  fi

  config_example="$(find "$extracted" -maxdepth 2 -type f -name 'server_config.example.json' | head -n 1)"
  if [[ -z "$config_example" ]]; then
    fail "Could not find server_config.example.json inside the archive."
    return 1
  fi

  sudo cp "$server_bin" "$GOOSE_BIN"
  sudo chmod 755 "$GOOSE_BIN"
  sudo cp "$config_example" "$GOOSE_CONFIG"

  key="$(openssl rand -hex 32)"
  printf "%s\n" "$key" | sudo tee "$GOOSE_KEY_FILE" >/dev/null
  sudo chmod 600 "$GOOSE_KEY_FILE"

  sudo sed -i -E "s|(\"tunnel_key\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")|\1${key}\2|" "$GOOSE_CONFIG"
  if grep -q '"server_host"' "$GOOSE_CONFIG"; then
    sudo sed -i -E "s|(\"server_host\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")|\1${GOOSE_SERVER_HOST}\2|" "$GOOSE_CONFIG"
  fi
  if grep -q '"server_port"' "$GOOSE_CONFIG"; then
    sudo sed -i -E "s|(\"server_port\"[[:space:]]*:[[:space:]]*)[0-9]+|\1${GOOSE_BACKEND_PORT}|" "$GOOSE_CONFIG"
  fi

  ok "Installed $GOOSE_BIN"
  ok "Created $GOOSE_CONFIG"
  ok "Tunnel key saved at $GOOSE_KEY_FILE"
  rm -rf "$workdir"
}

write_goose_service() {
  sudo tee "$GOOSE_UNIT" >/dev/null <<'EOF'
[Unit]
Description=GooseRelayVPN exit server
After=network.target

[Service]
Type=simple
WorkingDirectory=/root
ExecStart=/root/goose-server -config /root/server_config.json
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  ok "Wrote $GOOSE_UNIT"
}

start_goose_service() {
  run_step "systemctl daemon-reload" sudo systemctl daemon-reload
  run_step "systemctl enable goose-relay" sudo systemctl enable goose-relay
  run_step "systemctl start goose-relay" sudo systemctl restart goose-relay
  printf "\n%sLive service status:%s\n" "$BOLD" "$RESET"
  sudo systemctl status goose-relay --no-pager || true
}

health_check() {
  load_state
  local url code
  printf "\n%sHealth check - simple results%s\n" "$BOLD" "$RESET"

  if sudo systemctl is-active --quiet goose-relay; then
    ok "goose-relay service is active."
  else
    fail "goose-relay service is not active. Read: sudo journalctl -u goose-relay --no-pager -n 80"
  fi

  if [[ "${GOOSE_MODE:-http}" == "tls" ]]; then
    url="https://${GOOSE_DOMAIN}:${GOOSE_PUBLIC_PORT}/healthz"
    if sudo systemctl is-active --quiet haproxy; then
      ok "haproxy service is active."
    else
      fail "haproxy service is not active. Read: sudo journalctl -u haproxy --no-pager -n 80"
    fi
  else
    url="http://127.0.0.1:${GOOSE_PUBLIC_PORT}/healthz"
  fi

  if command_exists curl; then
    code="$(curl -k -m 8 -s -o /tmp/gooseforge-health.out -w '%{http_code}' "$url" || true)"
    if [[ "$code" =~ ^[234][0-9][0-9]$ ]]; then
      ok "HTTP test reached GooseRelayVPN: ${url} returned HTTP ${code}."
      sed 's/^/  /' /tmp/gooseforge-health.out 2>/dev/null || true
    else
      warn "HTTP test did not get a response from ${url}. This can mean firewall, DNS, service, or port issue."
    fi
    rm -f /tmp/gooseforge-health.out
  else
    warn "curl is missing, so HTTP health test was skipped."
  fi
}

install_flow() {
  load_state
  local domain download_url
  GOOSE_DOMAIN=""
  GOOSE_MODE="http"
  GOOSE_PUBLIC_PORT="8443"
  GOOSE_BACKEND_PORT="8443"
  GOOSE_SERVER_HOST="0.0.0.0"

  printf "\n%sInstall mode%s\n" "$BOLD" "$RESET"
  info "First I ask before each major package install. If you say no, I skip it and continue."
  install_haproxy_prompt || true
  install_certbot_prompt || true
  install_basic_tools

  read -r -p "Subdomain for TLS certificate, or press Enter to use VPS IPv4 HTTP mode: " domain
  if [[ -n "$domain" ]]; then
    if ! valid_domain "$domain"; then
      fail "That domain name is not valid."
      return 1
    fi
    GOOSE_DOMAIN="$domain"
    GOOSE_MODE="tls"
    GOOSE_PUBLIC_PORT="8443"
    GOOSE_BACKEND_PORT="9444"
    GOOSE_SERVER_HOST="127.0.0.1"
    request_certificate "$domain"
    build_haproxy_pem "$domain"
    configure_haproxy_for_domain "$domain"
  else
    warn "No domain given. Using HTTP mode: http://YOUR_VPS_IPV4:8443/tunnel"
  fi

  read -r -p "Download link [${DEFAULT_DOWNLOAD_URL}]: " download_url
  GOOSE_DOWNLOAD_URL="${download_url:-$DEFAULT_DOWNLOAD_URL}"

  open_firewall_ports
  download_and_install_goose "$GOOSE_DOWNLOAD_URL"
  write_goose_service
  start_goose_service
  save_state
  health_check

  printf "\n%sServer installation is done.%s\n" "$GREEN" "$RESET"
  printf "Client guide: %s\n" "$PROJECT_URL"
  if [[ "$GOOSE_MODE" == "tls" ]]; then
    printf "Relay URL for Apps Script: https://%s:%s/tunnel\n" "$GOOSE_DOMAIN" "$GOOSE_PUBLIC_PORT"
  else
    printf "Relay URL for Apps Script: http://YOUR_VPS_IPV4:%s/tunnel\n" "$GOOSE_PUBLIC_PORT"
  fi
  printf "Tunnel key: sudo cat %s\n" "$GOOSE_KEY_FILE"
}

uninstall_flow() {
  printf "\n%sUninstall%s\n" "$BOLD" "$RESET"
  if ! ask_yes_no "Remove GooseRelayVPN service, binary, config, state, and GooseForge HAProxy block?"; then
    warn "Uninstall cancelled."
    return 0
  fi

  sudo systemctl disable --now goose-relay >/dev/null 2>&1 || true
  sudo rm -f "$GOOSE_UNIT"
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  sudo rm -f "$GOOSE_BIN" "$GOOSE_CONFIG" "$GOOSE_KEY_FILE"
  sudo rm -rf /root/GooseRelayVPN-server-* /root/goose-relay /root/goose_safe_upgrade.sh
  sudo rm -rf "$STATE_DIR"

  if [[ -f "$HAPROXY_CFG" ]] && { grep -qF "$MANAGED_BEGIN" "$HAPROXY_CFG" || grep -qE '^[[:space:]]*frontend[[:space:]]+goose_tls_in[[:space:]]*$' "$HAPROXY_CFG"; }; then
    local tmp
    tmp="$(mktemp)"
    sudo cp -f "$HAPROXY_CFG" "${HAPROXY_CFG}.bak.$(date +%Y%m%d-%H%M%S)"
    awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '
      $1 == "frontend" && $2 == "goose_tls_in" { skip=1; next }
      $1 == "backend" && $2 == "goose_back" { skip=1; next }
      $0 == begin { skip=1; next }
      $0 == end { skip=0; next }
      skip && ($1 == "frontend" || $1 == "backend") { skip=0 }
      !skip { print }
    ' "$HAPROXY_CFG" > "$tmp"
    sudo cp "$tmp" "$HAPROXY_CFG"
    rm -f "$tmp"
    if command_exists haproxy; then
      sudo haproxy -c -f "$HAPROXY_CFG" && sudo systemctl restart haproxy || true
    fi
  fi

  ok "GooseRelayVPN files and GooseForge state removed."
  if ask_yes_no "Also purge haproxy and certbot packages?"; then
    run_step "Purging packages" bash -c 'sudo apt purge haproxy certbot -y && sudo apt autoremove -y'
  fi
}

haproxy_custom_menu() {
  if ! command_exists haproxy && [[ ! -f "$HAPROXY_CFG" ]]; then
    warn "HAProxy is not installed or configured."
    if ask_yes_no "Install HAProxy first?"; then
      run_step "Installing HAProxy" bash -c 'sudo apt update && sudo apt install haproxy -y'
    else
      return 0
    fi
  fi
  sudo cp -f "$HAPROXY_CFG" "${HAPROXY_CFG}.manual.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  "${EDITOR:-nano}" "$HAPROXY_CFG"
  validate_and_reload_haproxy
}

cert_management_menu() {
  local choice domain
  while true; do
    banner
    printf "1) Get certificate for domain\n"
    printf "2) Show certificate status\n"
    printf "3) Show HAProxy certificate path\n"
    printf "4) Renew certificates\n"
    printf "0) Back\n"
    read -r -p "Choice: " choice
    case "$choice" in
      1)
        read -r -p "Domain: " domain
        valid_domain "$domain" || { fail "Invalid domain."; pause; continue; }
        command_exists certbot || run_step "Installing Certbot" bash -c 'sudo apt update && sudo apt install certbot -y'
        request_certificate "$domain"
        build_haproxy_pem "$domain"
        pause
        ;;
      2)
        sudo certbot certificates || true
        pause
        ;;
      3)
        printf "HAProxy PEM folder: %s\n" "$HAPROXY_CERT_DIR"
        sudo ls -la "$HAPROXY_CERT_DIR" 2>/dev/null || true
        pause
        ;;
      4)
        run_step "Renewing certificates" sudo certbot renew
        sudo systemctl reload haproxy >/dev/null 2>&1 || true
        pause
        ;;
      0) return 0 ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}

port_management_menu() {
  local domain public_port backend_port use_tls cert_path tmp frontend backend
  if ! command_exists haproxy; then
    warn "HAProxy is required for port/domain routing."
    if ask_yes_no "Install HAProxy first?"; then
      run_step "Installing HAProxy" bash -c 'sudo apt update && sudo apt install haproxy -y'
    else
      return 0
    fi
  fi

  read -r -p "Domain for this route: " domain
  valid_domain "$domain" || { fail "Invalid domain."; return 1; }
  read -r -p "Public port to listen on: " public_port
  valid_port "$public_port" || { fail "Invalid public port."; return 1; }
  read -r -p "Backend local port, for example 9444 or 10020: " backend_port
  valid_port "$backend_port" || { fail "Invalid backend port."; return 1; }

  use_tls="no"
  if [[ -f "${HAPROXY_CERT_DIR}/${domain}.pem" ]]; then
    use_tls="yes"
  elif ask_yes_no "No HAProxy PEM found for ${domain}. Get a cert now?"; then
    command_exists certbot || run_step "Installing Certbot" bash -c 'sudo apt update && sudo apt install certbot -y'
    request_certificate "$domain"
    build_haproxy_pem "$domain"
    use_tls="yes"
  fi

  frontend="gf_${public_port}_${domain//./_}_in"
  backend="gf_${public_port}_${domain//./_}_back"
  cert_path="${HAPROXY_CERT_DIR}/${domain}.pem"
  tmp="$(mktemp)"
  sudo cp -f "$HAPROXY_CFG" "${HAPROXY_CFG}.ports.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  cat "$HAPROXY_CFG" > "$tmp"
  {
    printf "\n# GooseForge custom route for %s on %s\n" "$domain" "$public_port"
    printf "frontend %s\n" "$frontend"
    if [[ "$use_tls" == "yes" ]]; then
      printf "    bind *:%s ssl crt %s\n" "$public_port" "$cert_path"
      printf "    mode http\n"
      printf "    default_backend %s\n\n" "$backend"
      printf "backend %s\n" "$backend"
      printf "    mode http\n"
      printf "    server target 127.0.0.1:%s\n" "$backend_port"
    else
      printf "    bind *:%s\n" "$public_port"
      printf "    mode tcp\n"
      printf "    default_backend %s\n\n" "$backend"
      printf "backend %s\n" "$backend"
      printf "    mode tcp\n"
      printf "    server target 127.0.0.1:%s\n" "$backend_port"
    fi
  } >> "$tmp"
  sudo cp "$tmp" "$HAPROXY_CFG"
  rm -f "$tmp"
  validate_and_reload_haproxy
  sudo ufw allow "${public_port}/tcp" >/dev/null 2>&1 || true
  ok "Added route: ${domain}:${public_port} -> 127.0.0.1:${backend_port}"
}

status_menu() {
  banner
  load_state
  printf "Project: %s\n" "$PROJECT_URL"
  printf "Mode: %s\n" "${GOOSE_MODE:-unknown}"
  printf "Domain: %s\n" "${GOOSE_DOMAIN:-none}"
  printf "Public port: %s\n" "${GOOSE_PUBLIC_PORT:-unknown}"
  printf "Config: %s\n" "$GOOSE_CONFIG"
  printf "Tunnel key file: %s\n\n" "$GOOSE_KEY_FILE"
  health_check
  printf "\nRecent goose-relay logs:\n"
  sudo journalctl -u goose-relay --no-pager -n 30 || true
  pause
}

main_menu() {
  local choice
  while true; do
    banner
    printf "1) Install\n"
    printf "2) Uninstall\n"
    printf "3) Change HAProxy config custom\n"
    printf "4) Cert management\n"
    printf "5) Port management\n"
    printf "6) Status and live test\n"
    printf "0) Exit\n\n"
    read -r -p "Choice: " choice
    case "$choice" in
      1) install_flow; pause ;;
      2) uninstall_flow; pause ;;
      3) haproxy_custom_menu; pause ;;
      4) cert_management_menu ;;
      5) port_management_menu; pause ;;
      6) status_menu ;;
      0) ok "Exit."; exit 0 ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}

trap 'fail "Stopped at line ${LINENO}. Read the message above, fix it, then run the script again."' ERR

need_root
main_menu
