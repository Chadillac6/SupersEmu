# Distribution

How SupersEmu reaches Chad and invited testers:

| Platform | Channel | Script |
| --- | --- | --- |
| iPhone / iPad | TestFlight (App Store Connect upload) | `scripts/release-ios.sh` |
| Mac | Developer ID signed + notarized `.dmg` / `.zip`, outside the Mac App Store | `scripts/release-mac.sh` |

Local and CI builds need none of this. With no team set, `Config/Signing.xcconfig` keeps ad-hoc signing (`-`), so `./scripts/build.sh` works without an Apple account.

## What Chad provides

1. **Team ID** (`SUPERSEMU_TEAM_ID`): 10 characters, from developer.apple.com > Account > Membership details.
2. **App Store Connect API team key** (Admin role):
   - `ASC_KEY_ID`: the key's Key ID.
   - `ASC_ISSUER_ID`: the Issuer ID (UUID) shown above the key list.
   - Provide the key as `ASC_KEY_PATH=/path/to/AuthKey_<KEYID>.p8` or `ASC_KEY_P8_BASE64="$(base64 -i AuthKey_<KEYID>.p8)"`. `ASC_KEY_P8_BASE64` accepts base64 of either the entire `.p8` file or the raw DER key.
3. **App Store Connect app record** for bundle ID `com.chadillac6.supersemu` (iOS platform).
4. **Mac only:** a **Developer ID Application** certificate in the login keychain of the Mac that runs `release-mac.sh`. Only the Account Holder can create it.

Optional: `SUPERSEMU_BUILD_NUMBER` overrides the build number. The default is a UTC timestamp, `YYYYMMDD.HHMMSS`, so each run gets a higher number than the last.

Never commit the `.p8`. `*.p8` and `Config/Signing.local.xcconfig` are gitignored. The scripts copy the key into a private temp directory and delete it when they exit.

## One-time setup (exact clicks)

### 1. Find the Team ID
developer.apple.com > **Account** > **Membership details** > **Team ID**.

### 2. Register the bundle ID
developer.apple.com > **Certificates, IDs & Profiles** > **Identifiers** > **+** > **App IDs** > **App** > Continue.
- Description: `SupersEmu`
- Bundle ID: **Explicit**, `com.chadillac6.supersemu`
- Capabilities: none are needed.

> Optional: `xcodebuild -allowProvisioningUpdates` with an Admin key can register this ID automatically on the first iOS run. Registering it by hand first rules out that step as a cause of failure.

### 3. Create the app record
appstoreconnect.apple.com > **Apps** > **+** > **New App**.
- Platforms: **iOS**. The universal iOS app covers iPhone and iPad.
- Name: `SupersEmu` (it must be unique on the App Store; if it is taken, use another name, since only the bundle ID matters to the scripts)
- Primary language: English (U.S.)
- Bundle ID: `com.chadillac6.supersemu`
- SKU: anything, for example `supersemu`
- User access: Full Access

### 4. Create the API key
appstoreconnect.apple.com > **Users and Access** > **Integrations** > **App Store Connect API** > **Team Keys** > **Generate API Key** (or **+**).
- Name: `SupersEmu release`
- Access: **Admin**
- Click **Generate**, then **Download** the `.p8`. Apple lets you download it only once.
- Copy the **Issuer ID** (shown above the table) and the key's **Key ID**.

Only an App Store Connect Admin can generate team keys ([Apple: Creating API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)). The key itself is set to Admin as well. App Manager can upload builds and run TestFlight, but `-allowProvisioningUpdates` also creates the distribution certificate and the App Store provisioning profile. Admin covers that step too. If you would rather use a narrower role, try App Manager and switch to Admin only if signing fails.

### 5. Mac: create the Developer ID Application certificate
On the Mac that will run the release, signed in to Xcode with the Account Holder's Apple Account:
**Xcode > Settings > Accounts** > select the team > **Manage Certificates** > **+** > **Developer ID Application**.
This puts the certificate and its private key in the login keychain. Check with:
`security find-identity -v -p codesigning | grep "Developer ID Application"`.

### 6. TestFlight testers
After the first upload finishes processing: App Store Connect > the app > **TestFlight**.
- **Internal Testing** > **+**: add App Store Connect users (up to 100, no review).
- **External Testing**: add testers by email or public link. The first build for external testers needs Beta App Review.
- The first time, answer the export compliance question if asked. The Info.plist key below normally answers it.

## Releasing

```sh
export SUPERSEMU_TEAM_ID=ABCDE12345 ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export ASC_KEY_PATH=~/keys/AuthKey_XXXXXXXXXX.p8
./scripts/release-ios.sh   # archive + upload; build shows in TestFlight after processing
./scripts/release-mac.sh   # build/release-mac/<build>/SupersEmu-<version>-<build>.dmg (+ .zip)
```

If a variable is missing, both scripts stop before building and print the missing names (exit code 2).

