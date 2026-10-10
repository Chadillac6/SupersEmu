# Console to core matrix

| Console | Default core | Core ID | Licence | Status |
|---|---|---|---|---|
| SNES | Snes9x | `snes9x` | Non-commercial | **Running** (M0; macOS tests + iOS builds) |
| Game Boy / Color | Gambatte | `gambatte` | GPLv2 | **Running** (M1; macOS tests + iOS builds) |
| Game Boy Advance | mGBA | `mgba` | MPL 2.0 | **Running** (M1; macOS tests + iOS builds) |
| Genesis / Mega Drive | Genesis Plus GX | `genesis_plus_gx` | Non-commercial | **Running** (M1; macOS tests + iOS builds) |
| Sega CD | Genesis Plus GX | `genesis_plus_gx` | Non-commercial | **Core builds** (M2; macOS host tests with synthetic disc + iOS Simulator/device builds). Needs user BIOS. No real disc booted yet |
| Sega 32X | PicoDrive | `picodrive` | MAME (non-commercial) | **Running** (M2; macOS tests with homebrew 32X ROM + iOS Simulator/device builds) |
| PlayStation | Beetle PSX (mednafen_psx) | `beetle_psx` | GPLv2 | **Linked** (M2; macOS tests + iOS builds). Boots bundled OpenBIOS without a Sony BIOS; no commercial disc or real BIOS tested yet |
| Nintendo 64 | Mupen64Plus-Next | `mupen64plus_next` | GPLv2 | **Running** (M3; macOS host tests with homebrew N64 ROM + iOS Simulator). GLideN64 over libretro hardware rendering, cached interpreter. Real iPhone/iPad speed not measured |
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
| Beetle PSX | [libretro/beetle-psx-libretro](https://github.com/libretro/beetle-psx-libretro) | `10e4b0c6ceae20daa65ddf436a4445dddd0982d2` | `COPYING` (GPLv2) | cue, chd, m3u (pbp not yet) |
| Mupen64Plus-Next | [libretro/mupen64plus-libretro-nx](https://github.com/libretro/mupen64plus-libretro-nx) | `12edd2c74a517ff86dfa8cfc71ad75e4c10486d5` | `LICENSE` (GPLv2) | z64, n64, v64 |

**Licensing.** Snes9x, Genesis Plus GX and PicoDrive (MAME licence: redistribution only
non-commercially, with source) forbid commercial use, so SupersEmu must stay free:
never sold, no ads, no paid tier. Gambatte, Beetle PSX and Mupen64Plus-Next are GPLv2 and mGBA is MPL 2.0; the app is planned
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
- All cores are interpreters: no JIT, no dynarec. All but Mupen64Plus-Next are software renderers.
  Builds for macOS (arm64/x86_64), iOS device arm64 and iOS Simulator.
- Mupen64Plus-Next: GLideN64 renders through libretro hardware rendering (`RETRO_ENVIRONMENT_SET_HW_RENDER`
  in `SELibretroHost.mm`): an offscreen OpenGL core-profile context (CGL, 4.1 on current macOS), an OpenGL ES 3 `EAGLContext`
  on iOS. The core draws into a host FBO; each frame is blitted (flipped) into an IOSurface-backed
  `CVPixelBuffer` texture and copied from the surface into the normal frame buffer, so `GameSession`/
  `EmulatorScreen` present it like any software core (no `glReadPixels`). Core options are fixed by the host:
  `gliden64` RDP, `hle` RSP, `cached_interpreter` CPU, no threaded renderer. On macOS GLideN64 frame buffer emulation is off
  (`EnableFBEmulation=False`): with it on, only black reaches the host FBO (seen on a macOS VM, not yet
  checked on a real Mac GPU), so games that need frame-buffer effects can draw wrongly until that is fixed.
  Probably for the same reason, a state resumed in a new session (the app's "Resumed where you left off")
  can show stale stripes wherever the game doesn't redraw: GLideN64 doesn't write frames back to RDRAM, so
  the restored RDRAM holds old picture data. The cube demo redraws only its cubes, so it shows there. It
  isn't caused by switching cores; a host-test resume with no other core in between showed it too.
  iOS keeps the upstream default (on). The iOS Simulator can't back a GLES texture with an IOSurface
  (`CVOpenGLESTextureCacheCreateTextureFromImage` fails), so there the host falls back to `glReadPixels`.
  **Known gap:** in the iOS Simulator the test ROM's geometry is right but its colours are not (yellow
  background, black cubes, where macOS shows coloured cubes on black). Unknown whether this is the
  Simulator's GLES or GLideN64's GLES3 path; it needs a real iPhone/iPad to tell. HLE RSP only runs Nintendo microcode: current libdragon homebrew
  (custom `rspq` microcode, open-source IPL3) shows a black screen, and cxd4 LLE times out on it. CPU: cached interpreter on
  both platforms (`WITH_DYNAREC` unset): iOS forbids JIT, and upstream's own `platform=osx` build also
  disables the dynarec, so macOS uses the same tested path. Not built: ParaLLEl-RDP/RSP (Vulkan via
  MoltenVK: a later option for accuracy), angrylion, cxd4. Host test fixture: the
  PeterLemon/N64 RDP cube demo (Unlicense; like most old homebrew it boots with Nintendo's IPL3). SDK zlib replaces the bundled copy;
  `Host/CoreEntry/Mupen64PlusNext/` holds the `fp.h` shim libpng needs and the GL/GLES `glsym` switch.
  Apple marks OpenGL/OpenGL ES deprecated; both still ship on macOS 26 / iOS 26.
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
- Beetle PSX uses the software renderer only (no `HAVE_HW`, OpenGL or Vulkan) and is built without
  Lightrec (`HAVE_LIGHTREC` unset). The source list is upstream `Makefile.common` for
  `make platform=osx HAVE_LIGHTREC=0`: CHD (libretro-common rchd), PBP, threaded CD reads, PGXP.
  No dynarec sources are compiled. libretro-common `memmap.c` still contains generic JIT helpers
  (`memjit_alloc`, `memprotect`, `memsync`) that nothing in this build calls; on iOS the archive
  has no `pthread_jit_write_protect_np` reference.
  - `need_fullpath` is true: the host passes the path and the core opens the cue's tracks itself.
    `.bin`/`.iso`/`.img` are deliberately not in `CoreRegistry`, because `.bin` stays Genesis;
    discs launch through their `.cue`/`.m3u`.
  - BIOS: the core looks for `scph5500.bin`/`scph5501.bin`/`scph5502.bin` (by disc region) in the
    system directory and otherwise boots its bundled OpenBIOS.
  - Size (Release, arm64 slice of the prelinked object): 4.0 MB `__TEXT` + 4.7 MB `__DATA`, plus
    16.4 MB zero-fill (RAM, not file size). The universal macOS archive is 22.3 MB; the iOS device
    (arm64) archive is 10.6 MB.
  - Build time: a clean target build takes about 29 s wall on the 12-core build VM (Release macOS
    and Debug iOS device each). The full `./scripts/build.sh` (all cores, macOS tests + iOS
    Simulator app) takes 1 m 47 s. A clean upstream `make` dylib takes about 72 s.
  - Builds verified: macOS arm64/x86_64, iOS device arm64 (`-sdk iphoneos`, target only), and the
    iOS Simulator app (arm64/x86_64) via `scripts/build.sh`.

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

Beetle PSX has no matrix fixture. Its tests live in `Tests/HostTests/SEBeetlePSXTests.mm` and use
generated cue/bin sets only:
- system info and `need_fullpath`
- a no-BIOS synthetic disc loads, runs on OpenBIOS and renders the OpenBIOS shell (non-blank, 8-bit
  scaled), with a byte-identical state and frame replay
- a cue with a missing track fails with an NSError and leaves the core reusable
- a real-BIOS boot, which is skipped unless `SUPERSEMU_PSX_BIOS` or
  `Tests/Fixtures/local/bios/scph5501.bin` exists. Never run here: no BIOS is available.

PS-EXE homebrew (e.g. MIT-licensed JaCzekanski/ps1-tests) does **not** run without a Sony BIOS. Beetle's
EXE side-loader patches a Sony-BIOS-specific address (`0x6990`), so on OpenBIOS the shell runs instead.
OpenBIOS also did not boot an ISO9660 disc generated with `SYSTEM.CNF` + `PSX.EXE`, either as
`MODE2/2048` or as `MODE2/2352` without EDC/ECC. So no homebrew fixture is fetched yet.

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
output and commercial-game compatibility. PS1: any commercial disc, a real Sony
BIOS, `.chd` loading (`.m3u` is verified only with two synthetic cues, including a disc swap), audio output, memory cards and swapping real discs. On macOS (arm64,
software renderer) Beetle PSX ran 1800 OpenBIOS frames in about 2.5 s, roughly 12x real time.
