# Roadmap

## Milestone 0: Public Project Skeleton

- Create repository and docs.
- Add minimal Go gateway that compiles and serves placeholder endpoints.
- Define open-source boundary.
- Write development plan and handoff.

## Milestone 1: Gateway Contract

- Define provider profile schema.
- Load providers from `providers.json`.
- Generate model catalog JSON.
- Add OpenAI-compatible Chat adapter behind tests.
- Add deterministic non-streaming `/v1/responses` translation test.

## Milestone 2: Streaming

- Translate Chat Completions SSE into Responses-style SSE.
- Preserve usage tokens when upstream includes usage.
- Add malformed stream and upstream failure tests.

## Milestone 3: Anthropic Adapter

- Add Anthropic Messages request transform.
- Add Anthropic streaming transform.
- Map tool-use and stop reasons.

## Milestone 4: Mac App Shell

- SwiftUI menu bar app.
- Start/stop gateway helper.
- Store secrets in Keychain.
- Add provider CRUD.
- Activate/deactivate client config.

## Milestone 5: Local Observability

- Local JSONL usage events.
- Usage summary endpoint.
- Log tail in app.
- Health/status page.

