# Public Boundary Checklist

Run this before any commit, public push, package handoff, or beta share.

## Automated Gate

```bash
./scripts/public-boundary-check.sh
```

Expected: `RelayKit public boundary check passed`.

The script scans tracked files only and fails on private provider/domain references, credential-shaped content, tracked auth/log/usage artifacts, or ignored private/build paths that accidentally entered git.

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
if env -u RELAYKIT_SIGNING_IDENTITY -u RELAYKIT_NOTARYTOOL_PROFILE -u RELAYKIT_APPLE_TEAM_ID ./script/package_signed_release.sh; then
  echo "signed package unexpectedly succeeded without credentials" >&2
  exit 1
fi
test ! -f dist/github-release/v0.1.0/RelayKitApp-0.1.0-signed.zip
codesign --verify --deep --strict --verbose=4 dist/RelayKitApp.app
codesign -dvvv --entitlements :- dist/RelayKitApp.app
spctl -a -vvv -t exec dist/RelayKitApp.app
xcrun stapler validate dist/RelayKitApp.app
```

Expected: package can be generated locally. Codesign/spctl may show ad-hoc or not notarized for local beta; that is a distribution blocker, not a local beta failure.

The signed package command is expected to fail without Apple credentials and must print `missing Developer ID signing identity / notarization credentials`. It must not leave a signed artifact behind.

## GitHub Release Draft Shape

Signed beta release assets, once real Developer ID signing and notarization pass:

- `dist/github-release/v<version>/RelayKitApp-<version>-signed.zip`
- `dist/github-release/v<version>/RelayKitApp-<version>-signed.zip.sha256`

Do not publish Sparkle appcast metadata or advertise auto-update until the later updater phase is implemented after signed beta.

Publishing is blocked until every row has evidence.
