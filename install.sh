#!/usr/bin/env bash
set -Eeuo pipefail

# =====================================================================
#  GooseForge v2.0.0 — FULL installer & manager for GooseRelayVPN
#
#  One script, everything:
#    1)  Full installation : server + Apps Script + both clients
#    2)  Server install    : VPS (Linux amd64) - goose-server + HAProxy TLS
#    3)  Client install    : Linux amd64 + Android arm64 (Termux-ready)
#    4)  Apps Script       : working Code.gs + 5-step deployment guide
#    5)  Test              : server test / client test
#    6)  Doctor            : one-key health diagnosis
#    7)  IPv4-only helper  : fixes a VPS with dead IPv6 (like OVH boxes)
#    8)  Status    9) Advanced    10) Uninstall
#
#  Every submenu has:  b) Back   and   0) Exit.
#
#  * The server side stays 100% compatible with GooseForge v1 (same
#    state file, same HAProxy managed block) - safe to run again on a
#    VPS that already has v1 installed.
#  * The client side needs NO root and never touches system files.
#  * Client configs are the field-proven tuned ones (auto-picked fast
#    Google edge, 25 ms uplink coalescing, 2 idle slots, 3 SNIs).
#
#  Author : jackh0006 <jackh109867@gmail.com>
#  Project: https://github.com/Kianmhz/GooseRelayVPN
#  License: MIT - see LICENSE
# =====================================================================

VERSION="2.0.0"
APP="GooseForge"
AUTHOR="jackh0006 <jackh109867@gmail.com>"
PROJECT_URL="https://github.com/Kianmhz/GooseRelayVPN"
RELAY_RELEASE="v1.7.1"
RELAY_BASE="https://github.com/Kianmhz/GooseRelayVPN/releases/download/${RELAY_RELEASE}"
SERVER_URL="${GOOSE_SERVER_URL:-${RELAY_BASE}/GooseRelayVPN-server-${RELAY_RELEASE}-linux-amd64.tar.gz}"
CLIENT_LINUX_URL="${GOOSE_CLIENT_LINUX_URL:-${RELAY_BASE}/GooseRelayVPN-client-${RELAY_RELEASE}-linux-amd64.tar.gz}"
CLIENT_ANDROID_URL="${GOOSE_CLIENT_ANDROID_URL:-${RELAY_BASE}/GooseRelayVPN-client-${RELAY_RELEASE}-android-arm64.tar.gz}"

# ---- server (VPS) paths - IDENTICAL to GooseForge v1 (safe re-run) ----
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

# ---- client paths (no root needed; env-overridable for tests) ----
CLIENT_HOME="${GOOSE_CLIENT_HOME:-$HOME/goose}"
ANDROID_HOME="${GOOSE_ANDROID_HOME:-$HOME/goose-android}"
GOOGLE_EDGES=(216.239.32.120 216.239.34.120 216.239.36.120 216.239.38.120)
DEFAULT_EDGE="216.239.38.120"
DEP_IDS=(); DEP_ACCTS=()   # globals; always defined (see set -u)

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
BLUE=$'\033[34m'; MAGENTA=$'\033[35m'; CYAN=$'\033[36m'
BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'

export DEBIAN_FRONTEND=noninteractive

info() { printf "%s[INFO]%s %s\n" "$CYAN" "$RESET" "$*"; }
ok()   { printf "%s[ OK ]%s %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "$YELLOW" "$RESET" "$*"; }
fail() { printf "%s[FAIL]%s %s\n" "$RED" "$RESET" "$*"; }

pause() { printf "\n%sPress Enter to continue...%s " "$DIM" "$RESET"; read -r _ || true; }

menu_title() {
  printf "\n%s%s%s\n%s\n" "$BOLD" "$1" "$RESET" "--------------------------------------------"
}

# Graceful on Ctrl+D everywhere: exit clean instead of spinning on EOF.
bye_eof() { printf "\n"; ok "Bye. (${APP} ${VERSION} — by ${AUTHOR})"; exit 0; }

ask_line() { # ask_line VAR [prompt]  — reads one line, EOF-safe
  local __var="$1" __prompt="${2:-}" __line=""
  if [[ -n "$__prompt" ]]; then printf "%s" "$__prompt"; fi
  if ! IFS= read -r __line; then bye_eof; fi
  printf -v "$__var" '%s' "$__line"
}

ask_yes_no() { # ask_yes_no "prompt"  — EOF counts as "no"
  local answer
  while true; do
    ask_line answer "$1 [y/N]: "
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no|"") return 1 ;;
      *) warn "Please type yes or no." ;;
    esac
  done
}

