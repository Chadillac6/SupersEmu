# SupersEmu Server (Swift package)

Phase 1 home server for Chad's Mac mini. See `docs/specs/server.md` and `docs/adr/0004-home-server.md`.

| Target | What it is |
|---|---|
| `SupersEmuKit` | Shared API models + `APIClient`. Used by the apps (iOS/macOS), the CLI and the server. No dependencies. |
| `SupersEmuServerCore` | Hummingbird 2 router, GRDB/SQLite schema, users, device + API tokens, permission checks. |
| `supersemu-server` | Daemon executable: `run --data-dir --port 8487`, `bootstrap --name Chad`. |
| `supersemu` | CLI for Chad, scripts and OpenClaw: `login`, `server status`, `users`, `devices`, `tokens` (more per track). See `docs/specs/cli.md` and `docs/openclaw.md`. |

```sh
cd Server && swift test
swift run supersemu-server bootstrap --data-dir /tmp/se && swift run supersemu-server run --data-dir /tmp/se
swift run supersemu server status --token "$(cat /tmp/se/admin.token)"
```

## Rules every track follows

- Every authenticated route is registered on the `authed` group (behind `TokenAuthMiddleware`), calls `context.caller()`, then `require(scope)` / `requireAdmin()`.
- Anything listing or serving games goes through `Permissions` (admin sees all in Phase 1; players see granted games in Phase 2).
- Per-user data lives under `ServerPaths.userDirectory(userID)`; rows always carry `user_id`.
- New schema = a new migration in your own file, appended to `ServerMigrations.registerTrackMigrations`.
- Shared DTOs go in `SupersEmuKit/Models.swift` (additive only) or your own file in `SupersEmuKit`.

## Track ownership (Wave 1)

| Track | Owns |
|---|---|
| Server library | `LibraryRoutes.swift`, `AdminLibraryRoutes.swift`, `SupersEmuServerCore/Library/*` |
| CLI + admin | `AdminUserRoutes.swift`, `Sources/supersemu/*` |
| Pairing + network + daemon | `PairingRoutes.swift`, `SupersEmuServerCore/Network/*`, `Resources/*.plist`, Server mode in app |
| Save sync | `SaveRoutes.swift`, `SupersEmuServerCore/Saves/*`, `SupersEmuKit/Saves*.swift`, app save sync |
