#!/usr/bin/env bash
# Waits for another job in the current GitHub Actions run to finish, so release jobs can build
# while the checks run but publish only after they pass. Exits 0 only if the job succeeded.
# Usage: ci-wait-for-job.sh "<job name>"
set -euo pipefail
job="${1:?Pass the job name}"
repo="${GITHUB_REPOSITORY:?GitHub Actions only}"
run_id="${GITHUB_RUN_ID:?GitHub Actions only}"
interval="${SUPERSEMU_WAIT_INTERVAL:-30}"
timeout="${SUPERSEMU_WAIT_TIMEOUT:-5400}"
start=$SECONDS
while :; do
  # filter=all, newest attempt of the job: "Re-run failed jobs" leaves a passed check in an earlier attempt.
  if state="$(gh api "repos/$repo/actions/runs/$run_id/jobs?filter=all&per_page=100" \
      --jq "[.jobs[] | select(.name == \"$job\")] | sort_by(.run_attempt) | last
        | select(. != null) | \"\(.status) \(.conclusion // \"none\")\"")"; then
    case "$state" in
      'completed success') echo "$job passed."; exit 0 ;;
      completed\ *) echo "error: $job finished with '${state#completed }'; not publishing." >&2; exit 1 ;;
      '') state='not started' ;;
    esac
  else
    state='unknown (GitHub API error)'
  fi
  elapsed=$((SECONDS - start))
  if [ "$elapsed" -ge "$timeout" ]; then
    echo "error: gave up waiting for $job after ${elapsed}s (last state: $state)" >&2
    exit 1
  fi
  echo "Waiting for $job: $state (${elapsed}s)"
  sleep "$interval"
done
