#!/usr/bin/env bash
# Tests release_gatekeeper_check from release-common.sh against fake xcrun, spctl and codesign.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/gatekeeper-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
mkdir -p "$temp_dir/fakebin"
# Each fake exits 0 when its FAKE_*_OK variable is "yes".
cat > "$temp_dir/fakebin/xcrun" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = 'stapler validate' ] || { echo "unexpected xcrun: $*" >&2; exit 64; }
[ "$FAKE_STAPLED" = yes ]
STUB
cat > "$temp_dir/fakebin/spctl" <<'STUB'
#!/usr/bin/env bash
echo "spctl $*" >> "$FAKE_LOG"
[ "$FAKE_SPCTL_OK" = yes ]
STUB
cat > "$temp_dir/fakebin/codesign" <<'STUB'
#!/usr/bin/env bash
echo "codesign $*" >> "$FAKE_LOG"
[ "$FAKE_CODESIGN_OK" = yes ]
STUB
chmod +x "$temp_dir/fakebin/"*

failures=0
run_case() { # name stapled spctl_ok codesign_ok want_status want_codesign_calls want_warning
  local name="$1" status=0 calls
  : > "$temp_dir/log"
  PATH="$temp_dir/fakebin:$PATH" FAKE_LOG="$temp_dir/log" FAKE_STAPLED="$2" FAKE_SPCTL_OK="$3" \
    FAKE_CODESIGN_OK="$4" SUPERSEMU_TEAM_ID=ABCDE12345 \
    /bin/bash -c 'set -euo pipefail; source "$1"; release_gatekeeper_check test.dmg --type open' \
    _ "$script_dir/release-common.sh" > "$temp_dir/out" 2> "$temp_dir/err" || status=$?
  calls="$(grep -c '^codesign ' "$temp_dir/log" || true)"
  if [ "$status" -eq "$5" ] && [ "$calls" -eq "$6" ] &&
     { [ "$7" = no ] || grep -q '^warning: test.dmg is unstapled' "$temp_dir/err"; } &&
     { [ "$6" = 0 ] || grep -q 'subject.OU\] = "ABCDE12345"' "$temp_dir/log"; }; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (status $status, codesign calls $calls)" >&2
    cat "$temp_dir/log" "$temp_dir/err" >&2
    failures=$((failures + 1))
  fi
}

run_case 'stapled and accepted' yes yes yes 0 0 no
run_case 'stapled but rejected by Gatekeeper fails' yes no yes 1 0 no
run_case 'unstapled with a valid Developer ID signature only warns' no no yes 0 1 yes
run_case 'unstapled without a valid Developer ID signature fails' no no no 1 1 no
run_case 'unstapled and accepted online' no yes yes 0 1 no
[ "$failures" -eq 0 ]
