# Disc games, BIOS and Milestone 2 contracts

Milestone 2 adds PS1 (Beetle PSX), Sega CD (Genesis Plus GX) and 32X (PicoDrive), plus messy-library import.
This spec is the Wave 0 contract every Milestone 2 track builds on.

## Game identity for multi-file games
- A single-file game (cartridge ROM, `.chd`, `.iso`) keeps its ID: the SHA-256 of that file.
- A `.cue` game's ID is the SHA-256 of the **normalized cue sheet** (UTF-8, LF line endings, `FILE` names lowercased) plus each referenced track's SHA-256, in cue order.
  Renaming the folder doesn't change the ID; changing any track does.
- A multi-disc game is one library entry. Its ID is the SHA-256 of the sorted per-disc IDs joined by `\n`.
  The server writes a generated `.m3u` (role `m3u`) listing the discs in order. Each disc's files get `discNumber` 1...N.
- `game_files` rows: `role` is `m3u`, `cue`, `disc` (bin/track/chd/iso) or `rom`, and `discNumber` is null for cartridges.
  The client launches by `ClientCache.launchFileURL` order: m3u, then cue, then rom, then disc.

## Disc grouping rules (server importer)
- A `.cue` is grouped with the files its `FILE` lines reference, in the same folder or zip. If any referenced file is missing, the game goes to Review Needed with the reason `Missing track: <name>`.
- Discs belong to the same game when their normalized titles match after stripping `(Disc N)`/`(CD N)`/`Disc N of M`, and they share a system and region tag.
  A user-supplied `.m3u` overrides the inferred grouping.
- `.bin` files not referenced by any cue keep Genesis detection (cartridge header check). Anything else ambiguous goes to Review Needed; never guess.
- System detection for discs: the PS1 license string `Sony Computer Entertainment` in the first data track's system area, and the Sega CD `SEGADISCSYSTEM` / `SEGA SEGASYSTEM` header at sector 0. Otherwise Review Needed.

## BIOS
- The server stores BIOS files under `<data>/bios/<sha256>/<filename>`, never in the repo or app bundle.
- A table of known BIOS files lives in `SupersEmuKit` (`KnownBIOS`): filename, SHA-256 or MD5, system, region and required/optional.
  Example entries: PS1 `scph5500.bin`/`scph5501.bin`/`scph5502.bin`; Sega CD `bios_CD_U.bin`/`bios_CD_E.bin`/`bios_CD_J.bin`.
- The importer recognizes BIOS files by hash, whatever their name, and files them as BIOS instead of games.
- API: `GET /v1/bios` (needs `library:read`) returns `[BIOSFileInfo{id(sha256), filename, system, region, required}]`.
  `GET /v1/bios/{sha256}` serves the bytes with Range/ETag, the same way as game files.
- The client keeps `AppPaths.system` in sync with `/v1/bios`, writing each file under the canonical name the core expects, before launching a disc game.
  If a required BIOS is missing, the detail view shows "Needs <system> BIOS" and the Play button is disabled.
- Client (multi-disc track, built): `BIOSStore` (`SupersEmuKit/BIOSSync.swift`) and `BIOSCenter` (`App/Client/BIOSCenter.swift`).
  Sync runs after every library refresh, when a PS1/Sega CD detail opens, and before a disc game launches. Each file's SHA-256 is checked before it is written (atomically) under its exact canonical name; names that need sanitizing are rejected.
  Synced files are tracked in `System/.supersemu-bios.json`, so only files the app wrote are replaced or removed; user-placed files are left alone. Offline, files already on disk that still match their hash count as installed.
  A system counts as satisfied when any verified BIOS for it is installed. Matching a BIOS region to a game's region is **not implemented**.
  Verified by `BIOSStoreTests` with synthetic bytes. **Unverified:** an end-to-end sync against the real `/v1/bios` routes, which the import track adds in parallel. The client calls `GET /v1/bios` and `GET /v1/bios/{sha256}` through the generic `APIClient.get`/`raw`, so no `APIClient` change is needed.
