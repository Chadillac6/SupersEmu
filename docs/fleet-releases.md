# Fleet releases

The `Fleet CI and release` workflow runs server tests, Mac host/input tests, and an
unsigned iOS simulator build for PRs. PR jobs have read-only tokens and no release
secrets. Homebrew test fixtures use the existing fetch script; unavailable fixtures
skip their matching tests.

A push to `main` (including a merged PR) runs the same checks. In parallel,
`Select release version` picks one shared marketing version and build number, then
`Publish Mac update` builds and notarizes the universal Developer ID Mac update and
`Upload iOS build to TestFlight` archives the iOS app. Both release jobs wait for
`Mac and server checks` to pass (`scripts/ci-wait-for-job.sh`) before publishing, so a
release takes about as long as the checks rather than checks plus both builds. The marketing version advances by 0.0.1
above the latest App Store Connect iOS or Sparkle Mac version, with `project.yml` as
the minimum floor. TestFlight builds are added to the internal **Chad** group
automatically. The Mac release is notarized and stapled. Stapling is retried 10 times; if Apple's
ticket server stays unreachable, the notarized files ship unstapled with a warning
(Gatekeeper fetches the ticket online). Its GitHub release contains
the ZIP, DMG, and `appcast.xml`. Standard `macos-15` hosted runners with Xcode 26.2
(Swift 6.2) are used; no runner is installed on the production Mac mini. Failed checks,
notarization, or TestFlight upload fail the matching release job. The Mac and iOS jobs
publish independently: a failed Mac notarization no longer stops the TestFlight upload.

## One-time credential setup

Use the `mac-release` GitHub environment, restricted to the `main` branch. Store:

| Secret | Value |
| --- | --- |
| `MAC_CERT_P12_BASE64` | Base64 of the Developer ID Application certificate **and private key** exported as .p12 |
| `MAC_CERT_PASSWORD` | Password protecting that .p12 export |
| `ASC_KEY_ID` | Team App Store Connect API key ID |
| `ASC_ISSUER_ID` | Team API issuer ID |
| `ASC_KEY_P8_BASE64` | Base64 of the downloaded team API .p8 key |
| `SPARKLE_PRIVATE_KEY` | Existing Sparkle key exported by `generate_keys --account com.chadillac6.supersemu -x <private-file>` |

A `.p12` exported from Keychain Access or OpenSSL 3+ is supported because CI
re-encodes it before macOS imports it. A wrong password fails with a specific
`MAC_CERT_PASSWORD` error.

The Sparkle key must match the public key already installed on the fleet. Never
regenerate it as a setup shortcut. The current Developer ID certificate expires
February 1, 2027; renew it and replace the certificate secret before expiry.
Raw credentials are scoped to the signing-preparation step. The archive receives
only notarization IDs and a private staged key-file path, so Xcode does not inherit
the certificate password or raw private-key values. Local release scripts also
remove raw signing secrets from child-process environments after staging the key.

Private files/passwords must stay outside the repository and workflow logs. Use
`gh secret set NAME --env mac-release` with input from a file or pipe; do not place
secrets in command-line arguments. GitHub encrypts secrets at rest.

The workflow imports the certificate into an isolated temporary runner keychain,
then restores the previous search list and removes temporary signing material even
on failure. It never changes a developer's login keychain. The release script checks
all required secrets before building. The `main`-only environment restriction must
remain enabled; do not grant release credentials to PR workflows.

## Daily use

1. Open a PR and wait for `Mac and server checks` to pass.
2. Merge the PR into `main`.
3. Watch `Publish Mac update` and `Upload iOS build to TestFlight` in the Actions tab.
   Their successful completion means the Mac update was published and the iOS build was
   uploaded to TestFlight; merging by itself is not proof of delivery.
4. The iOS build appears in the internal **Chad** TestFlight group after processing.
   Macs with the bootstrap Sparkle app installed can fetch the update automatically
   or use **Check for Updates**. A Mac serving the library may need administrator
   approval to restart its boot daemon; client-only Macs do not run that daemon.

To retry a failed release, run this workflow manually on `main` using **Run workflow**.
Build numbers use UTC timestamps. Builds are serialized per ref, and a stale main
commit is not published if main has moved forward. If the Mac update publishes but
the TestFlight upload fails, the next run advances from the latest Mac version.

## Recovery

Never overwrite an existing signed release or reuse its build number. To roll back
code, revert the change in a new PR and merge it: the release gets a higher version,
so Sparkle can deliver the reverted code. Installing an older release manually is
also possible, but Sparkle does not automatically downgrade.

The Developer ID bootstrap changed the signing identity of the old development
app. Its existing SMAppService registration needed unregister/register once.
Future releases retain that Developer ID identity. Verify the boot server health
after the first real update; release publication alone does not prove the updater
installation and server restart succeeded on every Mac.

Main branch protection is not changed by this workflow PR. Recommended: require
`Mac and server checks` before merge, retain PR review of workflow changes, and keep
signing secrets accessible only to trusted maintainers. For a single maintainer,
required independent approvals would block routine work, so they are not assumed.
