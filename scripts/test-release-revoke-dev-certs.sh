#!/usr/bin/env bash
# Checks release_revoke_dev_certs against a fake App Store Connect (curl stub on PATH).
set -euo pipefail
# shellcheck source=scripts/release-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/release-common.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
make_cert() {
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/$1.key" -out "$work/$1.pem" \
    -subj "/CN=$2" -days 1 2>/dev/null
  grep -v -- '-----' "$work/$1.pem" | tr -d '\n'
}
runner_content="$(make_cert runner 'Apple Development: Created via API')"
other_content="$(make_cert other 'Apple Development: Created via API')"

mkdir "$work/bin"
cat > "$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
url="${*: -1}"
case " $* " in
  *" -X DELETE "*)
    echo "$url" >> "$FAKE_ASC_DELETES"
    [ "${FAKE_ASC_DELETE_FAIL:-0}" = 1 ] && { echo 'curl: (22) 403' >&2; exit 22; }
    exit 0 ;;
esac
cat "$FAKE_ASC_LIST"
CURL
chmod +x "$work/bin/curl"
cat > "$work/list.json" <<JSON
{"data": [
  {"id": "OTHERDEV1", "attributes": {"certificateType": "DEVELOPMENT", "certificateContent": "$other_content"}},
  {"id": "RUNNERDEV", "attributes": {"certificateType": "DEVELOPMENT", "certificateContent": "$runner_content"}},
  {"id": "DISTRIB01", "attributes": {"certificateType": "DISTRIBUTION", "certificateContent": "$runner_content"}}
]}
JSON
: > "$work/header"
export FAKE_ASC_LIST="$work/list.json" FAKE_ASC_DELETES="$work/deletes"

run_revoke() {
  : > "$FAKE_ASC_DELETES"
  PATH="$work/bin:$PATH" release_revoke_dev_certs "$work/header" "$1"
}

output="$(run_revoke "$work/runner.pem")"
if [ "$(cat "$FAKE_ASC_DELETES")" != "https://api.appstoreconnect.apple.com/v1/certificates/RUNNERDEV" ]; then
  printf 'FAIL: expected only RUNNERDEV revoked, got: %s\n' "$(cat "$FAKE_ASC_DELETES")" >&2
  exit 1
fi
[[ "$output" == *"Revoked temporary development certificate RUNNERDEV"* ]] ||
  { printf 'FAIL: revoke not reported: %s\n' "$output" >&2; exit 1; }
echo "PASS: only this runner's DEVELOPMENT certificate is revoked"

: > "$work/empty.pem"
output="$(run_revoke "$work/empty.pem")"
[ ! -s "$FAKE_ASC_DELETES" ] && [[ "$output" == *"No temporary development certificate"* ]] ||
  { printf 'FAIL: empty keychain export revoked something: %s\n' "$output" >&2; exit 1; }
echo "PASS: nothing to revoke when the runner has no temporary certificate"

make_cert unknown 'Apple Development: Created via API' > /dev/null
output="$(run_revoke "$work/unknown.pem")"
[ ! -s "$FAKE_ASC_DELETES" ] && [[ "$output" == *"No matching development certificate"* ]] ||
  { printf 'FAIL: unmatched certificate revoked something: %s\n' "$output" >&2; exit 1; }
echo "PASS: certificates not on App Store Connect are left alone"

if output="$(FAKE_ASC_DELETE_FAIL=1 run_revoke "$work/runner.pem" 2>&1)"; then
  echo "FAIL: a failed revoke was reported as success" >&2
  exit 1
elif [[ "$output" != *"could not revoke temporary development certificates"* ]]; then
  printf 'FAIL: failed revoke did not explain the error: %s\n' "$output" >&2
  exit 1
fi
echo "PASS: a failed revoke returns an error"
