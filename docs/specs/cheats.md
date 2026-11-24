# Cheats (Game Genie)

Preinstalled Game Genie codes cover known SNES, Genesis / Mega Drive, Game Boy, Game Boy Color and 32X ROMs.
Manual entry also supports other code formats and systems; see `CheatCodec.formats(for:)` for the full list.

## What the player gets
- Game details → **Cheats** (Shift-Command-C on the Mac): saved codes for that exact ROM, each with an on/off toggle.
  Add one code with live validation, or **Paste Several Codes** (one per line; other words on the line become the
  name, blank names become "Cheat N"), review what was understood, untick any and save. New cheats start on.
- In game: **Cheats** in the in-game menu (or Shift-Command-C). The game pauses; d-pad/arrows move,
  A/Start/Return toggles, B/Select/Esc closes. Preinstalled suggestions are listed separately from **My cheats**
  and start off. Their labels distinguish an exact ROM catalog match from a compare-byte match on your ROM.
  The picker reports whether each enabled code was accepted, sent without core confirmation, or rejected.
- A **Cheats on** badge in the player toolbar while the core accepted or was sent at least one enabled code.
  Saves made with cheats on sync as usual.

## Where things live
| Piece | File |
| --- | --- |
| Model, merge rules, code parser | `Server/Sources/SupersEmuKit/Cheats.swift` |
| Bundled catalog and revision resolver | `Server/Sources/SupersEmuKit/BundledCheatCatalog.swift`, `App/Cheats/BundledCheatLibrary.swift` |
| Device storage + sync queue | `Server/Sources/SupersEmuKit/CheatsSync.swift` (`AppPaths.cheats/<gameID>.json`, `sync-state.json`) |
| Server table / routes | `CheatMigrations.swift` (`v9_cheats`), `CheatStore.swift`, `CheatRoutes.swift` |
| Host | `SELibretroHost applyCheats(_:)`, `SECoreAPI.cheat_reset/cheat_set/cheat_count` |
| Core shims | `Host/CoreEntry/snes9x/se_cheats.cpp`, `Host/CoreEntry/genesis_plus_gx/se_libretro.c` |
| App | `App/Cheats/*`, `GameSession` (cheats section), `PlayerView`, `GameDetailView` |

Cheats are keyed by the ROM's SHA-256 game ID, never the filename. They are fully separate from saves: no
SaveRAM or save-state format changed, and cheat sync has its own files, queue, table and routes.
Bundled selections use stable IDs by ROM and code group and travel through the same sync as manual cheats.
Only the selection is saved; the app resolves the actual codes from its catalog again before using them.

## Matching preinstalled codes

The app resolves the catalog against the local ROM after download or when an existing download is first played.
It uses a No-Intro SHA-1 match, stripping a SNES copier header or deinterleaving Sega SMD data if needed.
Files larger than the catalog's cartridge size limit for the system are skipped before hashing.
Catalog entries are joined to unambiguous DAT names at generation time, never to a player's editable title.
No ROM data is shipped with the catalog or sent to a service to match cheats.

If the catalog knows a GB/GBC ROM's revision family but has no exact cheat entry, the app tries other revisions
in catalog order for each effect. Every component must have a compare byte that matches in a mapper-eligible
ROM bank. Six-digit GB/GBC and SNES, Genesis and 32X Game Genie codes do not carry a compare byte and are
never used as fallbacks. Unknown ROM hashes receive no suggestions; manual entry still works. A match is
not proof of a gameplay effect.

To rebuild the compact catalog, check out the libretro-database revision in
`App/Resources/GameGenieCatalog-Attribution.txt`, then run
`python3 scripts/generate-game-genie-catalog.py /path/to/libretro-database`. That notice also links the source
and the CC BY-SA 4.0 license for the derived data.

## API
- `GET /v1/cheats?since=<revision>`: every change (tombstones included) for the caller's user newer than
  `since`, plus the user's head `revision`. Players don't see cheats for games they've hidden. The head comes from
  a per-user counter (`cheat_revisions`), so it never goes backwards when old tombstones are pruned.
- `GET /v1/cheats/:game`: the game's live cheats.
- `PUT /v1/cheats/:game/:id` (paired devices only): body is a `CheatRecord`. The server merges it field by field
  and returns the result; replaying the same body doesn't create a new revision.

Clients that get 404 from `/v1/cheats` (an older server) keep cheats on the device and say so. Unknown JSON fields
are ignored and unknown `format` values decode as `unknown`.

## Merge rules
Name, code and on/off each keep their newest edit (timestamps are whole seconds; ties go to the upload the server
saw last). A device stamps each change at least one second after the change it follows, so an edit right after a
delete brings the cheat back and a delete right after an edit sticks. A delete is a tombstone: it beats edits made before it and loses to edits made after it. The server
drops tombstones after 90 days. Sign-out drops the queue so the next account never receives this account's edits.

## Applying codes
Launch only reads the device's copy. After the game loads, after loading any state, after a restart and after
every toggle, the host calls `cheat_reset` and then `cheat_set` once per enabled valid code, comparing the core's
cheat count before and after each call when the core exposes one. A compound catalog cheat sends each
component separately. If the core rejects any component, the player removes that group and reapplies the
remaining cheats. The host rejects literal `+`, empty strings and codes over 240 bytes. It also resets cheats
right after `load_game` and before `unload_game`, so codes can't carry over to another game.

## Verified vs not
- Verified by host tests (`Tests/HostTests/SECheatTests.mm`): reset-then-set order, per-code outcomes, clearing,
  no carry-over, real Snes9x and Genesis Plus GX accepting valid Game Genie codes and rejecting malformed ones on
  the synthetic fixtures.
- SNES decoding is checked against vectors produced by Snes9x's own `S9xGameGenieToRaw`.
- `BundledCheatCatalogTests.swift` covers compound parsing, bank-aware comparison, revision fallback and
  headered ROM matches. The Gambatte host suite includes a synthetic cartridge whose SRAM output changes
  under a compound Game Genie cheat and returns to normal when cleared.
- Not verified: the visible effect of a code in a commercial game (no commercial ROMs in tests).
- Every SNES Game Genie character is also in the Genesis alphabet, so an SNES code pasted into a Genesis game
  parses as a (different) Genesis code. The reverse is detected and labeled.
