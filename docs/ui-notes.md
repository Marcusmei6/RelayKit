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
