#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# =====================================================================
#  GooseForge QuickInstall — One-line full deployment
#  curl -fsSL https://raw.githubusercontent.com/jackh0006/GooseRelayVPN-Installer/main/quickinstall.sh | bash
#  Author: jackh0006 <jackh109867@gmail.com>
#  Version: 2.2.0
# =====================================================================

set -Eeuo pipefail

# ---- QuickInstall Configuration ----
VERSION="2.2.0"
APP="GooseForge QuickInstall"
AUTHOR="jackh0006 <jackh109867@gmail.com>"
PROJECT_URL="https://github.com/Kianmhz/GooseRelayVPN"
RELAY_RELEASE="v1.7.1"
RELAY_BASE="https://github.com/Kianmhz/GooseRelayVPN/releases/download/${RELAY_RELEASE}"
SERVER_URL="${GOOSE_SERVER_URL:-${RELAY_BASE}/GooseRelayVPN-server-${RELAY_RELEASE}-linux-amd64.tar.gz}"
CLIENT_LINUX_URL="${GOOSE_CLIENT_LINUX_URL:-${RELAY_BASE}/GooseRelayVPN-client-${RELAY_RELEASE}-linux-amd64.tar.gz}"
CLIENT_ANDROID_URL="${GOOSE_ANDROID_URL:-${RELAY_BASE}/GooseRelayVPN-client-${RELAY_RELEASE}-android-arm64.tar.gz}"

# Server paths (VPS, needs root)
STATE_DIR="/etc/gooseforge"
STATE_FILE="${STATE_DIR}/state.conf"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
HAPROXY_CERT_DIR="/etc/haproxy/certs"
GOOSE_UNIT="/etc/systemd/system/goose-relay.service"
GOOSE_BIN="/root/goose-server"
GOOSE_CONFIG="/root/server_config.json"
GOOSE_KEY_FILE="/root/goose_tunnel_key.txt"

# Client paths (no root needed)
CLIENT_HOME="${HOME}/goose"
ANDROID_HOME="${HOME}/goose-android"
GOOGLE_EDGES=(216.239.32.120 216.239.34.120 216.239.36.120 216.239.38.120)
DEFAULT_EDGE="216.239.38.120"

# Colors
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
BLUE=$'\033[34m'; MAGENTA=$'\033[35m'; CYAN=$'\033[36m'
BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
CHECK="✅"; CROSS="❌"; SPINNER="⏳"; LOCK="🔐"; GLOBE="🌐"; BUNDLE="📦"

export DEBIAN_FRONTEND=noninteractive

# QuickInstall flags
DRY_RUN=0
ASSUME_YES=0
SKIP_EDGE_TEST=0
VERBOSE=0
TUTORIAL=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --assume-yes|-y) ASSUME_YES=1; shift ;;
        --skip-edge-test) SKIP_EDGE_TEST=1; shift ;;
        --verbose|-v) VERBOSE=1; shift ;;
        --tutorial) TUTORIAL=1; shift ;;
        --help|-h)
            cat <<'HELP_EOF'
GooseForge QuickInstall v2.2.0 — One-line full VPN deployment

Usage: curl -fsSL https://raw.githubusercontent.com/jackh0006/GooseRelayVPN-Installer/main/quickinstall.sh | bash [options]

Options:
  --dry-run           Show what would be done without executing
  --assume-yes, -y    Non-interactive mode (use all defaults)
  --skip-edge-test    Skip Google edge speed test (use default edge)
  --verbose, -v       Verbose output
  --tutorial          Interactive tutorial mode (step-by-step with explanations)
  --help, -h          Show this help

Examples:
  # Interactive (recommended for first time)
  curl -fsSL ... | bash

  # Fully automatic (CI/CD, servers)
  curl -fsSL ... | bash -s -- --assume-yes

  # Quick test without edge probe
  curl -fsSL ... | bash -s -- --skip-edge-test

  # Learn how it works
  curl -fsSL ... | bash -s -- --tutorial
HELP_EOF
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---- Helper Functions ----
info() { printf "%s[INFO]%s %s\n" "$CYAN" "$RESET" "$*"; }
ok()   { printf "%s %s[OK]%s %s\n" "$CHECK" "$GREEN" "$RESET" "$*"; }
warn() { printf "%s %s[WARN]%s %s\n" "⚠️" "$YELLOW" "$RESET" "$*"; }
fail() { printf "%s %s[FAIL]%s %s\n" "$CROSS" "$RED" "$RESET" "$*"; exit 1; }
step() { printf "\n%s%s==>%s %s\n" "$MAGENTA" "$BOLD" "$RESET" "$*"; }
substep() { printf "  %s %s\n" "$SPINNER" "$*"; }
done_msg() { printf "  %s %s\n" "$CHECK" "$*"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }
require_root() { [[ $EUID -eq 0 ]] || fail "This part needs root (run with sudo)."; }

