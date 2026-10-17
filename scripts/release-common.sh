#!/usr/bin/env bash
# Shared by release-ios.sh and release-mac.sh (sourced, not run). Checks the release environment and
# writes the App Store Connect API key to a private temp file. Never prints key material.

release_usage_env() {
  cat >&2 <<'USAGE'
Required environment:
  SUPERSEMU_TEAM_ID   Apple Developer Team ID (10 characters, developer.apple.com > Membership details)
  ASC_KEY_ID          App Store Connect API key ID
  ASC_ISSUER_ID       App Store Connect API issuer ID (UUID)
  ASC_KEY_P8_BASE64   base64 of the AuthKey_<ID>.p8 file or raw DER key, or
  ASC_KEY_PATH        path to the AuthKey_<ID>.p8 file
Optional:
  SUPERSEMU_BUILD_NUMBER  CFBundleVersion to use (default: UTC timestamp, always increasing)
See docs/specs/distribution.md.
USAGE
}

release_require_env() {
  local missing=() name
  for name in SUPERSEMU_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID; do
    [ -n "${!name:-}" ] || missing+=("$name")
  done
  if [ -z "${ASC_KEY_P8_BASE64:-}" ] && [ -z "${ASC_KEY_PATH:-}" ]; then
    missing+=("ASC_KEY_P8_BASE64 or ASC_KEY_PATH")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'error: missing %s\n' "${missing[@]}" >&2
    release_usage_env
    exit 2
  fi
  if ! [[ "$SUPERSEMU_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "error: SUPERSEMU_TEAM_ID should be the 10-character Team ID, got '$SUPERSEMU_TEAM_ID'" >&2
    exit 2
  fi
  if [ -n "${SUPERSEMU_BUILD_NUMBER:-}" ] && ! [[ "$SUPERSEMU_BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "error: SUPERSEMU_BUILD_NUMBER must be up to three dot-separated integers, got '$SUPERSEMU_BUILD_NUMBER'" >&2
    exit 2
  fi
  for name in xcodegen xcodebuild; do
    command -v "$name" >/dev/null || { echo "error: $name not found" >&2; exit 2; }
  done
}

release_normalize_p8() {
  local key_file="$1"
  local pem_file="${key_file}.pem"
  if ! (umask 077
        openssl pkey -in "$key_file" -out "$pem_file" 2>/dev/null ||
          openssl pkey -inform DER -in "$key_file" -out "$pem_file" 2>/dev/null) ||
     ! mv "$pem_file" "$key_file" 2>/dev/null; then
    rm -f "$pem_file" 2>/dev/null || true
    echo "error: the App Store Connect key is not a .p8 private key" >&2
    return 2
  fi
}

_release_p12_decode_for_validation() {
  local ossl="$1"
  local input="$2"
  local legacy="$3"
  if [ "$legacy" = "yes" ]; then
    "$ossl" pkcs12 -in "$input" -nodes -passin env:MAC_CERT_PASSWORD -legacy
  else
    "$ossl" pkcs12 -in "$input" -nodes -passin env:MAC_CERT_PASSWORD
  fi
}

_release_p12_export() {
  local ossl="$1"
  local input="$2"
  local output="$3"
  local legacy="$4"
  if [ "$legacy" = "yes" ]; then
    "$ossl" pkcs12 -export \
      -in <("$ossl" pkcs12 -in "$input" -nokeys -passin env:MAC_CERT_PASSWORD -legacy 2>&3) \
      -inkey <("$ossl" pkcs12 -in "$input" -nocerts -nodes -passin env:MAC_CERT_PASSWORD -legacy 2>&3) \
      -out "$output" -passout env:MAC_CERT_PASSWORD \
      -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>&3 >/dev/null
  else
    "$ossl" pkcs12 -export \
      -in <("$ossl" pkcs12 -in "$input" -nokeys -passin env:MAC_CERT_PASSWORD 2>&3) \
      -inkey <("$ossl" pkcs12 -in "$input" -nocerts -nodes -passin env:MAC_CERT_PASSWORD 2>&3) \
      -out "$output" -passout env:MAC_CERT_PASSWORD \
      -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>&3 >/dev/null
  fi
}

release_normalize_p12() (
  if [ "$#" -ne 2 ]; then
    echo "error: release_normalize_p12 requires an input and output .p12 path" >&2
    return 2
  fi
  local input="$1"
  local output="$2"
  local ossl=""
  local brew_prefix=""
  local decode_error=""
  local initial_error=""
  local legacy_error=""
  local export_error=""
  local diagnostics=""
  local version=""
  local legacy="no"
  local temp_output=""
  umask 077
  if [ -z "${MAC_CERT_PASSWORD:-}" ]; then
    echo "error: MAC_CERT_PASSWORD is required" >&2
    return 2
  fi
  if command -v brew >/dev/null 2>&1; then
    brew_prefix=$(brew --prefix openssl@3 2>/dev/null || true)
    if [ -n "$brew_prefix" ] && [ -x "$brew_prefix/bin/openssl" ]; then
      ossl="$brew_prefix/bin/openssl"
    fi
  fi
  if [ -z "$ossl" ]; then
    ossl=$(command -v openssl || true)
  fi
  if [ -z "$ossl" ]; then
    echo "error: OpenSSL is required to normalize MAC_CERT_P12_BASE64" >&2
    return 2
  fi
  if decode_error=$(_release_p12_decode_for_validation "$ossl" "$input" no 2>&1 >/dev/null); then
    legacy="no"
  else
    initial_error="$decode_error"
    if decode_error=$(_release_p12_decode_for_validation "$ossl" "$input" yes 2>&1 >/dev/null); then
      legacy="yes"
    else
      legacy_error="$decode_error"
      diagnostics="${initial_error}"$'\n'"${legacy_error}"
      if [[ "$diagnostics" == *"Mac verify error"* ]]; then
        echo "error: MAC_CERT_PASSWORD does not match the MAC_CERT_P12_BASE64 certificate; re-export the .p12 and update both secrets" >&2
      else
        version=$("$ossl" version 2>/dev/null || true)
        if [[ "$version" == *LibreSSL* && "$diagnostics" == *"unsupported"* ]]; then
          echo "error: the available LibreSSL cannot read this .p12; install Homebrew openssl@3" >&2
        else
          echo "error: MAC_CERT_P12_BASE64 is not a valid .p12 (certificate + private key)" >&2
        fi
      fi
      return 2
    fi
  fi
  if ! temp_output=$(mktemp "${output}.XXXXXX" 2>/dev/null); then
    echo "error: could not create a normalized .p12 output" >&2
    return 2
  fi
  if export_error=$(_release_p12_export "$ossl" "$input" "$temp_output" "$legacy" 3>&1); then
    if ! mv -f "$temp_output" "$output"; then
      rm -f "$temp_output"
      echo "error: could not write the normalized .p12 output" >&2
      return 2
    fi
  else
    rm -f "$temp_output"
    if [[ "$export_error" == *"Mac verify error"* ]]; then
      echo "error: MAC_CERT_PASSWORD does not match the MAC_CERT_P12_BASE64 certificate; re-export the .p12 and update both secrets" >&2
    else
      echo "error: MAC_CERT_P12_BASE64 is not a valid .p12 (certificate + private key)" >&2
    fi
    return 2
  fi
)

# Sets RELEASE_TMP (removed on exit) and ASC_KEY_FILE.
release_prepare_key() {
  RELEASE_TMP="$(mktemp -d)"
  trap 'rm -rf "$RELEASE_TMP"' EXIT
  ASC_KEY_FILE="$RELEASE_TMP/AuthKey_${ASC_KEY_ID}.p8"
  (
    umask 077
    if [ -n "${ASC_KEY_P8_BASE64:-}" ]; then
      printf '%s' "$ASC_KEY_P8_BASE64" | base64 -D > "$ASC_KEY_FILE" 2>/dev/null ||
        { echo "error: ASC_KEY_P8_BASE64 is not valid base64" >&2; exit 2; }
    else
      [ -r "$ASC_KEY_PATH" ] || { echo "error: ASC_KEY_PATH '$ASC_KEY_PATH' is not readable" >&2; exit 2; }
      cp "$ASC_KEY_PATH" "$ASC_KEY_FILE"
    fi
  ) || exit 2
  release_normalize_p8 "$ASC_KEY_FILE" || exit 2
  openssl pkey -in "$ASC_KEY_FILE" -noout 2>/dev/null ||
    { echo "error: the App Store Connect key is not a .p8 private key" >&2; exit 2; }
  # shellcheck disable=SC2034 # used by the sourcing scripts
  ASC_AUTH_ARGS=(-authenticationKeyPath "$ASC_KEY_FILE" -authenticationKeyID "$ASC_KEY_ID"
                 -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  # Xcode logs build-phase environments. Keep raw private signing values out of
  # child build tools, including local releases that use the base64 input path.
  unset ASC_KEY_P8_BASE64 MAC_CERT_P12_BASE64 MAC_CERT_PASSWORD SPARKLE_PRIVATE_KEY
}

release_build_number() {
  if [ -n "${SUPERSEMU_BUILD_NUMBER:-}" ]; then echo "$SUPERSEMU_BUILD_NUMBER"; else date -u +%Y%m%d.%H%M%S; fi
}

release_next_marketing_version() {
  local floor="${1:-}"
  python3 -c '
import re
import sys

def parse(version):
    match = re.fullmatch(r"([0-9]+)\.([0-9]+)(?:\.([0-9]+))?", version.strip())
    if not match:
        raise ValueError(f"invalid numeric marketing version: {version!r}")
    return int(match.group(1)), int(match.group(2)), int(match.group(3) or 0)

try:
    floor = parse(sys.argv[1])
    versions = [parse(line) for line in sys.stdin if line.strip()]
    if versions:
        latest = max(versions)
        bumped = latest[0], latest[1], latest[2] + 1
        result = max(bumped, floor)
    else:
        result = floor
except (IndexError, ValueError) as error:
    print(f"error: {error}", file=sys.stderr)
    sys.exit(2)

print(".".join(str(part) for part in result))
' "$floor"
}

release_asc_marketing_versions() {
  local auth_header="$RELEASE_TMP/asc-marketing-auth-header"
  local versions_file="$RELEASE_TMP/ios-prerelease-versions.txt"
  if ! python3 - "$ASC_KEY_FILE" "$auth_header" <<'PY'
import base64
import json
import os
import subprocess
import sys
import time

key_path, header_path = sys.argv[1:]
def b64url(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")
def read_len(value, index):
    length = value[index]
    if length < 0x80:
        return length, index + 1
    count = length & 0x7f
    return int.from_bytes(value[index + 1:index + 1 + count], "big"), index + 1 + count

header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
payload = {
    "iss": os.environ["ASC_ISSUER_ID"],
    "iat": int(time.time()),
    "exp": int(time.time()) + 1200,
    "aud": "appstoreconnect-v1",
}
unsigned = b64url(json.dumps(header, separators=(",", ":")).encode()) + "." + b64url(
    json.dumps(payload, separators=(",", ":")).encode()
)
signature = subprocess.check_output(
    ["openssl", "dgst", "-sha256", "-sign", key_path], input=unsigned.encode()
)
if signature[0] != 0x30:
    raise ValueError("unexpected App Store Connect signature format")
_, offset = read_len(signature, 1)
if signature[offset] != 0x02:
    raise ValueError("unexpected App Store Connect signature format")
r_length, offset = read_len(signature, offset + 1)
r = signature[offset:offset + r_length]
offset += r_length
if signature[offset] != 0x02:
    raise ValueError("unexpected App Store Connect signature format")
s_length, offset = read_len(signature, offset + 1)
s = signature[offset:offset + s_length]
token = unsigned + "." + b64url(r[-32:].rjust(32, b"\0") + s[-32:].rjust(32, b"\0"))
fd = os.open(header_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as output:
    output.write("Authorization: Bearer " + token + "\n")
PY
  then
    echo "error: could not create App Store Connect authorization for marketing version lookup" >&2
    return 1
  fi

  versions_file="$RELEASE_TMP/ios-prerelease-versions.txt"
  if ! python3 - "$auth_header" "$versions_file" <<'PY'
import json
import subprocess
import sys
from urllib.parse import urljoin, urlsplit

auth_header, versions_path = sys.argv[1:]
base = "https://api.appstoreconnect.apple.com/v1"

def get_json(url):
    response = subprocess.run(
        ["curl", "--silent", "--show-error", "--fail", "-H", f"@{auth_header}", url],
        capture_output=True,
        text=True,
    )
    if response.returncode:
        detail = response.stderr.strip() or f"curl exited {response.returncode}"
        raise RuntimeError(detail)
    return json.loads(response.stdout)

try:
    apps = get_json(
        base + "/apps?filter%5BbundleId%5D=com.chadillac6.supersemu&limit=200"
    ).get("data", [])
    if len(apps) != 1:
        raise RuntimeError(f"expected one app for com.chadillac6.supersemu, found {len(apps)}")
    app_id = apps[0]["id"]
    next_url = (
        base + "/preReleaseVersions?filter%5Bapp%5D=" + app_id
        + "&filter%5Bplatform%5D=IOS&limit=200"
    )
    versions = []
    seen = set()
    while next_url:
        if next_url in seen:
            raise RuntimeError("App Store Connect returned a repeated pagination URL")
        seen.add(next_url)
        page = get_json(next_url)
        versions.extend(
            item["attributes"]["version"]
            for item in page.get("data", [])
            if item.get("attributes", {}).get("version")
        )
        next_link = page.get("links", {}).get("next")
        if not next_link:
            next_url = None
        else:
            next_url = urljoin(next_url, next_link)
            parsed = urlsplit(next_url)
            if parsed.scheme != "https" or parsed.netloc != "api.appstoreconnect.apple.com":
                raise RuntimeError("App Store Connect returned an unexpected pagination host")
    with open(versions_path, "w", encoding="utf-8") as output:
        output.write("".join(version + "\n" for version in versions))
except Exception as error:
    print(f"error: App Store Connect marketing version lookup failed: {error}", file=sys.stderr)
    sys.exit(1)
PY
  then
    return 1
  fi
  cat "$versions_file"
}

release_mac_marketing_version() {
  local appcast version
  if ! appcast="$(curl -fsSL https://github.com/Chadillac6/SupersEmu/releases/latest/download/appcast.xml)"; then
    echo "error: latest Mac marketing version lookup failed" >&2
    return 1
  fi
  if ! version="$(printf '%s' "$appcast" | python3 -c '
import sys
import xml.etree.ElementTree as ET

namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ET.fromstring(sys.stdin.read())
for item in root.iter("item"):
    version = item.get(namespace + "shortVersionString")
    if version:
        print(version)
        break
')"; then
    echo "error: latest Mac appcast does not contain a valid release item" >&2
    return 1
  fi
  if [ -z "$version" ]; then
    echo "error: latest Mac appcast does not contain sparkle:shortVersionString" >&2
    return 1
  fi
  printf '%s\n' "$version"
}

release_calculate_marketing_version() {
  local floor="$1" ios_versions mac_version
  if ! ios_versions="$(release_asc_marketing_versions)"; then
    echo "error: could not retrieve iOS pre-release versions from App Store Connect" >&2
    return 1
  fi
  if ! mac_version="$(release_mac_marketing_version)"; then
    echo "error: could not retrieve the latest Mac marketing version" >&2
    return 1
  fi
  if [ -z "$mac_version" ]; then
    echo "error: latest Mac appcast returned no release version" >&2
    return 1
  fi
  printf '%s\n%s\n' "$ios_versions" "$mac_version" | release_next_marketing_version "$floor"
}

release_marketing_version() {
  if [ "${SUPERSEMU_MARKETING_VERSION+x}" = x ]; then
    if [ -z "$SUPERSEMU_MARKETING_VERSION" ]; then
      echo "error: SUPERSEMU_MARKETING_VERSION is set but empty" >&2
      return 2
    fi
    echo "Using SUPERSEMU_MARKETING_VERSION override: $SUPERSEMU_MARKETING_VERSION" >&2
    printf '%s\n' "$SUPERSEMU_MARKETING_VERSION"
    return 0
  fi

  if [ -z "${ASC_KEY_FILE:-}" ] || [ -z "${ASC_KEY_ID:-}" ] ||
     [ -z "${ASC_ISSUER_ID:-}" ] || [ -z "${RELEASE_TMP:-}" ]; then
    echo "error: release_prepare_key must run before release_marketing_version" >&2
    return 2
  fi

  local script_dir project_file floor marketing_version
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  project_file="$script_dir/../project.yml"
  floor="$(awk '
    /^settings:[[:space:]]*$/ { in_settings=1; next }
    in_settings && /^[^[:space:]]/ { in_settings=0; in_base=0 }
    in_settings && /^  base:[[:space:]]*$/ { in_base=1; next }
    in_base && /^    MARKETING_VERSION:[[:space:]]*/ {
      value=$2
      gsub(/"/, "", value)
      print value
      exit
    }
  ' "$project_file")"
  if [ -z "$floor" ]; then
    echo "error: could not read settings.base.MARKETING_VERSION from $project_file" >&2
    return 2
  fi

  if ! marketing_version="$(release_calculate_marketing_version "$floor")"; then
    echo "error: could not calculate the next shared marketing version" >&2
    return 1
  fi
  echo "Using project.yml marketing version floor $floor; selected $marketing_version" >&2
  printf '%s\n' "$marketing_version"
}
