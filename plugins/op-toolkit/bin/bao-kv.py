#!/usr/bin/env python3
"""bao-kv.py -- generic CRUD for an OpenBao / Vault KV-v2 store, over an AppRole identity.

A headless, sub-agent-safe alternative to the `bao`/`vault` CLI for the common day-to-day KV ops:
list a tree, read a secret (all fields or one), merge/replace fields, delete. Auth is an AppRole whose
creds live age-encrypted on disk (same convention as op-cache-get / enrich-secret), so nothing
interactive is ever required and no token is passed on a command line.

Usage:
    bao-kv list [prefix]              # keys directly under prefix (dirs end with /)
    bao-kv tree [prefix]             # whole subtree, indented
    bao-kv get  <path> [field]        # all fields as JSON, or one field's raw value (for scripts)
    bao-kv put  <path> k=v [k=v ...]  # MERGE fields into a secret (preserves the rest); verifies read-back
    bao-kv rm   <path>               # soft-delete the latest version
    bao-kv rm   <path> --destroy-all  # PERMANENTLY destroy all versions + metadata

  put value sources (so multiline values like PEM keys survive -- a plain k=v mangles newlines):
    k=v            literal
    k=@file        read the value from a file
    k=-            read the value from STDIN (one field only)
  put flags:
    --replace      write EXACTLY the given fields (drop every field not listed) instead of merging

Config (env vars, generic defaults -- nothing infra-specific hardcoded):
    BAO_ADDR          KV base URL, required (e.g. https://vault.example.com)     [also VAULT_ADDR]
    OP_APPROLE_FILE   age-encrypted AppRole creds json     (default ~/.config/openbao/approle.age)
    OP_AGE_IDENTITY   age private key                      (default ~/.config/sops/age/keys.txt)
    OP_APPROLE_ROLE   which role in the approle file        (default ansible-controller)
    BAO_MOUNT         KV v2 mount                           (default secret)
    BAO_SKIP_VERIFY   set to 1 to skip TLS verification (self-signed)            (default off)

The approle file is a JSON object: { "<role>": {"role_id": "...", "secret_id": "..."}, ... }.
Every write VERIFIES by read-back before reporting success -- a write that does not read back the
intended state exits non-zero.
"""
import json
import os
import subprocess
import sys

ADDR = (os.environ.get("BAO_ADDR") or os.environ.get("VAULT_ADDR") or "").rstrip("/")
APPROLE = os.path.expanduser(os.environ.get("OP_APPROLE_FILE", "~/.config/openbao/approle.age"))
AGEKEY = os.path.expanduser(os.environ.get("OP_AGE_IDENTITY", "~/.config/sops/age/keys.txt"))
ROLE = os.environ.get("OP_APPROLE_ROLE", "ansible-controller")
MOUNT = os.environ.get("BAO_MOUNT", "secret")
SKIP_VERIFY = os.environ.get("BAO_SKIP_VERIFY", "") not in ("", "0", "false")


def die(msg, code=1):
    print(f"bao-kv: {msg}", file=sys.stderr)
    sys.exit(code)


def curl(method, path, token=None, body=None):
    # curl -4: some deployments sit behind an IPv4-only access gate where python's urllib would
    # pick IPv6 and get a 403. curl's -4 avoids that. Mirrors the other op-toolkit tools.
    cmd = ["curl", "-s", "-4", "--max-time", "25", "-X", method, f"{ADDR}/v1/{path}"]
    if SKIP_VERIFY:
        cmd.insert(1, "-k")
    if token:
        cmd += ["-H", f"X-Vault-Token: {token}"]
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "-d", json.dumps(body)]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout
    return json.loads(out) if out.strip() else {}


def login():
    if not ADDR:
        die("BAO_ADDR (or VAULT_ADDR) is not set")
    if not os.path.isfile(APPROLE):
        die(f"approle file not found: {APPROLE}")
    dec = subprocess.run(["age", "-d", "-i", AGEKEY, APPROLE], capture_output=True, text=True)
    if dec.returncode != 0:
        die(f"cannot decrypt {APPROLE}: {dec.stderr.strip()[:160]}")
    try:
        creds = json.loads(dec.stdout)[ROLE]
    except (json.JSONDecodeError, KeyError):
        die(f"role {ROLE!r} not found in {APPROLE}")
    r = curl("POST", "auth/approle/login",
             body={"role_id": creds["role_id"], "secret_id": creds["secret_id"]})
    tok = (r.get("auth") or {}).get("client_token")
    if not tok:
        die(f"AppRole login failed: {json.dumps(r.get('errors') or r)[:200]}")
    return tok


