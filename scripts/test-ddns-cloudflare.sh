#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
method=GET
output=
url=
payload=
while (($#)); do
  case "$1" in
    --request) method=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --data) payload=$2; shift 2 ;;
    -w|--write-out) shift 2 ;;
    -K|--config|--silent|--show-error|--max-time|--header) [[ "$1" == --silent || "$1" == --show-error ]] && { shift; continue; }; shift 2 ;;
    *) url=$1; shift ;;
  esac
done
printf '%s|%s|%s\n' "$method" "$url" "$payload" >>"$CURL_RECORD"
status=200
body=
fail_status=500
fail_body='{"success":false,"errors":[{"message":"internal error"}],"result":[]}'
if [[ "$SCENARIO" == forbidden-* ]]; then
  fail_status=403
  fail_body='{"success":false,"errors":[{"code":9109,"message":"Invalid access token"}],"result":[]}'
fi
if [[ "$url" == https://api.ipify.org ]]; then
  if [[ "$SCENARIO" == fallback ]]; then exit 22; fi
  body=${TEST_IP:-203.0.113.10}
elif [[ "$url" == https://checkip.amazonaws.com ]]; then
  body=203.0.113.10
elif [[ "$SCENARIO" == forbidden && "$url" == *"/zones?"* ]]; then
  status=403
  body='{"success":false,"errors":[{"code":9109,"message":"Invalid access token"}],"result":[]}'
elif [[ "$SCENARIO" == error-zone && "$url" == *"/zones?"* ]]; then
  status=$fail_status
  body=$fail_body
elif [[ "$SCENARIO" == *-records && "$url" == *"/dns_records?type=A"* ]]; then
  status=$fail_status
  body=$fail_body
elif [[ ( "$SCENARIO" == *-patch || "$SCENARIO" == *-post ) && ( "$method" == PATCH || "$method" == POST ) ]]; then
  status=$fail_status
  body=$fail_body
elif [[ "$url" == *"/zones?name=games.supersemu.com" ]]; then
  body='{"success":true,"result":[]}'
elif [[ "$url" == *"/zones?name=supersemu.com" ]]; then
  body='{"success":true,"result":[{"id":"zone-parent"}]}'
elif [[ "$url" == *"/zones?name=example.com" ]]; then
  body='{"success":true,"result":[{"id":"zone-example"}]}'
elif [[ "$url" == *"/dns_records?type=A"* ]]; then
  case "$SCENARIO" in
    changed|forbidden-patch|error-patch) body='{"success":true,"result":[{"id":"record-1","content":"192.0.2.1","proxied":false}]}' ;;
    unchanged) body='{"success":true,"result":[{"id":"record-1","content":"203.0.113.10","proxied":false}]}' ;;
    proxied) body='{"success":true,"result":[{"id":"record-1","content":"203.0.113.10","proxied":true}]}' ;;
    multiple) body='{"success":true,"result":[{"id":"record-1","content":"192.0.2.1","proxied":false},{"id":"record-2","content":"203.0.113.10","proxied":true}]}' ;;
    *) body='{"success":true,"result":[]}' ;;
  esac
elif [[ "$url" == *"/dns_records/record-1" && "$method" == PATCH ]]; then
  body='{"success":true,"result":{"id":"record-1"}}'
elif [[ "$url" == *"/dns_records/record-2" && "$method" == PATCH ]]; then
  body='{"success":true,"result":{"id":"record-2"}}'
elif [[ "$url" == *"/dns_records" && "$method" == POST ]]; then
  body='{"success":true,"result":{"id":"record-new"}}'
else
  status=404
  body='{"success":false,"errors":[{"message":"not found"}],"result":[]}'
fi
[[ -z "$output" ]] || printf '%s' "$body" >"$output"
printf '%s' "$status"
STUB
chmod +x "$tmp/bin/curl"

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

run_case() {
  local name=$1 scenario=$2 host=${3:-games.supersemu.com} test_ip=${4:-203.0.113.10}
  mkdir -p "$tmp/$name"
  printf '%s\n' 'token-string-must-not-appear' >"$tmp/$name/cloudflare.token"
  : >"$tmp/$name/curl.log"
  PATH="$tmp/bin:$PATH" CURL_RECORD="$tmp/$name/curl.log" SCENARIO="$scenario" TEST_IP="$test_ip" \
    SUPERSEMU_CLOUDFLARE_API=https://cloudflare.test/client/v4 \
    "$script_dir/ddns-cloudflare.sh" --host "$host" --data-dir "$tmp/$name" >"$tmp/$name/output.log" 2>&1
}

