#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ci-retry-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

cat > "$temp_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "api --paginate repos/owner/repo/actions/runs/42/attempts/$ATTEMPT/jobs?per_page=100 --jq "*)
    jq -r "$5" <<< "$JOBS"
    ;;
  "api repos/owner/repo/actions/workflows/8/runs?branch=main&per_page=1 --jq "*)
    jq -r "$4" <<< "{\"workflow_runs\":[{\"id\":$LATEST_RUN,\"run_attempt\":$LATEST_ATTEMPT,\"status\":\"$LATEST_STATUS\",\"head_sha\":\"abc\"}]}"
    ;;
  "api repos/owner/repo/git/ref/heads/main --jq .object.sha")
    echo "$MAIN_SHA"
    ;;
  "api --method POST repos/owner/repo/actions/runs/42/rerun-failed-jobs --silent")
    echo rerun >> "$POSTS"
    ;;
  *)
    echo "Unexpected gh command: $*" >&2
    exit 64
    ;;
esac
STUB
chmod +x "$temp_dir/gh"

run_case() {
  local name="$1" expected="$2" notice="$3" jobs="$4" attempt="$5"
  local latest_run="${6:-42}" latest_attempt="${7:-$attempt}" latest_status="${8:-completed}" main_sha="${9:-abc}"
  : > "$temp_dir/posts"
  if ! PATH="$temp_dir:$PATH" GITHUB_REPOSITORY=owner/repo \
      JOBS="$jobs" ATTEMPT="$attempt" LATEST_RUN="$latest_run" LATEST_ATTEMPT="$latest_attempt" \
      LATEST_STATUS="$latest_status" MAIN_SHA="$main_sha" POSTS="$temp_dir/posts" \
      bash "$script_dir/ci-retry-testflight.sh" 42 "$attempt" 8 > "$temp_dir/output" 2>&1 ||
      [[ "$(< "$temp_dir/posts")" != "$expected" ]] ||
      ! grep -Fq "$notice" "$temp_dir/output"; then
    echo "FAIL: $name"
    cat "$temp_dir/output" >&2
    exit 1
  fi
  echo "PASS: $name"
}

cancelled='{"jobs":[{"id":9,"name":"Upload iOS build to TestFlight","conclusion":"cancelled","runner_id":0,"steps":[]}]}'
success='{"jobs":[{"id":9,"name":"Upload iOS build to TestFlight","conclusion":"success","runner_id":123,"steps":[{"name":"Upload iOS build to TestFlight","conclusion":"success"}]}]}'
if [[ $# == 2 ]]; then
  cancelled="$(< "$1")"
  success="$(< "$2")"
fi
runner_assigned='{"jobs":[{"id":9,"name":"Upload iOS build to TestFlight","conclusion":"cancelled","runner_id":123,"steps":[]}]}'
other_job='{"jobs":[{"id":9,"name":"Publish Mac update","conclusion":"cancelled","runner_id":0,"steps":[]}]}'

run_case 'retries a TestFlight job that acquired no runner' rerun 'Requested a retry' "$cancelled" 1
run_case 'allows a second retry after another acquisition cancellation' rerun 'Requested a retry' "$cancelled" 2
run_case 'skips after a successful TestFlight upload' '' 'no TestFlight runner-acquisition cancellation' "$success" 2
run_case 'skips a cancelled job that acquired a runner' '' 'no TestFlight runner-acquisition cancellation' "$runner_assigned" 1
run_case 'skips a different job with an acquisition cancellation' '' 'no TestFlight runner-acquisition cancellation' "$other_job" 1
run_case 'skips after reaching the retry limit' '' 'retry limit reached' "$cancelled" 3
run_case 'skips when a newer Fleet run exists' '' 'no longer the latest completed attempt' "$cancelled" 1 43
run_case 'skips a delayed event after a newer attempt' '' 'no longer the latest completed attempt' "$cancelled" 1 42 2
run_case 'skips while the latest attempt is not completed' '' 'no longer the latest completed attempt' "$cancelled" 1 42 1 in_progress
run_case 'skips when main advances before Fleet queues a new run' '' 'a newer main commit exists' "$cancelled" 1 42 1 completed def
