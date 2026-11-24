#!/usr/bin/env bash
set -euo pipefail

temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
mkdir -p "$temp_dir/scripts" "$temp_dir/bin"
script="$temp_dir/scripts/fetch-test-roms.sh"
fixtures="$temp_dir/Tests/Fixtures/local"
source_script="$(dirname "${BASH_SOURCE[0]}")/fetch-test-roms.sh"

printf 'fixture bytes\n' > "$temp_dir/noudar.0.0.2.32x"
sha="$(shasum -a 256 "$temp_dir/noudar.0.0.2.32x" | cut -d' ' -f1)"
sed -E "s/[a-f0-9]{64}/$sha/g" "$source_script" > "$script"
(cd "$temp_dir" && zip -q noudar.zip noudar.0.0.2.32x)

cat > "$temp_dir/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *'--retry 2 --retry-all-errors --connect-timeout 10 --max-time 30'* ]]
while [[ "$1" != -o ]]; do shift; done
url="$3"
printf '%s\n' "${url%%\?*}" >> "$CURL_LOG"
case "$url" in
  */HelloWorld.sfc)
    [[ "${FAIL_SNES:-}" != 1 ]] || exit 22
    printf 'fixture bytes\n' > "$2"
    ;;
  https://github.com/*/chroma-circuit.cdi)
    printf 'different rolling release\n' > "$2"
    ;;
  */noudar.0.0.2.32x.zip)
    cp "$TEST_ARCHIVE" "$2"
    ;;
  *)
    printf 'fixture bytes\n' > "$2"
    ;;
esac
SH
chmod +x "$temp_dir/bin/curl"
export PATH="$temp_dir/bin:$PATH" CURL_LOG="$temp_dir/requests" TEST_ARCHIVE="$temp_dir/noudar.zip"

mkdir -p "$fixtures"
printf 'corrupt cached disc\n' > "$fixtures/chroma-circuit.cdi"
output="$(GITHUB_OUTPUT="$temp_dir/complete" bash "$script" --require-all 2>&1)"
[[ "$output" == *'Fixtures ready'*'(0 unavailable)' ]]
[[ "$(cat "$temp_dir/complete")" == 'complete=true' ]]
[[ "$output" == *'SHA-256 mismatch for chroma-circuit.cdi'* ]]
grep -q '^https://web.archive.org/' "$CURL_LOG"
cmp "$fixtures/chroma-circuit.cdi" "$temp_dir/noudar.0.0.2.32x"
cmp "$fixtures/noudar.32x" "$temp_dir/noudar.0.0.2.32x"
echo 'PASS: cold fetch, corrupt CDI repaired via verified fallback, ZIP extracted'

: > "$CURL_LOG"
bash "$script" --require-all
[[ ! -s "$CURL_LOG" ]]
echo 'PASS: verified fixture files reused without network calls'

rm "$fixtures/HelloWorld.sfc"
status=0
output="$(FAIL_SNES=1 bash "$script" --require-all 2>&1)" || status=$?
[[ "$status" == 1 ]]
[[ "$output" == *'::error title=Test fixture unavailable::Could not download and verify HelloWorld.sfc'* ]]
[[ "$output" == *'Test fixture setup incomplete: 1 unavailable'* ]]
echo 'PASS: missing required fixture fails with a named annotation'

printf 'corrupt cached ROM\n' > "$fixtures/HelloWorld.sfc"
output="$(FAIL_SNES=1 GITHUB_STEP_SUMMARY="$temp_dir/summary" GITHUB_OUTPUT="$temp_dir/incomplete" \
  bash "$script" --allow-missing 2>&1)"
[[ "$output" == *'::error title=Test fixture unavailable::Could not download and verify HelloWorld.sfc'* ]]
[[ "$(cat "$temp_dir/summary")" == *'Test fixture unavailable: `HelloWorld.sfc`'* ]]
[[ ! -e "$fixtures/HelloWorld.sfc" && ! -s "$temp_dir/incomplete" ]]
echo 'PASS: main mode annotates and summarizes missing fixtures without failing or marking the cache complete'

output="$(FAIL_SNES=1 bash "$script" 2>&1)"
[[ "$output" == *'warning: could not download and verify HelloWorld.sfc'* ]]
[[ "$output" != *'::error'* ]]
echo 'PASS: local fetch still reports failures without blocking tests'
