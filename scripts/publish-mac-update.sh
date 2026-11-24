#!/usr/bin/env bash
# Run only when the release is approved. Publishing makes it available to automatic updaters.
# Usage: publish-mac-update.sh build/release-mac/<build> <tag> <commit-or-branch>
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:?Pass release output directory}"
tag="${2:?Pass release tag}"
ref="${3:?Pass the tested commit or branch}"
repo=Chadillac6/SupersEmu
[[ "$tag" =~ ^mac-[0-9]+(\.[0-9]+){0,2}$ ]] ||
  { echo 'Expected mac-<build>, with up to three dot-separated integers.' >&2; exit 2; }

release_list() {
  gh api --paginate --slurp "repos/$repo/releases?per_page=100"
}

release_discover() {
  release_list | jq -c --arg tag "$tag" '[.[][] | select(.tag_name == $tag)] | first'
}

release_view() {
  gh api "repos/$repo/releases/$release_id"
}

release="$(release_discover)"
commit="$(git rev-parse --verify "$ref^{commit}")"
shopt -s nullglob
zips=("$out"/SupersEmu-*.zip)
dmgs=("$out"/SupersEmu-*.dmg)
if [[ "${#zips[@]}" != 1 || "${#dmgs[@]}" != 1 ]]; then
  echo 'Expected exactly one release ZIP and DMG.' >&2
  exit 2
fi
zip_name="${zips[0]##*/}"
dmg_name="${dmgs[0]##*/}"
if [[ "${zip_name%.zip}" != "${dmg_name%.dmg}" ]]; then
  echo 'Expected exactly one matching release ZIP and DMG.' >&2
  exit 2
fi
build="${tag#mac-}"
if [[ "$zip_name" != SupersEmu-*-"$build".zip ]]; then
  echo "Release assets do not match build $build." >&2
  exit 2
fi

release_id=""
if [[ "$release" != null ]]; then
  if jq -e '.draft == false' <<< "$release" >/dev/null; then
    tag_commit="$(gh api "repos/$repo/commits/refs/tags/$tag" --jq .sha)"
    if [[ "$tag_commit" == "$commit" ]] && jq -e --arg zip "$zip_name" --arg dmg "$dmg_name" '
      [.assets[] | select(.state == "uploaded" and .size > 0) | .name] as $names
      | ([$zip, $dmg, "appcast.xml"] - $names) == []
    ' <<< "$release" >/dev/null; then
      echo "Mac update $tag is already published."
      exit 0
    fi
    echo "Published release $tag does not match the requested build and commit; refusing to modify it." >&2
    exit 2
  fi
  release_id="$(jq -er '.id' <<< "$release")"
fi

same_draft() {
  jq -e --arg id "$release_id" --arg commit "$commit" '
    .draft == true and (.id | tostring) == $id and .target_commitish == $commit
  ' <<< "$1" >/dev/null
}

if [[ -n "$release_id" ]] && ! same_draft "$release"; then
  echo "Release $tag is not a draft for $commit; refusing to modify it." >&2
  exit 2
fi

scripts/prepare-mac-appcast.sh "$out" "$tag" "$commit"
notes_files=("$out"/updates/SupersEmu-*.html)
[ "${#notes_files[@]}" = 1 ] || { echo 'Expected exactly one generated release-notes HTML file.' >&2; exit 2; }
files=("$out/updates/$zip_name" "$out/updates/appcast.xml" "${dmgs[0]}")
digests=()
for file in "${files[@]}"; do
  [[ -s "$file" ]] || { echo "Missing or empty release asset: $file" >&2; exit 2; }
  digest="$(shasum -a 256 < "$file")"
  digests+=("sha256:${digest%% *}")
done

if [[ -z "$release_id" ]]; then
  gh release create "$tag" --repo "$repo" --target "$commit" --title "SupersEmu $tag" \
    --notes-file "${notes_files[0]}" --draft
  release="$(release_discover)"
  release_id="$(jq -er '.id' <<< "$release")"
fi

asset_matches() {
  jq -e --arg name "$2" --arg digest "$3" '
    any(.assets[]; .name == $name and .state == "uploaded" and .size > 0 and .digest == $digest)
  ' <<< "$1" >/dev/null
}

upload_asset() {
  local file="$1" digest="$2" name="${1##*/}" attempt snapshot
  for attempt in 1 2 3 4; do
    if snapshot="$(release_view)"; then
      if ! same_draft "$snapshot"; then
        echo "Draft $tag changed during upload; refusing to modify it." >&2
        return 1
      fi
      if asset_matches "$snapshot" "$name" "$digest"; then
        return 0
      fi
      if gh release upload "$tag" "$file" --repo "$repo" --clobber &&
        snapshot="$(release_view)" && asset_matches "$snapshot" "$name" "$digest"; then
        return 0
      fi
    fi
    if (( attempt < 4 )); then
      echo "Could not verify $name after attempt $attempt; retrying." >&2
      sleep "$((2 ** attempt))"
    fi
  done
  echo "Could not verify $name; leaving $tag as a draft." >&2
  return 1
}

for i in "${!files[@]}"; do
  upload_asset "${files[i]}" "${digests[i]}"
done

release="$(release_view)"
same_draft "$release" || { echo "Draft $tag changed before publication." >&2; exit 1; }
for i in "${!files[@]}"; do
  name="${files[i]##*/}"
  asset_matches "$release" "$name" "${digests[i]}" ||
    { echo "Could not verify $name; leaving $tag as a draft." >&2; exit 1; }
done
# Latest is explicit because Sparkle follows /releases/latest/download/appcast.xml.
newer_tag="$(release_list | jq -r --arg build "$build" '
  def build_key:
    sub("^(?<date>[0-9]{8})\\.(?<time>[0-9]{4})$"; "\(.date).\(.time)00")
    | split(".") + ["0", "0"] | .[:3]
    | map(sub("^0+"; "") | [length, .]);
  ($build | build_key) as $current
  | [.[][] | select(.draft == false) | .tag_name
     | select(test("^mac-[0-9]+(\\.[0-9]+){0,2}$"))
     | {tag: ., key: (ltrimstr("mac-") | build_key)}
     | select(.key > $current)]
  | (max_by(.key) | .tag) // empty
')"
if [[ -n "$newer_tag" ]]; then
  echo "Mac update $newer_tag is newer; leaving $tag as a draft." >&2
  exit 1
fi
gh release edit "$tag" --repo "$repo" --draft=false --latest
