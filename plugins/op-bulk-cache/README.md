# op-bulk-cache

Fetch a whole 1Password vault in **one** biometric prompt, then read individual secrets instantly from a `/tmp` cache via `jq`. Never trigger `op` biometric spam in a Claude Code session again.

## The problem

Every call to `op item get` triggers a Touch ID / biometric prompt when you do not have a long-lived session. In an agent loop that needs 5 secrets, that is 5 interruptions. This plugin cuts it to **one prompt per vault, per session** — every subsequent lookup is a local `jq` read on a cached JSON file.

## The trick

`op item list --vault X --format=json | op item get - --format=json` pipes every item ID in the vault into a single `op item get` invocation. It is one CLI call, one biometric prompt, full JSON for every item (all fields, all categories, concealed values revealed, custom sections preserved).

Dropping `--fields` is critical: with `--fields label=password`, any item missing that field aborts the stream. Without it, every item returns its full shape and the script moves on.

## Install

```shell
# in Claude Code:
/plugin marketplace add stanguc/tanguc-marketplace
/plugin install op-bulk-cache@tanguc
```

Requires `op` (1Password CLI ≥ 2.x) and `jq` on PATH.

## Usage

### Pre-warm one or more vaults (one prompt per vault)

```bash
op-bulk-load.sh Infrastructure
op-bulk-load.sh Infrastructure Private Personal
```

### Read a secret by reference

```bash
PASS=$(op-cache-get.sh 'op://Infrastructure/Proxmox VE/password')
```

Reference format matches 1Password's own `op read` URI scheme: `op://<vault>/<item title>/<field label>`.

### Use an alias map (optional)

Create `~/.config/op-bulk-cache/aliases.env` with `NAME=op://...` entries:

```
PVE_PASS=op://Infrastructure/Proxmox VE - Main/password
CF_TOKEN=op://Infrastructure/Cloudflare API Token/password
DB_URL=op://Infrastructure/Postgres/connection string
```

Then:

```bash
PASS=$(op-cache-get.sh --alias PVE_PASS)
TOKEN=$(op-cache-get.sh --alias CF_TOKEN)
```

### Force refresh a vault

```bash
op-cache-get.sh --refresh 'op://Infrastructure/Proxmox VE/password'
# or wipe everything:
op-cache-clear.sh
# or just specific vaults:
op-cache-clear.sh Infrastructure Private
```

## Cache layout

- **Directory:** `/tmp/.op-bulk-cache-$(id -u)/` (700 perms, user-only)
- **Files:** `<vault>.json` per vault (600 perms), jq array of full item JSON
- **Lifetime:** cleared on reboot (because `/tmp`); also clearable via `op-cache-clear.sh`
- **Override location:** set `OP_BULK_CACHE_DIR`
- **Override alias file:** set `OP_BULK_ALIAS_FILE`

## Security

- Cache files are `chmod 600`, cache dir is `chmod 700`, user-only
- Secrets are plaintext JSON on disk (inside `/tmp`)
- Scripts never echo secret values to stdout except the final lookup result
- Alias file should also be `chmod 600` (your responsibility)

If plaintext-on-disk is unacceptable for your threat model, use `op` directly and accept the prompts.

## Limits

- **Document** category items return metadata only; their file content needs `op document get`
- **File attachments** on regular items are not downloaded; metadata only
- **TOTP** fields return the OTP URI (source of truth), not the live 6-digit code — use `op item get --otp` for live codes
- Item titles containing `/` break the `op://Vault/Item/field` parser (1Password's own limitation)

## Scripts

| Script | Purpose |
|--------|---------|
| `op-bulk-load.sh <vault>...` | Fetch full vault(s) into cache. One biometric prompt per vault. |
| `op-cache-get.sh <ref>` | Read a secret from cache. Bootstraps vault cache on miss. |
| `op-cache-get.sh --alias <NAME>` | Read via a user-defined alias. |
| `op-cache-get.sh --refresh <ref>` | Force re-fetch of the containing vault before reading. |
| `op-cache-clear.sh [vault...]` | Clear the cache (all or specific). |

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `OP_BULK_CACHE_DIR` | `/tmp/.op-bulk-cache-$(id -u)` | Where cache files live |
| `OP_BULK_ALIAS_FILE` | `~/.config/op-bulk-cache/aliases.env` | Alias map location |
| `OP_BULK_VAULTS` | (unset) | Default vault list if `op-bulk-load.sh` is called with no args |

## License

[MIT](../../LICENSE)
