# Boot-time launch daemon

`com.chadillac6.supersemu.server.plist` is registered with `SMAppService.daemon(plistName:)` from the Mac
app's Server mode (Window › Server Mode, ⇧⌘S, or launch with `--server-mode`).

- `scripts/embed-server-daemon.sh` (Xcode build phase, macOS only) builds `supersemu-server` with SwiftPM and
  copies it to `SupersEmu.app/Contents/MacOS/` and this plist to `SupersEmu.app/Contents/Library/LaunchDaemons/`.
- The daemon runs as root with `run --bootstrap`: data in `/Library/Application Support/SupersEmu Server`
  (TLS cert/key in `tls/`, local admin token in `admin.token`), HTTPS on port 8487, Bonjour `_supersemu._tcp`,
  log at `/Library/Logs/supersemu-server.log`.
- Server mode can also run the embedded server for the current session only (user data folder, port 8488).

## Verification status

Verified in a macOS VM (Xcode 26):

- The app bundle contains `Contents/MacOS/supersemu-server` and `Contents/Library/LaunchDaemons/<plist>`;
  `plutil -lint` passes.
- The embedded binary serves HTTPS with the self-signed cert, pairs a device (`/v1/pair`) and rejects reused
  codes; the served leaf SHA-256 matches `PairingPayload.certificateSHA256`.

Not verifiable in a VM; test on the Mac mini:

- The one-time approval in System Settings › General › Login Items, and `SMAppService` reaching `.enabled`
  (needs a properly signed app; an ad-hoc signed debug build may report `.requiresApproval` or fail).
- The daemon starting at boot with no one logged in, and `KeepAlive` restarts.
- Public HTTPS reachability before login, with Cloudflare DDNS and Caddy.
- iPhone/iPad pairing over LAN and public HTTPS, and the local-network permission prompt on device.
