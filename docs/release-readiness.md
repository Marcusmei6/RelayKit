# Release Readiness

RelayKit is preparing for public beta distribution, not a public release yet.

## Current Source Candidate and CI Status

At runtime-safety source candidate `5992d6d`, the P0 matrix is 8/8 PASS. `dist/runtime-safety/evidence.json` binds that source commit and the tracked harness/test hashes; later CI/documentation-only commits do not replace the runtime candidate. Installed Build 16 remains the historical/current shared runtime and was untouched; this result does not create or validate a replacement installation. Build 17 signed beta is the next distribution goal.

The repository now contains GitHub-ready workflows, but this checkout has no Git remote and none of the workflows has run on GitHub. CI is therefore not yet GitHub-green. On the first separately authorized public push, confirm these exact checks before making them required on `main`:

- `Fast Gates / Public boundary`
- `Fast Gates / Shell contracts`
- `Fast Gates / Go test, vet, and format`
- `macOS App / Swift and headless package validation`
- `macOS Runtime Safety / Offline contract and fault harness`
- `Protocol Contract / Loopback adapters and Responses`

After the checks appear and pass, enable branch protection requiring all six and an up-to-date branch. Remote creation, push, signing, notarization, packaging, and release remain outside this lane.

## Signed Beta v0.1.0 Current Candidate

Release readiness is **complete for a signed beta candidate; public release remains unpublished**. The current artifact is `dist/github-release/v0.1.0/RelayKitApp-0.1.0-signed.zip`, SHA-256 `116928bda89b6ca9a266bd7e1b3b820fc811d45f6ba118be16a367c619cf1a78`. Its release/trimmed-path binaries passed the archive personal-path scan, Developer ID signing, hardened runtime, fresh notarization acceptance, stapling, Gatekeeper validation, signed-zip dogfood, and the menu-bar right-click Quit lifecycle.

`dist/dogfood-local-beta/evidence.json` binds normal extracted-App launch, Provider/Keychain persistence, gateway restart, failure guidance, Quit, cleanup, and zip SHA directly to the immutable current release zip. This is setup/plumbing evidence and its provider remains explicitly a fixture. Real current-package route evidence is separate under `dist/signed-beta-v0.1.0/path-clean-six-stage-20260720T162614Z/final-evidence/`: six unique Desktop stages each have one submission, one exact rollout binding, and `evidence_verified` state. Official and provider plain/Markdown requests completed; both tool routes show native tool calls with matching output, fresh marker, workspace `pwd`, and exit code 0. Required Markdown rendered without bare XML, `function_calls`, or unresolved protocol JSON.

The product fix in `c2581ac` accepts the single terminal LF added by current Desktop explicit-shell input. It does not claim a rejected second-leg payload as the root cause. The current run uses the corrected harness directly; no post-run evidence rewrite is needed.

Cleanup passed: the App, bundled gateway, and isolated Desktop stopped; `19777` and `18787` were free; and global Codex config/auth guards passed unchanged. The public GitHub Release remains unpublished and the updater is not implemented.

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

Developer ID identity and the notarization credential profile were prepared during that historical RC1 closeout. The current candidate above subsequently completed signing, notarization, stapling, signed dogfood, and its final Desktop route gate.

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

## Historical Local/RC1 Checks

The checks below describe earlier local/RC1 artifacts. They are historical reference only and do not complete the current Signed Beta candidate or replace its fresh six-stage current-package proof.

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

## Historical Signed Beta Packaging Flow

This packaging contract remains documented for a future version or a required rebuild. Do not rerun it for the fixed current artifact, which is already signed, notarized, and stapled.

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

Historical packaging/rebuild checklist (not the current completion sequence):

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

The current Signed Beta candidate passed its bounded package and route gates:

- current eligible artifact: SHA-256 `116928bda89b6ca9a266bd7e1b3b820fc811d45f6ba118be16a367c619cf1a78`;
- superseded path-bearing artifact: SHA-256 `c340a53682d0a615ab0409c3be8f0a290f720aa5a488c774349be615fc5020ee`;
- historical/ineligible failed artifact: SHA-256 `c481ae5607c813f8f907f3c7b82252e7c709f7e10b77b1176688215736f720f3`;
- publication remains a separate, currently unexecuted decision.

Public release still needs:

- signed beta tester feedback;
- final privacy, install, uninstall, support, and security docs reviewed in public-safe form;
- Sparkle 2 updater implementation after signed beta, following `docs/update-policy.md`;
- release notes and checksum.

## Do Not Fake

Do not add a partial signing script that appears official without a Developer ID flow. Do not claim notarization until `spctl` verifies a stapled or online-notarized artifact.
