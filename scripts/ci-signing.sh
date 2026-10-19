#!/bin/bash
# Ephemeral GitHub-hosted runner only; never changes the developer's login keychain.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'GitHub Actions only' >&2; exit 2; }
# shellcheck source=scripts/release-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/release-common.sh"
keychain="$RUNNER_TEMP/supersemu-release.keychain-db"
secrets_dir="$RUNNER_TEMP/supersemu-release-secrets"
# Xcode's automatic iOS signing creates a new "Created via API" development certificate on
# every fresh runner. Revoke this run's so the team never reaches Apple's certificate limit.
revoke_runner_dev_certs() {
  local pems="$secrets_dir/api-dev-certs.pem" header="$secrets_dir/asc-auth-header" kc
  local keychains=()
  for kc in "$keychain" "$HOME/Library/Keychains/login.keychain-db"; do
    [ -f "$kc" ] && keychains+=("$kc")
  done
  [ "${#keychains[@]}" -gt 0 ] || return 0
  security find-certificate -a -c 'Apple Development: Created via API' -p "${keychains[@]}" \
    > "$pems" 2>/dev/null || true
  [ -s "$pems" ] || { echo "No temporary development certificate to revoke"; return 0; }
  (
    ASC_KEY_ID="$(cat "$secrets_dir/asc-key-id")"
    ASC_ISSUER_ID="$(cat "$secrets_dir/asc-issuer-id")"
    export ASC_KEY_ID ASC_ISSUER_ID
    release_asc_auth_header "$secrets_dir/notarization.p8" "$header"
  ) && release_revoke_dev_certs "$header" "$pems"
}
if [ "${1:-}" = cleanup ]; then
  if [ -f "$secrets_dir/asc-issuer-id" ]; then
    revoke_runner_dev_certs ||
      echo "::warning::Could not revoke this run's temporary Apple Development certificate. Revoke unused \"Created via API\" development certificates in the Apple Developer portal before the account limit is reached."
  fi
  if [ -f "$secrets_dir/original-keychains.txt" ]; then
    python3 - "$secrets_dir/original-keychains.txt" <<'RESTORE'
import shlex, subprocess, sys
from pathlib import Path
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s',
                *shlex.split(Path(sys.argv[1]).read_text())], check=True)
RESTORE
  fi
  security delete-keychain "$keychain" 2>/dev/null || true
  # Only the private directory created below, on the disposable runner.
  rm -rf "$secrets_dir"
  exit 0
fi
for name in MAC_CERT_P12_BASE64 MAC_CERT_PASSWORD ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64 SPARKLE_PRIVATE_KEY; do
  [ -n "${!name:-}" ] || { echo "Missing mac-release secret: $name" >&2; exit 2; }
done
umask 077
mkdir "$secrets_dir"
printf '%s' "$MAC_CERT_P12_BASE64" | base64 -D > "$secrets_dir/certificate.p12" ||
  { echo "error: MAC_CERT_P12_BASE64 is not valid base64" >&2; exit 2; }
release_normalize_p12 "$secrets_dir/certificate.p12" "$secrets_dir/certificate-import.p12" || exit 2
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$secrets_dir/sparkle.key"
printf '%s' "$ASC_KEY_P8_BASE64" | base64 -D > "$secrets_dir/notarization.p8" ||
  { echo "error: ASC_KEY_P8_BASE64 is not valid base64" >&2; exit 2; }
release_normalize_p8 "$secrets_dir/notarization.p8" || exit 2
printf '%s' "$ASC_KEY_ID" > "$secrets_dir/asc-key-id"
printf '%s' "$ASC_ISSUER_ID" > "$secrets_dir/asc-issuer-id"
password=$(openssl rand -hex 32)
echo "::add-mask::$password"
security list-keychains -d user > "$secrets_dir/original-keychains.txt"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$secrets_dir/certificate-import.p12" -k "$keychain" -P "$MAC_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
# Always a fresh timestamp from the shared helper, so reruns get a new build number.
{
  echo "SUPERSEMU_BUILD_NUMBER=$(SUPERSEMU_BUILD_NUMBER='' release_build_number)"
  echo "ASC_KEY_PATH=$secrets_dir/notarization.p8"
  echo "SPARKLE_ED_KEY_FILE=$secrets_dir/sparkle.key"
  echo "SPARKLE_GENERATE_APPCAST=build/release-mac/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
} >> "$GITHUB_ENV"