valid_domain()        { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_port()          { [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
valid_appscript_id()  { [[ "$1" =~ ^AKfycb[A-Za-z0-9_-]{50,}$ ]]; }
valid_deployment_id() { [[ "$1" =~ ^[A-Za-z0-9_-]{20,}$ ]]; }
valid_tunnel_key()    { printf '%s' "$1" | grep -qE '^[0-9a-f]{64}$'; }
valid_host_ip()       { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_relay_url()     { [[ "$1" =~ ^https?://[A-Za-z0-9._~%-]+(:[0-9]{1,5})?/tunnel/?$ ]]; }
command_exists()      { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "This part needs root privileges (it must run ON the VPS)."
    info "Run it there with:  sudo bash $0"
    return 1
  fi
  return 0
}

# ---- server state (same file and fields as GooseForge v1) ----
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
GOOSE_BACKEND_PORT="${GOOSE_BACKEND_PORT:-9444}"
GOOSE_DOWNLOAD_URL="${GOOSE_DOWNLOAD_URL:-$SERVER_URL}"
GOOSE_INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
  sudo chmod 600 "$STATE_FILE"
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

fetch() { # fetch <url> <outfile>
  local url="$1" out="$2"
  if command_exists curl; then
    curl -fsSL --retry 2 -o "$out" "$url"
  elif command_exists wget; then
    wget -qO "$out" "$url"
  else
    fail "Need curl or wget (try: sudo apt install curl)."
    return 1
  fi
}

banner() {
  clear || true
  printf "%s" "$CYAN"
  cat <<'GF_BANNER'
   ____                         _____
  / ___| ___   ___  ___  ___   |  ___|__  _ __ __ _  ___
 | |  _ / _ \ / _ \/ __|/ _ \  | |_ / _ \| '__/ _` |/ _ \
 | |_| | (_) | (_) \__ \  __/  |  _| (_) | | | (_| |  __/
  \____|\___/ \___/|___/\___/  |_|  \___/|_|  \__, |\___|
                                               |___/
GF_BANNER
  printf "%s" "$RESET"
  printf "%sGooseForge v%s%s — FULL installer\n" "$BOLD" "$VERSION" "$RESET"
  printf "%sserver = VPS | client-PC = linux amd64 | client-phone = android arm64%s\n" "$DIM" "$RESET"
  printf "%sby %s%s\n\n" "$DIM" "$AUTHOR" "$RESET"
}

# Test the 4 known Google edge IPs, keep the fastest one in EDGE_PICKED.
probe_edges() {
  local ip out code ms best="" best_ms=999999
  if ! command_exists curl; then
    warn "curl not found — skipping the edge test, using ${DEFAULT_EDGE}."
    EDGE_PICKED="$DEFAULT_EDGE"
    return 0
  fi
  printf "\n%sTesting 4 known Google edge IPs (worst case ~25s)...%s\n" "$BOLD" "$RESET"
  for ip in "${GOOGLE_EDGES[@]}"; do
    out="$(curl -sS -o /dev/null --max-time 6 --resolve "www.google.com:443:${ip}" -w '%{http_code} %{time_total}' https://www.google.com/generate_204 2>/dev/null || true)"
    code="${out%% *}"
    if [[ "$code" == "204" ]]; then
      ms="$(awk -v t="${out#* }" 'BEGIN{printf "%d", t*1000}')"
      printf "  %-16s HTTP %s   %sms\n" "$ip" "$code" "$ms"
      if [[ "$ms" -lt "$best_ms" ]]; then best_ms="$ms"; best="$ip"; fi
    else
      printf "  %-16s HTTP %s   (blocked here)\n" "$ip" "${code:-err}"
    fi
  done
  if [[ -n "$best" ]]; then
    ok "Best edge for THIS network: ${best}"
    EDGE_PICKED="$best"
  else
    warn "No edge answered from this network — using ${DEFAULT_EDGE} (changeable later in client_config.json)."
    EDGE_PICKED="$DEFAULT_EDGE"
  fi
}

client_state_save() { # client_state_save <home>
  {
    echo "CLIENT_LABEL=\"${CLIENT_LABEL:-}\""
    echo "CLIENT_GOOGLE_HOST=\"${EDGE_PICKED:-}\""
    echo "CLIENT_RELAY_URL=\"${RELAY_URL:-}\""
    echo "CLIENT_DEPLOYMENTS=\"${#DEP_IDS[@]}\""
    echo "CLIENT_INSTALLED_AT=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  } > "$1/.gooseforge-state"
}

# Write the field-proven tuned client config (uses DEP_IDS/DEP_ACCTS).
# Tuned values (validated live on a hostile hotspot):
#   coalesce_step_ms = 25   => fewer Apps Script calls, faster bursts
#   idle_slots_per_bucket = 2 => required minimum for 1 deployment
write_client_config() { # write_client_config <home> <edge> <tunnel_key>
  local home="$1" edge="$2" key="$3"
  local n="${#DEP_IDS[@]}" i tail
  {
    echo '{'
    echo '  "debug_timing": false,'
    echo '  "socks_host": "127.0.0.1",'
    echo '  "socks_port": 1080,'
    echo "  \"google_host\": \"${edge}\","
    echo '  "sni": ["www.google.com", "mail.google.com", "accounts.google.com"],'
    echo "  \"_comment_script_keys\": \"Want more speed/failover later? See GUIDE.txt -> 'Adding another deployment later'. Deployments whose account label is the same share one Apps Script daily quota bucket.\","
    echo '  "script_keys": ['
    for ((i = 0; i < n; i++)); do
      tail=","
      if [[ $((i + 1)) -eq $n ]]; then tail=""; fi
      printf '    {"id": "%s", "account": "%s"}%s\n' "${DEP_IDS[i]}" "${DEP_ACCTS[i]}" "$tail"
    done
    echo '  ],'
    echo "  \"tunnel_key\": \"${key}\","
    echo '  "_comment_socks_auth": "Optional: require SOCKS5 username/password (RFC 1929). Both fields must be set together or both omitted.",'
    echo '  "socks_user": "",'
    echo '  "socks_pass": "",'
    echo '  "_comment_coalesce": "25 ms = bundle small bursts of outgoing data before one Apps Script call. Fewer calls = further from the daily quota and more stable on an unstable hotspot. Set 0 to disable.",'
    echo '  "coalesce_step_ms": 25,'
    echo '  "_comment_idle_slots": "2 is correct for a single-deployment account: the client code enforces a minimum of 2 idle slots for a single bucket (needed for download throughput). After adding deployments under a second Google account the client can use other values (min 1, max 3) - see GUIDE.txt.",'
    echo '  "idle_slots_per_bucket": 2'
    echo '}'
  } > "${home}/client_config.json"
}

# =====================================================================
#  SHARED CLIENT PIECES: start/stop scripts, guide, Apps Script Code.gs
# =====================================================================

write_start_script() { # write_start_script <home>
  cat > "$1/start-goose.sh" <<'GF_START_EOF'
#!/usr/bin/env bash
# GooseRelayVPN — safe start script.
# Starts the VPN client and keeps a log in ./goose-client.log (next to this file).
# The script always finds its own folder, so it works from:
#   ~/goose ,  Downloads/GooseRelayVPN-client-v1.7.1-linux-amd64 ,
#   and the android-arm64 folder (Termux).
# Stop it any time with Ctrl+C in this window, or run:  ./stop-goose.sh

cd "$(dirname "$0")" || exit 1

# --- Safety check 1: another VPN (v2rayN / sing-box TUN) must not be capturing traffic ---
# (check is skipped automatically on systems where the `ip` tool is missing, e.g. Termux)
if command -v ip >/dev/null 2>&1 && ip link show singbox_tun >/dev/null 2>&1; then
  echo ""
  echo "!! PROBLEM: v2rayN's 'Tun mode' (sing-box) is ON and capturing ALL internet traffic."
  echo "!! Running GooseRelayVPN on top of it is exactly what causes connection resets."
  echo ""
  echo "FIX (10 seconds) — do EITHER one:"
  echo "   A) In the v2rayN window: click the  'Tun mode'  toggle so it turns OFF."
  echo "   B) OR right-click the v2rayN icon near the clock -> Exit / Quit completely."
  echo ""
  echo "   (When TUN is off, your desktop internet goes direct and Firefox via"
  echo "    SOCKS5 127.0.0.1:1080 gets the tunnel — that is the normal Way-A setup.)"
  echo ""
  while true; do
    if ! read -r -p ">> Turn it off, then press ENTER here to re-check (Ctrl+C to quit): " _ack; then
      echo ""; echo "No terminal input available — run this script inside a terminal window."
      exit 1
    fi
    if ! ip link show singbox_tun >/dev/null 2>&1; then
      echo "   singbox_tun is gone — good. Starting GooseRelayVPN..."
      break
    fi
    echo "   ...still ON. Flip the toggle in v2rayN (or exit v2rayN), then press ENTER again."
  done
fi

# --- Safety check 2: the SOCKS5 port must be free ---
# (check is skipped automatically if the `ss` tool is missing, e.g. Termux)
if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":1080 "; then
  echo ""
  echo "!! Port 1080 is already taken — goose-client is probably already running."
  echo "!! Run  ./stop-goose.sh  first if you want to restart it."
  ss -tlnp 2>/dev/null | grep ":1080 "
  exit 1
fi

echo "=== started $(date) ===" >> goose-client.log
echo "Starting GooseRelayVPN client..."
echo "  - SOCKS5 proxy address: socks5://127.0.0.1:1080  (set this in your browser/app)"
echo "  - Wait for the lines:  'pre-flight OK'  then  'ready: local SOCKS5 is listening'"
echo "  - Press Ctrl+C (or run ./stop-goose.sh) to stop it."
echo ""
./goose-client -config client_config.json 2>&1 | tee -a goose-client.log
echo "Client stopped."
GF_START_EOF
  chmod 755 "$1/start-goose.sh"
}

write_stop_script() { # write_stop_script <home>
  cat > "$1/stop-goose.sh" <<'GF_STOP_EOF'
#!/usr/bin/env bash
# GooseRelayVPN — stop script. Stops a running goose-client.
if pkill -f "goose-client -config" 2>/dev/null; then
  echo "goose-client stopped."
else
  echo "No goose-client was running."
fi
GF_STOP_EOF
  chmod 755 "$1/stop-goose.sh"
}

write_guide() { # write_guide <home>
  cat > "$1/GUIDE.txt" <<'GF_GUIDE_EOF'
 GooseRelayVPN - BEGINNER GUIDE (keep this file!)
=================================================

WHAT THIS IS
------------
A VPN that hides your traffic inside normal-looking Google HTTPS.
Your browser talks to a small program (goose-client) on YOUR device
through a "SOCKS5 proxy" at address 127.0.0.1 port 1080.
Everything then goes: Google -> Apps Script -> your VPS -> the internet.
Only you hold the AES key; Google sees only encrypted noise.

=================================================
 DAILY USE
=================================================

START THE VPN
  - Open a terminal IN THIS FOLDER and run:   ./start-goose.sh
  - GOOD SIGNS in the output:
       "pre-flight OK: relay healthy, AES key matches end-to-end"
       "ready: local SOCKS5 is listening on 127.0.0.1:1080"
    After that it keeps printing harmless info lines. Leave the window open.

STOP THE VPN
  - Press Ctrl+C in that terminal window, or run:  ./stop-goose.sh

USE IT IN FIREFOX
  1. Firefox -> Settings -> General -> Network Settings -> "Settings..."
  2. Choose "Manual proxy configuration".
  3. Check "SOCKS Host", fill:   127.0.0.1     Port: 1080
  4. Under it choose  SOCKS v5
  5. VERY IMPORTANT: check  "Proxy DNS when using SOCKS v5"   (required!)
  6. OK. Verify at https://api.ipify.org - you must see your VPS IP.

RULE #1 (THE THING THAT BREAKS EVERYTHING WHEN IGNORED)
-------------------------------------------------------
  NEVER run GooseRelayVPN while another VPN "TUN mode" is ON
  (v2rayN on the PC, or a TUN/VPN app on the phone).
  One tunnel at a time! The start script detects TUN, refuses to start,
  hugs you through fixing it: flip the toggle off, press ENTER, done.

CHECK IF THE VPN IS WORKING RIGHT NOW?
--------------------------------------
     curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
  Prints your exit IP. It must be your VPS IP, NOT your real IP.
  Logs live in ./goose-client.log (next to this file).

=================================================
 ANDROID PHONE (Termux) - this folder is ALREADY READY
=================================================
  (goose-client, client_config.json, start-goose.sh, stop-goose.sh,
   GUIDE.txt - same keys as the PC)
  1. Install "Termux" (from F-Droid) and run:  pkg update
  2. Copy this whole folder to the phone, then in Termux:
        cd ~/storage/downloads/<this folder name>
        chmod +x goose-client start-goose.sh stop-goose.sh
        ./start-goose.sh
     (if the script ever misbehaves, run the raw binary instead:
        ./goose-client -config client_config.json )
  3. When you see "ready: local SOCKS5 is listening on 127.0.0.1:1080",
     open an app that understands SOCKS5 (NekoBox or v2rayNG):
     proxy type SOCKS5, 127.0.0.1:1080 - and in its per-app settings
     EXCLUDE Termux itself from the proxy list.
  4. Same Rule #1: one tunnel at a time - do not run goose inside
     another VPN TUN app on the phone either.

=================================================
 QUOTA / EXPECTATIONS
=================================================
  - About 20,000 Apps Script calls/day per Google ACCOUNT (shared by
    all deployments of that account). Resets midnight US Pacific
    (about 10:30 Iran summer / 11:30 winter). Visible in the client's
    "[stats]" lines ("today=N").
  - Speed: about 300-800 ms extra per round trip - normal video
    buffering at 1080p; 480p is comfortable. More accounts help.
  - Occasional "blacklisted for 3s ... recovered" lines are NORMAL.
    Only worry if "[stats]" bytes stay at 0 for many minutes while
    you actively browse.

=================================================
 ADDING ANOTHER DEPLOYMENT LATER (more speed + more quota)
=================================================
  1. Sign in to the NEW Google account, open https://script.google.com/
  2. New project -> delete the sample code
  3. Paste the SAME Code.gs you used before (it is in this folder if
     the installer wrote it), or the official one:
     https://github.com/Kianmhz/GooseRelayVPN/blob/main/apps_script/Code.gs
  4. Only the RELAY_URLS line matters - keep it pointing to your VPS:
     https://YOUR-DOMAIN:8443/tunnel
  5. Deploy -> New deployment -> Web app -> Execute as: Me,
     Who has access: Anyone -> Deploy -> copy the Deployment ID
  6. Open client_config.json in this folder and add inside script_keys:
         ,{"id": "PASTE_NEW_ID", "account": "acct-b"}
  7. Restart the client. Quota doubles and failover is automatic.

  IMPORTANT: every time you edit Code.gs you must use
  Deploy -> "New deployment" (saving alone changes nothing).

=================================================
 SECURITY - PLEASE READ ONCE
=================================================
  - NEVER share client_config.json (the "tunnel_key" inside is the
    entire security: anyone with it can use your VPS as exit).
  - If leaked: change tunnel_key on BOTH the VPS config and here.
  - When pasting logs online, black out long AKfycb... and
    user_content_key=... strings.
GF_GUIDE_EOF
  chmod 644 "$1/GUIDE.txt"
}

# Official forwarder code (Kianmhz/GooseRelayVPN apps_script/Code.gs).
# The placeholder relay URL is swapped for the user's own URL.
write_code_gs() { # write_code_gs <dest_file> <relay_url>
  local dest="$1" url="$2"
  mkdir -p "$(dirname "$dest")"
  cat > "${dest}.template" <<'GF_CODE_EOF'
// GooseRelay forwarder.
//
// Apps Script web app deployed as: Execute as: Me, Access: Anyone (or Anyone with Google account).
// All traffic is AES-GCM encrypted by the client; this script is a dumb pipe
// and never sees plaintext or holds the key.
//
// Wire: client POSTs base64(encrypted batch). We forward the bytes verbatim
// to one of RELAY_URLS and return its response body verbatim.
//
// Replace RELAY_URLS with your VPS address(es) before deploying.

const RELAY_URLS = [
  // Replace YOUR_SERVER_PORT with server_config.json's server_port.
  'http://YOUR.VPS.IP:YOUR_SERVER_PORT/tunnel',
];
const FORWARDER_VERSION = 1;
const PROTOCOL_VERSION = 1;
const ENABLE_INVOCATION_COUNTING = false;
const GAS_RELAY_LOOP_RE = /^https?:\/\/script\.google\.com\/macros\//i;

function doPost(e) {
  for (let i = 0; i < RELAY_URLS.length; i++) {
    if (GAS_RELAY_LOOP_RE.test(RELAY_URLS[i])) {
      // Throw so Apps Script returns HTTP 500. Returning 200 with this
      // diagnostic text would be parsed by the client as a base64 batch and
      // fail at the colon - see the v1.7.0 -> v1.7.1 fix in client.go.
      throw new Error('relay_loop_detected: RELAY_URLS must point to your VPS /tunnel endpoint, not Apps Script');
    }
  }
  if (ENABLE_INVOCATION_COUNTING) {
    bumpInvocationCount_();
  }
  const payload = (e && e.postData && e.postData.contents) || '';
  let lastError = 'no RELAY_URLS configured';
  for (let i = 0; i < RELAY_URLS.length; i++) {
    try {
      const resp = UrlFetchApp.fetch(RELAY_URLS[i], {
        method: 'post',
        contentType: 'text/plain',
        payload: payload,
        muteHttpExceptions: true,
        followRedirects: false,
        deadline: 30,  // seconds; long-poll window is kept below this for Apps Script stability
      });
      const status = resp.getResponseCode();
      const text = resp.getContentText();
      if (status === 200) {
        return ContentService
          .createTextOutput(text)
          .setMimeType(ContentService.MimeType.TEXT);
      }
      lastError = 'upstream status ' + status + ': ' + text.slice(0, 1024);
    } catch (err) {
      lastError = 'upstream fetch error: ' + String(err);
    }
  }
  // All RELAY_URLS failed. Throw so Apps Script returns HTTP 500 with an
  // HTML error page - the GooseRelay client's non-200 code path treats this
  // as a clean endpoint failure and rotates to the next deployment. Returning
  // 200 with a plain-text error body (as v1.7.0 did) was the cause of the
  // "batch: base64 decode: illegal base64 data at input byte 9" client log
  // spam: the client would try to base64-decode "upstream fetch error: ..."
  // and fail at the first colon.
  throw new Error(lastError);
}

// doGet returns this deployment's per-day invocation count so the client can
// log real per-deployment usage alongside its own client-side counter. The
// day boundary tracks the Apps Script quota window (midnight Pacific). Format
// is JSON so the client can parse without ambiguity:
//   {"ok":true,"date":"2026-05-04","count":1234}
function doGet(e) {
  if (e && e.parameter && e.parameter.legacy === '1') {
    return ContentService
      .createTextOutput('GooseRelay forwarder OK')
      .setMimeType(ContentService.MimeType.TEXT);
  }
  const props = PropertiesService.getScriptProperties();
  const today = pacificDateKey_();
  const count = parseInt(props.getProperty('count_' + today) || '0', 10);
  const out = {
    ok: true,
    date: today,
    count: count,
    version: FORWARDER_VERSION,
    protocol: PROTOCOL_VERSION,
  };
  return ContentService
    .createTextOutput(JSON.stringify(out))
    .setMimeType(ContentService.MimeType.JSON);
}

function pacificDateKey_() {
  return Utilities.formatDate(new Date(), 'America/Los_Angeles', 'yyyy-MM-dd');
}

// bumpInvocationCount_ records one invocation in PropertiesService keyed by
// today's PT date. Best-effort: under high concurrency two requests may read
// the same value and write the same incremented number, slightly under-counting.
// That's acceptable for an informational counter - adding a LockService gate
// would add tens of ms to every tunnel request, which costs more than perfect
// accuracy is worth.
function bumpInvocationCount_() {
  try {
    const props = PropertiesService.getScriptProperties();
    const today = pacificDateKey_();
    const key = 'count_' + today;
    const raw = props.getProperty(key);
    if (raw === null) {
      // First request of a new day - purge yesterday's keys so the property
      // store doesn't grow unbounded (capped at 9 KB / 500 entries by Google).
      pruneStaleCounts_(props, today);
    }
    const cur = raw === null ? 0 : parseInt(raw, 10);
    props.setProperty(key, String(cur + 1));
  } catch (err) {
    // Property writes can fail under contention; counting is informational
    // so we swallow the error rather than break the tunnel request.
  }
}

function pruneStaleCounts_(props, today) {
  const keys = props.getKeys();
  const keep = 'count_' + today;
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    if (k.indexOf('count_') === 0 && k !== keep) {
      props.deleteProperty(k);
    }
  }
}
GF_CODE_EOF
  awk -v url="$url" '{
    gsub(/http:\/\/YOUR\.VPS\.IP:YOUR_SERVER_PORT\/tunnel/, url)
    print
  }' "${dest}.template" > "$dest"
  rm -f "${dest}.template"
  ok "Apps Script code written: ${dest}   (RELAY_URLS -> ${url})"
}

apps_script_walkthrough() { # apps_script_walkthrough <codegs_path>
  printf "\n%sNEXT: 5 steps on script.google.com (child-proof):%s\n\n" "$BOLD" "$RESET"
  printf " 1) Open https://script.google.com in the browser you are signed in with.\n"
  printf " 2) New project -> DELETE the sample code -> paste EVERYTHING from %s\n" "$1"
  printf " 3) Deploy -> New deployment -> gear 'Web app' ->\n"
  printf "      Execute as: Me    Who has access: Anyone -> Deploy\n"
  printf " 4) Copy the Deployment ID (starts with AKfycb...) shown at the end.\n"
  printf " 5) Give that ID to the client: menu 3 asks for it during install, or\n"
  printf "      open client_config.json and add it under script_keys.\n"
  printf "\n%sNOTE: editing Code.gs later ALWAYS needs Deploy -> New deployment%s\n" "$DIM" "$RESET"
  printf "%s(saving alone changes nothing).%s\n\n" "$DIM" "$RESET"
}

apps_script_flow() { # standalone helper: menu item 4
  banner
  menu_title "Apps Script helper - working Code.gs + deployment steps"
  load_state
  local def="" relay dest d
  if [[ "${GOOSE_MODE:-}" == "tls" && -n "${GOOSE_DOMAIN:-}" ]]; then
    def="https://${GOOSE_DOMAIN}:${GOOSE_PUBLIC_PORT:-8443}/tunnel"
  fi
  if [[ -n "$def" ]]; then
    info "Detected from your server install: ${def}"
    ask_line relay "Relay URL [${def}] (0 = cancel): "
    relay="${relay:-$def}"
  else
    info "A Relay URL looks like: https://YOUR-DOMAIN:8443/tunnel"
    ask_line relay "Relay URL (0 = cancel): "
  fi
  if [[ "$relay" == "0" ]]; then info "Cancelled."; return 0; fi
  while ! valid_relay_url "$relay"; do
    fail "That does not look like a relay URL. Example: https://vpn.example.com:8443/tunnel"
    ask_line relay "Relay URL (0 = cancel): "
    if [[ "$relay" == "0" ]]; then info "Cancelled."; return 0; fi
  done
  RELAY_URL="$relay"
  dest="$HOME/goose/Code.gs"
  if [[ ! -d "$HOME/goose" ]]; then dest="$(pwd)/Code.gs"; fi
  ask_line d "Save Code.gs to [${dest}] (0 = cancel): "
  if [[ "$d" == "0" ]]; then info "Cancelled."; return 0; fi
  dest="${d:-$dest}"
  write_code_gs "$dest" "$RELAY_URL"
  apps_script_walkthrough "$dest"

  # If a client config exists, offer to add this deployment to it directly.
  local cfgs=() c
  for c in "$HOME/goose/client_config.json" "$ANDROID_HOME/client_config.json"; do
    if [[ -f "$c" ]]; then cfgs+=("$c"); fi
  done
  if [[ "${#cfgs[@]}" -gt 0 ]] && command_exists python3; then
    info "Found client config(s): ${cfgs[*]}"
    if ask_yes_no "Add this deployment ID to them now?"; then
      local dep acct idok=0
      while [[ $idok -eq 0 ]]; do
        ask_line dep "Deployment ID (AKfycb..., 0 = cancel): "
        if [[ "$dep" == "0" ]]; then break; fi
        if valid_appscript_id "$dep"; then
          idok=1
        elif [[ "$dep" =~ ^AKfycb ]] && valid_deployment_id "$dep"; then
          warn "Suspiciously short ID (~70 chars expected)."
          if ask_yes_no "Use it anyway?"; then idok=1; fi
        else
          fail "That does not look like an Apps Script deployment ID."
        fi
      done
      if [[ $idok -eq 1 ]]; then
        ask_line acct "Account label [acct-b]: "
        acct="${acct:-acct-b}"
        local f
        for f in "${cfgs[@]}"; do
          cp -f "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
          if python3 - "$f" "$dep" "$acct" <<'GF_PY_ADD'
import json, sys
p, dep, acct = sys.argv[1], sys.argv[2], sys.argv[3]
with open(p) as fh: c = json.load(fh)
ks = c.setdefault("script_keys", [])
if any(k.get("id") == dep for k in ks):
    print("   already present - left unchanged")
else:
    ks.append({"id": dep, "account": acct})
    with open(p, "w") as fh: json.dump(c, fh, indent=2)
print("   added")
GF_PY_ADD
          then
            ok "Updated ${f}"
          else
            fail "Could not update ${f} (added nothing). Add it by hand."
          fi
        done
      else
        fail "Deployment ID invalid or cancelled - nothing was changed."
      fi
    fi
  fi
  pause
}

# =====================================================================
#  CLIENT INPUT COLLECTORS (shared by linux + android flows)
# =====================================================================

collect_deployments() { # fills global DEP_IDS / DEP_ACCTS (min 1, max 4)
  DEP_IDS=(); DEP_ACCTS=()
  local letters=(a b c d e f g h)
  local i=1 id acct n=0 def_acct
  info "You need at least ONE Apps Script 'Deployment ID' (starts with AKfycb...)."
  info "It comes from script.google.com -> Deploy -> Manage deployments."
  while true; do
    ask_line id "Deployment ID #${i} (or Enter to finish, 0 = cancel): "
    if [[ "$id" == "0" ]]; then fail "Cancelled."; return 1; fi
    if [[ -z "$id" ]]; then break; fi
    if ! valid_appscript_id "$id"; then
      if [[ "$id" =~ ^AKfycb ]] && valid_deployment_id "$id"; then
        warn "That ID is suspiciously short (real ones are ~70 chars) - may be truncated."
        if ! ask_yes_no "Use it anyway?"; then
          continue
        fi
      elif valid_deployment_id "$id"; then
        warn "That does not look like an Apps Script deployment ID."
        warn "(They normally start with:  AKfycb...)"
        info "If you pasted your 64-hex TUNNEL KEY by mistake, press Ctrl+C and start over."
        if ! ask_yes_no "Use this ID anyway?"; then
          continue
        fi
      else
        fail "That ID looks wrong (20+ chars, only letters/digits/_/-)."
        continue
      fi
    fi
    def_acct="acct-${letters[n]:-x$((n + 1))}"
    ask_line acct "  Google account label for it [${def_acct}]: "
    acct="${acct:-$def_acct}"
    DEP_IDS+=("$id"); DEP_ACCTS+=("$acct")
    n=$((n + 1)); i=$((i + 1))
    if [[ $n -ge 4 ]]; then
      warn "Four deployments is plenty (Google quota is per Google ACCOUNT)."
      break
    fi
  done
  if [[ "${#DEP_IDS[@]}" -eq 0 ]]; then
    fail "No deployment ID was given - the client cannot work without one."
    return 1
  fi
  return 0
}

collect_key() { # fills global CLIENT_KEY
  if [[ -n "${GOOSE_PRED_KEY:-}" ]] && valid_tunnel_key "$GOOSE_PRED_KEY"; then
    CLIENT_KEY="$GOOSE_PRED_KEY"
    ok "Tunnel key taken from your fresh server install (no typing needed)."
    return 0
  fi
  if [[ -n "${GOOSE_PRED_KEY:-}" ]]; then
    fail "Ignoring invalid GOOSE_PRED_KEY."
  fi
  info "The tunnel key is 64 hex chars - it lives on the VPS:  sudo cat /root/goose_tunnel_key.txt"
  local k
  while true; do
    ask_line k "Tunnel key (64 hex chars, 0 = cancel): "
    if [[ "$k" == "0" ]]; then fail "Cancelled."; return 1; fi
    k="$(printf '%s' "$k" | tr -d '[:space:]' | tr 'A-F' 'a-f')"
    if valid_tunnel_key "$k"; then
      CLIENT_KEY="$k"
      return 0
    fi
    fail "Must be exactly 64 hex characters (0-9, a-f)."
  done
}

# =====================================================================
#  CLIENT INSTALL — engine (linux + phone share ONE code path)
# =====================================================================

client_common_install() { # <home> <label> <url>
  local home="$1" label="$2" url="$3"
  local tarball extract bin tmp
  mkdir -p "$home"

  tarball="$(mktemp)"
  if ! run_step "Downloading client archive (${RELAY_RELEASE} ${label})" fetch "$url" "$tarball"; then
    rm -f "$tarball"
    return 1
  fi
  if ! run_step "Checking archive integrity" tar -tzf "$tarball"; then
    rm -f "$tarball"
    return 1
  fi
  extract="$(mktemp -d)"
  if ! tar -xzf "$tarball" -C "$extract"; then
    fail "Archive could not be extracted (broken download?)."
    rm -f "$tarball"; rm -rf "$extract"
    return 1
  fi
  rm -f "$tarball"

  bin="$(find "$extract" -maxdepth 3 -type f -name 'goose-client' | head -n 1)"
  if [[ -z "$bin" ]]; then
    fail "goose-client binary not found inside the archive."
    find "$extract" -maxdepth 3 -type f | sed 's/^/  /'
    rm -rf "$extract"
    return 1
  fi
  cp "$bin" "${home}/goose-client"
  chmod 755 "${home}/goose-client"
  rm -rf "$extract"
  ok "Installed binary: ${home}/goose-client"

  # Upgrade path: keep an existing config if there is one (key stays safe).
  if [[ -f "${home}/client_config.json" ]]; then
    if ask_yes_no "An existing client_config.json was found - KEEP it (recommended)?"; then
      ok "Keeping your existing config (tunnel key and deployments untouched)."
    else
      if ! collect_deployments; then return 1; fi
      if ! collect_key; then return 1; fi
      if [[ -n "${GOOSE_PRED_EDGE:-}" ]]; then
        EDGE_PICKED="$GOOSE_PRED_EDGE"
        ok "Google edge preselected: ${EDGE_PICKED}"
      else
        probe_edges
      fi
      CLIENT_LABEL="$label"
      write_client_config "$home" "$EDGE_PICKED" "$CLIENT_KEY"
    fi
  else
    if ! collect_deployments; then return 1; fi
    if ! collect_key; then return 1; fi
    if [[ -n "${GOOSE_PRED_EDGE:-}" ]]; then
      EDGE_PICKED="$GOOSE_PRED_EDGE"
      ok "Google edge preselected: ${EDGE_PICKED}"
    else
      probe_edges
    fi
    CLIENT_LABEL="$label"
    write_client_config "$home" "$EDGE_PICKED" "$CLIENT_KEY"
  fi

  write_start_script "$home"
  write_stop_script "$home"
  write_guide "$home"
  client_state_save "$home"

  # Validate the JSON if python3 exists (best testing available).
  if command_exists python3; then
    if ! python3 - "$home/client_config.json" > /dev/null 2>&1 <<'GF_PY_VAL'
import json, sys
c = json.load(open(sys.argv[1]))
assert c["socks_port"] == 1080
assert isinstance(c["script_keys"], list) and len(c["script_keys"]) >= 1
assert len(c["tunnel_key"]) == 64
print("config JSON valid")
GF_PY_VAL
    then
      fail "Generated client_config.json failed validation."
      return 1
    fi
    ok "Config validated: JSON parses, 1080, 1+ deployments, 64-hex key."
  fi

  chmod 755 "${home}/start-goose.sh" "${home}/stop-goose.sh" "${home}/goose-client" 2>/dev/null || true
  printf "\n%s%s client ready in: %s%s\n" "$GREEN" "$label" "$home" "$RESET"
  printf "  start :  cd %s && ./start-goose.sh\n" "$home"
  printf "  stop  :  ./stop-goose.sh   (or Ctrl+C)\n"
  printf "  check :  curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org\n"
  return 0
}

client_linux_install() { # menu 3 -> 1
  banner
  menu_title "Client installation - Linux amd64 (PC)"
  if [[ "$(uname -m)" != "x86_64" ]]; then
    warn "This device is '$(uname -m)'; the Linux client is amd64 (made for a PC)."
    if ! ask_yes_no "Continue anyway (e.g. preparing a folder for another PC)?"; then
      return 0
    fi
  fi
  if ! command_exists curl && ! command_exists wget; then
    fail "Need curl or wget:  sudo apt install curl   (then run me again)."
    return 1
  fi
  if ! command_exists tar; then
    fail "Need tar:  sudo apt install tar"
    return 1
  fi
  local dir
  info "Everything goes into ONE self-contained folder (no root, no system files)."
  ask_line dir "Install folder [${CLIENT_HOME}]: "
  CLIENT_HOME="${dir:-$CLIENT_HOME}"
  if ! client_common_install "$CLIENT_HOME" "linux-amd64" "$CLIENT_LINUX_URL"; then
    fail "Linux client installation did not finish."
    return 1
  fi
  return 0
}

client_android_install() { # menu 3 -> 2
  banner
  menu_title "Client installation - Android arm64 (phone / Termux)"
  local dir in_termux=0
  if [[ -n "${TERMUX_VERSION:-}" ]]; then
    in_termux=1
    ok "Termux detected - installing directly on THIS phone."
    if [[ "$(uname -m)" != "aarch64" ]]; then
      fail "Termux arch is '$(uname -m)' but the phone client needs arm64."
      return 1
    fi
    CLIENT_HOME="$HOME/goose"
  else
    info "Preparing a READY-TO-COPY phone folder (this device: $(uname -m))."
    if [[ "$(uname -m)" != "x86_64" && "$(uname -m)" != "aarch64" ]]; then
      warn "Unusual machine '$(uname -m)' - fine for preparing the folder."
      if ! ask_yes_no "Continue?"; then return 0; fi
    fi
  fi
  if ! command_exists tar; then
    fail "Need tar (in Termux: pkg install tar)."
    return 1
  fi
  if ! command_exists curl && ! command_exists wget; then
    fail "Need curl or wget (in Termux: pkg install curl)."
    return 1
  fi
  ask_line dir "Folder [${ANDROID_HOME}]: "
  ANDROID_HOME="${dir:-$ANDROID_HOME}"
  if ! client_common_install "$ANDROID_HOME" "android-arm64" "$CLIENT_ANDROID_URL"; then
    fail "Android client preparation did not finish."
    return 1
  fi
  if [[ $in_termux -eq 0 ]]; then
    printf "\n%sPHONE TRANSFER (2 minutes):%s\n" "$BOLD" "$RESET"
    printf "  1) Copy the folder %s to the phone (USB cable is fine).\n" "$ANDROID_HOME"
    printf "  2) In Termux:   pkg update && pkg install curl tar\n"
    printf "      cd ~/storage/downloads/%s\n" "$(basename "$ANDROID_HOME")"
    printf "      chmod +x goose-client start-goose.sh stop-goose.sh\n"
    printf "      ./start-goose.sh\n"
    printf "  3) In NekoBox/v2rayNG: SOCKS5 127.0.0.1:1080, and EXCLUDE\n"
    printf "     Termux itself from the proxied apps. Details: GUIDE.txt\n"
  fi
  return 0
}

# =====================================================================
#  FULL INSTALLATION (menu item 1): server + Apps Script + clients
# =====================================================================

server_relay_url() { # derive relay URL from server state (root/vps)
  load_state
  if [[ "${GOOSE_MODE:-}" == "tls" && -n "${GOOSE_DOMAIN:-}" ]]; then
    printf "https://%s:%s/tunnel" "$GOOSE_DOMAIN" "${GOOSE_PUBLIC_PORT:-8443}"
  else
    local ip
    ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)"
    if [[ -z "$ip" ]] && command_exists hostname; then
      ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    printf "http://%s:%s/tunnel" "${ip:-YOUR_VPS_IP}" "${GOOSE_PUBLIC_PORT:-8443}"
  fi
}

full_install_flow() {
  banner
  menu_title "FULL installation (server + Apps Script + clients)"
  local relay="" key="" server_ok=0 client_label=""

  if [[ "${EUID}" -eq 0 ]] && command_exists systemctl; then
    info "STEP 1/3 - SERVER (VPS)."
    GOOSE_TRAP_OFF=1
    set +e
    install_flow
    local server_rc=$?
    set -e
    GOOSE_TRAP_OFF=0
    if [[ $server_rc -eq 0 ]]; then
      server_ok=1
      relay="$(server_relay_url)"
      RELAY_URL="$relay"
      key="$(cat "$GOOSE_KEY_FILE" 2>/dev/null || true)"
      ok "Server part done. Relay URL: ${relay}"
    else
      warn "Server part did not finish - I will still set up client parts."
      if ! ask_yes_no "Continue with the client parts anyway?"; then return 1; fi
    fi
  else
    warn "The server part must run ON the VPS with root:  sudo bash $0"
    info "On THIS device I can still do the FULL CLIENT setup."
    if ! ask_yes_no "Set up the client for THIS device now?"; then
      info "Tip: for the one-command whole thing, run on the VPS:  sudo bash $0"
      return 0
    fi
  fi

  info "STEP 2/3 - CLIENTS."
  if [[ -n "$key" ]]; then
    export GOOSE_PRED_KEY="$key"
  fi
  if [[ "${EUID}" -eq 0 && $server_ok -eq 1 ]]; then
    local which
    printf "  1) BOTH client folders (one to copy to a PC, one to the phone) [default]\n"
    printf "  2) Linux amd64 only\n"
    printf "  3) Android arm64 only (ready to copy to the phone)\n"
    ask_line which "Which client folders should I prepare? [1]: "
    which="${which:-1}"
    case "$which" in
      1)
        CLIENT_HOME="/root/GooseRelayVPN-client-linux"
        ANDROID_HOME="/root/GooseRelayVPN-client-android"
        client_linux_install || true
        if ask_yes_no "Continue to prepare the ANDROID folder too?"; then
          client_android_install || true
        fi
        ;;
      2) client_linux_install || true ;;
      3) client_android_install || true ;;
      *) warn "Unknown choice - skipping client preparation." ;;
    esac
  else
    # Not-root machine: auto-pick the right client for THIS device.
    if [[ -n "${TERMUX_VERSION:-}" ]]; then
      client_label="android"
    else
      case "$(uname -m)" in
        x86_64) client_label="linux" ;;
        aarch64|arm64) client_label="android" ;;
        *) client_label="" ;;
      esac
    fi
    if [[ "$client_label" == "linux" ]]; then
      client_linux_install || true
    elif [[ "$client_label" == "android" ]]; then
      client_android_install || true
    else
      printf "  1) Linux amd64 (PC)\n  2) Android arm64 (phone)\n"
      local pick
      ask_line pick "Which one? [1]: "
      pick="${pick:-1}"
      if [[ "$pick" == "2" ]]; then client_android_install || true
      else client_linux_install || true; fi
    fi
  fi

  # Code.gs: write it wherever a client folder just got created.
  if [[ -n "$relay" ]]; then
    local code_dest=""
    if [[ -f "/root/GooseRelayVPN-client-linux/client_config.json" ]]; then
      code_dest="/root/GooseRelayVPN-client-linux/Code.gs"
    elif [[ -f "$CLIENT_HOME/client_config.json" ]]; then
      code_dest="${CLIENT_HOME}/Code.gs"
    elif [[ -d "$(pwd)" ]]; then
      code_dest="$(pwd)/Code.gs"
    fi
    if [[ -n "$code_dest" ]]; then
      write_code_gs "$code_dest" "$relay"
      apps_script_walkthrough "$code_dest"
    fi
  fi

  # One-file bundle on the VPS: grab it with scp and everything is inside.
  if [[ $server_ok -eq 1 && -d "/root/GooseRelayVPN-client-android" ]]; then
    if run_step "Packing a ready bundle of both client folders" \
      tar -czf /root/goose-clients-bundle.tgz -C /root GooseRelayVPN-client-linux GooseRelayVPN-client-android; then
      ok "Bundle ready: /root/goose-clients-bundle.tgz"
      printf "\n%sTo pull it to your PC at home:%s\n" "$BOLD" "$RESET"
      printf "  scp root@YOUR_VPS_IP:/root/goose-clients-bundle.tgz .\n"
      printf "  tar xzf goose-clients-bundle.tgz\n"
      printf "  -> 'GooseRelayVPN-client-linux' = for a PC, '-android' = for the phone.\n"
    fi
  fi

  if [[ $server_ok -eq 1 ]]; then
    info "STEP 3/3 - automatic SERVER TEST."
    server_test_flow quiet || true
  fi

  printf "\n%sFULL INSTALLATION FINISHED.%s\n" "$GREEN" "$RESET"
  printf "Read the printed summaries above - every next step is written in front of you.\n"
  pause
}

