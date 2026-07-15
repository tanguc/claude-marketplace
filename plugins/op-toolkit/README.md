# op-toolkit

Full 1Password CLI toolkit for Claude Code: bulk-cache vaults so biometric prompts hit once per session, read secrets via `op://` references, and create new items from YAML templates.

## Why

Every call to `op item get` triggers an auth prompt — either a Touch ID dialog or a desktop CLI authorization dialog (via `Settings → Developer → Integrate with 1Password CLI`). Both expire after 10 minutes of inactivity. In an agent loop that needs 5 secrets, that is 5 interruptions.

The cache is a JSON file in `/tmp`. It is unaffected by idle timeouts because `op` is not involved in reads after the initial warm. One prompt per vault, per session. Every subsequent lookup is a local `jq` read.

## The trick

```bash
op item list --vault X --format=json | op item get - --format=json
```

One pipe, one prompt, full vault. `op` receives the piped item IDs and fetches everything in a single invocation — all fields, all categories, concealed values revealed, custom sections preserved.

Drop `--fields` or it will abort on any item missing that field.

## Install

```shell
/plugin marketplace add tanguc/claude-marketplace
/plugin install op-toolkit@tanguc
```

Requires: `op` 2.x, `jq`, `yq` (for `op-item-new.sh`).

## Quickstart

```bash
# 1. one-time: pick which vaults Claude should cache
op-toolkit-init.sh

# 2. (optional) explicit pre-warm
op-bulk-load.sh

# 3. read secrets — instant after first cache load
PASS=$(op-cache-get.sh 'op://Infrastructure/Proxmox/password')

# 4. create new items from a YAML template
op-item-new.sh templates/login.yaml
```

## Commands

| Script | Purpose |
|--------|---------|
| `op-toolkit-init.sh` | One-time setup: pick vaults to cache, write config |
| `op-bulk-load.sh [vault...]` | Fetch full vault(s) into cache. One biometric prompt per vault. |
| `op-cache-get.sh <ref>` | Read a secret from cache. Auto-refreshes on miss. |
| `op-cache-clear.sh [vault...]` | Clear the cache (all or specific vaults). |
| `op-item-new.sh <template.yaml>` | Create a new 1Password item from a YAML template. |
| `enrich-secret.py <path> '<json>'` | Add descriptive metadata **fields** to an OpenBao/Vault KV-v2 secret (see below). |
| `bao-kv.py <list\|tree\|get\|put\|rm>` | Generic CRUD for an OpenBao/Vault KV-v2 store over an AppRole (see below). |

## Secret metadata convention (OpenBao / Vault KV v2)

If you mirror your KV store into another vault (e.g. 1Password) for break-glass / autofill, the
mirror copies **data fields** — not the KV `custom_metadata`. So any metadata you want to *see* in
the mirror (what a secret is, what consumes it) must be a data field, not custom_metadata.

`enrich-secret.py` adds two descriptive fields to a secret so every item becomes self-describing:

- **`kind`** — a short slug. Suggested vocabulary: `camera`, `vm-root-credential`, `api-token`,
  `oauth-token`, `tunnel-token`, `ssh-key`, `deploy-key`, `encryption-key`, `disk-passphrase`,
  `backup-key`, `database-credential`, `service-admin`, `registry-credential`, `ci-token`,
  `mcp-credential`, `mailbox-credential`, `remote-desktop-credential`, `service-account-token`,
  `notification-token`, `launch-account`.
- **`description`** — one clear sentence: what it is, what it protects, what consumes it, where.

```bash
export BAO_ADDR=https://vault.example.com     # or VAULT_ADDR
enrich-secret.py myapp/db '{"kind":"database-credential","description":"prod Postgres for the billing app on vm-04, consumed by the API container"}'
```

**It is safe to hand to a sub-agent on production secrets.** By construction it:
- refuses any field name that looks secret-ish (`password`/`token`/`credential`/`key`/…) — it can
  *never* add or overwrite a credential;
- only writes whitelisted descriptive keys (`kind`, `description`, `location`, `consumer`, `purpose`,
  `category`, `owner`, `environment`, `criticality`, `notes_extra`);
- merges (never drops an existing field) and **verifies by read-back** — any mismatch aborts
  non-zero and leaves the secret untouched.

Auth is an AppRole read from an age-encrypted file (headless, no biometric): `OP_APPROLE_FILE`
(default `~/.config/openbao/approle.age`), `OP_AGE_IDENTITY` (default `~/.config/sops/age/keys.txt`),
`OP_APPROLE_ROLE` (default `ansible-controller`), `BAO_MOUNT` (default `secret`),
`BAO_SKIP_VERIFY=1` for a self-signed KV endpoint.

## bao-kv — generic KV-v2 CRUD

`bao-kv.py` is a headless, sub-agent-safe stand-in for the `bao`/`vault` CLI for everyday KV ops. It
uses the **same AppRole auth and env vars as `enrich-secret.py`** (above) — no interactive login, and
no token ever on a command line.

