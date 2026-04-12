#!/bin/bash
# op-cache-clear.sh -- wipe the op-toolkit cache
# usage:
#   op-cache-clear.sh                          # clear everything
#   op-cache-clear.sh Infrastructure Private   # clear specific vaults

set -euo pipefail

CACHE_DIR="${OP_TOOLKIT_CACHE_DIR:-/tmp/.op-toolkit-$(id -u)}"
[ -d "$CACHE_DIR" ] || { echo "no cache to clear ($CACHE_DIR)"; exit 0; }

if [ $# -eq 0 ]; then
  rm -f "$CACHE_DIR"/*.json
  echo "cleared all vault caches in $CACHE_DIR"
else
  for vault in "$@"; do
    safe=$(printf '%s' "$vault" | tr -c '[:alnum:]._-' '_')
    f="$CACHE_DIR/$safe.json"
    if [ -f "$f" ]; then
      rm -f "$f"
      echo "cleared $vault"
    else
      echo "no cache for vault '$vault'"
    fi
  done
fi
