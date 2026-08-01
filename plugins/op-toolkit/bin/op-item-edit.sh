#!/bin/bash
# op-item-edit.sh -- edit an existing 1Password item from a YAML template
# updates fields/sections, attaches files, deletes fields/attachments, then
# refreshes the vault cache so the change is immediately readable.
#
# usage:
#   op-item-edit.sh changes.yaml
#   op-item-edit.sh changes.yaml --item <id-or-title> --vault Private
#   op-item-edit.sh changes.yaml --dry-run
#
# YAML schema (every top-level key is optional except item + vault):
#   item: opyian7xhf2bt5u44wlglwnlry   # id or exact title (or pass --item)
#   vault: Private                     # (or pass --vault)
#   title: New Title                   # rename
#   url: https://...
#   username: newuser
#   password: newsecret                # or "generate"
#   notes: |                           # REPLACES notesPlain wholesale
#     ...
#   sections:                          # add/update fields (concealed if name ~ password/token/secret/key)
#     Setup:
#       folder: ~/.surfshark-vpn/
#   files:                             # attach; a dot in the label = op section.field
#     "WireGuard config": ~/.surfshark-vpn/wireguard.conf
#   delete:                            # remove fields/attachments by reference
#     - "test-attach"
#     - "Archive.wireguard-mai2026"

set -euo pipefail

LOADER="$(dirname "$0")/op-bulk-load.sh"

usage() {
  cat >&2 <<EOF
usage: op-item-edit.sh <changes.yaml> [--item ID-OR-TITLE] [--vault VAULT] [--dry-run]
  changes.yaml   YAML describing the edits (see header for schema)
  --item         target item by id or exact title (overrides 'item:' in yaml)
  --vault        vault of the item (overrides 'vault:' in yaml)
  --dry-run      print the op command (secrets redacted) and exit
EOF
  exit 1
}

TEMPLATE=""
DRY_RUN=false
ITEM_OVERRIDE=""
VAULT_OVERRIDE=""

[ $# -eq 0 ] && usage

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --item)  [ $# -ge 2 ] || { echo "error: --item requires an argument" >&2; exit 1; }; ITEM_OVERRIDE="$2"; shift 2 ;;
    --vault) [ $# -ge 2 ] || { echo "error: --vault requires an argument" >&2; exit 1; }; VAULT_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "error: unknown option: $1" >&2; usage ;;
    *)
      if [ -z "$TEMPLATE" ]; then TEMPLATE="$1"; else echo "error: unexpected argument: $1" >&2; usage; fi
      shift ;;
  esac
done

[ -z "$TEMPLATE" ] && { echo "error: changes file is required" >&2; usage; }
[ -f "$TEMPLATE" ] || { echo "error: changes file not found: $TEMPLATE" >&2; exit 1; }

