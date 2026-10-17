#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/release-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/release-common.sh"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
appcast_fixture="$script_dir/mac-appcast-child-version.xml"

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

release_asc_marketing_versions() {
  printf '%s\n' "${TEST_IOS_VERSIONS:-}"
}

release_mac_marketing_version() {
  if [ "${TEST_MAC_LOOKUP_FAIL:-0}" = 1 ]; then
    return 1
  fi
  if [ -n "${TEST_MAC_APPCAST_FIXTURE:-}" ]; then
    release_mac_marketing_version_from_appcast < "$TEST_MAC_APPCAST_FIXTURE"
    return
  fi
  printf '%s\n' "${TEST_MAC_VERSION:-}"
}

assert_shared_version() {
  local label="$1" floor="$2" ios="$3" mac="$4" expected="$5" actual
  actual="$(TEST_IOS_VERSIONS="$ios" TEST_MAC_VERSION="$mac" \
    release_calculate_marketing_version "$floor")"
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL: %s (expected %s, got %s)\n' "$label" "$expected" "$actual" >&2
    return 1
  fi
  printf 'PASS: %s -> %s\n' "$label" "$actual"
}

assert_shared_version "Mac 0.0.1 and iOS 0.0.5" "0.0.1" "0.0.5" "0.0.1" "0.0.6"
assert_shared_version "Mac 0.0.7 and iOS 0.0.6" "0.0.1" "0.0.6" "0.0.7" "0.0.8"
assert_shared_version "project floor beats both releases" "0.1.0" "0.0.5" "0.0.1" "0.1.0"

fixture_version="$(release_mac_marketing_version_from_appcast < "$appcast_fixture")"
if [ "$fixture_version" != "0.0.1" ]; then
  printf 'FAIL: Sparkle child-element appcast (expected 0.0.1, got %s)\n' "$fixture_version" >&2
  exit 1
fi
echo "PASS: Sparkle child-element appcast -> $fixture_version"

fixture_shared_version="$(TEST_IOS_VERSIONS="0.0.5" TEST_MAC_APPCAST_FIXTURE="$appcast_fixture" \
  release_calculate_marketing_version "0.0.1")"
if [ "$fixture_shared_version" != "0.0.6" ]; then
  printf 'FAIL: Sparkle child-element appcast with iOS 0.0.5 (expected 0.0.6, got %s)\n' \
    "$fixture_shared_version" >&2
  exit 1
fi
echo "PASS: Sparkle child-element appcast and iOS 0.0.5 -> $fixture_shared_version"

if output="$(TEST_IOS_VERSIONS="0.0.5" TEST_MAC_LOOKUP_FAIL=1 \
  release_calculate_marketing_version "0.0.1" 2>&1)"; then
  echo "FAIL: failed Mac lookup was accepted" >&2
  exit 1
elif [[ "$output" != *"could not retrieve the latest Mac marketing version"* ]]; then
  printf 'FAIL: failed Mac lookup did not explain the error: %s\n' "$output" >&2
  exit 1
fi
echo "PASS: failed Mac lookup stops release calculation"
