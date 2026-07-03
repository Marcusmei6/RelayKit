# UI Notes

UI implementation is active for the P0 menu-bar control center.

Use Open Design `relay` as visual direction, then keep only public-safe product behavior:

- menu bar first;
- small popover/control-center, not a dashboard window;
- tabs `接入`, `Usage`, and `设置`;
- focused provider list;
- add/edit provider sheet;
- active route status;
- gateway health and logs;
- no dashboard bloat in the first release.

Avoid copying CC Switch's all-in-one control panel scope. RelayKit should feel lighter and more native.

Do not ship fake toggles or mock usage cards. Hide unfinished settings, or mark future targets like Claude Code disabled until wired.

## Replay/Kaboo Conformance Repair

The current product surface is intentionally menu-bar only:

- visible compact status item with a short icon footprint;
- click opens an anchored `NSPopover`, not a standalone dashboard window;
- global header keeps RelayKit identity, gateway state, port, model count, and Codex state visible across every tab;
- `接入` focuses on CLI route selection, gateway actions, and provider/model list;
- `Usage` presents real local summary KPIs first and keeps the usage JSONL path behind a secondary control;
- `设置` presents real wired actions as cards and keeps raw paths behind an Advanced disclosure;
- provider add remains a modal overlay inside the popover for complex configuration;
- `scripts/menu-bar-e2e-smoke.sh` now writes evidence JSON for each captured state and fails if the popover is not anchored, the status item is not visible, expected semantic sections are missing, or RelayKit-owned smoke processes are left behind.

OpenDesign project `replay` was not available through the local OD tools during the repair pass, so the local `relaykit-gateway-popover.html` artifact was used as the visual reference. Do not commit that artifact or generated OD images unless a future task explicitly asks for a scrubbed design asset handoff.
