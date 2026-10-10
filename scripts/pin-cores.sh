#!/usr/bin/env bash
# Checks out every statically linked libretro core (Vendor/cores/*) at its pinned upstream commit.
# Bumping a core: change its commit here, run this script, update the revision in project.yml
# (-DSE_CORE_REVISION) and docs/specs/core-matrix.md, then run scripts/build.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pin() { # path url commit
  local path="$1" url="$2" commit="$3"
  git submodule update --init --depth 1 "$path" 2>/dev/null || git submodule update --init "$path"
  if [ "$(git -C "$path" rev-parse HEAD)" != "$commit" ]; then
    git -C "$path" fetch -q --depth 1 "$url" "$commit"
    git -C "$path" checkout -q "$commit"
  fi
  echo "$path @ $(git -C "$path" rev-parse --short HEAD)"
}

pin Vendor/cores/snes9x          https://github.com/libretro/snes9x.git            fae2fea08f74180759ef540ee94259213f503480
pin Vendor/cores/gambatte        https://github.com/libretro/gambatte-libretro.git d9d6cd06382d1ced30de34d56d3609452323dab1
pin Vendor/cores/mgba            https://github.com/libretro/mgba.git              7a12d6d4b9acb14c0ae62c9166b6a2f3d08007f6
pin Vendor/cores/genesis_plus_gx https://github.com/libretro/Genesis-Plus-GX.git   393f70cd64c7334564c19a424c383f53986c13f4
pin Vendor/cores/beetle_psx      https://github.com/libretro/beetle-psx-libretro.git 10e4b0c6ceae20daa65ddf436a4445dddd0982d2
pin Vendor/cores/picodrive       https://github.com/libretro/picodrive.git         1890c2932234c9d30f4cd3851d02228baae8f09e
pin Vendor/cores/mupen64plus_next https://github.com/libretro/mupen64plus-libretro-nx.git 12edd2c74a517ff86dfa8cfc71ad75e4c10486d5
# PicoDrive's own submodules that the C-only build compiles (no Cyclone asm, no libchdr).
git -C Vendor/cores/picodrive submodule update --init --depth 1 platform/libpicofe platform/common/dr_libs pico/sound/emu2413
