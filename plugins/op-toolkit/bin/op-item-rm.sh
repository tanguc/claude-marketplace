#!/bin/bash
# op-item-rm.sh -- delete a 1Password item, then refresh the vault cache.
# Archives by default (recoverable from the 1Password archive). Use --hard to
# delete permanently.
#
# usage:
#   op-item-rm.sh "Item Title" --vault Private
#   op-item-rm.sh <item-id> --vault Private --hard
#   op-item-rm.sh "Item Title" --vault Private --dry-run

set -euo pipefail

LOADER="$(dirname "$0")/op-bulk-load.sh"

usage() {
  cat >&2 <<EOF
usage: op-item-rm.sh <id-or-title> --vault VAULT [--hard] [--dry-run]
  <id-or-title>  item to remove (id or exact title)
  --vault        vault the item lives in (required)
  --hard         permanent delete (default: archive, recoverable)
  --dry-run      print what would run and exit
EOF
  exit 1
}

ITEM=""
VAULT=""
HARD=false
DRY_RUN=false

[ $# -eq 0 ] && usage

while [ $# -gt 0 ]; do
  case "$1" in
    --vault) [ $# -ge 2 ] || { echo "error: --vault requires an argument" >&2; exit 1; }; VAULT="$2"; shift 2 ;;
    --hard) HARD=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    -*) echo "error: unknown option: $1" >&2; usage ;;
    *) if [ -z "$ITEM" ]; then ITEM="$1"; else echo "error: unexpected argument: $1" >&2; usage; fi; shift ;;
  esac
done

[ -z "$ITEM" ]  && { echo "error: item id or title is required" >&2; usage; }
[ -z "$VAULT" ] && { echo "error: --vault is required" >&2; usage; }
command -v op >/dev/null || { echo "op not found in PATH" >&2; exit 1; }

CMD=(op item delete "$ITEM" --vault "$VAULT")
[ "$HARD" = false ] && CMD+=(--archive)

if [ "$DRY_RUN" = true ]; then
  echo "dry-run — command that would be executed:"
  printf '  %s\n' "${CMD[*]}"
  [ "$HARD" = false ] && echo "  (--archive: recoverable from the 1Password archive)"
  exit 0
fi

mode=$([ "$HARD" = true ] && echo "permanently deleting" || echo "archiving")
echo "$mode item '$ITEM' in vault '$VAULT'..." >&2
"${CMD[@]}" 2>&1 || { echo "error: op item delete failed" >&2; exit 1; }

echo "refreshing vault cache for '$VAULT'..." >&2
"$LOADER" "$VAULT" >&2

echo "removed: $ITEM ($([ "$HARD" = true ] && echo 'permanent' || echo 'archived'))"
echo "cache refreshed"
