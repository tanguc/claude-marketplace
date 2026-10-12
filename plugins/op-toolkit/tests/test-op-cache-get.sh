#!/bin/bash
set -euo pipefail

BIN=$(cd "$(dirname "$0")/../bin" && pwd -P)
ROOT=$(mktemp -d)
ROOT=$(cd "$ROOT" && pwd -P)
trap 'rm -rf -- "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/home" "$ROOT/cache" "$ROOT/out"
chmod 700 "$ROOT" "$ROOT/out"
export HOME="$ROOT/home"
export PATH="$ROOT/bin:$PATH"
export OP_TOOLKIT_CACHE_DIR="$ROOT/cache"
export OP_TOOLKIT_ALIAS_FILE="$ROOT/aliases.env"
export OP_TOOLKIT_CONFIG="$ROOT/config.env"
export OP_TOOLKIT_VAULTS=Synthetic
export OP_TOOLKIT_PREWARM_ALL=0
export OP_TOOLKIT_REFRESH_DEBOUNCE=0
export FIXTURE="$ROOT/fixture.json" OP_LOG="$ROOT/op.log"
export FAKE_MODE=success RACE_OUTPUT="$ROOT/out/result.bin"
VAULT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaa
ITEM_ID=bbbbbbbbbbbbbbbbbbbbbbbbbb
FILE_ID=cccccccccccccccccccccccccc
REF='op://Synthetic/Test Item/sample.bin'

cat > "$ROOT/bin/op" <<'OP'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$OP_LOG"
if [ "$1" = item ]; then
  case "$2" in
    list) printf '[]\n' ;;
    get) cat >/dev/null; cat "$FIXTURE" ;;
    *) exit 91 ;;
  esac
  exit 0
fi
[ $# -eq 7 ] && [ "$1" = read ] \
  && [ "$2" = op://aaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbb/cccccccccccccccccccccccccc ] \
  && [ "$3" = --out-file ] && [ "$5" = --file-mode ] \
  && [ "$6" = 0600 ] && [ "$7" = --force ] || exit 92
case "$4" in ./.op-attachment.*/content) ;; *) exit 93 ;; esac
[ -f "$4" ] && [ ! -L "$4" ] || exit 94
printf 'native-output-must-not-leak\n'
printf 'native-error-must-not-leak\n' >&2
printf 'fake\0attachment\n' > "$4"
case "$FAKE_MODE" in
  fail) exit 95 ;;
  empty) : > "$4" ;;
  race-file) printf 'existing\n' > "$RACE_OUTPUT" ;;
  race-dir) mkdir "$RACE_OUTPUT" ;;
  race-symlink) ln -s "$RACE_TARGET" "$RACE_OUTPUT" ;;
  symlink-content) rm "$4"; ln -s "$RACE_TARGET" "$4" ;;
  directory-content) rm "$4"; mkdir "$4" ;;
  signal) kill -TERM "$PPID" ;;
  success) ;;
  *) exit 96 ;;
esac
OP
chmod 700 "$ROOT/bin/op"
jq -n --arg vault "$VAULT_ID" --arg item "$ITEM_ID" --arg file "$FILE_ID" '
  {id:$item, title:"Test Item", vault:{id:$vault,name:"Synthetic"},
   fields:[{label:"password",value:"synthetic-field"},{label:"sample.bin",value:"not-a-file"}],
   files:[{id:$file,name:"sample.bin"}]}
