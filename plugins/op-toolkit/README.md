# op-toolkit

Full 1Password CLI toolkit for Claude Code: bulk-cache vaults so biometric prompts hit once per session, read secrets via `op://` references, and create/edit/delete items (fields and file attachments) from YAML templates.

## Why

Every call to `op item get` triggers an auth prompt — either a Touch ID dialog or a desktop CLI authorization dialog (via `Settings → Developer → Integrate with 1Password CLI`). Both expire after 10 minutes of inactivity. In an agent loop that needs 5 secrets, that is 5 interruptions.

The cache is a JSON file in `/tmp`. Cached field reads don't call `op` after the initial warm. One prompt per vault, per session. Attachment content is not cached: an explicit `--file-output` download calls `op` inside the toolkit and may require another authorization prompt.

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

Requires: `op` 2.x, `jq`, `yq` (for `op-item-new.sh` / `op-item-edit.sh`).

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
| `op-cache-get.sh <ref>` | Read a field from cache. Auto-refreshes on miss. |
| `op-cache-get.sh --file-output OUTPUT <ref>` | Download an attachment to a new private file using warmed metadata. |
| `op-cache-clear.sh [vault...]` | Clear the cache (all or specific vaults). |
| `op-item-new.sh <template.yaml>` | Create a new item from a YAML template (fields + attachments). |
| `op-item-edit.sh <changes.yaml>` | Edit an existing item: update fields, attach files, delete fields/attachments. |
| `op-item-rm.sh <id-or-title> --vault V` | Delete an item — archive by default, `--hard` for permanent. |
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

`op://Vault/Item/field` matches 1Password's own `op read` URI scheme.

## Downloading attachments

Use the reader's file mode, not a direct `op read` call:

```bash
op-bulk-load.sh 'Example Vault'
mkdir -p "$HOME/.config/example"
chmod 700 "$HOME/.config/example"
op-cache-get.sh --file-output "$HOME/.config/example/config.json" \
  'op://Example Vault/Service Config/config.json'
```

In this mode the last reference component is a file name or file ID, not a field label.
The item can be an exact title or ID. The warmed cache must identify exactly one item and
one attachment in its `.files` metadata, with valid vault, item and file IDs. The toolkit
uses those IDs for one native `op read` invocation. Missing or ambiguous metadata fails
without refreshing or downloading; warm the vault explicitly if the metadata is stale.
`--alias`, `--refresh` and `--no-refresh` cannot be combined with `--file-output`.

The output must not exist, even as a dangling symlink. Its parent must already exist,
belong to the current user and not be group/world-writable. Symlinks anywhere in the
output directory chain and `..` path components are rejected. Ancestors must belong to
root or the current user and not be group/world-writable, except root-owned sticky
ancestors such as the system temporary directory. BSD ACLs with any `allow` entry and
GNU extended ACL markers are rejected; deny-only BSD ACLs are accepted.
On macOS `/tmp` is a symlink: use its physical path (`/private/tmp`) or obtain a physical
temporary path with `pwd -P`.

The download is staged in a private directory beside the output, then published with
native `link`, which atomically refuses any existing destination. No partial output is
published. The resulting file is mode `0600`; empty downloads fail. Attachment bytes
never go to stdout or into shell variables/arguments. Native stdout/stderr is discarded,
so failures report a generic error rather than CLI diagnostics. Staging is removed on
normal exit, failure, HUP, INT and TERM. SIGKILL or a crash can leave a private staging
directory that needs removal. The destination filesystem must support hard links, and
the native `link` command must be on `PATH` (macOS and GNU coreutils provide it).

Downloaded files are not part of the cache. `op-cache-clear.sh` does not remove them;
remove them yourself when no longer needed. These checks protect against other local
users, not root or a process running as the same user, which can already read `0600` files.

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

## Creating, editing, deleting items

`op-item-new.sh` reads a YAML template and creates the item via `op item create`. Grouped fields go under `sections:` (concealed automatically when the field name looks like `password`/`token`/`secret`/`key`); file attachments go under `files:`.

```yaml
category: login
vault: Infrastructure
title: My Service - Production
username: admin
password: generate            # or a literal value
url: https://example.com
notes: |
  Purpose: ... Rotation: every 90 days. Related: ...
sections:
  API:
    API Key: ""
files:                        # ~ is expanded, the file must exist
  "config.ovpn": ~/vpn/config.ovpn
  "Certs.CA": ~/vpn/ca.crt    # a dot in the label = op section.field
```

Validation: `title` 10+ chars, `notes` required prose, `category` must be valid. Pass `--dry-run` to print the resolved command (secrets redacted) without touching 1Password.

`op-item-edit.sh` edits an existing item with the same YAML shape — everything optional except `item` + `vault`. Only keys present are applied; `notes` replaces notesPlain wholesale. A `delete:` list removes fields or attachments by reference:

```yaml
item: opyian7xhf2bt5u44wlglwnlry   # id or exact title (or pass --item)
vault: Private
sections:
  Setup:
    folder: ~/app
files:
  "config.ovpn": ~/vpn/config.ovpn
delete:
  - "old-attachment"
  - "Section.field"
```

`op-item-rm.sh "Title" --vault V` deletes an item — archived (recoverable) by default, `--hard` to destroy permanently. All three refresh the vault cache on success and support `--dry-run`.

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
- Field reads return the requested value on stdout; attachment downloads never emit content
- Attachment outputs are new `0600` files; native diagnostics are suppressed
- Alias file: your responsibility to keep at `chmod 600`

If plaintext-on-disk is unacceptable for your threat model, use `op` directly and accept the prompts.

## Limits

- **Document** category primary content is not downloaded by this reader; it only handles `.files` attachment metadata
- **File attachments** remain metadata-only in the bulk cache; use `--file-output` to download content explicitly
- **TOTP** fields return the OTP URI (source of truth), not the live 6-digit code — use `op item get --otp` for live codes
- Item titles containing `/` break the `op://Vault/Item/field` parser (1Password's own limitation)

## Tests

Run from the repository root:

```bash
bash plugins/op-toolkit/tests/test-op-cache-get.sh
```

The tests use an isolated home/cache and a fake `op` on `PATH`. No real vault, network or
1Password session is used. They cover field-read compatibility, binary downloads,
permissions, ambiguous metadata, unsafe paths, failed reads, cleanup and destination races.

## License

[MIT](../../LICENSE)
