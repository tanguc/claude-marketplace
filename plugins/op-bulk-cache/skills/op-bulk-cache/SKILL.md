---
name: op-bulk-cache
description: "Fetch a whole 1Password vault in one biometric prompt, then read individual secrets instantly from a /tmp cache. Use whenever a shell command needs an op secret."
allowed-tools:
  - Bash
---

# op-bulk-cache

Bulk-fetch every item from one or more 1Password vaults with a single `op` invocation, cache the result to `/tmp`, then look up individual fields via `jq` without ever hitting `op` again.

## Why

`op item get <name>` triggers a biometric prompt **every time** you lack a long-lived session. In an agent loop that needs 5 secrets, that is 5 Touch ID prompts interrupting the user. This skill cuts it to **one prompt per vault, per session** — every subsequent lookup is a local `jq` read.

## Rule

**Never call `op item get`, `op read`, or any direct `op` fetch inside ad-hoc commands.** Always route through this skill's bundled scripts (they are on `PATH` when the plugin is enabled):

```bash
# wrong
PASS=$(op item get "Proxmox VE" --fields password --reveal)

# right
PASS=$(op-cache-get.sh 'op://Infrastructure/Proxmox VE/password')
```

## Commands

All scripts are available on `PATH` while the plugin is enabled.

| Script | Purpose |
|--------|---------|
| `op-bulk-load.sh <vault> [vault...]` | Fetch full vault(s) into cache. One biometric prompt per vault. |
| `op-cache-get.sh <ref>` | Read a secret from cache. Bootstraps missing vault on demand. |
| `op-cache-get.sh --alias <NAME>` | Read via a user-defined alias (see aliases.env below). |
| `op-cache-get.sh --refresh <ref>` | Force re-fetch of the containing vault before reading. |
| `op-cache-clear.sh [vault...]` | Clear the cache (all vaults or specific ones). |

Reference format: `op://<vault>/<item title>/<field label>` — matches 1Password's own `op read` URI scheme.

## Aliases (optional)

Create `~/.config/op-bulk-cache/aliases.env` with `NAME=op://...` lines:

```
PVE_PASS=op://Infrastructure/Proxmox VE - Main/password
CF_TOKEN=op://Infrastructure/Cloudflare API Token/password
DB_URL=op://Infrastructure/Postgres/connection string
```

Then:

```bash
PASS=$(op-cache-get.sh --alias PVE_PASS)
```

## Cache layout

- Directory: `/tmp/.op-bulk-cache-$(id -u)/` (700 perms, user-only)
- Files: `<vault>.json` per vault (600 perms), jq array of full item JSON
- Lifetime: cleared on reboot (because `/tmp`); also clearable via `op-cache-clear.sh`
- Override location: set `OP_BULK_CACHE_DIR`
- Override alias file: set `OP_BULK_ALIAS_FILE`

## How it works

`op item list --vault X --format=json | op item get - --format=json` pipes every item ID into a single `op item get` invocation. `op` uses the piped vault context to fetch all items in one go — one CLI call, one biometric prompt, full JSON (all fields, all categories, concealed values revealed, custom sections preserved).

Dropping `--fields` is critical: with `--fields label=password`, any item missing that field aborts the stream. Without it, every item returns its full shape and the script moves on.

## Limits

- **Document** category items return metadata only; their file content needs `op document get`. Not handled by this skill.
- **File attachments** on regular items are not downloaded; metadata only.
- **TOTP** fields return the OTP URI (source of truth), not the live 6-digit code. Use `op item get --otp` for live codes.
- Cache is plaintext JSON on disk (inside `/tmp`, user-only). If that is unacceptable, use `op` directly and accept the prompts.
- Item titles containing `/` break the `op://Vault/Item/field` parser (1Password's own limitation).

## Requirements

- `op` — 1Password CLI 2.x or later, signed in
- `jq` — JSON query tool
- Bash 4+ (macOS ships 3.2; install via Homebrew: `brew install bash`)

## Typical session

```bash
# 1. pre-warm one or more vaults (one prompt per vault)
op-bulk-load.sh Infrastructure
op-bulk-load.sh Infrastructure Private Personal

# 2. read as many secrets as you want, zero prompts
PVE=$(op-cache-get.sh 'op://Infrastructure/Proxmox VE - Main/password')
CF=$(op-cache-get.sh --alias CF_TOKEN)
```
