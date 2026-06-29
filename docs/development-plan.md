# RelayKit Development Plan

## Goal

Build a public, Apple-native local gateway kit for agentic coding tools, starting with Codex-compatible routing while keeping the architecture general enough for future clients.

## Product Shape

RelayKit should sit between Beacon and CC Switch:

- lighter and more native than CC Switch;
- more capable as a gateway than Beacon;
- safe to publish without private infrastructure.

## Architecture

```text
SwiftUI/AppKit app
  -> starts and controls Go helper
  -> stores secrets in Keychain
  -> writes client config
  -> shows status, logs, usage

Go gateway helper
  -> exposes loopback HTTP API
  -> loads provider profiles
  -> adapts public upstream APIs
  -> writes local usage events
  -> generates model catalog
```

## Phase 0: Repository Foundation

Status: complete.

- Initialized Git repository.
- Added open-source boundary docs.
- Added `app/` and `gateway/` ownership rules.
- Added minimal gateway with `/healthz`, `/v1/models`, `/v1/responses`.
- Added tests and initial commits.

## Phase 1: Gateway MVP

Status: complete.

- Defined `ProviderProfile` schema.
- Loaded profiles from JSON.
- Added OpenAI Chat adapter.
- Added model catalog generator.
- Added request/response tests.
- Added CLI flags for config path and listen address.

Minimal public `ProviderProfile` contract:

```json
{
  "id": "local-openai-compatible",
  "name": "Local OpenAI Compatible",
  "base_url": "http://127.0.0.1:11434/v1",
  "api_format": "openai_chat",
  "auth_env": "RELAYKIT_EXAMPLE_API_KEY",
  "models": [
    {
      "id": "qwen3-coder",
      "display_name": "Qwen3 Coder",
      "context_window": 128000
    }
  ]
}
```

Phase 1 should reject missing `id`, `base_url`, `api_format`, or empty `models`. `auth_env` is optional for local fake providers and must name an environment variable, not contain a secret.

## Phase 2: Streaming MVP

Status: complete for text streaming MVP.

- Added SSE parser.
- Translated Chat Completions stream into Responses stream.
- Preserved output text, finish reason, and usage when present.
- Added malformed/truncated stream tests.

## Phase 3: Anthropic Adapter

Status: complete for Messages MVP.

- Added Messages request adapter.
- Added Messages stream adapter.
- Kept unsupported fields explicit and tested.
- Tool-use hardening remains a later focused item.

## Phase 4: Mac App MVP

Status: local usable alpha complete.

- Created SwiftUI app shell.
- Added development gateway helper lifecycle.
- Showed gateway status.
- Read `/healthz` and `/v1/models`.
- Activated Codex config with explicit source/target paths and backup/rollback output.
- Added local alpha smoke script.
- Defer Keychain, provider CRUD, LaunchAgent install, and log tail until the visible shell is reviewed.

## Phase 4.5: Helper Lifecycle Hardening

Status: next.

- Add the smallest LaunchAgent or packaged-helper flow for the existing built gateway binary.
- Keep explicit provider config paths.
- Do not add credentials, signing, notarization, or publishing.
- Keep uninstall/stop behavior scoped to RelayKit-owned helper state.
- Preserve `./scripts/local-alpha-smoke.sh` as the baseline.

## Phase 5: Local Observability

- Write usage JSONL.
- Summarize local usage by model/provider/day.
- Add app usage view.
- Keep cloud upload out of scope.

## Task Ownership

- `relaykit_planner` owns roadmap, dispatch, review/validation gates, release gates, and public boundary.
- `relaykit_gateway` owns Go helper, adapters, catalog, config parsing, usage events, and gateway tests.
- `relaykit_app` owns SwiftUI/AppKit shell, Keychain, helper lifecycle, LaunchAgent, config activation, and app tests.
- `relaykit_worker` owns bounded docs/examples/small cross-cutting implementation tasks.
- `relaykit_test` owns validation evidence and tier adequacy.
- `relaykit_cr` owns read-only correctness, simplicity, public-boundary, and security-sensitive review.
- `relaykit_release` owns packaging, signing readiness, helper layout, and public repo hygiene checks.

See `docs/agents/README.md` for the assignment header and dispatch rules.

## Release Gate

First public release requires:

- no private strings in repository;
- `go test ./...` passes;
- README has install/build instructions;
- one public provider works end-to-end;
- Codex config activation has backup and rollback;
- no hosted telemetry.
