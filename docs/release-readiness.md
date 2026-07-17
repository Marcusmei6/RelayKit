# Release Readiness

RelayKit is preparing for public beta distribution, not a public release yet.

## Signed Beta v0.1.0 Current Candidate

The current Developer ID / notarized candidate is `dist/github-release/v0.1.0/RelayKitApp-0.1.0-signed.zip`, SHA-256 `55a11eb435d4a0170942e34b28670755dfa164e6c1d74f5f6935eb96051b1587`. Signing, notarization acceptance, stapling, Gatekeeper validation, and two fresh extracted-App dogfood runs are recorded for that artifact.

Release readiness is **incomplete** because the final same-artifact isolated Desktop proof is incomplete: Official plain and Markdown have fresh submitted/completed/200 GUI evidence, but the Official tool request completed as text without a native function call/output and exit-zero tool block. Historical local/ad-hoc or prior Desktop route artifacts cannot substitute for this missing stage.

The redacted diagnostic at `dist/signed-beta-v0.1.0/official-tool-nondeterminism-diagnostic/evidence.json` binds this failure to the signed zip. The GUI request advertised `exec_command` among 16 tools over WebSocket; a same-version provider control executed a real tool successfully; and exact captured Official input/tool replays through the signed gateway produced native function calls over both HTTP and WebSocket. The Official adapter currently delegates tool routing to a nested model and can nondeterministically return ordinary text for an explicit shell request. Retrying until it happens to emit a function call is not an acceptable release gate.

The final closeout audit also failed the global-state gate: `~/.codex/auth.json` changed after the recorded isolated attempts, at filesystem mtime `2026-07-17T18:33:56Z`. The source is not attributed, and RelayKit did not read, repair, or rewrite that file. Global `config.toml` remained at its baseline hash and `18787`/`19777` were free, but no Signed Beta completion claim is allowed while the required final auth hash differs from the run baseline.

Do not publish a GitHub Release or implement an updater from this state. The next product remediation requires an explicit decision because the current Signed Beta workflow has already consumed its one allowed code/sign cycle.

## Historical Local/RC1 State

RelayKit can still build the earlier local non-Developer-ID beta package:

```bash
./script/package_release.sh --verify
```

Expected artifact:

- `dist/RelayKitApp.app`
- `dist/RelayKitApp-local.zip`
- bundled gateway at `RelayKitApp.app/Contents/MacOS/relay`
- bundled examples at `RelayKitApp.app/Contents/Resources/providers.example.json` and `codex.config.example.toml`

This is a local beta package only. It is not a signed, notarized, ordinary-user distribution.

The local beta uses macOS ad-hoc code signing (`codesign --sign -`) only. It is not iOS Ad Hoc distribution, does not use provisioning profiles, does not use UDIDs, and must not add `embedded.mobileprovision` or iOS-style Ad Hoc profile material. It also must not add unrelated entitlements, such as virtualization, to make local beta signing appear more official.

Historical local/RC1 summary:

- local beta: ready.
- open-source public-safe: ready.
- local beta packaging pipeline: ready.
- local ad-hoc RC1 public proof: accepted; the final matrix and fresh Test/independent CR gates passed.
- signed beta scaffolding and local Apple distribution inputs: present at that stage.
- signed beta: was not executed by the historical RC1 product-closeout goal; the current signed candidate is described above.
- public release: not complete.
- updater runtime: deferred until a signed and notarized artifact exists.

RC1 public-proof status is separate from the older local-beta result. The final matrix passed in a fresh `relaykit_test` lane, and an independent `relaykit_cr` review passed. The visual review type was `independent_visual_review`; `automated_classifier=false` was preserved and was not relabeled. This is local ad-hoc RC1 acceptance, not Signed Beta or public-release acceptance. Planner completion still requires a final release inspection of the current artifact. The accepted matrix was selected by:

```bash
./scripts/relaykit-validate.sh --plan-only --rc1
```

That profile builds one local package, then reuses its extracted `dist/verify-release/RelayKitApp.app` for the menu smoke, loopback-only native Responses proof, and abrupt-parent helper lifecycle proof. It does not use a real provider, send a paid Desktop request, run the four-stage Desktop scenario, sign with Developer ID, notarize, publish, or update shared Codex/LaunchAgent state.