- BIOS checker: `supersemu bios status` and the Server mode UI list each system's BIOS as present, missing or wrong-hash.

## Host
- `SELibretroHost` honors `retro_system_info.need_fullpath`. When it's true, the host passes only `game.path` and never reads the whole disc into memory.
- Wave 0 (done): `need_fullpath` handling, and the `BIOSFileInfo` model in `SupersEmuKit/Models.swift`.
- Sega CD + 32X (Wave 1, built): `segacd` runs on Genesis Plus GX (`.cue`/`.iso`/`.chd`/`.m3u` by path, BIOS
  `bios_CD_U/E/J.bin` from the system directory; a missing BIOS or unreadable disc fails the load) and `sega32x` on
  PicoDrive (`.32x`). `CoreRegistry` maps Sega CD by console only, since `.cue`/`.chd`/`.iso` are shared with PS1.
  Verified with synthetic discs and a homebrew 32X ROM; real Sega CD discs and CHD images are not yet verified
  (see `core-matrix.md`).
- Multi-disc track: the host implements `RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE` (and `_EXT`) and exposes `diskCount`, `currentDisk` and `insertDisk(_:)` to Swift.
  The player shows "Swap disc" for games with more than one disc.
  Built: the host stores the legacy or EXT callbacks (a NULL interface clears them; they are reset on load and shutdown) and reports interface version 1.
  `insertDisk(_:error:)` opens the tray (unless it is already open), sets the index, and always closes the tray again, so a failed swap leaves the previous disc running. Labels come from `get_image_label` (EXT only).
  Verified by `Tests/HostTests/SEDiskControlTests.mm` against a stub three-disc core (`SELibretroHostRegisterCore` in `Host/SELibretroHost+Testing.h`).
  **Unverified:** swapping with a real disc core (PS1/Sega CD cores land in parallel tracks).
- Player: the "Swap disc" button (Command-D, or L + R + Select on a controller) pauses the game and opens a "Disc N of M" picker.
  In the picker, up/down or the d-pad moves, Return / Start / the bottom face button inserts, and Esc / Select / the right face button cancels. Number keys 1-9 pick a disc directly.
  `SUPERSEMU_DEBUG_DISC_COUNT=N` (Debug builds only) fakes an N-disc game so the UI can be captured without a disc core.
- Library: a multi-disc game is one tile (one `GameSummary`). Its detail view shows "N discs · total size". The file-list downloader fetches and verifies every file; `ClientCacheTests.testDownloadsEveryFileOfSyntheticMultiDiscGame` (m3u + 2 discs) launches from the `.m3u`.
- Save states and SRAM stay per game ID, shared across discs (for PS1, memory card 1 is per game).
- PS1 (Beetle PSX, built): `need_fullpath` is true, so the host passes the `.cue`/`.chd`/`.m3u`/`.pbp` path and the core opens the tracks beside it.
  The core looks for `scph5500.bin`/`scph5501.bin`/`scph5502.bin` (by disc region) in `AppPaths.system`; with none present it boots its bundled OpenBIOS instead of failing.
  So "Needs PlayStation BIOS" is a frontend policy, not something the core enforces. Commercial-game compatibility on OpenBIOS is unverified.

## Track ownership (Wave 1)
| Track | Owns |
|---|---|
| Import | `Server/Sources/SupersEmuServerCore/Library/*`, `KnownBIOS`, BIOS routes, CLI `bios`/import commands, 200-file messy fixture generator |
| PS1 core | `Vendor/cores/beetle_psx` (or SwanStation), `project.yml` target, `Host/CoreEntry/<core>`, `CoreRegistry` entry, host tests |
| Sega CD + 32X | Genesis Plus GX CD path, `Vendor/cores/picodrive`, its target and CoreEntry, `CoreRegistry`, host tests |
| Multi-disc + BIOS UI | `Host/SELibretroHost.*` disk-control interface, `App/Client/*` BIOS sync, Needs-BIOS state, `PlayerView` disc swap, one tile per multi-disc game |

No ROMs, discs or BIOS files are committed. Tests use generated synthetic fixtures, such as tiny cue/bin sets with fake headers.
