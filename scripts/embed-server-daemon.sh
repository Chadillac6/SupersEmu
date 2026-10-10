#!/bin/bash
# Xcode build phase: build supersemu-server with SwiftPM and embed it plus its launchd plist in the macOS app.
set -euo pipefail
[ "${PLATFORM_NAME:-}" = "macosx" ] || exit 0

config=debug
[ "${CONFIGURATION:-Debug}" = "Release" ] && config=release
scratch="${PROJECT_TEMP_DIR}/supersemu-server-swiftpm"
swiftpm() {
    # Clean environment so Xcode's SDK/arch settings don't leak into SwiftPM.
    env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="${DEVELOPER_DIR}" \
        xcrun swift build --package-path "${SRCROOT}/Server" --scratch-path "$scratch" -c "$config" --product supersemu-server "$@"
}
swiftpm
bin="$(swiftpm --show-bin-path)/supersemu-server"

app="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
install -m 755 "$bin" "$app/Contents/MacOS/supersemu-server"
mkdir -p "$app/Contents/Library/LaunchDaemons"
install -m 644 "${SRCROOT}/Server/Resources/com.chadillac6.supersemu.server.plist" "$app/Contents/Library/LaunchDaemons/"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$app/Contents/MacOS/supersemu-server"
