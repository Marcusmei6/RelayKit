# Gateway Agent Rules

The gateway is the portable engine. Keep it headless, testable, and free of Apple UI concerns.

## Responsibilities

- Local HTTP server.
- `/healthz`, `/v1/models`, `/v1/responses`.
- Request/response adapters between public API formats.
- SSE translation.
- Model catalog generation.
- Local usage event logging.

## Public Boundary

- Only public provider examples are allowed.
- Secrets must enter through runtime config, environment, or OS keychain plumbing owned by the app.
- Tests must use fixtures with fake model names and fake keys.

## Verification

Run:

```bash
go test ./...
```

