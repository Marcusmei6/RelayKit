# Install And Uninstall

## Local Beta Install

Build and verify the local package:

```bash
./script/package_release.sh --verify
```

Then unzip `dist/RelayKitApp-local.zip` and open `RelayKitApp.app`. This package is ad-hoc signed only for local bundle integrity; it is not Developer ID signed or notarized, so Gatekeeper friction is expected.

## Signed Beta Install

Signed beta packages will use the same app bundle layout and reserved bundle id:

- Bundle ID: `dev.relaykit.app`
- App bundle: `RelayKitApp.app`
- Signed artifact: `RelayKitApp-<version>-signed.zip`

The current signed beta candidate is `dist/github-release/v0.1.0/RelayKitApp-0.1.0-signed.zip`. It is Developer ID signed, notarized, stapled, and Gatekeeper accepted. Unzip that artifact and open `RelayKitApp.app`; do not distribute the local ad-hoc zip as a signed beta. The public GitHub Release is still unpublished.

## Uninstall

1. Quit RelayKit from the menu-bar app.
2. Remove `RelayKitApp.app`.
3. If you installed the optional local helper, run:

```bash
./scripts/relaykit-helper.sh uninstall
```

4. Optional local state cleanup:

```bash
rm -rf "$HOME/Library/Application Support/RelayKit"
```

RelayKit validation and packaging must not modify global Codex config/auth files, shared `agent-local-gateway` services, or unrelated LaunchAgents.
