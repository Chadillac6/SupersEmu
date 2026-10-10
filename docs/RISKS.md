# Risks

| Risk | Impact | Mitigation | Status |
|---|---|---|---|
| N64 without JIT on iOS | N64 may run too slowly on iPhone | Test Mupen64Plus-Next interpreter on real devices early; ship N64 as "beta" per device if needed | Open, needs Chad's hardware |
| Google restricted scope | Unverified-app warning, 100-user cap | Acceptable for friends; verification before public release | Accepted |
| Non-commercial core licences | App can't be sold | Keep app free; GPLv3 open source | Accepted |
| ROM/BIOS legality | App Store/TestFlight rejection | No ROMs/BIOS bundled; user imports only | Designed in |
| Save-state compatibility across core versions | Lost progress after updates | Pin cores; store core version; keep native saves as fallback | Designed in |
| Simulator-only testing | Performance and controller claims unverified | Validate on Chad's devices before claiming support | Open |
| Test ROM licence | Can't commit fixtures | PeterLemon/SNES ROMs fetched locally, never committed; find a clearly licensed set for CI | Open |
