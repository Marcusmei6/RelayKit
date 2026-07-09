# Public Boundary Checklist

Run this before any commit, public push, package handoff, or beta share.

## Private Provider Scan

```bash
PRIVATE_PROVIDER_PATTERN='cc''club|CC''CLUB|claude-code''\.club|Claude Code'' Club|relaykit\.provider\.cc''club'
rg -n \
  --glob '!dist/**' \
  --glob '!docs/private/**' \
  --glob '!scripts/private/**' \
  --glob '!**/.build/**' \
  --glob '!*.png' \
  "$PRIVATE_PROVIDER_PATTERN" \
  app gateway scripts docs examples .codex AGENTS.md README.md
```

Expected: no output. Ignored local private notes may still contain old proof history under `docs/private/` or `scripts/private/`; do not commit those files.

## Credential Shape Scan

```bash
rg -n \
  --glob '!dist/**' \
  --glob '!docs/private/**' \
  --glob '!scripts/private/**' \
  --glob '!**/.build/**' \
  --glob '!*.png' \
  'auth\.json|refresh token|access token|api[_-]?key|Bearer |sk-' \
  app gateway scripts docs examples .codex AGENTS.md README.md
```

Allowed hits:

- boundary rules and docs saying not to copy tokens or `auth.json`;
- fake validation strings such as `sk-secret-value`;
- implementation code that assembles an auth header from a reference;
- tests proving secrets are rejected or redacted.

Blocked hits:

- real API keys, bearer tokens, cookies, copied auth files, private provider URLs, or real Keychain item names.

## Git Hygiene

```bash
git status --short --ignored=matching
git diff --check
git ls-files docs/private scripts/private local-conversation-page-*.js local-conversation-thread-*.js remote-conversation-page-*.js
```

Expected: private/local artifacts are ignored or absent from tracked files.

## Public Proof Scripts

```bash
./scripts/full-merged-catalog-proof.sh
./scripts/codex-desktop-acceptance.sh
./scripts/menu-bar-e2e-smoke.sh
```

Expected: scripts use demo providers, loopback upstreams, isolated config, and `dist/` evidence. They must not write global `~/.codex/config.toml`, copy `~/.codex/auth.json`, bind `18787`, or print provider secrets.

## Package Readiness

```bash
./script/package_release.sh --verify
codesign -dvvv --entitlements :- dist/RelayKitApp.app
spctl -a -vv dist/RelayKitApp.app
```

Expected: package can be generated locally. Codesign/spctl may show ad-hoc or not notarized for local beta; that is a distribution blocker, not a local beta failure.

Publishing is blocked until every row has evidence.
