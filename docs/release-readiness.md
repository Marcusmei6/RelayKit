# Release Readiness

## Current State

RelayKit can build a local unsigned beta package:

```bash
./script/package_release.sh --verify
```

Expected artifact:

- `dist/RelayKitApp.app`
- `dist/RelayKitApp-local.zip`
- bundled gateway at `RelayKitApp.app/Contents/MacOS/relay`
- bundled examples at `RelayKitApp.app/Contents/Resources/providers.example.json` and `codex.config.example.toml`

This is a local beta package only. It is not a signed, notarized, ordinary-user distribution.

## Local Checks

```bash
test -x dist/RelayKitApp.app/Contents/MacOS/relay
test -f dist/RelayKitApp.app/Contents/Resources/providers.example.json
test -f dist/RelayKitApp.app/Contents/Resources/codex.config.example.toml
codesign -dvvv --entitlements :- dist/RelayKitApp.app
spctl -a -vv dist/RelayKitApp.app
```

For the current local beta, ad-hoc signing or Gatekeeper rejection is expected. Do not describe this artifact as a signed beta or public release.

Latest local check on this machine:

- `codesign -dvvv --entitlements :- dist/RelayKitApp.app`: `Signature=adhoc`, `TeamIdentifier=not set`.
- `spctl -a -vv dist/RelayKitApp.app`: rejected local distribution shape; current output was `code has no resources but signature indicates they must be present`.

## Distribution Ladder

Local beta:

- unsigned zip generated locally;
- intended for trusted testers who understand Gatekeeper friction;
- no cloud telemetry;
- feedback collected manually with `docs/feedback-template.md`.

Signed beta still needs:

- Developer ID Application certificate;
- signing for the main app and bundled `relay` helper;
- hardened runtime;
- notarization;
- stapling;
- versioned artifact naming;
- install and uninstall instructions.

Public release still needs:

- signed and notarized package;
- privacy statement;
- update policy;
- support contact and issue template;
- release notes and checksum.

## Do Not Fake

Do not add a partial signing script that appears official without a Developer ID flow. Do not claim notarization until `spctl` verifies a stapled or online-notarized artifact.
