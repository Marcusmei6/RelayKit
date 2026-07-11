# Beta Dogfood Checklist

Use this checklist for each local beta pass while Developer ID signing is still parked.

1. Build the local package:

   ```bash
   ./script/package_release.sh --verify
   ```

2. Unzip `dist/RelayKitApp-local.zip` and launch the extracted `RelayKitApp.app`.
3. Open the menu-bar app and confirm `Settings` shows gateway port `127.0.0.1:19777`.
4. In `接入`, add or edit one demo/loopback provider, save the key to Keychain, run `Test connection`, run `Detect models`, and use only reachable models.
5. Quit and relaunch RelayKit, then confirm the provider and saved-key state still appear.
6. Use the isolated Codex Desktop proof harness for route proof. Do not edit global `~/.codex/config.toml` or `~/.codex/auth.json`.

   ```bash
   ./scripts/codex-desktop-manual-proof.sh --setup-only
   RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG="$HOME/path/to/local-providers.json" \
   RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID="public/provider-model-id" \
     ./scripts/codex-desktop-manual-proof.sh
   ```

   The first command is setup/picker preflight only. It cannot satisfy route proof. The full run requires a real provider config stored locally outside git with a Keychain reference and no inline key/token. Set the public model id to one model present in that config.

7. Complete the four current-run GUI stages: GPT-5.5 simple request, GPT-5.6 Luna simple request, real provider Markdown request, and real provider shell/tool request. The picker must include the current account's GPT-5.3 Codex Spark entry and must not expose stale GPT-5.2. Confirm Usage records completed/200 events for both routes, Markdown renders structurally, the tool block shows matching output and exit code 0, and no raw XML/`function_calls` appears.
8. Export diagnostics and attach only the redacted bundle plus redacted screenshots to feedback:

   ```bash
   ./scripts/export-diagnostics.sh
   ```

Expected local beta friction: Gatekeeper may reject the ad-hoc app. That is expected until Developer ID signing and notarization are available.

Before accepting a pass, confirm `dist/dogfood-local-beta/evidence.json` matches the current zip SHA and `dist/codex-desktop-manual-proof/evidence.json` reports unchanged source/harness hashes and unchanged global Codex config/auth hashes. Setup-only, fixture, old usage, or CLI fallback evidence is not GUI route proof.
