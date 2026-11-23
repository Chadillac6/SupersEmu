#!/usr/bin/env bash
set -u

[[ "${GITHUB_RUN_ATTEMPT:-}" == 1 ]] || exit 0
repo="$GITHUB_REPOSITORY"
run_id="$GITHUB_RUN_ID"
deadline=$((SECONDS + 10200))

while (( SECONDS < deadline )); do
  replacement=''
  if runs="$(timeout 15s gh api "repos/$repo/actions/workflows/fleet.yml/runs?branch=main&per_page=100")" &&
     candidate="$(jq -r --arg repo "$repo" --argjson number "$GITHUB_RUN_NUMBER" '
       [.workflow_runs[] | select(
         .run_number > $number and .head_branch == "main" and .head_repository.full_name == $repo
         and (.event == "push" or .event == "workflow_dispatch")
       )] | max_by(.run_number) | select(.status == "pending" or .status == "waiting" or .status == "queued")
       | [.id, .head_sha] | @tsv
     ' <<< "$runs")"; then
    if [[ -n "$candidate" ]]; then
      IFS=$'\t' read -r candidate_id candidate_sha <<< "$candidate"
      if main_sha="$(timeout 15s gh api "repos/$repo/git/ref/heads/main" --jq '.object.sha')"; then
        if [[ -n "$main_sha" && "$main_sha" == "$candidate_sha" && "$main_sha" != "$GITHUB_SHA" ]]; then
          replacement="$candidate_id"
        fi
      else
        echo "::notice::Could not verify the current main commit; keeping Fleet run $run_id."
      fi
    fi
  else
    echo "::notice::Could not check for a queued replacement; keeping Fleet run $run_id."
  fi

  # Inspect jobs after seeing the newer main SHA. A later guard will see the old SHA is stale;
  # a guard already started may have approved publishing even if the publish step has not started.
  if jobs="$(timeout 15s gh api --paginate --slurp "repos/$repo/actions/runs/$run_id/attempts/1/jobs?per_page=100")" &&
     state="$(jq -r '
       [.[] | .jobs[]] |
       if ([.[] | select(.status == "completed") | .name] | contains([
         "Select release version", "Test Mac app and server", "Build iOS simulator app",
         "Mac and server checks", "Publish Mac update", "Upload iOS build to TestFlight"
       ])) then "finished"
       elif any(.[]; (.name == "Publish Mac update" or .name == "Upload iOS build to TestFlight") and (
         any(.steps[]?; (.name == "Check for newer main commit" or .name == "Publish signed Sparkle update" or
           .name == "Upload iOS build to TestFlight") and .conclusion != "skipped" and
           (.started_at != null or .status == "in_progress" or .status == "completed"))
         or (.status == "in_progress" and ([.steps[]?.name] | contains(["Check for newer main commit"]) | not))
       )) then "publishing"
       else "idle" end
     ' <<< "$jobs")"; then
    if [[ "$state" == finished ]]; then
      exit 0
    fi
    if [[ -n "$replacement" && "$state" == idle ]]; then
      echo "::notice::Fleet run $replacement is queued for the current main commit; cancelling stale Fleet run $run_id before publication."
      if timeout 15s gh api --method POST "repos/$repo/actions/runs/$run_id/cancel" --silent; then
        exit 0
      fi
      echo "::notice::Could not cancel stale Fleet run $run_id; keeping it for now."
    fi
  else
    echo "::notice::Could not check release steps; keeping Fleet run $run_id."
  fi

  sleep "${SUPERSEMU_SUPERSEDE_INTERVAL:-30}"
done

echo "::notice::Fleet supersede watcher reached its polling limit without cancelling the run."
