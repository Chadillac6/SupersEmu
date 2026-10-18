#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ci-wait-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
fake_bin="$temp_dir/fakebin"
mkdir -p "$fake_bin"

# Each call answers with the next line of $GH_STATES, run through the script's real --jq filter:
# "status conclusion" is that one job in attempt 1, a line starting with "{" is a raw jobs page, "[" a list of pages,
# "error" fails the call and "missing" lists no jobs (not started yet).
cat > "$fake_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
calls=0
[ -f "$GH_CALLS" ] && IFS= read -r calls < "$GH_CALLS"
calls=$((calls + 1))
printf '%s\n' "$calls" > "$GH_CALLS"
[ "$1 $2 $3 $4" = "api --paginate repos/owner/repo/actions/runs/42/jobs?filter=all&per_page=100 --jq" ] \
  || { echo "unexpected gh call: $*" >&2; exit 64; }
line="$(sed -n "${calls}p" "$GH_STATES")"
case "$line" in
  error) exit 1 ;;
  missing) json='{"jobs":[]}' ;;
  '{'*) json="$line" ;;
  '['*) jq -c '.[]' <<< "$line" | while IFS= read -r page; do jq -r "$5" <<< "$page"; done; exit 0 ;;
  *) json="{\"jobs\":[{\"name\":\"Mac and server checks\",\"run_attempt\":1,\"status\":\"${line% *}\",\"conclusion\":$( [ "${line#* }" = none ] && echo null || echo "\"${line#* }\"")}]}" ;;
esac
jq -r "$5" <<< "$json"
STUB
chmod +x "$fake_bin/gh"

run_case() { # name expected-status expected-calls timeout states...
  local name="$1" expected="$2" expected_calls="$3" timeout="$4" status=0 calls
  shift 4
  printf '%s\n' "$@" > "$temp_dir/states"
  rm -f "$temp_dir/calls"
  PATH="$fake_bin:$PATH" GH_STATES="$temp_dir/states" GH_CALLS="$temp_dir/calls" \
    GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=42 SUPERSEMU_WAIT_INTERVAL=0 SUPERSEMU_WAIT_TIMEOUT="$timeout" \
    "$script_dir/ci-wait-for-job.sh" 'Mac and server checks' > "$temp_dir/out" 2>&1 || status=$?
  calls="$(<"$temp_dir/calls")"
  if [ "$status" -ne "$expected" ] || [ "$calls" -ne "$expected_calls" ]; then
    echo "FAIL: $name (status $status, $calls calls; expected $expected, $expected_calls)" >&2
    cat "$temp_dir/out" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$name"
}

run_case 'waits through queued, running and API errors, then passes' 0 5 60 \
  missing 'queued none' error 'in_progress none' 'completed success'
run_case 'failed checks block publishing' 1 2 60 'in_progress none' 'completed failure'
run_case 'cancelled checks block publishing' 1 1 60 'completed cancelled'
run_case 'gives up after the timeout' 1 1 0 'in_progress none'
run_case 'publishes a release-only rerun after checks passed in an earlier attempt' 0 1 60 \
  '{"jobs":[{"name":"Mac and server checks","run_attempt":1,"status":"completed","conclusion":"success"},{"name":"Upload iOS build to TestFlight","run_attempt":2,"status":"in_progress","conclusion":null}]}'
run_case 'uses the newest attempt of the checks' 1 2 60 \
  '{"jobs":[{"name":"Mac and server checks","run_attempt":2,"status":"in_progress","conclusion":null},{"name":"Mac and server checks","run_attempt":1,"status":"completed","conclusion":"success"}]}' \
  '{"jobs":[{"name":"Mac and server checks","run_attempt":2,"status":"completed","conclusion":"failure"},{"name":"Mac and server checks","run_attempt":1,"status":"completed","conclusion":"success"}]}'
run_case 'reads the newest attempt from a later page' 1 1 60 \
  '[{"jobs":[{"name":"Mac and server checks","run_attempt":1,"status":"completed","conclusion":"success"}]},{"jobs":[{"name":"Mac and server checks","run_attempt":2,"status":"completed","conclusion":"failure"}]}]'
