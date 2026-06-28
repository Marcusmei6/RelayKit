# RelayKit Agent Rules

RelayKit is intended to become a public open-source project. Keep the repository clean enough to publish at any time.

## Non-Negotiable Boundary

- Do not commit private provider names, internal domains, JWTs, API keys, cookies, local auth files, private launch agents, or copied user logs.
- Local development agent routing may mirror the private Iris model split in `.codex/agents/` while this repository is private on this machine. Before publishing or pushing to a public GitHub repository, replace those model IDs with public defaults and record the scrub in `docs/handoff.md`.
- Do not copy code from the local private gateway binary or private configuration. Rebuild public behavior from the public contract and tests.
- Keep provider integrations public by default. Private adapters belong outside this repository.
- Prefer small, boring changes. Do not add framework scaffolding for features not in the current milestone.

## Architecture Direction

- `app/` is the Apple-native shell: SwiftUI/AppKit UI, Keychain, LaunchAgent, helper lifecycle.
- `gateway/` is the portable local gateway helper: HTTP server, protocol adapters, model catalog, usage events.
- `docs/` is the product and engineering source of truth.
- `examples/` contains safe public sample config only.
- `.codex/agents/` contains project-scoped RelayKit development agents. See `docs/agents/README.md`.

## Workflow

- Non-trivial project work starts with `relaykit_planner`.
- Implementation goes to bounded specialist lanes: `relaykit_gateway`, `relaykit_app`, or `relaykit_worker`.
- Validation goes to `relaykit_test`; review goes to `relaykit_cr`; packaging/release scope goes to `relaykit_release`.
- If the planner cannot spawn specialists, it must emit `PARENT DISPATCH REQUIRED` with exact assignments for the parent/root session.
- Specialist assignments must include WORKTREE, BRANCH, PLAN, OWNED PATHS, BLOCKED PATHS, Change Risk Tier, Validation Tier, CR Tier, and STOP CONDITIONS.

## Verification

- Gateway changes need `go test ./...`.
- Documentation-only changes need a link/path sanity check.
- Any change touching config or credentials must include a redaction review before completion.
