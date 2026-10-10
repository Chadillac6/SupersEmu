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
No cloud sync yet.
