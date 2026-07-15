#!/usr/bin/env python3
"""enrich-secret.py -- SAFELY add descriptive metadata FIELDS to an OpenBao (or Vault) KV-v2 secret.

Why: a mirror that copies KV data FIELDS to another store (e.g. 1Password) only surfaces DATA, not
KV custom_metadata. So descriptive metadata that must be visible in the mirror has to be a data
field. This tool adds descriptive fields (kind, description, ...) WITHOUT ever touching the actual
secret values.

Usage:
    enrich-secret.py <path> '<json object of descriptive fields>'
    e.g. enrich-secret.py myapp/db '{"kind":"database-credential","description":"prod Postgres"}'

Config (env vars, all with sensible generic defaults -- nothing infra-specific hardcoded):
    BAO_ADDR          KV base URL (required, e.g. https://vault.example.com)   [also VAULT_ADDR]
    OP_APPROLE_FILE   age-encrypted AppRole creds json    (default ~/.config/openbao/approle.age)
    OP_AGE_IDENTITY   age private key                     (default ~/.config/sops/age/keys.txt)
    OP_APPROLE_ROLE   which role in the approle file       (default ansible-controller)
    BAO_MOUNT         KV v2 mount                          (default secret)
    BAO_SKIP_VERIFY   set to 1 to skip TLS verification (self-signed)          (default off)

Safety (this is why it is safe to hand to a sub-agent on prod secrets):
  * REFUSES any field name that looks secret-ish (password/token/credential/key/secret/...).
    A caller can NEVER add or overwrite a credential through this tool.
  * Only writes whitelisted descriptive keys.
  * Merge preserves every existing field; a new field is added, an existing descriptive field is
    updated only if its key is explicitly passed.
  * VERIFIES by read-back: every ORIGINAL field must still hold its ORIGINAL value and every new
    field must be present. Any mismatch aborts NON-ZERO; the secret is left as it was.
"""
import json
import os
import re
import subprocess
import sys

ADDR = (os.environ.get("BAO_ADDR") or os.environ.get("VAULT_ADDR") or "").rstrip("/")
APPROLE = os.path.expanduser(os.environ.get("OP_APPROLE_FILE", "~/.config/openbao/approle.age"))
AGEKEY = os.path.expanduser(os.environ.get("OP_AGE_IDENTITY", "~/.config/sops/age/keys.txt"))
ROLE = os.environ.get("OP_APPROLE_ROLE", "ansible-controller")
MOUNT = os.environ.get("BAO_MOUNT", "secret")
SKIP_VERIFY = os.environ.get("BAO_SKIP_VERIFY", "") not in ("", "0", "false")

SECRETISH = re.compile(r"(password|passphrase|token|secret|credential|private_key|api_key|"
                       r"^key$|szaeskey|unseal|root_token)", re.I)
ALLOWED = {"kind", "description", "location", "consumer", "purpose", "service", "category",
           "owner", "environment", "criticality", "notes_extra"}


def curl(method, path, token=None, body=None):
    # shell out to curl -4 (some setups sit behind an IPv4-only access gate; python urllib
    # would pick IPv6 and get a 403). curl's happy-eyeballs + -4 avoids that.
    cmd = ["curl", "-s", "-4", "--max-time", "20", "-X", method, f"{ADDR}/v1/{path}"]
    if SKIP_VERIFY:
        cmd.insert(1, "-k")
    if token:
        cmd += ["-H", f"X-Vault-Token: {token}"]
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "-d", json.dumps(body)]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=25).stdout
    return json.loads(out) if out.strip() else {}


def die(msg, code=1):
    print(f"FATAL: {msg}", file=sys.stderr)
    sys.exit(code)


def main():
    if not ADDR:
        die("set BAO_ADDR (or VAULT_ADDR) to your KV base URL", 2)
    if len(sys.argv) != 3:
        die("usage: enrich-secret.py <path> '<json fields>'", 2)
    path = sys.argv[1].strip().lstrip("/")
    if path.startswith(f"{MOUNT}/"):
        path = path[len(MOUNT) + 1:]
    try:
        new = json.loads(sys.argv[2])
    except json.JSONDecodeError as e:
        die(f"bad json: {e}", 2)
    if not isinstance(new, dict) or not new:
        die("second arg must be a non-empty json object", 2)

    for k in new:
        if k not in ALLOWED:
            die(f"field '{k}' is not an allowed metadata key {sorted(ALLOWED)}", 3)
        if SECRETISH.search(k):
            die(f"refusing to write secret-ish field '{k}'", 3)
        if not isinstance(new[k], str) or not new[k].strip():
            die(f"field '{k}' must be a non-empty string", 3)

    try:
        ident = json.loads(subprocess.run(["age", "-d", "-i", AGEKEY, APPROLE],
                                          capture_output=True, text=True).stdout)
    except json.JSONDecodeError:
        die(f"cannot decrypt approle file {APPROLE} with {AGEKEY}")
    if ROLE not in ident:
        die(f"role '{ROLE}' not in {APPROLE} (have: {sorted(ident)})")
    r = ident[ROLE]
    login = curl("POST", "auth/approle/login",
                 body={"role_id": r["role_id"], "secret_id": r["secret_id"]})
    token = (login.get("auth") or {}).get("client_token")
    if not token:
        die(f"AppRole login failed: {login}")

    cur = curl("GET", f"{MOUNT}/data/{path}", token=token)
    existing = ((cur.get("data") or {}).get("data"))
    if existing is None:
        die(f"{MOUNT}/{path} does not exist")

    merged = dict(existing)
    merged.update(new)
    for k, v in existing.items():
        if k not in new and merged.get(k) != v:
            die(f"merge would change original field '{k}' -- abort")

    curl("POST", f"{MOUNT}/data/{path}", token=token, body={"data": merged})

    back = ((curl("GET", f"{MOUNT}/data/{path}", token=token).get("data") or {}).get("data")) or {}
    for k, v in merged.items():
        if back.get(k) != v:
            die(f"read-back mismatch on '{k}' -- secret may be inconsistent!")
    for k in existing:
        if k not in back:
            die(f"original field '{k}' vanished after write!")

    added = [k for k in new if k not in existing]
    updated = [k for k in new if k in existing]
    print(f"OK {path}: added={added} updated={updated} (all {len(existing)} original fields intact)")


main()
