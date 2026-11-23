#!/usr/bin/env bash
set -euo pipefail

repo="${GITHUB_REPOSITORY:?GitHub Actions only}"
event_path="${GITHUB_EVENT_PATH:?GitHub Actions only}"
run="$(jq -c '.workflow_run | select(.event == "pull_request" and .status == "completed" and .conclusion == "failure")' "$event_path")"
[[ -n "$run" ]] || exit 0
run_id="$(jq -r '.id' <<< "$run")"
attempt="$(jq -r '.run_attempt' <<< "$run")"

skip() {
  echo "::notice::Skipping Fleet PR run $run_id attempt $attempt: $1."
  exit 0
}

(( attempt < 3 )) || skip 'retry limit reached'

jobs="$(gh api --paginate --slurp "repos/$repo/actions/runs/$run_id/attempts/$attempt/jobs?per_page=100")"
failed_jobs="$(jq -r '
  .[].jobs[] | select(.conclusion != "success" and .conclusion != "skipped") |
  if .conclusion == "cancelled" and .runner_id == 0 and .steps == []
     and any(.labels[]; startswith("macos-")) then .id
  elif .name == "Mac and server checks" and .conclusion == "failure"
     and any(.labels[]; startswith("ubuntu-")) then empty
  else "other"
  end
' <<< "$jobs")"
[[ -n "$failed_jobs" ]] || skip 'no macOS runner-acquisition cancellation'

while IFS= read -r job_id; do
  [[ "$job_id" != other ]] || skip 'another job failed or was cancelled'
  annotation="$(gh api --paginate "repos/$repo/check-runs/$job_id/annotations?per_page=100" --jq '
    .[] | select(.annotation_level == "failure" and .message == "The job was not acquired by Runner of type hosted even after multiple attempts") | .message
  ')"
  [[ -n "$annotation" ]] || skip 'GitHub did not report a runner-acquisition failure'
done <<< "$failed_jobs"

workflow_id="$(jq -r '.workflow_id' <<< "$run")"
head_branch="$(jq -r '.head_branch // empty' <<< "$run")"
head_sha="$(jq -r '.head_sha // empty' <<< "$run")"
head_repo_id="$(jq -r '.head_repository.id // empty' <<< "$run")"
head_owner="$(jq -r '.head_repository.owner.login // empty' <<< "$run")"
[[ -n "$head_branch" && -n "$head_sha" && -n "$head_repo_id" && -n "$head_owner" ]] ||
  skip 'the PR head no longer exists'

latest="$(gh api --method GET --paginate --slurp "repos/$repo/actions/workflows/$workflow_id/runs" \
  -f event=pull_request -f "branch=$head_branch" -f "head_sha=$head_sha" -f per_page=100 |
  jq -r --argjson head_repo_id "$head_repo_id" '
    [.[].workflow_runs[] | select(.head_repository.id == $head_repo_id)] | max_by(.run_number) |
    [.id, .run_attempt, .status, .conclusion] | @tsv
  ')"
IFS=$'\t' read -r latest_id latest_attempt latest_status latest_conclusion <<< "$latest"
[[ "$latest_id" == "$run_id" && "$latest_attempt" == "$attempt" &&
   "$latest_status" == completed && "$latest_conclusion" == failure ]] ||
  skip 'no longer the latest failed Fleet attempt for this PR head'

prs="$(gh api --method GET --paginate --slurp "repos/$repo/pulls" \
  -f state=open -f "head=$head_owner:$head_branch" -f per_page=100)"
matching_prs="$(jq -r --argjson head_repo_id "$head_repo_id" --arg head_branch "$head_branch" '
  [.[][] | select(.head.repo.id == $head_repo_id and .head.ref == $head_branch)] |
  if length == 1 then .[0].head.sha else empty end
' <<< "$prs")"
[[ "$matching_prs" == "$head_sha" ]] || skip 'the PR is closed, ambiguous, or has a newer head'

gh api --method POST "repos/$repo/actions/runs/$run_id/rerun-failed-jobs" --silent
echo "::notice::Requested a retry of Fleet PR run $run_id after macOS runner acquisition failed on attempt $attempt."
