# SupersEmu

A Netflix/Plex-style retro game library for iPhone, iPad and Mac. Import games you own, browse
them as a library, play with touch or a controller, and pick up where you left off.

Status: **M0 feasibility spike done**. SNES (Snes9x) runs on macOS and the iOS simulator. Next
architecture (proposed): a Plex-style SupersEmu Server on a Mac mini with invited users and local
play, see [ADR 0004](docs/adr/0004-home-server.md) and [docs/specs/server.md](docs/specs/server.md). See [docs/M0_SPIKE_REPORT.md](docs/M0_SPIKE_REPORT.md) and
[docs/ARCHITECTURE_AND_PLAN.md](docs/ARCHITECTURE_AND_PLAN.md).

SupersEmu does not include games or BIOS files.

## Build
Requirements: Xcode 26+, `brew install xcodegen`.

```sh
git clone --recursive https://github.com/Chadillac6/SupersEmu.git
cd SupersEmu
scripts/build.sh          # fetch test ROMs, generate project, run macOS tests, build iOS sim
open SupersEmu.xcodeproj  # schemes: SupersEmu-macOS, SupersEmu-iOS
```

Set `SUPERSEMU_IMPORT_DIR=/path/to/roms` in the scheme (or `SIMCTL_CHILD_SUPERSEMU_IMPORT_DIR`
with `xcrun simctl launch`) to auto-import a folder on launch.

## Controls
Keyboard: arrows, Z = B, X = A, A = Y, S = X, Q/W = L/R, Return = Start, Tab = Select.
Controllers: any MFi/Xbox/PlayStation/8BitDo controller, mapped by button position.

## Layout
- `App/` SwiftUI app (library, player, input)
- `Host/` libretro host
- `Vendor/cores/` pinned emulator cores (git submodules)
- `docs/` ADRs, specs, risks, reports

## Licence
GPLv3 (planned, to match bundled GPL cores). Snes9x is under its own non-commercial licence.
