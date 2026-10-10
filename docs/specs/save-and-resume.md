# Save and resume

## Save kinds
| Kind | Written when | Overwritten? |
|---|---|---|
| Native save (SRAM, memory card) | On exit, background, every autosave | Yes, but previous revision kept |
| Auto state | Every 30 s, on exit, on app background | Rolling history (keep last N) |
| Manual state | User taps Save | Never automatically |

## Metadata per state (M1)
game SHA-256, core id + version, app build, platform/arch, SHA-256 of state, device id,
created-at, parent revision.

## Resume
Opening a game with an auto state resumes it ("Continue" badge in the library). A state is only
offered when its core version matches the bundled core.

## Sync states shown to the user
Saved on this device, Waiting to upload, Uploading, Synced, Conflict, Failed (retrying).

## Conflicts
Never pick a winner silently. If two devices advanced the same game, keep both as branches and
ask the user which to continue.

## Implemented in M0 spike
Local auto state (30 s, exit, background), resume on launch, one manual slot, SRAM flush.

## Sync target (ADR 0004)
Saves sync to the user's own area on the SupersEmu Server (`docs/specs/server.md`), not to Google
Drive. Revisions, branches and statuses above are unchanged.

## Implemented in M1 (saves track)
### Server (`SupersEmuServerCore/Saves`, `SaveRoutes.swift`)
- `GET /v1/saves/{game}`: the caller's own revisions only (oldest first), `isHead` per (kind, slot) line,
  `deviceName` of the uploader. Requires `saves:read`; players only see games `Permissions` lets them see.
- `PUT /v1/saves/{game}/{kind}?slot&parent&core&coreVersion[&sha256]`: raw body, paired devices only (API
  tokens can't upload). Every upload is a new immutable revision at `users/<userID>/saves/<game>/<rev>`;
  nothing is ever overwritten. If `parent` isn't the line's current head the revision is still stored and the
  response says `branched=true`. Re-sending the same bytes on the same parent returns the existing revision
  (safe retries). Limit 64 MB (413); optional `sha256` must match (400); `core`/`coreVersion` at most 128
  chars. `native`/`auto` have no slot. `branch=1` keeps the upload only as a branch copy: listed and
  downloadable, but never the line head.
- `GET /v1/saves/{game}/revisions/{rev}`: the bytes, re-hashed before serving (corrupt files are a 500,
  never served).
- Retention: the last 10 `auto` revisions per game are kept; older ones are deleted unless they're a line
  head or the revision a device last uploaded/downloaded for that line (`save_device_bases`), so a device
  that was away can still prove the head descends from its copy. `native` and `manual` revisions are never
  pruned.
- Users can never list or download another user's saves (a foreign revision id is a 404).

### Client (`SupersEmuKit/SavesSync.swift` `SaveSyncEngine`, `App/Sync`)
- Local-only when no server is signed in: `SaveSync.shared.provider` returns no client, nothing is
  queued and launches behave exactly like M0. The sign-in track sets the provider; for development,
  `SUPERSEMU_SERVER_URL` + `SUPERSEMU_SERVER_TOKEN` (a device token) turn sync on.
- After SRAM, the auto state or slot 1 is written locally, a copy is queued on disk
  (`Application Support/SupersEmu/Sync/pending`) and uploaded. Offline uploads stay queued across
  relaunches and retry on the next save, launch or app start. Newer copies of a line supersede queued
  older ones.
- Before a game starts the app fetches the server's heads: SRAM before the core loads, states after
  (they need the core version). A newer compatible revision is downloaded when this device has nothing
  newer. States from another core id/version are never downloaded or loaded (same rule as local
  incompatible states); SRAM is portable.
- Conflicts: if this device has progress the server doesn't, or the server moved on from a different
  branch (or its base is no longer on the server), the game waits on "A newer save from <device> is
  available" and no frames run. This device's copy is uploaded as a branch copy (`branch=1`) first, so
  both stay on the server without disturbing other devices. *Use Newer Save* downloads the other device's
  revision; *Keep This Device's* uploads this copy on top of it so it becomes the newest. Leaving without
  choosing changes nothing and asks again next launch.

Untested in M1 so far: real two-device continuity over the network (manager), very large saves on cellular.