' > "$FIXTURE"
printf 'fake\0attachment\n' > "$ROOT/expected.bin"
printf 'existing\n' > "$ROOT/existing.bin"
count=0
pass() { count=$((count + 1)); printf 'ok %s - %s\n' "$count" "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
reset() {
  rm -rf -- "$ROOT/out"
  mkdir "$ROOT/out"
  chmod 700 "$ROOT/out"
  jq -s '.' "$FIXTURE" > "$ROOT/cache/Synthetic.json"
  : > "$OP_LOG"
  export FAKE_MODE=success
}
run_download() {
  "$BASH" "$BIN/op-cache-get.sh" --file-output "$ROOT/out/result.bin" "$REF" \
    > "$ROOT/stdout" 2> "$ROOT/stderr"
}
check_quiet() {
  [ ! -s "$ROOT/stdout" ] || fail 'attachment emitted stdout'
  if grep -q 'must-not-leak' "$ROOT/stderr"; then fail 'native diagnostic leaked'; fi
  [ -z "$(find "$ROOT/out" -name '.op-attachment.*' -print)" ] || fail 'staging directory leaked'
}
reject() {
  if run_download; then fail "$1 accepted"; fi
  [ ! -e "$ROOT/out/result.bin" ] && [ ! -L "$ROOT/out/result.bin" ] || fail "$1 created output"
  [ ! -s "$OP_LOG" ] || fail "$1 invoked op"
  check_quiet
  pass "$1"
}

reset
[ "$("$BASH" "$BIN/op-cache-get.sh" --no-refresh 'op://Synthetic/Test Item/password')" = synthetic-field ] \
  || fail 'ordinary field changed'
[ "$("$BASH" "$BIN/op-cache-get.sh" --no-refresh 'op://Synthetic/Test Item/sample.bin')" = not-a-file ] \
  || fail 'ordinary field was treated as attachment'
printf 'TEST_PASS=op://Synthetic/Test Item/password\n' > "$OP_TOOLKIT_ALIAS_FILE"
[ "$("$BASH" "$BIN/op-cache-get.sh" --alias TEST_PASS)" = synthetic-field ] || fail 'alias changed'
[ ! -s "$OP_LOG" ] || fail 'warm field invoked op'
pass 'warm field and alias reads remain local'

reset
run_download || fail 'binary download failed'
check_quiet
cmp "$ROOT/expected.bin" "$ROOT/out/result.bin" || fail 'attachment bytes changed'
mode=$(stat -f '%Lp' "$ROOT/out/result.bin" 2>/dev/null) \
  || mode=$(stat -c '%a' "$ROOT/out/result.bin")
[ "$mode" = 600 ] || fail 'attachment permissions are not 600'
[ "$(wc -l < "$OP_LOG" | tr -d ' ')" = 1 ] || fail 'attachment used more than one native read'
pass 'binary attachment uses stable IDs, private permissions and no stdout'

reset
"$BASH" "$BIN/op-cache-get.sh" --file-output "$ROOT/out/result.bin" \
  "op://Synthetic/$ITEM_ID/$FILE_ID" > "$ROOT/stdout" 2> "$ROOT/stderr" || fail 'ID reference failed'
check_quiet
pass 'item and file IDs are accepted'

reset
(cd "$ROOT/out" && "$BASH" "$BIN/op-cache-get.sh" --file-output '-relative file.bin' "$REF") \
  > "$ROOT/stdout" 2> "$ROOT/stderr" || fail 'relative output failed'
cmp "$ROOT/expected.bin" "$ROOT/out/-relative file.bin" || fail 'relative output bytes changed'
check_quiet
pass 'relative output handles spaces and leading hyphens'

for kind in file directory symlink dangling; do
  reset
  case "$kind" in
    file) cp "$ROOT/existing.bin" "$ROOT/out/result.bin" ;;
    directory) mkdir "$ROOT/out/result.bin" ;;
    symlink) ln -s "$ROOT/existing.bin" "$ROOT/out/result.bin" ;;
    dangling) ln -s "$ROOT/missing" "$ROOT/out/result.bin" ;;
  esac
  if run_download; then fail "existing $kind accepted"; fi
  [ ! -s "$OP_LOG" ] || fail "existing $kind invoked op"
  [ "$kind" != file ] || cmp "$ROOT/existing.bin" "$ROOT/out/result.bin" || fail 'output overwritten'
  check_quiet
  pass "existing $kind is rejected before native read"
done

reset
rm "$ROOT/cache/Synthetic.json"
reject 'cold attachment cache'
reset
printf 'not-json cached-value-must-not-leak\n' > "$ROOT/cache/Synthetic.json"
reject 'invalid metadata JSON'
! grep -q 'cached-value-must-not-leak' "$ROOT/stderr" || fail 'cached value leaked'
reset
jq '[.[0],.[0]]' "$ROOT/cache/Synthetic.json" > "$ROOT/changed.json"
mv "$ROOT/changed.json" "$ROOT/cache/Synthetic.json"
reject 'duplicate items'
reset
jq '.[0].files += .[0].files' "$ROOT/cache/Synthetic.json" > "$ROOT/changed.json"
mv "$ROOT/changed.json" "$ROOT/cache/Synthetic.json"
reject 'duplicate files'
reset
jq --arg file "$FILE_ID" '.[0].files += [{id:"dddddddddddddddddddddddddd",name:$file}]' \
  "$ROOT/cache/Synthetic.json" > "$ROOT/changed.json"
