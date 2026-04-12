#!/bin/bash
# op-item-new.sh -- create a 1Password item from a YAML template
# enforces the structured-fields convention (sections, typed fields, prose notes)
# refreshes the vault cache after creation so the new item is immediately readable
#
# usage:
#   op-item-new.sh template.yaml
#   op-item-new.sh template.yaml --vault Personal
#   op-item-new.sh template.yaml --dry-run

set -euo pipefail

LOADER="$(dirname "$0")/op-bulk-load.sh"
VALID_CATEGORIES="login server api-credential secure-note password database"
# categories that require at least one credential field
CRED_REQUIRED_CATEGORIES="login server api-credential database"

usage() {
  cat >&2 <<EOF
usage: op-item-new.sh <template.yaml> [--dry-run] [--vault VAULT-OVERRIDE]
  template.yaml   path to a YAML item template
  --dry-run       print the op command (with secrets redacted) and exit
  --vault VAULT   override the vault set in the template
EOF
  exit 1
}

# ---- arg parsing ----
TEMPLATE=""
DRY_RUN=false
VAULT_OVERRIDE=""

[ $# -eq 0 ] && usage

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --vault)
      [ $# -ge 2 ] || { echo "error: --vault requires an argument" >&2; exit 1; }
      VAULT_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage
      ;;
    *)
      if [ -z "$TEMPLATE" ]; then
        TEMPLATE="$1"
      else
        echo "error: unexpected argument: $1" >&2
        usage
      fi
      shift
      ;;
  esac
done

[ -z "$TEMPLATE" ] && { echo "error: template file is required" >&2; usage; }

# ---- dependency check ----
command -v jq >/dev/null || { echo "jq not found in PATH" >&2; exit 1; }
command -v yq >/dev/null || {
  echo "yq not found. Install: brew install yq" >&2
  exit 1
}

# ---- validate template file ----
[ -f "$TEMPLATE" ] || { echo "error: template file not found: $TEMPLATE" >&2; exit 1; }

# ---- yaml field extraction helpers ----
yq_get() {
  yq -r "$1" "$TEMPLATE" 2>/dev/null || true
}

# yq returns "null" as a string for missing keys — normalize to empty
normalize() {
  local v="$1"
  [ "$v" = "null" ] && echo "" || echo "$v"
}

# ---- extract fields ----
TITLE=$(normalize "$(yq_get '.title')")
CATEGORY=$(normalize "$(yq_get '.category')")
VAULT=$(normalize "$(yq_get '.vault')")
URL=$(normalize "$(yq_get '.url')")
USERNAME=$(normalize "$(yq_get '.username')")
PASSWORD=$(normalize "$(yq_get '.password')")
NOTES=$(normalize "$(yq_get '.notes')")

# vault override takes precedence
[ -n "$VAULT_OVERRIDE" ] && VAULT="$VAULT_OVERRIDE"

# ---- hard validations ----
errors=()

# title: required, >= 10 chars
if [ -z "$TITLE" ]; then
  errors+=("title is required")
elif [ "${#TITLE}" -lt 10 ]; then
  errors+=("title too short (got ${#TITLE} chars, need 10+): $TITLE")
fi

# category: required, must be in allowed list
if [ -z "$CATEGORY" ]; then
  errors+=("category is required")
else
  valid_cat=false
  for c in $VALID_CATEGORIES; do
    [ "$CATEGORY" = "$c" ] && valid_cat=true && break
  done
  if [ "$valid_cat" = false ]; then
    errors+=("invalid category: $CATEGORY (allowed: $VALID_CATEGORIES)")
  fi
fi

# vault: required
[ -z "$VAULT" ] && errors+=("vault is required (set in template or pass --vault)")

# notes: required
[ -z "$NOTES" ] && errors+=("notes are required (use prose explaining purpose, rotation, related items)")

# check if sections exist — needed for cred-required validation
has_sections=false
if yq_get '.sections | keys | length' "$TEMPLATE" 2>/dev/null | grep -qE '^[1-9]'; then
  has_sections=true
fi

# for cred-required categories, at least one credential must be present
if [ -n "$CATEGORY" ]; then
  needs_cred=false
  for c in $CRED_REQUIRED_CATEGORIES; do
    [ "$CATEGORY" = "$c" ] && needs_cred=true && break
  done
  if [ "$needs_cred" = true ]; then
    if [ -z "$USERNAME" ] && [ -z "$PASSWORD" ] && [ "$has_sections" = false ]; then
      errors+=("category '$CATEGORY' requires at least one credential field (username, password, or sections)")
    fi
  fi
