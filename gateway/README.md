# RelayKit Gateway

The gateway is a local loopback HTTP helper. It provides client-facing OpenAI-compatible surfaces and routes requests to configured upstream providers.

Current local alpha:

- `GET /healthz`
- `GET /v1/models`
- `POST /v1/responses`
- provider loading from explicit JSON config files;
- OpenAI Chat-compatible upstream translation;
- Anthropic Messages upstream translation, including non-streaming `tool_use` to Responses `function_call`;
- text streaming for OpenAI Chat-compatible and Anthropic Messages providers;
- local usage JSONL writes and day/provider/model summary.

## Build And Run

```bash
go test ./...
go vet ./...
test -z "$(gofmt -l .)"
go build -o bin/relay ./cmd/gateway
./bin/relay -listen 127.0.0.1:19777 -config ../examples/providers.example.json
```

## Local Usage Summary

```bash
./bin/relay summarize-usage -path "$HOME/Library/Application Support/RelayKit/usage.jsonl"
```

The summary command reads local JSONL only and emits day/provider/model aggregates.

## Public Boundary

Example configs must stay fake and public-safe. Provider credentials are references only: legacy configs may use `auth_env`, and new configs may use `credential_ref.kind = "env"`, `"key_file"`, or `"keychain"` in the gateway runtime. Config files must never contain credential values.
