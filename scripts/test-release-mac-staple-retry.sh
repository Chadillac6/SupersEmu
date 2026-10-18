#!/usr/bin/env bash
# Tests staple_with_retry from release-mac.sh against a fake xcrun.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/release-staple-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

function_source="$temp_dir/staple-function.sh"
sed -n '/^staple_with_retry() {$/,/^}/p' "$script_dir/release-mac.sh" > "$function_source"
[ -s "$function_source" ] || { echo "FAIL: staple_with_retry function not found" >&2; exit 1; }

mkdir -p "$temp_dir/fakebin"
cat > "$temp_dir/fakebin/xcrun" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-} ${2:-}" = 'stapler staple' ] || { echo "unexpected xcrun command: $*" >&2; exit 64; }
attempt=$(($(cat "$STAPLE_ATTEMPT_FILE" 2>/dev/null || echo 0) + 1))
echo "$attempt" > "$STAPLE_ATTEMPT_FILE"
[ "$attempt" -gt "$STAPLE_FAIL_ATTEMPTS" ] && exit 0
# Messages and exit codes match the real stapler: ticket server unreachable vs. no ticket for this build.
if [ "$STAPLE_FAIL_MODE" = missing ]; then
  echo 'CloudKit query for test.app failed due to "Record not found".'
  echo 'The staple and validate action failed! Error 65.'
  exit 65
fi
echo 'error is Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost."'
echo 'The staple and validate action failed! Error 68.'
exit 68
STUB
chmod +x "$temp_dir/fakebin/xcrun"

failures=0
run_case() { # name fail_attempts want_status want_attempts want_retry_lines want_warning|error [fail_mode] [attempts]
  local name="$1" status=0 attempts retries case_dir
  case_dir="$(mktemp -d "$temp_dir/case.XXXXXX")"
  PATH="$temp_dir/fakebin:$PATH" STAPLE_FAIL_ATTEMPTS="$2" STAPLE_ATTEMPT_FILE="$case_dir/attempts" \
    STAPLE_FAIL_MODE="${7:-unreachable}" SUPERSEMU_STAPLE_ATTEMPTS="${8:-10}" \
    SUPERSEMU_STAPLE_RETRY_DELAY=0 GITHUB_ACTIONS='' \
    /bin/bash -c 'set -euo pipefail; source "$1"; staple_with_retry "$2"' _ "$function_source" test.app \
    > "$case_dir/out" 2> "$case_dir/err" || status=$?
  attempts="$(cat "$case_dir/attempts" 2>/dev/null || echo 0)"
  retries="$(grep -c '^Stapling test.app failed (attempt [0-9]*/10); retrying in 0s$' "$case_dir/err" || true)"
  if [ "$status" -eq "$3" ] && [ "$attempts" -eq "$4" ] && [ "$retries" -eq "$5" ] &&
     { [ "$6" != yes ] || grep -Fq 'warning: could not staple test.app after 10 attempts' "$case_dir/err"; } &&
     { [ "$6" != error ] || grep -Fq "error: stapling test.app failed (stapler exit 65)" "$case_dir/err"; } &&
     { [ "$6" = yes ] || ! grep -q 'warning: could not staple' "$case_dir/err"; }; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (status $status, attempts $attempts, retry lines $retries)" >&2
    cat "$case_dir/err" >&2
    failures=$((failures + 1))
  fi
}

run_case 'staples first time' 0 0 1 0 no
run_case 'succeeds on the third attempt after two failures' 2 0 3 2 no
run_case 'succeeds on the last attempt' 9 0 10 9 no
run_case 'ticket server unreachable 10 times: returns 1 with a warning (ships unstapled)' 99 1 10 9 yes
run_case 'no ticket for the build ("Record not found"): fails the release' 99 1 10 9 error missing
run_case 'SUPERSEMU_STAPLE_ATTEMPTS=0 is rejected before stapling' 0 2 0 0 no unreachable 0
[ "$failures" -eq 0 ]
