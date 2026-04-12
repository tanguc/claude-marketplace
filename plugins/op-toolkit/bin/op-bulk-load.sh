#!/bin/bash
# op-bulk-load.sh -- fetch all items from one or more 1Password vaults in bulk
# uses a single `op item list | op item get -` pipe per vault so the desktop CLI
# authorization dialog (or Touch ID) prompts once per vault instead of per secret
#
# usage:
#   op-bulk-load.sh                          # use vaults from config.env
#   op-bulk-load.sh Infrastructure
#   op-bulk-load.sh Infrastructure Private Personal
#   OP_TOOLKIT_VAULTS="Infrastructure Private" op-bulk-load.sh
#
# config:
#   ~/.config/op-toolkit/config.env   OP_TOOLKIT_VAULTS="..."
#
# cache layout:
#   $OP_TOOLKIT_CACHE_DIR/<vault>.json   -- jq array of full items
#   defaults to /tmp/.op-toolkit-$(id -u)/

set -euo pipefail

CONFIG_FILE="${OP_TOOLKIT_CONFIG:-$HOME/.config/op-toolkit/config.env}"
CACHE_DIR="${OP_TOOLKIT_CACHE_DIR:-/tmp/.op-toolkit-$(id -u)}"

mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR"

# load configured vaults if no args
if [ $# -eq 0 ]; then
  if [ -z "${OP_TOOLKIT_VAULTS:-}" ] && [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  # shellcheck disable=SC2206
  VAULTS=(${OP_TOOLKIT_VAULTS:-})
else
  VAULTS=("$@")
fi

if [ ${#VAULTS[@]} -eq 0 ]; then
  echo "no vaults specified" >&2
  echo "  pass them as arguments: op-bulk-load.sh Infrastructure Private" >&2
  echo "  or run: op-toolkit-init.sh" >&2
  echo "  or set OP_TOOLKIT_VAULTS env var" >&2
  exit 1
fi

command -v op >/dev/null || { echo "op CLI not found in PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found in PATH" >&2; exit 1; }

for vault in "${VAULTS[@]}"; do
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
