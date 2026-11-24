#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mac-publish-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
mkdir -p "$temp_dir/scripts" "$temp_dir/bin" "$temp_dir/out/updates"
cp "$script_dir/publish-mac-update.sh" "$temp_dir/scripts/"
export PATH="$temp_dir/bin:$PATH"
export STATE="$temp_dir/release" EVENTS="$temp_dir/events" COMMIT
COMMIT="$(git -C "$script_dir" rev-parse HEAD)"
export ZIP=SupersEmu-0.0.25-20261123.231830.zip DMG=SupersEmu-0.0.25-20261123.231830.dmg
export ZIP_DIGEST APPCAST_DIGEST DMG_DIGEST MODE

printf zip > "$temp_dir/out/updates/$ZIP"
printf appcast > "$temp_dir/out/updates/appcast.xml"
printf notes > "$temp_dir/out/updates/${ZIP%.zip}.html"
printf dmg > "$temp_dir/out/$DMG"
file_digest() {
  local checksum
  checksum="$(shasum -a 256 < "$1")"
  echo "sha256:${checksum%% *}"
}
ZIP_DIGEST="$(file_digest "$temp_dir/out/updates/$ZIP")"
APPCAST_DIGEST="$(file_digest "$temp_dir/out/updates/appcast.xml")"
DMG_DIGEST="$(file_digest "$temp_dir/out/$DMG")"

cat > "$temp_dir/scripts/prepare-mac-appcast.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$3" == "$COMMIT" ]]
echo prepare >> "$EVENTS"
STUB
cat > "$temp_dir/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "rev-parse --verify ${COMMIT}^{commit}" ]]
echo "$COMMIT"
STUB
cat > "$temp_dir/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo "sleep $1" >> "$EVENTS"
STUB
cat > "$temp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == api && "$2" == repos/Chadillac6/SupersEmu/releases/42 ]]; then
  set -- release snapshot mac-20261123.231830
elif [[ "$*" == 'api --paginate --slurp repos/Chadillac6/SupersEmu/releases?per_page=100' ]]; then
  if [[ "$MODE" == lookup-error ]]; then
    echo '[[]]'
    echo 'HTTP 403: Resource not accessible by integration' >&2
    exit 1
  fi
  if [[ ! -s "$STATE" ]]; then
    echo '[[]]'
  elif [[ "$MODE" == newer-published ]]; then
    jq '[[.], [{draft:false,tag_name:"mac-20261124.0000"}]]' "$STATE"
  else
    jq '[[.]]' "$STATE"
  fi
  exit 0
fi
[[ "$1" == release && "$3" == mac-20261123.231830 ]]
case "$2" in
  snapshot)
    if [[ "$MODE" == vanishes ]] && jq -e --arg name "$DMG" 'any(.assets[]; .name == $name)' "$STATE" >/dev/null; then
      if grep -qx 'all assets seen' "$EVENTS"; then
        jq --arg name "$ZIP" '.assets |= map(select(.name != $name))' "$STATE"
        exit 0
      fi
      echo 'all assets seen' >> "$EVENTS"
    fi
    cat "$STATE"
    ;;
  create)
    [[ ! -s "$STATE" && " $* " == *" --target $COMMIT "* && " $* " == *" --draft "* ]]
    echo create >> "$EVENTS"
    jq -n --arg commit "$COMMIT" --arg tag "$3" \
      '{id:42,draft:true,target_commitish:$commit,tag_name:$tag,assets:[]}' > "$STATE"
    ;;
  upload)
    jq -e '.draft' "$STATE" >/dev/null
    name="${4##*/}"
    echo "upload $name" >> "$EVENTS"
    case "$name" in
      "$ZIP") digest="$ZIP_DIGEST"; size=3 ;;
      appcast.xml) digest="$APPCAST_DIGEST"; size=7 ;;
      "$DMG") digest="$DMG_DIGEST"; size=3 ;;
      *) exit 64 ;;
    esac
    [[ " $* " == *" --clobber "* ]]
    if [[ "$name" == "$DMG" ]]; then
      case "$MODE" in
        transient)
          if ! grep -qx 'sleep 2' "$EVENTS"; then
            echo 'HTTP 404: Not Found' >&2
            exit 1
          fi
          ;;
        missing) exit 0 ;;
      esac
    fi
    jq --arg name "$name" --arg digest "$digest" --argjson size "$size" '
      .assets |= (map(select(.name != $name)) + [{name:$name,state:"uploaded",size:$size,digest:$digest}])
    ' "$STATE" > "$STATE.next"
    mv "$STATE.next" "$STATE"
    if [[ "$MODE" == lost-response && "$name" == "$DMG" ]]; then
      echo 'connection reset by peer' >&2
      exit 1
    fi
    ;;
  edit)
    [[ " $* " == *" --draft=false --latest "* ]]
    jq -e '.draft' "$STATE" >/dev/null
    echo publish >> "$EVENTS"
    jq '.draft = false' "$STATE" > "$STATE.next"
    mv "$STATE.next" "$STATE"
    ;;
  *) exit 64 ;;
