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

- Initialize Git repository.
- Add open-source boundary docs.
- Add `app/` and `gateway/` ownership rules.
- Add minimal gateway with `/healthz`, `/v1/models`, `/v1/responses`.
- Add tests and initial commit.

## Phase 1: Gateway MVP

- Define `ProviderProfile` schema.
- Load profiles from JSON.
- Add OpenAI Chat adapter.
- Add model catalog generator.
- Add request/response tests.
- Add CLI flags for config path and listen address.

## Phase 2: Streaming MVP

- Add SSE parser.
- Translate Chat Completions stream into Responses stream.
- Preserve output text, tool calls, finish reason, and usage when present.
- Add stream interruption tests.

## Phase 3: Anthropic Adapter

- Add Messages request adapter.
- Add Messages stream adapter.
- Map tool-use and stop reasons.
- Keep unsupported fields explicit and tested.

## Phase 4: Mac App MVP

- Create SwiftUI menu-bar app.
- Add gateway helper lifecycle.
- Store API keys in Keychain.
- Add provider CRUD.
- Activate Codex config with backup/rollback.
- Show gateway status and log tail.

## Phase 5: Local Observability

- Write usage JSONL.
- Summarize local usage by model/provider/day.
- Add app usage view.
- Keep cloud upload out of scope.

## Task Ownership

- Main coordinator owns roadmap, review, release gates, and public boundary.
- Gateway lane owns Go helper, adapters, tests.
- App lane owns SwiftUI shell, Keychain, helper lifecycle.
- Docs lane owns README, examples, comparisons, and handoff docs.

## Release Gate

First public release requires:

- no private strings in repository;
- `go test ./...` passes;
- README has install/build instructions;
- one public provider works end-to-end;
- Codex config activation has backup and rollback;
- no hosted telemetry.

