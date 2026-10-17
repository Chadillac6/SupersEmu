# `supersemu` CLI

The CLI for Chad, scripts and bots (OpenClaw). It only talks to the server's HTTP API with a token;
it never touches the library folder or database. Source: `Server/Sources/supersemu/`.

```sh
cd Server && swift build -c release && cp "$(swift build -c release --show-bin-path)/supersemu" /usr/local/bin/
```

## Connection and config
Every API command takes `--server URL`, `--token TOKEN` and `--json`. They're resolved in this order:

| | Server | Token |
|---|---|---|
| 1 | `--server` | `--token` |
| 2 | `SUPERSEMU_SERVER` | `SUPERSEMU_TOKEN` |
| 3 | config file `server` | config file `token` (only sent to the server it was saved with: same scheme, host, port and path) |
| 4 | `http://127.0.0.1:8487` | `/Library/Application Support/SupersEmu Server/admin.token` (only for `http://localhost:8487` / `127.0.0.1:8487`, i.e. the server on this Mac mini) |

Config file: `~/.config/supersemu/config.json` (or `$XDG_CONFIG_HOME/supersemu/config.json`;
`SUPERSEMU_CONFIG` overrides the path). `supersemu login` writes it atomically with mode `0600`
in a `0700` directory. The file is only read when a flag or env var doesn't already give both server and token, so a broken config never blocks explicit flags.

```json
{ "server" : "https://games.supersemu.com", "token" : "sek_…" }
```

## Commands
| Command | Needs | What it does |
|---|---|---|
| `login --server URL (--token T \| --token-stdin) [--no-verify]` | any valid token | Checks the token with `GET /v1/me`, then saves the config file. |
| `server status` | any token (health works with none) | Health and who you are. Admins also get the data directory, free disk space and game/review/user/device counts (`GET /v1/admin/status`). |
| `users list` | admin + `users:admin` | `GET /v1/admin/users` |
| `users create NAME` | admin + `users:admin` | Creates a **player** account (Phase 2 groundwork, `POST /v1/admin/users`). |
| `devices list` | admin + `users:admin` | All paired devices, including revoked ones. |
| `devices revoke ID` | admin + `users:admin` | The device's token stops working on its next request. Idempotent. |
| `tokens create --name N --scope S[,S…]` | admin + `users:admin` | Creates a scoped API token. The plaintext token is returned **once**. `--scope` is comma-separated and repeatable. |
| `tokens list` | admin + `users:admin` | Never shows token values or hashes. |
| `tokens revoke ID` | admin + `users:admin` | Stops the token immediately. Idempotent. |

Scopes: `library:read`, `library:write`, `users:admin`, `saves:read`. A token can only create tokens with
scopes it holds itself. Write and admin scopes only work for tokens owned by an admin user, and a
player's token never gets admin rights. Every admin change and its `audit_log` row are written in one transaction. Revoking something that is already revoked keeps the first `revokedAt` and adds no audit row.

## Output
- Text mode prints a table or a short line. `tokens create` prints **only the token** on stdout
  (the notice goes to stderr), so `TOKEN=$(supersemu tokens create …)` works.
- `--json` prints the API's JSON on stdout (pretty, sorted keys, ISO 8601 dates): an array for `list`
  commands, an object otherwise. `server status --json` is `{"health":…,"me":…,"admin":…}`, where
  `me` and `admin` are left out when not available.
- Errors always go to stderr. With `--json` an error is `{"error":"…","status":403,"exitCode":4}`
  (`status` is left out when no HTTP response came back).

## Exit codes
| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | Unexpected error (e.g. config file unreadable or unwritable) |
| 2 | Not found (HTTP 404) |
| 3 | Unauthorized: missing, wrong or revoked token (HTTP 401) |
| 4 | Forbidden: not admin or missing scope (HTTP 403) |
| 5 | Server unreachable |
| 6 | Other request error (HTTP 4xx) |
| 7 | Server error (HTTP 5xx, bad response) |
| 64 | Usage error (bad flags, unknown scope, invalid URL) |

## Adding commands (other tracks)
Add a `FooCommand.swift` (library track: `Library*.swift`) with an `AsyncParsableCommand` group that
uses `@OptionGroup var connection: Connection` and wraps its body in
`CLIOutput.run(json: connection.json) { … }`, then append `Foo.self` to the `subcommands` list in
`main.swift`.
