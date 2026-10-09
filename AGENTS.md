# SPDX-License-Identifier: MIT
# AGENTS.md — AI contributor guide for GooseRelayVPN-Installer

You touch people's servers as root. Be conservative.

## Hard rules

1. **Never break a working installer.** `bash -n` + `shellcheck -S error`
   clean. Prefer docs over code churn; test flows mentally (no live VPS here).
2. **Upstream binary stays pinned.** `DEFAULT_DOWNLOAD_URL` +
   `DEFAULT_DOWNLOAD_SHA256` change together, with the hash confirmed on
   the upstream release page. Custom URLs require `GOOSE_SHA256` or the
   installer refuses. Never reintroduce `curl -k`.
3. **No secrets in repo.** No tunnel keys, configs, tokens. State files
   live under `/etc/gooseforge` (`700`), never in Git.
4. **Fail closed.** Firewall deny-by-default; health checks verify TLS;
   aborts must leave the system safe and say exactly how to resume.
5. **Honest provider/DPI language.** Relays hide content from local nets,
   not activity from providers. Never `unhackable / invisible / NSA-proof`.
6. **Version-proof texts.** No hardcoded versions outside code constants;
   releases cut only by tag with canonical asset names. Keep MIT.

## Workflow

- Small diffs, verification noted per change.
- End every answer with: files changed, how to verify, open risks.
  If you cannot follow a rule, stop and ask the human.
