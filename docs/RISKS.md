# Risks

| Risk | Impact | Mitigation | Status |
|---|---|---|---|
| N64 without JIT on iOS | N64 may run too slowly on iPhone | Mupen64Plus-Next builds for iOS arm64 with the interpreter (see `docs/N64_BUILD_CHECK.md`); measure FPS on real devices early; ship N64 as "beta" per device if needed | Open: builds, speed needs Chad's hardware |
| Non-commercial core licences | App can't be sold | Keep app free; GPLv3 open source | Accepted |
| ROM/BIOS legality | App Store/TestFlight rejection | No ROMs/BIOS bundled; user imports only | Designed in |
| Save-state compatibility across core versions | Lost progress after updates | Pin cores; store core version; keep native saves as fallback | Designed in |
| Simulator-only testing | Performance and controller claims unverified | Validate on Chad's devices before claiming support | Open |
| Test ROM licence | Can't commit fixtures | PeterLemon/SNES ROMs fetched locally, never committed; find a clearly licensed set for CI | Open |
| Generic USB controllers on iPhone/iPad | Pads that don't identify as Xbox/PlayStation/Switch/MFi may not work | `GCController` everywhere; `IOHIDManager` fallback on Mac; per-model 8BitDo mode guide (`docs/specs/controllers.md`) | Open, needs Chad's controllers |
| Mac mini offline or asleep | Friends can't download new games or sync saves | Daemon at boot, disable sleep in setup checklist, play and save offline then sync later, "server offline" status | Designed in |
| Remote access depends on Tailscale | Friends must install Tailscale; free-plan limits | Machine sharing to friends' own accounts; Cloudflare Tunnel fallback | Open, verify in server spike |
| Public HTTPS exposure | Internet-facing routes increase attack surface | Disabled by default; Caddy terminates HTTPS and forwards only to loopback; public router omits admin routes, rejects API tokens and keeps per-user permissions/rate limits | Designed in; local proxy e2e pending |
| Pairing/token security | A leaked token exposes a user's games and saves | Per-device tokens in Keychain, cert pinning, revoke, scoped bot tokens, audit log | Designed in |
| Large downloads (PS1 discs) | Slow first play, phone storage | Resumable downloads, cache sizes shown, remove downloaded games | Designed in |
