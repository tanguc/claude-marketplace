#!/bin/bash
# op-cache-get.sh -- look up a single secret from the bulk cache
# never calls `op` except to bootstrap a missing vault cache (one prompt)
#
# usage:
#   op-cache-get.sh 'op://Vault/Item/field'
#   op-cache-get.sh --alias PVE_PASS
#   op-cache-get.sh --refresh 'op://Vault/Item/field'
#
# alias file (optional): ~/.config/op-bulk-cache/aliases.env
#   PVE_PASS=op://Infrastructure/Proxmox VE - VxRail #1/password
#   CF_TOKEN=op://Infrastructure/Cloudflare API Token - OpenTofu IaC/password
#
# env:
#   OP_BULK_CACHE_DIR   override cache dir
#   OP_BULK_ALIAS_FILE  override alias file path

set -euo pipefail

CACHE_DIR="${OP_BULK_CACHE_DIR:-/tmp/.op-bulk-cache-$(id -u)}"
ALIAS_FILE="${OP_BULK_ALIAS_FILE:-$HOME/.config/op-bulk-cache/aliases.env}"
LOADER="$(dirname "$0")/op-bulk-load.sh"

command -v jq >/dev/null || { echo "jq not found in PATH" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
usage: op-cache-get.sh <ref> | --alias <name> | --refresh <ref>
  ref:   op://Vault/Item/field
  alias: name in \$OP_BULK_ALIAS_FILE (default: ~/.config/op-bulk-cache/aliases.env)
EOF
  exit 1
}

resolve_alias() {
  local name="$1"
  [ -f "$ALIAS_FILE" ] || { echo "alias file not found: $ALIAS_FILE" >&2; return 1; }
  local line
  line=$(grep -E "^${name}=" "$ALIAS_FILE" | head -1) || true
  [ -z "$line" ] && { echo "unknown alias: $name" >&2; return 1; }
  printf '%s' "${line#*=}"
}

parse_ref() {
  local ref="$1"
  if [[ "$ref" =~ ^op://([^/]+)/([^/]+)/(.+)$ ]]; then
    VAULT="${BASH_REMATCH[1]}"
    ITEM="${BASH_REMATCH[2]}"
    FIELD="${BASH_REMATCH[3]}"
    return 0
  fi
  echo "invalid reference (expected op://Vault/Item/field): $ref" >&2
  return 1
}

REFRESH=0
REF=""

[ $# -eq 0 ] && usage

case "$1" in
  --alias)
    [ $# -eq 2 ] || usage
    REF=$(resolve_alias "$2") || exit 1
    ;;
  --refresh)
    [ $# -eq 2 ] || usage
    REFRESH=1
    REF="$2"
    ;;
  -h|--help) usage ;;
  op://*) REF="$1" ;;
  *) usage ;;
esac

parse_ref "$REF" || exit 1

safe=$(printf '%s' "$VAULT" | tr -c '[:alnum:]._-' '_')
CACHE_FILE="$CACHE_DIR/$safe.json"

if [ "$REFRESH" = 1 ] || [ ! -f "$CACHE_FILE" ]; then
  "$LOADER" "$VAULT" >&2
fi

VALUE=$(jq -r --arg item "$ITEM" --arg field "$FIELD" '
  [.[]
   | select(.title == $item)
   | .fields[]?
   | select((.label // "") == $field)
   | .value // empty
  ] | first // empty
' "$CACHE_FILE")

if [ -z "$VALUE" ]; then
  echo "not found: $REF (cache: $CACHE_FILE)" >&2
  exit 1
fi

printf '%s' "$VALUE"
