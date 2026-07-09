# Updater Readiness

Status: blocked.

RelayKit has the version and release package structure needed for a future Sparkle 2 updater, but the updater is not implemented and must not be advertised as available.

## Ready Now

- Bundle ID: `dev.relaykit.app`.
- Version keys: `CFBundleShortVersionString` and `CFBundleVersion`.
- Headless app bundle build: `./script/build_app_bundle.sh --verify`.
- Local ad-hoc beta package: `./script/package_release.sh --verify`.
- Signed release script shape: `./script/package_signed_release.sh`.
- GitHub Release asset shape: `dist/github-release/v<version>/RelayKitApp-<version>-signed.zip` plus `.sha256`.

## Blocked Before Sparkle Runtime Work

- Developer ID Application certificate.
- Notarization credentials.
- A successful signed and stapled RelayKit app.
- Sparkle EdDSA private key stored outside git.
- Sparkle public key committed only after the signed beta path is real.
- Signed stable appcast hosted from the GitHub Releases release process.

## Minimum Future Implementation

When the signed beta gate is real:

1. Add Sparkle 2 as the macOS updater dependency.
2. Add `SUPublicEDKey`, `SUFeedURL`, and signed-feed settings to `Info.plist`.
3. Add a tiny updater controller.
4. Add `Check for Updates` in Settings.
5. Keep local ad-hoc builds showing `Updates unavailable for local beta`.
6. Verify unsigned or non-notarized archives are rejected.

Do not implement beta/stable channels, custom release-note UI, delta updates, or forced updates until stable updating works.

## Verification

Before marking updater ready:

```bash
./script/package_signed_release.sh
codesign --verify --deep --strict --verbose=4 dist/RelayKitApp.app
spctl -a -vvv -t exec dist/RelayKitApp.app
xcrun stapler validate dist/RelayKitApp.app
```

Then verify Sparkle against a stable appcast whose enclosure points only to the signed and notarized GitHub Release asset.