# =====================================================================
#  SERVER INSTALL (VPS) — proven GooseForge v1 flow, kept compatible
# =====================================================================

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
    local port
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
  sudo tee "$HAPROXY_CFG" >/dev/null <<'EOF'
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

  ask_line domain "Subdomain for TLS certificate, or press Enter to use VPS IPv4 HTTP mode: "
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

  ask_line download_url "Download link [${SERVER_URL}]: "
  GOOSE_DOWNLOAD_URL="${download_url:-$SERVER_URL}"

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
  return 0
}

# =====================================================================
#  TEST — menu item 5: server test / client test
# =====================================================================

chk_pass() { ok "PASS: $*"; CHK_PASS=$((CHK_PASS + 1)); }
chk_fail() { fail "FAIL: $*"; CHK_FAIL=$((CHK_FAIL + 1)); }

client_state_load() { # source the first client state found (CLIENT_RELAY_URL etc.)
  local f
  for f in "$CLIENT_HOME/.gooseforge-state" "$ANDROID_HOME/.gooseforge-state"; do
    if [[ -f "$f" ]]; then
      # shellcheck disable=SC1090
      source "$f"
      return 0
    fi
  done
  return 1
}

client_test_flow() { # client_test_flow [compact]
  local compact=0
  if [[ "${1:-}" == "compact" || "${1:-}" == "1" ]]; then compact=1; fi
  CHK_PASS=0; CHK_FAIL=0

  local homes=() p
  for p in "$CLIENT_HOME" "$ANDROID_HOME"; do
    if [[ -f "$p/client_config.json" ]]; then homes+=("$p"); fi
  done
  for p in "$HOME/Downloads"/GooseRelayVPN-client-*; do
    if [[ -d "$p" && -f "$p/client_config.json" ]] && ! in_list "$p" "${homes[@]+"${homes[@]}"}"; then
      homes+=("$p")
    fi
  done
  if [[ -f "$(pwd)/client_config.json" ]] && ! in_list "$(pwd)" "${homes[@]+"${homes[@]}"}"; then
    homes+=("$(pwd)")
  fi

  if [[ "${#homes[@]}" -eq 0 ]]; then
    info "No client installed here yet. Use menu 3 to install one."
    return 1
  fi

  if command_exists ip && ip link show singbox_tun >/dev/null 2>&1; then
    warn "Rule #1: another VPN TUN (sing-box) is ON - results below can be misleading."
  fi

  local h label port liveip code
  for h in "${homes[@]}"; do
    if [[ -f "$h/.gooseforge-state" ]]; then
      # shellcheck disable=SC1090
      source "$h/.gooseforge-state"
    fi
    label="${CLIENT_LABEL:-unknown}"
    CLIENT_LABEL=""
    printf "\n%sClient: %s  (%s)%s\n" "$BOLD" "$h" "$label" "$RESET"

    if [[ -x "$h/goose-client" ]]; then
      chk_pass "binary is executable (${h}/goose-client)"
    else
      chk_fail "binary missing/not executable (${h}/goose-client)"
    fi

    port=""
    if command_exists python3; then
      if port="$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1])).get("socks_port",1080)))' "$h/client_config.json" 2>/dev/null)"; then
        chk_pass "config JSON parses (socks_port=${port})"
      else
        chk_fail "config JSON does not parse (${h}/client_config.json)"
      fi
    else
      if grep -q '"tunnel_key"' "$h/client_config.json" 2>/dev/null; then
        chk_pass "config present (install python3 for deep validation)"
      else
        chk_fail "config is not a goose config (${h}/client_config.json)"
      fi
      port="$(grep -oE '"socks_port"[^0-9]*[0-9]+' "$h/client_config.json" 2>/dev/null | grep -oE '[0-9]+' | head -n 1)"
    fi
    port="${port:-1080}"

    if command_exists ss && ss -tln 2>/dev/null | grep -q ":${port} "; then
      if command_exists curl; then
        liveip="$(curl -s --max-time 12 --socks5-hostname "127.0.0.1:${port}" https://api.ipify.org 2>/dev/null || true)"
        if [[ -n "$liveip" ]]; then
          chk_pass "SOCKS5 on 127.0.0.1:${port} is LIVE - exit IP via tunnel: ${liveip}"
        else
          chk_fail "port ${port} is open but the tunnel did not answer (client stuck? restart it)"
        fi
      else
        chk_pass "port ${port} listening (install curl for a live tunnel test)"
      fi
    else
      info "client is not running right now - start:  cd ${h} && ./start-goose.sh"
    fi
  done

  printf "\n%sClient test: %s passed, %s failed.%s\n" "$BOLD" "$CHK_PASS" "$CHK_FAIL" "$RESET"
  if [[ $compact -eq 0 ]]; then pause; fi
  return 0
}

