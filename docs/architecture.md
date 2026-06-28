# Architecture

RelayKit uses a thin native app plus a portable gateway helper.

```text
Mac app
  - SwiftUI/AppKit UI
  - Keychain storage
  - helper lifecycle
  - client config activation

Gateway helper
  - loopback HTTP server
  - client-facing API compatibility
  - upstream adapters
  - model catalog generation
  - local usage events
```

## Why Not All Swift

Swift is the right tool for Mac-native UI, Keychain, LaunchAgent, menus, and helper management. It is not the shortest path for protocol-heavy gateway work.

The gateway stays in Go so streaming, HTTP, tests, and future headless use remain simple.

## First Client

Codex is the first compatibility target because it already supports `openai_base_url` and external model catalog configuration.

RelayKit should not expose this as a Codex-only architecture. The public contract should stay generic enough to support other agentic clients later.

## Data Flow

```text
Agent client -> 127.0.0.1 RelayKit gateway -> upstream provider
            <- translated response/SSE     <-

Mac app -> profiles/config -> gateway helper
Mac app -> activate route -> client config
Gateway -> local usage JSONL
```

## Storage

- Provider profiles: app-owned local config.
- Secrets: macOS Keychain.
- Generated catalog: local JSON file.
- Usage events: local JSONL, no hosted upload in the first release.

