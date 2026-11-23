#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ci-ios-simulators.sh"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ci-ios-sims-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
cat > "$temp_dir/devices.json" <<'JSON'
{"devices":{
  "com.apple.CoreSimulator.SimRuntime.iOS-18-5":[{"name":"iPhone 16","udid":"P18"},{"name":"iPad Air 11-inch (M3)","udid":"T18"}],
  "com.apple.CoreSimulator.SimRuntime.iOS-26-2":[{"name":"iPad Pro 11-inch (M5)","udid":"T262"},{"name":"iPhone 17","udid":"P262"}],
  "com.apple.CoreSimulator.SimRuntime.iOS-26-4":[{"name":"iPhone 17","udid":"P264"}],
  "com.apple.CoreSimulator.SimRuntime.iOS-26-10":[{"name":"iPhone 17","udid":"P2610"},{"name":"iPad mini (A17 Pro)","udid":"T2610"}],
  "com.apple.CoreSimulator.SimRuntime.watchOS-26-2":[{"name":"Apple Watch Series 11 (46mm)","udid":"W"}]
}}
JSON

failures=0
run_case() { # name sdk expected-exit expected-output
  local output status=0
  output="$("$script" "$temp_dir/devices.json" "$2" 2>/dev/null)" || status=$?
  if [ "$status" = "$3" ] && [ "$output" = "$4" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (exit $status, output: ${output//$'\n'/ })"
    failures=$((failures + 1))
  fi
}

run_case 'uses the runtime matching the SDK' 26.2 0 $'iphone=P262\nipad=T262'
run_case 'never picks a runtime newer than the SDK' 26.4 0 $'iphone=P262\nipad=T262'
run_case 'compares versions numerically' 26.10 0 $'iphone=P2610\nipad=T2610'
run_case 'falls back to an older runtime' 18.6 0 $'iphone=P18\nipad=T18'
run_case 'fails without an iPhone and iPad pair' 17.0 1 ''

[ "$failures" = 0 ]