server_test_flow() { # server_test_flow [quiet]
  local quiet=0
  if [[ "${1:-}" == "quiet" || "${1:-}" == "1" ]]; then quiet=1; fi
  CHK_PASS=0; CHK_FAIL=0
  banner
  menu_title "Server test"

  if [[ "${EUID}" -ne 0 ]]; then
    warn "Deep server tests must run ON the VPS:  ssh root@YOUR_VPS_IP  then  sudo bash $0"
    if client_state_load && [[ -n "${CLIENT_RELAY_URL:-}" ]]; then
      local base url code
      base="${CLIENT_RELAY_URL%/tunnel}"
      url="${base%/}/healthz"
      if command_exists curl; then
        code="$(curl -k -m 8 -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
        if [[ "$code" =~ ^[2345][0-9][0-9]$ ]]; then
          chk_pass "your VPS relay answered from HERE through the internet: HTTP ${code}"
        else
          chk_fail "your VPS relay at ${url} did not answer (from this network)"
        fi
      fi
    else
      info "(No client state found here, so no remote relay probe was possible.)"
    fi
    printf "\n%sServer test: %s passed, %s failed.%s\n" "$BOLD" "$CHK_PASS" "$CHK_FAIL" "$RESET"
    if [[ $quiet -eq 0 ]]; then pause; fi
    return 0
  fi

  load_state
  info "Running the deep server checks..."
  if systemctl is-active --quiet goose-relay; then
    chk_pass "goose-relay service is active"
  else
    chk_fail "goose-relay service is NOT active (see: journalctl -u goose-relay -n 30)"
  fi
  if [[ "${GOOSE_MODE:-http}" == "tls" ]]; then
    if systemctl is-active --quiet haproxy; then
      chk_pass "haproxy is active"
    else
      chk_fail "haproxy is NOT active (see: journalctl -u haproxy -n 30)"
    fi
  fi
  if [[ "${GOOSE_MODE:-http}" == "tls" ]] && [[ -n "${GOOSE_DOMAIN:-}" ]]; then
    if [[ -f "${HAPROXY_CERT_DIR}/${GOOSE_DOMAIN}.pem" ]]; then
      chk_pass "HAProxy certificate exists for ${GOOSE_DOMAIN}"
      if command_exists openssl; then
        local end left
        end="$(openssl x509 -enddate -noout -in "${HAPROXY_CERT_DIR}/${GOOSE_DOMAIN}.pem" 2>/dev/null | cut -d= -f2)"
        if [[ -n "$end" ]]; then
          left=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
          if [[ $left -ge 14 ]]; then
            chk_pass "certificate valid for ${left} more days"
          elif [[ $left -ge 0 ]]; then
            warn "certificate expires in ${left} days - run menu 9 -> TLS certificates -> renew"
          else
            chk_fail "certificate EXPIRED ${left} days ago - renew it (menu 9 -> TLS)"
          fi
        fi
      fi
    else
      chk_fail "HAProxy certificate missing for ${GOOSE_DOMAIN}"
    fi
  fi
  if [[ -x "$GOOSE_BIN" ]]; then
    chk_pass "server binary present ($GOOSE_BIN)"
  else
    chk_fail "server binary missing ($GOOSE_BIN)"
  fi
  if [[ -f "$GOOSE_CONFIG" ]]; then
    chk_pass "server config present ($GOOSE_CONFIG)"
  else
    chk_fail "server config missing ($GOOSE_CONFIG)"
  fi
  local fmode
  fmode="$(stat -c %a "$GOOSE_KEY_FILE" 2>/dev/null || echo missing)"
  if [[ "$fmode" == "600" ]]; then
    chk_pass "tunnel key file permissions are 600"
  else
    chk_fail "tunnel key file perms are '${fmode}' (want 600)"
  fi
  local bcode
  bcode="$(curl -s -m 6 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GOOSE_BACKEND_PORT:-9444}/healthz" 2>/dev/null || true)"
  if [[ "$bcode" =~ ^[2345][0-9][0-9]$ ]]; then
    chk_pass "backend answers on 127.0.0.1:${GOOSE_BACKEND_PORT:-9444} (HTTP ${bcode})"
  else
    chk_fail "backend did not answer on 127.0.0.1:${GOOSE_BACKEND_PORT:-9444}"
  fi
  if [[ "${GOOSE_MODE:-http}" == "tls" && -n "${GOOSE_DOMAIN:-}" ]] && command_exists curl; then
    local pcode
    pcode="$(curl -k -m 8 -s -o /dev/null -w '%{http_code}' "https://${GOOSE_DOMAIN}:${GOOSE_PUBLIC_PORT:-8443}/healthz" 2>/dev/null || true)"
    if [[ "$pcode" =~ ^[2345][0-9][0-9]$ ]]; then
      chk_pass "public endpoint answers: https://${GOOSE_DOMAIN}:${GOOSE_PUBLIC_PORT:-8443} (HTTP ${pcode})"
    else
      chk_fail "public endpoint did not answer (firewall/DNS/haproxy?)"
    fi
  fi

  printf "\n%sServer test: %s passed, %s failed.%s\n" "$BOLD" "$CHK_PASS" "$CHK_FAIL" "$RESET"
  if [[ $CHK_FAIL -gt 0 ]] && command_exists journalctl; then
    printf "Last 5 goose-relay log lines:\n"
    journalctl -u goose-relay -n 5 --no-pager 2>/dev/null | sed 's/^/  /' || true
  fi
  if [[ $quiet -eq 0 ]]; then pause; fi
  return 0
}

