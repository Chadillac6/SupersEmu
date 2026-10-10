# M0 feasibility spike report

Goal (PRD): launch a legally distributable SNES test game from a SwiftUI entry point, save and
load a state, and return cleanly to SwiftUI, on macOS and iOS.

## What was actually run
Environment: macOS 26.6 VM on Apple M4 Pro, Xcode 26.6, iPhone 17 simulator (iOS 26).

| Check | Result | Evidence |
|---|---|---|
| Snes9x (pinned submodule) builds for macOS arm64 and iOS simulator | Pass | `scripts/build.sh` |
| Host loads ROM, reports Snes9x and ~60 fps timing | Pass | `testLoadsSnes9xAndReportsTiming` |
| Core renders a non-blank 256x224 frame | Pass | `testRendersNonBlankFrame` |
| Restoring a state replays identically (state + frame match) | Pass | `testStateRestoreIsDeterministic` |
| State file saved in one session resumes in a fresh session | Pass | `testStateFileResumesInFreshSession` |
| Only one core instance can be active | Pass | `testOnlyOneHostCanBeActive` |
| iOS app launches, imports 2 ROMs, shows library | Pass | simulator screenshot |
| Emulation speed (macOS, M4 Pro VM) | 120 frames in < 0.05 s (> 40x real time) | test timings |

## Not yet verified
- Interactive play, save/load buttons and return-to-library in the UI (handed to UI testing).
- Physical iPhone/iPad/Mac performance, real controllers, audio latency.
- N64 (separate risk spike), Google Drive, any other console.

## Spike design
- `Host/SELibretroHost.{h,mm}`: libretro frontend (video XRGB8888/RGB565/0RGB1555, audio via
  AVAudioEngine ring buffer, joypad input, SRAM, serialize/unserialize).
- `App/`: SwiftUI library grid, Files import with SHA-256 dedupe, player with on-screen
  controls (iOS), GameController + keyboard input, 30 s autosave and resume.
- Rendering is CALayer contents per frame on the main thread. Fine for SNES; M1 moves to a
  dedicated emulation thread and Metal.

## Test ROMs
PeterLemon/SNES homebrew (`HelloWorld.sfc`, `ControllerLatency.sfc`), fetched by
`scripts/fetch-test-roms.sh`. No licence file upstream, so they are never committed.
