# Menus and dialogs

**Reach.** `header#pluto-nav button[aria-label="More"]` (More menu),
`button.toggle_export` (export), settings (`dialog.psettings`), the
shortcuts sheet (`dialog.ember-shortcuts`), confirmation dialogs
(`dialog.ember-dialog`).

**Drive.** Click to open; menus are `[role=menu]` with
`[role=menuitem]` items; Escape closes. Open each at 600 px as well as
1440.

**End state.** The menu or dialog is fully inside the viewport, nothing
in it is clipped (layout rules `off-screen`, `clipped`), focus moves
into it and back to the opener on close, and only one dialog is open at
a time.
