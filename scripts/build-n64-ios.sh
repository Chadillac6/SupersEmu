#!/usr/bin/env bash
# N64 risk spike: builds Mupen64Plus-Next as an iOS arm64 (device) dylib.
# Applies two local fixes the vendored deps need on current Apple SDKs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/n64"
COMMIT=12edd2c74a517ff86dfa8cfc71ad75e4c10486d5
mkdir -p "$WORK/shim"
if [ ! -d "$WORK/mupen64plus-libretro-nx/.git" ]; then
  git clone -q https://github.com/libretro/mupen64plus-libretro-nx.git "$WORK/mupen64plus-libretro-nx"
fi
cd "$WORK/mupen64plus-libretro-nx"
git fetch -q --depth 1 origin "$COMMIT"
git checkout -q "$COMMIT"
# Vendored libpng includes the classic-Mac <fp.h> whenever TARGET_OS_MAC is defined.
echo '#include <math.h>' > "$WORK/shim/fp.h"
# Vendored zlib redefines fdopen() to NULL whenever TARGET_OS_MAC is defined, breaking <stdio.h>.
sed -i '' 's/defined(MACOS) || defined(TARGET_OS_MAC)/defined(MACOS)/' custom/dependencies/libzlib/zutil.h
CPATH="$WORK/shim" make platform=ios-arm64 -j"$(sysctl -n hw.ncpu)"
file mupen64plus_next_libretro_ios.dylib
