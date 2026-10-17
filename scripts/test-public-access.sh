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
if [[ -n ${CADDY_CALLS:-} ]]; then printf '%s\n' "$1" >>"$CADDY_CALLS"; fi
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
cat >"$tmp/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
command=$1
shift
if [[ "$command" == bootstrap ]]; then
  plist=
  for argument in "$@"; do plist=$argument; done
  case "$plist" in
    *com.chadillac6.supersemu.caddy.plist)
      if grep -Fq 'old-caddy-plist' "$plist"; then
        printf 'bootstrap-old-caddy\n' >>"$TEST_EVENTS"
        exit 0
      fi
      printf 'bootstrap-new-caddy\n' >>"$TEST_EVENTS"
      exit 1
      ;;
    *com.chadillac6.supersemu.ddns.plist)
      if grep -Fq 'old-ddns-plist' "$plist"; then
        printf 'bootstrap-old-ddns\n' >>"$TEST_EVENTS"
      else
        printf 'bootstrap-new-ddns\n' >>"$TEST_EVENTS"
      fi
      ;;
  esac
fi
printf '%s|%s\n' "$command" "$*" >>"$TEST_EVENTS"
STUB
chmod +x "$tmp/bin/caddy" "$tmp/bin/curl" "$tmp/bin/launchctl"

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
assert "public-access config is readable by the data-dir owner" test -r "$data/public-access.json"
assert "public-access config is mode 0600" bash -c '[[ "$(stat -f "%Lp" "$1")" == 600 ]]' _ "$data/public-access.json"

"$script_dir/public-access.sh" disable --no-launchd --purge --data-dir "$data" >/dev/null
assert "purge removes token and DDNS state" bash -c '[[ ! -e "$1/cloudflare.token" && ! -e "$1/ddns-state.json" && ! -e "$1/bin" ]]' _ "$data"

path_data="$tmp/path-data"
caddy_calls="$tmp/caddy-calls"
: >"$events"
if PATH=/usr/bin:/bin TEST_EVENTS="$events" CADDY_CALLS="$caddy_calls" \
  SUPERSEMU_CADDY_PATH="$tmp/bin/caddy" \
  "$script_dir/public-access.sh" enable --local-test --no-launchd --host localhost \
  --data-dir "$path_data" >"$tmp/path-enable.log" 2>&1; then
  path_status=0
else
  path_status=$?
fi
assert "enable works with Caddy outside the restricted PATH" test "$path_status" -eq 0
assert "restricted-PATH enable validates and runs Caddy" bash -c \
  '[[ -f "$1" && "$(wc -l <"$1")" -eq 2 && "$(sed -n "1p" "$1")" == validate && "$(sed -n "2p" "$1")" == run ]]' \
  _ "$caddy_calls"
"$script_dir/public-access.sh" disable --no-launchd --purge --data-dir "$path_data" >/dev/null

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

rollback_data="$tmp/rollback-data"
rollback_launchd="$tmp/rollback-launchd"
mkdir -p "$rollback_data" "$rollback_launchd"
printf '%s\n' 'rollback-token' >"$rollback_data/cloudflare.token"
printf '%s\n' 'old-caddy-plist' >"$rollback_launchd/com.chadillac6.supersemu.caddy.plist"
printf '%s\n' 'old-ddns-plist' >"$rollback_launchd/com.chadillac6.supersemu.ddns.plist"
: >"$events"
if PATH="$tmp/bin:/usr/bin:/bin" TEST_EVENTS="$events" REJECT_TOKEN=0 \
  SUPERSEMU_CLOUDFLARE_API=https://cloudflare.test/client/v4 \
  SUPERSEMU_LAUNCHD_DIR="$rollback_launchd" \
  "$script_dir/public-access.sh" enable --host games.supersemu.com --data-dir "$rollback_data" \
  >"$tmp/rollback.log" 2>&1; then
  rollback_status=0
else
  rollback_status=$?
fi
assert "failed Caddy bootstrap exits nonzero" test "$rollback_status" -ne 0
assert "failed Caddy bootstrap restores the previous plists" bash -c \
  'grep -Fq "old-caddy-plist" "$1" && grep -Fq "old-ddns-plist" "$2"' _ \
  "$rollback_launchd/com.chadillac6.supersemu.caddy.plist" \
  "$rollback_launchd/com.chadillac6.supersemu.ddns.plist"
assert "failed Caddy bootstrap re-bootstraps both previous jobs" bash -c \
  'grep -Fq "bootstrap-old-caddy" "$1" && grep -Fq "bootstrap-old-ddns" "$1"' _ "$events"

missing="$tmp/missing"
if PATH="$tmp/empty-path:/usr/bin:/bin" SUPERSEMU_CADDY_PATH="$tmp/empty-path/caddy" \
  "$script_dir/public-access.sh" enable --no-launchd --host games.supersemu.com \
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
