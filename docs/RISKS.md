# Risks

| Risk | Impact | Mitigation | Status |
|---|---|---|---|
| N64 without JIT on iOS | N64 may run too slowly on iPhone | Mupen64Plus-Next builds for iOS arm64 with the interpreter (see `docs/N64_BUILD_CHECK.md`); measure FPS on real devices early; ship N64 as "beta" per device if needed | Open: builds, speed needs Chad's hardware |
| Google restricted scope | Unverified-app warning, 100-user cap | Acceptable for friends; verification before public release | Accepted |
| Non-commercial core licences | App can't be sold | Keep app free; GPLv3 open source | Accepted |
| ROM/BIOS legality | App Store/TestFlight rejection | No ROMs/BIOS bundled; user imports only | Designed in |
| Save-state compatibility across core versions | Lost progress after updates | Pin cores; store core version; keep native saves as fallback | Designed in |
| Simulator-only testing | Performance and controller claims unverified | Validate on Chad's devices before claiming support | Open |
| Test ROM licence | Can't commit fixtures | PeterLemon/SNES ROMs fetched locally, never committed; find a clearly licensed set for CI | Open |
| Generic USB controllers on iPhone/iPad | Pads that don't identify as Xbox/PlayStation/Switch/MFi may not work | `GCController` everywhere; `IOHIDManager` fallback on Mac; per-model 8BitDo mode guide (`docs/specs/controllers.md`) | Open, needs Chad's controllers |