fi

if [ ${#errors[@]} -gt 0 ]; then
  echo "validation errors:" >&2
  for e in "${errors[@]}"; do
    echo "  - $e" >&2
  done
  exit 1
fi

# ---- soft warning on notes quality ----
notes_lower=$(echo "$NOTES" | tr '[:upper:]' '[:lower:]')
if ! echo "$notes_lower" | grep -qE '(purpose|rotation|related)'; then
  echo "warning: notes don't mention 'purpose', 'rotation', or 'related' — consider documenting all three" >&2
fi

# ---- build section field args ----
# outputs lines like: "SSH.host[text]=192.168.10.1"
# uses [concealed] for fields whose name contains password/token/secret/key
build_section_args() {
  # bash 3.2 compatible: read into newline-delimited string, iterate via while-read
  local section
  while IFS= read -r section; do
    [ -z "$section" ] || [ "$section" = "null" ] && continue

    local field
    while IFS= read -r field; do
      [ -z "$field" ] || [ "$field" = "null" ] && continue

      local value
      value=$(normalize "$(yq_get ".sections[\"$section\"][\"$field\"]")")
      [ -z "$value" ] && continue

      # choose field type based on field name
      local field_lower
      field_lower=$(echo "$field" | tr '[:upper:]' '[:lower:]')
      local ftype="text"
      if echo "$field_lower" | grep -qE '(password|token|secret|key)'; then
        ftype="concealed"
      fi

      printf '%s.%s[%s]=%s\n' "$section" "$field" "$ftype" "$value"
    done < <(yq_get ".sections[\"$section\"] | keys | .[]")
  done < <(yq_get '.sections | keys | .[]')
}

# collect section args into an array
SECTION_ARGS=()
if [ "$has_sections" = true ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && SECTION_ARGS+=("$line")
  done < <(build_section_args)
fi

# ---- build op item create command ----
CMD=(op item create
  --category "$CATEGORY"
  --vault "$VAULT"
  --title "$TITLE"
)

[ -n "$URL" ] && CMD+=(--url "$URL")

# handle password
if [ "$PASSWORD" = "generate" ]; then
  CMD+=(--generate-password='letters,digits,symbols,32')
elif [ -n "$PASSWORD" ]; then
  CMD+=("password=$PASSWORD")
fi

[ -n "$USERNAME" ] && CMD+=("username=$USERNAME")

# bash 3.2 + set -u: expand empty array safely via ${var+...}
if [ ${#SECTION_ARGS[@]} -gt 0 ]; then
  for arg in "${SECTION_ARGS[@]}"; do
    CMD+=("$arg")
  done
fi

CMD+=("notesPlain=$NOTES")

# ---- dry run: print redacted command ----
if [ "$DRY_RUN" = true ]; then
  echo "dry-run — command that would be executed:"
  for word in "${CMD[@]}"; do
    # redact concealed fields and password values
    if echo "$word" | grep -qE '\[concealed\]='; then
      field_key="${word%%=*}"
      printf '  %s=<redacted>\n' "$field_key"
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

# ---- execute ----
echo "creating item '$TITLE' in vault '$VAULT'..." >&2
result=$(op item create "${CMD[@]}" --format=json 2>&1) || {
  echo "error: op item create failed:" >&2
  echo "$result" >&2
  exit 1
}

item_id=$(echo "$result" | jq -r '.id // empty')
item_title=$(echo "$result" | jq -r '.title // empty')

# refresh vault cache
echo "refreshing vault cache for '$VAULT'..." >&2
"$LOADER" "$VAULT" >&2

# determine output reference
has_password_field=false
if echo "$result" | jq -e '.fields[] | select(.label == "password" or .purpose == "PASSWORD") | .value' >/dev/null 2>&1; then
  has_password_field=true
fi
# also true if we used --generate-password or set an explicit password
[ "$PASSWORD" = "generate" ] && has_password_field=true
[ -n "$PASSWORD" ] && [ "$PASSWORD" != "generate" ] && has_password_field=true

if [ "$has_password_field" = true ]; then
  echo "created: op://$VAULT/$item_title/password"
else
  echo "created: op://$VAULT/$item_title/"
fi
echo "cache refreshed"