esac
STUB
chmod +x "$temp_dir/scripts/prepare-mac-appcast.sh" "$temp_dir/bin/"*

half_done() {
  jq -n --arg commit "$COMMIT" --arg zip "$ZIP" --arg zip_digest "$ZIP_DIGEST" '
    {id:42,draft:true,target_commitish:$commit,tag_name:"mac-20261123.231830",assets:[
      {name:$zip,state:"uploaded",size:3,digest:$zip_digest},
      {name:"appcast.xml",state:"uploaded",size:7,digest:"sha256:stale"}
    ]}
  ' > "$STATE"
}

run_case() {
  local name="$1" expected_status="$2" expected_events="$3" status=0
  : > "$EVENTS"
  bash "$temp_dir/scripts/publish-mac-update.sh" "$temp_dir/out" mac-20261123.231830 "$COMMIT" \
    > "$temp_dir/output" 2>&1 || status=$?
  if [[ "$status" != "$expected_status" || "$(< "$EVENTS")" != "$expected_events" ]]; then
    echo "FAIL: $name (exit $status; expected $expected_status)"
    cat "$temp_dir/output" "$EVENTS" >&2
    exit 1
  fi
  echo "PASS: $name"
}

create=$'prepare\ncreate\nupload '"$ZIP"$'\nupload appcast.xml\nupload '"$DMG"
publish=$'\npublish'

MODE=transient
run_case 'retries the DMG after an upload 404 and publishes' 0 "$create"$'\nsleep 2\nupload '"$DMG$publish"
MODE=normal
run_case 'leaves a complete published release untouched' 0 ''

half_done
run_case 'resumes a draft, preserving the matching ZIP and replacing the stale appcast' 0 \
  $'prepare\nupload appcast.xml\nupload '"$DMG$publish"

rm "$STATE"
MODE=lost-response
run_case 'does not overwrite an uploaded asset after a lost response' 0 "$create"$'\nsleep 2'"$publish"

rm "$STATE"
MODE=missing
run_case 'does not publish when the DMG never appears even after successful upload commands' 1 \
  "$create"$'\nsleep 2\nupload '"$DMG"$'\nsleep 4\nupload '"$DMG"$'\nsleep 8\nupload '"$DMG"

rm "$STATE"
MODE=vanishes
run_case 'rechecks all assets together before publishing' 1 "$create"$'\nall assets seen'

MODE=lookup-error
run_case 'does not try to create or upload when the release lookup is forbidden' 1 ''

half_done
MODE=newer-published
run_case 'does not mark an older draft latest when a newer Mac release is published' 1 \
  $'prepare\nupload appcast.xml\nupload '"$DMG"
