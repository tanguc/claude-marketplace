#!/bin/bash
# op-cache-get.sh -- look up a single secret from the cache
# auto-refreshes the vault on miss (debounced) so newly-added items are picked up
#
# usage:
#   op-cache-get.sh 'op://Vault/Item/field'
#   op-cache-get.sh --alias PVE_PASS
#   op-cache-get.sh --refresh 'op://Vault/Item/field'      # force refresh first
#   op-cache-get.sh --no-refresh 'op://Vault/Item/field'   # disable auto-refresh
#   op-cache-get.sh --file-output OUTPUT 'op://Vault/Item/FileName'
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
#   OP_TOOLKIT_PREWARM_ALL      on cold cache, pre-warm all configured vaults
#                               (default: 1; set to 0 to load only the requested vault)

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
  --file-output OUTPUT op://Vault/Item/FileName:
                 download an attachment to a new 0600 file (requires warm cache)
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

# only root and this user may change the output's directory chain
check_output_dir() {
  local dir="$1" attrs owner mode bits uid listing perms
  uid=$(id -u)
  while :; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    # mode bits don't include ACL grants; BSD lists them, GNU marks them with +
    listing=$(LC_ALL=C ls -lde "$dir" 2>/dev/null) \
      || listing=$(LC_ALL=C ls -ld "$dir" 2>/dev/null) || return 1
    if [[ "$listing" = *$'\n'* ]]; then
      [[ "$listing" != *' allow '* ]] || return 1
    else
      read -r perms _ <<< "$listing"
      [[ "$perms" != *+* ]] || return 1
    fi
    attrs=$(stat -f '%u %Lp' "$dir" 2>/dev/null) \
      || attrs=$(stat -c '%u %a' "$dir" 2>/dev/null) || return 1
    read -r owner mode <<< "$attrs"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ "$owner" = "$uid" ] || [ "$owner" = 0 ] || return 1
    bits=$((8#$mode))
    if [ "$dir" = "$1" ]; then
      [ "$owner" = "$uid" ] && [ $((bits & 0022)) -eq 0 ] || return 1
    elif [ $((bits & 0022)) -ne 0 ]; then
      # a root-owned sticky ancestor cannot unlink another user's directory
      [ "$owner" = 0 ] && [ $((bits & 01000)) -ne 0 ] || return 1
    fi
    [ "$dir" = / ] && return 0
    dir=$(dirname -- "$dir")
  done
}

download_file() (
  fail() { printf '%s\n' "$1" >&2; exit 1; }
  command -v op >/dev/null || fail 'op CLI not found in PATH'
  command -v link >/dev/null || fail 'link not found in PATH'
  [ -f "$CACHE_FILE" ] || fail 'attachment metadata missing; warm the vault cache first'

  # resolve once, with no cached values or native diagnostics reaching the terminal
  ids=$(jq -er --arg vault "$VAULT" --arg item "$ITEM" --arg file "$FIELD" '
    def valid_id: type == "string" and test("^[a-z0-9]{26}$");
    [.[] | select(.title == $item or .id == $item)]
    | if length == 1 then .[0] else error("item not unique") end
    | select(.vault.name == $vault or .vault.id == $vault)
    | . as $item
    | [.files[]? | select(.name == $file or .id == $file)]
    | if length == 1 then .[0] else error("file not unique") end
    | [$item.vault.id, $item.id, .id]
    | if all(.[]; valid_id) then join("/") else error("invalid ids") end
  ' "$CACHE_FILE" 2>/dev/null) || fail 'attachment metadata missing, ambiguous or invalid'

  [[ ! "$FILE_OUTPUT" =~ [[:cntrl:]] ]] || fail 'unsafe output path'
  case "$FILE_OUTPUT" in
    */|*/../*|../*|*/..|..|.) fail 'unsafe output path' ;;
    /*) output="$FILE_OUTPUT" ;;
    *) output="$PWD/$FILE_OUTPUT" ;;
  esac
  [[ ! "$output" =~ [[:cntrl:]] ]] || fail 'unsafe output path'
  parent=$(dirname -- "$output")
  name=$(basename -- "$output")
  check_output_dir "$parent" || fail 'unsafe output directory'
  # pin the checked parent so later pathname changes cannot redirect placement
  cd -P -- "$parent" || fail 'cannot open output directory'
  [ ! -e "./$name" ] && [ ! -L "./$name" ] || fail 'output already exists'

  umask 077
  stage=$(mktemp -d './.op-attachment.XXXXXX') || fail 'cannot create private staging directory'
  trap 'rm -rf -- "$stage" || { printf "cannot remove private staging directory\n" >&2; exit 1; }' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  (set -C; : > "$stage/content") || fail 'cannot create private staging file'
  if ! op read "op://$ids" --out-file "$stage/content" --file-mode 0600 --force >/dev/null 2>&1; then
    fail 'attachment read failed'
  fi
  [ ! -L "$stage/content" ] && [ -f "$stage/content" ] && [ -s "$stage/content" ] \
    || fail 'attachment empty or not a regular file'
  chmod 600 "$stage/content" || fail 'cannot set private file permissions'
  # link calls link(2), unlike ln/mv it never treats a raced destination as a directory
  link "$stage/content" "./$name" 2>/dev/null || fail 'cannot place attachment; output exists or hard links unavailable'
  printf 'attachment downloaded to private file\n' >&2
)

REFRESH_MODE=auto
REF=""
FILE_OUTPUT=""

[ $# -eq 0 ] && usage

case "$1" in
  --file-output)
    [ $# -eq 3 ] && [ -n "$2" ] || usage
    FILE_OUTPUT="$2"
    REF="$3"
    ;;
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

if [ -n "$FILE_OUTPUT" ]; then
  download_file
  exit $?
fi

# bootstrap if missing, or force refresh
if [ "$REFRESH_MODE" = "force" ] || [ ! -f "$CACHE_FILE" ]; then
  # cold cache (no vault files at all) and not a force-refresh? pre-warm all
  # configured vaults so subsequent cross-vault reads don't trigger more prompts.
  # opt out with OP_TOOLKIT_PREWARM_ALL=0
  prewarm="${OP_TOOLKIT_PREWARM_ALL:-1}"
  if [ "$REFRESH_MODE" != "force" ] && [ "$prewarm" = "1" ] \
     && ! ls "$CACHE_DIR"/*.json >/dev/null 2>&1; then
    "$LOADER" >&2 || "$LOADER" "$VAULT" >&2
  else
    "$LOADER" "$VAULT" >&2
  fi
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
