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
boot_data_dir="/Library/Application Support/SupersEmu Server"
data_dir=${SUPERSEMU_DATA_DIR:-"$boot_data_dir"}
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

if ((no_launchd)) && [[ $action != status ]]; then
  # Without launchd, Caddy runs as the caller; it must never run as root.
  ((EUID != 0)) || { echo "--no-launchd runs Caddy as the calling user; don't run it as root."; exit 2; }
elif [[ "$data_dir" == "$boot_data_dir" && $EUID -ne 0 && $action != status ]]; then
  echo "This operation needs administrator access; rerunning with sudo."
  exec sudo env SUPERSEMU_DATA_DIR="$data_dir" "$0" "${original_args[@]}"
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
template="$script_dir/Caddyfile.template"
[[ -f "$template" ]] || template="$script_dir/../Server/Resources/Caddyfile.template"
# Root installs the daemons; they run as this unprivileged account. Everything they execute or load
# (Caddy, its Caddyfile, the DDNS script) lives in a root-owned directory; only their state is theirs.
service_user=${SUPERSEMU_SERVICE_USER:-_supersemu}
privileged=0
((EUID != 0 || no_launchd)) || privileged=1
if [[ -n ${SUPERSEMU_REMOTE_ACCESS_DIR:-} ]]; then
  install_dir=$SUPERSEMU_REMOTE_ACCESS_DIR
elif ((no_launchd)); then
  install_dir="$data_dir/remote-access"
else
  install_dir="/Library/Application Support/SupersEmu Remote Access"
fi
caddy_dir="$data_dir/caddy"
ddns_dir="$data_dir/ddns"
config_file="$data_dir/public-access.json"
caddyfile="$install_dir/Caddyfile"
installed_caddy="$install_dir/bin/caddy"
label="com.chadillac6.supersemu.caddy"
launchd_dir=${SUPERSEMU_LAUNCHD_DIR:-/Library/LaunchDaemons}
plist="$launchd_dir/$label.plist"
ddns_label="com.chadillac6.supersemu.ddns"
ddns_plist="$launchd_dir/$ddns_label.plist"
ddns_script="$install_dir/bin/ddns-cloudflare.sh"
token_file="$data_dir/cloudflare.token"
server_label="system/com.chadillac6.supersemu.server"
# Before 2026-10 the DDNS script and its state lived directly in the data directory.
legacy_ddns_bin="$data_dir/bin"
legacy_ddns_state="$data_dir/ddns-state.json"

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

