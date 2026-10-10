# Console to core matrix

| Console | Default core | Core ID | Licence | Status |
|---|---|---|---|---|
| SNES | Snes9x | `snes9x` | Non-commercial | **Running** (M0; macOS tests + iOS builds) |
| Game Boy / Color | Gambatte | `gambatte` | GPLv2 | **Running** (M1; macOS tests + iOS builds) |
| Game Boy Advance | mGBA | `mgba` | MPL 2.0 | **Running** (M1; macOS tests + iOS builds) |
| Genesis / Mega Drive | Genesis Plus GX | `genesis_plus_gx` | Non-commercial | **Running** (M1; macOS tests + iOS builds) |
| Sega CD | Genesis Plus GX | `genesis_plus_gx` | Non-commercial | **Core builds** (M2; macOS host tests with synthetic disc + iOS Simulator/device builds). Needs user BIOS. No real disc booted yet |
| Sega 32X | PicoDrive | `picodrive` | MAME (non-commercial) | **Running** (M2; macOS tests with homebrew 32X ROM + iOS Simulator/device builds) |
| PlayStation | Beetle PSX (mednafen_psx) | | GPLv2 | Planned M2; needs user BIOS, disc/.m3u support |
| Nintendo 64 | Mupen64Plus-Next | | GPLv2 | **Risk**: builds for iOS arm64 (interpreter, no JIT); needs GPU rendering in host + device speed test |
| Dreamcast | Flycast | | GPLv2 | Phase 2 |

Alternates: bsnes (SNES accuracy), SameBoy (GB), SwanStation / PCSX ReARMed (PS1), ParaLLEl N64.

## Linked cores (pinned)

Each core is a git submodule under `Vendor/cores/`, pinned by `scripts/pin-cores.sh`.