run_case create create
assert "missing record is created" grep -Fq 'POST|https://cloudflare.test/client/v4/zones/zone-parent/dns_records|' "$tmp/create/curl.log"

run_case changed changed games.supersemu.com 198.51.100.25
assert "changed IP patches existing record" grep -Fq 'PATCH|https://cloudflare.test/client/v4/zones/zone-parent/dns_records/record-1|' "$tmp/changed/curl.log"

run_case unchanged unchanged
assert "unchanged record is not written" bash -c '! grep -q "^POST|" "$1" && ! grep -q "^PATCH|" "$1"' _ "$tmp/unchanged/curl.log"

run_case proxied proxied
assert "proxied record is patched to DNS-only" grep -Fq 'PATCH|https://cloudflare.test/client/v4/zones/zone-parent/dns_records/record-1|' "$tmp/proxied/curl.log"

run_case multiple multiple
assert "both A records needing correction are patched" bash -c \
  'grep -Fq "dns_records/record-1|" "$1" && grep -Fq "dns_records/record-2|" "$1" && [[ "$(grep -c "^PATCH|" "$1")" == 2 ]]' \
  _ "$tmp/multiple/curl.log"

run_case longest create
assert "zone lookup tries longest suffix first" bash -c '[[ "$(sed -n "2p" "$1")" == *"name=games.supersemu.com"* && "$(sed -n "3p" "$1")" == *"name=supersemu.com"* ]]' _ "$tmp/longest/curl.log"

run_case fallback fallback example.com
assert "ipify failure falls back to checkip" grep -Fq 'GET|https://checkip.amazonaws.com|' "$tmp/fallback/curl.log"

mkdir -p "$tmp/forbidden"
printf '%s\n' 'token-string-must-not-appear' >"$tmp/forbidden/cloudflare.token"
: >"$tmp/forbidden/curl.log"
if PATH="$tmp/bin:$PATH" CURL_RECORD="$tmp/forbidden/curl.log" SCENARIO=forbidden \
  SUPERSEMU_CLOUDFLARE_API=https://cloudflare.test/client/v4 \
  "$script_dir/ddns-cloudflare.sh" --host games.supersemu.com --data-dir "$tmp/forbidden" >"$tmp/forbidden/output.log" 2>&1; then
  forbidden_status=0
else
  forbidden_status=$?
fi
assert "403 returns token-rejected exit status" test "$forbidden_status" -eq 3
assert "403 stores the rejected-token error" python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["lastError"] == "Cloudflare token was rejected"' "$tmp/forbidden/ddns-state.json"
assert "token never appears in recorded curl args or output" bash -c '! grep -Fq "token-string-must-not-appear" "$@"' _ "$tmp/forbidden/curl.log" "$tmp/forbidden/output.log"

# Every Cloudflare API call maps a rejected token to exit 3 and any other failure to exit 1.
run_failure_case() {
  local scenario=$1 expected_status=$2 expected_error=$3 status
  mkdir -p "$tmp/$scenario"
  printf '%s\n' 'token-string-must-not-appear' >"$tmp/$scenario/cloudflare.token"
  : >"$tmp/$scenario/curl.log"
  if PATH="$tmp/bin:$PATH" CURL_RECORD="$tmp/$scenario/curl.log" SCENARIO="$scenario" TEST_IP=198.51.100.25 \
    SUPERSEMU_CLOUDFLARE_API=https://cloudflare.test/client/v4 \
    "$script_dir/ddns-cloudflare.sh" --host games.supersemu.com --data-dir "$tmp/$scenario" >"$tmp/$scenario/output.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  assert "$scenario exits $expected_status" test "$status" -eq "$expected_status"
  assert "$scenario stores '$expected_error'" python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["lastError"] == sys.argv[2]' \
    "$tmp/$scenario/ddns-state.json" "$expected_error"
  assert "$scenario prints '$expected_error'" grep -Fxq "$expected_error" "$tmp/$scenario/output.log"
}

run_failure_case forbidden-records 3 "Cloudflare token was rejected"
run_failure_case forbidden-patch 3 "Cloudflare token was rejected"
run_failure_case forbidden-post 3 "Cloudflare token was rejected"
run_failure_case error-zone 1 "Cloudflare zone lookup failed"
run_failure_case error-records 1 "Cloudflare DNS record lookup failed"
run_failure_case error-patch 1 "Cloudflare DNS record update failed"
run_failure_case error-post 1 "Cloudflare DNS record creation failed"

if ((failures)); then
  printf 'FAIL: %d DDNS test(s)\n' "$failures" >&2
  exit 1
fi
printf 'PASS: all DDNS tests\n'
