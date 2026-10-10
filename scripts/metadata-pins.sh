#!/usr/bin/env bash
# Prints the SHA-256 of every libretro-database DAT the server uses at a given commit, for MetadataCatalog.pinned.
# Usage: scripts/metadata-pins.sh <libretro-database commit>
set -euo pipefail
commit="${1:?usage: $0 <commit>}"
systems=(
  "Nintendo - Super Nintendo Entertainment System:no-intro" "Nintendo - Game Boy:no-intro"
  "Nintendo - Game Boy Color:no-intro" "Nintendo - Game Boy Advance:no-intro" "Sega - Mega Drive - Genesis:no-intro"
  "Sega - 32X:no-intro" "Nintendo - Nintendo 64:no-intro" "Sega - Mega-CD - Sega CD:redump" "Sony - PlayStation:redump"
)
for entry in "${systems[@]}"; do
  name="${entry%%:*}"
  for folder in "${entry##*:}" genre releaseyear publisher developer maxusers; do
    path=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "metadat/$folder/$name.dat")
    if sha=$(curl -fsSL "https://raw.githubusercontent.com/libretro/libretro-database/$commit/$path" | shasum -a 256); then
      echo "$name  $folder  ${sha%% *}"
    fi
  done
done