def read_data(token, path):
    """Return the KV-v2 data dict, or None if the secret does not exist."""
    r = curl("GET", f"{MOUNT}/data/{path}", token)
    if r.get("errors"):
        return None
    return (r.get("data") or {}).get("data")


def cmd_list(token, prefix="", recurse=False, indent=0):
    prefix = prefix.strip("/")
    listing = curl("LIST", f"{MOUNT}/metadata/{prefix}" + ("/" if prefix else ""), token)
    keys = (listing.get("data") or {}).get("keys") or []
    if not keys and not recurse:
        if listing.get("errors"):
            die(f"list {prefix!r}: {listing['errors']}")
    for k in keys:
        full = f"{prefix}/{k}" if prefix else k
        print("  " * indent + k)
        if recurse and k.endswith("/"):
            cmd_list(token, full, recurse=True, indent=indent + 1)


def cmd_get(token, path, field=None):
    data = read_data(token, path)
    if data is None:
        die(f"secret not found: {path}", 2)
    if field is None:
        print(json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False))
    else:
        if field not in data:
            die(f"field {field!r} not present in {path} (have: {', '.join(sorted(data))})", 2)
        sys.stdout.write(str(data[field]))


def _parse_kv(arg):
    if "=" not in arg:
        die(f"bad field (expected key=value): {arg!r}")
    k, _, v = arg.partition("=")
    if v == "-":
        v = sys.stdin.read()
    elif v.startswith("@"):
        fpath = os.path.expanduser(v[1:])
        if not os.path.isfile(fpath):
            die(f"file not found for {k}: {fpath}")
        with open(fpath) as fh:
            v = fh.read()
    return k, v


def cmd_put(token, path, pairs, replace=False):
    if not pairs:
        die("put needs at least one key=value")
    new = dict(_parse_kv(p) for p in pairs)
    cur = read_data(token, path) or {}
    merged = dict(new) if replace else {**cur, **new}
    w = curl("POST", f"{MOUNT}/data/{path}", token, body={"data": merged})
    if w.get("errors"):
        die(f"write failed: {w['errors']}")
    back = read_data(token, path) or {}
    # verify: every field we intended is present with the intended value
    bad = {k: v for k, v in merged.items() if str(back.get(k)) != str(v)}
    if bad or (replace and set(back) != set(merged)):
        die(f"read-back MISMATCH after write ({path}); left as the store returned it. diff keys="
            f"{sorted(set(bad) | (set(back) ^ set(merged)))}", 3)
    verb = "replaced" if replace else "merged"
    print(f"OK {verb} {path}: {len(new)} field(s) written, {len(back)} total, read-back verified")


def cmd_rm(token, path, destroy_all=False):
    if destroy_all:
        meta = curl("GET", f"{MOUNT}/metadata/{path}", token)
        versions = list(((meta.get("data") or {}).get("versions") or {}).keys())
        curl("DELETE", f"{MOUNT}/metadata/{path}", token)
        if read_data(token, path) is not None:
            die(f"destroy did not remove {path}", 3)
        print(f"OK destroyed {path} (all {len(versions)} version(s) + metadata, permanent)")
    else:
        curl("DELETE", f"{MOUNT}/data/{path}", token)
        print(f"OK soft-deleted latest version of {path} (recover with `bao kv undelete`)")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    op, rest = argv[0], argv[1:]
    token = login()
    if op == "list":
        cmd_list(token, rest[0] if rest else "")
    elif op == "tree":
        cmd_list(token, rest[0] if rest else "", recurse=True)
    elif op == "get":
        if not rest:
            die("get needs a path")
        cmd_get(token, rest[0], rest[1] if len(rest) > 1 else None)
    elif op == "put":
        if not rest:
            die("put needs a path")
        replace = "--replace" in rest
        pairs = [a for a in rest[1:] if a != "--replace"]
        cmd_put(token, rest[0], pairs, replace=replace)
    elif op == "rm":
        if not rest:
            die("rm needs a path")
        cmd_rm(token, rest[0], destroy_all="--destroy-all" in rest)
    else:
        die(f"unknown command {op!r} (list|tree|get|put|rm)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
