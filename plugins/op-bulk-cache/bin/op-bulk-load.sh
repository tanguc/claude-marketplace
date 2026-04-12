#!/bin/bash
# op-bulk-load.sh -- fetch all items from one or more 1Password vaults in bulk
# uses a single `op item list | op item get -` pipe per vault so macOS Touch ID
# prompts once per vault instead of once per secret
#
# usage:
#   op-bulk-load.sh Infrastructure
#   op-bulk-load.sh Infrastructure Private Personal
#   OP_BULK_VAULTS="Infrastructure Private" op-bulk-load.sh
#
# cache layout:
#   $OP_BULK_CACHE_DIR/<vault>.json   -- jq-friendly array of full items
#   defaults to /tmp/.op-bulk-cache-$(id -u)/
#
# env:
#   OP_BULK_CACHE_DIR   override cache dir
#   OP_BULK_VAULTS      default vault list if no args given

set -euo pipefail

CACHE_DIR="${OP_BULK_CACHE_DIR:-/tmp/.op-bulk-cache-$(id -u)}"
mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR"

if [ $# -eq 0 ]; then
  # shellcheck disable=SC2206
  VAULTS=(${OP_BULK_VAULTS:-})
else
  VAULTS=("$@")
fi

if [ ${#VAULTS[@]} -eq 0 ]; then
  echo "usage: op-bulk-load.sh <vault> [vault ...]" >&2
  echo "       or set OP_BULK_VAULTS env var" >&2
  exit 1
fi

command -v op >/dev/null || { echo "op CLI not found in PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found in PATH" >&2; exit 1; }

for vault in "${VAULTS[@]}"; do
  # sanitize vault name for filename (keep alnum/._-)
  safe=$(printf '%s' "$vault" | tr -c '[:alnum:]._-' '_')
  target="$CACHE_DIR/$safe.json"
  tmp=$(mktemp "$CACHE_DIR/.${safe}.XXXXXX")
  chmod 600 "$tmp"

  if op item list --vault "$vault" --format=json 2>/dev/null \
     | op item get - --format=json 2>/dev/null \
     | jq -s '.' > "$tmp" \
     && [ -s "$tmp" ]; then
    mv "$tmp" "$target"
    chmod 600 "$target"
    count=$(jq 'length' "$target")
    echo "loaded $count items from vault '$vault' -> $target"
  else
    rm -f "$tmp"
    echo "failed to load vault '$vault'" >&2
    exit 1
  fi
done
