#!/usr/bin/env bash
# Fetches freely-licensed homebrew test ROMs into Tests/Fixtures/local (gitignored).
# Never commit these files or bundle them into the app. Each download is pinned (tag/commit +
# SHA-256); a failed download prints a warning and the matching host tests skip.
#
#   SNES      PeterLemon/SNES HelloWorld, ControllerLatency  (no licence file: local testing only)
#   GB        mattcurrie/dmg-acid2 v1.0                      (MIT)
#   GBC       mattcurrie/cgb-acid2 v1.1                      (MIT)
#   GBA       jsmolka/gba-tests ppu/hello.gba                (MIT)
#   Genesis   rhargreaves/mega-drive-midi-interface v1.34    (GPLv3)
#   32X       haroldo-ok/noudar-32x v0.0.2                   (BSD 2-Clause)
#   N64       PeterLemon/N64 RDP cube demo                   (Unlicense; boots with Nintendo's IPL3 bootcode)
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/Tests/Fixtures/local"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$dest"
failures=0

fetch() { # name url sha256
  local name="$1" url="$2" sha="$3"
  if [ -f "$dest/$name" ] && [ "$(shasum -a 256 "$dest/$name" | cut -d' ' -f1)" = "$sha" ]; then return; fi
  if curl -fsSL --retry 2 -o "$tmp/$name" "$url" &&
     [ "$(shasum -a 256 "$tmp/$name" | cut -d' ' -f1)" = "$sha" ]; then
    mv "$tmp/$name" "$dest/$name"
  else
    echo "warning: could not fetch $name from $url (tests that need it will skip)" >&2
    failures=$((failures + 1))
  fi
}

if git clone --depth 1 --quiet https://github.com/PeterLemon/SNES.git "$tmp/SNES"; then
  cp "$tmp/SNES/HelloWorld/HelloWorld.sfc" "$tmp/SNES/INPUT/ControllerLatency/ControllerLatency.sfc" "$dest/"
else
  echo "warning: could not clone PeterLemon/SNES (SNES tests will skip)" >&2
  failures=$((failures + 1))
fi

fetch dmg-acid2.gb https://github.com/mattcurrie/dmg-acid2/releases/download/v1.0/dmg-acid2.gb \
  464e14b7d42e7feea0b7ede42be7071dc88913f75b9ffa444299424b63d1dff1
fetch cgb-acid2.gbc https://github.com/mattcurrie/cgb-acid2/releases/download/v1.1/cgb-acid2.gbc \
  197fb0bcec544f0400527fc707e0a94f55435974986e6986b424ace5de81720e
fetch gba-tests-hello.gba https://raw.githubusercontent.com/jsmolka/gba-tests/a7113b67e63f83a9b321696ddd7042ccfad6c881/ppu/hello.gba \
  38aed48b67bc0f701e8aa222b0c3334bd306bd29888707bb7224d81f5576c264
fetch mega-drive-midi-interface.md https://github.com/rhargreaves/mega-drive-midi-interface/releases/download/v1.34/mega-drive-midi-interface-generic-v1.34.bin \
  7fc340e1f0ecd210c91a3a70956248dda57c5b2067a6eba592aeb2b1a5e27f68
fetch cube-fill-triangle.z64 https://raw.githubusercontent.com/PeterLemon/N64/7085543e4a19d8c539fc9e0a4d2869e788b4ed4b/RDP/32BPP/Triangle/Cube/FillTriangle320x240/CubeFillTriangle32BPP320X240.N64 \
  d66c08615ccdb93d03fece84f8f5f7e08a615985fb11ec6f6c00d0f183c3b9f9

