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
   ./scripts/codex-desktop-manual-proof.sh
   ```

7. Send one simple request and one tool/command request. Confirm Usage shows fresh current-run events and the Codex UI does not show raw XML/function call text.
8. Export diagnostics and attach only the redacted bundle plus redacted screenshots to feedback:

   ```bash
   ./scripts/export-diagnostics.sh
   ```

Expected local beta friction: Gatekeeper may reject the ad-hoc app. That is expected until Developer ID signing and notarization are available.
