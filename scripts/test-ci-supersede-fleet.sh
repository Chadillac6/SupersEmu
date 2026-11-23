#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ci-supersede-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

cat > "$temp_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${0##*/}" == timeout ]]; then
  shift 2
fi
case "$*" in
  "api repos/owner/repo/actions/workflows/fleet.yml/runs?branch=main&per_page=100")
    echo runs >> "$CALLS"
    printf '{"workflow_runs":[%s]}\n' "$RUNS"
    ;;
  "api repos/owner/repo/git/ref/heads/main --jq .object.sha")
    echo main >> "$CALLS"
    echo "$MAIN_SHA"
    ;;
  "api --paginate --slurp repos/owner/repo/actions/runs/42/attempts/1/jobs?per_page=100")
    if grep -Fxq jobs "$CALLS"; then
      printf '%s\n' "$FINISHED"
    else
      echo jobs >> "$CALLS"
      [[ "$JOBS" != error ]] || exit 1
      printf '[{"jobs":[%s]}]\n' "$JOBS"
    fi
    ;;
  "api --method POST repos/owner/repo/actions/runs/42/cancel --silent")
    echo cancel >> "$CALLS"
    ;;
  *)
    echo "Unexpected gh command: $*" >&2
    exit 64
    ;;
esac
STUB
chmod +x "$temp_dir/gh"
ln -s gh "$temp_dir/timeout"

queued_run() {
  jq -nc --arg status "$1" --arg sha "${2:-new}" '
    {id:43,run_number:211,head_branch:"main",head_sha:$sha,event:"push",head_repository:{full_name:"owner/repo"},status:$status}'
}

release_job() {
  jq -nc --arg job "$1" --arg step "$2" --arg state "$3" '
    {name:$job,status:"in_progress",steps:[
      {name:"Check for newer main commit",status:"queued"},
      {name:$step,status:$state}
    ]}'
}

finished='[{"jobs":[
  {"name":"Select release version","status":"completed"},
  {"name":"Test Mac app and server","status":"completed"},
  {"name":"Build iOS simulator app","status":"completed"},
  {"name":"Mac and server checks","status":"completed"},
  {"name":"Publish Mac update","status":"completed"},
  {"name":"Upload iOS build to TestFlight","status":"completed"}
]}]'

run_case() {
  local name="$1" expected="$2" runs="$3" jobs="$4"
  local attempt="${5:-1}" main_sha="${6:-new}" actual
  : > "$temp_dir/calls"
  if ! PATH="$temp_dir:$PATH" GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=42 GITHUB_RUN_NUMBER=210 \
      GITHUB_RUN_ATTEMPT="$attempt" GITHUB_SHA=old SUPERSEMU_SUPERSEDE_INTERVAL=0 \
      CALLS="$temp_dir/calls" RUNS="$runs" JOBS="$jobs" FINISHED="$finished" MAIN_SHA="$main_sha" \
      perl -e 'alarm shift; exec @ARGV or die $!;' 5 bash "$script_dir/ci-supersede-fleet.sh" > "$temp_dir/output" 2>&1; then
    echo "FAIL: $name"
    cat "$temp_dir/output" >&2
    exit 1
  fi
  actual="$(paste -sd ' ' "$temp_dir/calls")"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $name (expected calls '$expected', got '$actual')" >&2
    cat "$temp_dir/output" >&2
    exit 1
  fi
  echo "PASS: $name"
}

pending="$(queued_run pending)"
testflight_idle="$(release_job 'Upload iOS build to TestFlight' 'Upload iOS build to TestFlight' queued)"
testflight_upload="$(release_job 'Upload iOS build to TestFlight' 'Upload iOS build to TestFlight' in_progress)"
mac_publish="$(release_job 'Publish Mac update' 'Publish signed Sparkle update' in_progress)"
guard_started="$(jq -c '.steps[0].status = "completed" | .steps[0].started_at = "2026-11-23T19:35:09Z"' <<< "$testflight_idle")"

run_case 'cancels only after confirming a newer pending run and no publication' 'runs main jobs cancel' "$pending" "$testflight_idle"
run_case 'keeps a run with a started TestFlight upload' 'runs main jobs runs main' "$pending" "$testflight_upload"
run_case 'keeps a run with a started Mac publish step' 'runs main jobs runs main' "$pending" "$mac_publish"
run_case 'keeps a run whose publication guard may already have approved uploading' 'runs main jobs runs main' "$pending" "$guard_started"
run_case 'keeps a run when there is no newer run' 'runs jobs runs' '' "$testflight_idle"
run_case 'leaves a Fleet retry entirely untouched' '' "$pending" "$testflight_idle" 2
run_case 'ignores a newer run already in progress' 'runs jobs runs' "$(queued_run in_progress)" "$testflight_idle"
run_case 'ignores a newer completed run' 'runs jobs runs' "$(queued_run completed)" "$testflight_idle"
run_case 'ignores a dispatch for the same main SHA' 'runs main jobs runs main' "$(queued_run queued old)" "$testflight_idle" 1 old
run_case 'keeps the run when the pending replacement is not current main' 'runs main jobs runs main' "$pending" "$testflight_idle" 1 other
run_case 'keeps the run when its jobs cannot be inspected' 'runs main jobs runs main' "$pending" error
