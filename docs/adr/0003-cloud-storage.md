# ADR 0003: Cloud storage

- Status: Accepted (owner decision, 2026-10-10)

## Decision
- Phase 1: Google Drive with the full `https://www.googleapis.com/auth/drive` scope, so the app can
  see games the user drops into a Drive folder from any device or browser.
- Phase 2: iCloud Drive as an alternative sign-in/storage option.
- All sync code goes through a `CloudStorageProvider` protocol so iCloud slots in without touching
  the library, save or import code.

See `docs/specs/google-drive.md` for the scope analysis.

## Consequences
- Full Drive scope is a restricted scope. Until Google verifies the app, users see an
  "unverified app" screen at sign-in and the project is capped at 100 users. Fine for
  Chad + friends on TestFlight; public release needs Google's verification and security assessment.
- The OAuth consent screen must be set to "In production" (not "Testing"), otherwise refresh
  tokens expire after 7 days.
