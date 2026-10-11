#!/usr/bin/env bash
# Generate a signed, single-channel appcast for an already-built Mac release.
# No uploads. Usage: prepare-mac-appcast.sh build/release-mac/<build> <release-tag>
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:?Pass the Mac release output directory}"
tag="${2:?Pass the GitHub release tag}"
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid release tag' >&2; exit 2; }
tool="${SPARKLE_GENERATE_APPCAST:-build/mac/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast}"
[ -x "$tool" ] || { echo 'Resolve the Sparkle package before generating the appcast.' >&2; exit 2; }
shopt -s nullglob
archives=("$out"/SupersEmu-*.zip)
[ "${#archives[@]}" = 1 ] || { echo 'Expected exactly one release ZIP.' >&2; exit 2; }
app="$out/export/SupersEmu.app"
[ -d "$app" ] || { echo 'Missing exported release app.' >&2; exit 2; }
/usr/bin/codesign --verify --deep --strict "$app"
/usr/sbin/spctl --assess --type execute "$app"
key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")"
[ -n "$key" ] || { echo 'App has no Sparkle public signing key.' >&2; exit 2; }
updates="$out/updates"
mkdir -p "$updates"
cp "${archives[0]}" "$updates/"
auth=(--account com.chadillac6.supersemu)
if [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then auth=(--ed-key-file "$SPARKLE_ED_KEY_FILE"); fi
"$tool" "${auth[@]}" --download-url-prefix "https://github.com/Chadillac6/SupersEmu/releases/download/$tag/" \
  --maximum-deltas 0 "$updates"
[ -s "$updates/appcast.xml" ] || { echo 'No appcast generated.' >&2; exit 1; }
echo "Signed appcast ready: $updates/appcast.xml"
echo 'Publish this appcast and its ZIP together as assets of the same GitHub release.'
