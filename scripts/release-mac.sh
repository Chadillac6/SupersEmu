#!/usr/bin/env bash
# Builds the Mac app for distribution outside the Mac App Store: Developer ID signed, hardened runtime,
# notarized by Apple and stapled. Produces build/release-mac/<build>/SupersEmu-<version>-<build>.dmg
# (and a stapled .zip). Why not TestFlight/App Store: docs/specs/distribution.md.
# Needs a "Developer ID Application" certificate for SUPERSEMU_TEAM_ID in the login keychain.
# Environment: see scripts/release-common.sh or docs/specs/distribution.md.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/release-common.sh
source scripts/release-common.sh

release_require_env
identity="$(security find-identity -v -p codesigning 2>/dev/null |
  awk -v team="($SUPERSEMU_TEAM_ID)" '/"Developer ID Application: / && index($0, team) { print $2; exit }')"
if [ -z "$identity" ]; then
  echo "error: no 'Developer ID Application' certificate for team $SUPERSEMU_TEAM_ID in the keychain." >&2
  echo "Create one in Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application." >&2
  exit 2
fi
release_prepare_key
marketing_version="$(release_marketing_version)"
notary_auth=(--key "$ASC_KEY_FILE" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
build_number="$(release_build_number)"
out="build/release-mac/$build_number"
archive="$out/SupersEmu-macOS.xcarchive"
mkdir -p "$out"

notarize() { # file
  local result status id
  result="$RELEASE_TMP/notary-$(basename "$1").json"
  echo "Notarizing $(basename "$1") (usually a few minutes)"
  xcrun notarytool submit "$1" "${notary_auth[@]}" --wait --output-format json > "$result" || true
  status="$(plutil -extract status raw -o - "$result" 2>/dev/null || echo unknown)"
  if [ "$status" != "Accepted" ]; then
    id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
    echo "error: notarization status '$status' for $1" >&2
    cat "$result" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" "${notary_auth[@]}" >&2 || true
    exit 1
  fi
}

# `stapler staple` validates the ticket itself. A failure here is only the ticket download: notarize
# already required "Accepted", and GitHub's runners often lose the connection to Apple's ticket server.
# Unstapled notarized builds still pass Gatekeeper (it fetches the ticket online), so callers publish
# anyway with a warning rather than failing the release.
staple_or_warn() { # file; returns 1 when left unstapled
  local file="$1" attempt=1 attempts delay
  attempts="${SUPERSEMU_STAPLE_ATTEMPTS:-8}"
  delay="${SUPERSEMU_STAPLE_RETRY_DELAY:-30}"
  while [ "$attempt" -le "$attempts" ]; do
    if xcrun stapler staple "$file"; then
      return 0
    fi
    if [ "$attempt" -lt "$attempts" ]; then
      printf 'Stapling %s failed (attempt %s/%s); retrying in %ss\n' "$file" "$attempt" "$attempts" "$delay" >&2
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done
  printf '::warning::Could not staple %s after %s attempts (Apple ticket server unreachable); it is notarized, so Gatekeeper checks it online. Publishing unstapled.\n' "$file" "$attempts" >&2
  return 1
}

git submodule update --init --depth 1
git -C Vendor/cores/picodrive submodule update --init --depth 1 platform/libpicofe platform/common/dr_libs pico/sound/emu2413
xcodegen generate

echo "Version $marketing_version (build $build_number)"
echo "Archiving SupersEmu-macOS build $build_number (Developer ID, team $SUPERSEMU_TEAM_ID)"
xcodebuild archive -project SupersEmu.xcodeproj -scheme SupersEmu-macOS -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$archive" -derivedDataPath build/release-mac/DerivedData \
  SUPERSEMU_TEAM_ID="$SUPERSEMU_TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp CURRENT_PROJECT_VERSION="$build_number" \
  MARKETING_VERSION="$marketing_version"

cat > "$RELEASE_TMP/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$SUPERSEMU_TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/export" \
  -exportOptionsPlist "$RELEASE_TMP/ExportOptions.plist"
app="$out/export/SupersEmu.app"

codesign --verify --deep --strict "$app"
sorted_archs() { lipo -archs "$1" | tr ' ' '\n' | sort | xargs; }
app_archs="$(sorted_archs "$app/Contents/MacOS/SupersEmu")"
server_archs="$(sorted_archs "$app/Contents/MacOS/supersemu-server")"
[ "$app_archs" = "$server_archs" ] ||
  { echo "error: app is '$app_archs' but supersemu-server is '$server_archs'" >&2; exit 1; }
for bin in "$app/Contents/MacOS/SupersEmu" "$app/Contents/MacOS/supersemu-server"; do
  codesign -dv --verbose=4 "$bin" 2>&1 | grep -q 'flags=.*runtime' ||
    { echo "error: $bin is not signed with the hardened runtime" >&2; exit 1; }
done

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
name="SupersEmu-$version-$build_number"

ditto -c -k --keepParent "$app" "$RELEASE_TMP/$name.zip"
notarize "$RELEASE_TMP/$name.zip"
stapled=both
staple_or_warn "$app" || { stapled='dmg-only'; touch "$out/app-unstapled"; }
ditto -c -k --keepParent "$app" "$out/$name.zip"

staging="$RELEASE_TMP/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/SupersEmu.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname SupersEmu -srcfolder "$staging" -format UDZO -ov "$out/$name.dmg" >/dev/null
codesign --sign "$identity" --timestamp "$out/$name.dmg"
notarize "$out/$name.dmg"
if staple_or_warn "$out/$name.dmg"; then
  spctl --assess --type open --context context:primary-signature -v "$out/$name.dmg"
else
  if [ "$stapled" = both ]; then stapled='app-only'; else stapled=none; fi
  spctl --assess --type open --context context:primary-signature -v "$out/$name.dmg" ||
    echo "::warning::spctl could not confirm the unstapled DMG's notarization online" >&2
fi

echo "Done: $out/$name.dmg and $out/$name.zip (notarized; stapled: $stapled); Version $marketing_version (build $build_number)"
