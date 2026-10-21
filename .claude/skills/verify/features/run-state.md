# Run state

**Reach.**
- Safe preview: open any notebook; `#ember-safe-preview` banner with
  "Run this notebook". No cell shows a chip.
- Partly run: run one cell (`runCell`), then `page.reload()`. Cells that
  haven't run show an `ember-chip` "Not run yet"; the header shows a
  `header#pluto-nav button.ember-btn` "Run N not run".
- Edited: edit a cell without running it; `#saveall-container` shows
  "Save all changes" with ⌘ S or Ctrl+S (`emulatePlatform`).
- Stale: a cell whose result is out of date shows a clock chip
  (`format_stale_chip` in `components/Cell.js`); `status-views.test.mjs`
  shows how to get there.

**End state.** Every cell in the same state shows the same chip, the
first cell included (#284, layout rule `cell-mismatch`). The header's
run button count matches the chips. "Save all changes" sits inside the
viewport and its label inside its box with both shortcut labels at 600,
900 and 1440 px (#290). `#ember-r-status` reads "R ready" when idle.
