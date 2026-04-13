---
name: op-toolkit
description: "Bulk-cache 1Password vaults so Claude never triggers per-secret biometric prompts. Read secrets via op:// references, create items from YAML templates. Use whenever a shell command needs an op secret OR when creating a new 1Password item."
allowed-tools:
  - Bash
---

# op-toolkit

Bulk-fetch 1Password vault(s) once per session, cache to `/tmp`, then read fields via `jq` without triggering `op` again. Also creates new items from YAML templates.

## The rule

**Never call `op item get`, `op read`, or any direct `op` fetch inline.** Always route through the bundled scripts (on `PATH` when the plugin is enabled):

```bash
# wrong
PASS=$(op item get "Proxmox VE" --fields password --reveal)

# right
PASS=$(op-cache-get.sh 'op://Infrastructure/Proxmox VE/password')
```

## First-time setup

```bash
op-toolkit-init.sh
```

Picks which vaults to cache and writes config. Run once per machine. After init, `op-bulk-load.sh` runs automatically on first `op-cache-get.sh` call.

## Reading secrets

```bash
PASS=$(op-cache-get.sh 'op://Vault/Item Title/field label')
TOKEN=$(op-cache-get.sh --alias CF_TOKEN)
```

Reference format: `op://<vault>/<item title>/<field label>` — same as 1Password's native `op read` URI scheme.

Auto-refresh-on-miss is on by default. When a key is not found and the cache is older than `OP_TOOLKIT_REFRESH_DEBOUNCE` seconds (default 30), the vault is re-fetched and the lookup retried. No manual refresh needed in normal use.

Disable: `--no-refresh`. Override debounce: `OP_TOOLKIT_REFRESH_DEBOUNCE=60`.

## Creating items

```bash
op-item-new.sh path/to/template.yaml
op-item-new.sh path/to/template.yaml --dry-run
```

YAML template schema:

```yaml
category: login          # required: login, server, api-credential, etc.
vault: Infrastructure    # required
title: My Service - Prod # required, min 10 chars
username: admin
password: ""
url: https://example.com
notes: |                 # required, prose only — not structured data
  Purpose and rotation notes here.
fields:
  - label: API Key
    type: concealed
    value: ""
```

## Commands

| Script | Purpose |
|--------|---------|
| `op-toolkit-init.sh` | one-time setup: pick vaults, write config |
| `op-bulk-load.sh [vault...]` | pre-warm cache (one biometric prompt per vault) |
| `op-cache-get.sh <ref>` | read secret from cache, auto-refresh on miss |
| `op-cache-clear.sh [vault...]` | clear all or specific vault caches |
| `op-item-new.sh <template.yaml>` | create new item from YAML template |

## Aliases

`~/.config/op-toolkit/aliases.env` — `NAME=op://...` lines. Use with `--alias NAME`.

## Cache

`/tmp/.op-toolkit-$(id -u)/` (dir 700, files 600). Cleared on reboot. Plaintext JSON. Override with `OP_TOOLKIT_CACHE_DIR`.

## Common gotchas

- `title` must be 10+ characters — shorter values fail validation
- `notes` is required and must be prose, not key-value data
- Item titles with `/` break the `op://` parser — 1Password limitation, not a bug
- `--fields` flag on `op item get` aborts stream if any item lacks the field — the bulk load script deliberately omits it

## Limits

- Document category items: metadata only, no file content
- File attachments: not downloaded, metadata only
- TOTP: returns OTP URI, not live 6-digit code

## Requirements

- `op` 2.x signed in
- `jq`
- `yq` (for `op-item-new.sh` only)
- Bash 3.2+ (scripts are compatible with the default macOS bash)
