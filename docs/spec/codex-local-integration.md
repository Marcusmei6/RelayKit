# Codex Local Integration

RelayKit's first client integration is a safe local Codex configuration that points Codex at the loopback gateway.

## Example Config

Use `examples/codex.config.example.toml` as the public template. It is an example only and must not be written over a real user config by any automated command.

The template points Codex at:

- `base_url = "http://127.0.0.1:19777/v1"`;
- `wire_api = "responses"`;
- a fake local bearer token value;
- a placeholder model catalog path.

## Local Smoke Path

1. Start RelayKit from the gateway module:

   ```bash
   cd gateway
   go run ./cmd/gateway -listen 127.0.0.1:19777 -config ../examples/providers.example.json
   ```

2. In another terminal, verify:

   ```bash
   curl http://127.0.0.1:19777/healthz
   curl http://127.0.0.1:19777/v1/models
   ```

3. `/v1/responses` should be validated through gateway tests with fake upstreams. The public example provider file is loopback-only and does not start a real upstream.

## Activation Contract

A future config activation command must:

- require an explicit target config path;
- create a timestamped backup before writing;
- print the backup path and exact rollback command;
- refuse to overwrite a real config without backup success;
- never read, print, or persist real provider credentials.

The gateway package `internal/codexconfig` contains the minimal activation primitive for this contract. It has no default target path: callers must pass the destination config path explicitly.

## Not In This Slice

- automatic writing to `~/.codex/config.toml`;
- merging with a user's existing Codex config;
- model catalog generation;
- SwiftUI/AppKit UI;
- Keychain storage.
