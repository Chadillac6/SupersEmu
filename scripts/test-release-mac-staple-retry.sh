#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
release_script="$script_dir/release-mac.sh"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/release-staple-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

fake_bin="$temp_dir/fakebin"
mkdir -p "$fake_bin"
function_source="$temp_dir/staple-function.sh"
sed -n '/^staple_or_warn() {/,/^}/p' "$release_script" > "$function_source"
[ -s "$function_source" ] || fail "staple_or_warn function not found"

# Fake xcrun: `stapler staple` fails for the first STAPLE_FAIL_ATTEMPTS calls; `stapler validate`
# always fails, like Apple's ticket lookup did on the 0ef4e26 release run after a successful staple.
cat > "$fake_bin/xcrun" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$XCRUN_LOG"
case "${2:-}" in
  staple)
    attempts="$(grep -c ' staple ' "$XCRUN_LOG" || true)"
    [ "$attempts" -gt "$STAPLE_FAIL_ATTEMPTS" ] || exit 65
    ;;
  validate) exit 65 ;;
  *) echo "unexpected xcrun command: $*" >&2; exit 64 ;;
esac
STUB
chmod +x "$fake_bin/xcrun"

run_helper() { # fail_attempts name
  local log="$temp_dir/$2.log"
  : > "$log"
  set +e
  PATH="$fake_bin:$PATH" XCRUN_LOG="$log" STAPLE_FAIL_ATTEMPTS="$1" \
    SUPERSEMU_STAPLE_RETRY_DELAY=0 SUPERSEMU_STAPLE_ATTEMPTS=8 \
    /bin/bash -c 'source "$1"; staple_or_warn "$2"' _ "$function_source" test.app \
    > "$temp_dir/$2.stdout" 2> "$temp_dir/$2.stderr"
  status=$?
  set -e
  staples="$(grep -c ' staple ' "$log" || true)"
  validates="$(grep -c ' validate ' "$log" || true)"
  retries="$(grep -c '^Stapling test.app failed ' "$temp_dir/$2.stderr" || true)"
}

run_helper 0 first
[ "$status" -eq 0 ] || fail "first-try staple returned $status"
[ "$staples" -eq 1 ] && [ "$validates" -eq 0 ] || fail "first-try: $staples staples, $validates validates"
echo "PASS: staples on the first try and doesn't re-check with a separate validate"

run_helper 2 third
[ "$status" -eq 0 ] || fail "third-try staple returned $status"
[ "$staples" -eq 3 ] && [ "$retries" -eq 2 ] && [ "$validates" -eq 0 ] ||
  fail "third-try: $staples staples, $retries retries, $validates validates"
grep -Fq 'Stapling test.app failed (attempt 2/8); retrying in 0s' "$temp_dir/third.stderr" || fail "missing retry message"
echo "PASS: retries until the ticket is available (success on attempt 3)"

run_helper 99 never
[ "$status" -eq 1 ] || fail "unreachable ticket server returned $status, want 1 (unstapled)"
[ "$staples" -eq 8 ] && [ "$retries" -eq 7 ] || fail "never: $staples staples, $retries retries"
grep -Fq '::warning::Could not staple test.app after 8 attempts' "$temp_dir/never.stderr" || fail "missing warning"
echo "PASS: gives up after 8 attempts with a warning and status 1 (left unstapled)"

# The release must keep going (and publish) when stapling is skipped.
grep -Fq 'staple_or_warn "$app" || {' "$release_script" && grep -Fq 'touch "$out/app-unstapled"' "$release_script" ||
  fail "app staple failure isn't handled"
grep -Fq '[ -e "$out/app-unstapled" ] || exit 1' "$script_dir/prepare-mac-appcast.sh" ||
  fail "prepare-mac-appcast.sh doesn't allow an unstapled (notarized) app"
grep -Fq 'if staple_or_warn "$out/$name.dmg"; then' "$release_script" || fail "DMG staple failure isn't handled"
! grep -E '^[[:space:]]*staple_or_warn "' "$release_script" | grep -vq '||' || fail "an unguarded staple_or_warn call would abort the release"
! grep -q 'stapler validate' "$release_script" || fail "release still gates on 'stapler validate'"
echo "PASS: release-mac.sh continues to publish when stapling is skipped"
