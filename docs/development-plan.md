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
- Added a repository-local `./script/build_and_run.sh` entrypoint that builds the gateway binary, bundles it inside a SwiftPM macOS app bundle, and opens the app.
- Added development gateway helper lifecycle.
- Showed gateway status.
- Read `/healthz` and `/v1/models`.
- Activated Codex config with explicit source/target paths and backup/rollback output.
- Added local alpha smoke script.
- Kept the default provider config pointed at the public no-secret demo file, `examples/providers.example.json`.
- Keychain credential storage remains deferred until explicitly selected.

## Phase 4.5: Helper Lifecycle Hardening

Status: local LaunchAgent flow complete.

- Added the smallest LaunchAgent flow for the existing built gateway binary.
- Kept explicit provider config paths.
- Did not add credentials, signing, notarization, or publishing.
- Kept uninstall/stop behavior scoped to RelayKit-owned helper state.
- Kept the listen address fixed at `127.0.0.1:19777` and helper stdout/stderr at `/tmp/relay.{out,err}.log` for this local alpha slice.
- Preserve `./scripts/local-alpha-smoke.sh` as the baseline, including temporary LaunchAgent install/status/health/logs/uninstall coverage.

## Phase 5: Local Observability

Status: local usage view implemented.

- Added a local helper log tail command for `/tmp/relay.{out,err}.log`.
- Added local usage JSONL writes with the conservative contract below.
- Added local usage summary by day/provider/model.
- Added app usage view backed by the local summary CLI, including request, token, and duration aggregates.
- Covered local usage summary in the alpha smoke.
- Keep cloud upload out of scope.

Minimal usage JSONL contract:

- Path: `~/Library/Application Support/RelayKit/usage.jsonl` for the app/helper flow; tests may pass an explicit temporary path.
- Format: one JSON object per completed gateway request.
- Allowed fields: timestamp, request id, provider id, model, route, streaming flag, status, HTTP status, input tokens, output tokens, total tokens, duration milliseconds, and error code.
- Forbidden fields: request body, response body, prompts, tool arguments, headers, authorization values, cookies, API keys, local usernames, private domains, and raw upstream URLs containing credentials.
- Unknown token counts may be omitted or written as zero; do not invent estimates.
- Writes are local-only append operations. No cloud upload, daemon sync, or hosted telemetry.
- App summary may read this file and aggregate by day/provider/model only.
- Summary output is a JSON array sorted by day, provider id, and model. Fields: day, provider id, model, requests, input tokens, output tokens, total tokens, and duration milliseconds.

These defaults are intentionally conservative and are not a product blocker. If a later caller needs more fields, add them behind review with a public-boundary test.

## Phase 5.5: Local Configuration Editing

Status: minimal provider config editor implemented.

- Added provider config editing without secrets.
- Edit only public provider metadata and model list through explicit JSON text: provider id, display name, base URL, API format, auth env var name, model id, display name, and context window.
- Never edit, display, or store API keys, bearer tokens, cookies, or credential values.
- Preserve explicit config paths; no default writes to private provider configs.
- Validate JSON before displaying or writing and keep backup behavior for existing files.
- Reject credential-looking keys/values and base URLs with userinfo, query strings, or fragments before writing.
- Cover the credential-boundary validator through the SwiftPM `RelayKitAppValidationTests` executable run by local smoke.

## Phase 3.5/3.6: Anthropic Tool-Use Hardening

Status: tool-use mapping implemented for non-streaming and streaming fake upstreams.

- Mapped minimal Anthropic `tool_use` blocks to Responses `function_call` output items using fake upstream tests.
- Preserve unsupported cases as explicit errors or documented omissions.
- Did not add real provider calls or private provider behavior.
- Streaming tool-use mapping is implemented for fake upstream streams.

Minimal streaming tool-use contract:

- Fake upstream tests only; no real providers.
- Map `content_block_start` tool-use metadata to a Responses `function_call` item start when enough name/id data is present.
- Accumulate `input_json_delta` fragments into the function call arguments string without parsing or executing it.
- Emit a final function call output item before `response.completed`.
- If a stream ends with incomplete tool arguments, emit `response.error` and do not invent valid JSON.
- Keep text delta streaming behavior unchanged.
- Do not execute tools or record tool arguments in usage JSONL.

## Phase 6: Local Release Readiness

Status: README refreshed and agent model routes scrubbed to public defaults.

- Made README install/run commands match the current local alpha.
- Added unsigned local zip packaging with extraction and bundled-gateway verification.
- Run `docs/public-boundary-checklist.md`.
- Scrubbed `.codex/agents/*.toml` to public model defaults.
- Keep signing, notarization, publishing, and GitHub push out of scope until explicitly requested.

## Phase 7: P0 Menu-Bar Control Center

Status: in progress; menu-bar shell, screenshot smoke, reference coverage smoke, and temporary Codex E2E smoke are implemented.

- Primary surface is a menu-bar resident control-center, not a dashboard window.
- Main tabs are `接入`, `Usage`, and `设置`.
- `接入` owns real bundled gateway start/stop/restart, health, model refresh, Codex active target state, and a disabled Claude Code placeholder.
- `Usage` reads real local usage summaries only; empty state is allowed, mock cards are not.
- `设置` may show only settings wired to real state; unfinished settings stay hidden or disabled.
- Provider/model add uses a form sheet that writes the current public provider schema. JSON editing remains a fallback, not the primary P0 path.
- Provider form P0 persists provider id/name, base URL, API format, auth env reference, model id/display name, and context window. Streaming/tools/reasoning/priority/health metadata remain gateway-discovered or future schema work.
- Credentials are references only: env var, Keychain item name, or key-file reference. Never store or display credential values.
- P0 regression includes screenshot evidence under `dist/ui-smoke/`, redacted reference model coverage under `dist/reference-model-coverage.json`, and a temporary Codex E2E smoke under `dist/codex-e2e/` that never writes real `~/.codex/config.toml`.
- Gateway OpenAI Chat streaming Responses events must stay compatible with Codex CLI: accept Responses input message parts, emit output item/content part lifecycle events before text deltas, and include Responses-shaped usage totals in `response.completed`.

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
