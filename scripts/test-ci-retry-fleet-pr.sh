#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ci-retry-fleet-pr-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

cat > "$temp_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "api --paginate --slurp repos/owner/repo/actions/runs/$RUN_ID/attempts/$ATTEMPT/jobs?per_page=100")
    jq -c '[.]' <<< "$JOBS"
    ;;
  "api --paginate repos/owner/repo/check-runs/"*"/annotations?per_page=100 --jq "*)
    jq -r "$5" <<< "$ANNOTATIONS"
    ;;
  "api --method GET --paginate --slurp repos/owner/repo/actions/workflows/8/runs -f event=pull_request -f branch=$HEAD_BRANCH -f head_sha=abc -f per_page=100")
    printf '[{"workflow_runs":[{"id":99,"run_number":99,"head_repository":{"id":99}},{"id":%s,"run_number":1,"run_attempt":%s,"status":"completed","conclusion":"failure","head_repository":{"id":%s}}]}]\n' \
      "$LATEST_RUN" "$LATEST_ATTEMPT" "$HEAD_REPO_ID"
    ;;
  "api --method GET --paginate --slurp repos/owner/repo/pulls -f state=open -f head=$HEAD_OWNER:$HEAD_BRANCH -f per_page=100")
    printf '%s\n' "$PRS"
    ;;
  "api --method POST repos/owner/repo/actions/runs/$RUN_ID/rerun-failed-jobs --silent")
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
  local name="$1" expected="$2" notice="$3" jobs="$4"
  local run_id="${RUN_ID:-42}" attempt="${ATTEMPT:-1}" sha="${PR_SHA:-abc}"
  local head_owner="${HEAD_OWNER:-owner}" head_branch='feature/my-check'
  local head_repo_id="${HEAD_REPO_ID:-7}" prs="${PRS:-}"
  if [[ -z "$prs" ]]; then
    prs="$(jq -nc --arg branch "$head_branch" --argjson id "$head_repo_id" --arg sha "$sha" \
      '[[{head:{ref:$branch,repo:{id:$id},sha:$sha}}]]')"
  fi
  jq -nc --argjson id "$run_id" --argjson attempt "$attempt" --arg branch "$head_branch" \
    --argjson repo_id "$head_repo_id" --arg owner "$head_owner" '
      {workflow_run:{id:$id,run_attempt:$attempt,event:"pull_request",status:"completed",conclusion:"failure",
       workflow_id:8,head_sha:"abc",head_branch:$branch,head_repository:{id:$repo_id,owner:{login:$owner}},pull_requests:[]}}
    ' > "$temp_dir/event"
  : > "$temp_dir/posts"
  if ! PATH="$temp_dir:$PATH" GITHUB_REPOSITORY=owner/repo GITHUB_EVENT_PATH="$temp_dir/event" \
      JOBS="$jobs" ANNOTATIONS="${ANNOTATIONS:-$acquisition_annotation}" POSTS="$temp_dir/posts" \
      RUN_ID="$run_id" ATTEMPT="$attempt" HEAD_BRANCH="$head_branch" HEAD_OWNER="$head_owner" HEAD_REPO_ID="$head_repo_id" \
      LATEST_RUN="${LATEST_RUN:-$run_id}" LATEST_ATTEMPT="${LATEST_ATTEMPT:-$attempt}" PRS="$prs" \
      bash "$script_dir/ci-retry-fleet-pr.sh" > "$temp_dir/output" 2>&1 ||
      [[ "$(< "$temp_dir/posts")" != "$expected" ]] ||
      ! grep -Fq "$notice" "$temp_dir/output"; then
    echo "FAIL: $name"
    cat "$temp_dir/output" >&2
    exit 1
  fi
  echo "PASS: $name"
}

acquisition_annotation='[{"annotation_level":"failure","message":"The job was not acquired by Runner of type hosted even after multiple attempts"}]'
unacquired='{"id":9,"name":"Build and test iOS app","labels":["macos-15"],"conclusion":"cancelled","runner_id":0,"steps":[]}'
gate='{"id":10,"name":"Mac and server checks","labels":["ubuntu-latest"],"conclusion":"failure","runner_id":123}'
tests_failed='{"id":11,"name":"Test Mac app and server","labels":["macos-15"],"conclusion":"failure","runner_id":123,"steps":[{"name":"Test Mac app","conclusion":"failure"}]}'
split="{\"jobs\":[$unacquired,$gate]}"
single="{\"jobs\":[$unacquired]}"
mixed="{\"jobs\":[$unacquired,$gate,$tests_failed]}"

if [[ $# == 5 ]]; then
  RUN_ID="$1" ANNOTATIONS="$(< "$3")" run_case "replay Fleet run $1" "$4" "$5" "$(< "$2")"
  exit 0
fi

run_case 'retries the unacquired simulator job and its dependent gate' rerun 'Requested a retry' "$split"
run_case 'retries an unacquired Mac job when there is no separate gate' rerun 'Requested a retry' "$single"
HEAD_OWNER=fork-owner HEAD_REPO_ID=8 run_case 'identifies a fork PR even without a linked PR in the event' rerun 'Requested a retry' "$split"
ATTEMPT=2 run_case 'allows one more retry after another acquisition failure' rerun 'Requested a retry' "$split"
ATTEMPT=3 run_case 'enforces the attempt cap' '' 'retry limit reached' "$split"
ANNOTATIONS='[]' run_case 'does not retry an ordinary cancellation' '' 'GitHub did not report a runner-acquisition failure' "$split"
run_case 'does not retry a real Mac failure even when iOS also had no runner' '' 'another job failed or was cancelled' "$mixed"
run_case 'does not retry a gate-only failure' '' 'no macOS runner-acquisition cancellation' "{\"jobs\":[$gate]}"
LATEST_RUN=43 run_case 'does not retry when a newer run exists for this head' '' 'no longer the latest failed Fleet attempt' "$split"
LATEST_ATTEMPT=2 run_case 'does not retry a delayed event from an older attempt' '' 'no longer the latest failed Fleet attempt' "$split"
PR_SHA=def run_case 'does not retry a superseded commit before its Fleet run starts' '' 'the PR is closed, ambiguous, or has a newer head' "$split"
PRS='[[]]' run_case 'does not retry a closed PR' '' 'the PR is closed, ambiguous, or has a newer head' "$split"
