#!/usr/bin/env bash
# Waits for jobs in the current GitHub Actions run to finish, so release jobs can build
# while the checks run but publish only after every named job passes.
# Usage: ci-wait-for-job.sh "<job name>" ["<job name>" ...]
set -euo pipefail
: "${1:?Pass at least one job name}"
repo="${GITHUB_REPOSITORY:?GitHub Actions only}"
run_id="${GITHUB_RUN_ID:?GitHub Actions only}"
interval="${SUPERSEMU_WAIT_INTERVAL:-30}"
timeout="${SUPERSEMU_WAIT_TIMEOUT:-5400}"
start=$SECONDS
while :; do
  # filter=all, newest attempt of each job across every page: "Re-run failed jobs" leaves a passed check in an
  # earlier attempt, and reruns can push the newest attempt past the first page.
  if states="$(gh api --paginate "repos/$repo/actions/runs/$run_id/jobs?filter=all&per_page=100" \
      --jq '.jobs[] | [.run_attempt, .status, (.conclusion // "none"), .name] | @tsv' \
      | sort -t $'\t' -k1,1nr)"; then
    pending=''
    for job in "$@"; do
      state="$(awk -F '\t' -v job="$job" '$4 == job { print $2, $3; exit }' <<< "$states")"
      case "$state" in
        'completed success') ;;
        completed\ *) echo "error: $job finished with '${state#completed }'; not publishing." >&2; exit 1 ;;
        *) pending+="${pending:+; }$job: ${state:-not started}" ;;
      esac
    done
    if [ -z "$pending" ]; then
      printf '%s passed.\n' "$@"
      exit 0
    fi
  else
    pending='unknown (GitHub API error)'
  fi
  elapsed=$((SECONDS - start))
  if [ "$elapsed" -ge "$timeout" ]; then
    echo "error: gave up waiting for checks after ${elapsed}s (last state: $pending)" >&2
    exit 1
  fi
  echo "Waiting for checks: $pending (${elapsed}s)"
  sleep "$interval"
done
