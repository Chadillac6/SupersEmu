#!/usr/bin/env bash
# For source-built (Debug) installs only.
# Updates this Mac to the latest SupersEmu: pulls main, rebuilds the Mac app, replaces /Applications/SupersEmu.app,
# restarts the boot server if it's registered, and reopens the app. Games, saves and settings live outside the app.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=/Applications/SupersEmu.app
NEW=/Applications/.SupersEmu.app.new
OLD=/Applications/.SupersEmu.app.old
if [ ! -d "$APP" ] && [ -d "$OLD" ]; then
  mv "$OLD" "$APP"
  echo "Recovered SupersEmu.app from an interrupted update."
fi
if [ -d "$APP" ] &&
  codesign -dv --verbose=2 "$APP" 2>&1 | grep -q 'Authority=Developer ID Application'; then
  echo "This Mac has the notarized release build; update it with the newer release .dmg instead. This script is for apps built from source."
  exit 1
fi
git pull --ff-only
git submodule update --init --depth 1
git -C Vendor/cores/picodrive submodule update --init --depth 1 platform/libpicofe platform/common/dr_libs pico/sound/emu2413
xcodegen generate
xcodebuild build -project SupersEmu.xcodeproj -scheme SupersEmu-macOS -destination 'platform=macOS' -derivedDataPath build/mac

rm -rf "$NEW" "$OLD"
ditto build/mac/Build/Products/Debug/SupersEmu.app "$NEW"
codesign --verify --deep "$NEW"
osascript -e 'quit app "SupersEmu"' >/dev/null 2>&1 || true
sleep 2
[ -d "$APP" ] && mv "$APP" "$OLD"
if ! mv "$NEW" "$APP"; then
  [ -d "$OLD" ] && mv "$OLD" "$APP"
  echo "Update failed; previous app restored." >&2
  exit 1
fi
rm -rf "$OLD"
if launchctl print system/com.chadillac6.supersemu.server >/dev/null 2>&1; then
  echo "Restarting the boot server (asks for your password)…"
  sudo launchctl kickstart -k system/com.chadillac6.supersemu.server
fi
open /Applications/SupersEmu.app
echo "Updated."
