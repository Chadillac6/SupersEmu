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
export TAG=mac-20261123.231830 OTHER_TAG=mac-20261124.0000
export ZIP_DIGEST APPCAST_DIGEST DMG_DIGEST MODE

printf zip > "$temp_dir/out/updates/$ZIP"
cp "$temp_dir/out/updates/$ZIP" "$temp_dir/out/$ZIP"
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
if [[ "${0##*/}" == curl ]]; then
  [[ "$1 $2" == '--config -' ]]
  [[ "$(</dev/stdin)" == 'header = "Authorization: Bearer stub-token"' ]]
  [[ "${!#}" == "https://uploads.github.com/repos/Chadillac6/SupersEmu/releases/42/assets?name=${9##*/}" ]]
  [[ "$8" == --data-binary && "$9" == @* ]]
  set -- release upload "$TAG" "${9#@}"
elif [[ "$*" == 'auth token --hostname github.com' ]]; then
  echo stub-token
  exit 0
elif [[ "$1" == api && "$2" == repos/Chadillac6/SupersEmu/releases/42 ]]; then
  set -- release snapshot "$TAG"
elif [[ "$1 $2 ${3:-} ${4:-}" == 'api --method POST repos/Chadillac6/SupersEmu/releases' ]]; then
  [[ " $* " == *" -f tag_name=$TAG "* && " $* " == *" -f target_commitish=$COMMIT "* &&
     " $* " == *" -F draft=true "* ]]
  set -- release create "$TAG"
elif [[ "$1 $2 ${3:-} ${4:-}" == 'api --method PATCH repos/Chadillac6/SupersEmu/releases/42' ]]; then
  [[ " $* " == *" -f tag_name=$TAG -F draft=false -f make_latest=true "* ]]
  set -- release edit "$TAG"
elif [[ "$1 $2 ${3:-}" == 'api --method DELETE' && "$4" == repos/Chadillac6/SupersEmu/releases/assets/* ]]; then
  jq -e '.draft' "$STATE" >/dev/null
  jq --argjson id "${4##*/}" '.assets |= map(select(.id != $id))' "$STATE" > "$STATE.next"
  mv "$STATE.next" "$STATE"
  exit 0
elif [[ "$*" == 'api --paginate --slurp repos/Chadillac6/SupersEmu/releases?per_page=100' ]]; then
  if [[ "$MODE" == lookup-error ]]; then
    echo '[[]]'
    echo 'HTTP 403: Resource not accessible by integration' >&2
    exit 1
  fi
  if [[ ! -s "$STATE" || "$MODE" == undiscoverable ]]; then
    echo '[[]]'
  elif [[ "$MODE" == other-published ]]; then
    jq --arg tag "$OTHER_TAG" '[[.], [{draft:false,tag_name:$tag}]]' "$STATE"
  else
    jq '[[.]]' "$STATE"
  fi
  exit 0
elif [[ "$*" == "api repos/Chadillac6/SupersEmu/commits/refs/tags/$TAG --jq .sha" ]]; then
  if [[ "$MODE" == wrong-tag-commit ]]; then
    echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  else
    echo "$COMMIT"
  fi
  exit 0
elif [[ "$*" == "api repos/Chadillac6/SupersEmu/git/matching-refs/tags/$TAG" ]]; then
  if [[ "$MODE" == wrong-draft-tag ]] ||
    { [[ "$MODE" == wrong-draft-tag-appears ]] && grep -Fxq "upload $DMG" "$EVENTS"; }; then
    jq -n --arg ref "refs/tags/$TAG" '[{ref:$ref,object:{type:"commit",sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}]'
  elif [[ "$MODE" == matching-draft-tag ]]; then
    jq -n --arg ref "refs/tags/$TAG" '[{ref:$ref,object:{type:"tag",sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}]'
  else
    echo '[]'
  fi
  exit 0
else
  echo "Unexpected stub call: $*" >&2
  exit 64
fi
[[ "$1" == release && "$3" == "$TAG" ]]
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
    [[ ! -s "$STATE" ]]
    echo create >> "$EVENTS"
    jq -n --arg commit "$COMMIT" --arg tag "$3" \
      '{id:42,draft:true,target_commitish:$commit,tag_name:$tag,assets:[],
        html_url:"https://github.com/Chadillac6/SupersEmu/releases/tag/untagged-stub"}' > "$STATE"
    if [[ "$MODE" == missing-create-id ]]; then
      jq 'del(.id)' "$STATE"
    else
      cat "$STATE"
    fi
    ;;
  upload)
    jq -e '.draft' "$STATE" >/dev/null
    name="${4##*/}"
    echo "upload $name" >> "$EVENTS"
    case "$name" in
      "$ZIP") id=1; digest="$ZIP_DIGEST"; size=3 ;;
      appcast.xml) id=2; digest="$APPCAST_DIGEST"; size=7 ;;
      "$DMG") id=3; digest="$DMG_DIGEST"; size=3 ;;
      *) exit 64 ;;
    esac
    jq -e --arg name "$name" 'all(.assets[]; .name != $name)' "$STATE" >/dev/null
    if [[ "$name" == "$DMG" ]]; then
      case "$MODE" in
        transient)
          if ! grep -qx 'sleep 2' "$EVENTS"; then
            echo 'curl: (22) The requested URL returned error: 404' >&2
            printf '{"message":"Not Found","details":"%1100snot logged"}\n' ''
            exit 22
          fi
          ;;
        missing) exit 0 ;;
      esac
    fi
    jq --argjson id "$id" --arg name "$name" --arg digest "$digest" --argjson size "$size" '
      .assets += [{id:$id,name:$name,state:"uploaded",size:$size,digest:$digest}]
    ' "$STATE" > "$STATE.next"
    mv "$STATE.next" "$STATE"
    if [[ "$MODE" == lost-response && "$name" == "$DMG" ]]; then
      echo 'connection reset by peer' >&2
      exit 1
    fi
    ;;
  edit)
    jq -e '.draft' "$STATE" >/dev/null
    echo publish >> "$EVENTS"
    jq '.draft = false' "$STATE" > "$STATE.next"
    mv "$STATE.next" "$STATE"
    if [[ "$MODE" == wrong-published-tag ]]; then
      jq '.tag_name = "untagged-stub"' "$STATE"
    elif [[ "$MODE" == still-draft ]]; then
      jq '.draft = true' "$STATE"
    else
      cat "$STATE"
    fi
    ;;
  *) exit 64 ;;
