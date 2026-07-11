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
6. Use the locked `run-auto --scenario` interface for explicitly authorized isolated Codex Desktop route proof. Do not edit global `~/.codex/config.toml` or `~/.codex/auth.json`. `--setup-only` remains a picker preflight; the live interface uses a private `0600` v1 scenario. `$relaykit-desktop-query` is a separate one-query dispatcher and does not satisfy this four-stage gate.

   ```bash
   RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP=1 \
   RELAYKIT_DESKTOP_PROOF_REUSE_EXTRACTED_APP=1 \
     ./scripts/codex-desktop-manual-proof.sh --setup-only
   RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP=1 \
   RELAYKIT_DESKTOP_PROOF_REUSE_EXTRACTED_APP=1 \
     ./scripts/codex-desktop-manual-proof.sh run-auto --scenario /absolute/path/scenario.json
   ```

   The first command is setup/picker preflight only. It cannot satisfy route proof. Accessibility permission, authenticated Desktop state, and a real provider config stored locally outside git with a Keychain reference and no inline key/token are one-time prerequisites. The Skill keeps query bodies only in `0600` temporary files and removes them after the run.

7. Use four current-run automated GUI stages: GPT-5.5 simple request, GPT-5.6 Luna simple request, real provider Markdown request, and real provider shell/tool request. The harness must select each model and submit each query without a person selecting, pasting, typing, clicking Send, or pressing Enter. The picker must include the current account's GPT-5.3 Codex Spark entry and must not expose stale GPT-5.2. Confirm Usage records completed/200 events for both routes, Markdown renders structurally, the tool block shows matching output and exit code 0, and no raw XML/`function_calls` appears.
8. Export diagnostics and attach only the redacted bundle plus redacted screenshots to feedback:

   ```bash
   ./scripts/export-diagnostics.sh
   ```

Expected local beta friction: Gatekeeper may reject the ad-hoc app. That is expected until Developer ID signing and notarization are available.

Before accepting a pass, confirm `dist/dogfood-local-beta/evidence.json` matches the current zip SHA and `dist/codex-desktop-manual-proof/evidence.json` separately records the same `product_artifact_sha256`, the current `harness_sha256`, the private `scenario_sha256`, unchanged product source, and unchanged global Codex config/auth hashes. Full-standard automated acceptance additionally requires harness exit `0`, `desktop_gui_route_proof=automated_gui_complete`, and `human_intervention_count=0`. A stage may have multiple matching upstream usage events only when all are completed/200; one rollout thread with one user marker and one assistant marker proves a single GUI submission. Custom scenarios may update last-route/custom evidence but cannot replace the full-standard last-complete slot. Setup-only, fixture, old usage, CLI fallback, or aggregation of separate runs is not full-standard GUI route proof.

Keep setup and route claims separate in handoff material. Headless acceptance, picker/catalog projection, demo provider setup, and extracted-App dogfood are setup evidence. Only the current one-invocation four-stage Desktop result is route/render evidence.

Use tiered validation. Product-source or package-input changes get focused tests first, then one package/dogfood/four-stage run after the coherent root-cause group is complete. Harness, AX driver, screenshot, or assertion changes must reuse the fixed zip and extracted App and must not invoke a package script. Docs-only changes run documentation, public-boundary, and diff checks without building or launching GUI.