test_menu() {
  local c
  while true; do
    banner
    menu_title "Test"
    printf " 1) Server test   (run ON the VPS for deep checks)\n"
    printf " 2) Client test   (run on a PC / in Termux)\n"
    printf " b) Back\n"
    printf " 0) Exit\n\n"
    ask_line c "Choice: "
    case "$c" in
      1) server_test_flow || true; pause ;;
      2) client_test_flow || true; pause ;;
      b|B) return 0 ;;
      0) ok "Exit."; exit 0 ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}

# =====================================================================
#  DOCTOR — one-key diagnosis (menu item 6)
# =====================================================================

doctor_flow() {
  banner
  menu_title "Doctor - one-key diagnosis"
  info "Plan: internet -> Google edges -> client -> VPS (seen from here) -> advice."
  if command_exists curl; then
    local realip
    realip="$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "$realip" ]]; then
      ok "Internet: reachable (your public IPv4: ${realip})"
    else
      fail "Internet check failed - no direct web access on IPv4."
    fi
  else
    warn "curl missing - install it for a full diagnosis."
  fi
  if command_exists ip && ip link show singbox_tun >/dev/null 2>&1; then
    warn "A v2rayN/sing-box TUN is ON - turn it off before using goose (Rule #1)."
  fi
  probe_edges
  client_test_flow compact || true
  if client_state_load && [[ -n "${CLIENT_RELAY_URL:-}" ]]; then
    local base code
    base="${CLIENT_RELAY_URL%/tunnel}"
    if command_exists curl; then
      code="$(curl -k -m 8 -s -o /dev/null -w '%{http_code}' "${base%/}/healthz" 2>/dev/null || true)"
      if [[ "$code" =~ ^[2345][0-9][0-9]$ ]]; then
        ok "Your VPS relay answered from here: HTTP ${code} (${base%/})"
      else
        warn "VPS relay did NOT answer from here (down, DNS, or blocked): ${base%/}"
      fi
    fi
  fi
  printf "\n%sQUICK REMEDIES:%s\n" "$BOLD" "$RESET"
  printf " - client will not start on PC  -> close v2rayN TUN (Rule #1), then ./start-goose.sh\n"
  printf " - 'blacklisted 3s' lines       -> normal; worry only if stats bytes stay 0\n"
  printf " - 'HTTP 404 via AKfycb...'     -> deployment not 'Anyone'; redeploy web app\n"
  printf " - want more speed/quota        -> add a 2nd deployment (2nd Google account)\n"
  printf " - worst case                   -> menu 6 Doctor again, then read GUIDE.txt\n"
  pause
}

