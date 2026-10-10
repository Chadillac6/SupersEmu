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

echo "Fixtures ready in $dest ($failures unavailable)"
