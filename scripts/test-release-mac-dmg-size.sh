#!/usr/bin/env bash
# Tests dmg_size_mb and make_dmg from release-mac.sh: the dmg is sized from the staged files with headroom,
# and on macOS an unsigned fixture builds with the release's hdiutil flags.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/release-dmg-size-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

function_source="$temp_dir/dmg-size-function.sh"
sed -n '/^dmg_size_mb() {/,/^}/p; /^make_dmg() {/,/^}/p' "$script_dir/release-mac.sh" > "$function_source"
grep -q '^make_dmg() {' "$function_source" || { echo "FAIL: dmg_size_mb or make_dmg not found" >&2; exit 1; }
# shellcheck source=/dev/null
source "$function_source"

failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

staging="$temp_dir/dmg"
mkdir -p "$staging/SupersEmu.app/Contents"
head -c $((40 * 1024 * 1024)) /dev/zero > "$staging/SupersEmu.app/Contents/payload"
mkdir -p "$staging/SupersEmu.app/Contents/Resources"
for i in $(seq 1 2000); do printf 'file %s\n' "$i" > "$staging/SupersEmu.app/Contents/Resources/r$i.txt"; done
ln -s /Applications "$staging/Applications"

used="$(du -sm "$staging" | cut -f1)"
size="$(dmg_size_mb "$staging")"
[[ "$size" =~ ^[0-9]+$ ]] || fail "expected a whole number of MB, got: $size"
[ "$size" -ge $((used + used / 4 + 64)) ] || fail "expected at least 25% + 64 MB over $used MB, got $size"

empty="$temp_dir/empty"
mkdir -p "$empty"
[ "$(dmg_size_mb "$empty")" -ge 64 ] || fail "an empty folder should still get 64 MB of headroom"

if command -v hdiutil >/dev/null; then
  if make_dmg "$staging" "$temp_dir/fixture.dmg"; then
    hdiutil verify "$temp_dir/fixture.dmg" >/dev/null 2>&1 || fail "hdiutil verify rejected the fixture dmg"
  else
    fail "make_dmg could not build the fixture dmg"
  fi
else
  echo "hdiutil not available; skipping the dmg build"
fi

[ "$failures" -eq 0 ] || exit 1
echo "PASS: dmg_size_mb"
