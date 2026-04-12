#!/bin/bash
# op-cache-get.sh -- look up a single secret from the cache
# auto-refreshes the vault on miss (debounced) so newly-added items are picked up
#
# usage:
#   op-cache-get.sh 'op://Vault/Item/field'
#   op-cache-get.sh --alias PVE_PASS
#   op-cache-get.sh --refresh 'op://Vault/Item/field'      # force refresh first
#   op-cache-get.sh --no-refresh 'op://Vault/Item/field'   # disable auto-refresh
#
# behavior:
#   1. if vault cache file does not exist, bulk-load it (one prompt)
#   2. jq lookup
#   3. if miss AND cache mtime older than $OP_TOOLKIT_REFRESH_DEBOUNCE seconds:
#        refresh the vault (one prompt) and re-lookup
#      else: error out
#
# alias file (optional): ~/.config/op-toolkit/aliases.env
#   PVE_PASS=op://Infrastructure/Proxmox VE - Main/password
#
# env:
#   OP_TOOLKIT_CACHE_DIR        override cache dir
#   OP_TOOLKIT_ALIAS_FILE       override alias file path
#   OP_TOOLKIT_REFRESH_DEBOUNCE seconds before a missed lookup is allowed to refresh
#                               (default: 30)

set -euo pipefail

CACHE_DIR="${OP_TOOLKIT_CACHE_DIR:-/tmp/.op-toolkit-$(id -u)}"
ALIAS_FILE="${OP_TOOLKIT_ALIAS_FILE:-$HOME/.config/op-toolkit/aliases.env}"
DEBOUNCE="${OP_TOOLKIT_REFRESH_DEBOUNCE:-30}"
LOADER="$(dirname "$0")/op-bulk-load.sh"

command -v jq >/dev/null || { echo "jq not found in PATH" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
usage: op-cache-get.sh <ref> | --alias <name> | --refresh <ref> | --no-refresh <ref>
  ref:           op://Vault/Item/field
  --alias NAME:  resolve via \$OP_TOOLKIT_ALIAS_FILE (default: ~/.config/op-toolkit/aliases.env)
  --refresh:     force vault refresh before lookup
  --no-refresh:  disable auto-refresh-on-miss
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

# portable mtime in seconds since epoch
file_mtime() {
  if stat -f %m "$1" 2>/dev/null; then return 0; fi    # macOS / BSD
  if stat -c %Y "$1" 2>/dev/null; then return 0; fi    # GNU / Linux
  echo 0
}

lookup() {
  jq -r --arg item "$ITEM" --arg field "$FIELD" '
    [.[]
     | select(.title == $item)
     | .fields[]?
     | select((.label // "") == $field)
     | .value // empty
    ] | first // empty
  ' "$CACHE_FILE"
}

REFRESH_MODE=auto
REF=""

[ $# -eq 0 ] && usage

case "$1" in
  --alias)
    [ $# -eq 2 ] || usage
    REF=$(resolve_alias "$2") || exit 1
    ;;
  --refresh)
    [ $# -eq 2 ] || usage
    REFRESH_MODE=force
    REF="$2"
    ;;
  --no-refresh)
    [ $# -eq 2 ] || usage
    REFRESH_MODE=never
    REF="$2"
    ;;
  -h|--help) usage ;;
  op://*) REF="$1" ;;
  *) usage ;;
esac

parse_ref "$REF" || exit 1

safe=$(printf '%s' "$VAULT" | tr -c '[:alnum:]._-' '_')
CACHE_FILE="$CACHE_DIR/$safe.json"

# bootstrap if missing, or force refresh
if [ "$REFRESH_MODE" = "force" ] || [ ! -f "$CACHE_FILE" ]; then
  "$LOADER" "$VAULT" >&2
fi

VALUE=$(lookup)

# auto-refresh-on-miss with debounce
if [ -z "$VALUE" ] && [ "$REFRESH_MODE" = "auto" ]; then
  now=$(date +%s)
  mtime=$(file_mtime "$CACHE_FILE")
  age=$((now - mtime))
  if [ "$age" -ge "$DEBOUNCE" ]; then
    echo "miss for $REF — cache age ${age}s >= debounce ${DEBOUNCE}s, refreshing vault" >&2
    "$LOADER" "$VAULT" >&2
    VALUE=$(lookup)
  else
    echo "miss for $REF — cache age ${age}s < debounce ${DEBOUNCE}s, not refreshing" >&2
  fi
fi

if [ -z "$VALUE" ]; then
  echo "not found: $REF (cache: $CACHE_FILE)" >&2
  exit 1
fi

printf '%s' "$VALUE"
