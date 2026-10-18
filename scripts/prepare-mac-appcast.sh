#!/usr/bin/env bash
# Generate a signed, single-channel appcast for an already-built Mac release.
# No uploads. Usage: prepare-mac-appcast.sh build/release-mac/<build> <release-tag>
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:?Pass the Mac release output directory}"
tag="${2:?Pass the GitHub release tag}"
release_ref="${3:-${GITHUB_SHA:-HEAD}}"
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid release tag' >&2; exit 2; }
# shellcheck source=scripts/mac-release-notes.sh
source scripts/mac-release-notes.sh
tool="${SPARKLE_GENERATE_APPCAST:-build/mac/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast}"
[ -x "$tool" ] || { echo 'Resolve the Sparkle package before generating the appcast.' >&2; exit 2; }
shopt -s nullglob
archives=("$out"/SupersEmu-*.zip)
[ "${#archives[@]}" = 1 ] || { echo 'Expected exactly one release ZIP.' >&2; exit 2; }
app="$out/export/SupersEmu.app"
[ -d "$app" ] || { echo 'Missing exported release app.' >&2; exit 2; }
/usr/bin/codesign --verify --deep --strict "$app"
if ! /usr/sbin/spctl --assess --type execute "$app"; then
  # release-mac.sh leaves this marker when Apple's ticket server was unreachable for stapling;
  # the app is notarized, so only the online Gatekeeper lookup failed here too.
  [ -e "$out/app-unstapled" ] || exit 1
  echo '::warning::spctl could not confirm the unstapled app online; it was notarized (Accepted) by release-mac.sh' >&2
fi
key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")"
[ -n "$key" ] || { echo 'App has no Sparkle public signing key.' >&2; exit 2; }
updates="$out/updates"
mkdir -p "$updates"
cp "${archives[0]}" "$updates/"
zip_name="${archives[0]##*/}"
notes_file="$updates/${zip_name%.zip}.html"
previous_tag=""
if command -v gh >/dev/null 2>&1; then
  previous_tag="$(gh release list --repo Chadillac6/SupersEmu --limit 100 \
    --json tagName,isDraft,publishedAt \
    --jq '[.[] | select(.tagName | startswith("mac-")) | select(.isDraft == false)] | sort_by(.publishedAt) | last | .tagName // empty' \
    2>/dev/null || true)"
fi
previous_commit=""
if [ -n "$previous_tag" ]; then
  git fetch --quiet origin "refs/tags/$previous_tag:refs/tags/$previous_tag" 2>/dev/null || true
  previous_commit="$(git rev-parse --verify "$previous_tag^{commit}" 2>/dev/null || true)"
fi
subjects=""
if [ -n "$previous_commit" ]; then
  subjects="$(git log --format=%s "$previous_commit..$release_ref" 2>/dev/null || true)"
fi
if [ -z "$subjects" ]; then
  subjects="$(git log -10 --format=%s "$release_ref")"
fi
printf '%s\n' "$subjects" | mac_release_notes_html > "$notes_file"
auth=(--account com.chadillac6.supersemu)
if [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then auth=(--ed-key-file "$SPARKLE_ED_KEY_FILE"); fi
appcast_args=(--download-url-prefix "https://github.com/Chadillac6/SupersEmu/releases/download/$tag/"
  --maximum-deltas 0)
if [[ "$("$tool" --help 2>&1 || true)" == *"--embed-release-notes"* ]]; then
  appcast_args+=(--embed-release-notes)
fi
"$tool" "${auth[@]}" "${appcast_args[@]}" "$updates"
[ -s "$updates/appcast.xml" ] || { echo 'No appcast generated.' >&2; exit 1; }
echo "Signed appcast ready: $updates/appcast.xml"
echo 'Publish this appcast and its ZIP together as assets of the same GitHub release.'
