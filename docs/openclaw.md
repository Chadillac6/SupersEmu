# Driving SupersEmu Server from OpenClaw (or any agent/script)

Bots use the `supersemu` CLI with their own **scoped token**. They never read or write the server's
data folder or database directly, so every action goes through the same auth, permission checks and
audit log as the apps. CLI reference: [`specs/cli.md`](specs/cli.md).

This page only covers the CLI and environment variables. How you install a skill or give a tool to
OpenClaw is OpenClaw's own configuration (see its docs); from SupersEmu's point of view it is just
a process running `supersemu` commands.

## 1. Create a token for the bot (Chad, once)
On the Mac mini (the CLI uses the local `admin.token` there):

```sh
supersemu tokens create --name openclaw --scope library:read,library:write
# prints only the token (sek_…) on stdout; it is never shown again
```

Pick the smallest scopes that cover the job:

| Scope | Allows |
|---|---|
| `library:read` | List and read games |
| `library:write` | Import and organise games (library commands) |
| `saves:read` | Read save metadata |
| `users:admin` | Users, devices and tokens (`users`, `devices`, `tokens`, admin `server status`) |

`library:write` and `users:admin` only work for tokens owned by an admin (Chad). No scope can delete
game files or overwrite a user's save.

## 2. Give the token to the bot
Either set environment variables for the process that runs the CLI:

```sh
export SUPERSEMU_SERVER=https://macmini.<tailnet>.ts.net:8487   # or https://127.0.0.1:8487 on the Mac mini (pins tls/server.cer)
export SUPERSEMU_TOKEN=sek_…
```

or save them once for the bot's OS user (the token is read from stdin to keep it out of shell history):

```sh
printf %s "$TOKEN" | supersemu login --server https://macmini.<tailnet>.ts.net:8487 --token-stdin
# writes ~/.config/supersemu/config.json with mode 0600
```

## 3. Run commands
Always pass `--json` and check the exit code:

```sh
supersemu server status --json          # health + who am I (+ disk/counts with users:admin)
supersemu tokens list --json            # needs users:admin
supersemu devices list --json           # needs users:admin
supersemu devices revoke <device-id> --json
```

Library commands (`supersemu library …`) are added by the library track and follow the same
flags, JSON output and exit codes.

| Exit code | What the bot should do |
|---|---|
| 0 | Parse stdout as JSON |
| 3 | Token missing, wrong or revoked: ask Chad for a new one |
| 4 | Not allowed (scope): don't retry; report it |
| 5 | Server unreachable: retry later (Mac mini asleep, Tailscale down) |
| 2, 6, 64 | Bad ID or arguments: fix the command |
| 7, 1 | Server/unexpected error: report stderr |

With `--json`, errors are on stderr as `{"error":"…","status":403,"exitCode":4}`.

## 4. Revoke
```sh
supersemu tokens list
supersemu tokens revoke <token-id>     # the bot's next request gets exit code 3
```
