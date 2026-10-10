# Google Drive permissions analysis

| Scope | What the app can see | Sign-in experience | Fit |
|---|---|---|---|
| `drive.file` | Only files the app created or the user picked in Google Picker | Clean, no verification | Breaks "drop ROMs in a Drive folder and they appear" |
| `drive.readonly` | Everything, read-only | Restricted scope, same warnings as full | Can't upload saves, so not enough on its own |
| `drive` (chosen) | Everything, read/write | "Unverified app" warning until verified; 100-user cap | Matches the product |

Notes (from Google's documentation, not yet exercised end to end):
- Google Picker on iOS/macOS goes through the system browser and only grants `drive.file`.
- Projects left in "Testing" publishing status issue refresh tokens that expire after 7 days.
- Restricted scopes require a third-party security assessment before public release.

## Folder layout in Drive
```
SupersEmu/
  Games/<Console>/...        user-visible, user may add files here
  Saves/<game-sha256>/       native saves (.srm, memory cards)
  States/<game-sha256>/      auto/<timestamp>.state, manual/<slot>.state + manifest.json
  Library/catalog.json       library metadata, versioned
```

## Needed from Chad
A Google Cloud project with the OAuth client (iOS + macOS bundle IDs) once the Apple Developer
account is ready.