Developer ID identity and the notarization credential profile were prepared during that historical RC1 closeout. The current candidate above subsequently completed signing, notarization, and stapling, but has not passed its final Desktop route gate.

Historical RC1 boundary: that goal produced no signed artifact, notarization submission, stapling result, Gatekeeper result, or GitHub Release. `dist/RelayKitApp-local.zip` remains an ad-hoc artifact and must not be described as the current signed beta.

Headless build and release commands:

- `./script/build_app_bundle.sh --verify` builds and verifies `dist/RelayKitApp.app` without opening the GUI app.
- `./script/package_release.sh --verify` packages the local ad-hoc beta without opening the GUI app.
- `./script/build_and_run.sh --verify` remains the LaunchServices GUI verification path.

Reserved app metadata:

- Bundle ID: `dev.relaykit.app`
- Marketing version: `RELAYKIT_APP_VERSION`, default `0.1.0`
- Build number: `RELAYKIT_BUILD_NUMBER`, default `1`

These values are already written into `Info.plist` as `CFBundleIdentifier`, `CFBundleShortVersionString`, and `CFBundleVersion` so the later Sparkle 2 updater phase can reuse the package structure. Do not implement an updater before signed beta. See `docs/update-policy.md` and `docs/updater-readiness.md`.

## Local Checks

```bash
test -x dist/RelayKitApp.app/Contents/MacOS/relay
test -f dist/RelayKitApp.app/Contents/Resources/providers.example.json
test -f dist/RelayKitApp.app/Contents/Resources/codex.config.example.toml
test -f dist/RelayKitApp.app/Contents/_CodeSignature/CodeResources
codesign --verify --deep --strict --verbose=4 dist/RelayKitApp.app
codesign -dvvv --entitlements :- dist/RelayKitApp.app
spctl -a -vvv -t exec dist/RelayKitApp.app
xcrun stapler validate dist/RelayKitApp.app
```

For the current local beta, Gatekeeper rejection is expected because the app is ad-hoc signed and not Developer ID signed or notarized. Do not describe this artifact as a signed beta, public release, or updater-ready release.

Latest local check on this machine, 2026-07-10:

- `./script/package_release.sh --verify`: passed and wrote `dist/RelayKitApp-local.zip`.
- `dist/RelayKitApp.app/Contents/_CodeSignature/CodeResources`: present.
- `codesign --verify --deep --strict --verbose=4 dist/RelayKitApp.app`: passed; bundled `relay` is prepared and validated.
- `codesign -dvvv --entitlements :- dist/RelayKitApp.app`: `Identifier=dev.relaykit.app`, `Signature=adhoc`, `TeamIdentifier=not set`, sealed resources present.
- `spctl -a -vvv -t exec dist/RelayKitApp.app`: rejected with status `3`, expected for local ad-hoc beta.
- `xcrun stapler validate dist/RelayKitApp.app`: no stapled ticket, expected until notarization.

`./script/build_app_bundle.sh --verify` and `./script/package_release.sh --verify` must continue to reject local beta artifacts that are missing `_CodeSignature/CodeResources`, are not `Signature=adhoc`, have a `TeamIdentifier`, or contain iOS-style provisioning profiles.

## Signed Beta Flow

The signed beta script is present but intentionally fails without real Apple distribution inputs:

```bash
RELAYKIT_SIGNING_IDENTITY="Developer ID Application: Example Team (TEAMID)" \
RELAYKIT_NOTARYTOOL_PROFILE="relaykit-notary" \
RELAYKIT_APPLE_TEAM_ID="TEAMID" \
./script/package_signed_release.sh
```

Required local or CI secrets:

- Developer ID Application certificate in a keychain available to `codesign`;
- `notarytool` keychain profile or equivalent notarization credential;
- Apple Team ID.

These values must never enter git, issue templates, screenshots, release evidence, or logs.

Signing order:

