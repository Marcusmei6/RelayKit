# App Agent Rules

The app is the Apple-native shell. Keep it thin.

## Responsibilities

- SwiftUI/AppKit menu bar and settings UI.
- Keychain-backed credential storage.
- Gateway helper install/start/stop/status.
- Codex config activation and rollback UI.
- Local logs and usage summary views.

## Non-Responsibilities

- Protocol translation.
- Provider-specific request rewriting.
- Streaming/SSE parsing.
- Pricing calculations beyond displaying gateway output.

Those belong in `gateway/`.