esac
STUB
chmod +x "$temp_dir/scripts/prepare-mac-appcast.sh" "$temp_dir/bin/"*
ln -s gh "$temp_dir/bin/curl"

half_done() {
  jq -n --arg commit "$COMMIT" --arg tag "$TAG" --arg zip "$ZIP" --arg zip_digest "$ZIP_DIGEST" '
    {id:42,draft:true,target_commitish:$commit,tag_name:$tag,assets:[
      {id:1,name:$zip,state:"uploaded",size:3,digest:$zip_digest},
      {id:2,name:"appcast.xml",state:"uploaded",size:7,digest:"sha256:stale"}
    ]}
  ' > "$STATE"
}

run_case() {
  local name="$1" expected_status="$2" expected_events="$3" status=0
  : > "$EVENTS"
  bash "$temp_dir/scripts/publish-mac-update.sh" "$temp_dir/out" "$TAG" "$COMMIT" \
    > "$temp_dir/stdout" 2> "$temp_dir/stderr" || status=$?
  cat "$temp_dir/stdout" "$temp_dir/stderr" > "$temp_dir/output"
  if [[ "$status" != "$expected_status" || "$(< "$EVENTS")" != "$expected_events" ]]; then
    echo "FAIL: $name (exit $status; expected $expected_status)"
    cat "$temp_dir/output" "$EVENTS" >&2
    exit 1
  fi
  echo "PASS: $name"
}

assert_publication_unconfirmed() {
  grep -Fx "GitHub did not confirm publication of $TAG (release 42)." "$temp_dir/stderr" >/dev/null
}

create=$'prepare\ncreate\nupload '"$ZIP"$'\nupload appcast.xml\nupload '"$DMG"
publish=$'\npublish'

MODE=transient
run_case 'retries the DMG after an upload 404 and publishes' 0 "$create"$'\nsleep 2\nupload '"$DMG$publish"
grep -Fq 'The requested URL returned error: 404' "$temp_dir/stderr"
grep -Fq "GitHub upload response for $DMG (first 1024 bytes): {\"message\":\"Not Found\"" "$temp_dir/stderr"
if grep -Fq 'not logged' "$temp_dir/output"; then
  echo 'FAIL: GitHub upload response was not truncated' >&2
  exit 1
