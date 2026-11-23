#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
core=Vendor/cores/lrps2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

feature_macro=-D_POSIX_C_SOURCE=200809L
if [[ $(uname -s) == Darwin ]]; then
    feature_macro=-D_DARWIN_C_SOURCE
fi
"${CC:-cc}" -std=c99 "$feature_macro" -Wall -Wextra -Werror \
    -I "$core" -I "$core/pcsx2" -I "$core/libretro/libretro-common/include" \
    Tests/Portable/PS2MemoryCardTests.c Host/CoreEntry/lrps2/se_memcard.c \
    -o "$work/test-card"
"$work/test-card" "$work"
