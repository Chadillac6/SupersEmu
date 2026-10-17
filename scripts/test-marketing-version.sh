#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/release-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/release-common.sh"

assert_version() {
  local label="$1" floor="$2" versions="$3" expected="$4" actual
  actual="$(printf '%s' "$versions" | release_next_marketing_version "$floor")"
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL: %s (expected %s, got %s)\n' "$label" "$expected" "$actual" >&2
    return 1
  fi
  printf 'PASS: %s -> %s\n' "$label" "$actual"
}

assert_version "0.0.1 bumps to 0.0.2" "0.0.1" $'0.0.1\n' "0.0.2"
assert_version "numeric comparison selects 0.0.10" "0.0.1" $'0.0.9\n0.0.10\n0.0.2\n' "0.0.11"
assert_version "empty version list uses the floor" "0.0.1" "" "0.0.1"
assert_version "higher floor wins" "0.1.0" $'0.0.5\n' "0.1.0"
assert_version "latest version bumps above equal floor" "0.1.0" $'0.1.0\n' "0.1.1"
assert_version "missing patch is zero" "0.0.1" $'1.2\n' "1.2.1"