fi
MODE=normal
run_case 'leaves a complete published release untouched' 0 ''
MODE=wrong-tag-commit
run_case 'rejects a published release whose tag points at a different commit' 2 ''
MODE=normal
jq --arg zip "$ZIP" '.assets[] |= if .name == $zip then .name = "SupersEmu-different.zip" else . end' \
  "$STATE" > "$STATE.next"
mv "$STATE.next" "$STATE"
run_case 'rejects a published release with a different build ZIP' 2 ''

half_done
MODE=matching-draft-tag
run_case 'resumes a draft, preserving the matching ZIP and replacing the stale appcast' 0 \
  $'prepare\nupload appcast.xml\nupload '"$DMG$publish"

half_done
MODE=wrong-draft-tag
run_case 'refuses to change a draft whose Git tag points to a different commit' 2 ''

half_done
MODE=wrong-draft-tag-appears
run_case 'refuses to publish if a conflicting Git tag appears during upload' 1 \
  $'prepare\nupload appcast.xml\nupload '"$DMG"
grep -Fq "Git tag $TAG points to" "$temp_dir/output"

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

rm "$STATE"
MODE=undiscoverable
run_case 'publishes by numeric ID even while the new untagged draft is missing from release lists' 0 "$create$publish"

rm "$STATE"
MODE=missing-create-id
run_case 'refuses to upload when the draft creation response has no release ID' 1 $'prepare\ncreate'
grep -Fq "GitHub did not return an ID when creating draft $TAG." "$temp_dir/stderr"

MODE=normal
run_case 'resumes the existing zero-asset untagged draft without creating another release' 0 \
  $'prepare\nupload '"$ZIP"$'\nupload appcast.xml\nupload '"$DMG$publish"
grep -Fq "Resuming draft $TAG (release 42)." "$temp_dir/stdout"

half_done
MODE=wrong-published-tag
run_case 'fails when the publish response returns a different tag' 1 \
  $'prepare\nupload appcast.xml\nupload '"$DMG$publish"
assert_publication_unconfirmed

half_done
MODE=still-draft
run_case 'fails when the publish response still identifies the release as a draft' 1 \
  $'prepare\nupload appcast.xml\nupload '"$DMG$publish"
assert_publication_unconfirmed

half_done
MODE=other-published
run_case 'does not mark an older draft latest when a newer Mac release is published' 1 \
  $'prepare\nupload appcast.xml\nupload '"$DMG"

TAG=mac-20261123.231829
MODE=normal
run_case 'rejects a tag that does not match the exported build' 2 ''

set_build() {
  local build="$1" stem="SupersEmu-0.0.25-$1"
  TAG="mac-$build"
  mv "$temp_dir/out/$ZIP" "$temp_dir/out/$stem.zip"
  mv "$temp_dir/out/updates/$ZIP" "$temp_dir/out/updates/$stem.zip"
  mv "$temp_dir/out/updates/${ZIP%.zip}.html" "$temp_dir/out/updates/$stem.html"
  mv "$temp_dir/out/$DMG" "$temp_dir/out/$stem.dmg"
  ZIP="$stem.zip"
  DMG="$stem.dmg"
  half_done
}

set_build 1.10.2
MODE=other-published
OTHER_TAG=mac-1.9.12
run_case 'accepts an overridden build number and compares its components numerically' 0 \
  $'prepare\nupload appcast.xml\nupload '"$DMG$publish"

set_build 20261124.0001
OTHER_TAG=mac-20261124.0001.1
run_case 'compares an omitted third component as zero rather than interpreting the build as a time' 1 \
  $'prepare\nupload appcast.xml\nupload '"$DMG"
grep -Fq "must be newer than published Mac update $OTHER_TAG" "$temp_dir/output"

set_build 20261124.123456
OTHER_TAG=mac-20261124.123456.0
run_case 'refuses to publish a build equal to a release with an explicit trailing zero' 1 \
  $'prepare\nupload appcast.xml\nupload '"$DMG"
grep -Fq "must be newer than published Mac update $OTHER_TAG" "$temp_dir/output"