```bash
export BAO_ADDR=https://vault.example.com     # or VAULT_ADDR
bao-kv.py list [prefix]              # keys directly under prefix (dirs end with /)
bao-kv.py tree [prefix]              # whole subtree, indented
bao-kv.py get  myapp/db              # all fields as JSON
bao-kv.py get  myapp/db password     # one field's raw value (for scripts)
bao-kv.py put  myapp/db host=db-04 port=5432        # MERGE fields (preserves the rest)
bao-kv.py put  myapp/tls cert=@server.pem key=-     # value from a file, or from STDIN (multiline-safe)
bao-kv.py put  myapp/db host=db-05 --replace        # write EXACTLY these fields, drop the rest
bao-kv.py rm   myapp/old                            # soft-delete the latest version
bao-kv.py rm   myapp/old --destroy-all              # permanently destroy all versions + metadata
```

Unlike `enrich-secret.py` (which refuses to touch credential fields), `bao-kv put` is the **full CRUD
tool** — it can write any field, including secret values. Every write **verifies by read-back** and
exits non-zero on any mismatch. `put` defaults to a merge; `--replace` writes exactly the given set.
Value sources for `put`: `k=v` literal, `k=@file`, or `k=-` (one field from STDIN — the way to store a
PEM/multiline value without a shell mangling its newlines).

## Reference format

`op://Vault/Item/field` — matches 1Password's own `op read` URI scheme.

## Auto-refresh on miss

When `op-cache-get.sh` does not find a key in the cache, it checks the cache file's age. If older than `OP_TOOLKIT_REFRESH_DEBOUNCE` seconds (default: 30), it auto-refreshes the vault and retries the lookup.

This handles the common case where a new item was added to 1Password since the cache was last warmed. The 30-second debounce prevents typos from triggering repeated vault fetches.

Disable: pass `--no-refresh`. Override the debounce: `OP_TOOLKIT_REFRESH_DEBOUNCE=60`.

## Aliases (optional)

Create `~/.config/op-toolkit/aliases.env` with `NAME=op://...` entries:

```
PVE_PASS=op://Infrastructure/Proxmox VE - Main/password
CF_TOKEN=op://Infrastructure/Cloudflare API Token/password
DB_URL=op://Infrastructure/Postgres/connection string
```

Then:

```bash
PASS=$(op-cache-get.sh --alias PVE_PASS)
```

The alias file should be `chmod 600`.

## Creating items with YAML templates

`op-item-new.sh` reads a YAML template and creates the item via `op item create`. Example template (`templates/login.yaml`):

```yaml
category: login
vault: Infrastructure
title: My Service - Production
username: admin
password: "{{ generate | length=32 }}"
url: https://example.com
notes: |
  Created via op-toolkit template.
  Rotate every 90 days.
fields:
  - label: API Key
    type: concealed
    value: ""
```

Validation rules:
- `title` must be 10+ characters
- `notes` must be prose, not structured data
- `category` must be a valid 1Password category (`login`, `server`, `api-credential`, etc.)

Pass `--dry-run` to print the resolved template without creating anything.

See `templates/` for more examples.

## Cache layout

| Path | Perms | Purpose |
|------|-------|---------|
| `/tmp/.op-toolkit-$(id -u)/` | 700 | cache root, user-only |
| `/tmp/.op-toolkit-$(id -u)/<vault>.json` | 600 | full item JSON for one vault |

Cleared on reboot. Override with `OP_TOOLKIT_CACHE_DIR`.

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `OP_TOOLKIT_CACHE_DIR` | `/tmp/.op-toolkit-$(id -u)` | where cache files live |
| `OP_TOOLKIT_CONFIG` | `~/.config/op-toolkit/config.env` | config written by init script |
| `OP_TOOLKIT_ALIAS_FILE` | `~/.config/op-toolkit/aliases.env` | alias map location |
| `OP_TOOLKIT_VAULTS` | (unset) | default vault list for `op-bulk-load.sh` with no args |
| `OP_TOOLKIT_REFRESH_DEBOUNCE` | `30` | seconds before a cache miss triggers auto-refresh |

## Security

- Cache dir is `chmod 700`, files are `chmod 600`, user-only
- Secrets are plaintext JSON on disk in `/tmp`
- Scripts never echo secret values to stdout except the final lookup result
- Alias file: your responsibility to keep at `chmod 600`

If plaintext-on-disk is unacceptable for your threat model, use `op` directly and accept the prompts.

## Limits

- **Document** category items return metadata only; file content requires `op document get`
- **File attachments** on regular items are not downloaded; metadata only
- **TOTP** fields return the OTP URI (source of truth), not the live 6-digit code — use `op item get --otp` for live codes
- Item titles containing `/` break the `op://Vault/Item/field` parser (1Password's own limitation)

## License

[MIT](../../LICENSE)