# =====================================================================
#  IPv4-ONLY HELPER (VPS, menu item 7)
# =====================================================================

ipv4_only_flow() {
  banner
  menu_title "IPv4-only helper (VPS)"
  if ! require_root; then pause; return 1; fi
  info "Some providers (OVH etc.) advertise IPv6 that is dead: every connection"
  info "tries both families and half the dials fail. Making the VPS IPv4-only is"
  info "the fastest + most stable path. (Already applied live with success.)"
  local cur code6
  cur="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)"
  if [[ "$cur" == "1" ]]; then
    ok "This VPS is already IPv4-only. Nothing to do."
    pause
    return 0
  fi
  if command_exists curl; then
    code6="$(curl -6 -s --max-time 5 -o /dev/null -w '%{http_code}' https://api64.ipify.org 2>/dev/null || true)"
    if [[ "$code6" =~ ^[2345][0-9][0-9]$ ]]; then
      warn "IPv6 answered here (HTTP ${code6}) - disabling it is still safe for goose."
    else
      info "IPv6 is indeed broken from this VPS (no answer) - the fix will help."
    fi
  fi
  if ! ask_yes_no "Disable IPv6 now (writes /etc/sysctl.d/99-gooserelay-ipv4-only.conf)?"; then
    info "Cancelled."
    return 0
  fi
  sudo tee /etc/sysctl.d/99-gooserelay-ipv4-only.conf >/dev/null <<'EOF'
# GooseRelayVPN: IPv4-only VPS (dead IPv6 was causing dial failures)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  run_step "Applying sysctl rules" sysctl --system
  if systemctl is-active --quiet goose-relay; then
    run_step "Restarting goose-relay" systemctl restart goose-relay
  fi
  if systemctl is-active --quiet haproxy; then
    run_step "Restarting haproxy" systemctl restart haproxy
  fi
  ok "Done. VPS is now IPv4-only."
  info "To undo:  sudo rm /etc/sysctl.d/99-gooserelay-ipv4-only.conf && sudo sysctl --system"
  pause
  return 0
}

