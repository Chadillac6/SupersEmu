#!/bin/bash
# Xcode build phase: build supersemu-server with SwiftPM and embed it plus its launchd plist in the macOS app.
set -euo pipefail
[ "${PLATFORM_NAME:-}" = "macosx" ] || exit 0

config=debug
[ "${CONFIGURATION:-Debug}" = "Release" ] && config=release
archs="${ARCHS:-$(uname -m)}"
swiftpm() { # arch, extra args...
    local arch="$1"; shift
    # Clean environment so Xcode's SDK/arch settings don't leak into SwiftPM.
    env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="${DEVELOPER_DIR}" \
        xcrun swift build --package-path "${SRCROOT}/Server" --scratch-path "${PROJECT_TEMP_DIR}/supersemu-server-swiftpm-$arch" \
        -c "$config" --skip-update --product supersemu-server --triple "$arch-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-15.0}" "$@"
}
# One slice per app architecture, so a universal Release app gets a universal server.
slices=()
for arch in $archs; do
    swiftpm "$arch"
    slices+=("$(swiftpm "$arch" --show-bin-path)/supersemu-server")
done

app="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
lipo -create "${slices[@]}" -output "$app/Contents/MacOS/supersemu-server"
chmod 755 "$app/Contents/MacOS/supersemu-server"
mkdir -p "$app/Contents/Library/LaunchDaemons"
install -m 644 "${SRCROOT}/Server/Resources/com.chadillac6.supersemu.server.plist" "$app/Contents/Library/LaunchDaemons/"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
sign=(--force --sign "$identity" --timestamp=none)
# Release signing (scripts/release-mac.sh): notarization needs a secure timestamp and the hardened runtime.
if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ] && [ "$identity" != "-" ]; then
  sign=(--force --sign "$identity" --timestamp --options runtime)
fi
codesign "${sign[@]}" "$app/Contents/MacOS/supersemu-server"
