# SupersEmu Server (Mac mini)

Status: **Draft for owner review.** [Verified] = checked against vendor docs on 2026-10-10.
[Inference] = design judgement, to be proven in the server spike.

## Requirements (from Chad)
- Mac mini (new, Apple silicon) is the server. Chad controls which games exist and who sees them.
- Fewer than 10 invited users. Optimise for simplicity, not scale.
- Works on the home network and remotely.
- Starts automatically when the Mac mini boots.
- Each user's saves, favourites and history are private to them.
- Easy to drive from CLIs and bots such as OpenClaw.

## Components
```
Mac mini
 ├─ supersemu-server   launch daemon (headless): HTTP API, SQLite (GRDB), library + user data
 ├─ SupersEmu.app      "Server" admin mode: status, import, review queue, users, permissions, tokens
 └─ supersemu (CLI)    talks to the API with a token; used by Chad, scripts and OpenClaw

Player devices (Mac, iPhone, iPad)
 └─ SupersEmu.app      sign in, browse permitted games, download/cache, play locally, sync saves
```
- The server is Swift (proposed: Vapor or Hummingbird + GRDB) so library, metadata and save types
  are shared with the client in one Swift package. [Inference]
- One Mac app with Server and Player modes rather than two apps. The daemon ships inside the app
  bundle in `Contents/Library/LaunchDaemons` and is registered with
  `SMAppService.daemon(plistName:)` [Verified: Apple ServiceManagement docs], so it starts at
  boot and runs with no one logged in. [Inference: needs an admin approval once in System Settings, to
  be confirmed on macOS 15+.]

## Data on the server
```
/Library/Application Support/SupersEmu Server/
 ├─ library.sqlite          games, files, hashes, metadata, artwork refs, disc groups, permissions
 ├─ games/<sha256>/…        imported game files (content-addressed, originals never modified)
 ├─ artwork/…
 └─ users/<user-id>/
     ├─ saves/<game>/…      native saves, auto states, manual states (immutable, content-hashed)
     └─ profile.json        favourites, history, per-user settings
```
- Import sources: a watched `Incoming` folder on the Mac mini, drag-drop in the admin UI, and
  `supersemu library import <path>`. The pipeline in `import-and-library.md` now runs on the server.
- Chad publishes games and assigns them per user or per group ("Everyone", "Kids", …). A user only
  ever sees games they're allowed.

## Accounts and sign-in
1. Chad creates an invite (admin UI or `supersemu users invite <name>`). The invite is a one-time
   link/QR code containing the server's LAN name, its Tailscale name and the server certificate fingerprint.
2. The friend opens it in SupersEmu, picks a display name, and the server issues a **per-device
   token** stored in the device Keychain. No password and no Google/Apple account needed.
3. Adding another device: scan a QR from an already signed-in device, or Chad issues a new invite.
4. Chad can revoke a device or a whole user. Revoked tokens stop working immediately.
- Roles: `admin` (Chad), `player`. Bot tokens are separate and scoped (below).
- [Open] Optional "Sign in with Apple" later instead of invite-only. Not needed for <10 users.

## Network access
| Where | How the app reaches the server |
|---|---|
| Home Wi-Fi | Bonjour discovery (`_supersemu._tcp`), direct HTTPS on the LAN |
| Away | Same API over Tailscale (`<macmini>.<tailnet>.ts.net`) |

- **Tailscale** [Verified: tailscale.com/pricing and kb/1084/sharing, 2026-10-10]: the Personal plan
  is free with up to 6 users. Machine sharing is available on all plans and gives an outside user
  access to only the shared machine. So friends use their own free Tailscale account and Chad
  shares just the Mac mini with them. [Inference: shared-in users don't count towards the 6 users,
  to confirm.]
- No port forwarding and no public exposure. Fallback if Tailscale is a non-starter: a Cloudflare
  Tunnel with the same token auth (more setup, public hostname).
- TLS: the server presents its own certificate and the app pins its fingerprint from the invite, so the
  LAN and Tailscale paths use the same trust check. [Inference] iOS needs the Local Network
  permission prompt for Bonjour (`NSLocalNetworkUsageDescription`, `NSBonjourServices`).
- [Inference] The Mac App Store Tailscale app runs only while a user is logged in. For boot-time remote
  access the Mac mini should use Tailscale's standalone/daemon install. Verify in the server spike.

## API (v1, JSON over HTTPS)
```
POST /v1/pair                       invite code -> device token
GET  /v1/library                    games this user may see (+ ETag for cheap refresh)
GET  /v1/games/{id}                 metadata, discs, artwork
GET  /v1/games/{id}/files/{file}    download (HTTP Range for resume)
GET  /v1/saves/{game}               this user's save heads + history
PUT  /v1/saves/{game}/{rev}         upload immutable revision (parent rev required)
GET  /v1/events                     server-sent events: library.updated, save.synced, …
admin: /v1/admin/users, /invites, /permissions, /library/import, /library/publish, /tokens
```
- Saves: same model as `save-and-resume.md`. The server stores immutable revisions per user. An upload
  whose parent isn't the current head becomes a branch, never an overwrite. "Synced" shows only
  after the server confirms.
- Downloads: whole files to the device cache with resumable Range requests. PS1 discs are large, so
  the cache UI shows sizes and lets users remove downloaded games.

## CLI and bots (OpenClaw)
```
supersemu server status
supersemu library scan | import <path> | publish <game> --to <user|group>
supersemu users list | invite <name> | revoke <user>
supersemu tokens create --scope library:read,library:write --name openclaw
supersemu backups run
```
- OpenClaw [Verified: openclaw.ai, github.com/openclaw/openclaw] is a self-hosted agent gateway with
  a CLI and a skills/plugin system. We ship a SupersEmu skill that calls the `supersemu` CLI, so a
  message like "add the games in Downloads and give them to Alex" works through the API.
- Bot tokens are scoped (`library:read`, `library:write`, `users:admin`, `saves:read`), every call is
  audit-logged, writes are idempotent, and no scope can delete game files or overwrite a user's save.
- Webhooks (Phase 2): `game.imported`, `library.updated`, `user.invited`, `save.synced`,
  `server.health_changed`.

## Phases
| Phase | Server scope |
|---|---|
| **1** | Daemon at boot, admin mode, import/organise on server, invites + device tokens, per-user permissions, LAN + Tailscale access, downloads/cache, per-user save sync, CLI + scoped tokens |
| **2** | Polish: webhooks, OpenClaw skill on ClawHub, server backups (Time Machine / Google Drive / iCloud), health and "server offline" UX, bandwidth limits, multi-server |

## Legal note (not legal advice)
The server only ever holds files Chad imports. Sharing copies of games with friends is Chad's
responsibility. SupersEmu ships no games or BIOS files.

## Spike before M2 (needs the new Mac mini)
- Daemon starts at boot with no user logged in. API reachable on LAN and over Tailscale from an iPhone on cellular.
- Pair an iPhone from an invite QR. Revoke it and confirm the next request fails.
- Download a 700 MB file over Tailscale with a resume after interruption.