# Every directory from $1 up to / must be owned by root and not writable by group or others, so no
# other account can swap what root (or the service account) reads from it.
require_root_owned_path() {
  local path uid mode
  if ! path=$(cd "$1" 2>/dev/null && pwd -P); then
    echo "Remote Access needs the boot server's data folder, and $1 doesn't exist."
    return 6
  fi
  while :; do
    read -r uid mode < <(stat -f '%u %Lp' "$path")
    if [[ "$uid" != 0 ]] || ((8#$mode & 022)); then
      echo "Remote Access needs the boot server: $path must be owned by root and writable only by root."
      return 6
    fi
    [[ "$path" != / ]] || return 0
    path=$(dirname "$path")
  done
}

# A hidden system account (no shell, no password, no home) for the Caddy and DDNS daemons.
ensure_service_account() {
  local id gid used
  if ! dscl . -read "/Groups/$service_user" PrimaryGroupID >/dev/null 2>&1 \
    || ! dscl . -read "/Users/$service_user" UniqueID >/dev/null 2>&1; then
    used=$({ dscl . -list /Users UniqueID; dscl . -list /Groups PrimaryGroupID; } | awk '{print $2}')
    for id in {300..499}; do
      grep -qx "$id" <<<"$used" || break
    done
    grep -qx "$id" <<<"$used" && { echo "No free system account ID for $service_user."; return 1; }
  fi
  if ! dscl . -read "/Groups/$service_user" PrimaryGroupID >/dev/null 2>&1; then
    dscl . -create "/Groups/$service_user"
    dscl . -create "/Groups/$service_user" PrimaryGroupID "$id"
    dscl . -create "/Groups/$service_user" RealName "SupersEmu Remote Access"
    dscl . -create "/Groups/$service_user" Password '*'
  fi
  gid=$(dscl . -read "/Groups/$service_user" PrimaryGroupID | awk '{print $2}')
  if ! dscl . -read "/Users/$service_user" UniqueID >/dev/null 2>&1; then
    dscl . -create "/Users/$service_user"
    dscl . -create "/Users/$service_user" UniqueID "$id"
    dscl . -create "/Users/$service_user" PrimaryGroupID "$gid"
    dscl . -create "/Users/$service_user" UserShell /usr/bin/false
    dscl . -create "/Users/$service_user" NFSHomeDirectory /var/empty
    dscl . -create "/Users/$service_user" RealName "SupersEmu Remote Access"
    dscl . -create "/Users/$service_user" Password '*'
    dscl . -create "/Users/$service_user" IsHidden 1
  fi
}

# A directory the service account owns and only it (and root) can enter.
make_service_dir() {
  mkdir -p "$1"
  chmod 700 "$1"
  # chown -R doesn't follow symbolic links, so links planted inside can't redirect it.
  if ((privileged)); then chown -R "$service_user:$service_user" "$1"; fi
}

# Root-owned copy, replaced atomically so a running daemon never sees a partial file.
install_root_file() {
  local mode=$1 source=$2 target=$3
  if ((privileged)); then
    install -o root -g wheel -m "$mode" "$source" "$target.new"
  else
    install -m "$mode" "$source" "$target.new"
  fi
  mv -f "$target.new" "$target"
}

run_as_service() {
  if ((privileged)); then
    (cd / && sudo -u "$service_user" /usr/bin/env PATH=/usr/bin:/bin:/usr/sbin:/sbin "$@")
  else
    "$@"
  fi
}

# Root keeps the token; the service account's group may only read it.
share_token_with_service() {
  [[ -f "$token_file" ]] || return 0
  if ((privileged)); then
    chown "root:$service_user" "$token_file"
    chmod 640 "$token_file"
  fi
}

write_access_config() {
  local enabled=$1 owner=
  # Same owner as the data directory, so a session server can still read its own config.
  if ((EUID == 0)); then owner=$(stat -f '%u:%g' "$data_dir"); fi
  python3 - "$config_file" "$enabled" "$host" "$port" "$port_explicit" "$owner" <<'PY'
import json
import os
import sys
import tempfile

path, enabled, host, port, port_explicit, owner = sys.argv[1:]
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
# mkstemp never follows or reuses an existing name, and the descriptor-based chmod/chown can't be redirected.
descriptor, temporary = tempfile.mkstemp(prefix=".public-access.", dir=os.path.dirname(path))
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        os.fchmod(stream.fileno(), 0o600)
        if owner:
            uid, gid = (int(part) for part in owner.split(":"))
            os.fchown(stream.fileno(), uid, gid)
        json.dump(value, stream, indent=2)
        stream.write("\n")
    os.replace(temporary, path)
except BaseException:
    os.unlink(temporary)
    raise
PY
}

write_caddyfile() {
  local email=${SUPERSEMU_ACME_EMAIL:-}
  if [[ -n "$email" && ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    echo "SUPERSEMU_ACME_EMAIL must be a valid email address."
    return 2
  fi
  local rendered
  rendered=$(mktemp "$install_dir/.Caddyfile.XXXXXX")
  if [[ -n "$email" ]]; then
    sed "s|# SUPERSEMU_ACME_EMAIL|email $email|" "$template" | sed "s|# SUPERSEMU_TLS_DIRECTIVE|$([[ $local_test == 1 ]] && echo 'tls internal')|" >"$rendered"
  else
    sed '/# SUPERSEMU_ACME_EMAIL/d' "$template" | sed "s|# SUPERSEMU_TLS_DIRECTIVE|$([[ $local_test == 1 ]] && echo 'tls internal')|" >"$rendered"
  fi
  # Holds no secrets; the service account needs to read it.
  chmod 644 "$rendered"
  mv -f "$rendered" "$caddyfile"
}

allow_through_firewall() {
  local firewall=/usr/libexec/ApplicationFirewall/socketfilterfw
  ((privileged)) && [[ -x "$firewall" ]] || return 0
  "$firewall" --getglobalstate 2>/dev/null | grep -qi enabled || return 0
  "$firewall" --add "$1" >/dev/null 2>&1 || true
  "$firewall" --unblockapp "$1" >/dev/null 2>&1 || true
}

# Prints the state folder an installed LaunchDaemon was set up with, or nothing if it isn't installed.
daemon_data_dir() {
  [[ -f "$1" ]] || return 0
  python3 - "$1" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    value = plistlib.load(stream)
arguments = value.get("ProgramArguments", [])
if "--data-dir" in arguments[:-1]:
    print(arguments[arguments.index("--data-dir") + 1])
else:
    print(value.get("EnvironmentVariables", {}).get("SUPERSEMU_CADDY_DATA_DIR", ""))
PY
}

# True if the installed daemon (or none at all) belongs to this data folder, so disabling it here is safe.
daemon_belongs_here() {
  local served
  served=$(daemon_data_dir "$1")
  [[ -z "$served" || "$served" == "$2" || "$served" == "$data_dir" ]]
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
    if ((privileged)); then
      # Root daemons must not load anything from a folder another account controls (e.g. a session server's),
      # and the shared install folder belongs to the boot server alone.
      if [[ "$data_dir" != "$boot_data_dir" ]]; then
        echo "Remote Access needs the boot server's data folder ($boot_data_dir), not $data_dir."
        exit 6
      fi
      require_root_owned_path "$data_dir" || exit 6
      ensure_service_account
      install -d -o root -g wheel -m 755 "$install_dir" "$install_dir/bin"
      require_root_owned_path "$install_dir" || exit 6
    else
      mkdir -p "$data_dir" "$install_dir/bin"
    fi
    make_service_dir "$caddy_dir"
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
    share_token_with_service
    if [[ -f "$token_file" ]]; then
      install_root_file 755 "$script_dir/ddns-cloudflare.sh" "$ddns_script"
      make_service_dir "$ddns_dir"
      if run_as_service "$ddns_script" --host "$host" --data-dir "$ddns_dir" --token-file "$token_file"; then
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
      previous_config_backup=$(mktemp "$data_dir/public-access.XXXXXX")
      cp -p "$config_file" "$previous_config_backup"
      previous_config_existed=1
    fi
    write_caddyfile
    rm -f "$caddy_dir/Caddyfile"
    daemon_caddy=$caddy_bin
    if ((no_launchd == 0)); then
      # The daemon runs a root-owned copy, not a binary the Homebrew user can replace.
      install_root_file 755 "$caddy_bin" "$installed_caddy"
      daemon_caddy=$installed_caddy
    fi
    # Validation writes nothing into Caddy's real storage, so root never touches the service account's files.
    validate_dir=$(mktemp -d)
    if SUPERSEMU_PUBLIC_HOST=$host SUPERSEMU_PUBLIC_PORT=$port SUPERSEMU_CADDY_DATA_DIR=$validate_dir \
      XDG_DATA_HOME=$validate_dir XDG_CONFIG_HOME=$validate_dir \
      "$daemon_caddy" validate --config "$caddyfile" --adapter caddyfile; then
      rm -rf "$validate_dir"
    else
      rm -rf "$validate_dir"
      false
    fi
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
        XDG_DATA_HOME=$caddy_dir XDG_CONFIG_HOME=$caddy_dir nohup "$caddy_bin" run --config "$caddyfile" --adapter caddyfile \
        >>"$caddy_dir/caddy.out" 2>&1 &
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
        python3 - "$ddns_plist" "$ddns_script" "$host" "$ddns_dir" "$token_file" "$service_user" <<'PY'
import os
import plistlib
import sys

path, script, host, data, token, user = sys.argv[1:]
value = {
    "Label": "com.chadillac6.supersemu.ddns",
    # The shell opens the log after launchd has switched to the service account.
    "ProgramArguments": [
        "/bin/bash", "-c", 'exec "$@" >>"$SUPERSEMU_DDNS_LOG" 2>&1', "ddns-cloudflare",
        script, "--host", host, "--data-dir", data, "--token-file", token,
    ],
    "UserName": user,
    "GroupName": user,
    "EnvironmentVariables": {"SUPERSEMU_DDNS_LOG": os.path.join(data, "ddns.log")},
    "RunAtLoad": False,
    "StartInterval": 300,
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
      allow_through_firewall "$daemon_caddy"
      python3 - "$plist" "$daemon_caddy" "$caddyfile" "$caddy_dir" "$host" "$port" "$service_user" <<'PY'
import os
import plistlib
import sys

path, binary, config, data, host, port, user = sys.argv[1:]
value = {
    "Label": "com.chadillac6.supersemu.caddy",
    "ProgramArguments": [binary, "run", "--config", config, "--adapter", "caddyfile"],
    # Unprivileged processes can bind ports 80 and 443 on macOS. Caddy logs to caddy.log itself.
    "UserName": user,
    "GroupName": user,
    "RunAtLoad": True,
    "KeepAlive": True,
    "EnvironmentVariables": {
        "SUPERSEMU_PUBLIC_HOST": host,
        "SUPERSEMU_PUBLIC_PORT": port,
        "SUPERSEMU_CADDY_DATA_DIR": data,
        "XDG_DATA_HOME": data,
        "XDG_CONFIG_HOME": data,
        "HOME": data,
    },
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
    rm -rf "$legacy_ddns_bin"
    rm -f "$legacy_ddns_state" "$data_dir/ddns.log"
    echo "Public HTTPS configured for https://$host; admin routes return 404."
    [[ -z "$previous_config_backup" ]] || rm -f "$previous_config_backup"
    [[ -z "$previous_caddy_plist_backup" ]] || rm -f "$previous_caddy_plist_backup"
    [[ -z "$previous_ddns_plist_backup" ]] || rm -f "$previous_ddns_plist_backup"
    trap - ERR
    ;;
  disable)
    # As root, only write into a data folder that already exists; never create one in a user's home.
    if ((EUID != 0)); then mkdir -p "$data_dir"; fi
    if [[ -d "$data_dir" ]]; then write_access_config false; fi
    if ((no_launchd)); then
      if [[ -f "$caddy_dir/caddy.pid" ]]; then
        pid=$(cat "$caddy_dir/caddy.pid")
        kill "$pid" 2>/dev/null || true
        rm -f "$caddy_dir/caddy.pid"
      fi
    else
      # Another server's daemons (e.g. the boot server's, when turning off a session setup) stay running.
      owns_install=0
      [[ "$data_dir" != "$boot_data_dir" ]] || owns_install=1
      if daemon_belongs_here "$plist" "$caddy_dir"; then
        [[ ! -f "$plist" ]] || owns_install=1
        launchctl_cmd bootout "system/$label" >/dev/null 2>&1 || true
        rm -f "$plist"
      fi
      if daemon_belongs_here "$ddns_plist" "$ddns_dir"; then
        launchctl_cmd bootout "system/$ddns_label" >/dev/null 2>&1 || true
        rm -f "$ddns_plist"
      fi
      launchctl_cmd kickstart -k "$server_label" >/dev/null 2>&1 || true
    fi
    if ((purge)); then
      rm -rf "$caddy_dir" "$ddns_dir" "$legacy_ddns_bin"
      if ((no_launchd || owns_install)); then rm -rf "$install_dir"; fi
      rm -f "$token_file" "$legacy_ddns_state" "$data_dir/ddns.log"
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
    if [[ -f "$ddns_dir/ddns-state.json" ]]; then
      echo "DDNS state:"
      cat "$ddns_dir/ddns-state.json"
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