`release-ios.sh` runs these steps: xcodegen, then `xcodebuild archive` (Release, `generic/platform=iOS`, automatic signing), then `xcodebuild -exportArchive` with `method = app-store-connect` and `destination = upload`. Both `xcodebuild` steps get `-allowProvisioningUpdates` and `-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID`.

`release-mac.sh` runs these steps:
1. Archive with `Developer ID Application` signing, hardened runtime, and secure timestamps. `scripts/embed-server-daemon.sh` signs the embedded `supersemu-server` daemon with the same options.
2. Export with `method = developer-id`.
3. Verify the signatures.
4. Notarize the app with `xcrun notarytool submit --key/--key-id/--issuer --wait`, using the same API key, and staple it.
5. Build a `.dmg`, sign it, notarize it, staple it, and check it with `spctl`.

Bump the user-visible version by changing `MARKETING_VERSION` in `project.yml`.

## Why the Mac app isn't on TestFlight or the Mac App Store

Mac App Store builds, and therefore Mac TestFlight builds, must follow App Review Guideline 2.4.5 ([guidelines](https://developer.apple.com/app-store/review/guidelines/#mac-app-store)):
- (i) apps "must be appropriately sandboxed"
- (ii) apps "cannot install code or resources in shared locations"
- (iii) apps "may not auto-launch or have other code run automatically at startup or login without consent nor spawn processes that continue to run without consent after a user has quit the app"

Server Mode is built in a way that conflicts with all three:
- It registers `supersemu-server` with `SMAppService.daemon(plistName:)` as a launch daemon. The daemon starts at boot, runs as root before anyone logs in, and keeps serving over the LAN after the app quits (`App/ServerMode/ServerModeModel.swift`, `Server/Resources/com.chadillac6.supersemu.server.plist`).
- It reads ROM folders anywhere on disk.

A sandboxed app could only do this with a user-scoped login item and security-scoped bookmarks. That would mean redesigning the "Plex-style" server so it no longer runs at boot without a logged-in user. I haven't tested how sandboxing breaks the daemon. This is a conclusion from the guideline text plus how the code is structured. Separately, App Store Connect requires App Sandbox on every macOS upload, including TestFlight builds. That requirement comes from Apple's upload validation. I don't have an Apple documentation page to cite for it.

Developer ID plus notarization is Apple's supported route for Mac apps distributed outside the App Store. Since macOS 10.15, Developer ID software must be notarized. Notarization requires the hardened runtime, a secure timestamp, and no `get-task-allow` ([Apple: Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution); [Developer ID](https://developer.apple.com/developer-id/)). Notarization doesn't require the sandbox, so the daemon keeps working as it does now. Testers download the `.dmg` from wherever Chad shares it. It opens without Gatekeeper warnings, and Server Mode can be turned on as it is today.

## Export compliance (`ITSAppUsesNonExemptEncryption = NO`)

The iOS build sets `ITSAppUsesNonExemptEncryption` to `NO` (`project.yml`). Only App Store Connect reads this key, so it has no effect on the Developer ID Mac build. The app's only cryptography is:
- Apple's TLS, through `URLSession` to the paired server, with certificate pinning in `ConnectionPinning.swift`.
- Hashing.

It ships no custom or proprietary encryption. Apple says encryption built into the operating system, "for example, when your app makes HTTPS connections using URLSession", is exempt from export documentation requirements. Apple also says to set the key to `NO` when the app "either uses no encryption, or only uses encryption that's exempt" ([Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations); [ITSAppUsesNonExemptEncryption](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption)).

I checked the archived iOS binary with `nm`: it links CryptoKit `SHA256` and Apple TLS, and no BoringSSL. The Mac-only server daemon (Hummingbird/SwiftNIO SSL, which bundles BoringSSL) is not in the iOS app. It ships only by Developer ID, so this key doesn't apply to it.

Apple notes that some exempt uses may still need a year-end self-classification report to the U.S. government. Check that with whoever handles compliance. Revisit this setting if the app ever adds its own crypto (for example, encrypted save sync with a bundled library).

## Privacy manifest

`App/PrivacyInfo.xcprivacy` declares no tracking and no collected data. It declares the "required reason" APIs that the app and the cores it links call. I checked the reason codes against [Apple's reason list](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons).

| Category | Where | Reason |
| --- | --- | --- |
| UserDefaults | `@AppStorage`, `UserDefaults.standard` | `CA92.1`: information only accessible to the app itself |
| File timestamp | `attributesOfItem` / `.modificationDate` on library and save-state files, `stat`/`fstat` in cores | `C617.1`: metadata of files inside the app container |

To recheck the categories, run `nm -u` on the archived binary. It currently shows `_stat`, `_fstat`, `NSFileModificationDate` and `NSUserDefaults`, and nothing for system boot time, disk space or active keyboards. Run it again whenever a core is added.

## Licence risk (TestFlight and App Store)

This section flags risks. It isn't legal advice. Get it reviewed before any **public App Store** release.

- **Non-commercial cores.** Upstream terms for three of the bundled cores:
  - Snes9x permits use "for non-commercial purposes ... without fee" and says "Commercial use includes ... selling Snes9x" (`Vendor/cores/snes9x/LICENSE`).
  - Genesis Plus GX and PicoDrive say "Redistributions may not be sold, nor may they be used in a commercial product or activity" (`Vendor/cores/genesis_plus_gx/LICENSE.txt`, `Vendor/cores/picodrive/COPYING`).

  A free app with no in-app purchases or ads is the most defensible case. Charging for the app, ads, or IAP would very likely breach these terms. TestFlight distribution is free and limited to invited testers, so the risk there is low. The terms say nothing specifically about App Store distribution itself. That is a judgment call for the rights holders, not something these licences settle.
- **GPL and the App Store.** The app is planned as GPLv3, and Gambatte and Beetle PSX are GPLv2. In 2010 the FSF said App Store terms impose restrictions on recipients that conflict with the GPL, and asked Apple to stop distributing a GPL app ([FSF: GPL Enforcement in Apple's App Store](https://www.fsf.org/news/2010-05-app-store-compliance)). That was the FSF's position about a particular app at that time. It is not an Apple rule, and GPL apps do appear on the App Store. The practical risk is a takedown request from a copyright holder of a GPL component, not rejection by App Review. Since Chad owns the GPLv3 app code, only third-party GPL cores are exposed. This risk applies to public App Store distribution. It is small for invite-only TestFlight, but TestFlight distribution still happens under Apple's terms.
- **Emulators themselves.** Guideline 4.7 lets "retro game console and PC emulator apps ... offer to download games", but "You are responsible for all such software offered in your app ... and all applicable laws" ([guidelines](https://developer.apple.com/app-store/review/guidelines/#4.7)). SupersEmu bundles no ROMs or BIOS, and users load their own. Keep it that way: no ROM or BIOS downloads or links in the app, and none in the repo.
- **Mac Developer ID** distribution happens outside Apple's store terms, so the store-terms GPL point doesn't apply there. The non-commercial core terms still apply.

Core licences in detail: `docs/specs/core-matrix.md`.

## Automatic Mac updates (Sparkle)

The Mac app embeds Sparkle 2.10.0. One feed is used, with no beta/stable channels:
`https://github.com/Chadillac6/SupersEmu/releases/latest/download/appcast.xml`.
Release apps check hourly, download automatically, and normally install when the app quits.
“Check for Updates…” is also available in the SupersEmu menu. Debug builds never
start the updater, so a published release cannot replace an in-progress local experiment.

`Config/Updates.xcconfig` contains the feed and public Ed25519 key. Its private key
is held only in the Mac mini's login Keychain under account `com.chadillac6.supersemu`.
Keep that Keychain backed up. `Config/Updates.local.xcconfig` is ignored by Git and
can override settings for isolated update tests. Never commit an exported private key.
Downloaded archives are verified before extraction; anonymous profiling is disabled.

After a Sparkle update, a registered boot server is marked for restart. On the next
launch of `/Applications/SupersEmu.app`, the app offers to refresh the firewall entry
and restart the daemon through a macOS administrator dialog. Choosing Later or cancelling
keeps the restart pending; use “Restart Updated Server…” to retry. A privileged helper
would be needed to make this daemon step completely silent. Client-only Macs do not
need this restart. Games and saves live outside the app bundle.

To publish a tested release:

1. Restore a valid Developer ID Application signing certificate and configure the Apple
   release credentials described above.
2. Build with `scripts/release-mac.sh` (its output has a unique increasing build number).
3. Run `scripts/publish-mac-update.sh build/release-mac/<build> <tag> <tested-commit>`.
   It verifies the exported app, generates a signed appcast, uploads both assets to a draft,
   then publishes the draft as the latest GitHub release. Do not publish a release with a
   newer “latest” designation unless it also includes the Mac ZIP and appcast.

`prepare-mac-appcast.sh` performs step 3 without uploading or publishing anything.
Use `SPARKLE_GENERATE_APPCAST` to point at the tool in another derived-data directory.
For CI, `SPARKLE_ED_KEY_FILE` can point at a privately supplied signing key file;
never upload that file as a release asset. `generate_appcast` checks archive signatures
against the public key embedded in the app.

To undo a release, rebuild the desired older commit with a **new, higher build number**
and publish it as the latest release. Checking out an old PR alone does not downgrade
an installed app, and Sparkle intentionally ignores lower build numbers.

Initial rollout still requires installing one Sparkle-enabled release. Existing apps
without Sparkle cannot discover or install that first update. Test a real older-to-newer
signed/notarized pair before relying on unattended installs. iOS continues to update
through TestFlight, independently of Sparkle.
