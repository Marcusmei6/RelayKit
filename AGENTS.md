# RelayKit Agent Rules

RelayKit is intended to become a public open-source project. Keep the repository clean enough to publish at any time.

## Non-Negotiable Boundary

- Do not commit private provider names, internal domains, JWTs, API keys, cookies, local auth files, private launch agents, or copied user logs.
- Checked-in `.codex/agents/` model IDs must stay public-safe. Private/local routing belongs only in untracked machine-local overrides.
- Do not copy code from the local private gateway binary or private configuration. Rebuild public behavior from the public contract and tests.
- Keep provider integrations public by default. Private adapters belong outside this repository.
- Prefer small, boring changes. Do not add framework scaffolding for features not in the current milestone.

## Shared Runtime Verification Boundary

- Validation must not seize shared runtime services. Treat `127.0.0.1:18787`, `com.meihang.agent-local-gateway.*`, `~/.codex/config.toml`, `~/.codex/auth.json`, and any `~/Library/LaunchAgents/*` entry as global shared resources, not as RelayKit's private sandbox.
- RelayKit verification must use isolated ports such as `127.0.0.1:18790` or `127.0.0.1:19777`, with processes started and stopped by the verification itself. Do not modify `~/.config/agent-local-gateway/codex-model-catalog.json` or another client's config for a local RelayKit smoke.
- Codex Desktop cutover validation must use an isolated profile and isolated `CODEX_HOME`/config. Do not modify the global `~/.codex/config.toml` for RelayKit validation, and do not set the global `model` to RelayKit/private model IDs.
- Taking over `18787` is a planned cutover, not a validation shortcut. Before doing it, get explicit user confirmation, state what will change, who is affected, and the rollback path, then stop clients, sync all configs/catalogs, verify the complete model set end to end, and roll back immediately on any failure.
- Before any operation touching shared services or launch agents, write the intended change, expected impact, and rollback command in the response and wait for confirmation.

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
