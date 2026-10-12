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
