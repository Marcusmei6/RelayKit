# RelayKit Beta Test Guide

This guide is for a small local beta. RelayKit does not collect cloud telemetry; share only redacted screenshots and summaries.

## Install And Start

1. Get `RelayKitApp-local.zip` from the developer.
2. Unzip it and open `RelayKitApp.app`.
3. Open the RelayKit menu-bar item.
4. Confirm Settings shows gateway port `127.0.0.1:19777`.

If macOS blocks the app, this is expected for the local ad-hoc beta. The signed beta/public release is a later step.

## Add An OpenAI-Compatible Provider

1. Open `接入`.
2. Click add provider.
3. Enter a provider name.
4. Enter an OpenAI-compatible base URL.
5. Paste an API key. RelayKit stores the key in Keychain and writes only a credential reference to provider JSON.
6. Enter a model id.
7. Click `Test connection`.
8. Click `Detect models` if the provider exposes a model-list endpoint.
9. Choose `Use reachable models` so failed models do not enter the usable list.
10. Save, quit RelayKit, reopen it, and confirm the provider plus masked saved-Keychain state remain visible.

Do not send the provider base URL or API key in feedback.

## Add An Anthropic-Compatible Provider

1. Open the provider form.
2. Enter a provider name.
3. Enter the Anthropic-compatible base URL.
4. Paste an API key.
5. Enter a public model id.
6. Open Advanced only if needed.
7. Set `Upstream protocol` to `Anthropic Messages`.
8. Use `Custom models URL`, `Custom auth header`, or `Upstream model override` only when your provider requires it.
9. Test, detect models, choose reachable models, and save.
10. Quit and reopen RelayKit to confirm the provider and masked saved-Keychain state persist.

## Verify Locally

1. Start the gateway from RelayKit.
2. Confirm `/v1/models` lists official models and saved provider models.
3. Prepare the isolated Codex Desktop proof state:

   ```bash
   ./scripts/codex-desktop-manual-proof.sh --setup-only
   ```

4. Run the manual proof harness and keep its terminal open:

   ```bash
   RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG="$HOME/path/to/local-providers.json" \
   RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID="public/provider-model-id" \
     ./scripts/codex-desktop-manual-proof.sh
   ```

   The local provider config must live outside tracked repository files, contain the selected public model id, and store only a Keychain credential reference. Never put an API key or token in that JSON file.

5. In the isolated Codex Desktop window, confirm the model picker lists current official and locally configured provider models. Current account projection should include GPT-5.3 Codex Spark and exclude stale GPT-5.2.
6. Complete the harness prompts for GPT-5.5, GPT-5.6 Luna, provider Markdown, and provider shell/tool output.
7. Confirm Markdown and tool blocks render normally with no raw XML, `function_calls`, or unparsed tool JSON.
8. Open RelayKit Usage and confirm fresh completed events appear for both official and provider routes.

The public demo/loopback provider is only a catalog, picker, Keychain, and form-plumbing fixture. It cannot prove real model output or tool compatibility. Real route proof must use a provider configured locally outside git; RelayKit evidence records only public model ids and redacted status/count fields.

Keep screenshots redacted. Hide provider URLs, keys, account names, local usernames, and private model names if needed.

## Feedback

Use `docs/feedback-template.md`. Good feedback includes:

- whether the app launched;
- whether provider setup made sense;
- whether model listing worked;
- whether a request routed;
- whether tool-call display looked correct;
- whether Usage updated;
- where the UI stalled or confused you.

Attach a redacted diagnostics bundle when possible:

```bash
./scripts/export-diagnostics.sh
```

Do not include API keys, bearer tokens, cookies, `auth.json`, raw logs, or unredacted private provider URLs.

## Cleanup

Quit RelayKit from the menu-bar right-click menu.

Remove isolated proof state:

```bash
rm -rf "$HOME/Library/Application Support/RelayKit/DesktopProof"
```

Remove all RelayKit local data only if you also want to delete provider config and usage history:

```bash
rm -rf "$HOME/Library/Application Support/RelayKit"
```
