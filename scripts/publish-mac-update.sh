#!/usr/bin/env bash
# Run only when the release is approved. Publishing makes it available to automatic updaters.
# Usage: publish-mac-update.sh build/release-mac/<build> <tag> <commit-or-branch>
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:?Pass release output directory}"
tag="${2:?Pass release tag}"
ref="${3:?Pass the tested commit or branch}"
# Refuse to modify an existing release or replace its signed assets.
if gh release view "$tag" --repo Chadillac6/SupersEmu >/dev/null 2>&1; then
  echo 'Release already exists. Build a new version rather than replacing it.' >&2; exit 2
fi
scripts/prepare-mac-appcast.sh "$out" "$tag"
shopt -s nullglob
zips=("$out"/updates/SupersEmu-*.zip)
gh release create "$tag" "${zips[@]}" "$out/updates/appcast.xml" "$out"/SupersEmu-*.dmg \
  --repo Chadillac6/SupersEmu --target "$ref" --title "SupersEmu $tag" --generate-notes --draft
# Latest is explicit because Sparkle follows /releases/latest/download/appcast.xml.
gh release edit "$tag" --repo Chadillac6/SupersEmu --draft=false --latest
