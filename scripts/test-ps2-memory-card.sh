#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
core=Vendor/cores/lrps2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"${CC:-cc}" -std=c99 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    -I "$core" -I "$core/pcsx2" -I "$core/libretro/libretro-common/include" \
    Tests/Portable/PS2MemoryCardTests.c Host/CoreEntry/lrps2/se_memcard.c \
    -o "$work/test-card"
"$work/test-card" "$work"