command -v jq >/dev/null || { echo "jq not found in PATH" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq not found. Install: brew install yq" >&2; exit 1; }

yq_get() { yq -r "$1" "$TEMPLATE" 2>/dev/null || true; }
normalize() { [ "$1" = "null" ] && echo "" || echo "$1"; }
expand_tilde() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

ITEM=$(normalize "$(yq_get '.item')")
VAULT=$(normalize "$(yq_get '.vault')")
TITLE=$(normalize "$(yq_get '.title')")
URL=$(normalize "$(yq_get '.url')")
USERNAME=$(normalize "$(yq_get '.username')")
PASSWORD=$(normalize "$(yq_get '.password')")
NOTES=$(normalize "$(yq_get '.notes')")

[ -n "$ITEM_OVERRIDE" ] && ITEM="$ITEM_OVERRIDE"
[ -n "$VAULT_OVERRIDE" ] && VAULT="$VAULT_OVERRIDE"

[ -z "$ITEM" ]  && { echo "error: item is required (set 'item:' in yaml or pass --item)" >&2; exit 1; }
[ -z "$VAULT" ] && { echo "error: vault is required (set 'vault:' in yaml or pass --vault)" >&2; exit 1; }

# ---- sections -> assignment args (concealed if name looks secret) ----
build_section_args() {
  local section field value field_lower ftype
  while IFS= read -r section; do
    [ -z "$section" ] || [ "$section" = "null" ] && continue
    while IFS= read -r field; do
      [ -z "$field" ] || [ "$field" = "null" ] && continue
      value=$(normalize "$(yq_get ".sections[\"$section\"][\"$field\"]")")
      [ -z "$value" ] && continue
      field_lower=$(echo "$field" | tr '[:upper:]' '[:lower:]')
      ftype="text"
      echo "$field_lower" | grep -qE '(password|token|secret|key)' && ftype="concealed"
      printf '%s.%s[%s]=%s\n' "$section" "$field" "$ftype" "$value"
    done < <(yq_get ".sections[\"$section\"] | keys | .[]")
  done < <(yq_get '.sections | keys | .[]')
}

# ---- files -> attachment args ----
build_file_args() {
  local label path
  while IFS= read -r label; do
    [ -z "$label" ] || [ "$label" = "null" ] && continue
    path=$(normalize "$(yq_get ".files[\"$label\"]")")
    [ -z "$path" ] && continue
    path=$(expand_tilde "$path")
    [ -f "$path" ] || { echo "error: attachment file not found for '$label': $path" >&2; exit 1; }
    printf '%s[file]=%s\n' "$label" "$path"
  done < <(yq_get '.files | keys | .[]')
}

# ---- delete list -> [delete] args ----
build_delete_args() {
  local ref
  while IFS= read -r ref; do
    [ -z "$ref" ] || [ "$ref" = "null" ] && continue
    printf '%s[delete]=\n' "$ref"
  done < <(yq_get '.delete | .[]')
}

SECTION_ARGS=(); FILE_ARGS=(); DELETE_ARGS=()
if yq_get '.sections | keys | length' 2>/dev/null | grep -qE '^[1-9]'; then
  while IFS= read -r l; do [ -n "$l" ] && SECTION_ARGS+=("$l"); done < <(build_section_args)
fi
if yq_get '.files | keys | length' 2>/dev/null | grep -qE '^[1-9]'; then
  while IFS= read -r l; do [ -n "$l" ] && FILE_ARGS+=("$l"); done < <(build_file_args)
fi
if yq_get '.delete | length' 2>/dev/null | grep -qE '^[1-9]'; then
  while IFS= read -r l; do [ -n "$l" ] && DELETE_ARGS+=("$l"); done < <(build_delete_args)
fi

# ---- build op item edit command ----
CMD=(op item edit "$ITEM" --vault "$VAULT")
[ -n "$TITLE" ] && CMD+=(--title "$TITLE")
[ -n "$URL" ] && CMD+=(--url "$URL")
if [ "$PASSWORD" = "generate" ]; then
  CMD+=(--generate-password='letters,digits,symbols,32')
elif [ -n "$PASSWORD" ]; then
  CMD+=("password=$PASSWORD")
fi
[ -n "$USERNAME" ] && CMD+=("username=$USERNAME")

if [ ${#SECTION_ARGS[@]} -gt 0 ]; then for a in "${SECTION_ARGS[@]}"; do CMD+=("$a"); done; fi
if [ ${#FILE_ARGS[@]}   -gt 0 ]; then for a in "${FILE_ARGS[@]}";   do CMD+=("$a"); done; fi
if [ ${#DELETE_ARGS[@]} -gt 0 ]; then for a in "${DELETE_ARGS[@]}"; do CMD+=("$a"); done; fi
[ -n "$NOTES" ] && CMD+=("notesPlain=$NOTES")

# base command is 6 words (op item edit ITEM --vault VAULT); more means real edits
if [ ${#CMD[@]} -le 6 ]; then
  echo "error: no changes found in $TEMPLATE (need at least one of: title, url, username, password, sections, files, delete, notes)" >&2
  exit 1
fi

# ---- dry run ----
if [ "$DRY_RUN" = true ]; then
  echo "dry-run — command that would be executed:"
  for word in "${CMD[@]}"; do
    if echo "$word" | grep -qE '\[concealed\]='; then
      printf '  %s=<redacted>\n' "${word%%=*}"
    elif [[ "$word" == "password="* ]] && [ "$PASSWORD" != "generate" ]; then
      echo "  password=<redacted>"
    elif [[ "$word" == "notesPlain="* ]]; then
      echo "  notesPlain=<...>"
    else
      echo "  $word"
    fi
  done
  exit 0
fi

# ---- execute ---- (CMD already starts with: op item edit ITEM --vault VAULT ...)
echo "editing item '$ITEM' in vault '$VAULT'..." >&2
result=$("${CMD[@]}" --format=json 2>&1) || {
  echo "error: op item edit failed:" >&2
  echo "$result" >&2
  exit 1
}
item_title=$(echo "$result" | jq -r '.title // empty')

echo "refreshing vault cache for '$VAULT'..." >&2
"$LOADER" "$VAULT" >&2

echo "edited: op://$VAULT/${item_title:-$ITEM}/"
echo "cache refreshed"
