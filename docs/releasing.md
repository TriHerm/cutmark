# Releasing Cutmark

Public production releases are built from a green `main` commit and use Apple Developer ID signing,
hardened runtime, secure timestamps, notarization, and Gatekeeper verification before GitHub Release
publishes `Cutmark.dmg`.

## GitHub environment

Create a protected GitHub Actions environment named `production-release`. Configure:

- Environment variable `APPLE_TEAM_ID`
- Secret `APPLE_DEVELOPER_ID_P12_BASE64`
- Secret `APPLE_DEVELOPER_ID_P12_PASSWORD`
- Secret `APPLE_NOTARY_KEY_P8_BASE64`
- Secret `APPLE_NOTARY_KEY_ID`
- Secret `APPLE_NOTARY_ISSUER_ID`

The certificate must be a **Developer ID Application** certificate for `APPLE_TEAM_ID`. The notary
credential should be a **Team App Store Connect API key** that is accepted by `notarytool`.

Keep the raw `.p12` and `.p8` out of the repository. Store their base64 encodings only in the
protected environment secrets. The release runner materializes them in its temporary directory and
deletes the temporary keychain/key files at the end of the job.

## Release gate

1. Merge the release candidate to `main` and require the normal CI run for that exact commit to pass.
2. Add `docs/releases/vMAJOR.MINOR.PATCH.md` in the release-candidate commit.
3. Create `vMAJOR.MINOR.PATCH` on that same green commit.
4. The Release workflow reuses the successful CI result, imports the Developer ID identity into an
   ephemeral keychain, builds/signs Cutmark, signs the DMG, notarizes and staples the DMG, runs
   Gatekeeper checks against the DMG and mounted app, then creates the GitHub Release.

Production mode is fail-closed. Missing credentials, an unexpected nested Mach-O, a Team ID mismatch,
a missing hardened-runtime flag, rejected notarization, or failed Gatekeeper assessment stops the
release before publication.

Local development does not require Apple release credentials. `build.sh` keeps the existing local
self-signed certificate path and the explicit ad-hoc mode used by ordinary CI.
