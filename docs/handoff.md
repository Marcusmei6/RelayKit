# RelayKit Handoff

## Current State

The repository has been initialized as a public-safe skeleton. It contains docs, ownership rules, public examples, and a minimal Go gateway placeholder.

Current verification on the initializing machine:

- File/path sanity check passed.
- Private-string quick scan passed for known local internal keywords.
- `go test ./...` was not run because `go`/`gofmt` are not installed on this machine's PATH.

## Important Decisions

- Project name: RelayKit.
- Public scope: local model routing kit for agentic coding tools.
- First client target: Codex compatibility.
- UI direction: Apple-native SwiftUI/AppKit shell, deferred until gateway contract stabilizes.
- Gateway direction: Go helper, not Swift.
- Open-source boundary: no private adapters, internal model IDs, internal URLs, tokens, or copied local gateway implementation.

## Next Workstream

Start with Phase 1 from `docs/development-plan.md`:

1. Define provider profile schema.
2. Load `examples/providers.example.json`.
3. Generate catalog from public profiles.
4. Add OpenAI-compatible Chat adapter behind tests.
5. Keep the app directory documentation-only until the gateway contract is real.

## Suggested First Agent Assignment

Implement Gateway MVP only. Do not start SwiftUI yet.

Acceptance:

- `go test ./...` passes.
- Gateway loads a public example provider file.
- `/v1/models` returns configured model IDs.
- Non-streaming `/v1/responses` can call a fake upstream in tests and return Responses-shaped JSON.
