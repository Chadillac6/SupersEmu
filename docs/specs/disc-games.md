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
  Verified by `BIOSStoreTests` with synthetic bytes. `BIOSCenter` fetches through the import track's `APIClient.bios()` and `biosData(sha256:)`. **Unverified:** an end-to-end client sync against a running server; the routes and the store are each tested separately.
- BIOS checker: `supersemu bios status` and the Server mode UI list each system's BIOS as present, missing or wrong-hash.

## Import track: built and verified (server)
Verified by `(cd Server && swift test)` with generated fixtures (`DiscImportTests.swift`, `LibraryCLITests.swift`):
- Cue grouping from a folder or a zip (zip entries stream to disk, so tracks over the 512 MB in-memory limit still import). `FILE` paths resolve relative to the cue, case-insensitively; `\` is accepted.
- Cue game ID byte layout: SHA-256 over the normalized cue bytes followed by each track's SHA-256 as **lowercase hex text**, in cue order (a duplicate `FILE` reference counts once).
- Stored file names stay as the originals, made unique per game (`Disc 2 - Track 01.bin`). When a name changes, the stored cue's `FILE` lines are rewritten. Every `game_files.id` is the SHA-256 of the stored bytes, so a rewritten cue gets a new file ID (the game ID still uses the original cue).
- Roles and disc numbers: `cue` and `disc` rows carry `discNumber` 1...N, including single-disc games (N = 1). The generated `<title>.m3u` (role `m3u`, `discNumber` null) is written only for sets with more than one disc, and lists each disc's cue (or .chd/.iso).
- Inferred sets: the title with the disc marker stripped, all parenthesised tags (region, revision, ...) and the system must match. Disc numbers must be exactly 1...N (and match `of M` when given). Otherwise every disc goes to Review Needed (`Disc set is missing Disc 2`).
- Generic cue names (`game.cue`) take their disc number and region/revision tags from the folder name. Every `of M` must equal the number of discs.
- A user `.m3u` lists discs relative to itself. It overrides inferred grouping and names the game. A missing entry sends it to Review Needed (`Missing disc: <line>`).
- Re-importing a reordered `.m3u` is a duplicate: the game ID uses sorted disc IDs, so the stored order stays as first imported (delete the game and re-import it to change the order).
- A `.bin`/`.img` named after an unreadable `.cue` in the same folder is reported with the cue and left in `Incoming`. It isn't guessed as a cartridge.
- Review Needed entries for discs hold the cue (or .chd/.iso, or the .m3u) under its own SHA-256. They are removed once the complete game imports. `scanIncoming` moves a disc's files out of `Incoming` only after the whole game imports.
- Detection: PS1 when `Sony Computer Entertainment` appears in the first 16 sectors (2048- or 2352-byte) of the first data track. Sega CD when `SEGADISCSYSTEM`/`SEGA SEGASYSTEM` is at byte 0 (2048) or 16 (raw 2352). A loose `.bin` keeps the Genesis cartridge check; a loose Sega CD `.bin` with no cue goes to review.
- 32X: `.32x` (or `.md`/`.bin`) is `sega32x` when the Genesis header at 0x100 names `32X` or `MARS` is at 0x3C0. A `.32x` with neither goes to Review Needed.
- `.chd`: the hunks are compressed, so the bytes aren't header-checked. The system comes from the folder name (`PS1`, `PSX`, `PlayStation`, `Sega CD`, `Mega-CD`, ...); any other folder goes to Review Needed.
- Junk (`.txt`, `.nfo`, images, `.sfv`/`.md5`, `.sub`/`.sbi` sidecars, `.DS_Store`, `._*`) is skipped silently. Patches (`.ips`/`.bps`/`.ups`/`.xdelta`) are reported as unsupported.
- BIOS: `KnownBIOS.all` matches by MD5 (+ size). Only files with a known BIOS size or name are MD5'd. A matching file is stored at `bios/<sha256>/<canonical name>` and listed in `ImportReport.bios`. A file named like a known BIOS but with a different hash is recorded as wrong-hash and is neither stored nor served.
- Routes (`library:read`): `GET /v1/bios`, `GET /v1/bios/status` (`[BIOSStatus]`: present / missing / wrong-hash), and `GET /v1/bios/{sha256}` (Range/ETag/If-Range via the same helper as game files). Client: `APIClient.bios()`, `biosStatus()`, `biosData(sha256:)`, `biosPath(sha256:)`. CLI: `supersemu bios status [--json]`.

Not verified: real PS1/Sega CD dumps and real BIOS files (only synthetic headers and a synthetic hash table are tested). The `KnownBIOS` MD5s are copied from the libretro docs and were not checked against real files. `.sbi` LibCrypt sidecars are skipped instead of being stored with the disc.

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

## Track ownership (Wave 1)
| Track | Owns |
|---|---|
| Import | `Server/Sources/SupersEmuServerCore/Library/*`, `KnownBIOS`, BIOS routes, CLI `bios`/import commands, 200-file messy fixture generator |
| PS1 core | `Vendor/cores/beetle_psx` (or SwanStation), `project.yml` target, `Host/CoreEntry/<core>`, `CoreRegistry` entry, host tests |
| Sega CD + 32X | Genesis Plus GX CD path, `Vendor/cores/picodrive`, its target and CoreEntry, `CoreRegistry`, host tests |
| Multi-disc + BIOS UI | `Host/SELibretroHost.*` disk-control interface, `App/Client/*` BIOS sync, Needs-BIOS state, `PlayerView` disc swap, one tile per multi-disc game |

No ROMs, discs or BIOS files are committed. Tests use generated synthetic fixtures, such as tiny cue/bin sets with fake headers.