1. Build and verify the complete app bundle.
2. Sign the bundled `RelayKitApp.app/Contents/MacOS/relay` helper.
3. Sign `RelayKitApp.app` with `--options runtime` hardened runtime.
4. Verify with `codesign --verify --deep --strict --verbose=4 dist/RelayKitApp.app`.
5. Create the notarization zip.
6. Submit with `xcrun notarytool submit --wait`.
7. Staple with `xcrun stapler staple`.
8. Validate with `xcrun stapler validate`.
9. Gatekeeper-check with `spctl -a -vvv -t exec`.
10. Re-extract the signed zip and repeat `codesign`, `spctl`, and `stapler validate` on the extracted app.

Expected signed beta output:

- `dist/github-release/v<version>/RelayKitApp-<version>-signed.zip`
- `dist/github-release/v<version>/RelayKitApp-<version>-signed.zip.sha256`

If the credentials are missing, the script must print `missing Developer ID signing identity / notarization credentials` and must not create or reuse a signed zip.

Future Signed Beta checklist:

1. Confirm a Developer ID Application identity:

   ```bash
   security find-identity -p codesigning -v | grep "Developer ID Application"
   ```

2. Store notarization credentials outside git:

   ```bash
   xcrun notarytool store-credentials relaykit-notary
   ```

3. Export release-only inputs outside git:

   ```bash
   export RELAYKIT_SIGNING_IDENTITY="Developer ID Application: Example Team (TEAMID)"
   export RELAYKIT_NOTARYTOOL_PROFILE="relaykit-notary"
   export RELAYKIT_APPLE_TEAM_ID="TEAMID"
   export RELAYKIT_GITHUB_REPO="owner/repo"
   ```

4. Run `./script/package_signed_release.sh`.
5. Verify `codesign`, `spctl`, and `xcrun stapler validate` on `dist/RelayKitApp.app` and on the app extracted from the signed zip.
6. Install dogfood from the signed zip, not from the repo checkout.
7. Create the GitHub Release draft with `./script/create_github_release_draft.sh`.

## GitHub Releases Structure

For signed beta, create a draft GitHub Release `v<version>` with:

- `RelayKitApp-<version>-signed.zip`
- `RelayKitApp-<version>-signed.zip.sha256`
- release notes that state the supported macOS version, bundle id, signing/notarization status, and known beta limitations;
- no appcast, Sparkle feed, or auto-update metadata until the signed beta path is proven.

Use `RELAYKIT_GITHUB_REPO=owner/repo ./script/create_github_release_draft.sh` after `package_signed_release.sh` succeeds. The draft script re-validates the signed zip before uploading assets.

Version bump flow:

```bash
RELAYKIT_APP_VERSION=0.1.1 RELAYKIT_BUILD_NUMBER=2 ./script/package_release.sh --verify
RELAYKIT_APP_VERSION=0.1.1 RELAYKIT_BUILD_NUMBER=2 ./script/package_signed_release.sh
RELAYKIT_APP_VERSION=0.1.1 ./script/create_github_release_draft.sh
```

The checksum is always named beside the signed zip as `RelayKitApp-<version>-signed.zip.sha256`.

After signed beta is proven, the stable updater feed may be added as a GitHub Releases-backed Sparkle appcast. Local ad-hoc zips must never enter that feed.

## Distribution Ladder

Local beta:

- locally generated zip with an ad-hoc bundle signature only;
- intended for trusted testers who understand Gatekeeper friction;
- no cloud telemetry;
- feedback collected manually with `docs/feedback-template.md`.

Signed beta still needs:

- external Developer ID Application certificate and notarization credentials;
- successful run of `./script/package_signed_release.sh`;
- a stapled app that passes the acceptance commands above;
- draft GitHub Release assets and checksum.

Public release still needs:

- signed and notarized package;
- signed beta tester feedback;
- final privacy, install, uninstall, support, and security docs reviewed in public-safe form;
- Sparkle 2 updater implementation after signed beta, following `docs/update-policy.md`;
- release notes and checksum.

## Do Not Fake

Do not add a partial signing script that appears official without a Developer ID flow. Do not claim notarization until `spctl` verifies a stapled or online-notarized artifact.
