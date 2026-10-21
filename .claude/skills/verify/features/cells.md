# Cells

**Reach.** Any notebook; `fixtures/ui-sweep.R` or `cells.R`. Code cells
need execution allowed: click "Run this notebook"
(`#ember-safe-preview button`) or run any one cell.

**Drive.**
- Edit: `setCellCode(page, id, code)`. The cell gets `.code_differs`,
  and "Save all changes" (`#saveall-container.ask_to_save`) appears.
- Run: `runCell(page, id)` (Shift+Enter) or the cell's run button
  (`button.ember-run`, shown on hover).
- Add: the "+" between cells (`button.add_cell.after` / `.before`).
- Show/hide code: `ember-cell-tools > button.ember-eye` (aria-label
  "Hide code", `aria-pressed` true while hidden), at the cell's top right
  next to the menu.
- Cell menu: `button.input_context_menu` (aria-label "Cell options")
  opens `div.input_context_menu[role=menu]`; items are
  `button[role=menuitem]` (Hide code, Disable, Delete, ...).
- Delete: from the cell menu; undo bar is `nav#undo_delete`.

**End state.** Output appears in the cell's `pluto-output`; `.running`
and `.queued` clear; the file on disk has the new code (read it); the
cell's chip matches its state (see run-state.md). Hidden code: the
input is gone and the same toggle brings it back (#287).
