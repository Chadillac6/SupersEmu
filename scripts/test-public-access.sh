#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/empty-path"
events="$tmp/events"

cat >"$tmp/bin/caddy" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == validate ]]; then exit 0; fi
printf 'caddy\n' >>"$TEST_EVENTS"
exec sleep 60
STUB
cat >"$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
method=GET
output=
url=
while (($#)); do
  case "$1" in
    --request) method=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --data) shift 2 ;;
    -w|--write-out) shift 2 ;;
    -K|--config|--silent|--show-error|--max-time|--header) [[ "$1" == --silent || "$1" == --show-error ]] && { shift; continue; }; shift 2 ;;
    *) url=$1; shift ;;
  esac
done
status=200
body=
if [[ "$url" == https://api.ipify.org ]]; then
  body=203.0.113.10
elif [[ "$url" == *"/zones?"* ]]; then
  printf 'ddns\n' >>"$TEST_EVENTS"
  if [[ "$REJECT_TOKEN" == 1 ]]; then
    status=403
    body='{"success":false,"errors":[{"code":9109,"message":"Invalid access token"}],"result":[]}'
  else
    body='{"success":true,"result":[{"id":"zone-test"}]}'
  fi
elif [[ "$url" == *"/dns_records?type=A"* ]]; then
  body='{"success":true,"result":[]}'
elif [[ "$url" == *"/dns_records" && "$method" == POST ]]; then
  body='{"success":true,"result":{"id":"record-new"}}'
else
  status=404
  body='{"success":false,"errors":[{"message":"not found"}],"result":[]}'
fi
[[ -z "$output" ]] || printf '%s' "$body" >"$output"
printf '%s' "$status"
STUB
chmod +x "$tmp/bin/caddy" "$tmp/bin/curl"

failures=0
assert() {
  local label=$1
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$label"
  else
    printf 'FAIL: %s\n' "$label" >&2
    failures=$((failures + 1))
  fi
}

data="$tmp/data"
printf '%s\n' 'test-cloudflare-token' >"$tmp/token"
: >"$events"
PATH="$tmp/bin:/usr/bin:/bin" TEST_EVENTS="$events" REJECT_TOKEN=0 \
  SUPERSEMU_CLOUDFLARE_API=https://cloudflare.test/client/v4 \
  "$script_dir/public-access.sh" enable --no-launchd --host games.supersemu.com \
  --data-dir "$data" --cloudflare-token-file "$tmp/token" >"$tmp/enable.log" 2>&1

assert "Cloudflare token stored with mode 0600" bash -c '[[ "$(stat -f "%Lp" "$1")" == 600 ]]' _ "$data/cloudflare.token"
assert "DDNS runs before Caddy starts" bash -c '[[ "$(sed -n "1p" "$1")" == ddns && "$(sed -n "2p" "$1")" == caddy ]]' _ "$events"
assert "DDNS state created during enable" test -f "$data/ddns-state.json"

"$script_dir/public-access.sh" disable --no-launchd --purge --data-dir "$data" >/dev/null
assert "purge removes token and DDNS state" bash -c '[[ ! -e "$1/cloudflare.token" && ! -e "$1/ddns-state.json" && ! -e "$1/bin" ]]' _ "$data"

rejected="$tmp/rejected"
mkdir -p "$rejected"
printf '%s\n' 'test-cloudflare-token' >"$tmp/rejected-token"
: >"$events"
if PATH="$tmp/bin:/usr/bin:/bin" TEST_EVENTS="$events" REJECT_TOKEN=1 \
  SUPERSEMU_CLOUDFLARE_API=https://cloudflare.test/client/v4 \
  "$script_dir/public-access.sh" enable --no-launchd --host games.supersemu.com \
  --data-dir "$rejected" --cloudflare-token-file "$tmp/rejected-token" >"$tmp/rejected.log" 2>&1; then
  rejected_status=0
else
  rejected_status=$?
fi
assert "rejected token exits 3" test "$rejected_status" -eq 3
assert "rejected new token is removed and config is rolled back" bash -c '[[ ! -e "$1/cloudflare.token" && ! -e "$1/public-access.json" ]]' _ "$rejected"
assert "rejected token does not start Caddy" bash -c '! grep -Fqx "caddy" "$1"' _ "$events"

missing="$tmp/missing"
if PATH="$tmp/empty-path:/usr/bin:/bin" "$script_dir/public-access.sh" enable --no-launchd --host games.supersemu.com \
  --data-dir "$missing" >"$tmp/missing.log" 2>&1; then
  missing_status=0
else
  missing_status=$?
fi
assert "missing Caddy exits 5" test "$missing_status" -eq 5

if ((failures)); then
  printf 'FAIL: %d public-access test(s)\n' "$failures" >&2
  exit 1
fi
printf 'PASS: all public-access tests\n'
