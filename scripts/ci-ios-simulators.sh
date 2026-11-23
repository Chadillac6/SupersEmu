#!/usr/bin/env bash
# Prints iphone=<udid> and ipad=<udid> (for $GITHUB_OUTPUT) from the newest installed iOS runtime
# no newer than the selected Xcode's simulator SDK, and starts booting both so they are ready by the
# time the tests are built.
#   scripts/ci-ios-simulators.sh [simctl-devices.json sdk-version]   # replaces simctl/xcrun (tests)
set -euo pipefail
if [ $# -gt 0 ]; then
  devices="$(cat "$1")" sdk="$2"
else
  devices="$(xcrun simctl list devices available --json)"
  sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
fi
picked="$(python3 -c '
import json, re, sys
runtimes = json.loads(sys.argv[1])["devices"]
def version(runtime):
    m = re.search(r"\.iOS-(\d+)-(\d+)$", runtime)
    return (int(m.group(1)), int(m.group(2))) if m else None
sdk = tuple(int(part) for part in sys.argv[2].split(".")[:2])
ios = sorted((r for r in runtimes if version(r) and version(r) <= sdk), key=version, reverse=True)
for runtime in ios:
    devices = [d for d in runtimes[runtime] if d.get("isAvailable", True)]
    iphone = next((d for d in devices if d["name"].startswith("iPhone")), None)
    ipad = next((d for d in devices if d["name"].startswith("iPad")), None)
    if iphone and ipad:
        print("iphone=" + iphone["udid"])
        print("ipad=" + ipad["udid"])
        print(runtime + ": " + iphone["name"] + " and " + ipad["name"], file=sys.stderr)
        break
else:
    sys.exit("No iOS runtime up to " + sys.argv[2] + " with both an iPhone and an iPad simulator")
' "$devices" "$sdk")"
echo "$picked"
if [ $# -eq 0 ]; then
  while IFS='=' read -r _ udid; do xcrun simctl boot "$udid" >/dev/null 2>&1 || true; done <<<"$picked"
fi