# =====================================================================
#  STATUS (menu item 8)
# =====================================================================

status_menu() {
  banner
  menu_title "Status & health"
  if [[ "${EUID}" -eq 0 ]] && command_exists systemctl; then
    load_state
    printf "Server: mode=%s domain=%s public_port=%s config=%s\n" \
      "${GOOSE_MODE:-unknown}" "${GOOSE_DOMAIN:-none}" "${GOOSE_PUBLIC_PORT:-?}" "$GOOSE_CONFIG"
    if systemctl is-active --quiet goose-relay; then
      ok "goose-relay: active"
    else
      warn "goose-relay: NOT active"
    fi
    if [[ "${GOOSE_MODE:-http}" == "tls" ]]; then
      if systemctl is-active --quiet haproxy; then
        ok "haproxy: active"
      else
        warn "haproxy: NOT active"
      fi
    fi
  else
    printf "%s(server details need root on the VPS: sudo bash %s)%s\n" "$DIM" "$0" "$RESET"
  fi

  local homes=() p
  for p in "$CLIENT_HOME" "$ANDROID_HOME"; do
    if [[ -f "$p/client_config.json" ]]; then homes+=("$p"); fi
  done
  if [[ "${#homes[@]}" -gt 0 ]]; then
    printf "\nClients found:\n"
    local running="no"
    if command_exists pgrep && pgrep -x goose-client >/dev/null 2>&1; then running="YES"; fi
    if command_exists ss && ss -tln 2>/dev/null | grep -q ":1080 "; then running="YES (listening on 1080)"; fi
    for p in "${homes[@]}"; do
      printf "  - %s\n" "$p"
    done
    printf "Client running: %s\n" "$running"
  else
    printf "\nNo client folders found on this machine yet.\n"
  fi
  pause
}

# =====================================================================
#  ADVANCED (menu item 9): v1 power tools + updates
# =====================================================================

update_server_flow() {
  if ! require_root; then pause; return 1; fi
  load_state
  local url="${GOOSE_DOWNLOAD_URL:-$SERVER_URL}"
  local workdir tarball topdir extracted newbin
  workdir="$(mktemp -d)"
  tarball="${workdir}/srv.tar.gz"
  run_step "Downloading server archive" wget -O "$tarball" "$url"
  run_step "Checking archive" tar -tzf "$tarball"
  tar -xzf "$tarball" -C "$workdir"
  topdir="$(awk -F/ 'NF {print $1; exit}' <(tar -tzf "$tarball"))"
  extracted="${workdir}/${topdir}"
  [[ -d "$extracted" ]] || extracted="$workdir"
  newbin="$(find "$extracted" -maxdepth 2 -type f -name 'goose-server' | head -n 1)"
  if [[ -z "$newbin" ]]; then
    fail "No goose-server in the archive."; rm -rf "$workdir"; return 1
  fi
  if systemctl is-active --quiet goose-relay; then
    run_step "Stopping service for update" systemctl stop goose-relay
  fi
  cp "$newbin" "$GOOSE_BIN"
  chmod 755 "$GOOSE_BIN"
  rm -rf "$workdir"
  run_step "Starting updated service" systemctl restart goose-relay
  ok "Server binary updated (config and tunnel key untouched)."
  info "Run Test -> Server test to confirm all green."
  pause
}

