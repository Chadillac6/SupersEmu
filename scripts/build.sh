#!/usr/bin/env bash
# Generates the Xcode project, runs host tests on macOS and builds the iOS simulator app.
set -euo pipefail
cd "$(dirname "$0")/.."
git submodule update --init --depth 1
[ -f Tests/Fixtures/local/HelloWorld.sfc ] || scripts/fetch-test-roms.sh
xcodegen generate
xcodebuild test -project SupersEmu.xcodeproj -scheme SupersEmu-macOS \
  -destination 'platform=macOS' -derivedDataPath build/mac
xcodebuild build -project SupersEmu.xcodeproj -scheme SupersEmu-iOS \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios
