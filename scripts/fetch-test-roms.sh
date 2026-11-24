#!/usr/bin/env bash
# Fetches homebrew test ROMs into Tests/Fixtures/local (gitignored).
# Never commit these files or bundle them into the app. Fleet uses --require-all;
# local downloads are best effort so host tests can skip unavailable fixtures.
#
#   SNES      PeterLemon/SNES HelloWorld                    (no licence file: local testing only)
#   GB        mattcurrie/dmg-acid2 v1.0                      (MIT)
#   GBC       mattcurrie/cgb-acid2 v1.1                      (MIT)
#   GBA       jsmolka/gba-tests ppu/hello.gba                (MIT)
#   Genesis   rhargreaves/mega-drive-midi-interface v1.34    (GPLv3)
#   32X       haroldo-ok/noudar-32x v0.0.2                   (BSD 2-Clause)
#   N64       PeterLemon/N64 RDP cube demo                   (Unlicense; boots with Nintendo's IPL3 bootcode)
set -euo pipefail
required=false
if [[ ${1:-} == --require-all ]]; then
  required=true
  shift
fi
if (( $# )); then
  echo "Usage: $0 [--require-all]" >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/Tests/Fixtures/local"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$dest"
failures=0

matches_sha() {
  [[ -f "$1" && "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$2" ]]
}

download() {
  curl -fsSL --retry 2 --retry-all-errors --connect-timeout 10 --max-time 30 -o "$1" "$2"
}

unavailable() {
  local name="$1"
  if "$required"; then
    echo "::error title=Test fixture unavailable::Could not download and verify $name" >&2
  else
    echo "warning: could not download and verify $name (tests that need it may skip)" >&2
  fi
  failures=$((failures + 1))
}

fetch() { # name url sha256 [fallback url...]
  local name="$1" primary="$2" sha="$3" url
  shift 3
  if matches_sha "$dest/$name" "$sha"; then return; fi
  for url in "$primary" "$@"; do
    if download "$tmp/$name" "$url"; then
      if matches_sha "$tmp/$name" "$sha"; then
        mv "$tmp/$name" "$dest/$name"
        return
      fi
      echo "SHA-256 mismatch for $name" >&2
    fi
  done
  unavailable "$name"
}

snes=https://raw.githubusercontent.com/PeterLemon/SNES/350b394e86ec5d62f600b5cbf64cdce3721bb6ef
fetch HelloWorld.sfc "$snes/HelloWorld/HelloWorld.sfc" \
  63ed338621788ad4ab856bb782e16044193882b7840370b500c8359a41fb87ef

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
fetch chroma-circuit.elf "$dc_release/chroma-circuit.elf" a04f8f0b2a3ca11857132e4c8b45b4910beda4d6539e66d87dca74eca01d44cc \
  "$dc_archive/20261115140248id_/https://release-assets.githubusercontent.com/github-production-release-asset/1347954256/2e51992b-dcb0-47aa-a0a0-828b7178b3e6?sp=r&sv=2018-11-09&sr=b&spr=https&se=2026-11-15T14%3A56%3A19Z&rscd=attachment%3B+filename%3Dchroma-circuit.elf&rsct=application%2Foctet-stream&skoid=96c2d410-5711-43a1-aedd-ab1947aa7ab0&sktid=398a6654-997b-47e9-b12b-9515b896b4de&skt=2026-11-15T13%3A55%3A39Z&ske=2026-11-15T14%3A56%3A19Z&sks=b&skv=2018-11-09&sig=5%2F5aRdw9qoRrPWJDA8sUCCOfhjOFBJvrY%2B1njnxW5pQ%3D&jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmVsZWFzZS1hc3NldHMuZ2l0aHVidXNlcmNvbnRlbnQuY29tIiwia2V5Ijoia2V5MSIsImV4cCI6MTc5NDc1MTY2OCwibmJmIjoxNzk0NzUxMzY4LCJwYXRoIjoicmVsZWFzZWFzc2V0cHJvZHVjdGlvbi5ibG9iLmNvcmUud2luZG93cy5uZXQifQ.J2ZYHCUzSBqZVxn09CudhqhyrdATE3XABUYMEXVRkec&response-content-disposition=attachment%3B%20filename%3Dchroma-circuit.elf&response-content-type=application%2Foctet-stream"
fetch chroma-circuit.cdi "$dc_release/chroma-circuit.cdi" b8786cb90dd146c52adbd512b74e6da7967c6c812bce1ad93656d1d7d3530a3d \
  "$dc_archive/20261115140254id_/https://release-assets.githubusercontent.com/github-production-release-asset/1347954256/828fc1d1-6f82-4c4f-8ccf-1ef4b9783e0b?sp=r&sv=2018-11-09&sr=b&spr=https&se=2026-11-15T14%3A56%3A18Z&rscd=attachment%3B+filename%3Dchroma-circuit.cdi&rsct=application%2Foctet-stream&skoid=96c2d410-5711-43a1-aedd-ab1947aa7ab0&sktid=398a6654-997b-47e9-b12b-9515b896b4de&skt=2026-11-15T13%3A55%3A24Z&ske=2026-11-15T14%3A56%3A18Z&sks=b&skv=2018-11-09&sig=EAC9j5BjeBhjL2eqJjEMZuImSFzJ%2BAHIuvvLGPAkx0s%3D&jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmVsZWFzZS1hc3NldHMuZ2l0aHVidXNlcmNvbnRlbnQuY29tIiwia2V5Ijoia2V5MSIsImV4cCI6MTc5NDc1MTY3NCwibmJmIjoxNzk0NzUxMzc0LCJwYXRoIjoicmVsZWFzZWFzc2V0cHJvZHVjdGlvbi5ibG9iLmNvcmUud2luZG93cy5uZXQifQ.febnlu-Cj1OnuAQG6xG37eSv4LepB-dVH-fI2Ro_of4&response-content-disposition=attachment%3B%20filename%3Dchroma-circuit.cdi&response-content-type=application%2Foctet-stream"

noudar_sha=e162e5b9fc80b1671eaf8c68d886b8fc51601141ed2373b678f9465981875c0d
if ! matches_sha "$dest/noudar.32x" "$noudar_sha"; then
  if download "$tmp/noudar.zip" https://github.com/haroldo-ok/noudar-32x/releases/download/v0.0.2/noudar.0.0.2.32x.zip &&
     unzip -p "$tmp/noudar.zip" noudar.0.0.2.32x > "$tmp/noudar.32x" &&
     matches_sha "$tmp/noudar.32x" "$noudar_sha"; then
    mv "$tmp/noudar.32x" "$dest/noudar.32x"
  else
    unavailable noudar.32x
  fi
fi

if (( failures )); then
  echo "Test fixture setup incomplete: $failures unavailable in $dest" >&2
  if "$required"; then exit 1; fi
else
  echo "Fixtures ready in $dest (0 unavailable)"
fi