fetch() {
    local url="$1" out="$2"
    if command_exists curl; then curl -fsSL --retry 2 -o "$out" "$url"
    elif command_exists wget; then wget -qO "$out" "$url"
    else fail "Need curl or wget"; fi
}

valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
valid_tunnel_key() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
valid_appscript_id() { [[ "$1" =~ ^AKfycb[A-Za-z0-9_-]{50,}$ ]]; }
valid_relay_url() { [[ "$1" =~ ^https?://[A-Za-z0-9._~%-]+(:[0-9]{1,5})?/tunnel/?$ ]]; }

run_step() {
    local title="$1"; shift
    local log; log="$(mktemp)"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] Would run: $title"
        return 0
    fi
    if "$@" >"$log" 2>&1; then
        done_msg "$title"
        [[ $VERBOSE -eq 1 && -s "$log" ]] && tail -n 5 "$log" | sed 's/^/    /'
        rm -f "$log"
        return 0
    fi
    fail "$title (see $log)"
}

# ---- Tutorial Mode ----
tutorial_step() {
    [[ $TUTORIAL -eq 1 ]] || return 0
    printf "\n%s%s📚 Tutorial:%s %s\n" "$BOLD" "$BLUE" "$RESET" "$*"
    printf "Press Enter to continue..."
    read -r _
}

# ---- Edge Probe ----
probe_edges() {
    [[ $SKIP_EDGE_TEST -eq 1 ]] && { EDGE_PICKED="$DEFAULT_EDGE"; ok "Using default edge: $EDGE_PICKED"; return 0; }
    if ! command_exists curl; then EDGE_PICKED="$DEFAULT_EDGE"; return 0; fi
    step "Testing Google edge IPs for fastest connection..."
    local ip out code ms best="" best_ms=999999
    for ip in "${GOOGLE_EDGES[@]}"; do
        out="$(curl -sS -o /dev/null --max-time 6 --connect-timeout 3 --resolve "www.google.com:443:${ip}" -w '%{http_code} %{time_total}' https://www.google.com/generate_204 2>/dev/null || true)"
        code="${out%% *}"
        if [[ "$code" == "204" ]]; then
            ms="$(awk -v t="${out#* }" 'BEGIN{printf "%d", t*1000}')"
            substep "$ip → HTTP $code (${ms}ms)"
            if [[ "$ms" -lt "$best_ms" ]]; then best_ms="$ms"; best="$ip"; fi
        else
            substep "$ip → HTTP ${code:-err} (blocked)"
        fi
    done
    if [[ -n "$best" ]]; then EDGE_PICKED="$best"; ok "Best edge: $EDGE_PICKED (${best_ms}ms)"
    else EDGE_PICKED="$DEFAULT_EDGE"; warn "No edge responded, using default: $EDGE_PICKED"; fi
}

# ---- Key Generation (with entropy check) ----
generate_tunnel_key() {
    local entropy
    entropy="$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo 3000)"
    if [[ $entropy -lt 1000 ]]; then
        warn "Low entropy ($entropy) — consider installing haveged or rng-tools"
    fi
    openssl rand -hex 32
}

# ---- JSON Schema Validation (draft-07 style) ----
validate_client_config() {
    local file="$1"
    python3 - "$file" <<'PYEOF'
import json, sys, re
with open(sys.argv[1]) as f:
    c = json.load(f)
# Required fields
assert c.get("socks_port") == 1080, "socks_port must be 1080"
assert isinstance(c.get("script_keys"), list) and len(c["script_keys"]) >= 1, "need ≥1 deployment"
assert len(c.get("tunnel_key", "")) == 64, "tunnel_key must be 64 hex chars"
assert re.fullmatch(r"[0-9a-f]{64}", c["tunnel_key"]), "tunnel_key must be hex"
for k in c["script_keys"]:
    assert isinstance(k.get("id"), str) and len(k["id"]) >= 60, f"deployment ID too short: {k.get('id')}"
    assert k["id"].startswith("AKfycb"), f"deployment ID must start with AKfycb: {k['id']}"
    assert isinstance(k.get("account"), str) and len(k["account"]) > 0, "account label required"
assert c.get("coalesce_step_ms", 25) == 25, "coalesce_step_ms should be 25"
assert c.get("idle_slots_per_bucket", 2) == 2, "idle_slots_per_bucket should be 2"
assert c.get("sni") == ["www.google.com", "mail.google.com", "accounts.google.com"], "SNIs mismatch"
print("VALID")
PYEOF
}

validate_server_config() {
    local file="$1"
    python3 - "$file" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
assert "tunnel_key" in c and len(c["tunnel_key"]) == 64, "server tunnel_key missing/invalid"
assert "server_port" in c and 1 <= c["server_port"] <= 65535, "server_port invalid"
assert c.get("server_host") in ("0.0.0.0", "127.0.0.1"), "server_host must be 0.0.0.0 or 127.0.0.1"
print("VALID")
PYEOF
}

# ---- Supply Chain Verification ----
verify_binary() {
    local file="$1" expected_arch="$2"
    if ! command_exists file; then return 0; fi
    local out; out="$(file "$file" 2>/dev/null)"
    case "$expected_arch" in
        amd64) [[ "$out" == *"x86-64"* ]] || return 1 ;;
        arm64) [[ "$out" == *"aarch64"* ]] || return 1 ;;
    esac
    return 0
}

# ---- Audit Log ----
audit_log() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    local action="$1" details="$2"
    local log_dir="/var/log/gooseforge"
    sudo mkdir -p "$log_dir" 2>/dev/null || mkdir -p "$HOME/.gooseforge/logs"
    log_dir="${log_dir:-$HOME/.gooseforge/logs}"
    local entry
    entry="$(printf '{"timestamp":"%s","action":"%s","user":"%s","details":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$action" "${USER:-unknown}" "$details")"
    echo "$entry" | sudo tee -a "${log_dir}/audit.log" >/dev/null 2>&1 || echo "$entry" >> "${log_dir}/audit.log"
}

