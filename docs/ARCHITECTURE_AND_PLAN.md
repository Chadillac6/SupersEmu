# SupersEmu — Architecture Options & Spec-Driven Plan (v0.2, for owner review)

Status: **DRAFT — awaiting owner decisions (Section 9).** No code written yet. Builds on `RETRO_GAMING_PLATFORM_DEVIN_PRD.md`.

Legend: **[Verified]** = checked today against a primary source. **[Inference]** = my engineering judgement, to be proven in the M0 spike.

## v0.2 change: Plex-style home server (ADR 0004, accepted)

- Chad's Mac mini runs **SupersEmu Server**. He imports and organises games once. In Phase 2 he
  invites fewer than 10 friends and chooses which games each person sees.
- Phase 2 friends sign in with an invite. Games download to their Mac/iPhone/iPad and **run locally**. Saves,
  favourites and history are private per user and sync to the server.
- LAN and remote (Tailscale) access from Phase 1. Server starts at boot. HTTP API + `supersemu` CLI
  for bots such as OpenClaw.
- **Phase 1 is Chad only** (server + Mac/iPhone/iPad apps) so he can use it and give feedback.
  **Phase 2 goal:** invited friends with their own accounts, permitted games and private saves.
  Phase 1 is multi-user-ready underneath, so Phase 2 adds features without a rewrite.
- Two phases only, no game streaming. Google Drive is no longer how users get games (ADR 0003 superseded).
- Details: `docs/specs/server.md`. UI direction: `docs/specs/ui-direction.md`. Sections 2, 4 and 8
  below are updated; the rest of v0.1 still stands.

---

## 0. TL;DR

1. **Recommendation: build our own app from the ground up (SwiftUI) on top of a thin "libretro host" we write ourselves, using existing open-source emulator cores.** Do **not** fork RetroArch. Do **not** write emulators from scratch.
2. "Ground up" here means: we own 100% of the UI, library, import, save and sync code; we reuse the battle-tested emulator *cores* (Snes9x, mGBA, Beetle PSX, etc.) through the small, stable libretro C API. This is the same pattern OpenEmu/Provenance use and is the only route that gets you a Netflix-quality UX without a RetroArch settings maze underneath.
3. Every required core already compiles for iOS arm64 on libretro's own build farm **[Verified]**, so the core side is low-risk except **N64** (no JIT on iOS → performance risk) — that gets its own early spike.
4. **Dreamcast moves to Phase 2** per your call.
5. The biggest *non-emulation* decision is **cloud storage**: Google Drive works, but its permission model fights the "drop files in a Drive folder from anywhere" flow. iCloud Drive would be noticeably simpler and more "behind the scenes". Needs your decision (Q2).
6. Process: spec-first. Each feature gets a short spec with acceptance criteria in `docs/specs/` before code; milestones end in a demo + test evidence; nothing is "supported" until it runs on your physical device.

---

## 1. Options considered

| | **A. Fork RetroArch** + SwiftUI shell | **B. Custom libretro host + SwiftUI** (recommended) | **C. Fork Provenance / Delta** | **D. Write emulators ourselves** |
|---|---|---|---|---|
| What it is | Embed RetroArch (C, ~1M LOC) and hide/replace its menus | Our Swift app + ~3–5k LOC C/ObjC++ host implementing the libretro API; cores bundled as signed frameworks | Start from an existing iOS emulator app | Clean-room emulators per console |
| UX control | Low–medium. RetroArch owns the run loop, input, config files, menus; fighting it forever | **Full.** Every pixel and flow is ours | Medium. Inherit their architecture/UI decisions | Full |
| Mac + iPhone + iPad from one codebase | Yes, but RetroArch's Apple targets are their own Xcode project | **Yes** (one SwiftUI multiplatform target) | Delta: iOS only. Provenance: iOS/tvOS, Mac via Catalyst | Yes |
| Core availability | All | **All** (same cores RetroArch uses) | Delta: few systems (no PS1/N64 parity, no Sega CD/32X). Provenance: broad | You'd be writing 9 emulators — years |
| Save-state portability Mac ↔ iPhone | Possible but users can swap cores/versions | **Strong**: we pin one core build per app release on all devices → same state format everywhere | Varies | n/a |
| Licence | GPLv3 for the whole app **[Verified]** | Our code is ours; bundled cores carry their own licences (Section 3) | Delta: **AGPLv3** **[Verified]**; Provenance: custom/mixed licence **[Verified: GitHub reports NOASSERTION]** | Ours |
| Maintenance | Constant upstream merge pain | We update cores on our schedule | Upstream drift + their tech debt | Huge |
| Time to first playable | Fast for a demo, slow for a good product | ~1 session for SNES spike | Fast demo, slow to reshape | Not viable |
| Verdict | ❌ "RetroArch settings page wearing new colors" — exactly what PRD §15 says not to ship | ✅ | ❌ Licence and architecture lock-in | ❌ |

