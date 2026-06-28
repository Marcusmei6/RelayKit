# RelayKit Agent Rules

RelayKit is intended to become a public open-source project. Keep the repository clean enough to publish at any time.

## Non-Negotiable Boundary

- Do not commit private provider names, internal domains, internal model IDs, JWTs, API keys, cookies, local auth files, private launch agents, or copied user logs.
- Do not copy code from the local private gateway binary or private configuration. Rebuild public behavior from the public contract and tests.
- Keep provider integrations public by default. Private adapters belong outside this repository.
- Prefer small, boring changes. Do not add framework scaffolding for features not in the current milestone.

## Architecture Direction

- `app/` is the Apple-native shell: SwiftUI/AppKit UI, Keychain, LaunchAgent, helper lifecycle.
- `gateway/` is the portable local gateway helper: HTTP server, protocol adapters, model catalog, usage events.
- `docs/` is the product and engineering source of truth.
- `examples/` contains safe public sample config only.

## Verification

- Gateway changes need `go test ./...`.
- Documentation-only changes need a link/path sanity check.
- Any change touching config or credentials must include a redaction review before completion.

