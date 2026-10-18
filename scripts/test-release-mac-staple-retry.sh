#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
release_script="$script_dir/release-mac.sh"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/release-staple-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

fake_bin="$temp_dir/fakebin"
mkdir -p "$fake_bin"
function_source="$temp_dir/staple-function.sh"
sed -n '/^staple_with_retry() {$/,/^}/p' "$release_script" > "$function_source"
[ -s "$function_source" ] || { echo "FAIL: staple_with_retry function not found" >&2; exit 1; }

cat > "$fake_bin/xcrun" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${2:-}" in
  staple)
    attempt=0
    if [ -f "$STAPLE_ATTEMPT_FILE" ]; then
      IFS= read -r attempt < "$STAPLE_ATTEMPT_FILE"
    fi
    attempt=$((attempt + 1))
    printf '%s\n' "$attempt" > "$STAPLE_ATTEMPT_FILE"
    if [ "$attempt" -le "$STAPLE_FAIL_ATTEMPTS" ]; then
      exit 1
    fi
    ;;
  validate)
    printf '%s\n' validate >> "$STAPLE_VALIDATE_FILE"
    ;;
  *)
    echo "unexpected xcrun command: $*" >&2
    exit 64
    ;;
esac
STUB
chmod +x "$fake_bin/xcrun"

run_helper() {
  local fail_attempts="$1" attempt_file="$2" validate_file="$3" stdout_file="$4" stderr_file="$5"
  PATH="$fake_bin:$PATH" \
    STAPLE_FAIL_ATTEMPTS="$fail_attempts" \
    STAPLE_ATTEMPT_FILE="$attempt_file" \
    STAPLE_VALIDATE_FILE="$validate_file" \
    SUPERSEMU_STAPLE_RETRY_DELAY=0 \
    /bin/bash -c 'source "$1"; staple_with_retry "$2"' _ "$function_source" test.app \
    > "$stdout_file" 2> "$stderr_file"
}

success_attempt_file="$temp_dir/success-attempts"
success_validate_file="$temp_dir/success-validations"
success_stdout="$temp_dir/success.stdout"
success_stderr="$temp_dir/success.stderr"
if run_helper 2 "$success_attempt_file" "$success_validate_file" "$success_stdout" "$success_stderr"; then
  [ "$(<"$success_attempt_file")" -eq 3 ] ||
    { echo "FAIL: expected success on attempt 3" >&2; exit 1; }
  [ "$(wc -l < "$success_validate_file" | tr -d ' ')" -eq 1 ] ||
    { echo "FAIL: expected one successful-attempt validation" >&2; exit 1; }
  [ "$(awk '/^Stapling .* failed / { count++ } END { print count+0 }' "$success_stderr")" -eq 2 ] ||
    { echo "FAIL: expected two retry messages" >&2; exit 1; }
  grep -Fq 'Stapling test.app failed (attempt 1/6); retrying in 0s' "$success_stderr" ||
    { echo "FAIL: missing first retry message" >&2; exit 1; }
  grep -Fq 'Stapling test.app failed (attempt 2/6); retrying in 0s' "$success_stderr" ||
    { echo "FAIL: missing second retry message" >&2; exit 1; }
  printf '%s\n' 'PASS: succeeds on the third attempt after two failures'
  cat "$success_stderr"
else
  echo "FAIL: expected the third-attempt run to succeed" >&2
  cat "$success_stderr" >&2
  exit 1
fi

failure_attempt_file="$temp_dir/failure-attempts"
failure_validate_file="$temp_dir/failure-validations"
failure_stdout="$temp_dir/failure.stdout"
failure_stderr="$temp_dir/failure.stderr"
if run_helper 6 "$failure_attempt_file" "$failure_validate_file" "$failure_stdout" "$failure_stderr"; then
  echo "FAIL: six failed attempts unexpectedly succeeded" >&2
  exit 1
else
  failure_status=$?
  [ "$failure_status" -ne 0 ] ||
    { echo "FAIL: six failed attempts returned zero" >&2; exit 1; }
  [ "$(<"$failure_attempt_file")" -eq 6 ] ||
    { echo "FAIL: expected exactly six staple attempts" >&2; exit 1; }
  [ "$(awk '/^Stapling .* failed / { count++ } END { print count+0 }' "$failure_stderr")" -eq 5 ] ||
    { echo "FAIL: expected five retry messages before the final error" >&2; exit 1; }
  grep -Fq 'error: failed to staple and validate test.app after 6 attempts' "$failure_stderr" ||
    { echo "FAIL: missing final error message" >&2; exit 1; }
  [ ! -e "$failure_validate_file" ] ||
    { echo "FAIL: validation ran after every staple attempt failed" >&2; exit 1; }
  printf 'PASS: six failed attempts exit non-zero (status %s)\n' "$failure_status"
  cat "$failure_stderr"
fi
