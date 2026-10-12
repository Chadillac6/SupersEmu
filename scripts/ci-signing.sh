#!/bin/bash
# Ephemeral GitHub-hosted runner only; never changes the developer's login keychain.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'GitHub Actions only' >&2; exit 2; }
keychain="$RUNNER_TEMP/supersemu-release.keychain-db"
secrets_dir="$RUNNER_TEMP/supersemu-release-secrets"
if [ "${1:-}" = cleanup ]; then
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
printf '%s' "$MAC_CERT_P12_BASE64" | base64 -D > "$secrets_dir/certificate.p12"
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$secrets_dir/sparkle.key"
password=$(openssl rand -hex 32)
echo "::add-mask::$password"
security list-keychains -d user > "$secrets_dir/original-keychains.txt"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$secrets_dir/certificate.p12" -k "$keychain" -P "$MAC_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
# Timestamp versions match the existing release convention; reruns get a fresh version.
{
  echo "SUPERSEMU_BUILD_NUMBER=$(date -u +%Y%m%d.%H%M%S)"
  echo "SPARKLE_ED_KEY_FILE=$secrets_dir/sparkle.key"
  echo "SPARKLE_GENERATE_APPCAST=build/release-mac/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
} >> "$GITHUB_ENV"
