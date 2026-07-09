# RelayKit Beta Test Guide

This guide is for a small local beta. RelayKit does not collect cloud telemetry; share only redacted screenshots and summaries.

## Install And Start

1. Get `RelayKitApp-local.zip` from the developer.
2. Unzip it and open `RelayKitApp.app`.
3. Open the RelayKit menu-bar item.
4. Confirm Settings shows gateway port `127.0.0.1:19777`.

If macOS blocks the app, this is expected for the unsigned local beta. The signed beta/public release is a later step.

## Add An OpenAI-Compatible Provider

1. Open `接入`.
2. Click add provider.
3. Enter a provider name.
4. Enter an OpenAI-compatible base URL.
5. Paste an API key. RelayKit stores the key in Keychain and writes only a credential reference to provider JSON.
6. Enter a model id.
7. Click `Test connection`.
8. Click `Detect models` if the provider exposes a model-list endpoint.
9. Save.

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
9. Test, detect models, and save.

## Verify Locally

1. Start the gateway from RelayKit.
2. Confirm `/v1/models` lists official models and saved provider models.
3. In an isolated Codex Desktop profile, point Codex to RelayKit's local gateway.
4. Confirm the model picker lists the expected provider models.
5. Send a tiny request.
6. Open RelayKit Usage and confirm a local usage row appears.

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
