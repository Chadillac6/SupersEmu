#!/usr/bin/env bash
# Archives the iPhone/iPad app and uploads it to App Store Connect, where it appears in TestFlight.
# Signing is automatic (profiles and certificates managed by Xcode through the API key).
# Environment: see scripts/release-common.sh or docs/specs/distribution.md.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/release-common.sh
source scripts/release-common.sh

release_require_env
release_prepare_key
build_number="$(release_build_number)"
out="build/release-ios/$build_number"
archive="$out/SupersEmu-iOS.xcarchive"
mkdir -p "$out"

git submodule update --init --depth 1
git -C Vendor/cores/picodrive submodule update --init --depth 1 platform/libpicofe platform/common/dr_libs pico/sound/emu2413
xcodegen generate

echo "Archiving SupersEmu-iOS build $build_number for team $SUPERSEMU_TEAM_ID"
xcodebuild archive -project SupersEmu.xcodeproj -scheme SupersEmu-iOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" -derivedDataPath build/release-ios/DerivedData \
  -allowProvisioningUpdates "${ASC_AUTH_ARGS[@]}" \
  SUPERSEMU_TEAM_ID="$SUPERSEMU_TEAM_ID" CURRENT_PROJECT_VERSION="$build_number"

cat > "$RELEASE_TMP/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$SUPERSEMU_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

echo "Uploading build $build_number to App Store Connect"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/export" \
  -exportOptionsPlist "$RELEASE_TMP/ExportOptions.plist" -allowProvisioningUpdates "${ASC_AUTH_ARGS[@]}"

echo "Uploaded SupersEmu $build_number. It shows in App Store Connect > TestFlight after processing (usually minutes)."
