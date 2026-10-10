# SupersEmu — Architecture Options & Spec-Driven Plan (v0.1, for owner review)

Status: **DRAFT — awaiting owner decisions (Section 9).** No code written yet. Builds on `RETRO_GAMING_PLATFORM_DEVIN_PRD.md`.

Legend: **[Verified]** = checked today against a primary source. **[Inference]** = my engineering judgement, to be proven in the M0 spike.

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
 ├─ Sync engine  → CloudProvider protocol       GoogleDriveProvider | iCloudProvider
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

## 4. Cloud storage — the key product decision

### What I verified about Google Drive today
- `drive.file` (non-sensitive, easy) only grants access to files **the app created** or the user **explicitly picked** in Google Picker. **[Verified]**
- On iOS/macOS, Google Picker opens in the **system browser**, not inside the app, and "only the `drive.file` scope is permitted" for that flow. **[Verified]**
- Full `drive` scope is **restricted**: needs Google verification + security assessment for a public app; "Backup and sync" apps are an allowed category. **[Verified]**
- An OAuth app left in **Testing** mode has tokens that **expire every 7 days** → user re-signs in weekly. **[Verified]** For personal use we'd publish the OAuth app to "In production / unverified" (warning screen, ≤100 users) — behaviour to be confirmed in M0. **[Inference]**
- Drive push notifications need a public HTTPS webhook; phones can't receive them → we sync on launch/foreground/periodic. **[PRD, cited]**

### Options

| | G1. Drive, `drive.file` | G2. Drive, full `drive` scope | G3. **iCloud Drive first**, Drive later |
|---|---|---|---|
| Sign-in | Google sign-in | Google sign-in + "unverified app" warning | **None** — uses the Apple ID already on the device |
| Drop ROMs into a folder from a browser / Drive app | ❌ app can't see files it didn't create unless picked | ✅ | ✅ via Files app / Finder (`iCloud Drive/SupersEmu/Incoming`) |
| Background sync | We implement it; iOS limits it | Same | **OS does it** (even when app closed) |
| Friends | Easy (non-sensitive scope) | Hard (verification) | Easy if they're on Apple devices |
| Storage cost | 15 GB free / Google One | Same | 5 GB free / iCloud+ (50 GB–2 TB) |
| Requires Apple Developer Program | No (but you need it anyway for devices) | No | **Yes** (iCloud entitlement) |
| Build effort | Medium | Medium | **Low** |

**My recommendation:** keep the `CloudProvider` abstraction either way. If your ROM library already lives in Google Drive or you want non-Apple portability, pick **G2 for personal use** (full scope, unverified prod app) and add G1 mode for friends later. If not, **G3 (iCloud) is the more "just works" option** and gets cross-device sync working sooner.

---

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
| **M0 — Decision gate + spike** | Repo, ADRs, specs; SwiftUI → libretro host → SNES homebrew plays on Mac + iPhone sim; save/load state; return to library. Second spike: N64 test ROM FPS. Cloud auth spike for chosen provider | You approve architecture; spike video; measured numbers |
| **M1 — Local library, "easy" consoles** | Netflix-style home/shelves/detail/search; local import; SNES, GB, GBC, GBA, Genesis; native saves + manual states; controller auto-map; Mac + iPhone + iPad | You play a game on your iPhone from a TestFlight/dev build |
| **M2 — Cloud library + cross-device saves** | Provider, manifest, upload/download queue, autosave ring, Continue on another device, conflict branches | Quit on Mac → Continue on iPhone; airplane-mode + conflict tests |
| **M3 — Smart import + disc systems** | Bulk messy import, hash ID, art, Review Needed; PS1 + Sega CD multi-disc + .m3u; BIOS checker | 200-file messy import fixture; 3-disc PS1 test set |
| **M4 — Hard consoles + controller polish** | N64, 32X; per-game remapping UI; touch overlays | Per-console device test logs |
| **M5 — Polish + friend-ready** | Visual polish, accessibility, onboarding, account isolation, docs | Someone new onboards with no help |
| **Phase 2** | Dreamcast (only if no-JIT perf is acceptable), second cloud provider, Apple TV, shaders | — |

**Parallelism (per your preference):** M0 is a single blocking "Wave 0". From M1 on, independent tracks (UI shell, import pipeline, sync engine, controllers, per-console core bring-up) can run as parallel Devin sessions consolidated into one PR per milestone.

## 9. Decisions needed from you

1. **Architecture:** approve B (custom libretro host + SwiftUI)?
2. **Cloud for MVP:** G2 Google Drive full-scope / G1 Google Drive `drive.file` / G3 iCloud first?
3. **Audience:** just you (private repo), you + friends (TestFlight, open-source GPLv3), or public App Store eventually?
4. **Apple Developer Program:** enrolled? ($99/yr; needed for TestFlight, iCloud, and installs that don't expire every 7 days.)
5. **Repo:** please create an empty private repo (e.g. `Chadillac6/SupersEmu`) and add it to the Devin GitHub app — I can't create repos.
6. **Your hardware:** which iPhone / iPad / Mac models, and which controller(s) (8BitDo SN30 Pro? which mode?).
7. **Library size:** roughly how many games, and how many PS1 discs? (Drives storage plan and scan design.)
8. **Minimum OS:** OK with iOS/iPadOS 18+ and macOS 15+ (my default)?
9. **Name:** keep "SupersEmu"?

## 10. What I can and can't verify from my environment

- **Can:** Apple Silicon Mac VM (M4 Pro, macOS 26.6), Xcode 26.6, iPhone/iPad simulators, unit/integration tests, CI.
- **Can't:** physical iPhone/iPad, real Bluetooth controllers, Apple signing (until you enroll and share a team), real-device FPS. Simulator results will always be labelled as simulator results.
