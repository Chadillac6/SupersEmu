# Console to core matrix

| Console | Default core | Core ID | Licence | Status |
|---|---|---|---|---|
| SNES | Snes9x | `snes9x` | Non-commercial | **Running** (M0; macOS tests + iOS builds) |
| Game Boy / Color | Gambatte | `gambatte` | GPLv2 | **Running** (M1; macOS tests + iOS builds) |
| Game Boy Advance | mGBA | `mgba` | MPL 2.0 | **Running** (M1; macOS tests + iOS builds) |
| Genesis / Mega Drive | Genesis Plus GX | `genesis_plus_gx` | Non-commercial | **Running** (M1; macOS tests + iOS builds) |
| Sega CD | Genesis Plus GX | | Non-commercial | Planned M2; needs user BIOS + CHD/CD sources |
| Sega 32X | PicoDrive | | MAME (non-commercial) | Planned M2 |
| PlayStation | Beetle PSX (mednafen_psx) | `beetle_psx` | GPLv2 | **Linked** (M2; macOS tests + iOS builds). Boots bundled OpenBIOS without a Sony BIOS; no commercial disc or real BIOS tested yet |
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
| Genesis Plus GX | [libretro/Genesis-Plus-GX](https://github.com/libretro/Genesis-Plus-GX) | `393f70cd64c7334564c19a424c383f53986c13f4` | `LICENSE.txt` (non-commercial) | md, gen, smd, bin, mdx |
| Beetle PSX | [libretro/beetle-psx-libretro](https://github.com/libretro/beetle-psx-libretro) | `10e4b0c6ceae20daa65ddf436a4445dddd0982d2` | `COPYING` (GPLv2) | cue, chd, m3u, pbp |

**Licensing.** Snes9x and Genesis Plus GX forbid commercial use, so SupersEmu must stay free:
never sold, no ads, no paid tier. Gambatte and Beetle PSX are GPLv2 and mGBA is MPL 2.0; the app is planned
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
- Genesis Plus GX is built without CHD / Sega CD image support (no libchdr); uses the SDK zlib.
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

Not yet verified: running on a real iPhone/iPad, controller input, and full-speed performance on
device for any core. For PS1 also unverified: any commercial disc, a real Sony BIOS, `.chd`/`.pbp`/`.m3u`
loading, audio output, memory cards and multi-disc swap. On macOS (arm64, software renderer) it ran
1800 OpenBIOS frames in about 2.5 s, roughly 12x real time.