update_client_flow() {
  local homes=() p
  for p in "$CLIENT_HOME" "$ANDROID_HOME"; do
    if [[ -f "$p/client_config.json" ]]; then homes+=("$p"); fi
  done
  if [[ "${#homes[@]}" -eq 0 ]]; then
    info "No client installed here - nothing to update."
    pause
    return 0
  fi
  local h label url tarball extract newbin
  for h in "${homes[@]}"; do
    label=""
    if [[ -f "$h/.gooseforge-state" ]]; then
      # shellcheck disable=SC1090
      source "$h/.gooseforge-state"
      label="$CLIENT_LABEL"
      CLIENT_LABEL=""
    fi
    case "$label" in
      linux-amd64) url="$CLIENT_LINUX_URL" ;;
      android-arm64) url="$CLIENT_ANDROID_URL" ;;
      *) warn "Skipping ${h} (unknown client label '${label:-none}')."; continue ;;
    esac
    printf "\n==>%s Updating client in %s (%s)\n" "$MAGENTA" "$RESET" "$h" "$label"
    tarball="$(mktemp)"
    if ! fetch "$url" "$tarball"; then rm -f "$tarball"; continue; fi
    extract="$(mktemp -d)"
    if ! tar -xzf "$tarball" -C "$extract"; then
      fail "archive could not be extracted"; rm -f "$tarball"; rm -rf "$extract"; continue
    fi
    rm -f "$tarball"
    newbin="$(find "$extract" -maxdepth 3 -type f -name 'goose-client' | head -n 1)"
    if [[ -z "$newbin" ]]; then
      fail "no goose-client in archive"; rm -rf "$extract"; continue
    fi
    cp "$h/goose-client" "$h/goose-client.old" 2>/dev/null || true
    cp "$newbin" "$h/goose-client"
    chmod 755 "$h/goose-client"
    rm -rf "$extract"
    ok "Updated ${h}/goose-client (old one kept as goose-client.old)."
  done
  printf "\nUpdate pass done. Restart each client with: ./start-goose.sh\n"
  pause
}

advanced_menu() {
  local c
  while true; do
    banner
    menu_title "Advanced (HAProxy / TLS / ports / update)"
    printf " 1) Edit HAProxy config manually (VPS)\n"
    printf " 2) TLS certificate management (VPS)\n"
    printf " 3) Custom port/domain routing (VPS)\n"
    printf " 4) Update server binary (VPS)\n"
    printf " 5) Update client binary(ies) (this machine)\n"
    printf " b) Back\n"
    printf " 0) Exit\n\n"
    ask_line c "Choice: "
    case "$c" in
      1)
        if require_root; then haproxy_custom_menu; fi
        pause
        ;;
      2)
        if require_root; then cert_management_menu; fi
        pause
        ;;
      3)
        if require_root; then port_management_menu; fi
        pause
        ;;
      4) update_server_flow || true ;;
      5) update_client_flow || true ;;
      b|B) return 0 ;;
      0) ok "Exit."; exit 0 ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}

haclient_uninstall() { # remove client folder(s) with double confirm
  local homes=() p
  for p in "$CLIENT_HOME" "$ANDROID_HOME"; do
    if [[ -f "$p/client_config.json" ]]; then homes+=("$p"); fi
  done
  if [[ "${#homes[@]}" -eq 0 ]]; then
    info "No client folders found here."
    return 0
  fi
  local i=1 pick
  printf "Installed clients:\n"
  for p in "${homes[@]}"; do
    printf "  %s) %s\n" "$i" "$p"
    i=$((i + 1))
  done
  printf "  a) all of them\n"
  ask_line pick "Which one to remove (number / a / Enter = cancel): "
  if [[ -z "$pick" ]]; then return 0; fi
  if [[ "$pick" == "a" ]]; then
    if ask_yes_no "Really DELETE ALL listed client folders (configs and keys gone)?"; then
      for p in "${homes[@]}"; do rm -rf "$p"; done
      ok "Client folders deleted."
    fi
    return 0
  fi
  if [[ "$pick" =~ ^[0-9]+$ ]] && [[ $pick -ge 1 ]] && [[ $pick -le ${#homes[@]} ]]; then
    p="${homes[$((pick - 1))]}"
    if ask_yes_no "Really DELETE ${p} (config and key gone)?"; then
      rm -rf "$p"
      ok "Deleted ${p}"
    fi
  else
    warn "No valid choice - nothing deleted."
  fi
}

uninstall_menu() {
  local c
  while true; do
    banner
    menu_title "Uninstall"
    printf " 1) Server (VPS - removes service/config/HAProxy block)\n"
    printf " 2) Client folder(s) (this machine)\n"
    printf " b) Back\n"
    printf " 0) Exit\n\n"
    ask_line c "Choice: "
    case "$c" in
      1)
        if require_root; then uninstall_flow; fi
        pause
        ;;
      2) haclient_uninstall || true; pause ;;
      b|B) return 0 ;;
      0) ok "Exit."; exit 0 ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}

client_menu() {
  local c
  while true; do
    banner
    menu_title "Client installation"
    printf " 1) Linux amd64 (PC)\n"
    printf " 2) Android arm64 (phone / Termux)\n"
    printf " b) Back\n"
    printf " 0) Exit\n\n"
    ask_line c "Choice: "
    case "$c" in
      1) client_linux_install || true; pause ;;
      2) client_android_install || true; pause ;;
      b|B) return 0 ;;
      0) ok "Exit."; exit 0 ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}


# =====================================================================
#  v1 POWER TOOLS (kept for parity with GooseForge v1)
# =====================================================================

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
    menu_title "TLS certificate management"
    printf "1) Get certificate for domain\n"
    printf "2) Show certificate status\n"
    printf "3) Show HAProxy certificate path\n"
    printf "4) Renew certificates\n"
    printf "b) Back\n"
    printf "0) Exit\n\n"
    ask_line choice "Choice: "
    case "$choice" in
      1)
        ask_line domain "Domain: "
        if ! valid_domain "$domain"; then
          fail "Invalid domain."
          pause
          continue
        fi
        if ! command_exists certbot; then
          run_step "Installing Certbot" bash -c 'sudo apt update && sudo apt install certbot -y'
        fi
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
      b|B) return 0 ;;
      0) ok "Exit."; exit 0 ;;
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

  ask_line domain "Domain for this route: "
  if ! valid_domain "$domain"; then
    fail "Invalid domain."
    return 1
  fi
  ask_line public_port "Public port to listen on: "
  if ! valid_port "$public_port"; then
    fail "Invalid public port."
    return 1
  fi
  ask_line backend_port "Backend local port, for example 9444 or 10020: "
  if ! valid_port "$backend_port"; then
    fail "Invalid backend port."
    return 1
  fi

  use_tls="no"
  if [[ -f "${HAPROXY_CERT_DIR}/${domain}.pem" ]]; then
    use_tls="yes"
  elif ask_yes_no "No HAProxy PEM found for ${domain}. Get a cert now?"; then
    if ! command_exists certbot; then
      run_step "Installing Certbot" bash -c 'sudo apt update && sudo apt install certbot -y'
    fi
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

uninstall_flow() {
  printf "\n%sUninstall (server)%s\n" "$BOLD" "$RESET"
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

# =====================================================================
#  MAIN MENU
# =====================================================================

main_menu() {
  local choice
  while true; do
    banner
    printf " 1) Full installation %s(server + Apps Script + clients)%s\n" "$DIM" "$RESET"
    printf " 2) Server installation %s(VPS - Linux amd64)%s\n" "$DIM" "$RESET"
    printf " 3) Client installation %s(Linux amd64 + Android arm64)%s\n" "$DIM" "$RESET"
    printf " 4) Apps Script helper %s(workable Code.gs + 5 steps)%s\n" "$DIM" "$RESET"
    printf " 5) Test %s(server test / client test)%s\n" "$DIM" "$RESET"
    printf " 6) Doctor %s(one-key diagnosis)%s\n" "$DIM" "$RESET"
    printf " 7) IPv4-only helper %s(VPS fix for dead IPv6)%s\n" "$DIM" "$RESET"
    printf " 8) Status & health\n"
    printf " 9) Advanced %s(HAProxy / TLS / ports / update)%s\n" "$DIM" "$RESET"
    printf "10) Uninstall %s(server / client)%s\n" "$DIM" "$RESET"
    printf "\n%sKeys: b = Back inside submenus  |  0 = Exit program%s\n\n" "$DIM" "$RESET"
    ask_line choice "Choice: "
    case "$choice" in
      1) full_install_flow || true ;;
      2)
        menu_title "Server installation (VPS - Linux amd64)"
        if require_root; then install_flow; fi
        pause
        ;;
      3) client_menu ;;
      4) apps_script_flow || true ;;
      5) test_menu ;;
      6) doctor_flow || true ;;
      7) ipv4_only_flow || true ;;
      8) status_menu || true ;;
      9) advanced_menu ;;
      10) uninstall_menu ;;
      0) ok "Exit."; exit 0 ;;
      *) warn "Invalid choice (1-10 or 0)."; pause ;;
    esac
  done
}

err_trap() {
  if [[ "${GOOSE_TRAP_OFF:-0}" == "1" ]]; then return 0; fi
  printf "\n"
  fail "Stopped unexpectedly at line ${LINENO}."
  fail "Re-run:  bash $0     Project: ${PROJECT_URL}"
  fail "GooseForge ${VERSION} by ${AUTHOR}"
}
trap 'err_trap' ERR
trap 'printf "\n%sCancelled.%s\n" "$YELLOW" "$RESET"; exit 130' INT

GOOSE_TRAP_OFF=0
main_menu
