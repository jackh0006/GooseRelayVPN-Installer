# GooseRelayVPN-Installer (GooseForge)

**The full installer for [GooseRelayVPN](https://github.com/Kianmhz/GooseRelayVPN)** — one script that installs, tests, diagnoses, and updates *everything*: the **VPS server**, the **Linux amd64 client**, the **Android arm64 client**, and the **Apps Script forwarder**.

**Author:** jackh0006 <jackh109867@gmail.com>
**Version:** 2.0.0 — "Full installer"
**License:** MIT

---

## Quick start

On the **VPS** (Debian/Ubuntu, as root):

```bash
wget -O install.sh https://raw.githubusercontent.com/jackh0006/GooseRelayVPN-Installer/main/install.sh
bash install.sh        # choose 1) Full installation — that's it
```

On a **PC** (Linux amd64, no root needed):

```bash
bash install.sh        # choose 3) Client installation -> 1) Linux amd64
```

On a **phone** (Termux):

```bash
bash install.sh        # choose 3) Client installation -> 2) Android arm64
```

Full installation on the VPS even **packs a ready bundle** (`/root/goose-clients-bundle.tgz`) with both client folders inside — pull it with `scp`, plug in Firefox or the phone, done.

## The menu

```
 1) Full installation (server + Apps Script + clients)
 2) Server installation (VPS - Linux amd64)
 3) Client installation (Linux amd64 + Android arm64)
 4) Apps Script helper (workable Code.gs + 5 steps)
 5) Test (server test / client test)
 6) Doctor (one-key diagnosis)
 7) IPv4-only helper (VPS fix for dead IPv6)
 8) Status & health
 9) Advanced (HAProxy / TLS / ports / update)
10) Uninstall (server / client)
```

Every submenu has **`b` = Back** and **`0` = Exit**. Every question validates its answer and re-asks politely. Ctrl+D exits cleanly anywhere.

## What you get

**Server (VPS):** `goose-server` + systemd unit + **HAProxy TLS termination** on port 8443 (backend 9444) + Let's Encrypt via certbot + UFW rules + one auto-generated 256-bit tunnel key (`/root/goose_tunnel_key.txt`). Re-running over an existing GooseForge v1 installation is safe — same state file, same managed HAProxy block.

**Clients (PC + phone):** official binaries from upstream releases into **one self-contained folder** (`~/goose`, `~/goose-android`): binary + tuned `client_config.json` + `start-goose.sh` + `stop-goose.sh` + `GUIDE.txt`. No root, no system files, ever.

**The tuned client config is field-proven on a hostile hotspot:**

- `google_host` — the fastest of the 4 known Google edge IPs, **auto-tested live** during install
- `coalesce_step_ms: 25` — outgoing bursts bundle into fewer Apps Script calls (more speed, more quota headroom)
- `idle_slots_per_bucket: 2` — required minimum for single-deployment download throughput
- 3 SNIs (`www.google.com`, `mail.google.com`, `accounts.google.com`)
- AES-256-GCM end-to-end; Google's fronting edge never sees the key

**`start-goose.sh` guards the #1 real-world mistake:** if a v2rayN/sing-box **TUN mode** is capturing all traffic (double-tunneling causes the infamous connection resets), the script refuses to start, walks you through the 10-second fix, and re-checks on ENTER. Termux-safe (`ip`/`ss`/`pgrep` checks degrade gracefully where those tools don't exist).

**Apps Script helper (menu 4):** writes the official `Code.gs` forwarder with **your relay URL already substituted**, prints the 5-step deployment walkthrough (Execute as: Me / Who has access: Anyone), and can add the resulting deployment ID straight into your client configs with an automatic backup.

**Test (menu 5):** *Server test* — deep checks (services, HAProxy, certificate expiry countdown, key permissions, backend + public endpoint). *Client test* — config JSON validation, binary checks, live SOCKS5 tunnel check with your exit IP.

**Doctor (menu 6):** one keypress: internet → Google edge speed table → client health → VPS seen *from here* → ranked remedies. Built from the three most common real-world failures.

**IPv4-only helper (menu 7):** fixes providers (OVH etc.) whose advertised IPv6 is dead — previously hundreds of failed dials until the fix was applied live. Idempotent, reversible (`sudo rm /etc/sysctl.d/99-gooserelay-ipv4-only.conf`).

## Testing story

This installer was validated by an actual horror test suite, not just by reading it:

1. `bash -n` + full piped-input runs of every menu and wrong-answer path
2. **real downloads** of both client archives (amd64 + arm64) inside a sandbox, producing complete folders
3. produced `start-goose.sh` / `stop-goose.sh` verified **byte-identical** to the live, field-proven versions
4. generated configs parsed and asserted (ports, tuned values, key lengths, SNIs)
5. the arm64 binary verified as `ELF 64-bit LSB pie executable, ARM aarch64`
6. the installed client **actually booted**: `pre-flight OK` → `ready: local SOCKS5 is listening` → live fetch through the tunnel returned the VPS exit IP, HTTP 200
7. Apps Script `Code.gs` verified: relay URL substituted, anti-loop guard intact, real deployment ID injected
8. server test verified remotely against a live HAProxy+TLS endpoint (HTTP 200)
9. graceful degradation verified for every root-gated menu on a non-root machine

## Repos

- This installer: <https://github.com/jackh0006/GooseRelayVPN-Installer>
- The VPN itself (server/client releases + Apps Script source): <https://github.com/Kianmhz/GooseRelayVPN>

## Security

The tunnel key (64 hex chars) is the entire access credential — treat `client_config.json` like a password. The Apps Script is a dumb encrypted pipe; it never sees plaintext. See `GUIDE.txt` (written into every client folder) for the short security checklist, and `SECURITY.md` for reporting.

## License

MIT — © 2026 jackh0006 <jackh109867@gmail.com>. See `LICENSE`.