| Core | Upstream | Commit | Licence file | Extensions (`App/CoreRegistry.swift`) |
|---|---|---|---|---|
| Snes9x | [libretro/snes9x](https://github.com/libretro/snes9x) | `fae2fea08f74180759ef540ee94259213f503480` | `LICENSE` (non-commercial) | sfc, smc |
| Gambatte | [libretro/gambatte-libretro](https://github.com/libretro/gambatte-libretro) | `d9d6cd06382d1ced30de34d56d3609452323dab1` | `COPYING` (GPLv2) | gb, gbc, dmg |
| mGBA | [libretro/mgba](https://github.com/libretro/mgba) | `7a12d6d4b9acb14c0ae62c9166b6a2f3d08007f6` | `LICENSE` (MPL 2.0) | gba |
| Genesis Plus GX | [libretro/Genesis-Plus-GX](https://github.com/libretro/Genesis-Plus-GX) | `393f70cd64c7334564c19a424c383f53986c13f4` | `LICENSE.txt` (non-commercial) | md, gen, smd, bin, mdx; Sega CD discs by console `segacd` |
| PicoDrive | [libretro/picodrive](https://github.com/libretro/picodrive) | `1890c2932234c9d30f4cd3851d02228baae8f09e` | `COPYING` (MAME licence, non-commercial) | 32x |

**Licensing.** Snes9x, Genesis Plus GX and PicoDrive (MAME licence: redistribution only
non-commercially, with source) forbid commercial use, so SupersEmu must stay free:
never sold, no ads, no paid tier. Gambatte is GPLv2 and mGBA is MPL 2.0; the app is planned
GPLv3 and ships each core's licence and source link. No ROMs or BIOS files are bundled.

## How cores are linked

All libretro cores export the same `retro_*` symbols, so each core is a static library
(`<Core>Core_${platform}` in `project.yml`) that Xcode prelinks into a single object
(`GENERATE_MASTER_OBJECT_FILE`) exporting only `se_core_<id>()` (`Host/CoreEntry/core.exports`).
That function returns an `SECoreAPI` function table (`Host/CoreEntry/SECoreAPI.h`);
`SELibretroHost` drives whichever table matches the requested core ID. One core runs at a time.
This replaces the per-core dynamic frameworks proposed in ADR 0002 for M1: same symbol isolation,
no `dlopen`, no extra frameworks to embed and sign.

Save metadata: `SELibretroHost.coreID` (e.g. `gambatte`) and `coreVersion` (core's own version
plus pinned short commit, e.g. `v0.5.0 (d9d6cd0)`).

Build notes:
- All cores are interpreters or software renderers: no JIT, no dynarec, no OpenGL. Builds for
  macOS (arm64/x86_64), iOS device arm64 and iOS Simulator.
- mGBA's CMake-generated `flags.h` / `version.c` are replaced by `Host/CoreEntry/mgba/`
  (GB + GBA, `MINIMAL_CORE=2`, no threads, no scripting/debugger/SQLite/PNG/zip).
- Genesis Plus GX: Sega CD built as upstream `Makefile.libretro` does (`HAVE_CHD`): `core/cd_hw`,
  libchdr + LZMA + zstd from `libretro/deps` (`USE_LIBCHDR`, `_7ZIP_ST`, `ZSTD_DISABLE_ASM`) and
  Tremor for OGG audio tracks (`USE_LIBTREMOR`); SDK zlib. Loads `.cue`/`.iso`/`.chd`/`.m3u` by path
  (`need_fullpath`). BIOS: `bios_CD_U.bin` / `bios_CD_E.bin` / `bios_CD_J.bin` in the system directory,
  chosen by disc region. `Host/CoreEntry/genesis_plus_gx/se_load_game.c` wraps `retro_load_game`
  (`SE_CORE_LOAD_GAME`): it clears the core's static "BIOS loaded" flags (they outlive `retro_deinit`
  in a static link) so a missing BIOS always fails, and rejects a disc file that upstream would
  silently load as a cartridge (e.g. a cue whose track file is missing).
- PicoDrive: C interpreters only, as iOS forbids JIT: FAME 68000 (`EMU_F68K`), CZ80 (`_USE_CZ80`),
  MAME SH-2 interpreter; no Cyclone/DrZ80 assembly, no SH-2/SVP dynarec (`cpu/drc`, `cpu/sh2/compiler.c`
  not compiled). Tremor on (OGG cue tracks); no libchdr (Sega CD uses Genesis Plus GX). 32X BIOS is
  optional (PicoDrive has built-in boot code). `REVISION` comes from `Host/CoreEntry/picodrive/prefix.h`.
  `Host/CoreEntry/picodrive/include/ogg` is a symlink to Tremor's `ogg/` headers so Tremor's own
  directory (whose `block.h` shadows the SDK's `<Block.h>` on case-insensitive disks) stays off the
  header path. PicoDrive's nested submodules (`libpicofe`, `dr_libs`, `emu2413`) are initialised by
  `scripts/build.sh` / `pin-cores.sh`.
- The host implements libretro disk control (legacy + EXT, see `disc-games.md`); tested with a stub core. Swapping on a real disc core is unverified.
- Gambatte is built with `-ftrivial-auto-var-init=zero` so unused save-state fields are
  deterministic.

## Server import for disc systems (M2 import track)
The server importer groups `.cue`+tracks, `.chd`, `.iso` and `.m3u` into disc games for PS1 (`psx`) and Sega CD (`segacd`), and detects 32X carts (`sega32x`). It files BIOS files by hash (`KnownBIOS`) and serves them at `/v1/bios`. Details and the verification status are in [disc-games.md](disc-games.md#import-track-built-and-verified-server).
Verified with synthetic fixtures only. Core playback of these games belongs to the PS1 and Sega CD tracks.

## Tests and fixtures

`Tests/HostTests/SECoreMatrixTests.mm` runs per core: loads + reports id/version/timing, renders
a non-blank frame, deterministic state round trip, and a state file resumed in a fresh session.
ROMs come from `scripts/fetch-test-roms.sh` (gitignored `Tests/Fixtures/local`; missing ROMs skip).

| Core | Fixture | Source | Licence |
|---|---|---|---|
| Snes9x | HelloWorld.sfc | PeterLemon/SNES | none stated (local testing only) |
| Gambatte | dmg-acid2.gb, cgb-acid2.gbc | mattcurrie/dmg-acid2 v1.0, cgb-acid2 v1.1 | MIT |
| mGBA | gba-tests-hello.gba | jsmolka/gba-tests `ppu/hello.gba` | MIT |
| Genesis Plus GX | mega-drive-midi-interface.md | rhargreaves/mega-drive-midi-interface v1.34 | GPLv3 |
| PicoDrive | noudar.32x | haroldo-ok/noudar-32x v0.0.2 (zip, SHA-256 pinned) | BSD 2-Clause |

`Tests/HostTests/SESegaDiscCoreTests.mm` needs no downloads (all content generated in a temp dir):
- Sega CD, synthetic one-track `MODE1/2048` cue + iso with a `SEGADISCSYSTEM` header: fails to load
  without BIOS; loads, runs 30 frames and serialises state with blank 128 KB `bios_CD_*.bin` files;
  a cue whose track file is missing fails to load.
- PicoDrive, synthetic 128 KB `.32x` (68000 vectors + `SEGA 32X` header + a `BRA *` loop): loads,
  reports metadata/timing, runs 60 frames, state round trip.

Known gap: Genesis Plus GX does not save the YM2612 busy timer (`fm_cycles_busy`), so a ROM that
polls the FM chip can differ by a few bytes after a restore. Frames replay identically; the
byte-exact state comparison for this core is an expected (non-strict) failure in the tests.
PicoDrive is similar: after a restore its YM2612 chunk (`CHUNK_FMv3`: `eg_cnt`/`eg_timer` and
per-channel FM fields) differs by ~10 bytes while frames match; also an expected (non-strict) failure.

iOS: `SupersEmu-iOS` builds for the iOS Simulator (`scripts/build.sh`) and for `generic/platform=iOS`
(device arm64, `CODE_SIGNING_ALLOWED=NO`) with both new cores linked.

Not yet verified: running on a real iPhone/iPad, controller input, and full-speed performance on
device for any core. Sega CD: booting a real disc with a real BIOS, CHD images (libchdr is compiled
but no CHD was loaded: no `chdman` here), OGG/WAV audio tracks and multi-disc `.m3u`. 32X: audio
output and commercial-game compatibility.
