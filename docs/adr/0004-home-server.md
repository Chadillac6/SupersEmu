# ADR 0004: Plex-style home server, local emulation on each device

- Status: Accepted (owner approved, 2026-10-10; phasing revised the same day). Supersedes ADR 0003.
- Context: in ADR 0003 every user connected their own Google Drive. Chad wants a Plex-style setup
  instead: his Mac mini hosts the library, he decides which games each person sees, and fewer than
  10 invited friends sign in with games already there. Each person's saves stay private to them.

## Decision
- **SupersEmu Server runs on Chad's Mac mini.** It owns the master library (import, organisation,
  artwork, disc grouping), the user accounts, per-user game permissions and every user's saves.
- **Games run on the player's own device.** The Mac/iPhone/iPad app downloads the game from the
  server, caches it, and runs the emulator locally through the existing libretro host (ADR 0001).
  The server never runs games and never streams video.
- **Two phases only.** No game-streaming phase.
  - **Phase 1: Chad only.** One admin user (Chad) on his own Mac, iPhone and iPad, so he can use it
    daily and give feedback before anyone else joins.
  - **Phase 2 goal: invited friends.** Fewer than 10 people get their own account through an
    invite. Each sees only the games Chad allows, and their saves and history stay private.
  - Phase 1 is built so Phase 2 only adds features, with no rewrite: every record and API call is
    tied to a user ID, devices sign in with tokens, and every request already passes through a
    permission check (Chad's admin account passes all of them).
- **LAN and remote access in Phase 1** for Chad's devices. On the home network the app finds the
  server via Bonjour. Away from home it uses the same API over Chad's Tailscale network. In Phase 2,
  friends reach it through Tailscale machine sharing (see `docs/specs/server.md`). The server port is
  never opened to the public internet.
- **The server starts at boot** with no one logged in: a launch daemon registered with
  `SMAppService.daemon(plistName:)`.
- **Automation-friendly:** a versioned HTTP API, a `supersemu` CLI and an OpenClaw skill that uses the
  CLI. Bots use scoped tokens and never touch the library folder or database directly.
- Google Drive and iCloud are no longer how users get games. They may come back as **server backup**
  targets in Phase 2.

## Why
- Friends set up nothing. They accept an invite, sign in, and see games. No Drive folders, no OAuth
  "unverified app" screen, no 7-day token expiry, no restricted-scope review.
- One place to organise games (Chad's Mac mini) instead of each user's own Drive.
- Running games on the device keeps controls responsive and works offline once a game is
  downloaded. iPhones can't run N64 games any faster by streaming from a Mac mini that's away from home.
- The client work done so far (libretro host, Snes9x, save design, controllers, touch UI) carries over
  unchanged.

## Consequences
- New component: a Swift server and its admin UI. More code than talking to Drive, but under our control.
- The Mac mini has to be on and online for new downloads and save sync. Play continues offline from
  the device cache, and saves upload later.
- Game files are copied onto users' devices. Chad is distributing his own library to invited friends,
  so this is his call (see legal note in `docs/specs/server.md`).
- Remote access depends on Tailscale. Each friend installs Tailscale once.
- Pairing, tokens and TLS become security-critical code with their own tests.
