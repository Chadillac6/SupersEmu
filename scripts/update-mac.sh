#!/usr/bin/env bash
# Updates this Mac to the latest SupersEmu: pulls main, rebuilds the Mac app, replaces /Applications/SupersEmu.app,
# restarts the boot server if it's registered, and reopens the app. Games, saves and settings live outside the app.
set -euo pipefail
cd "$(dirname "$0")/.."
git pull --ff-only
git submodule update --init --depth 1
git -C Vendor/cores/picodrive submodule update --init --depth 1 platform/libpicofe platform/common/dr_libs pico/sound/emu2413
xcodegen generate
xcodebuild build -project SupersEmu.xcodeproj -scheme SupersEmu-macOS -destination 'platform=macOS' -derivedDataPath build/mac
osascript -e 'quit app "SupersEmu"' >/dev/null 2>&1 || true
sleep 2
rm -rf /Applications/SupersEmu.app
ditto build/mac/Build/Products/Debug/SupersEmu.app /Applications/SupersEmu.app
if launchctl print system/com.chadillac6.supersemu.server >/dev/null 2>&1; then
  echo "Restarting the boot server (asks for your password)…"
  sudo launchctl kickstart -k system/com.chadillac6.supersemu.server
fi
open /Applications/SupersEmu.app
echo "Updated."
