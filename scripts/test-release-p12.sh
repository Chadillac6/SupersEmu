#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/release-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/release-common.sh"

ossl="$(command -v openssl || true)"
if command -v brew >/dev/null 2>&1; then
  brew_prefix=$(brew --prefix openssl@3 2>/dev/null || true)
  if [ -n "$brew_prefix" ] && [ -x "$brew_prefix/bin/openssl" ]; then
    ossl="$brew_prefix/bin/openssl"
  fi
fi
if [ -z "$ossl" ] || ! command -v security >/dev/null 2>&1; then
  echo "FAIL: OpenSSL and macOS security are required" >&2
  exit 2
fi

umask 077
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/release-p12-test.XXXXXX")
default_keychain="$temp_dir/default.keychain-db"
raw_keychain="$temp_dir/raw.keychain-db"
legacy_keychain="$temp_dir/legacy.keychain-db"
cleanup() {
  security delete-keychain "$default_keychain" >/dev/null 2>&1 || true
  security delete-keychain "$raw_keychain" >/dev/null 2>&1 || true
  security delete-keychain "$legacy_keychain" >/dev/null 2>&1 || true
  rm -rf "$temp_dir"
}
trap cleanup EXIT

create_keychain() {
  local keychain="$1"
  local password
  password=$("$ossl" rand -hex 32)
  security create-keychain -p "$password" "$keychain" >/dev/null
  security unlock-keychain -p "$password" "$keychain" >/dev/null
}

import_identity() {
  local p12="$1"
  local keychain="$2"
  local import_output
  import_output=$(security import "$p12" -k "$keychain" -P "$MAC_CERT_PASSWORD" -T /usr/bin/codesign 2>&1) || return 1
  [[ "$import_output" == *"1 identity imported"* ]]
}

record_pass() {
  printf 'PASS: %s\n' "$1"
}

record_fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

failures=0
test_password=$("$ossl" rand -hex 24)
export MAC_CERT_PASSWORD="$test_password"
"$ossl" req -new -x509 -newkey rsa:2048 -nodes \
  -keyout "$temp_dir/chain-ca.key" \
  -out "$temp_dir/chain-ca.pem" \
  -subj '/CN=Temporary release P12 test CA' -days 1 >/dev/null 2>&1
"$ossl" req -new -newkey rsa:2048 -nodes \
  -keyout "$temp_dir/certificate.key" \
  -out "$temp_dir/certificate.csr" \
  -subj '/CN=Temporary release P12 test' >/dev/null 2>&1
"$ossl" x509 -req \
  -in "$temp_dir/certificate.csr" \
  -CA "$temp_dir/chain-ca.pem" \
  -CAkey "$temp_dir/chain-ca.key" \
  -CAcreateserial \
  -out "$temp_dir/certificate.pem" -days 1 >/dev/null 2>&1
"$ossl" pkcs12 -export \
  -in "$temp_dir/certificate.pem" \
  -inkey "$temp_dir/certificate.key" \
  -certfile "$temp_dir/chain-ca.pem" \
  -out "$temp_dir/default.p12" \
  -passout env:MAC_CERT_PASSWORD >/dev/null 2>&1

create_keychain "$default_keychain"
if release_normalize_p12 "$temp_dir/default.p12" "$temp_dir/default-import.p12"; then
  certificate_count=$("$ossl" pkcs12 -in "$temp_dir/default-import.p12" -nokeys \
    -passin env:MAC_CERT_PASSWORD 2>/dev/null | awk '/^-----BEGIN CERTIFICATE-----$/ { count++ } END { print count+0 }')
  if [ "$certificate_count" -eq 2 ]; then
    record_pass "normalization preserves the full certificate chain"
  else
    record_fail "normalization preserves the full certificate chain"
  fi
  if import_identity "$temp_dir/default-import.p12" "$default_keychain"; then
    record_pass "OpenSSL-default .p12 normalizes and imports (1 identity imported)"
  else
    record_fail "normalized OpenSSL-default .p12 imports as one identity"
  fi
else
  record_fail "OpenSSL-default .p12 normalizes"
fi

create_keychain "$raw_keychain"
if security import "$temp_dir/default.p12" -k "$raw_keychain" \
    -P "$MAC_CERT_PASSWORD" -T /usr/bin/codesign >/dev/null 2>&1; then
  printf 'NOTE: unnormalized OpenSSL-default .p12 imported on this machine; compatibility assertion is not applicable.\n'
else
  record_pass "unnormalized OpenSSL-default .p12 is rejected by security import"
fi

create_keychain "$legacy_keychain"
if "$ossl" pkcs12 -export -legacy \
    -in "$temp_dir/certificate.pem" \
    -inkey "$temp_dir/certificate.key" \
    -certfile "$temp_dir/chain-ca.pem" \
    -out "$temp_dir/legacy.p12" \
    -passout env:MAC_CERT_PASSWORD >/dev/null 2>&1; then
  if release_normalize_p12 "$temp_dir/legacy.p12" "$temp_dir/legacy-import.p12"; then
    if import_identity "$temp_dir/legacy-import.p12" "$legacy_keychain"; then
      record_pass "-legacy .p12 normalizes and imports (1 identity imported)"
    else
      record_fail "normalized -legacy .p12 imports as one identity"
    fi
  else
    record_fail "-legacy .p12 normalizes"
  fi
else
  record_fail "OpenSSL can generate a -legacy .p12 fixture"
fi

wrong_password=$("$ossl" rand -hex 24)
wrong_error="$temp_dir/wrong-password.err"
if MAC_CERT_PASSWORD="$wrong_password" release_normalize_p12 \
    "$temp_dir/default.p12" "$temp_dir/wrong-password-output.p12" 2>"$wrong_error"; then
  record_fail "wrong password returns status 2"
else
  wrong_status=$?
  wrong_message=$(<"$wrong_error")
  if [ "$wrong_status" -eq 2 ] && [[ "$wrong_message" == *"MAC_CERT_PASSWORD"* ]]; then
    record_pass "wrong password returns 2 with a MAC_CERT_PASSWORD error"
  else
    record_fail "wrong password returns 2 with a MAC_CERT_PASSWORD error"
  fi
fi

printf '%s\n' 'not a PKCS#12 file' > "$temp_dir/garbage.p12"
garbage_error="$temp_dir/garbage.err"
if release_normalize_p12 "$temp_dir/garbage.p12" "$temp_dir/garbage-output.p12" 2>"$garbage_error"; then
  record_fail "garbage input returns status 2"
else
  garbage_status=$?
  garbage_message=$(<"$garbage_error")
  if [ "$garbage_status" -eq 2 ] && [[ "$garbage_message" == *"not a valid .p12"* ]]; then
    record_pass "garbage input returns 2 with an invalid .p12 error"
  else
    record_fail "garbage input returns 2 with an invalid .p12 error"
  fi
fi

if [ "$failures" -gt 0 ]; then
  printf '%s test case(s) failed.\n' "$failures" >&2
  exit 1
fi
