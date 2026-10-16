# Cheats (Game Genie)

Status: built for SNES (Snes9x) and Genesis / Mega Drive (Genesis Plus GX). Sega CD, 32X (PicoDrive), Pro Action
Replay and other systems are not supported yet.

## What the player gets
- Game details → **Cheats** (Shift-Command-C on the Mac): saved codes for that exact ROM, each with an on/off toggle.
  Add one code with live validation, or **Paste Several Codes** (one per line; other words on the line become the
  name, blank names become "Cheat N"), review what was understood, untick any and save. New cheats start on.
- In game: **Cheats** in the in-game menu or the toolbar (Shift-Command-C). The game pauses; d-pad/arrows move,
  A/Start/Return toggles, B/Select/Esc closes. Each row says Applied, Sent, Rejected by core, Invalid code or Off.
- A **Cheats on** badge in the player toolbar while any code is active. Saves made with cheats on sync as usual.

## Where things live
| Piece | File |
| --- | --- |
| Model, merge rules, code parser | `Server/Sources/SupersEmuKit/Cheats.swift` |
| Device storage + sync queue | `Server/Sources/SupersEmuKit/CheatsSync.swift` (`AppPaths.cheats/<gameID>.json`, `sync-state.json`) |
| Server table / routes | `CheatMigrations.swift` (`v9_cheats`), `CheatStore.swift`, `CheatRoutes.swift` |
| Host | `SELibretroHost applyCheats(_:)`, `SECoreAPI.cheat_reset/cheat_set/cheat_count` |
| Core shims | `Host/CoreEntry/snes9x/se_cheats.cpp`, `Host/CoreEntry/genesis_plus_gx/se_libretro.c` |
| App | `App/Cheats/*`, `GameSession` (cheats section), `PlayerView`, `GameDetailView` |

Cheats are keyed by the ROM's SHA-256 game ID, never the filename. They are fully separate from saves: no
SaveRAM or save-state format changed, and cheat sync has its own files, queue, table and routes.

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
cheat count before and after each call. That is how "Applied" is told apart from "Rejected by core" (the cores
themselves report nothing). Strings with `+`, empty strings and strings of 64+ characters never reach the core.
The host also resets cheats right after `load_game` and before `unload_game`, so codes can't carry over to
another game.

## Verified vs not
- Verified by host tests (`Tests/HostTests/SECheatTests.mm`): reset-then-set order, per-code outcomes, clearing,
  no carry-over, real Snes9x and Genesis Plus GX accepting valid Game Genie codes and rejecting malformed ones on
  the synthetic fixtures.
- SNES decoding is checked against vectors produced by Snes9x's own `S9xGameGenieToRaw`.
- Not verified: the visible effect of a code in a commercial game (no commercial ROMs in tests).
- Every SNES Game Genie character is also in the Genesis alphabet, so an SNES code pasted into a Genesis game
  parses as a (different) Genesis code. The reverse is detected and labeled.
