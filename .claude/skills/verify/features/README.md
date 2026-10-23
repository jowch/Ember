# Feature map

One file per surface. Each says how to reach it, how to drive it, what a
correct end state looks like, and which e2e tests already cover it, so a
verification can start from there.

| Feature | File | Main tests |
|---|---|---|
| Cells: edit, run, add, delete, cell menu | [cells.md](cells.md) | cells, run-cell, add-delete-reload, keyboard |
| Outputs: tables, plots, errors, text | [outputs.md](outputs.md) | rich-outputs, error, markdown, text |
| Run state: safe preview, chips, header run button, save all | [run-state.md](run-state.md) | safe-preview, header, status-views |
| Side panel: Variables, Packages, Help, Status | [side-panel.md](side-panel.md) | panel-default, tabs, help-panel, packages-tab |
| Menus and dialogs: More, export, settings, shortcuts | [menus.md](menus.md) | export-menu, settings, shortcuts, delete-dialog |

Every surface also runs through `tests/ui-sweep.test.mjs` at 600/900/1440
px for generic layout problems.
