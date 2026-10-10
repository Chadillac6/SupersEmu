#!/usr/bin/env bash
# Fetches homebrew SNES test ROMs into Tests/Fixtures/local (gitignored).
# Source: https://github.com/PeterLemon/SNES (public homebrew demos/tests).
# The upstream repo has no explicit licence file, so these binaries are used
# for local testing only and are never committed or bundled into the app.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/Tests/Fixtures/local"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git clone --depth 1 --quiet https://github.com/PeterLemon/SNES.git "$tmp/SNES"
mkdir -p "$dest"
cp "$tmp/SNES/HelloWorld/HelloWorld.sfc" "$dest/"
cp "$tmp/SNES/INPUT/ControllerLatency/ControllerLatency.sfc" "$dest/"
echo "Fixtures ready in $dest"
