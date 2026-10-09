# SPDX-License-Identifier: MIT
# GooseRelayVPN Installer — Privacy Policy

This installer configures **your** server. It collects nothing for the author.

## What leaves the device during install

- **Upstream GitHub release** (`github.com/Kianmhz/GooseRelayVPN`): sees
  your IP + the pinned tarball you download. Verified by SHA-256
  (`GOOSE_SHA256`) before extraction.
- **Package mirrors + Let's Encrypt** (if used): IP/packages, domain
  validation. Certificates are public in Transparency logs.

## What stays local

- Tunnel keys (`/root/goose_tunnel_key.txt`), configs, state
  (`/etc/gooseforge`, mode `700`). Keep them `0600`, never commit or paste.
- No analytics, no telemetry, no phone-home in `install.sh`.

## Operator notes

- Your VPS provider sees sizes/timing/destinations of relayed traffic —
  a relay hides content from local networks, not activity from the provider.
- The upstream binary is third-party code you run as root: the SHA pin
  proves *which* bytes you got, not that they are safe. Review upstream
  before high-risk reliance.

Questions: open an issue (no keys, no configs).