**Why B wins for your goals ("extremely user-friendly, does setup behind the scenes"):**
- The libretro API is small (load game, run one frame, video/audio/input callbacks, serialize/unserialize, memory regions for SRAM, disc control). We hide all of it.
- We control the save pipeline end to end — critical for auto-save + cloud resume, which is your #1 "it just works" feature.
- We pick one recommended core per console and never show the word "core" to a normal user.

---

## 2. Proposed tech stack (B)

```
SwiftUI app (macOS 15+, iOS/iPadOS 18+)        ← one multiplatform target
 ├─ Library (SQLite via GRDB)                   fast queries for 5k+ games, migrations
 ├─ Import pipeline (Swift actors)              unzip/7z → hash → identify → group discs → art
 ├─ Save coordinator                            native SRAM, autosave ring, manual slots
 ├─ Server client (pairing, library, downloads, per-user save sync)  → SupersEmu Server on the Mac mini
 ├─ Controllers (Apple GameController)          8BitDo etc., per-console/per-game maps
 └─ EmulatorHost (C/ObjC++)                     libretro frontend, Metal video, AVAudioEngine audio
      └─ Bundled, code-signed cores (.framework per core)
```

- Video: software-rendered cores (most of ours) → upload framebuffer to a Metal texture each frame; shaders (CRT/LCD) later as Metal shaders.
- Hardware-rendered cores (N64, optionally PS1 HW) need an OpenGL ES / Vulkan context: OpenGL ES (deprecated but functional on Apple) or Vulkan via MoltenVK. **[Inference — spike item]**
- iOS cannot download executable code after install, so all cores ship inside the app bundle. **[Verified via PRD-cited libretro docs]**
- No JIT on standard iOS distribution → cores run in interpreter/cached-interpreter mode on iPhone/iPad. Mac can use dynarec. **[Inference from Apple policy; spike will measure FPS]**

---

## 3. Console → core matrix (proposed defaults)

Licences **[Verified]** from libretro-core-info today. iOS arm64 builds **[Verified]** exist on libretro buildbot for every core listed.

| Console | Default core | Alt | Licence (default) | Risk on iPhone (no JIT) | Notes |
|---|---|---|---|---|---|
| SNES | Snes9x | bsnes (GPLv3) | **Non-commercial** | Low | Spike target |
| Game Boy / Color | Gambatte | SameBoy (MIT) | GPLv2 | Low | |
| GBA | mGBA | — | MPL-2.0 | Low | |
| Genesis / Mega Drive | Genesis Plus GX | PicoDrive | **Non-commercial** | Low | |
| Sega CD | Genesis Plus GX | PicoDrive | **Non-commercial** | Low | Needs user BIOS |
| Sega 32X | PicoDrive | — | MAME (non-commercial) | Medium | SH-2 dynarec unavailable on iOS |
| PlayStation 1 | Beetle PSX (software) | PCSX ReARMed (GPLv2), SwanStation (GPLv3) | GPLv2 | Low–Medium | Needs user BIOS; multi-disc via .m3u + disc control |
| Nintendo 64 | Mupen64Plus-Next | ParaLLEl N64 (GPLv2) | GPLv2 | **High** | No JIT + needs GPU renderer. Dedicated spike on your iPhone |
| Dreamcast | Flycast | — | GPLv2 | Very high | **Phase 2** |

**Licensing consequence (lawyer-readable summary, not legal advice):**
- Non-commercial cores (Snes9x, Genesis Plus GX, PicoDrive) → the app must be **free**, never sold or ad-supported.
- GPL cores bundled in an app you give to friends → you must offer the corresponding source. Simplest compliant posture if you share: **open-source the SupersEmu app under GPLv3**. If it stays personal-only (no distribution), no obligation is triggered.
- Public App Store + GPL is historically contentious (FSF position); TestFlight/ad-hoc for friends is lower-risk. Decision tied to Q3.

---

## 4. Storage and accounts (v0.2)

Replaced by the home-server model: see ADR 0004 and `docs/specs/server.md`. The v0.1 Google Drive
analysis lives on in `docs/specs/google-drive.md` (superseded) for a possible Phase 2 backup target.