mv "$ROOT/changed.json" "$ROOT/cache/Synthetic.json"
if "$BASH" "$BIN/op-cache-get.sh" --file-output "$ROOT/out/result.bin" "op://Synthetic/Test Item/$FILE_ID" \
  > "$ROOT/stdout" 2> "$ROOT/stderr"; then fail 'file ID/name collision accepted'; fi
[ ! -s "$OP_LOG" ] || fail 'file ID/name collision invoked op'
check_quiet
pass 'file ID/name collisions fail closed'

for change in '.[0].files = []' '.[0].id = null' '.[0].files[0].id = 7' \
  '.[0].vault.id = "bad/id"' '.[0].vault.name = "Other"'; do
  reset
  jq "$change" "$ROOT/cache/Synthetic.json" > "$ROOT/changed.json"
  mv "$ROOT/changed.json" "$ROOT/cache/Synthetic.json"
  reject "missing or invalid metadata ($change)"
done

reset
mv "$ROOT/out" "$ROOT/real-out"
ln -s "$ROOT/real-out" "$ROOT/out"
reject 'symlink parent'
rm "$ROOT/out"
mv "$ROOT/real-out" "$ROOT/out"
reset
mkdir -p "$ROOT/real-out/nested"
ln -s "$ROOT/real-out" "$ROOT/ancestor"
if "$BASH" "$BIN/op-cache-get.sh" --file-output "$ROOT/ancestor/nested/result.bin" "$REF" \
  > "$ROOT/stdout" 2> "$ROOT/stderr"; then fail 'symlink ancestor accepted'; fi
[ ! -s "$OP_LOG" ] && [ ! -e "$ROOT/real-out/nested/result.bin" ] || fail 'symlink ancestor used'
check_quiet
pass 'symlink ancestor is rejected'
reset
chmod 777 "$ROOT/out"
reject 'writable output parent'
reset
mkdir -p "$ROOT/shared/nested"
chmod 777 "$ROOT/shared"
if "$BASH" "$BIN/op-cache-get.sh" --file-output "$ROOT/shared/nested/result.bin" "$REF" \
  > "$ROOT/stdout" 2> "$ROOT/stderr"; then fail 'writable ancestor accepted'; fi
[ ! -s "$OP_LOG" ] || fail 'writable ancestor invoked op'
check_quiet
pass 'writable non-sticky ancestor is rejected'

export NATIVE_LS
NATIVE_LS=$(command -v ls)
export ACL_DIR="$ROOT/out" FAKE_ACL=bsd-allow
cat > "$ROOT/bin/ls" <<'LS'
#!/bin/bash
if [ "${@: -1}" = "$ACL_DIR" ]; then
  case "$FAKE_ACL" in
    bsd-allow)
      printf 'drwx------@ 1 owner group 0 Jan 1 00:00 output\n 0: everyone allow add_file\n'
      exit 0 ;;
    bsd-deny)
      printf 'drwx------+ 1 owner group 0 Jan 1 00:00 output\n 0: everyone deny delete\n'
      exit 0 ;;
    gnu)
      [ "$1" != -lde ] || exit 2
      printf 'drwx------+ 1 owner group 0 Jan 1 00:00 output\n'
      exit 0 ;;
  esac
fi
exec "$NATIVE_LS" "$@"
LS
chmod 700 "$ROOT/bin/ls"
reset
reject 'BSD ACL grant, including directories with extended attributes'
reset
export FAKE_ACL=gnu
reject 'GNU extended ACL marker'
reset
export FAKE_ACL=bsd-deny
run_download || fail 'deny-only BSD ACL rejected'
check_quiet
pass 'deny-only BSD ACL remains usable'
rm "$ROOT/bin/ls"

