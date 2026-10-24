# Changelog

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
