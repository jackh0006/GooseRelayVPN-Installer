# Changelog

## v2.1.0 — "Smart idempotence + Deployment-ID manager" (2026-10-25)
Author: jackh0006 <jackh109867@gmail.com>

### Added

- **Smart "already installed?" detection** (v2.1.0 core): before any install/update/redo the installer
  detects what exists, reports a concise health summary, and offers choices with a recommendation.
  - **Client flows**: Keep (default if valid) / Update binary+scripts / Redo (timestamped .bak first)
  - **Server flows**: Keep (default) / Update binary only / Replace TLS parts / Full redo (explicit key-preservation warning)
  - **Apps Script helper**: truly idempotent — same relay URL = "nothing to change"; different URL = backup + overwrite
- **Deployment-ID manager** (Client menu → `3) Manage deployment IDs`):
  - Works with any count (1, 2, 3, 4... deployments)
  - Add: AKfycb... (~70-char validated like the real client), auto-suggests account labels (acct-b, acct-c…), refuses duplicates
  - Remove: never the last one (client needs ≥1), numbered multi-select, .bak before change
  - Rename: pick by number, new label
  - List: masked IDs (`AKfycb…last6`) + account labels
  - Smart quota advice: same account = shared 20k/day bucket; different account = doubled quota + failover
  - Optional immediate Client test to verify tunnel with new IDs
  - All edits via python3 with pre-change backups, full JSON validation, DUP/LAST/BADIDX guards
- **Server smart idempotence** in `install_flow` and Full installation:
  - Detects existing service/binary/config/key/HAProxy block/state
  - Key preservation prompt on full redo (new key BREAKS clients; default = preserve)
- **Key safety**: `GOOSE_PRESERVE_KEY` guard in `download_and_install_goose`; redo warns loudly that a new key breaks existing clients
- **Client redo** always backs up config as `client_config.json.bak.TIMESTAMP`

### Changed

- `client_common_install` rewritten to smart fresh/keep/update/redo path
- `apps_script_flow` idempotent Code.gs (same-URL check, .bak before overwrite)
- `README.md` rewritten for v2.1.0 features (smart idempotence, deployment manager, server smarts)
- `CHANGELOG.md` v2.1.0 entry

### Kept

- All v2.0.0 features: Full installation, Server, Client (Linux amd64 + Android arm64), Apps Script, Test (server/client), Doctor, IPv4-only, Status, Advanced, Uninstall
- Byte-identical parity of generated scripts with live proven versions
- Complete GooseForge v1 server stack compatibility (state file, HAProxy managed block)
- v1.7.1 upstream binaries; official Code.gs with anti-loop guard

## v2.0.0 — "Full installer" (2026-10-24)
Author: jackh0006 <jackh109867@gmail.com>

### Added

- **Full installation flow**: one menu entry installs server + Apps Script + client folders and
  finishes with an automatic server test. On the VPS it packs a ready client bundle
  (`/root/goose-clients-bundle.tgz`) containing both client folders for one-scp transfer.
- **Client installation**: brand-new no-root flows for
  - **Linux amd64** (PC) and **Android arm64** (Termux-ready folder + phone transfer sheet)
  - self-contained folder: binary + tuned config + start/stop scripts + GUIDE.txt + state file
  - automatic live testing of the 4 Google edge IPs, best one auto-picked
  - upgrade-safe: an existing `client_config.json` is offered to be kept (keys stay intact)
  - Termux-safe helpers (`ip`/`ss`/`pgrep` guards), v2rayN-TUN "Rule #1" interception
    with ENTER-recheck guidance
- **Test menu**: `a) Server test` (deep: systemd, HAProxy, certificate expiry countdown,
  key perms, backend + public endpoint) and `b) Client test` (JSON validation, binary checks,
  live SOCKS5 exit-IP check). Server test now also has a **remote mode** that probes the
  relay URL recorded in a client state file from any machine.
- **Apps Script helper**: writes the official `Code.gs` with the user's relay URL already
  substituted, prints the 5-step deployment walkthrough, and can add the deployment ID
  directly into existing `client_config.json`s (with timestamped backups). Deployment IDs are
  validated against the real Apps Script shape (`AKfycb...`, ~70 chars) matching the client's
  own validation.
- **Doctor**: one-key diagnosis (internet → edge speed table → client health → VPS seen from
  here → ranked remedies).
- **IPv4-only helper**: fixes VPSes with dead advertised IPv6 (idempotent, reversible, written
  to /etc/sysctl.d/99-gooserelay-ipv4-only.conf) — proven live against hundreds of dial
  failures.
- **Update tooling**: server binary re-download/replace/restart and client binary updates that
  keep configs and keys untouched (old binary kept as `goose-client.old`).
- Client-side uninstall menu with double confirmation; graceful degradation of every
  root-gated menu on non-root machines.

### Changed

- `README.md` rewritten for the full-installer scope; menu map, quick-start for VPS/PC/phone,
  and the testing story.
- `install.sh` hardening: EOF-safe input at every prompt (no spin loops on Ctrl+D), input
  re-ask loops, archived-extraction guards, and menu-level guards so a flow's "not found"
  result can never kill the whole program.

### Kept

- The complete proven GooseForge v1 server stack (HAProxy TLS + Let's Encrypt + systemd +
  UFW + custom routes + cert management) — **state-file and HAProxy-managed-block compatible**,
  safe to run over an existing v1 VPS.

## v1.0.0

### Added

- GooseRelayVPN installation
- HAProxy integration
- Certbot support
- Firewall automation
- Service management
- Health checks
- Port management
