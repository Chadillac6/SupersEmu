#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: public-access.sh enable --host <fqdn> [--port 8489] [--data-dir <path>] [--cloudflare-token-file <path>] [--no-launchd] [--local-test]"
  echo "       public-access.sh disable [--data-dir <path>] [--no-launchd] [--purge]"
  echo "       public-access.sh status [--data-dir <path>]"
}

if [[ $# -lt 1 ]]; then usage; exit 2; fi
action=$1
shift
host=
port=8489
port_explicit=0
data_dir=${SUPERSEMU_DATA_DIR:-"/Library/Application Support/SupersEmu Server"}
no_launchd=0
purge=0
local_test=0
cloudflare_token_file=
original_args=("$action")
while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || { usage; exit 2; }; host=$2; original_args+=("$1" "$2"); shift 2 ;;
    --port) (($# >= 2)) || { usage; exit 2; }; port=$2; port_explicit=1; original_args+=("$1" "$2"); shift 2 ;;
    --data-dir) (($# >= 2)) || { usage; exit 2; }; data_dir=$2; original_args+=("$1" "$2"); shift 2 ;;
    --cloudflare-token-file) (($# >= 2)) || { usage; exit 2; }; cloudflare_token_file=$2; original_args+=("$1" "$2"); shift 2 ;;
    --no-launchd) no_launchd=1; original_args+=("$1"); shift ;;
    --purge) purge=1; original_args+=("$1"); shift ;;
    --local-test) local_test=1; original_args+=("$1"); shift ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

if [[ "$action" != enable && "$action" != disable && "$action" != status ]]; then usage; exit 2; fi
if [[ "$action" == enable ]]; then
  [[ -n "$host" ]] || { echo "enable requires --host <fqdn>"; exit 2; }
  [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || { echo "Invalid port"; exit 2; }
  if ((local_test)); then
    ((no_launchd)) || { echo "--local-test requires --no-launchd"; exit 2; }
    [[ "$host" == localhost || "$host" == localhost:* ]] || { echo "--local-test only accepts localhost"; exit 2; }
  else
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ && "$host" == *.* ]] || { echo "Use a DNS hostname without a scheme or port"; exit 2; }
  fi
fi

if [[ "$data_dir" == "/Library/Application Support/SupersEmu Server" && $EUID -ne 0 && $action != status ]]; then
  echo "This operation needs administrator access; rerunning with sudo."
  exec sudo env SUPERSEMU_DATA_DIR="$data_dir" "$0" "${original_args[@]}"
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
template="$script_dir/Caddyfile.template"
[[ -f "$template" ]] || template="$script_dir/../Server/Resources/Caddyfile.template"
caddy_dir="$data_dir/caddy"
config_file="$data_dir/public-access.json"
caddyfile="$caddy_dir/Caddyfile"
label="com.chadillac6.supersemu.caddy"
launchd_dir=${SUPERSEMU_LAUNCHD_DIR:-/Library/LaunchDaemons}
plist="$launchd_dir/$label.plist"
ddns_label="com.chadillac6.supersemu.ddns"
ddns_plist="$launchd_dir/$ddns_label.plist"
ddns_script="$data_dir/bin/ddns-cloudflare.sh"
token_file="$data_dir/cloudflare.token"
server_label="system/com.chadillac6.supersemu.server"

find_caddy() {
  if [[ ${SUPERSEMU_CADDY_PATH+x} ]]; then
    [[ -x "$SUPERSEMU_CADDY_PATH" ]] || return 1
    printf '%s\n' "$SUPERSEMU_CADDY_PATH"
    return 0
  fi
  command -v caddy 2>/dev/null || {
    [[ ! -x /opt/homebrew/bin/caddy ]] || { printf '%s\n' /opt/homebrew/bin/caddy; return; }
    [[ ! -x /usr/local/bin/caddy ]] || { printf '%s\n' /usr/local/bin/caddy; return; }
    return 1
  }
}
caddy_bin=$(find_caddy || true)
if [[ "$action" != status ]]; then
  mkdir -p "$caddy_dir"
  chmod 700 "$caddy_dir"
fi

set_data_owner() {
  if ((EUID == 0)); then
    local owner
    owner=$(stat -f '%u:%g' "$data_dir")
    chown "$owner" "$@"
  fi
}

write_access_config() {
  local enabled=$1
  python3 - "$config_file" "$enabled" "$host" "$port" "$port_explicit" <<'PY'
import json
import os
import sys

path, enabled, host, port, port_explicit = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as stream:
        value = json.load(stream)
except (OSError, ValueError):
    value = {}
if host:
    value["publicURL"] = "https://" + host
value.setdefault("publicURL", "https://localhost")
if port and (enabled == "true" or host or port_explicit == "1"):
    value["listenPort"] = int(port)
value["enabled"] = enabled == "true"
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(value, stream, indent=2)
    stream.write("\n")
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY
  set_data_owner "$config_file"
}

write_caddyfile() {
  local email=${SUPERSEMU_ACME_EMAIL:-}
  if [[ -n "$email" && ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    echo "SUPERSEMU_ACME_EMAIL must be a valid email address."
    return 2
  fi
  if [[ -n "$email" ]]; then
    sed "s|# SUPERSEMU_ACME_EMAIL|email $email|" "$template" | sed "s|# SUPERSEMU_TLS_DIRECTIVE|$([[ $local_test == 1 ]] && echo 'tls internal')|" >"$caddyfile"
  else
    sed '/# SUPERSEMU_ACME_EMAIL/d' "$template" | sed "s|# SUPERSEMU_TLS_DIRECTIVE|$([[ $local_test == 1 ]] && echo 'tls internal')|" >"$caddyfile"
  fi
  chmod 600 "$caddyfile"
  set_data_owner "$caddyfile"
}

launchctl_cmd() {
  if command -v launchctl >/dev/null 2>&1; then launchctl "$@"; else return 1; fi
}

rollback_enable() {
  local status=${1:-$?}
  trap - ERR
  if ((ddns_started)); then
    launchctl_cmd bootout "system/$ddns_label" >/dev/null 2>&1 || true
    if ((previous_ddns_plist_existed)); then
      cp -p "$previous_ddns_plist_backup" "$ddns_plist" || true
      launchctl_cmd bootstrap system "$ddns_plist" >/dev/null 2>&1 || echo "Couldn't restore the previous DDNS LaunchDaemon." >&2
    else
      rm -f "$ddns_plist"
    fi
  fi
  if ((caddy_started)); then
    if ((no_launchd)); then
      if [[ -n "$started_caddy_pid" ]]; then
        kill "$started_caddy_pid" 2>/dev/null || true
        wait "$started_caddy_pid" 2>/dev/null || true
      fi
      rm -f "$caddy_dir/caddy.pid"
    else
      launchctl_cmd bootout "system/$label" >/dev/null 2>&1 || true
      if ((previous_caddy_plist_existed)); then
        cp -p "$previous_caddy_plist_backup" "$plist" || true
        launchctl_cmd bootstrap system "$plist" >/dev/null 2>&1 || echo "Couldn't restore the previous Caddy LaunchDaemon." >&2
      else
        rm -f "$plist"
      fi
    fi
  fi
  if ((config_write_attempted)); then
    if ((previous_config_existed)); then
      mv -f "$previous_config_backup" "$config_file" || true
    else
      rm -f "$config_file" "$config_file.tmp"
    fi
  fi
  [[ -z "$previous_config_backup" ]] || rm -f "$previous_config_backup"
  if ((new_token_written)); then
    if ((previous_token_existed)); then
      mv -f "$previous_token_backup" "$token_file" || true
    else
      rm -f "$token_file"
    fi
  fi
  [[ -z "$previous_token_backup" ]] || rm -f "$previous_token_backup"
  [[ -z "$previous_caddy_plist_backup" ]] || rm -f "$previous_caddy_plist_backup"
  [[ -z "$previous_ddns_plist_backup" ]] || rm -f "$previous_ddns_plist_backup"
  exit "$status"
}

case "$action" in
  enable)
    if [[ -z "$caddy_bin" ]]; then
      echo "Caddy is required. Install it with: brew install caddy"
      exit 5
    fi
    [[ -f "$template" ]] || { echo "Missing Caddy template: $template"; exit 1; }
    caddy_started=0
    config_write_attempted=0
    previous_config_existed=0
    previous_config_backup=
    new_token_written=0
    previous_token_existed=0
    previous_token_backup=
    previous_caddy_plist_existed=0
    previous_caddy_plist_backup=
    previous_ddns_plist_existed=0
    previous_ddns_plist_backup=
    ddns_started=0
    started_caddy_pid=
    trap 'rollback_enable' ERR
    if [[ -n "$cloudflare_token_file" ]]; then
      [[ -f "$cloudflare_token_file" ]] || { echo "Cloudflare token file does not exist."; false; }
      if [[ -f "$token_file" ]]; then
        previous_token_backup=$(mktemp "$data_dir/cloudflare-token.XXXXXX")
        cp -p "$token_file" "$previous_token_backup"
        previous_token_existed=1
      fi
      install -m 600 "$cloudflare_token_file" "$token_file"
      new_token_written=1
    fi
    if [[ -f "$token_file" ]]; then
      mkdir -p "$data_dir/bin"
      install -m 755 "$script_dir/ddns-cloudflare.sh" "$ddns_script"
      if "$ddns_script" --host "$host" --data-dir "$data_dir"; then
        :
      else
        ddns_status=$?
        if ((ddns_status == 3)); then
          echo "Cloudflare token was rejected."
          rollback_enable 3
        fi
        echo "Cloudflare DNS update failed."
        rollback_enable 4
      fi
    else
      echo "Warning: no Cloudflare token; DNS will not be kept up to date." >&2
    fi
    if [[ -f "$config_file" ]]; then
      previous_config_backup=$(mktemp "$caddy_dir/public-access.XXXXXX")
      cp -p "$config_file" "$previous_config_backup"
      previous_config_existed=1
    fi
    write_caddyfile
    SUPERSEMU_PUBLIC_HOST=$host SUPERSEMU_PUBLIC_PORT=$port SUPERSEMU_CADDY_DATA_DIR=$caddy_dir \
      XDG_DATA_HOME=$caddy_dir caddy validate --config "$caddyfile" --adapter caddyfile
    if ((no_launchd)); then
      if [[ -f "$caddy_dir/caddy.pid" ]]; then
        old_pid=$(cat "$caddy_dir/caddy.pid")
        if kill -0 "$old_pid" 2>/dev/null; then
          kill "$old_pid"
          for _ in {1..50}; do
            kill -0 "$old_pid" 2>/dev/null || break
            sleep 0.1
          done
          if kill -0 "$old_pid" 2>/dev/null; then
            echo "Caddy did not stop for reconfiguration."
            false
          fi
        fi
        rm -f "$caddy_dir/caddy.pid"
      fi
      SUPERSEMU_PUBLIC_HOST=$host SUPERSEMU_PUBLIC_PORT=$port SUPERSEMU_CADDY_DATA_DIR=$caddy_dir \
        XDG_DATA_HOME=$caddy_dir nohup "$caddy_bin" run --config "$caddyfile" --adapter caddyfile \
        >>"$caddy_dir/caddy.log" 2>&1 &
      started_caddy_pid=$!
      caddy_started=1
      printf '%s\n' "$started_caddy_pid" >"$caddy_dir/caddy.pid"
      chmod 600 "$caddy_dir/caddy.pid"
      for _ in {1..20}; do
        if ! kill -0 "$started_caddy_pid" 2>/dev/null; then
          echo "Caddy exited during startup."
          false
        fi
        sleep 0.1
      done
    else
      mkdir -p "$launchd_dir"
      if [[ -f "$token_file" ]]; then
        if [[ -f "$ddns_plist" ]]; then
          previous_ddns_plist_backup=$(mktemp "$data_dir/ddns-plist.XXXXXX")
          cp -p "$ddns_plist" "$previous_ddns_plist_backup"
          previous_ddns_plist_existed=1
        fi
        ddns_started=1
        python3 - "$ddns_plist" "$ddns_script" "$host" "$data_dir" <<'PY'
import os
import plistlib
import sys

path, script, host, data = sys.argv[1:]
value = {
    "Label": "com.chadillac6.supersemu.ddns",
    "ProgramArguments": [script, "--host", host, "--data-dir", data],
    "RunAtLoad": False,
    "StartInterval": 300,
    "StandardOutPath": os.path.join(data, "ddns.log"),
    "StandardErrorPath": os.path.join(data, "ddns.log"),
}
with open(path, "wb") as stream:
    plistlib.dump(value, stream)
os.chmod(path, 0o644)
PY
        chmod 644 "$ddns_plist"
        launchctl_cmd bootout "system/$ddns_label" >/dev/null 2>&1 || true
        if launchctl_cmd bootstrap system "$ddns_plist"; then
          :
        else
          launchd_status=$?
          rollback_enable "$launchd_status"
        fi
      fi
      if [[ -f "$plist" ]]; then
        previous_caddy_plist_backup=$(mktemp "$data_dir/caddy-plist.XXXXXX")
        cp -p "$plist" "$previous_caddy_plist_backup"
        previous_caddy_plist_existed=1
      fi
      caddy_started=1
      python3 - "$plist" "$caddy_bin" "$caddyfile" "$caddy_dir" "$host" "$port" <<'PY'
import os
import plistlib
import sys

path, binary, config, data, host, port = sys.argv[1:]
value = {
    "Label": "com.chadillac6.supersemu.caddy",
    "ProgramArguments": [binary, "run", "--config", config, "--adapter", "caddyfile"],
    "RunAtLoad": True,
    "KeepAlive": True,
    "EnvironmentVariables": {
        "SUPERSEMU_PUBLIC_HOST": host,
        "SUPERSEMU_PUBLIC_PORT": port,
        "SUPERSEMU_CADDY_DATA_DIR": data,
        "XDG_DATA_HOME": data,
    },
    "StandardOutPath": os.path.join(data, "caddy.log"),
    "StandardErrorPath": os.path.join(data, "caddy.log"),
}
with open(path, "wb") as stream:
    plistlib.dump(value, stream)
os.chmod(path, 0o600)
PY
      chmod 600 "$plist"
      launchctl_cmd bootout "system/$label" >/dev/null 2>&1 || true
      if launchctl_cmd bootstrap system "$plist"; then
        :
      else
        launchd_status=$?
        rollback_enable "$launchd_status"
      fi
    fi
    config_write_attempted=1
    SUPERSEMU_PUBLIC_HOST=$host SUPERSEMU_PUBLIC_PORT=$port SUPERSEMU_CADDY_DATA_DIR=$caddy_dir \
      write_access_config true
    if ((no_launchd == 0)); then launchctl_cmd kickstart -k "$server_label"; fi
    echo "Public HTTPS configured for https://$host; admin routes return 404."
    [[ -z "$previous_config_backup" ]] || rm -f "$previous_config_backup"
    [[ -z "$previous_caddy_plist_backup" ]] || rm -f "$previous_caddy_plist_backup"
    [[ -z "$previous_ddns_plist_backup" ]] || rm -f "$previous_ddns_plist_backup"
    trap - ERR
    ;;
  disable)
    write_access_config false
    if ((no_launchd)); then
      if [[ -f "$caddy_dir/caddy.pid" ]]; then
        pid=$(cat "$caddy_dir/caddy.pid")
        kill "$pid" 2>/dev/null || true
        rm -f "$caddy_dir/caddy.pid"
      fi
    else
      launchctl_cmd bootout "system/$label" >/dev/null 2>&1 || true
      rm -f "$plist"
      launchctl_cmd bootout "system/$ddns_label" >/dev/null 2>&1 || true
      rm -f "$ddns_plist"
      launchctl_cmd kickstart -k "$server_label" >/dev/null 2>&1 || true
    fi
    if ((purge)); then
      rm -rf "$caddy_dir" "$data_dir/bin"
      rm -f "$token_file" "$data_dir/ddns-state.json"
    fi
    echo "Public access disabled. Existing server and Caddy certificates are retained unless --purge is used."
    ;;
  status)
    if ((no_launchd)); then
      if [[ -f "$caddy_dir/caddy.pid" ]] && kill -0 "$(cat "$caddy_dir/caddy.pid")" 2>/dev/null; then
        echo "Caddy process: running"
      else
        echo "Caddy process: stopped"
      fi
    else
      if [[ -n "$caddy_bin" ]]; then
        launchctl_cmd print "system/$label" 2>&1 | sed -n '1,5p' || true
      else
        echo "Caddy is not installed."
      fi
    fi
    if [[ ! -f "$config_file" ]]; then echo "Public access config: absent (disabled)"; exit 0; fi
    cat "$config_file"
    if [[ -f "$data_dir/ddns-state.json" ]]; then
      echo "DDNS state:"
      cat "$data_dir/ddns-state.json"
    fi
    public_url=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["publicURL"])' "$config_file")
    public_port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["listenPort"])' "$config_file")
    echo "Loopback listener:"
    curl --silent --show-error --max-time 2 "http://127.0.0.1:$public_port/v1/health" || true
    printf '\nPublic health: '
    curl_args=(--silent --show-error --max-time 10 --output /dev/null --write-out '%{http_code}\n')
    if [[ "$public_url" == https://localhost* ]]; then curl_args+=(--insecure); fi
    curl "${curl_args[@]}" "$public_url/v1/health" || true
    printf 'Public admin status: '
    curl "${curl_args[@]}" "$public_url/v1/admin/status" || true
    ;;
esac
