#!/usr/bin/env bash
set -euo pipefail

if ! gh api --method POST "repos/$GITHUB_REPOSITORY/statuses/$GITHUB_SHA" \
  -f state=success -f context=fleet/publish-started -f "description=Fleet run $GITHUB_RUN_ID" --silent; then
  echo "::notice::Could not record the publication marker; continuing with the main SHA check."
fi

latest="$(gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/main" --jq '.object.sha')"
if [[ "$latest" != "$GITHUB_SHA" ]]; then
  echo 'A newer main commit exists; this release will not be published.'
  echo 'publish=false' >> "$GITHUB_OUTPUT"
else
  echo 'publish=true' >> "$GITHUB_OUTPUT"
fi
