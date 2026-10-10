# ADR 0001: Native SwiftUI app on a custom thin libretro host

- Status: Accepted (owner approved, 2026-10-10)
- Context: the PRD asks us to compare forking RetroArch with a custom frontend.

## Decision
Build SupersEmu as a native SwiftUI app (iOS, iPadOS, macOS) that hosts existing open-source
libretro cores through a small host layer we own (`Host/SELibretroHost`). Do not fork RetroArch.
Do not write emulators.

## Why
- RetroArch's menu/config model is the UX the PRD tells us to avoid. A fork means carrying a
  large C codebase and rebasing it forever just to hide it.
- The libretro API is small (about 30 functions). A host that implements video, audio, input,
  save RAM and serialize/unserialize is a few hundred lines (see the M0 spike).
- Owning the host means we pin the exact core build on every device, which keeps save states
  portable between a user's Mac, iPhone and iPad.

## Consequences
- We maintain per-core build recipes and pin each core to a commit (git submodules under `Vendor/cores`).
- Cores with special needs (N64 GL/Vulkan, PS1 disc images, BIOS) need extra host features.
- Licences: Snes9x, Genesis Plus GX and PicoDrive are non-commercial, so SupersEmu must stay free.
  Shipping GPL cores means the app is distributed as GPLv3 open source.
