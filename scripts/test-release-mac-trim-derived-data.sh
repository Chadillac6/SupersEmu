#!/usr/bin/env bash
# Tests trim_derived_data from release-mac.sh: build intermediates go, Sparkle's SourcePackages stay.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/release-trim-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

function_source="$temp_dir/trim-function.sh"
sed -n '/^trim_derived_data() {/,/^}/p' "$script_dir/release-mac.sh" > "$function_source"
[ -s "$function_source" ] || { echo "FAIL: trim_derived_data function not found" >&2; exit 1; }
# shellcheck source=/dev/null
source "$function_source"

derived="$temp_dir/DerivedData"
tool="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
mkdir -p "$(dirname "$tool")" "$derived/Build/Intermediates.noindex/x" "$derived/ModuleCache.noindex" "$derived/Logs"
printf '#!/bin/sh\n' > "$tool"
chmod +x "$tool"
head -c 4096 /dev/zero > "$derived/Build/Intermediates.noindex/x/big.o"
touch "$derived/info.plist"

failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

output="$(trim_derived_data "$derived")"
[ -x "$tool" ] || fail "generate_appcast was removed"
remaining="$(cd "$derived" && ls -A)"
[ "$remaining" = SourcePackages ] || fail "expected only SourcePackages to remain, found: $remaining"
[[ "$output" == "Trimmed $derived from "*" (kept SourcePackages)" ]] || fail "unexpected output: $output"

trim_derived_data "$temp_dir/missing" || fail "a missing DerivedData directory should be a no-op"

[ "$failures" -eq 0 ] || exit 1
echo "PASS: trim_derived_data"
