#!/usr/bin/env bash
set -euo pipefail

run_id="${1:?Pass the Fleet run ID}"
attempt="${2:?Pass the Fleet run attempt}"
workflow_id="${3:?Pass the Fleet workflow ID}"
repo="${GITHUB_REPOSITORY:?GitHub Actions only}"

if (( attempt >= 3 )); then
  echo "::notice::Skipping Fleet run $run_id: retry limit reached (attempt $attempt)."
  exit 0
fi

unacquired_job="$(gh api --paginate "repos/$repo/actions/runs/$run_id/attempts/$attempt/jobs?per_page=100" --jq '
  .jobs[] | select(
    .name == "Upload iOS build to TestFlight" and .conclusion == "cancelled"
    and .runner_id == 0 and .steps == []
  ) | .id
')"
if [[ -z "$unacquired_job" ]]; then
  echo "::notice::Skipping Fleet run $run_id attempt $attempt: no TestFlight runner-acquisition cancellation."
  exit 0
fi

acquisition_failure="$(gh api --paginate "repos/$repo/check-runs/$unacquired_job/annotations?per_page=100" --jq '
  .[] | select(.message | contains("not acquired by Runner")) | .message
')"
if [[ -z "$acquisition_failure" ]]; then
  echo "::notice::Skipping Fleet run $run_id attempt $attempt: GitHub did not report a runner-acquisition failure."
  exit 0
fi

latest="$(gh api --paginate "repos/$repo/actions/workflows/$workflow_id/runs?branch=main&per_page=100" |
  jq -r --arg repo "$repo" '
    .workflow_runs[] | select(
      (.event == "push" or .event == "workflow_dispatch") and .head_repository.full_name == $repo
    ) | [.id, .run_attempt, .status, .head_sha] | @tsv
  ')"
IFS=$'\t' read -r latest_run latest_attempt latest_status latest_sha <<< "$latest"
if [[ "$latest_run" != "$run_id" || "$latest_attempt" != "$attempt" || "$latest_status" != completed ]]; then
  echo "::notice::Skipping Fleet run $run_id attempt $attempt: no longer the latest completed attempt of the latest Fleet run on main."
  exit 0
fi

main_sha="$(gh api "repos/$repo/git/ref/heads/main" --jq '.object.sha')"
if [[ "$latest_sha" != "$main_sha" ]]; then
  echo "::notice::Skipping Fleet run $run_id attempt $attempt: a newer main commit exists."
  exit 0
fi

gh api --method POST "repos/$repo/actions/runs/$run_id/rerun-failed-jobs" --silent
echo "::notice::Requested a retry of Fleet run $run_id after TestFlight did not acquire a runner on attempt $attempt."
