# Update Policy

RelayKit updater status: planned, not implemented.

## Candidate

RelayKit will use Sparkle 2 for macOS updates after a real signed beta exists.

Policy:

- Update source: GitHub Releases.
- Channel: stable only.
- Feed: one signed Sparkle appcast for stable releases.
- Archive: the same signed/notarized release zip produced for GitHub Releases.
- UI: a Settings action for `Check for Updates`.
- Automatic check frequency: Sparkle default unless product needs a quieter cadence later.

No beta/stable split, phased rollout, custom updater UI, or forced update path is planned for P1.

## Hard Gates

Auto-update must stay disabled until all of these are true:

- `RelayKitApp.app` is Developer ID signed.
- The release artifact is notarized and stapled.
- The update archive has a Sparkle EdDSA signature.
- The app has the matching Sparkle public key in `Info.plist`.
- The appcast is signed and served over HTTPS from the GitHub Releases-backed stable feed.
- Local validation proves Sparkle refuses unsigned, ad-hoc, or mismatched updates.

Local ad-hoc zips must never enter the updater feed.

## Local Beta Behavior

Local beta builds should not show auto-update as ready. If a Settings entry exists before signed beta, it must say `Updates unavailable for local beta` and must not download or install anything.

## References

- Sparkle documentation: https://sparkle-project.org/documentation/
- Sparkle project: https://github.com/sparkle-project/Sparkle