## 5. Saves & resume design (data safety first)

- Three kinds, never mixed: **native saves** (SRAM/memory card — most portable), **auto-states** (ring of last N, default 10), **manual slots** (never auto-overwritten).
- Autosave: on exit, on backgrounding, and every 3 min during play (tunable). Local write first, then upload.
- Every state blob is immutable, content-hashed (SHA-256), tagged with `{game hash, core id, core version, app build}`. A tiny pointer file names the "head". Never overwrite; prune old autosaves only after the newer one is confirmed remote.
- **Continue** on device 2: fetch remote head → verify fingerprint matches the local core build → load. Mismatch → explain and fall back to native save / older compatible state.
- Two devices played offline → keep both branches, show "Choose progress" (device, time, screenshot, playtime).
- UI status: Saved locally → Uploading → Synced (never "Synced" before the server confirms).

## 6. Import & organization (behind the scenes)

- Sources: Mac drag-drop, iOS Files/share sheet, cloud `Incoming/` folder.
- Pipeline: safe extract (zip/7z; RAR TBD for licence) → hash → match against **No-Intro/Redump** hash databases (via libretro-database) → header sniffing fallback → filename heuristics → **Review Needed** queue if low confidence.
- Clean display titles ("Chrono Trigger (USA) [!].sfc" → "Chrono Trigger"), keep region/revision as metadata.
- PS1/Sega CD: validate .cue → .bin references, group discs into one tile, auto-generate `.m3u`.
- Artwork: start with **libretro-thumbnails** (box art keyed by No-Intro names, no API key); add **IGDB** or **ScreenScraper** later for descriptions/hero art (needs keys; check terms).
- Never delete originals; quarantine bad files.

## 7. Controllers

- Apple GameController framework (MFi, Xbox, PlayStation, Switch Pro, 8BitDo in X-input/Switch modes) **[Inference: 8BitDo mode behaviour to test on your hardware]**.
- Layers: console default → controller-model override → per-game override. Visual remapping screen.
- iPhone/iPad touch overlays per console; Mac keyboard defaults.

## 8. Milestones (revised from PRD; Dreamcast removed)

Each milestone: spec docs → implementation → tests → demo video/screens → your sign-off.

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M0 — Decision gate + spike** | Done: ADRs, specs, SNES on Mac + iPhone sim, save/load, N64 iOS build check | Merged (#1–#3) |
| **M1 — Server + apps for Chad** | Mac mini server spike, then daemon at boot, Server mode, import on the server, Chad's devices paired by QR; Netflix-style library from the server; download and play locally SNES, GB, GBC, GBA, Genesis; native saves, auto/manual states synced across his devices; LAN + his Tailscale; CLI | Chad plays on his iPhone from the Mac mini library (at home and on cellular), quits, and continues on his Mac |
| **M2 — Smart import + disc systems** | Bulk messy import on the server, hash ID, art, Review Needed; PS1, Sega CD, 32X; multi-disc + .m3u; BIOS checker | 200-file messy import fixture; 3-disc PS1 test set |
| **M3 — Hard consoles + controller polish** | N64, Retrolink/generic HID on Mac, per-game remapping UI | Per-console device test logs |
| **Phase 2 — Friends** | Invites, player accounts, per-user game permissions, private saves, Tailscale sharing, revoke; webhooks, OpenClaw skill, backups, offline UX; Dreamcast if no-JIT speed allows; Apple TV; shaders | A friend accepts an invite, sees only permitted games, and their saves never appear in Chad's account |

**Parallelism (per your preference):** M0 is a single blocking "Wave 0". From M1 on, independent tracks (server + API, player app UI, import pipeline, client sync, controllers, per-console core bring-up) can run as parallel Devin sessions consolidated into one PR per milestone.

## 9. Decisions (v0.2)

Settled: ADR 0004; Tailscale for remote access; one Mac app with Server and Player modes; invite
sign-in (Phase 2) on top of QR device pairing (Phase 1); Phase 1 is Chad only.

Still needed from Chad:
1. Mac mini macOS version and storage size (sets the server's minimum macOS).
2. UI direction answers (`docs/specs/ui-direction.md`).

## 10. What I can and can't verify from my environment

- **Can:** Apple Silicon Mac VM (M4 Pro, macOS 26.6), Xcode 26.6, iPhone/iPad simulators, unit/integration tests, CI.
- **Can't:** physical iPhone/iPad, real Bluetooth controllers, Apple signing (until you enroll and share a team), real-device FPS. Simulator results will always be labelled as simulator results.