# Dreamcast homebrew (MIT, github.com/richstokes/dreamcast-homebrew). Upstream only publishes a rolling
# "continuous" release, so the pinned build falls back to its Wayback Machine capture once it moves on.
dc_release=https://github.com/richstokes/dreamcast-homebrew/releases/download/continuous
dc_archive=https://web.archive.org/web
fetch_dc() { # name sha256 archived-url
  fetch "$1" "$dc_release/$1" "$2" 2>/dev/null || true
  if [ ! -f "$dest/$1" ]; then
    failures=$((failures - 1))
    fetch "$1" "$3" "$2"
  fi
}
fetch_dc chroma-circuit.elf a04f8f0b2a3ca11857132e4c8b45b4910beda4d6539e66d87dca74eca01d44cc \
  "$dc_archive/20261115140248id_/https://release-assets.githubusercontent.com/github-production-release-asset/1347954256/2e51992b-dcb0-47aa-a0a0-828b7178b3e6?sp=r&sv=2018-11-09&sr=b&spr=https&se=2026-11-15T14%3A56%3A19Z&rscd=attachment%3B+filename%3Dchroma-circuit.elf&rsct=application%2Foctet-stream&skoid=96c2d410-5711-43a1-aedd-ab1947aa7ab0&sktid=398a6654-997b-47e9-b12b-9515b896b4de&skt=2026-11-15T13%3A55%3A39Z&ske=2026-11-15T14%3A56%3A19Z&sks=b&skv=2018-11-09&sig=5%2F5aRdw9qoRrPWJDA8sUCCOfhjOFBJvrY%2B1njnxW5pQ%3D&jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmVsZWFzZS1hc3NldHMuZ2l0aHVidXNlcmNvbnRlbnQuY29tIiwia2V5Ijoia2V5MSIsImV4cCI6MTc5NDc1MTY2OCwibmJmIjoxNzk0NzUxMzY4LCJwYXRoIjoicmVsZWFzZWFzc2V0cHJvZHVjdGlvbi5ibG9iLmNvcmUud2luZG93cy5uZXQifQ.J2ZYHCUzSBqZVxn09CudhqhyrdATE3XABUYMEXVRkec&response-content-disposition=attachment%3B%20filename%3Dchroma-circuit.elf&response-content-type=application%2Foctet-stream"
fetch_dc chroma-circuit.cdi b8786cb90dd146c52adbd512b74e6da7967c6c812bce1ad93656d1d7d3530a3d \
  "$dc_archive/20261115140254id_/https://release-assets.githubusercontent.com/github-production-release-asset/1347954256/828fc1d1-6f82-4c4f-8ccf-1ef4b9783e0b?sp=r&sv=2018-11-09&sr=b&spr=https&se=2026-11-15T14%3A56%3A18Z&rscd=attachment%3B+filename%3Dchroma-circuit.cdi&rsct=application%2Foctet-stream&skoid=96c2d410-5711-43a1-aedd-ab1947aa7ab0&sktid=398a6654-997b-47e9-b12b-9515b896b4de&skt=2026-11-15T13%3A55%3A24Z&ske=2026-11-15T14%3A56%3A18Z&sks=b&skv=2018-11-09&sig=EAC9j5BjeBhjL2eqJjEMZuImSFzJ%2BAHIuvvLGPAkx0s%3D&jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmVsZWFzZS1hc3NldHMuZ2l0aHVidXNlcmNvbnRlbnQuY29tIiwia2V5Ijoia2V5MSIsImV4cCI6MTc5NDc1MTY3NCwibmJmIjoxNzk0NzUxMzc0LCJwYXRoIjoicmVsZWFzZWFzc2V0cHJvZHVjdGlvbi5ibG9iLmNvcmUud2luZG93cy5uZXQifQ.febnlu-Cj1OnuAQG6xG37eSv4LepB-dVH-fI2Ro_of4&response-content-disposition=attachment%3B%20filename%3Dchroma-circuit.cdi&response-content-type=application%2Foctet-stream"

noudar_sha=e162e5b9fc80b1671eaf8c68d886b8fc51601141ed2373b678f9465981875c0d
if [ ! -f "$dest/noudar.32x" ] || [ "$(shasum -a 256 "$dest/noudar.32x" | cut -d' ' -f1)" != "$noudar_sha" ]; then
  if curl -fsSL --retry 2 -o "$tmp/noudar.zip" https://github.com/haroldo-ok/noudar-32x/releases/download/v0.0.2/noudar.0.0.2.32x.zip &&
     unzip -p "$tmp/noudar.zip" noudar.0.0.2.32x > "$tmp/noudar.32x" &&
     [ "$(shasum -a 256 "$tmp/noudar.32x" | cut -d' ' -f1)" = "$noudar_sha" ]; then
    mv "$tmp/noudar.32x" "$dest/noudar.32x"
  else
    echo "warning: could not fetch noudar-32x v0.0.2 (32X frame tests will skip)" >&2
    failures=$((failures + 1))
  fi
fi

echo "Fixtures ready in $dest ($failures unavailable)"
