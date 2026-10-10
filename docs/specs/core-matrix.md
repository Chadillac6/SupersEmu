# Console to core matrix

| Console | Default core | Licence | iOS arm64 build exists | Status |
|---|---|---|---|---|
| SNES | Snes9x | Non-commercial | Yes | **Running in M0 spike** (macOS tests + iOS simulator build) |
| Game Boy / Color | Gambatte | GPLv2 | Yes | Planned M1 |
| Game Boy Advance | mGBA | MPL 2.0 | Yes | Planned M1 |
| Genesis / Mega Drive | Genesis Plus GX | Non-commercial | Yes | Planned M1 |
| Sega CD | Genesis Plus GX | Non-commercial | Yes | Planned M2; needs user BIOS |
| Sega 32X | PicoDrive | MAME (non-commercial) | Yes | Planned M2 |
| PlayStation | Beetle PSX (mednafen_psx) | GPLv2 | Yes | Planned M2; needs user BIOS, disc/.m3u support |
| Nintendo 64 | Mupen64Plus-Next | GPLv2 | Yes | **Risk**: builds for iOS arm64 (interpreter, no JIT); needs GPU rendering in host + device speed test |
| Dreamcast | Flycast | GPLv2 | Yes | Phase 2 |

"iOS arm64 build exists" means a build is published on the libretro buildbot; only Snes9x has
been built and run by us so far. Alternates: bsnes (SNES accuracy), SameBoy (GB), SwanStation /
PCSX ReARMed (PS1), ParaLLEl N64.