for output in "$ROOT/out/missing/result.bin" "$ROOT/out/../result.bin" "$ROOT/out/" '' $'bad\npath'; do
  reset
  if "$BASH" "$BIN/op-cache-get.sh" --file-output "$output" "$REF" \
    > "$ROOT/stdout" 2> "$ROOT/stderr"; then fail 'invalid output accepted'; fi
  [ ! -s "$OP_LOG" ] || fail 'invalid output invoked op'
  check_quiet
  pass 'invalid or missing output directory is rejected'
done

for mode in fail empty signal symlink-content directory-content; do
  reset
  export FAKE_MODE="$mode" RACE_TARGET="$ROOT/existing.bin"
  if run_download; then fail "$mode native read accepted"; fi
  [ ! -e "$ROOT/out/result.bin" ] || fail "$mode created output"
  [ "$(< "$RACE_TARGET")" = existing ] || fail 'symlink target changed'
  check_quiet
  pass "$mode read fails without output or staging residue"
done

for mode in race-file race-dir race-symlink; do
  reset
  export FAKE_MODE="$mode" RACE_TARGET="$ROOT/real-out"
  if run_download; then fail "$mode overwrote raced output"; fi
  case "$mode" in
    race-file) cmp "$ROOT/existing.bin" "$ROOT/out/result.bin" || fail 'raced file overwritten' ;;
    race-dir) [ -z "$(ls -A "$ROOT/out/result.bin")" ] || fail 'attachment placed inside raced directory' ;;
    race-symlink) [ -L "$ROOT/out/result.bin" ] && [ ! -e "$RACE_TARGET/content" ] \
      || fail 'attachment followed raced symlink' ;;
  esac
  check_quiet
  pass "$mode cannot redirect atomic placement"
done

reset
cat > "$ROOT/bin/link" <<'LINK'
#!/bin/bash
printf 'native-error-must-not-leak\n' >&2
exit 1
LINK
chmod 700 "$ROOT/bin/link"
if run_download; then fail 'failed hard link accepted'; fi
[ ! -e "$ROOT/out/result.bin" ] || fail 'failed hard link published output'
check_quiet
pass 'hard-link failure leaves no output or staging residue'
rm "$ROOT/bin/link"

reset
run_download &
first=$!
"$BASH" "$BIN/op-cache-get.sh" --file-output "$ROOT/out/result.bin" "$REF" \
  > "$ROOT/stdout2" 2> "$ROOT/stderr2" &
second=$!
a=0; b=0
wait "$first" || a=$?
wait "$second" || b=$?
{ [ "$a" -eq 0 ] && [ "$b" -ne 0 ]; } || { [ "$b" -eq 0 ] && [ "$a" -ne 0 ]; } \
  || fail 'concurrent downloads did not produce exactly one success'
cmp "$ROOT/expected.bin" "$ROOT/out/result.bin" || fail 'concurrent output corrupted'
[ ! -s "$ROOT/stdout2" ] || fail 'concurrent read leaked stdout'
check_quiet
pass 'concurrent downloads produce exactly one success'

reset
"$BASH" "$BIN/op-cache-get.sh" --refresh 'op://Synthetic/Test Item/password' \
  > "$ROOT/stdout" 2> "$ROOT/stderr" || fail 'force refresh failed'
[ "$(< "$ROOT/stdout")" = synthetic-field ] || fail 'force-refresh field changed'
pass 'ordinary force refresh still uses the loader'
reset
jq '.[0].fields = []' "$ROOT/cache/Synthetic.json" > "$ROOT/changed.json"
mv "$ROOT/changed.json" "$ROOT/cache/Synthetic.json"
[ "$("$BASH" "$BIN/op-cache-get.sh" 'op://Synthetic/Test Item/password' 2> "$ROOT/stderr")" = synthetic-field ] \
  || fail 'ordinary auto-refresh failed'
pass 'ordinary miss still auto-refreshes'
reset
rm "$ROOT/cache/Synthetic.json"
[ "$("$BASH" "$BIN/op-cache-get.sh" 'op://Synthetic/Test Item/password' 2> "$ROOT/stderr")" = synthetic-field ] \
  || fail 'ordinary cold bootstrap failed'
pass 'ordinary cold cache still bootstraps'

printf 'passed %s tests (synthetic fixtures only)\n' "$count"
