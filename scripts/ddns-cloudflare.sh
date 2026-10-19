#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: ddns-cloudflare.sh --host <fqdn> --data-dir <path> [--token-file <path>]" >&2
}

host=
data_dir=
token_file=
while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || { usage; exit 2; }; host=$2; shift 2 ;;
    --data-dir) (($# >= 2)) || { usage; exit 2; }; data_dir=$2; shift 2 ;;
    --token-file) (($# >= 2)) || { usage; exit 2; }; token_file=$2; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -n "$host" && -n "$data_dir" ]] || { usage; exit 2; }
[[ "$host" =~ ^[A-Za-z0-9.-]+$ && "$host" == *.* ]] || { usage; exit 2; }
token_file=${token_file:-"$data_dir/cloudflare.token"}
state_file="$data_dir/ddns-state.json"
api=${SUPERSEMU_CLOUDFLARE_API:-https://api.cloudflare.com/client/v4}
api=${api%/}
mkdir -p "$data_dir"
response_file=$(mktemp "$data_dir/.ddns-response.XXXXXX")
curl_config=$(mktemp "$data_dir/.ddns-curl.XXXXXX")
chmod 600 "$response_file" "$curl_config"
trap 'rm -f "$response_file" "$curl_config"' EXIT

write_state() {
  local error=$1 ip=${2:-} wrote=$3
  python3 - "$state_file" "$error" "$ip" "$wrote" <<'PY'
import datetime
import json
import os
import sys

path, error, ip, wrote = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as stream:
        old = json.load(stream)
except (OSError, ValueError):
    old = {}
now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
value = {
    "ip": ip or old.get("ip"),
    "updatedAt": now if wrote == "yes" else old.get("updatedAt"),
    "lastCheckAt": now,
    "lastError": error or None,
}
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(value, stream)
    stream.write("\n")
os.chmod(temporary, 0o644)
os.replace(temporary, path)
PY
}

fail() {
  local code=$1 message=$2 old_ip=
  if [[ -f "$state_file" ]]; then
    old_ip=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("ip") or "")' "$state_file" 2>/dev/null || true)
  fi
  write_state "$message" "$old_ip" no
  [[ -z "$message" ]] || printf '%s\n' "$message" >&2
  exit "$code"
}

# Maps an api_request failure status to the exit contract: 3 = token rejected, otherwise 1.
api_fail() {
  local status=$1 message=$2
  ((status == 3)) && fail 3 "Cloudflare token was rejected"
  fail 1 "$message"
}

urlquote() {
  python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

if [[ ! -f "$token_file" ]]; then
  fail 1 "Cloudflare token file is missing"
fi
token=$(<"$token_file")
if [[ -z "$token" || "$token" == *$'\n'* || "$token" == *$'\r'* ]]; then
  fail 1 "Cloudflare token file is invalid"
fi
escaped_token=${token//\\/\\\\}
escaped_token=${escaped_token//\"/\\\"}
printf 'header = "Authorization: Bearer %s"\n' "$escaped_token" >"$curl_config"
unset token escaped_token

ip_urls=${SUPERSEMU_IP_URLS:-"https://api.ipify.org https://checkip.amazonaws.com"}
read -r -a ip_url_list <<<"$ip_urls"
ip=
for ip_url in "${ip_url_list[@]}"; do
  [[ -n "$ip_url" ]] || continue
  if http_status=$(curl --silent --show-error --max-time 10 --output "$response_file" --write-out '%{http_code}' "$ip_url" 2>/dev/null); then
    if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
      if parsed_ip=$(python3 - "$response_file" <<'PY'
import ipaddress
import sys

try:
    value = open(sys.argv[1], encoding="ascii").read().strip()
    parsed = ipaddress.IPv4Address(value)
    print(parsed)
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
      ); then
        ip=$parsed_ip
        break
      fi
    fi
  fi
done
[[ -n "$ip" ]] || fail 1 "Could not determine a public IPv4 address"

api_request() {
  local method=$1 url=$2 body=${3:-} status
  local args=(--silent --show-error --max-time 20 --request "$method" --output "$response_file" --write-out '%{http_code}' -K "$curl_config")
  if [[ -n "$body" ]]; then args+=(--header 'Content-Type: application/json' --data "$body"); fi
  if ! status=$(curl "${args[@]}" "$url" 2>/dev/null); then return 1; fi
  if [[ "$status" == 401 || "$status" == 403 ]]; then return 3; fi
  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then return 1; fi
  if python3 - "$response_file" <<'PY'
import json
import sys

try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)
if value.get("success") is True:
    raise SystemExit(0)
errors = value.get("errors") or []
auth_words = ("auth", "token", "permission", "unauthorized", "forbidden")
for error in errors:
    message = str(error.get("message", "")).lower()
    if any(word in message for word in auth_words):
        raise SystemExit(3)
raise SystemExit(1)
PY
  then
    return 0
  else
    return $?
  fi
}

suffixes=$(python3 - "$host" <<'PY'
import sys
labels = sys.argv[1].rstrip(".").split(".")
for index in range(max(1, len(labels) - 1)):
    print(".".join(labels[index:]))
PY
)
zone_id=
while IFS= read -r suffix; do
  [[ -n "$suffix" ]] || continue
  zone_url="$api/zones?$(python3 -c 'import sys,urllib.parse; print(urllib.parse.urlencode({"name":sys.argv[1]}))' "$suffix")"
  if api_request GET "$zone_url"; then
    zone_id=$(python3 - "$response_file" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8")).get("result") or []
if data:
    print(data[0].get("id", ""))
PY
    )
    [[ -n "$zone_id" ]] && break
  else
    api_fail $? "Cloudflare zone lookup failed"
  fi
done <<<"$suffixes"
[[ -n "$zone_id" ]] || fail 1 "No Cloudflare zone matched $host"

encoded_host=$(urlquote "$host")
zone_path=$(urlquote "$zone_id")
records_url="$api/zones/$zone_path/dns_records?type=A&name=$encoded_host"
if api_request GET "$records_url"; then
  records=$(python3 - "$response_file" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8")).get("result") or []
for item in data:
    print("\t".join(str(item.get(key, "")) for key in ("id", "content", "proxied")))
PY
  )
else
  api_fail $? "Cloudflare DNS record lookup failed"
fi

payload=$(python3 - "$host" "$ip" <<'PY'
import json
import sys
print(json.dumps({"type": "A", "name": sys.argv[1], "content": sys.argv[2], "ttl": 300, "proxied": False}))
PY
)
records_written=0
if [[ -n "$records" ]]; then
  while IFS=$'\t' read -r record_id record_ip record_proxied; do
    [[ -n "$record_id" ]] || continue
    if [[ "$record_ip" == "$ip" && "$record_proxied" == "False" ]]; then
      continue
    fi
    encoded_record_id=$(urlquote "$record_id")
    write_url="$api/zones/$zone_path/dns_records/$encoded_record_id"
    if api_request PATCH "$write_url" "$payload"; then
      records_written=1
    else
      api_fail $? "Cloudflare DNS record update failed"
    fi
  done <<<"$records"
else
  if api_request POST "$api/zones/$zone_path/dns_records" "$payload"; then
    records_written=1
  else
    api_fail $? "Cloudflare DNS record creation failed"
  fi
fi
if ((records_written)); then
  write_state "" "$ip" yes
else
  write_state "" "$ip" no
fi
