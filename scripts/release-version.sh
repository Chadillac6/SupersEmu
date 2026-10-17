#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/release-common.sh
source scripts/release-common.sh

release_require_env
release_prepare_key
release_marketing_version