# ---- Main QuickInstall Flow ----
main() {
    clear
    cat <<'BANNER'
   ____                         _____
  / ___| ___   ___  ___  ___   |  ___|__  _ __ __ _  ___
 | |  _ / _ \ / _ \/ __|/ _ \  | |_ / _ \| '__/ _` |/ _ \
 | |_| | (_) | (_) \__ \  __/  |  _| (_) | | | (_| |  __/
  \____|\___/ \___/|___/\___/  |_|  \___/|_|  \__, |___|
                                               |___/
BANNER
    printf "%s%s v%s%s — One-line full VPN deployment\n\n" "$BOLD" "$APP" "$VERSION" "$RESET"
    printf "%sAuthor: %s%s\n" "$DIM" "$AUTHOR" "$RESET"
    printf "%sProject: %s%s\n\n" "$DIM" "$PROJECT_URL" "$RESET"

    tutorial_step "Welcome! This will set up a complete GooseRelayVPN system:"
    tutorial_step "1. Server on this VPS (goose-server + HAProxy TLS)"
    tutorial_step "2. Client folder for your PC (Linux amd64)"
    tutorial_step "3. Client folder for your phone (Android arm64, Termux-ready)"
    tutorial_step "4. Apps Script Code.gs with your relay URL"
    tutorial_step "5. Deployment IDs for Google Apps Script"
    tutorial_step "6. A ready-to-copy bundle with everything"

    # Detect environment
    local is_vps=0 is_termux=0
    if [[ $EUID -eq 0 ]] && command_exists systemctl; then is_vps=1; fi
    [[ -n "${TERMUX_VERSION:-}" ]] && is_termux=1

    if [[ $is_vps -eq 1 ]]; then
        info "Detected: VPS (root + systemd) — will install SERVER + CLIENTS"
    elif [[ $is_termux -eq 1 ]]; then
        info "Detected: Termux on Android — will prepare CLIENT folder only"
        is_vps=0
    else
        info "Detected: Regular Linux (no root) — will prepare CLIENT folder only"
        is_vps=0
    fi

    # Collect inputs
    local domain="" relay_url="" deploy_ids=() deploy_accounts=() tunnel_key=""

    if [[ $is_vps -eq 1 ]]; then
        # Server needs domain for TLS
        if [[ $ASSUME_YES -eq 1 ]]; then
            domain="${GOOSE_DOMAIN:-}"
        else
            printf "\n%sServer TLS setup:%s\n" "$BOLD" "$RESET"
            printf "Enter your domain (e.g., vpn.example.com) or press Enter for HTTP-only mode:\n"
            read -r domain
        fi
        if [[ -n "$domain" ]] && ! valid_domain "$domain"; then
            fail "Invalid domain format"
        fi
    fi

    # Deployment IDs
    if [[ $ASSUME_YES -eq 1 ]]; then
        # In assume-yes mode, we need at least one deployment ID from env
        if [[ -n "${GOOSE_DEPLOYMENT_IDS:-}" ]]; then
            IFS=',' read -ra deploy_ids <<< "${GOOSE_DEPLOYMENT_IDS}"
            IFS=',' read -ra deploy_accounts <<< "${GOOSE_DEPLOYMENT_ACCOUNTS:-acct-a,acct-b,acct-c,acct-d}"
        else
            warn "No deployment IDs provided via GOOSE_DEPLOYMENT_IDS — you'll need to add them later"
        fi
    else
        printf "\n%sDeployment IDs (from script.google.com):%s\n" "$BOLD" "$RESET"
        printf "You need at least ONE Deployment ID (starts with AKfycb... ~70 chars).\n"
        printf "Get it from: script.google.com → Deploy → Manage deployments → Copy ID\n\n"
        while true; do
            printf "Deployment ID #%d (or Enter to finish): " $(( ${#deploy_ids[@]} + 1 ))
            read -r id
            [[ -z "$id" ]] && break
            if ! valid_appscript_id "$id"; then
                warn "Invalid format (must be AKfycb... 50+ chars). Try again."
                continue
            fi
            deploy_ids+=("$id")
            local def_acct="acct-$(( ${#deploy_ids[@]} + 96 ))"  # a, b, c...
            printf "  Account label [%s]: " "$def_acct"
            read -r acct
            deploy_accounts+=("${acct:-$def_acct}")
            [[ ${#deploy_ids[@]} -ge 4 ]] && { warn "4 is plenty (quota is per Google account)"; break; }
        done
        if [[ ${#deploy_ids[@]} -eq 0 ]]; then
            warn "No deployment IDs entered — you can add them later via menu 3→3"
        fi
    fi

    # Tunnel key
    if [[ $is_vps -eq 1 ]]; then
        tunnel_key="$(generate_tunnel_key)"
        ok "Generated tunnel key: ${tunnel_key:0:16}...${tunnel_key: -4}"
    else
        if [[ -n "${GOOSE_TUNNEL_KEY:-}" ]] && valid_tunnel_key "$GOOSE_TUNNEL_KEY"; then
            tunnel_key="$GOOSE_TUNNEL_KEY"
            ok "Using tunnel key from GOOSE_TUNNEL_KEY env"
        else
            printf "\n%sTunnel Key:%s\n" "$BOLD" "$RESET"
            printf "Enter the 64-char tunnel key from the VPS (sudo cat /root/goose_tunnel_key.txt):\n"
            read -r tunnel_key
            tunnel_key="$(printf '%s' "$tunnel_key" | tr -d '[:space:]' | tr 'A-F' 'a-f')"
            if ! valid_tunnel_key "$tunnel_key"; then fail "Invalid tunnel key (must be 64 hex chars)"; fi
        fi
    fi

    # Relay URL
    if [[ $is_vps -eq 1 && -n "$domain" ]]; then
        relay_url="https://${domain}:8443/tunnel"
    elif [[ -n "${GOOSE_RELAY_URL:-}" ]] && valid_relay_url "$GOOSE_RELAY_URL"; then
        relay_url="$GOOSE_RELAY_URL"
    else
        printf "\n%sRelay URL:%s\n" "$BOLD" "$RESET"
        printf "Enter your relay URL (e.g., https://vpn.example.com:8443/tunnel):\n"
        read -r relay_url
        if ! valid_relay_url "$relay_url"; then fail "Invalid relay URL format"; fi
    fi
    ok "Relay URL: $relay_url"

    # Edge test
    probe_edges

    # Confirmation
    if [[ $ASSUME_YES -eq 0 && $DRY_RUN -eq 0 ]]; then
        printf "\n%sSummary:%s\n" "$BOLD" "$RESET"
        [[ $is_vps -eq 1 ]] && printf "  Server: %s (TLS: %s)\n" "$LOCK" "$([[ -n $domain ]] && echo "Yes ($domain)" || echo "No (HTTP only)")"
        printf "  Edge: %s\n" "$EDGE_PICKED"
        printf "  Deployments: %d\n" "${#deploy_ids[@]}"
        printf "  Client folders: %s, %s\n" "$CLIENT_HOME" "$ANDROID_HOME"
        [[ $is_vps -eq 1 ]] && printf "  Bundle: ~/goose-quickinstall-bundle.tgz\n"
        printf "\nProceed? [Y/n]: "
        read -r confirm
        [[ "${confirm,,}" == "n" ]] && { info "Cancelled."; exit 0; }
    fi

    # ===== EXECUTION =====
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY RUN COMPLETE — no changes made"
        exit 0
    fi

    # ---- SERVER INSTALL (VPS only) ----
    if [[ $is_vps -eq 1 ]]; then
        step "Installing SERVER on VPS..."

        # Packages
        run_step "Installing packages (haproxy, certbot, wget, tar...)" \
            bash -c 'apt update && apt install -y haproxy certbot wget tar openssl ca-certificates curl file sed gawk'

        # Firewall
        run_step "Configuring firewall (UFW)" bash -c '
            ufw allow 22/tcp; ufw allow 8443/tcp; ufw allow 80/tcp; ufw allow 443/tcp
            ufw --force enable; ufw reload
        '

        # Download server
        local workdir tarball
        workdir="$(mktemp -d)"
        tarball="${workdir}/server.tar.gz"
        run_step "Downloading server binary" fetch "$SERVER_URL" "$tarball"
        run_step "Verifying archive" tar -tzf "$tarball"
        tar -xzf "$tarball" -C "$workdir"
        local topdir extracted server_bin config_example
        topdir="$(awk -F/ 'NF{print $1; exit}' <(tar -tzf "$tarball"))"
        extracted="${workdir}/${topdir}"
        [[ -d "$extracted" ]] || extracted="$workdir"
        server_bin="$(find "$extracted" -maxdepth 2 -type f -name 'goose-server' | head -1)"
        config_example="$(find "$extracted" -maxdepth 2 -type f -name 'server_config.example.json' | head -1)"
        [[ -n "$server_bin" && -n "$config_example" ]] || fail "Missing files in server archive"

        run_step "Installing goose-server binary" cp "$server_bin" "$GOOSE_BIN" && chmod 755 "$GOOSE_BIN"
        run_step "Installing server config" cp "$config_example" "$GOOSE_CONFIG"

        # Configure server
        sed -i -E "s/(\"tunnel_key\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\1${tunnel_key}\2/" "$GOOSE_CONFIG"
        if [[ -n "$domain" ]]; then
            sed -i -E 's/("server_host"[[:space:]]*:[[:space:]]*")[^"]*(")/\1 127.0.0.1\2/' "$GOOSE_CONFIG"
            sed -i -E "s/(\"server_port\"[[:space:]]*:[[:space:]]*)[0-9]+/\1 9444/" "$GOOSE_CONFIG"
        else
            sed -i -E 's/("server_host"[[:space:]]*:[[:space:]]*")[^"]*(")/\1 0.0.0.0\2/' "$GOOSE_CONFIG"
            sed -i -E "s/(\"server_port\"[[:space:]]*:[[:space:]]*)[0-9]+/\1 8443/" "$GOOSE_CONFIG"
        fi
        validate_server_config "$GOOSE_CONFIG" && ok "Server config validated"

        # Save key
        printf "%s\n" "$tunnel_key" | tee "$GOOSE_KEY_FILE" >/dev/null
        chmod 600 "$GOOSE_KEY_FILE"

        # Systemd service
        tee "$GOOSE_UNIT" >/dev/null <<'SVC_EOF'
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
SVC_EOF

        systemctl daemon-reload
        systemctl enable goose-relay
        systemctl start goose-relay

        # TLS + HAProxy
        if [[ -n "$domain" ]]; then
            run_step "Requesting Let's Encrypt certificate" certbot certonly --standalone -d "$domain"
            run_step "Building HAProxy PEM" bash -c "
                mkdir -p $HAPROXY_CERT_DIR
                cat /etc/letsencrypt/live/${domain}/fullchain.pem /etc/letsencrypt/live/${domain}/privkey.pem > ${HAPROXY_CERT_DIR}/${domain}.pem
                chmod 600 ${HAPROXY_CERT_DIR}/${domain}.pem
            "
            # HAProxy config
            mkdir -p "$(dirname "$HAPROXY_CFG")"
            tee "$HAPROXY_CFG" >/dev/null <<'HAP_EOF'
global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 4096
    ssl-default-bind-ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-bind-options ssl-min-ver TLSv1.3

defaults
    log global
    mode tcp
    timeout connect 10s
    timeout client 1m
    timeout server 1m
HAP_EOF
            cat >> "$HAPROXY_CFG" <<HAP_EOF

# GooseForge managed block
frontend goose_tls_in
    bind *:8443 ssl crt ${HAPROXY_CERT_DIR}/${domain}.pem
    mode http
    default_backend goose_back

backend goose_back
    mode http
    server goose 127.0.0.1:9444
HAP_EOF
            run_step "Validating HAProxy config" haproxy -c -f "$HAPROXY_CFG"
            systemctl restart haproxy
            systemctl enable haproxy
        else
            warn "No domain — running HTTP mode on port 8443 (no HAProxy TLS)"
        fi

        # Save state
        mkdir -p "$STATE_DIR"
        chmod 700 "$STATE_DIR"
        tee "$STATE_FILE" >/dev/null <<STATE_EOF
GOOSE_DOMAIN="${domain:-}"
GOOSE_MODE=$([[ -n $domain ]] && echo "tls" || echo "http")
GOOSE_PUBLIC_PORT=8443
GOOSE_BACKEND_PORT=$([[ -n $domain ]] && echo 9444 || echo 8443)
GOOSE_DOWNLOAD_URL="${SERVER_URL}"
GOOSE_INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STATE_EOF
        chmod 600 "$STATE_FILE"

        audit_log "server_install" "{\"domain\":\"$domain\",\"mode\":\"$([[ -n $domain ]] && echo tls || echo http)\"}"
        ok "SERVER installed successfully"
    fi

    # ---- CLIENT INSTALL (both) ----
    step "Preparing CLIENT folders..."

    for target in "linux:$CLIENT_HOME:$CLIENT_LINUX_URL:linux-amd64" "android:$ANDROID_HOME:$CLIENT_ANDROID_URL:android-arm64"; do
        IFS=':' read -r type home url label <<< "$target"
        [[ $is_termux -eq 1 && "$type" == "linux" ]] && continue  # Skip linux build on Termux
        [[ $is_vps -eq 0 && "$type" == "android" && ! -d "$home" ]] && mkdir -p "$home"

        run_step "Downloading $label client" bash -c "
            mkdir -p '$home'
            tmp=\$(mktemp)
            fetch '$url' '\$tmp'
            tar -tzf '\$tmp' >/dev/null
            tar -xzf '\$tmp' -C '\$(mktemp -d)' 2>/dev/null || true
            # Find and copy binary
            bin=\$(find /tmp -maxdepth 3 -name 'goose-client' -type f 2>/dev/null | head -1)
            [[ -n \$bin ]] && cp \$bin '$home/goose-client' && chmod 755 '$home/goose-client'
        " || fail "Failed to install $label client"

        verify_binary "$home/goose-client" "$([[ $type == linux ]] && echo amd64 || echo arm64)" && ok "$label binary verified"
    done

    # ---- WRITE CONFIGS ----
    step "Writing client configs..."
    for home in "$CLIENT_HOME" "$ANDROID_HOME"; do
        [[ -f "$home/goose-client" ]] || continue

        # Build script_keys JSON
        local script_keys_json=""
        for i in "${!deploy_ids[@]}"; do
            script_keys_json+=$(printf '{"id":"%s","account":"%s"}' "${deploy_ids[i]}" "${deploy_accounts[i]}")
            [[ $i -lt $((${#deploy_ids[@]}-1)) ]] && script_keys_json+=","
        done

        cat > "$home/client_config.json" <<CONFIG_EOF
{
  "debug_timing": false,
  "socks_host": "127.0.0.1",
  "socks_port": 1080,
  "google_host": "${EDGE_PICKED}",
  "sni": ["www.google.com", "mail.google.com", "accounts.google.com"],
  "script_keys": [${script_keys_json}],
  "tunnel_key": "${tunnel_key}",
  "socks_user": "",
  "socks_pass": "",
  "coalesce_step_ms": 25,
  "idle_slots_per_bucket": 2
}
CONFIG_EOF
        validate_client_config "$home/client_config.json" && ok "Config written: $home/client_config.json"
    done

    # ---- START/STOP SCRIPTS & GUIDE ----
    step "Writing helper scripts..."
    for home in "$CLIENT_HOME" "$ANDROID_HOME"; do
        [[ -f "$home/goose-client" ]] || continue

        cat > "$home/start-goose.sh" <<'START_EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")" || exit 1
if command -v ip >/dev/null 2>&1 && ip link show singbox_tun >/dev/null 2>&1; then
    echo "⚠️  v2rayN TUN mode is ON — turn it off first!"
    while ip link show singbox_tun >/dev/null 2>&1; do
        read -rp "Press Enter after turning off TUN mode... " _
    done
fi
if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":1080 "; then
    echo "Port 1080 busy — run ./stop-goose.sh first"; exit 1
fi
echo "=== Starting GooseRelayVPN ==="
echo "SOCKS5: socks5://127.0.0.1:1080"
echo "Wait for 'pre-flight OK' then 'ready: local SOCKS5 is listening'"
echo ""
./goose-client -config client_config.json 2>&1 | tee -a goose-client.log
START_EOF
        chmod 755 "$home/start-goose.sh"

        cat > "$home/stop-goose.sh" <<'STOP_EOF'
#!/usr/bin/env bash
if pkill -f "goose-client -config" 2>/dev/null; then echo "Stopped."; else echo "Not running."; fi
STOP_EOF
        chmod 755 "$home/stop-goose.sh"

        # Child-proof GUIDE.txt
        cat > "$home/GUIDE.txt" <<'GUIDE_EOF'
╔══════════════════════════════════════════════════════════════════╗
║                    GOOSERELayVPN — QUICK GUIDE                    ║
╚══════════════════════════════════════════════════════════════════╝

🌐 WHAT IS THIS?
   A VPN that hides your traffic inside normal Google HTTPS.
   Your browser → SOCKS5 (127.0.0.1:1080) → Google → Apps Script → Your VPS → Internet.
   Only YOU have the secret key. Google sees only encrypted noise.

▶️  START VPN (2 steps)
   1. Open terminal in THIS folder
   2. Run:  ./start-goose.sh
   ✅ Wait for: "pre-flight OK" then "ready: local SOCKS5 is listening on 127.0.0.1:1080"

⏹️  STOP VPN
   Press Ctrl+C in the terminal, OR run:  ./stop-goose.sh

🦊 USE IN FIREFOX (30 seconds)
   1. Settings → General → Network Settings → "Settings..."
   2. Manual proxy → SOCKS Host: 127.0.0.1  Port: 1080
   3. ☑️ SOCKS v5    ☑️ Proxy DNS when using SOCKS v5    → OK
   4. Check: https://api.ipify.org → Should show YOUR VPS IP

⚠️  RULE #1 (THE ONLY RULE!)
   NEVER run this while another VPN "TUN mode" is ON.
   (v2rayN on PC, or VPN app on phone).
   One tunnel at a time! The start script will stop you if you forget.

✅ CHECK IF WORKING
   curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
   Must show your VPS IP, NOT your real IP.

📱 ANDROID (Termux) — THIS FOLDER IS READY
   1. Install Termux (F-Droid) → pkg update
   2. Copy this folder to phone → cd ~/storage/downloads/<folder>
   3. chmod +x goose-client start-goose.sh stop-goose.sh
   4. ./start-goose.sh
   5. In NekoBox/v2rayNG: SOCKS5 127.0.0.1:1080, EXCLUDE Termux from proxy.

📊 QUOTA & SPEED
   ~20,000 calls/day per Google ACCOUNT (resets ~10:30 Iran summer / 11:30 winter).
   Speed: ~300-800ms extra per request. 1080p video works; 480p comfortable.
   "Blacklisted for 3s" = NORMAL. Only worry if stats bytes stay at 0.

➕ MORE SPEED/QUOTA?
   Add another deployment (different Google account):
   1. New Google account → script.google.com → paste Code.gs
   2. Deploy → New deployment → Anyone → Copy ID
   3. Edit client_config.json → add to "script_keys": ,{"id":"NEW_ID","account":"acct-b"}
   4. Restart client. Quota doubles, failover automatic.

🔒 SECURITY (READ ONCE)
   • NEVER share client_config.json (tunnel_key = full access to your VPS)
   • If leaked: change tunnel_key on BOTH VPS config AND here
   • When posting logs: black out AKfycb... and user_content_key=... strings

🆘 TROUBLESHOOTING
   • "pre-flight FAILED" → Check relay URL, VPS firewall, domain DNS
   • "HTTP 404" → Deployment not "Anyone" access → Redeploy web app
   • "Connection reset" → Rule #1 violated → Turn off other VPN TUN
   • Still stuck? Run installer again → Menu 6 (Doctor) → Read GUIDE.txt
GUIDE_EOF
    done

    # ---- APPS SCRIPT CODE.GS ----
    step "Generating Apps Script Code.gs..."
    local code_dest="$CLIENT_HOME/Code.gs"
    cat > "$code_dest" <<'CODE_EOF'
// GooseRelay forwarder — DEPLOY THIS TO script.google.com
// Execute as: Me | Who has access: Anyone
// REPLACE RELAY_URLS WITH YOUR VPS URL BEFORE DEPLOYING

const RELAY_URLS = [
  'RELAY_URL_PLACEHOLDER'
];
const FORWARDER_VERSION = 1;
const PROTOCOL_VERSION = 1;
const ENABLE_INVOCATION_COUNTING = false;
const GAS_RELAY_LOOP_RE = /^https?:\/\/script\.google\.com\/macros\//i;

function doPost(e) {
  for (let i = 0; i < RELAY_URLS.length; i++) {
    if (GAS_RELAY_LOOP_RE.test(RELAY_URLS[i])) {
      throw new Error('relay_loop_detected: RELAY_URLS must point to your VPS /tunnel endpoint, not Apps Script');
    }
  }
  if (ENABLE_INVOCATION_COUNTING) bumpInvocationCount_();
  const payload = (e && e.postData && e.postData.contents) || '';
  let lastError = 'no RELAY_URLS configured';
  for (let i = 0; i < RELAY_URLS.length; i++) {
    try {
      const resp = UrlFetchApp.fetch(RELAY_URLS[i], {
        method: 'post', contentType: 'text/plain', payload: payload,
        muteHttpExceptions: true, followRedirects: false, deadline: 30
      });
      const status = resp.getResponseCode();
      const text = resp.getContentText();
      if (status === 200) {
        return ContentService.createTextOutput(text).setMimeType(ContentService.MimeType.TEXT);
      }
      lastError = 'upstream status ' + status + ': ' + text.slice(0, 1024);
    } catch (err) { lastError = 'upstream fetch error: ' + String(err); }
  }
  throw new Error(lastError);
}

function doGet(e) {
  if (e && e.parameter && e.parameter.legacy === '1') {
    return ContentService.createTextOutput('GooseRelay forwarder OK').setMimeType(ContentService.MimeType.TEXT);
  }
  const props = PropertiesService.getScriptProperties();
  const today = Utilities.formatDate(new Date(), 'America/Los_Angeles', 'yyyy-MM-dd');
  const count = parseInt(props.getProperty('count_' + today) || '0', 10);
  return ContentService.createTextOutput(JSON.stringify({
    ok: true, date: today, count: count, version: FORWARDER_VERSION, protocol: PROTOCOL_VERSION
  })).setMimeType(ContentService.MimeType.JSON);
}

function bumpInvocationCount_() {
  try {
    const props = PropertiesService.getScriptProperties();
    const today = Utilities.formatDate(new Date(), 'America/Los_Angeles', 'yyyy-MM-dd');
    const key = 'count_' + today;
    const raw = props.getProperty(key);
    if (raw === null) {
      const keys = props.getKeys();
      for (let i = 0; i < keys.length; i++) if (keys[i].indexOf('count_') === 0 && keys[i] !== key) props.deleteProperty(keys[i]);
    }
    props.setProperty(key, String((raw === null ? 0 : parseInt(raw, 10)) + 1));
  } catch (err) {}
}
CODE_EOF

    # Replace placeholder
    sed -i "s|RELAY_URL_PLACEHOLDER|${relay_url}|" "$code_dest"
    ok "Code.gs written: $code_dest (relay URL injected)"

    # ---- BUNDLE (VPS only) ----
    if [[ $is_vps -eq 1 && -d "$CLIENT_HOME" && -d "$ANDROID_HOME" ]]; then
        step "Creating transfer bundle..."
        run_step "Packing bundle" tar -czf /root/goose-quickinstall-bundle.tgz -C /root GooseRelayVPN-client-linux GooseRelayVPN-android 2>/dev/null || \
            tar -czf /root/goose-quickinstall-bundle.tgz -C "$HOME" goose goose-android 2>/dev/null || \
            tar -czf /root/goose-quickinstall-bundle.tgz "$CLIENT_HOME" "$ANDROID_HOME"
        ok "Bundle ready: /root/goose-quickinstall-bundle.tgz"
        echo ""
        echo "  To copy to your PC:"
        echo "    scp root@$(hostname -I | awk '{print $1}'):/root/goose-quickinstall-bundle.tgz ."
        echo "    tar xzf goose-quickinstall-bundle.tgz"
        echo "    # 'goose' = PC folder, 'goose-android' = Phone folder"
    fi

    # ---- HEALTH CHECK ----
    if [[ $is_vps -eq 1 ]]; then
        step "Running health check..."
        sleep 3
        if systemctl is-active --quiet goose-relay; then ok "goose-relay: RUNNING"; else fail "goose-relay not running"; fi
        if [[ -n "$domain" ]]; then
            if systemctl is-active --quiet haproxy; then ok "haproxy: RUNNING"; else fail "haproxy not running"; fi
            local code; code="$(curl -k -m 8 -s -o /dev/null -w '%{http_code}' "https://${domain}:8443/healthz" 2>/dev/null || true)"
            [[ "$code" =~ ^[23][0-9][0-9]$ ]] && ok "HTTPS endpoint: HTTP $code" || warn "HTTPS endpoint check failed (check DNS/firewall)"
        else
            local code; code="$(curl -m 6 -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8443/healthz" 2>/dev/null || true)"
            [[ "$code" =~ ^[23][0-9][0-9]$ ]] && ok "HTTP endpoint: HTTP $code" || warn "HTTP endpoint check failed"
        fi
    fi

    # ---- FINAL SUMMARY ----
    echo ""
    printf "%s═══════════════════════════════════════════════════════════%s\n" "$GREEN" "$RESET"
    printf "%s  🎉  QUICKINSTALL COMPLETE!  🎉%s\n" "$BOLD$GREEN" "$RESET"
    printf "%s═══════════════════════════════════════════════════════════%s\n\n" "$GREEN" "$RESET"

    printf "%sWhat you have:%s\n" "$BOLD" "$RESET"
    [[ $is_vps -eq 1 ]] && printf "  %s Server: goose-server + HAProxy TLS on :8443 → :9444\n" "$LOCK"
    printf "  %s PC Client: %s (run ./start-goose.sh)\n" "$GLOBE" "$CLIENT_HOME"
    printf "  %s Phone Client: %s (copy to phone, run in Termux)\n" "📱" "$ANDROID_HOME"
    printf "  %s Apps Script: %s (deploy to script.google.com)\n" "📝" "$code_dest"
    [[ $is_vps -eq 1 ]] && printf "  %s Bundle: /root/goose-quickinstall-bundle.tgz (scp this)\n" "$BUNDLE"
    printf "\n%sNext steps:%s\n" "$BOLD" "$RESET"
    if [[ ${#deploy_ids[@]} -eq 0 ]]; then
        printf "  1. Deploy Code.gs to script.google.com (5 steps)\n"
        printf "  2. Copy Deployment ID → add to client_config.json manually\n"
        printf "  3. Or run installer again → Menu 3 → 3 (Deployment Manager)\n"
    else
        printf "  1. Deploy Code.gs to script.google.com (5 steps)\n"
        printf "  2. Your %d deployment ID(s) are already in configs ✅\n" "${#deploy_ids[@]}"
    fi
    printf "  3. PC: cd %s && ./start-goose.sh\n" "$CLIENT_HOME"
    printf "  4. Test: curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org\n"
    printf "\n%sTunnel key (save this!):%s %s\n" "$BOLD" "$RESET" "$tunnel_key"
    [[ $is_vps -eq 1 ]] && printf "%sOn VPS: sudo cat /root/goose_tunnel_key.txt%s\n" "$DIM" "$RESET"
    printf "\n%sHappy tunneling!%s\n" "$GREEN" "$RESET"

    audit_log "quickinstall_complete" "{\"vps\":$is_vps,\"deployments\":${#deploy_ids[@]},\"domain\":\"$domain\"}"
}

main "$@"
