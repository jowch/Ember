# UI, increment 3: implementation plan

Increment 3 gives Ember its own design, decided with the user in
[ui-3.md](ui-3.md): Sage colours and its own fonts, a left-aligned column
with a docked side panel, rails and chips on cells, text cells written as
`#'` lines, fixed figure sizes, notebooks created and moved from the
browser, and Pluto's "errors flow downstream" rule. This document plans how
to build it. Tests are listed in [ui-3-tests.md](ui-3-tests.md) and cited
here by number.

It is ten branches. Engine work comes first, then the frontend. Each
branch ends in something that runs, with CI green; an engine branch that
changes what the page receives includes the minimal page change, and the
restyle comes later.

1. **Piece 1a, errors flow downstream**: dependents of a failed cell run
   and fail on their own; no blocked state.
2. **Piece 1b, Disable cell**: a disabled cell and its dependents are
   skipped and written commented out; disabled cells define nothing.
3. **Piece 2, text cells and inline r**: `#'`-only cells are text;
   `` `r expr` `` runs reactively; mixed cells are an error with Split;
   function docstrings in Help.
4. **Piece 3, figures and Variables data**: fixed figure sizes from `#|`
   lines; each cell reports its globals' types and short values.
5. **Piece 7a, shared dialogs and menus**: `ask`/`tell` in-page dialogs and
   a keyboard menu hook, which the later frontend branches build on.
6. **Piece 4, notebooks and packages from the browser**: start page,
   create, rename or move, recent list, Packages Update, real install
   errors.
7. **Piece 5, identity and layout**: tokens, fonts, column, header, side
   panel and its tabs, theme switching.
8. **Piece 6a, cell chrome**: rail, run/stop, cell menu, "+", chips, empty
   notebook, disabled states; argument tooltips close when the cursor
   leaves their cell (the old gap list).
9. **Piece 6b, errors, outputs and text cells**: error box and traceback,
   tables, trees, console, ANSI palette, figures, text-cell editing.
10. **Piece 7, menus, settings, shortcuts, accessibility, wording**: Export
   menu, Settings, shortcuts sheet, F1, keyboard path, names, wording
   sweep, dead-code deletion; MathJax loaded only when a cell has TeX
   (the old gap list).

See [Order of implementation](#order-of-implementation) for why.

## Rules every piece follows

- **Pluto's fields stay filled.** Endeavor's page script reads
  `process_status`, `status_tree` and `nbpkg` from `window.editor_state`
  (endeavor/frontend/src/status.ts:20-22, drawer.ts:218), and error bodies'
  `msg`, `stacktrace` and `plain_error` (errors.ts:71-100). Ember's own data
  is added beside them, never in their place. Pluto fields that Ember now
  fills for real (`metadata.disabled`, `depends_on_disabled_cells`) keep
  Pluto's meaning.
- **Ember's additions** go in the top-level `ember` map, the per-cell
  `cell_results[id].ember` map, new fields on `cell_inputs[id]`, or new
  output-body fields prefixed `ember_` (as increment 2's `ember_dims`).
  Data about one cell goes in that cell's `ember` map, so a run patches
  only that cell. The projection stays a pure function of the state, and
  `pluto_edits()` still refuses client patches to `cell_inputs` fields
  other than `code`, `code_folded` and, from piece 1, `metadata.disabled`.
- **New page requests are named `ember_*`** (Pluto's own `completepath` is
  the one exception, piece 4), and each gets a row in the request table
  (server.R:637-666).
- **New worker messages, and new fields on existing ones, land on both
  sides in one commit.** The shell turns an unknown worker message type
  into `wk_failed`, and the poll then kills the worker (shell.R:685-697,
  551-564). The worker ignores unknown server messages (worker.R:194), but
  both sides still change together.
- **Kept as they are**: the DOM hooks Endeavor reads (`pluto-cell[id]`,
  `pluto-input .cm-content`, `button.add_cell.before/.after`,
  `pluto-output`, `.code_differs`, `.selected`, `header#pluto-nav`,
  `main pluto-notebook`, `pluto-trafficlight`, `jlerror > header`,
  `pluto-shoulder > button.foldcode`, `#helpbox-wrapper`, `pluto-helpbox`,
  `#live-docs-search`, the `open_bottom_right_panel` event), every CSS
  variable name in `themes/light.css` and `themes/dark.css` (Ember's new
  values are `--ember-*` tokens that the kept names point at),
  `window.editor_state` and `selected_cells`, and the URLs `/edit`,
  `/notebookfile`, `/notebookexport`.
- **No native pop-ups.** After piece 7a no new `alert()` or `confirm()` is
  added; dialogs use `ask`/`tell`, menus use `useMenu`.
- **Strings go through `lang/english.json`**, worded as board Words6 says.
  A piece that rebuilds a surface owns its strings; piece 7 checks the rest.
- R code is ASCII only (`"\u00d7"` for ×); man pages are hand-written;
  code comments only for constraints.

---

## 1. Errors flow downstream, and Disable cell

One branch, two parts: errors flow downstream (steps 1-5), then Disable
cell (steps 6-9), which ui-3.md lists in the cell menu and which the user
decided to build now. About 450 changed lines of R, 15 in the worker and
100 in the page, plus about 600 lines of tests. One worker message is added
(`drop_globals`); no page request is added.

### Problem

**Errors.** Today a cell whose ancestor failed never runs. `can_run()`
refuses it (step.R:256-277, using `failed_blockers()`, step.R:279-296), and
`reduce_wk_done()` takes the failed cell's dependents out of the queue
(`drop_downstream()`, step.R:404-415, called at step.R:1053-1055).
`reduce_run()` returns them in `skipped` (step.R:643-646). The view carries
the reason twice: `blocked` (a graph error on the cell or an ancestor,
state.R:330-335) and `blocked_by` (the failed ancestor, state.R:337-343).
The page shows a dimmed cell with an "upstream error" label and a run
button that jumps to the failed cell (Cell.js:73-76, 245-254, 353-354;
editor.css:1751-1770, 1798, 1812). `not_run_ids()` leaves both kinds of
blocked cell out of "N cells not run" (state.R:533-549).

A failed cell also keeps what it defined before it failed: the worker
records `owned[[cell]] <- facts$created` whatever the status
(worker.R:412-416), so after `a <- 1; stop("boom")` the `a` stays. The
server's own run errors (a changed foreign global, a global setting;
step.R:996-1010) come from runs the worker reported as "ok", so everything
those cells created stays too.

ui-3.md (Cells; Engine change 1) decides the opposite, as Pluto does:
dependents run and fail on their own, the failed cell's variables are
removed, and the page shows "Another cell defining **x** contains errors."
with **x** linking to that cell.

**Disable.** Ember can't disable a cell. The page has the parts: Cell.js's
`set_cell_disabled` (Cell.js:232-241) patches `metadata.disabled` and then
runs the cell, as Pluto does; editor.css dims `running_disabled` and
`depends_on_disabled_cells` cells (editor.css:1751-1776). But the server
refuses the patch (pluto-edits.R:87 allows only `code` and `code_folded`),
the projection sends one shared `CELL_METADATA` with `disabled = FALSE`
(pluto-state.R:19, 181), the file has nowhere to put the mark (the
cell-order footer reads only `folded`, notebook.R:290), and the scheduler
has no idea of it (step.R:256-277).

### What the user sees

Errors:

- A cell that fails no longer stops its dependents. In autorun the
  dependents that had run before rerun; those that use what the failed
  cell defined fail with "Another cell defining **a** contains errors."
  (several names: "**a** or **b**"). Clicking a name scrolls to the cell
  that defines it. No traceback is shown for this error; R's own message
  is kept in `plain_error` for copying.
- In lazy mode the dependents are marked stale, as after any run.
- A dependent that doesn't need the failed cell (it uses `a` only inside a
  function body, say) runs normally.
- The "upstream error" label, the dimming and the jump button are gone.
  A dependent is up to date, stale, not run, or errored, like any cell.
- Running a cell whose ancestor failed runs the ancestor again first (a
  failed result is never fresh), then the cell.
- Cells below a graph error (two cells defining `x`, a cycle, a syntax
  error) also run, and fail with the same wording if they use the broken
  cell's names, but only when the user asks: a run, "Run N not run", or
  autorun after a run the user made. An edit alone runs nothing; the
  broken cell's dependents are marked stale, not queued. The broken cell
  itself still can't run and shows its own error.
- "N cells not run" counts cells below a failed or broken cell, so "Run
  all" can bring it to zero. Cells with their own graph error are left
  out.
- A failed cell's `library()` attachments stay; only its variables go.
- R API: `run_cells()`'s `skipped` lists cells with a graph error of their
  own, text cells, and disabled cells and their dependents. The snapshot's
  `blocked` and `blocked_by` fields are removed.

Disable cell:

- The cell menu has "Disable cell" on every code cell except the setup
  cell; on a disabled cell it reads "Enable cell". Text cells don't have
  it.
- Disabling runs nothing. The cell and the cells that depend on it are
  dimmed and keep their last output. Their variables and attached packages
  are removed from R, as if the cells were deleted.
- A disabled cell does not count as defining its variables (as Pluto).
  Disabling one of two cells that define `x` clears "Multiple definitions";
  cells that read `x` then depend on the enabled definer and are not
  affected. A cell that reads a name only a disabled cell defines depends
  on the disabled cell and is switched off with it.
- Running a disabled cell or a dependent does nothing; "Run all" skips
  them; "Run N not run" doesn't count them.
- Enabling the cell runs it, as in Pluto. In autorun its dependents that
  had output rerun after it; in lazy mode they turn stale; dependents that
  never ran stay "Not run yet".
- A disabled cell's code can still be edited; the edit is saved and not
  run. In safe preview, disabling or enabling changes the file and the
  page and does not start R.
- In the `.R` file, the disabled cell and its dependents are written with
  `## ` before each line, so `Rscript notebook.R` runs the rest without
  errors. Packages used only in disabled cells stay installed and locked.
- R API: a new op `disable_cell(cell, disabled = TRUE)` for
  `edit_notebook()`; the snapshot gains `disabled` and `disabled_by`.

### Shape

**Rules touched.** Pluto's `depends_on_disabled_cells` and
`metadata.disabled` are now filled for real. The per-cell `ember` map loses
`blocked_by` and gains `upstream_error`, `disabled_by` and `can_disable`.
One worker message, `drop_globals`, on both sides in one commit. No
`ember_*` request. `pluto-cell` loses the `upstream_error` class; Endeavor
reads neither it nor `blocked`/`depends_on_disabled` (grep of
endeavor/frontend/src and endeavor/src).

#### 1a. Errors flow downstream

**Worker: `drop_globals`.** A server-to-worker message,
`list(type = "drop_globals", cell)`, with one line in `handle_next()`'s
switch (worker.R:172-195) and one in the protocol comment (worker.R:28-38).
No reply.

```r
#' Remove a failed cell's globals, keeping what it attached to the search
#' path (unlike remove_cell(), which also detaches and drops display data).
drop_globals <- function(cell) {
  globals <- owned[[cell]]
  if (length(globals)) {
    existing <- intersect(globals, ls(globalenv(), all.names = TRUE))
    if (length(existing)) rm(list = existing, envir = globalenv())
  }
  owned[[cell]] <<- character()
}
```

The engine decides when to drop, so one rule covers errors the worker
reports and errors only the server detects (`multiple_definitions` from a
changed foreign global and `global_setting`, step.R:996-1010).

**Engine (step.R).**

- `reduce_wk_done()` (step.R:939-1059): after the result is stored, if its
  status is not "ok", add `fx_send(gen, list(type = "drop_globals", cell =
  id))`. `step()` puts `reduce()`'s effects before `schedule()`'s
  (step.R:135), so the worker drops the globals before the next `run`.
  Then:
  - `"error"`: `invalidate_dependents(state, id, report$created)`, as the
    "ok" branch does (step.R:1052). Autorun queues the dependents that had
    a result; lazy marks them stale.
  - `"interrupted"`: `drop_downstream()` as today. An interrupt means
    "stop", and `reduce_interrupt()` has already emptied `pending`
    (step.R:653).
- **The upstream error kind.** In `reduce_wk_done()`, when the error kind
  is `"error"` (a plain R error, not `missing_package` or
  `source_conflict`):

  ```r
  #' The cells `id` reads from (by a "definition" or "package" edge, not
  #' "setup") whose last result failed or that have a graph error, with
  #' the names read: list(names = <chr>, cells = <chr, aligned>), or NULL.
  failed_definers(state, id)
  ```

  It reads `state$graph$edges` rows with `from == id` and `via %in%
  c("definition", "package")` (graph.R:26-29). A "definition" edge counts
  when `to` has `results[[to]]$status %in% c("error", "interrupted")` or is
  in `blocked_cells(graph)`. A "package" edge counts only when `to`'s last
  error kind is `"missing_package"`: `drop_globals()` keeps a failed cell's
  attachments, so a plain error on a cell that already attached its
  package still provides every name it exports, and a dependent's own
  unrelated error on one of those names is the dependent's own bug, not an
  upstream one. Only direct edges count: a chain gives a chain of messages,
  each linking one step up, as in Pluto. Duplicate names (two cells both
  defining `x`) keep one entry, the first definer in display order. If
  non-empty, the error becomes `new_run_error("upstream", message = <R's
  message>, traceback, names = fd$names, cells = fd$cells)`;
  `new_run_error()` (state.R:227-231) gains `cells = character()`. The
  setup edge is left out: an error in the setup cell has no name to show,
  so cells failing after it show their own R error.

  The rule is decided when the run ends, not each time the page draws (as
  Pluto's `get_erred_upstreams()`, ErrorMessage.js:644, does). R's "object
  'a' not found" has no condition class (R 4.6.1: `simpleError`) and its
  text is translated, so matching the message would break in other
  locales. The edge rule needs neither, and also covers a missing name that
  falls through to a package function (`df` resolving to `stats::df`).
- **`can_run()`** (step.R:256-277) becomes: the cell exists, is code (piece
  2 makes this `cell_runs()`), is not in `blocked_cells(state$graph)`, and
  is not off (1b). The downstream-of-blocked walk and the
  `blocked_by_failed` argument go; `failed_blockers()` is deleted, and its
  callers lose the argument: `schedule()` (step.R:212, 232, 239) and
  `reduce_run()` (step.R:643-644).
- **Graph-error cells lose their globals too.** A cell that ran and then
  gained a graph error (an edit made `x` defined twice, or a learned
  definition did, test-step.R:274-284) still holds its result, and the
  worker its globals. Now that cells below it can run, that matters. In
  `schedule()`, once a cell has been chosen to send (after the queue loop,
  step.R:242), a pure helper runs first:

  ```r
  #' For every cell in blocked_cells(graph) that still has a result: drop
  #' the result, mark its dependents stale (invalidate_dependents(...,
  #' queue = FALSE): nothing is queued, as for an edit), and send
  #' drop_globals. Returns list(state, effects); a no-op when there are none.
  drop_graph_error_results(state)
  ```

  Its effects go before the `run` message. It runs only when something is
  about to run, so an edit alone changes nothing in the worker (engine.md,
  Decisions: "an edit never runs anything"), and it is idempotent. The cell
  shows its graph error, which `project_output()` puts first
  (pluto-state.R:298-306).
- `drop_downstream()` (step.R:402-415) stays, called only for
  `"interrupted"`. Its doc and `can_run()`'s lose the "dependents of a cell
  that errored don't run" wording.

**View and snapshot (state.R).**

- `view_context()` (state.R:316-374): delete `blocked_direct`,
  `blocked_down`, `blocked`, `fblocked` and `blocked_by` (state.R:330-343)
  and their returned fields. `cell_view()` (state.R:378-416) loses `blocked`
  and `blocked_by`. `errors_by_cell` already says which cells have their
  own graph error.
- `not_run_ids()` (state.R:533-549): the two `blocked` checks
  (state.R:544-545) become `if (!is.null(ctx$errors_by_cell[[i]])) next`;
  1b adds the off check. The doc (state.R:522-532) says so.
- `snapshot_of()`'s doc (state.R:257-275) drops the two fields.

**Projection (pluto-state.R).**

- `cell_key()` and `key_unchanged()` (pluto-state.R:139-170) drop
  `blocked` and `blocked_by`. The upstream error lives in `result`, which
  the key already holds.
- `project_cell_result()` (pluto-state.R:205-218): `ember` gains
  `upstream_error`, absent unless the last error's kind is `"upstream"`,
  then `as_arr(list(list(name = "a", cell = "<id>"), ...))`. The doc
  (pluto-state.R:183-204) is updated.
- `project_error()` (pluto-state.R:424-436): kind `upstream` gives
  `msg = "Another cell defining a contains errors."` (names joined with
  "or": `join_names()`, pluto-state.R:403-407, gains `conj = "and"`),
  `stacktrace = list()`, and `plain_error = paste(msg, <R's message>, sep =
  "\n")`.

**Page (minimal; piece 6 restyles the error box).**

- Cell.js: delete `upstream_error` and the label branch (Cell.js:69-76;
  `code_changed` and `stale` stop checking it) and the `upstream_error`
  class (Cell.js:276). The jump (`upstream_error_jump`, Cell.js:245-254,
  passed as `on_jump`, Cell.js:353-354) is repointed from `blocked_by` to
  `ember.disabled_by` and renamed `disabled_jump`; it dispatches
  `cell_focus` to that id. `jump_title` is dropped, so RunArea shows its
  default `t_jump_cell` ("This cell depends on a disabled cell",
  english.json:219). Until 1b fills `disabled_by`, nothing reaches it.
- Notebook.js:52 and :84: stop passing `blocked_by`. Editor.js:187: the
  `ember` typedef becomes `{ stale, code_changed, upstream_error?:
  {name, cell}[], disabled_by?: string, can_disable: boolean }`.
- ErrorMessage.js: the Julia `UndefVarError` rewriter (ErrorMessage.js:
  475-514) is replaced by an Ember one with pattern
  `/^Another cell defining /`. It reads
  `cell_results[cell_id].ember.upstream_error` and renders
  `th("t_another_cell_defining_xs_contains_errors", ...)` (english.json:85,
  kept) with one link per name; each link scrolls to
  `pluto-cell[id='<cell>']`, as the deleted rewriter did
  (ErrorMessage.js:497-503). It sets `show_stacktrace: () => false`.
  Without the map it shows `msg` as text. `get_erred_upstreams()`
  (ErrorMessage.js:644-) has no other caller and goes.
- english.json: delete `t_ember_label_upstream_error` (line 28) and
  `t_jump_cell_blocked_by_error` (line 220).
- editor.css: delete the `pluto-cell.upstream_error` selectors
  (editor.css:1755-1770, 1798, 1812-1815). The `depends_on_disabled_cells`
  and `running_disabled` selectors (editor.css:1751-1776) stay for 1b.

**Docs.** engine.md: the rule list (line 20), "Blocked" (line 121), the
invalidation paragraph's "upstream error" (line 134) and the Decision at
line 216 now say "Dependents of a failed cell run anyway (as Pluto); a
failed cell's globals are removed". cell-graph.md:74: `blocked_cells()` is
"cells with a graph error (they can't run)". ui.md:143 and ui-2.md:1046,
1076-1078 get "replaced in increment 3, piece 1". api.R:229-232:
`skipped` as above.

#### 1b. Disable cell

**Disabled cells don't define anything; the graph knows them.**
`notebook_graph()` (graph.R:125) gains `disabled = character()`, the ids of
disabled cells, stored as `graph$disabled`. Every cell is still analysed
from its full code (`code_of()`, state.R:573-576, is unchanged), so the
graph still knows what a disabled cell would define, read and attach:
`graph$cells[[id]]` is unchanged, and `wanted_packages()` (resolve.R:155)
still sees its packages, which keeps them installed and locked. What
changes:

- `resolve_edges()` (graph.R:265) leaves disabled cells out of
  `definer_lookup` and `attachers`, so they satisfy no reference. A
  reference `n` of cell `b` now resolves in this order:
  1. enabled cells defining `n`: `via = "definition"`;
  2. else enabled cells attaching a package that exports `n`:
     `via = "package"` (an enabled package export wins over a disabled
     global definer, the same shadowing order as two enabled candidates);
  3. else disabled cells defining `n`: `via = "disabled"` (what `b` would
     read if they were enabled);
  4. else disabled cells attaching such a package: `via = "disabled"`.

  Rules 3-4 are skipped for the setup cell: a name only a disabled cell
  would provide is left unresolved there, as any other unknown name is,
  rather than ever marking the setup cell itself off (which would take the
  whole notebook with it, since every other cell depends on it).

  A disabled cell's own references still resolve as above, so it keeps its
  edges to what it reads.
- `upstream`/`downstream` include the `"disabled"` edges, so walks, the run
  order and the file order treat a disabled cell like any other:
  `compute_order()` keeps it before its readers whether or not it is
  disabled, and toggling never moves cells in the file.
- `find_errors()` (graph.R:390) leaves disabled cells out of every rule
  except `parse` (the user still sees that the code is broken):
  `multiple_definitions` and `private_name` don't count their names,
  `global_setting` skips them, and cycles are found on the components of
  the graph without `"disabled"` edges (`scc_components()` runs a second
  time on those lists only when some cell is disabled; `compute_order()`
  keeps the components with them). So disabling one of two cells that
  define `x` clears the error, and a cycle that runs through a disabled
  cell is not one.
- A new field, the **off set**:

  ```r
  #' Disabled cells and every cell downstream of them, through any edge
  #' (Pluto's depends_on_disabled_cells). None of them runs, and the code
  #' cells among them are written commented out. Named character vector:
  #' off id -> the disabled cell it comes from. A disabled cell maps to
  #' itself; a dependent to the first disabled cell, in display order,
  #' whose downstream walk reaches it. Empty when nothing is disabled.
  graph$off
  ```

  Computed at build time: for each disabled cell in display order, walk
  `downstream` and assign unassigned cells. Since disabled cells satisfy
  no reference, the only edges into one are `"disabled"` edges, so a cell
  is off exactly when it needs a name that only an off cell provides. A
  cell that reads `x` from an enabled definer is not off, even when a
  disabled cell also defines `x`. Off is closed downward, so an ancestor
  of a cell that can run is never off.
- `graph_learn()` (graph.R:218) passes `disabled = graph$disabled`.
  `rebuild_graph()` (step.R:429-440), `check_state()` (state.R:582) and
  `new_state()` (state.R:125) pass `disabled_ids(state$cells)`, a one-line
  helper next to `code_of()`; api-packages.R:101 passes the file's.
- Docs: cell-graph.md gets the `"disabled"` edge kind, the `off` field and
  the rule "disabled cells define nothing". graph.R's field list (graph.R:
  7-45) likewise.

Because the graph is rebuilt on every edit (step.R:431) and toggling is an
edit, everything below reads `state$graph$off`; nothing else recomputes it.

**State.** `state$cells[[id]]` becomes `list(code, kind, folded,
disabled)`. Every constructor sets `disabled = FALSE`: the parser's
`flush_cell()` (notebook.R:412), `new_notebook()` (api.R:93-94), the insert
op (step.R:540-541). The doc at state.R:48 is updated. `check_state()`
(state.R:579) also checks that no off cell is in `pending`.

**Edit op.**

```r
#' @export
disable_cell <- function(cell, disabled = TRUE) {
  structure(list(op = "disable", cell = cell, disabled = disabled),
            class = "ember_op")
}
```

Next to `fold_cell()` (api.R:203-206), exported in NAMESPACE, documented in
man/edit_notebook.Rd beside `fold_cell`. A `reduce_apply()` branch beside
`fold` (step.R:565-570): an unknown cell is refused as for `fold`; the
setup cell is refused ("the setup cell can't be disabled; empty it
instead"), since disabling it would switch off every cell; a text cell is
refused ("text cells can't be disabled"); otherwise
`cells[[op$cell]]$disabled <- isTRUE(op$disabled)`. A refusal refuses the
whole batch, as for every op.

**Cells turning off (step.R `step()`).** A cell becomes off when it is
disabled, when an edit makes it read a name only an off cell provides, or
when a run teaches the graph a new edge (`graph_learn()`, a newly attached
package). One rule in `step()`, right after `reduce()` (step.R:120),
handles all three:

```r
#' Cells that became off in this event (names(new$graph$off) minus
#' names(old$graph$off)): take them out of `pending`, mark their results
#' stale (kept, so the page can show them dimmed), and send remove_cell for
#' each that has a result or is running, as for a deleted cell. Enabled
#' cells that define a name one of them had defined (results$defined) get
#' their result marked stale and their dependents invalidated, queue =
#' FALSE: remove_cell may have removed a global they also made. Returns
#' list(state, effects).
turn_off(state, ids)
```

The effects go after `reduce()`'s and before `schedule()`'s, so
`remove_cell` reaches the worker before any later `run`. `remove_cell`
carries `order` as the delete path builds it (step.R:604-608), and is sent
only when the worker is `starting`/`ready`/`busy`, as there.

`remove_cell` (worker.R:31, 176-180, 462-471), not `drop_globals`, because
a disabled cell should leave R as if it had been deleted, attachments and
display data included, as `Rscript` would. A "more" or re-render request on
a dimmed output then gets `display = NULL`, which the page already handles
(worker.R:47-48).

Cells leaving the off set (enabled, or an edit removed the edge) get
nothing: their results are already stale, and an edit never runs anything.
The page's own run after enabling starts them.

**Scheduler.**

- `can_run()`: also `FALSE` when `id %in% names(state$graph$off)`.
- `reduce_run()` (step.R:623-647): requested ids that are off go straight
  to `skipped`, before `upstream_of_set()`; otherwise asking to run a
  disabled cell would still run its stale ancestors, and Pluto's frontend
  sends exactly that request after every toggle (Cell.js:238). "Run all"
  lists every off code cell in `skipped`.
- `reduce_wk_done()`: if the finished cell is off (disabled while it ran),
  the result is stored with `stale = TRUE`, and `invalidate_dependents()`
  and 1a's error handling are skipped. `remove_cell` is already queued
  behind the run (the worker reads messages only between runs,
  worker.R:60-64), so the globals the run made go too.
- Lazy mode needs nothing more. Off cells are never pending; when the cell
  is enabled and run, `invalidate_dependents()` (step.R:376-399) marks its
  dependents stale and, in autorun, queues them.

Disabled is not the blocked state 1a removes: it is the user's choice, it
has its own chip, and it is Pluto's own field. `failed_definers()` never
sees an off cell (off cells don't run, and `"disabled"` edges are not
`"definition"` or `"package"`); `drop_graph_error_results()` may clear an
off cell with a parse error, which does no harm.

**File format (notebook.R).**

*The code lines.* Each line of a disabled or commented code cell is written
as `"## "` + line, and an empty line as `"##"`; lines that are already
comments are prefixed too:

| code line | written |
|---|---|
| `x <- 1` | `## x <- 1` |
| (empty) | `##` |
| `  y` (indented) | `##   y` |
| `# note` | `## # note` |
| `#' not text` | `## #' not text` |
| `#| fig-width: 4` | `## #| fig-width: 4` |
| `##` | `## ##` |
| `%% 2` (inside brackets) | `## %% 2` |

The reader reverses it line by line (`"##"` gives `""`, a line starting
`"## "` loses three characters), then drops trailing blank lines as
`flush_cell()` does (notebook.R:406). The map is one-to-one, so
`format_notebook(parse_notebook(text)) == text` still holds.

Why `## ` and not `# `: with `# `, a code line starting with `%%` (legal
inside brackets) or `///` (inside a multi-line string) would become a cell
marker (`parse_marker()`, notebook.R:266) or a footer opener
(notebook.R:425) and corrupt the file; a line starting `##` never matches
`^# %%` or `^# ///`, so disabling needs no new refusal in `set_code`
(step.R:521-522). knitr::spin reads `^#+'` as text, but the third character
is always a space or the end of the line, so `## #' x` stays a code
comment. Positron and VS Code see no fake `# %%` cells.

*Which cells.* `notebook_file_of()` (state.R:429-459) sets the parsed
file's new `commented` field to the code cells in `names(state$graph$off)`
that are not themselves disabled. Text cells that are off are not
commented: `#'` lines are already comments. So the file comments out
exactly the cells that wouldn't run under `Rscript` with the disabled
cells gone: the disabled cells, and the cells that need a name only they
provide, and everything below those. A cell whose names resolve to an
enabled definer is written plainly, because `Rscript` runs it fine.

*The mark.* In the cell-order footer, after the id and after `folded`:

```
# /// cell order
# 6f1c...
# a41e... folded disabled
# c93b... commented
# ///
```

`disabled` is the user's choice and implies commented. `commented` only
records how the code is written; it is recomputed on every save.
`resolve_order()` (notebook.R:276-323) reads the words after the id as a
set (`folded`, `disabled`, `commented`) and still ignores unknown words.

*Reader.* `flush_cell()` keeps each cell's raw lines; after
`resolve_order()`, each cell marked `disabled` or `commented` has its code
rebuilt by un-commenting. Repairs, each a new problem kind:
`"uncommented_line"` (a line without `##`, from a hand edit: kept as is,
commented again at the next save); `"disabled_text_cell"` (`disabled` on a
text cell: ignored, lines untouched); `"disabled_setup_cell"` (code
un-commented, flag dropped). The parsed file gains `commented` (ids) next
to `cells`, and each cell gains `disabled`; `new_notebook_file()`
(notebook.R:65-71) gains `commented = character()`.

*Writer.* `cell_block_lines()` (notebook.R:600-612) comments the code of
cells in `file$commented` or with `disabled`. The cell-order lines
(notebook.R:617-619) add `folded`, then `disabled` or `commented`.

*Version.* No format bump. design.md's policy (notebook.R:96-119;
design.md:50-56, 771-776) raises the number when older text must be
converted before this reader can read it; format-1 text never contains the
new words, so `converters` stays empty and `ember_format` stays `1L`. An
older Ember opening a new file sees a newer `ember_version` and opens it
read-only (notebook.R:535-539): it shows the off cells as `##` comments
and runs nothing (`reduce_run()` refuses in read-only mode). If it saved
anyway, its `resolve_order()` checks only `parts[[2]] == "folded"`
(notebook.R:290), which writing `folded` first keeps right, and the code
would stay commented out.

**Views and snapshot (state.R).**

- `view_context()` adds `off` (logical by position) and `disabled_by`
  (the disabled cell's id for a dependent, else `NULL`), both from
  `state$graph$off`.
- `cell_view()` adds `disabled` and `disabled_by` (id or `NA`), and keeps
  `stale` as the engine's fact. `snapshot_of()`'s doc lists both fields.
- `not_run_ids()`: `if (isTRUE(ctx$off[[i]])) next`.

**Projection (pluto-state.R).**

- `CELL_METADATA` (pluto-state.R:19) gets a twin, `CELL_METADATA_DISABLED
  <- list(disabled = TRUE, show_logs = TRUE, skip_as_script = FALSE)`;
  `project_cell_input()` (pluto-state.R:179-182) picks one, so cells still
  share one R object.
- `project_cell_result()`: `depends_on_disabled_cells = view$disabled ||
  !is.na(view$disabled_by)`, true on the disabled cell itself too, as in
  Pluto (Run.jl:86-91). `ember` gains `disabled_by` (absent unless set) and
  `can_disable = identical(view$kind, "code") && !view$setup`.
  `ember$stale` becomes `isTRUE(view$stale) && !off`, so an off cell shows
  as disabled and not also as stale.
- `cell_key()`/`key_unchanged()` add `disabled_by`. The cell's own flag is
  already in the key through `state$cells[[i]]`; `setup` never changes
  after open, so `can_disable` needs no key field.

**Page edits and server.**

- `allowed_patch()` (pluto-edits.R:79-97): for `path[[3]] == "metadata"`,
  allow only `length(path) == 4 && path[[4]] == "disabled"`. Other metadata
  keys are still refused ("Ember doesn't support cell metadata.show_logs
  yet").
- `pluto_edits()` (pluto-edits.R:47-57): when `metadata$disabled` differs
  between before and after, add `disable_cell(id, after)`. An engine
  refusal comes back as today's thumbs-down and the next diff reverts it.
- `on_run()` (server.R:622-635): off ids are dropped next to blank cells.
  Without this, the run Pluto's frontend sends after a toggle would call
  `run_cells()` and set `allowed`, starting R in safe preview.

**Page (minimal; piece 6 builds the chips and the new menu).**

- CellInput.js `InputContextMenu` (CellInput.js:810-931): one item,
  "Disable cell" or "Enable cell" (`t_disable_cell`, `t_enable_cell`, new),
  shown when `cell_results[id].ember.can_disable`, calling
  `set_cell_disabled(!running_disabled)`. Cell.js passes `running_disabled`,
  `can_disable` and `set_cell_disabled` through.
- Cell.js `set_cell_disabled` (Cell.js:232-241): call `on_submit()` only
  when `!process_waiting_for_permission`, so enabling in safe preview
  doesn't ask to run.
- The 1a jump now works: a dependent's run button goes to the disabled
  cell. RunArea's "save" action and double-click popup for disabled cells
  (RunArea.js:28, 45-56) work as they are until piece 6 replaces RunArea.
- Ember never disables a cell by itself, so the run feedback stays
  `disabled_cells = {}` and `t_auto_disabled`/`t_auto_disabled_link`
  (english.json:371-372) stay unreachable (piece 7 deletes them).

**Docs.** design.md, File format: a disabled cell in the example and the
bullet "A disabled cell, and every code cell that needs a name only it
provides, is written with `## ` before each line, so `Rscript` skips it.
The footer says which (`disabled`, `commented`)." engine.md: "A disabled
cell defines nothing; it and its dependents don't run; their variables are
removed; enabling makes them stale." api.R's `run_cells()` doc (api.R:
228-232).

**Size.** 1a: step.R about -40/+70, state.R -25/+5, pluto-state.R -15/+25,
worker.R +12, frontend about -70/+35 across 6 files. 1b: graph.R +50,
notebook.R +60, step.R +70, state.R +25, pluto-state.R +20, pluto-edits.R
+10, api.R +8, server.R +5, man page +10, frontend +40 over 4 files. Docs
about 50 lines.

### Tests

1-14 (errors), 15-37 (disable): file format 15-19, graph 20-23, engine
24-34, request 35-36, end to end 37.

### Risks

- **A failing setup cell now lets everything run.** Every cell that had
  run reruns in autorun and most fail with their own R errors, where before
  they all sat blocked. This is Pluto's behaviour and what ui-3.md asks
  for, but noisier. A missing package already has its own install path
  (packages-core.R), so the common case recovers once the install
  finishes.
- **The classification is approximate in one direction.** A cell that
  reads a name from a failed cell and errors for an unrelated reason still
  shows "Another cell defining a contains errors.". Pluto's check is
  approximate the same way. R's real message stays in `plain_error`.
- **Package-edge wording.** If the failed cell attached a package, a
  dependent using one of its exports reads "Another cell defining mutate
  contains errors."; the link is right, the verb slightly off. Piece 7's
  wording table can change the string.
- **Changed foreign globals aren't restored.** A cell that changes another
  cell's `x` and then fails leaves `x` changed, as today.
- **Graph-error cleanup clears an old result** at the next run anywhere;
  the graph error was already shown in its place.
- **The snapshot API changes**: `blocked`/`blocked_by` go; `disabled`,
  `disabled_by` come. Nothing outside the listed tests reads the old ones
  (grep).
- **Graph edges gain a kind.** `graph$edges$via` can be `"disabled"`.
  Endeavor's graph queries see it; anything that filters on
  `"definition"` keeps working, but a query that lists all upstream cells
  now includes a disabled definer. Check Endeavor's adapter before merging.
- **Disabling throws away the dependents' variables**, so a slow dependent
  has to rerun after enabling. Pluto does the same.
- **Undo delete brings a disabled cell back enabled**: `order_ops()`
  re-inserts with code only (pluto-edits.R:157-158). Tracked in #26.
- **`##` looks unusual.** Someone who uncomments by hand and leaves a stray
  `#` gets the `uncommented_line` repair at the next open.
- **Snapshot vs page.** The snapshot's `stale` stays `TRUE` for off cells
  while the projection hides it; Endeavor sees both `stale` and `disabled`.
- **A save memo would need the edges.** shell.R:239-243 describes skipping
  `notebook_file_of()` when nothing changed; the code formats on every
  drain (shell.R:257). If a memo is added, its key must include
  `graph$off`.
- **knitr::spin and off text cells.** A text cell below a disabled cell is
  off but not commented, so spin would still evaluate its inline
  `` `r x` `` and fail. `Rscript` is not affected.

### Order within the piece

Two branches: 1a is steps 1-5, 1b is steps 6-9. Each step leaves CI
green.

1. Worker `drop_globals` and the engine sending it on every non-ok result,
   one commit: tests 2, 6, 8, 12.
2. Dependents run: `can_run()`, `failed_blockers()` deleted,
   `reduce_wk_done()` invalidates on error, `schedule()`/`reduce_run()`,
   `drop_graph_error_results()`: tests 1, 3, 7, 9.
3. The `upstream` kind and `failed_definers()`: tests 4, 5.
4. View, snapshot, projection and page in one commit (the projection stops
   sending `blocked_by` in the commit the page stops reading it):
   `view_context()`, `not_run_ids()`, `cell_key()`,
   `project_cell_result()`, `project_error()`, Cell.js (the disabled-cell
   jump is kept; step 9 repoints it to `ember.disabled_by`), Notebook.js, ErrorMessage.js, english.json,
   editor.css (disabled selectors kept): tests 10, 11.
5. Request and e2e tests 13, 14 with `upstream.R`; docs for 1a.
6. File format: reader, writer, `commented`, `disabled = FALSE` in every
   constructor (no behaviour change yet): tests 15, 16, 18, 19.
7. Graph: `disabled` argument, `"disabled"` edges, `find_errors()`
   exclusions, `off`: tests 20-23.
8. Engine: the `disable` op and `disable_cell()`, `can_run()`,
   `reduce_run()`, `turn_off()` in `step()`, `reduce_wk_done()`: tests
   24-31.
9. View, snapshot, projection, `pluto_edits()`, `on_run()` and the minimal
   page in one commit, so the page sends the patch in the commit the
   server accepts it; Cell.js's jump repointed to `ember.disabled_by`;
   `notebook_file_of()`'s `commented`; man page, docs:
   tests 17, 32-37 with `disabled.R`.

---
## 2. Text cells, inline r expressions, and function docstrings

A cell's kind is worked out from its code: only `#'` lines makes it text,
anything else is code. The code keeps its `#'` prefixes, so the editor
shows what the file holds. A cell mixing `#'` lines and code gets a graph
error and a "Split into n cells" button. In a text cell, `` `r expr` `` is
analysed like code: it takes part in the graph, runs in the worker in a new
run role (`"text"`), reruns when what it reads changes, and fails like any
cell. Separately, the `#` comment block directly above a top-level function
becomes that function's documentation in Help. About 520 lines of R and 60
of JavaScript across 15 files, plus tests.

### Problem

- A cell is markdown only because its marker says `[markdown]`
  (notebook.R:271, 441). The reader strips the `#'` prefixes
  (notebook.R:256-264, 407-409) and the writer puts them back
  (notebook.R:603-611), so the page edits code without `#'` lines, and
  typing `#'` can't make a cell text. ui-3.md says there is one kind of
  cell and `#'` lines are the text.
- A markdown cell never runs (step.R:269), and the graph sees it as empty
  code (state.R:573-576). Its text is rendered from its own code on every
  projection (pluto-state.R:255-261), so `` `r x` `` shows as a code span
  and is never evaluated.
- Nothing stops a cell from mixing `#'` lines and code. Today that is a
  code cell with comments, which `knitr::spin` would split into prose and
  a chunk.
- Help for a function the notebook defines shows only its cell's code under
  "Defined in this notebook" (`notebook_definition_doc()`,
  R/editor-services.R:213-221, called from the `docs` handler,
  server.R:759). A comment above the function, the usual way to say what it
  does, is shown only as part of that code.

### What the user sees

- Typing `#' Some *text*` into a cell and pressing Shift + Enter makes it a
  text cell: rendered and folded. The file holds the same `#'` lines under
  a plain `# %% id=...` marker.
- `#' The average car does `r round(mean(cars$mpg), 1)` mpg.` reads "The
  average car does 20.1 mpg." once the notebook runs. Values are formatted
  as knitr formats them (rounded to `getOption("digits")`, vectors joined
  with ", ") and shown as plain text, each inside
  `<span class="ember-inline">` (piece 6 adds the tint). Before the first
  run, or in safe preview, the expression shows as written, as a code span.
- When `cars` changes, the text updates (autorun) or goes stale (lazy).
- `` `r max(carz$wt)` `` fails like a cell: the error box ("object 'carz'
  not found") replaces the text. An inline expression may assign
  (`` `r n <- 5` `` defines `n`), as in knitr.
- A cell with `#'` lines and code shows "Text and code in one cell. A cell
  is either text (only #' lines) or code. Nothing in it has run." and a
  "Split into 2 cells" button, which leaves the text in the first cell and
  puts the code in a new cell below. This includes roxygen-style `#'`
  blocks above a function: `#'` is for text only; code comments use `#`.
- Help on a notebook function shows its signature (`clean_names(df)`), the
  comment lines directly above its definition rendered as Markdown,
  "Defined in a cell · Go to it", and the cell's code folded below:

  ```r
  # Lower-case the column names and replace spaces with "_".
  #
  # Returns the data frame.
  clean_names <- function(df) {
    names(df) <- gsub(" ", "_", tolower(names(df)))
    df
  }
  ```

  A blank line between the comment and the function makes it an ordinary
  comment. Functions made by calls (`memoise(f)`) have no doc; Help shows
  their code as today. `?name` in a cell is unchanged (R searches packages
  only).

This piece adds plain markup only: serif type, click-to-edit, `#'`
continuation on Enter, the tint, and opening the source below an error are
piece 6's.

### Shape

**Rules touched.** `kind` on `cell_inputs` keeps its values `"code"` and
`"markdown"` (Cell.js keeps working); it is now derived from the code and
still can't be patched by the page. New: `cell_results[id].ember.split` and
the `ember_split_cell` request. The worker's `run` message gets a new
`role` value, `"text"`; worker.R and step.R change in the same commit. Help
needs no worker change.

**Kind rules (new R/text-cells.R, pure, about 150 lines).**

```r
#' A text line is knitr::spin's text line: `#'`, `##'`, ... at column 1
#' (spin's default `doc = "^#+'[ ]?"`).
text_line <- function(lines) grepl("^#+'", lines)

#' "markdown" when not the setup cell, at least one line is non-blank, and
#' every non-blank line is a text line. Otherwise "code". A mixed cell is
#' "code", so it stays a graph node and gets the mixed_text graph error.
#' `#|` lines (piece 3) count as code lines.
cell_kind <- function(code, setup = FALSE)

#' TRUE when some lines are text lines and some other non-blank lines are not.
is_mixed <- function(code)

#' The cell split at each change between text and code: a character vector
#' of codes. Blank lines go with the run of lines before them; blank lines
#' at the start or end of a piece are dropped.
split_mixed <- function(code)

#' The inline expressions of a text cell, in reading order:
#' data.frame(line = <int, line in the cell>, expr = <chr>). Matched on
#' text lines only, with knitr's pattern (knitr 1.52,
#' all_patterns$md$inline.code): "(?<!(^``))(?<!(\n``))`r[ #]([^`]+)\\s*`".
#' An expression can't span lines: each `#'` line is matched on its own.
inline_spans <- function(code)

#' One expression per line, joined with "\n": what the graph analyses and
#' what the worker runs. "" when there are none.
inline_code <- function(code)

#' TRUE when the cell runs in the worker: a code cell, or a text cell with
#' at least one inline expression.
cell_runs <- function(cell)

#' The markdown body: each text line with `^#+'[ ]?` removed.
text_body <- function(code)

#' Markdown to HTML with commonmark, or escaped <pre> text without it. The
#' one renderer for text cells and function docs.
render_markdown <- function(text)
```

One expression per line, not one per source line, so `` `r x # note` ``
can't comment out the rest of a line, and a graph parse error's line number
indexes `inline_spans()$line`.

**File (notebook.R).**

- The reader keeps cell lines as they are; `strip_markdown_prefix()`
  (notebook.R:256) is deleted. A `[markdown]` cell is still read: a
  non-blank line in it without a `#'` prefix gets `#' ` added, so it can't
  become mixed. `parse_marker()` (notebook.R:266) still recognises the tag.
- Kinds are set after the setup cell is known and after piece 1's
  un-commenting (notebook.R:497-509): `cells[[id]]$kind <- cell_kind(code,
  setup = identical(id, setup))`. A disabled cell's recovered code is code,
  so its kind is right. The "first code cell is setup" fallback
  (notebook.R:500) uses `cell_kind(code)`.
- The writer writes `cell$code` as it is and never writes `[markdown]`
  (notebook.R:603, 608-612). A file Ember wrote still round-trips byte for
  byte; a file from an earlier Ember loses `[markdown]` on its next save.
  The format number stays 1 (notebook.R:98): this reader reads both forms,
  and an older Ember sees text cells as code cells of comments, which run
  nothing. A file in the old layout reads as before, because the old writer
  wrote `#'` before every line (notebook.R:609).
- Piece 1's `disabled_text_cell` repair applies to a cell whose code is
  only `#'` lines.

**Cells in the state.** `kind` is always `cell_kind(code, setup)`:

- api.R:93-94 (a new notebook) and notebook.R:505 (a made-up setup cell):
  `"code"`, unchanged.
- `reduce_apply()` `insert` (step.R:540-541): `kind = cell_kind(code)`,
  `folded = kind == "markdown"`.
- `reduce_apply()` `set_code` (step.R:525):
  `kind = cell_kind(code, setup = op$cell == state$setup)`. A code cell
  that becomes text is folded and loses `disabled`.
- `set_code` also resets the cell when the change affects how it runs (its
  kind changes, or it is a text cell left with no inline expression): its
  result is dropped and the worker gets `remove_cell`. These are the lines
  of the `deleted` loop (step.R:593-611), moved into a helper
  `forget_run(state, id)` that `deleted` also uses. Without the reset, a
  code cell rewritten as text would keep its globals for good.
- `insert_cell()` (api.R:191) loses its `kind` argument; `order_ops()`
  (pluto-edits.R:157-158) stops passing it. Undo-delete and paste keep a
  text cell as text because its code carries the `#'` lines.
- `check_state()` (state.R:598-611): "pending has a cell that doesn't run"
  (`!cell_runs()`), and "kind is not cell_kind(code)".

**Graph.**

- `code_of()` (state.R:573-576): a markdown cell gives `inline_code(code)`
  instead of `""`. A text cell without inline values still passes `""` and
  keeps its place beside its neighbours (`compute_order()`, graph.R:543;
  `is_markdown` there means "empty code"). A text cell with inline values is
  an ordinary node and comes after the cells it reads, in run order and so
  in the file, as `knitr::spin` and `source()` need.
- `find_errors()` (graph.R:390) adds one rule after `global_setting`
  (graph.R:463): each non-setup cell with `is_mixed(analyses[[id]]$code)`
  gets `kind = "mixed_text"`, message `"Text and code in one cell. A cell
  is either text (only #' lines) or code. Nothing in it has run."`,
  `fixes = character()` (the button is the fix). A text cell's analysed
  code has no `#'` lines, so only code cells can match. Being a graph
  error, it stops the cell itself and lets its dependents run (piece 1).
- `pkg::fn` inside an inline expression shows up in the analysis as for
  code. `waiting_cells()` (packages-core.R:470) and `reduce_run()`'s
  `code_ids` (step.R:637) select cells with `cell_runs()`.

**Running (step.R).**

- `can_run()`: `cell_runs(cell)` replaces piece 1's "is code" check.
- `invalidate_dependents()` (step.R:395) queues a dependent when
  `cell_runs()`, so a text cell reruns under autorun.
- `run_message()` (step.R:308-314): for a markdown cell,
  `role = "text"` and `code = inline_code(cell$code)`. `order` stays code
  cells only; text cells never attach packages. `worker$running$code`
  stays the cell's own code (step.R:250), so `code_differs` compares like
  for like.
- `reduce_wk_done()` (step.R:976-993): when the report's error has `span`,
  the run error gets `line = inline_spans(code)$line[span]` and
  `call = sprintf("`r %s`", inline_spans(code)$expr[span])`.
  `new_run_error()` (state.R:227) gains `call = NULL` and `line = NULL`;
  piece 6 fills them for code cells and shows "Error in `call` · line n".
  The "changed a global defined elsewhere" and `global_setting` checks
  (step.R:994-1010) apply to text runs unchanged.
- `all_code_cells_ran()` (step.R:1061) and the search-path `order` lists
  (step.R:309, 605) stay code-only. `not_run_ids()` uses `cell_runs()`.

**Worker (inst/worker.R).** Protocol comment (worker.R:29-30): `role` is
`"setup"|"cell"|"text"`; for `"text"`, each line of `code` is one
expression.

```r
#' knitr's inline formatting (knitr 1.52, .inline.hook and round_digits), so
#' a value reads the same as in knitr::spin's report.
inline_text <- function(x) {
  if (is.numeric(x)) x <- as.character(round(x, getOption("digits")))
  paste(as.character(x), collapse = ", ")
}
```

In `run_cell()` (worker.R:271), the evaluation loop (worker.R:325-337)
branches on `msg$role == "text"`: each line is parsed with
`parse(text = line)` and its expressions evaluated in order in
`globalenv()`; the value of the last goes through `inline_text()`, or is
`""` when invisible. It all runs inside the same `withCallingHandlers()`,
so messages and warnings go to the console and a failing `as.character()`
method is a cell error. A local `at` holds the index of the expression
being evaluated, and the error handler (worker.R:372) adds `span = at`.
Nothing is printed; the display step (worker.R:397-401) builds
`list(kind = "inline", mime = "application/vnd.ember.inline", values =
<chr>, text = paste(values, collapse = "\n"), truncated = FALSE)` instead
of `display_value()`. A plot drawn inline is dropped. `as_display()`
(shell.R:863-876) needs no change; the `ember_display` doc
(state.R:233-243) lists the new mime.

**Projection (pluto-state.R).**

- `project_output()` (pluto-state.R:246): the early return for markdown
  cells (pluto-state.R:255-261) moves below the error and interrupted
  branches, so a text cell's errors show as for code. A text cell's parse
  error uses the stacktrace form, since `project_parse_error()` measures
  lines in the analysed code. The return becomes `project_text(view)`:

  ```r
  #' A text cell's body. values: view$output$data$values when the output is
  #' application/vnd.ember.inline and !view$code_differs, else NULL.
  #' With values: each inline span is replaced by a token "EMBERINLINE<k>X",
  #' the body goes through render_markdown(), and each token is replaced by
  #' <span class="ember-inline">html-escaped value</span>. Without values
  #' the body is rendered as written (spans show as code). Without
  #' commonmark: text/plain, with the values put in as plain text.
  project_text <- function(view)
  ```

  Values go in as text, not markdown, so "inline values read as plain
  text" (ui-3.md, Accessibility) holds. The tokens are letters and digits,
  which commonmark leaves alone even inside code spans and links.
- `project_cell_result()` (pluto-state.R:205): `ember$split` is
  `length(split_mixed(view$code))` when `view$errors` has a `mixed_text`
  error, else `NULL`. The cell key already covers code and errors.

**Request `ember_split_cell`** `{cell_id, code}`, a row after
`ember_run_all` (server.R:821). If the cell's code is not `code`, or the
cell is not mixed, nothing happens. Otherwise, with
`pieces <- split_mixed(code)`, one batch:
`edit_notebook(nb, set_code(cell_id, pieces[1], expected = code),
insert_cell(i + 1, pieces[2]), ...)`. The first piece keeps the id, so
links to the cell still work. Then `flush_clients()`. Nothing runs; no
reply.

**Function docstrings (R/editor-services.R, pure, server side).**

```r
#' Documented functions in one cell's code. A function is a top-level
#' `name <- function(...)`, `name <- \(...)`, or the same with `=`. Its doc
#' is the run of comment lines directly above the expression's first line
#' (srcref), with no blank line between: lines matching "^\\s*#" but not
#' "^\\s*#'" (text) or "^\\s*#\\|" (cell options), with "^\\s*# ?"
#' removed. Code that doesn't parse gives no rows.
#' -> data.frame(name, line, signature, doc); signature "name(arg, b = 1)"
#'    from the parsed formals (expr[[3]][[2]]), formatted as
#'    format_signature() does; doc "" when there is no comment block.
function_docs <- function(code)
```

`notebook_definition_doc()` (R/editor-services.R:213) keeps its contract
(HTML, or `NULL` when no cell defines the name) and builds:

```
<p class="ember-def-sig"><code>clean_names(df)</code></p>      only for a function
<div class="ember-def-doc">render_markdown(doc)</div>          only when doc != ""
<p class="ember-def-where">Defined in a cell ·
   <a href="#" data-ember-cell="<id>">Go to it</a></p>
<details><summary>Code</summary><pre><code class="language-r">...</code></pre></details>
```

The whole page goes through `sanitize_help_html()` (R/editor-services.R:
238), so a `<script>` in a comment is dropped. It skips cells in piece 1's
off set, which define nothing. LiveDocsTab.js's link handler
(LiveDocsTab.js:126-135) gains one branch: a link with `data-ember-cell`
scrolls to and selects that cell, as Variables names do. The docstring is
a plain comment: Rscript and knitr see nothing new, and the cell's
analysis is unchanged.

**Page (minimal; piece 6 restyles).**

- CellInput.js:581-588: `r()` for every cell. The markdown language goes,
  because the code now starts with `#'`, and highlighting it as markdown
  would misread `#' ## Title`. Unused imports go.
- Cell.js: when `ember?.split`, a `<button class="ember-split">` under the
  error calls `pluto_actions.ember_split_cell(cell_id, code)`, labelled
  `t("t_ember_split", { n })` = "Split into {{n}} cells".
- Editor.js:744: `ember_split_cell` beside `ember_run_all`. Editor.js:187:
  `split?: number` in the `ember` typedef. Notebook.js:52 adds `split` to
  the fields the cell's memo compares.

**Docs.** design.md, File format (design.md:733, 768): the example marker
loses `[markdown]`; a line says a cell of only `#'` lines is text and
`` `r expr` `` works in it; a line describes docstrings. cell-graph.md:151,
245: "text cells without inline values". The worker protocol comment.

**Size.** text-cells.R 150, editor-services.R +60, notebook.R -20/+15,
step.R +50, state.R +15, graph.R +15, pluto-state.R +60, server.R +30,
worker.R +50, frontend +60.

### Tests

38-61: unit 38-52 (docstrings 51, 52), request 53-55, end to end 56-61.

### Risks

- **Roxygen comments** above a function make a mixed cell, as decided.
  Example notebooks that have them stop running until split; the button
  does it in one click.
- Earlier files lose `[markdown]` on the next save: one changed line per
  text cell in version control.
- Values are inserted as plain text, while knitr inserts them as markdown:
  `"**4 mpg**"` shows the asterisks in Ember and bold in `knitr::spin`.
- `#'` with spaces in front is a code comment, as in spin; indenting a
  text line makes the cell mixed.
- Folding on code-to-text happens on every `set_code`, including
  Endeavor's.
- A token `EMBERINLINE1X` typed in the text itself would be replaced too.
- **Docstrings are a convention, not syntax.** A comment that happens to
  sit right above a function (a commented-out line of code, say) shows in
  Help as its doc. The blank-line rule is the way out.

### Order within the piece

1. R/text-cells.R with tests 38-40. Nothing calls it yet.
2. Kind inferred: reader and writer, state constructors, `insert_cell()`
   without `kind`, `order_ops()`, `check_state()`; CellInput.js uses
   `r()`. Existing tests that use `kind = "markdown"` or stripped code are
   updated (37 lines in tests/testthat, and markdown.test.mjs). Inline
   values still render as code spans. Tests 41, 43, 50, 54, 60.
3. Mixed cells: the graph rule, `ember$split`, `ember_split_cell`, the
   button: tests 42 (mixed part), 49, 53, 59.
4. Inline values: `code_of()`, `cell_runs()` and its callers, the reset in
   `set_code`, the worker's `"text"` role with `run_message()` and
   `reduce_wk_done()` in one commit, `project_text()`, `text.R`: tests 42,
   44-48, 56-58.
5. Docstrings: `function_docs()`, `notebook_definition_doc()`, the
   LiveDocsTab link: tests 51, 52, 55, 61. Docs.

---

## 3. Figures and Variables data

Two independent parts on one branch, each its own commit with CI green:
**3a, fixed figure sizes** (engine, worker, and the small page change that
stops resize re-renders) and **3b, Variables data** (worker report, engine,
projection; no page change, piece 5 draws the tab). About 260 lines of R,
70 of JavaScript, 300 of tests; 12 files. 3b doesn't depend on 3a; they
can be two branches.

### Problem

**Figures.** Every plot is drawn at 720 x 480 px, 96 dpi: `open_device()`
(worker.R:1034-1043) opens the device at that size, and
`display_plot_value()`/`display_plot()` report `size = list(720, 480, 96)`
(worker.R:1286, 1301). The page redraws on every width change: `EmberPlot`
(EmberPlot.js:17-70) watches its container with a `ResizeObserver` and
sends `ember_render_plot {cell_id, width, height, res}` when the wanted
width differs by more than 10% (EmberPlot.js:31-41); the server clamps and
dispatches `ev_render` (server.R:804-815). So proportions and text size
change with the window, and a cell can't ask for its own size.

**Variables.** The worker knows which globals each cell created
(`owned[[cell]]`, worker.R:412-414, reported as `created`, kept on the
result as `defined`, step.R:1037-1040, state.R:211-216), but nothing
reports a global's type or value. The Variables tab needs, per global: name,
type, a one-line value, and the defining cell.

### What the user sees

- A plot with no `#|` lines is 7.5 x 5 in, shown 720 CSS px wide, the
  column's width. Resizing the window never redraws it; on a narrow window
  it scales down with the column.
- `#| fig-width: 8` and `#| fig-height: 4` at the top of a cell draw at
  8 x 4 in: 768 px scaled to the 720 px column; a 5 in wide figure shows
  at its real 480 px.
- Figures are sharp on a high-density screen from the first draw (2x,
  192 dpi). Moving the window to a denser screen, or zooming past 200%,
  redraws once at the higher density; nothing else does.
- A bad value (`#| fig-width: wide`, `#| fig-width: 0`) draws at the
  default for that side, with a warning under the cell: "`#| fig-width:
  wide` is not a number of inches; using 7.5."
- There is no "Figure size…" menu item (Figure4's note); the `#|` lines
  are the way.
- Variables: nothing visible until piece 5 builds the tab. The data is in
  the page's state and, names and types only, in `notebook_snapshot()`.

### Shape

#### 3a. Fixed figure sizes

**Reading the `#|` lines** (pure, R/notebook.R beside the cell reader,
since it is file-format knowledge):

```r
#' The figure size a cell asks for with Quarto's comment lines, in inches.
#' Only the run of `#|` lines at the top of the cell counts (Quarto's
#' rule; blank lines before it are skipped); a `#|` line further down is
#' an ordinary comment. Keys `fig-width`/`fig-height` and knitr's
#' `fig.width`/`fig.height`; other keys (`echo: false`, ...) are ignored.
#' A value must be a plain number between 0.5 and 30; anything else uses
#' the default for that side and adds a problem sentence.
#' @return list(width = <dbl>, height = <dbl>, problems = <chr>)
cell_figure_size(code)

FIGURE_DEFAULT <- list(width = 7.5, height = 5)
```

The line pattern is `^#\|\s*(fig[-.](width|height))\s*:\s*(.*?)\s*$`, the
value through `suppressWarnings(as.numeric())`. The lines stay in `code`,
so the writer needs no change and `Rscript` ignores them. It reads the
cell's code as stored, which for a disabled cell is already un-commented
(piece 1).

**Run message.** `run_message()` (step.R:308-314) adds
`fig = cell_figure_size(code)`, a new field on an existing message (both
sides in one commit). Editing a `#|` line changes the code, so the cell
shows as edited and its rerun redraws (`is_fresh()`, step.R:345-348).

**Worker.**

- `FIG_RES <- 192` and a worker-side `FIGURE_DEFAULT` (the worker is
  sourced on its own and can't see the package's). The first draw is at
  2x density (knitr's `fig.retina = 2` for HTML), so 1x and 2x screens
  never ask for a redraw.
- `open_device(fig)` (worker.R:1034): width `round(fig$width * res)`,
  height `round(fig$height * res)`, `res = FIG_RES`, lowered for this
  image so neither side exceeds 6000 px (a 30 in figure draws at 200 dpi).
  Devices scale text and lines by `res`, so a 7.5 x 5 in figure at 192 dpi
  looks like today's at 96, only sharper.
- `run_cell()` (worker.R:318-319): `dev <- open_device(msg$fig %||%
  FIGURE_DEFAULT)`; after the console collector starts, each of
  `msg$fig$problems` becomes `console$warning(simpleWarning(p))`.
- `display_plot_value()`/`display_plot()` (worker.R:1276-1303): `size =
  list(width = <px>, height = <px>, res = <dpi>)` from the device actually
  opened; the kept record gains `fig = list(width, height)` in inches.
- `render_plot(msg)` (worker.R:1436-1453): without `msg$width`/`height`,
  draw at `rec$fig` inches and `msg$res`; with them (the `render_png()`
  API), in pixels as today. Header comment (worker.R:36): `render  cell,
  res, width?, height?`.

**Engine and server.**

- `ev_render(cell, width, height, at, res = 96)` (step.R:45): `width` and
  `height` may be NULL; `reduce_render()` (step.R:747-756) sends them as
  given (NULL drops out).
- `ember_render_plot` (server.R:804-815, table row server.R:659) becomes
  `{cell_id, res}`: res clamped to 72-384 (4x),
  `ev_render(cell, NULL, NULL, at, res)`. A body that still carries
  `width`/`height` is ignored for those fields.
- `render_png()` (api.R:360) unchanged: an explicit pixel size re-renders
  at that size (Endeavor's `view_cell_output`). Its doc says the stored
  image is drawn at the cell's figure size at 192 dpi.

**Projection.** `project_cell_result()` (pluto-state.R:205-217) adds
`ember$figure = list(width = size$width / size$res, height = size$height /
size$res)` (inches) when the output is `image/png` with a size, else NULL.
It comes from the result, so `cell_key()` already covers it.

**Page (minimal).**

- Cell.js:305 and 383 pass `ember_figure=${cell_result.ember?.figure}` to
  `CellOutput`, which passes it to `OutputBody` and `EmberPlot`
  (CellOutput.js:158-161).
- `EmberPlot.js` is rewritten (about 60 lines, replacing the
  `ResizeObserver`):
  - the `<img>` gets `width: ${figure.width * 96}px; max-width: 100%;
    height: auto`: real size up to the column's width, scaled down below;
  - density check: `have = img.naturalWidth / (figure.width * 96)`,
    `want = min(devicePixelRatio, 4)`; when `have < want * 0.95` it sends
    `ember_render_plot(cell_id, 96 * want)`. It never asks for a lower
    density, so two tabs on screens of different density settle on the
    higher one (today's two-tab rule, EmberPlot.js:12-15, becomes this);
  - it checks when a new image arrives (`last_run_timestamp` changes) and
    when the density changes (`matchMedia("(resolution: <dpr>dppx)")`,
    re-registered after each change), only while the tab is visible, at
    most once per (timestamp, density) pair;
  - without `figure` (an older export, or an `image/png` from
    `knit_print`) it renders `PlutoImage` as before.
- Editor.js:732: `ember_render_plot: (cell_id, res) => ...`.

The figure styling (no frame, dark mode untouched) is piece 6's.

**Docs.** design.md:341-343, 364 and 853 ("re-rendered on resize") are
rewritten to the fixed-size rule.

#### 3b. Variables data

**Worker.** After the bookkeeping that sets `owned[[msg$cell]]`
(worker.R:412-414), and outside `uninterrupted()`'s block as display is
(a user's `str()` or `format()` method may be slow, so an interrupt stops
the summaries, not the cell's facts):

```r
#' One line per global the cell owns: type and a short value.
#' Names in alphabetical order; stops summarising after 0.25 s in total and
#' gives the rest kind = "none" (type only). Active bindings are never
#' called (as snapshot_globals(), worker.R:476): type "active binding".
#' Every format()/str() call goes through eval_in_notebook()
#' (worker.R:1076) so the notebook's own S3 methods are used, each in
#' tryCatch (an error gives kind "none").
#' @return named list name -> list(type, value, kind); `value` NULL when
#'   kind is "none". At most 80 characters, cut with "\u2026".
summarise_globals(names)
```

`type` is `class(x)[1]` (the board's `data.frame`, `numeric`, `lm`,
`character`, `boot`, `function`). `kind` and `value`, first rule that
applies:

| value | kind | value text | board example |
|---|---|---|---|
| `NULL` | `value` | `NULL` | |
| function | `value` | `function(` + `names(formals(args(x)))` joined by `, ` + `)` | `function(d, i)` |
| data frame | `shape` | `"<n> rows × <m> columns"` (`1 row`; `format(n, big.mark = ",")`) | `21 rows × 3 columns` |
| matrix or array | `shape` | `"<n> rows × <m> columns"`, or `"2 × 3 × 4 array"` | |
| atomic with no class; `Date`, `POSIXct`, `difftime` | `value` | `format(head(x, 20), trim = TRUE)` (characters through `encodeString(quote = '"')`), joined by spaces, cut at 80 with "…"; `character(0)` for length 0 | `4`; `"Mazda RX4" "Hornet 4 Drive" …` |
| anything else | `str` | first line of `utils::str(x, max.level = 0, give.attr = FALSE, vec.len = 2)`, trimmed | `List of 12` (an `lm`) |

In R source, × and … are written `"\u00d7"` and `"\u2026"`. `run_cell()`'s
report gains `globals` (rc init, worker.R:281-284; header comment
worker.R:259-265).

**Engine.**

- `new_result(..., variables = list())` (state.R:211). `reduce_wk_done()`
  (step.R:1037) passes `report$globals %||% list()` only when the stored
  result's status is "ok". A run the worker reports as failed, and an ok
  run the server turns into an error (step.R:996-1010), store none: their
  globals are about to go (piece 1's `drop_globals`), and the report was
  made before that. `reduce_wk_exited()` and restart already clear
  `state$results`.
- `cell_view()` (state.R:397) adds `variables`: a list of `list(name,
  type, value, kind)` sorted by name, without dot-names (private, as the
  graph treats them, graph.R:240), and empty for an off cell (piece 1:
  `remove_cell` removed its globals, though its result is kept for the
  dimmed output). The running cell shows its previous result's variables,
  as it shows its previous output.
- `notebook_snapshot()` (api.R:299): each cell's `variables` carries
  `name` and `type` only, so Endeavor's agent sees no values;
  man/notebooks.Rd documents it.

**Projection: the contract for the Variables tab.**

```r
#' cell_results[id].ember.variables =
#'   arr(list(name = <chr>, type = <chr>, value = <chr> | absent,
#'            kind = "value" | "shape" | "str" | "none"), ...)
#' sorted by name; absent when the cell has none.
```

Per cell, not top-level: a run patches only that cell's `cell_results`
entry, and `cell_key()` already covers the result. The defining cell is the
`cell_results` key; "greyed when stale" is the same entry's `ember$stale`.
Piece 5 collects all cells' lists into one table.

**Export.** `export_html()` (export.R:255) drops every
`cell_results[[id]]$ember$variables` before encoding: a value the notebook
never printed (an API key) must not land in a downloaded HTML file.

**Rules touched.** New data only under `cell_results[id].ember`
(`figure`, `variables`); `ember_render_plot`'s body changes; the `run`
message and `done` report gain fields, worker and server in one commit; the
`<img>` stays inside `pluto-output`.

### Tests

62-77: unit 62-71, request 72-73, end to end 74-77.

### Risks

- **Plot looks.** A 2x first draw relies on devices scaling text and line
  widths by `res`. ragg does; `grDevices::png` does for text, and for line
  widths on the cairo and quartz types. Test 64 checks pixel size only;
  check a base and a ggplot figure by eye at 96 and 192 dpi on each CI
  platform before merging.
- **Bigger images.** A 2x PNG is 2-3 times today's bytes, in the state,
  every page sync and every HTML export: a page with 50 plots grows by a
  few MB.
- **`render_png()` with a pixel size replaces the stored image**, so the
  page then shows that image. Unchanged from today; tracked in #28.
- **Summaries run user code** (`str` and `format` methods) after every
  run. The 0.25 s budget, per-name `tryCatch` and interruptibility bound
  it; a slow `class()` is not bounded.
- **Values go stale by reference.** An environment or R6 object changed by
  a later cell keeps the summary from its own cell's run.
- **Browser zoom changes `devicePixelRatio`**: zooming past 200% redraws
  every figure once.

### Order within the piece

1. `cell_figure_size()` with tests 62, 63 (no behaviour change).
2. Worker device sizes, `fig` in the run message, `render_plot` by res,
   `ember_render_plot {cell_id, res}`, `ember$figure`, the `EmberPlot`
   rewrite and the design.md text, in one commit (tests 64-67, 72-76): the
   old page would send width/height to the new server, which ignores them,
   so this lands together.
3. Variables: `summarise_globals()`, report field, result and view,
   projection, snapshot, export strip: tests 68-71, 77.

---

## 7a. Shared dialogs and menus

A small frontend branch: two shared modules and the replacement of most
native pop-ups. It goes before pieces 4, 5 and 6 so their rename form,
header menus and cell menu use it from the start. About 250 lines added,
60 removed; no engine change.

### Problem

19 `alert()`/`confirm()` calls block the page, can't be styled, and count
as failures in the e2e suite (tests/e2e/browser.mjs:40): ExportBanner.js:40,
119; Editor.js:617, 619, 878, 898, 1234, 1249, 1379, 1435, 1610, 1615;
BottomRightPanel.js:57; Settings.js:39; CellInput.js:862;
PlutoConnection.js:138, 144, 405, 461. Some point users to Pluto's GitHub
(PlutoConnection.js:138). Every later frontend piece needs a menu (header
⋯, Export, cell menu) and dialogs (rename or move, delete, long runs), and
nothing shared exists.

### What the user sees

- In-page dialogs where pop-ups were: "Delete 3 cells?" (Delete /
  Cancel); "A cell you're deleting is still running. Stop it first, then
  delete." (Stop / Cancel); "Something went wrong in this page. Reload it;
  your notebook is saved." (Reload); "Couldn't copy the output."; "Ember
  didn't accept this page's connection. Open the link Ember printed when
  it started."
- Nothing else changes yet.

### Shape

**`common/dialogs.js`** (new, about 130 lines). One modal `<dialog>`,
rendered by Preact into its own container appended to `document.body` on
first use, so PlutoConnection.js can use it before the Editor mounts.

```js
// Dialog({ title?, on_close, children })  the modal shell, also used by
//   piece 4's rename form: showModal(), focus to the first field or the
//   primary button, Esc and the cancel event call on_close, focus returns
//   to the element that had it before opening (saved explicitly; browsers
//   differ).
// ask({ title?, body, actions: [{ label, value, primary?, danger? }], cancel_value })
//   -> Promise<value>. Esc, the cancel event and Cancel resolve cancel_value.
// tell({ title?, body, action_label = t("t_close") }) -> Promise<void>
// reload_prompt() = ask({ body: t("t_page_error_reload"), actions: [Reload] })
//   -> location.reload()
```

`showModal()` makes the rest of the page inert and keeps Tab inside. It
uses `useDialog` (common/useDialog.js:9-56) and its polyfill path as is.
One dialog at a time; a second `ask` queues. Buttons name their action, no
Yes/No.

**`common/useMenu.js`** (new, about 90 lines), a hook for a button with a
popup menu, and the menu CSS (`.ember-menu`, `.ember-menuitem`,
`.ember-menu-note`, `.ember-menu-sep`, about 60 lines; sizes from Menus6
and Header3: 8 px radius, 4 px padding, items 8 x 10 px, title 13.5 px
weight 500, description 12 px muted, note 12.5 px amber on amber wash).

```js
// const { button_props, menu_props, item_props(i), open, close } = useMenu({ count })
// button: aria-haspopup="menu", aria-expanded; Enter, Space or Down opens
//   and focuses item 0.
// menu: role="menu"; items role="menuitem", roving tabindex.
// Up/Down (wrapping), Home/End, Enter/Space activates, Esc and Tab close.
// A click outside closes. Closing returns focus to the button. No slide
// transition.
```

Its first users are piece 5's ⋯ menu, piece 6's cell menu and piece 7's
Export menu.

**Pop-ups replaced now** (the other three go with the code that shows them:
ExportBanner.js:40 and :119 with piece 7's Export menu, Settings.js:39 with
piece 7's Settings, Editor.js:1379 with piece 7's shortcuts sheet):

| today | after |
|---|---|
| Editor.js:617 delete several | `ask`: "Delete {{count}} cells?", Delete (danger) / Cancel |
| Editor.js:619 delete while running | `ask`: "A cell you're deleting is still running. Stop it first, then delete." Stop / Cancel; Stop interrupts and does not delete, as today |
| Editor.js:878, 898 update counter, failed reset | `reload_prompt()`, details to `console.error` |
| Editor.js:1234 move confirm, 1249 move failure | `ask` (Move / Cancel) and `tell` ("Couldn't move the file: {{reason}}"); piece 4 deletes both with `submit_file_change` |
| Editor.js:1435 copying cells | `tell`: "Couldn't copy the cells." |
| Editor.js:1610, 1615 restart confirms | deleted: `risky_file_source` is never set by the server (no hit in R/), and the Julia-version check reads `__internal_julia_*` keys `project_nbpkg()` (pluto-state.R:583-621) never sends |
| BottomRightPanel.js:57 window too small | deleted (piece 5 makes the panel work at every width) |
| CellInput.js:862 copy output | `tell`: "Couldn't copy the output." (`t_copy_output_failed`) |
| PlutoConnection.js:138, 144 | `reload_prompt()`; the GitHub text goes to `console.error` only |
| PlutoConnection.js:405 out of sync | `reload_prompt()` |
| PlutoConnection.js:461 lost authentication | `tell`: "Ember didn't accept this page's connection. Open the link Ember printed when it started." |

New strings in english.json, from Words6.

### Tests

78 (unit), 79 (end to end).

### Risks

- **Focus return** differs between browsers; dialogs.js saves the element
  itself. Test 79 checks it in Chromium only.
- **The polyfill path** of `useDialog` is not exercised by CI's browsers;
  check once in a browser without `<dialog>` support if one is still
  supported.

### Order within the piece

1. `dialogs.js` and `useMenu.js` with the menu CSS.
2. The replacements, one file at a time; tests 78, 79.

---
## 4. Notebooks and packages from the browser

Create, open, rename, move and remember notebooks from the browser, update
packages to today's snapshot from the Packages tab, and show the real
reason when an install fails. About 550 lines of R and 650 of JavaScript
and CSS (minus about 90 deleted from Editor.js), 450 of tests. One new
worker message (`chdir`).

### Problem

- **Start page.** `GET /` is a bare `<ul>` of hosted notebooks
  (`http_index()`, server.R:1153-1163): no way to create a notebook, no
  recent list, no "Open a file". Making a notebook means `new_notebook()`
  in R, then `start_server()` (the old gap list, UI);
  `start_server(open = TRUE)` with no path opens nothing
  (server.R:171-174).
- **Recent notebooks** live only in the browser's localStorage
  (`update_stored_recent_notebooks`, Editor.js:1859-1870, written at
  Editor.js:1067 and 1526), which is per origin, so each port has its own
  list; nothing has read it since increment 2 deleted Pluto's welcome page.
- **Rename/move** half works. The header's `FilePicker` (Editor.js:
  1697-1714) patches `notebook.path`; `pluto_edits()` turns it into
  `move_to` (pluto-edits.R:64); `on_update_notebook()` calls
  `move_notebook()` (server.R:604), which validates the path (api.R:
  130-142); `reduce_move()` moves the file (step.R:731-737). Missing: the
  design's Name + Folder form; the page asks with `confirm()` and reports
  failures with `alert()` (Editor.js:1234, 1249; piece 7a turned these
  into `ask`/`tell`); and the running worker keeps its old working
  directory (started with `wd = dirname(state$path)`, step.R:207, 698), so
  board Move5's promise "Code that reads files by relative path will look
  in the new folder" is false today.
- **Packages Update.** `preview_date()` and `set_date()` exist
  (api-packages.R:41-75), but the page never calls them; the Packages tab
  (PackagesTab.js) only displays.
- **Install failures** (the old gap list, Packages). Reproduced: a notebook
  locking a source package that doesn't compile ends with
  `target$message = "install failed, status 1"` and an empty `target$log`,
  although the installer prints the compiler error and renv's
  `Error: failed to install "brokenpkg"`. The cause is `poll_jobs()`
  (library.R:401-440): while the process is alive each complete line goes
  to `make_progress` and is dropped, leaving only the unfinished last line
  in `job$buf` (library.R:413-417); on exit `make_done` gets
  `paste0(job$buf, rest)` (library.R:429-430), the empty remainder for any
  install longer than one poll. Patching `poll_jobs()` in memory to keep
  every chunk makes the same session report the compiler error, and
  `install_failure_message()` (shell.R:506-515) works once it gets the
  lines. Even so, the failure is one library-wide message: every locked
  package shows "failed" (`packages_view()`, packages-core.R:738-740), and
  the problems row has `package = NA` (packages-core.R:563).

### What the user sees

- **Start page** (board "Round 5 · Start page, compact"; `/?secret=`): a
  small logo and "ember"; one "My notebooks" list with "New notebook" at
  the top, then open notebooks (name, folder in faint mono, then "Running ·
  212 MB", "Safe preview" or "R stopped", and a round button that closes
  the notebook in the server, Pluto's shutdown: R stops and the notebook
  moves to the recent rows; titled "Stop R for this notebook" while
  running, "Close" otherwise; not shown for a notebook a host such as
  Endeavor opened), then recent notebooks, each with "Forget" ("Remove from
  this list. The file stays."). Under the list, an "Open a file" field with
  path completion and an Open button.
- **New notebook** expands in place into Name (the first free
  `notebook.R`, `notebook-2.R`, ...) and Folder (where Ember was started,
  `~` for home), plus Create and Cancel. Folder is a typed field that
  completes folder names; its "Change…" link focuses it and opens the
  list. Create makes the file and opens it. Errors show in the row ("A
  file called analysis.R is already in ~/projects/cars.").
- **Rename or move**: clicking the file name in the header opens board
  Move5's form under it: Name, Folder (same completion), "Moves the .R
  file. The notebook stays open and R keeps running. Code that reads files
  by relative path will look in the new folder.", Cancel / Save. A refusal
  shows inside the form ("Couldn't move the file: {reason}"). After the
  move, `getwd()` in a cell gives the new folder.
- **Packages tab**: "Versions as of 1 Sept 2026" with **Update**. Update
  says "Checking today's versions…", then updates the date and lock at
  once, and the library installs as usual. Only when R has loaded a
  package whose version would change does the tab ask, once, in the tab:
  "Updating changes ggplot2 and rlang, which R has loaded. R will restart
  and cells will need to run again." (Update / Cancel). If the index can't
  be fetched: "Couldn't get today's versions: {reason}".
- **A failed install** marks only the packages that failed and those that
  need them, with one card per package the notebook loads: **"broom
  couldn't install"**, then one sentence ("A package it needs, rlang 1.1.6,
  doesn't build on R 4.6.1." / "It doesn't build on R 4.6.1." / "It
  couldn't be downloaded. Check the internet connection." / "It needs a
  system library that isn't installed."), **Update** ("Updating usually
  fixes this") for build failures, Try again for downloads, and **Show the
  error** for all, which expands the installer's last 200 lines in mono.
  `notebook_snapshot(nb)$packages` carries the same facts.

### Shape

**A. Install failures reach the session.**

- `poll_jobs()` (library.R:401-440) keeps what it reads: each complete
  line also goes into `job$lines`, capped at the last 400. On exit,
  `make_done(status, paste(c(job$lines, job$buf, rest), collapse = "\n"))`.
  Progress parsing is unchanged. Index fetch failures (shell.R:372-380) get
  their real output from the same fix.
- A pure function in packages-core.R, next to `install_failure_message()`
  (which moves there from shell.R:506):

  ```r
  #' Which packages an install failed on, and why, from the installer's
  #' output. R's quotes are "\u2018"/"\u2019" or ASCII depending on locale;
  #' both are matched.
  #' -> data.frame(package, kind, detail): kind "compile" ("ERROR:
  #'    compilation failed for package"), "configure" ("ERROR: configuration
  #'    failed"), "dependency" ("ERROR: dependency 'x' is not available",
  #'    detail = x), "download" (renv's "error downloading" / "failed to
  #'    retrieve" naming the package), "other" (renv's "- [pkg]: install
  #'    failed" with none of the above; detail = first ERROR line).
  install_failures(lines)
  ```

- `ev_install_done()` (packages-core.R:148) gains `failures`; the shell's
  `make_done` (shell.R:402-408) fills it and sends `log = tail(lines, 200)`
  (40 today).
- `reduce_install_done()` (packages-core.R:544-573) stores `tgt$failures`
  and writes one `install_failed` problem row per failed package with
  `package` set, falling back to today's single NA row only when nothing
  was parsed.
- `packages_view()` (packages-core.R:718-779): `library` gains `log` and
  `failures` (plus `needed_by`: the direct packages whose dependency
  closure includes the failed one, from the snapshot's index when loaded,
  `deps`, resolve.R:78-80, else `character()`). Per-row status is
  `"failed"` for failed packages and the direct packages that need one;
  every other row in a failed library is `"not_installed"`, not
  `"failed"` (the staging folder is never renamed, so none is installed).
  The tab's pill and Pluto's `nbpkg`/`status_tree` treat `"not_installed"`
  as `"missing"`.
- `project_ember()` (pluto-state.R, `packages$library`):

  ```r
  #' library = list(status, message, progress,
  #'                log = <one string, the last 200 lines> | NULL (only when failed),
  #'                failures = arr(list(package, version, kind, detail | NULL,
  #'                                    needed_by = arr(<direct names>))))
  ```

  `reuse_fields()` (pluto-state.R:117) sends the log once, not on every
  flush. `project_nbpkg()` (pluto-state.R:584-619) keeps its shape; its
  `terminal_outputs$nbpkg_sync` now carries the real message, which
  Endeavor reads (drawer.ts:218, 244).
- The page builds the card sentences from `kind`, `package`, `version` and
  `packages$r_version` with translation keys
  (`t_ember_install_failed_title`, `_compile`, `_compile_dependency`,
  `_configure`, `_download`, `_other`, `t_ember_show_the_error`). R sends
  no prose.

**B. Update to today's snapshot.** The engine applies the proposal itself,
so the API, the page and Endeavor behave the same, and it stays pure.

- `new_proposal()` (packages-core.R:126) gains `apply = FALSE`;
  `ev_preview_date(date, at, apply = FALSE)` (packages-core.R:136) passes
  it; `reduce_preview_date()` (packages-core.R:584-593) stores it.
- The body of `reduce_set_date()` after its check (packages-core.R:611-622)
  moves into `apply_proposal(state)`, which `reduce_set_date()` calls.
- Stage 2 of `schedule_packages()` (packages-core.R:268-296), when an
  `apply = TRUE` proposal becomes `"ready"`: if none of the changed
  packages is in `state$worker$loaded` (or no worker runs), it calls
  `apply_proposal()`, and stage 3 installs the new target once allowed, as
  after `set_date()`. Otherwise the proposal stays `"ready"` with `restart
  = <those names>` and waits for `set_date()` or the page's answer.
- The view gains `proposal$restart` and `proposal$apply`; `project_ember()`
  gains, only for an `apply = TRUE` proposal (a plain `preview_date()` from
  R shows nothing):

  ```r
  #' packages$update = list(date, status = "checking"|"ready"|"failed",
  #'                        restart = arr(<names>), changes = <int>) | NULL
  ```

- Requests: `ember_update_packages {}` dispatches
  `ev_preview_date(format(Sys.time(), "%Y-%m-%d"), apply = TRUE)` (local
  time, as stage 1, packages-core.R:215-222), then flushes; no reply.
  `ember_apply_update {date}` calls `set_date(hub$nb, date)`; a refusal is
  logged and flushed. `ember_cancel_update {}` dispatches a new
  `ev_cancel_preview` (`proposal <- NULL`). The card's Update sends
  `ember_update_packages`; "Try again" sends `ember_run_all`, since
  `reduce_run()` already retries a failed library (step.R:629-632).

**C. Move keeps R running and follows the folder.**

- `state$worker` gets `wd`, set where the worker state is built
  (step.R:196, 692) from `dirname(state$path)`. `reduce_move()`
  (step.R:733-737), when the worker is `"ready"` or `"busy"`, appends
  `fx_send(gen, list(type = "chdir", from = <old dir>, to = <new dir>))`
  and sets `worker$wd`. `reduce_wk_hello()` (step.R:841) sends the same
  when `worker$wd` differs from `dirname(state$path)`, which covers a move
  while the worker was starting (a `send` is dropped then, shell.R:
  327-331).
- Worker `handle_next()` (worker.R:162-196) gets `chdir`: if `getwd()` is
  still `from`, `setwd(to)` (a notebook that called `setwd()` keeps its
  choice); `settings_start$wd <- to` (worker.R:90, 123); a `setup_restore`
  entry of kind `wd` equal to `from` becomes `to` (worker.R:423). No reply.
- man/notebooks.Rd, `move_notebook()`: "A running R process's working
  directory follows the file, unless the notebook changed it."
- Name rules, in a new R/notebook-files.R:

  ```r
  #' A notebook file path from what a person typed: `name` trimmed, ".R"
  #' appended unless it ends in .R/.r, no "/" or "\\" or "." / "..";
  #' `folder` with "~" expanded, absolute, existing, writable
  #' (file.access(folder, 2) == 0). -> the path, or an `ember_refused`
  #' condition with the reason as the page shows it.
  notebook_target_path(name, folder)
  ```

- `ember_move_notebook {name, folder}` calls `notebook_target_path()`,
  then `move_notebook()`, replies `{path}` or `{error}`, then flushes. The
  new `shortpath` and `path` reach the page through the normal diff
  (pluto-state.R:105).
- Page: new `components/MoveDialog.js` (about 110 lines), built on piece
  7a's `Dialog` shell (focus, Esc, focus return) and positioned under the
  file name as on Move5. It holds Name, Folder (`FolderField`, below) and
  the sentence. In the header (Editor.js:1697-1714), `FilePicker` is
  replaced by `<button id="ember-file-name">` showing `notebook.shortpath`
  (title: the full path) that opens it; piece 5 places and styles both.
  `submit_file_change`, `desktop_submit_file_change` and their `ask`/`tell`
  (Editor.js:1229-1278) are deleted, with the `DesktopInterface.js` move
  imports they use (Editor.js:48). The `path` patch route stays in
  `pluto_edits()` for Endeavor and old tabs.

**D. Recent notebooks, kept by the server.** New R/recent.R, plain
functions over one file:

```r
#' file.path(tools::R_user_dir("ember", "data"), "recent-notebooks.txt"):
#' one absolute path per line, newest first, at most 50. Shared by every
#' Ember server of this user, whatever the port. Written with
#' write_atomic() (shell.R:888).
recent_file()
read_recent()                        # -> character; missing file -> character()
remember_notebook(path, replaces = NULL)
forget_notebook(path)
```

`host_notebook()` (server.R:193) calls `remember_notebook(st$path)`;
`on_note()` (server.R:494) calls `remember_notebook(new, replaces = old)`
when a hub's path changed (the hub keeps `hub$path` to notice, so moves
through Endeavor or the R API count too). All are wrapped in `tryCatch`: a
read-only home folder must never break hosting. The localStorage list
(Editor.js:1065-1069, 1525-1527, 1857-1869) and
`t_remove_from_recent_notebooks` are deleted. Tests never touch the user's
file: setup-cache.R sets `R_USER_DATA_DIR` to a temp folder, and
server.mjs passes it to the child.

**E. Create, open, and the start page.**

- `new_server()` (server.R:235) records `server$start_dir <- getwd()`;
  `start_server()`'s child inherits the caller's directory (processx's
  default `wd`), so it is "where Ember was started" in both entry points.
  `start_server(path = NULL, open = TRUE)` opens the start page
  (server.R:171-174); server.Rd changes to match.
- `GET /` serves `start.html` (a new static file, excluded from the static
  path like editor.html, server.R:1223) with the cookie `http_edit()` sets;
  `/` stays in `QUERY_SECRET_ONLY_PATHS` (server.R:1168). `http_index()`
  and its HTML string are deleted.
- New requests, none needing a hub:

  | type | body | reply |
  |---|---|---|
  | `ember_start_page` | `{}` | `{start_dir, new_name, open: arr({notebook_id, path, name, folder, process, worker_memory, owned}), recent: arr({path, name, folder})}`; `recent` leaves out open paths and missing files (they stay in the file); `folder` shows `~` for home |
  | `ember_new_notebook` | `{name, folder}` | `notebook_target_path()`, `new_notebook()`, `host_notebook(owned = TRUE)` -> `{url: "edit?id=..&secret=.."}` (relative, as `http_open()`, server.R:1119-1126) or `{error}` |
  | `ember_open_notebook` | `{path}` | `{url}` or `{error}`; `http_open()`'s find-or-open body (server.R:1101-1117) moves into `open_or_find(server, path)`, used by both |
  | `ember_forget_recent` | `{path}` | `forget_notebook()`, then the `ember_start_page` reply |
  | `completepath` (Pluto's, stubbed at server.R:789-792) | `{query, ember_dirs_only?}` | Pluto's `{start, stop, results}`: entries of `dirname(query)` starting with its last part, folders with a trailing "/", at most 200, hidden files only when the typed part starts with "." |

  Closing an open notebook reuses `shutdown_notebook` with the row's
  `notebook_id` (server.R:701-711), which already refuses notebooks a host
  owns. `complete_path(query, dirs_only)` is a plain function in
  R/notebook-files.R. Listing folders is no new exposure: anyone with the
  secret can already run R.
- Page: `start.html` (about 30 lines, like editor.html's head, including
  piece 5's inline theme script once piece 5 lands) loads `start.js`,
  which renders `components/StartPage.js` with Preact from `imports/` and
  `create_pluto_connection` (common/PlutoConnection.js:289) with no
  notebook id. It sends `ember_start_page` on load and every 5 s while the
  tab is visible. `components/FolderField.js` (shared with MoveDialog) is a
  text input that sends `completepath` with `ember_dirs_only = true` and
  shows matches in a list (Up/Down, Enter, Esc). "Open a file" reuses
  `FilePicker` with `completepath`; its `.jl` suggestions
  (FilePicker.js:330-347) become `.R`. `start.css` uses the kept theme
  variable names, so piece 5's values apply with no edit. Strings go into
  english.json with Words6's wording. No `alert()` or `confirm()`: errors
  show in the row, as the board does.

**Rules touched.** New requests are `ember_*`, except Pluto's
`completepath`, already in the table. One worker message, `chdir`, both
sides in one commit. `nbpkg` stays filled; new fields go under
`ember.packages`. Only `/`'s content changes; Endeavor doesn't read `/`.
`pluto-filepicker` leaves the header; Endeavor's page code doesn't read it
(not in the kept list; check endeavor/frontend/src once before merging).

**Size.** R: recent.R 70, notebook-files.R 90, server handlers 170,
packages-core 120, step and worker 40, `poll_jobs` 10, projection 50.
JavaScript and CSS: StartPage 250, FolderField 90, MoveDialog 110,
PackagesTab +90, start.html and css 130. Rd: notebooks.Rd, packages.Rd's
`library` fields (line 76), server.Rd.

### Tests

80-100: unit 80-89, request 90-96, end to end 97-100.

### Risks

- **Today's index can change during the day.** PPM may publish today's
  snapshot after the first fetch, and indexes are cached forever ("a dated
  index never changes", resolve.R:84-88), so updating twice on one day can
  miss packages released later that day. Harmless (the lock pins what was
  chosen); tracked in #39.
- **Concurrent writers to the recent file** can lose an entry; writes are
  atomic, so it is never corrupt. Accepted.
- **`chdir` and a busy worker.** The message is read after the running
  cell finishes, so that cell still sees the old folder. Sourced files by
  relative path resolve from the new folder at once in the engine
  (step.R:925); a `source("helpers.R")` that didn't move with the notebook
  becomes a missing file. The form's sentence says so.
- **Parsing renv's and R's text** is not a contract. `install_failures()`
  falls back to "other" with the first `ERROR` line, the log is always
  available, and the fixtures pin the formats known today (renv 1.3.0,
  R 4.6.1).
- **`poll_jobs()` memory**: 400 lines per job, the tail, which holds the
  error.
- **Endeavor** reads `nbpkg.terminal_outputs.nbpkg_sync`; it now gets
  longer text, still one string.
- **Start page polling** every 5 s per open start tab: one request, no
  worker, stopped while hidden.

### Order within the piece

Each step is one commit that leaves CI green.

1. Install failures: `poll_jobs()` keeps the lines, with the
   failing-installer fixture and test 90 (fails before, passes after);
   then `install_failures()`, `ev_install_done`, `packages_view()`,
   `project_ember()`, packages.Rd (tests 80-82); then PackagesTab.js
   failure cards in today's layout (test 99).
2. Update: `apply` proposals, `apply_proposal()`, the three requests, the
   Update button and the in-tab question: tests 83, 84, 95.
3. Move: `chdir` in worker and engine, notebooks.Rd (tests 85, 89, 91);
   then `notebook_target_path()`, `ember_move_notebook`, `FolderField`,
   `completepath`, MoveDialog replacing FilePicker (tests 86, 88, 94, 98).
4. Recent list: R/recent.R, the calls in `host_notebook()` and
   `on_note()`, removal of the localStorage code: test 87.
5. Start page: `start_dir`, `open_or_find()`, the start-page requests,
   start.html, StartPage.js, start.css, `GET /`, `start_server()` opening
   it, server.Rd: tests 92, 93, 96, 97, 100.
   tests/e2e/tests/index-route.test.mjs waits for the script-rendered
   links.

---

## 5. Identity and layout

The page gets Ember's look and frame: Sage colours in light and dark, three
bundled fonts, the left-aligned 720 px column, the sticky header, and the
side panel with Variables, Help, Packages and Status. Cells and outputs are
piece 6's; the Export menu, Settings dialog, shortcuts sheet and keyboard
path are piece 7's. One small engine change: the page learns the
autorun/lazy mode and can change it, and learns the running R's version and
start time. About 1,900 lines of frontend changed or added and 900 deleted
(Pluto's status tree, the bottom-right box, the footer, the header's
process-status strings), 3 font families (about 310 KB), 40 lines of R,
470 of tests; about 30 files.

### Problem

- Both themes keep Pluto's values (themes/light.css:7-273, e.g.
  `--main-bg-color: white` at :7) and switch only by the system setting:
  light.css is wrapped in `@media (prefers-color-scheme: light)`
  (light.css:1), dark.css in the dark one (dark.css:1). A page can't
  choose its theme, and CodeMirror reads the media query once when a cell
  mounts (CellInput.js:493, FilePicker.js:124).
- Fonts are system stacks (editor.css:16-34), and copy-assets.mjs copies
  none.
- The column is Pluto's: `main` is at most 731 px (editor.css:67-74),
  pushed right for the help box (editor.css:88-96: `align-self: flex-end`,
  `margin-right` up to 500 px); centred on narrow windows,
  right-of-centre on wide ones.
- The side panel is Pluto's floating box: `#helpbox-wrapper` a sticky
  zero-height strip (editor.css:2940-2952), `pluto-helpbox` an absolute
  box 70% of the window high (editor.css:2954-2973), hidden below 500 px
  (until piece 7a, with an `alert()`), covering the notebook's bottom
  right, with three tabs (BottomRightPanel.js:16) and a
  picture-in-picture button (BottomRightPanel.js:86-113, 177-181).
- The header (Editor.js:1655-1743) is Pluto's: a big logo, process-status
  sentences with inline restart links (Editor.js:1718-1739),
  "R · 412 MB · Restart" (EmberStatus.js), the export toggle. It scrolls
  away (editor.css:521-536). "N cells not run · Run all" is a bar above the
  notebook (NotRunBar.js, Editor.js:1764). The footer holds Settings and
  FAQ links (Editor.js:1836-1847).
- Safe preview is an outline around the page plus an info popup
  (SafePreviewUI.js:19-76), and every cell says "not executed"
  (Cell.js:302-303, `SafePreviewOutput`).
- The Status tab is Pluto's task tree (StatusTab.js, 304 lines). No
  control for autorun/lazy: the engine has `ev_set_mode` (step.R:44,
  739-742) and the R function `set_cell_change_mode()` (api.R:211-213),
  but no request reaches them, and `project_ember()` (pluto-state.R:
  645-691) doesn't say which mode is on.

### What the user sees

(Boards "C · Sage", "Round 3 · Dark mode", "Wide", "Laptop", "Phone",
"Round 3 · Header and notebook controls", "Round 3 · Side panel tabs",
"Round 6 · Accessibility".)

- Sage colours: a soft green-grey page (`#f5f6f3`), header and panel a step
  lighter (`#fcfcfb`), teal accent. Dark mode uses the Sage dark tokens;
  the panel is a step lighter than the page instead of a shadow. The logo
  stays orange in both.
- Figtree in the header, panel and menus; Source Serif 4 in prose and help
  descriptions; IBM Plex Mono for code. They load from Ember's own server,
  so they work offline and over an SSH tunnel.
- One 720 px column on the left: 120 px from the edge at 1440 px, less on
  narrower windows, the full width with 16 px each side on a phone.
- The header, 52 px high, stays at the top while scrolling. Left to right:
  the flame, the file name (folder in the tooltip; click to rename or
  move), "Saved" in faint grey (no unsubmitted edits), "Run 2 not run"
  while anything can run, the R status as a button ("R ready", with a
  dot), icons for Variables, Help and Packages, Export, and ⋯ (Keyboard
  shortcuts, Settings, Open another notebook). While R runs, the status
  reads "Running 2 of 5 cells" with Stop beside it.
- The side panel is 400 px wide on the right. From 1240 px it sits in the
  free space and the notebook doesn't move when it opens; below that it
  slides over the notebook (380 px, with a shadow); at 640 px and below it
  is a sheet from the bottom over a dimmed page, closed by tapping the
  page. A header icon opens the panel at its tab, or closes it if that tab
  is showing; the R status opens Status. On a phone the three icons are
  one.
- Tabs: **Variables** (a filter; Name, Type, Value; click a name to go to
  its cell; stale variables faint; a footer with the count and R's
  memory), **Help** (back, forward, search; description and arguments in
  serif, usage and examples in mono), **Packages** ("Versions as of
  <date>", with piece 4's Update and failure cards), **Status** (R's state,
  memory, version and uptime; Interrupt and Restart R; not-run and error
  counts with "Run them" and "Go to it"; "When a cell changes" with the two
  choices).
- Safe preview is one banner under the header: "Safe preview: nothing in
  this notebook has run. Read the code, then run it if you trust it.
  Packages it needs install first." and "Run this notebook". No cell says
  "not executed".
- No footer. Memory and Restart R are no longer in the header.

### Shape

**Rules touched.** `status_tree`, `process_status` and `nbpkg` are still
projected although the page stops reading `status_tree`. Three new `ember`
fields. One new request, `ember_set_mode`. No worker message. Kept:
`header#pluto-nav` (Endeavor hides it, theme.ts:253), `main
pluto-notebook`, `#helpbox-wrapper`, `pluto-helpbox`, `pluto-helpbox >
header`, `pluto-helpbox > section`, `.live-docs-searchbox`,
`#live-docs-search` (drawer.ts:83-93, 156), the `open_bottom_right_panel`
event with detail `"docs"` (drawer.ts:147, 318), and every CSS variable
name. Endeavor reads `--main-bg-color`, `--pluto-cell-spacing`,
`--sans-serif-font-stack`, `--indented` (set by CodeMirror, not the
themes), `--normal-cell-color`, `--selected-cell-color` and
`--code-differs-cell-color` (errors.ts:29-31, diff.ts:21, asking.ts:14,
prompt.ts:32, theme.ts:287); each theme-file one stays defined, mapped onto
the tokens, and the three cell colours join endeavor-css-variables.txt.

**Tokens.** Ember's tokens are new `--ember-*` variables; every Pluto name
keeps existing and is set to one of them. Values are from ui-3.md
(Identity) and, where it is silent, from the last board that uses the
token. This piece defines every token the frontend pieces use, so pieces 6
and 7 only add the few listed there.

| token | light | dark | from |
|---|---|---|---|
| `--ember-page` | `#f5f6f3` | `#151917` | ui-3.md |
| `--ember-panel` | `#fcfcfb` | `#1b201d` | ui-3.md |
| `--ember-code` | `#eceeea` | `#212723` | ui-3.md |
| `--ember-line` | `#dce1db` | `#2f3631` | ui-3.md |
| `--ember-text` | `#1b201d` | `#dfe5e0` | ui-3.md |
| `--ember-muted` | `#57605a` | `#9ba59e` | ui-3.md |
| `--ember-faint` | `#636c65` | `#88928b` | ui-3.md, A11y6 |
| `--ember-accent` | `#22715f` | `#6cc7b2` | ui-3.md |
| `--ember-on-accent` | `#ffffff` | `#0f1a16` | Header3 `.btn.primary` |
| `--ember-accent-bg` | `#e3efeb` | `#1f3a33` | Header3, Panel3 |
| `--ember-active` | `#e3e7e2` | `#29302b` | Header3 `.ibtn.on` |
| `--ember-hover` | `#eef1ed` | `#232925` | Outputs4, Index5 |
| `--ember-logo` | `#e8590c` | `#f07032` | ui-3.md |
| `--ember-run` | `#2f5fae` | `#8fb4f0` | Header3, Panel3 |
| `--ember-amber`, `-amber-bg` | `#7a5a12`, `#f5ecd6` | `#dcb35a`, `#352d1b` | Header3, Menus6 |
| `--ember-red`, `-red-bg` | `#a8322a`, `#f8e6e3` | `#f08a80`, `#3a2321` | Panel3 |
| `--ember-rail-idle`, `-run`, `-due`, `-err` | `#d3d8d2`, `#7f9ccc`, `#cdb06e`, `#d48b83` | `#353c37`, `#6f8cbf`, `#a8904f`, `#b06a63` | Cells, Dark3 |
| `--ember-err-bg`, `-err-line`, `-due-bg`, `-due-line`, `-wash`, `-dis-bg` | `#faeae7`, `#efc9c3`, `#f6eedb`, `#e2cc95`, `#eceeea`, `#e6e9e5` | `#2c201e`, `#4a302c`, `#2c2719`, `#5a4b29`, `#1e2420`, `#202522` | Cells |
| `--ember-syn-kw`, `-fn`, `-str`, `-num`, `-com` | `#7b4a91`, `#22715f`, `#5d6b12`, `#a0521a`, `#636c65` | `#c9a3e0`, `#6cc7b2`, `#c3cf7a`, `#f0ae79`, `#8f988f` | Cells |
| `--ember-ansi-red`, `-green`, `-yellow`, `-blue`, `-magenta`, `-cyan` | `#b42318`, `#2b7a4b`, `#8a5a00`, `#2459b8`, `#8e3a9a`, `#0e7490` | `#f2948a`, `#86d19f`, `#e6c46f`, `#93b6f2`, `#d7a4e6`, `#7fd0de` | Outputs4 |
| `--ember-shadow` | `0 6px 24px rgba(20,28,22,0.14)` | `0 6px 24px rgba(0,0,0,0.5)` | Header3 |
| `--ember-panel-shadow` | `-10px 0 30px rgba(20,28,22,0.16)` | `-10px 0 30px rgba(0,0,0,0.55)` | Laptop |
| `--ember-scrim` | `rgba(20,28,22,0.3)` | `rgba(0,0,0,0.5)` | Phone |

The light comment colour is the faint grey `#636c65` (4.7 : 1 on code),
not the Cells board's `#6e766f` (4.0 : 1). Faint text is never used on the
hover or active backgrounds (`#636c65` on `#e3e7e2` is 4.35 : 1); a hovered
menu item's key hint uses muted. The Wide, Laptop and Phone boards use older
values in places (`--faint: #8b948d`, a darker dark page `#131614`);
ui-3.md and the Round 3 and Round 6 boards win.

Pluto names, in groups (each set in both files): page and chrome
(`--main-bg-color`, `--pluto-output-bg-color`, `--overlay-button-bg` to
page; `--header-bg-color`, `--helpbox-bg-color`,
`--input-context-menu-bg-color`, `--autocomplete-menu-bg-color`,
`--pkg-popup-bg` to panel; `--rule-color`, `--header-border-color`,
`--table-border-color`, `--helpbox-search-border-color` to line); text
(`--pluto-output-color`, `--pluto-output-h-color`, `--helpbox-text-color`,
`--nav-h1-text-color`, `--ui-button-color`, `--cm-color-editor-text`,
`--black` in light, to text; `--helpbox-notfound-search-color`,
`--index-light-text-color`, `--pluto-schema-types-color`,
`--cm-color-line-numbers` to faint); code (`--code-background`,
`--code-section-bg-color`, `--helpbox-search-bg-color`, `--blockquote-bg`);
cells (`--normal-cell-color` to rail-idle, `--code-differs-cell-color` to
rail-due, `--selected-cell-color` to `color-mix(in srgb,
var(--ember-accent) 40%, transparent)`, `--error-cell-color` to rail-err;
the `--normal-cell`, `--code-differs`, `--error-color` triplets used in
`rgba(var(...))` become the RGB of rail-idle, amber and red); syntax
(`--cm-color-keyword`, `--cm-color-control-operator` to syn-kw;
`--cm-color-function`, `--cm-color-definition`, `--cm-color-builtin` to
syn-fn; `--cm-color-string` to syn-str; `--cm-color-literal`,
`--cm-color-symbol` to syn-num; `--cm-color-comment` to syn-com;
`--cm-color-variable`, `--cm-color-bracket` to text); process
(`--process-busy` to run, `--process-finished` to accent,
`--process-failed` to red). Names only Julia or deleted features use keep a
token value close to their role. `--image-filters` becomes `none` in dark
mode: the header draws the logo inline in `--ember-logo`.

**Theme switching.** This piece owns the theme: the `THEME` setting,
`common/theme.js` and the `[data-theme]` selectors. Piece 7 only adds the
Settings row.

```css
/* themes/light.css */
:root { color-scheme: light; --ember-page: #f5f6f3; ... ; --main-bg-color: var(--ember-page); ... }
/* themes/dark.css */
:root[data-theme="dark"] { color-scheme: dark; --ember-page: #151917; ... }
```

No media query in either file. `<html>` always carries `data-theme="light"`
or `"dark"`, set by:

- a small classic script inlined at the top of editor.html's `<head>`,
  before the stylesheet, so the first paint is right: read
  `localStorage["pluto_setting_THEME"]` (JSON, as `get_settings()` reads
  it, Settings.js:208-222; `"system"` when absent or unreadable), resolve
  `"system"` with `matchMedia("(prefers-color-scheme: dark)")`, set the
  attribute;
- `common/theme.js` (new, about 50 lines): `apply_theme()` does the same
  and follows the media query's `change` while the setting is `"system"`;
  `is_dark_theme()` reads the attribute; a window event
  `ember theme change` fires on every switch.

`DEFAULT_SETTINGS` (Settings.js:194-203) gains `THEME: "system"`.
CellInput.js:493 and FilePicker.js:124, 166 call `is_dark_theme()`, and
CellInput puts `EditorView.theme({}, { dark })` in a compartment
reconfigured on `ember theme change`. editor.html's `theme-color` metas
(editor.html:10-11) become `#fcfcfb` and `#1b201d`. The one editor.css rule
under the media query (editor.css:4353, `.cm-selectionMatch`) moves to
`:root[data-theme="dark"]`. Exports keep editor.html's head, so the inline
script comes along; an exported file follows its viewer's setting.

**Fonts.** Bundled, so the page works with no internet (increment 2's
rule), about 310 KB:

| family | npm package (pinned in frontend-build/package.json) | files copied | bytes |
|---|---|---|---|
| Figtree | `@fontsource-variable/figtree` 5.3.0 | `figtree-{latin,latin-ext}-wght-{normal,italic}.woff2` (weights 300-900 in one file) | 61,740 |
| Source Serif 4 | `@fontsource-variable/source-serif-4` 5.3.0 | `source-serif-4-{latin,latin-ext}-wght-{normal,italic}.woff2` (the `wght` axis only; `opsz` is 2.4 times larger) | 188,640 |
| IBM Plex Mono | `@fontsource/ibm-plex-mono` 5.3.0 | `ibm-plex-mono-{latin,latin-ext}-{400,500}-normal.woff2` | 56,376 |

The shipped frontend is 2.12 MB today (ui-2-tests.md 14 caps it at 3 MB)
and becomes about 2.43 MB. No italic Plex Mono (nothing sets code in
italic); no Greek or Cyrillic subsets (they fall back per character through
each `@font-face`'s `unicode-range`).

- `scripts/copy-assets.mjs` copies the 12 files into
  `inst/frontend/fonts/` with content-hashed names (`copyHashed()`), plus
  each package's licence (SIL Open Font License 1.1) as
  `fonts/OFL-<family>.txt`; its "No font files are copied" comment goes.
- `build.mjs` writes `inst/frontend/fonts.css`: one `@font-face` per file,
  `font-display: swap`, the package's `unicode-range`, `font-weight: 300
  900` for variable files, the hashed name. editor.css imports it after the
  dialog polyfill (editor.css:3).
- R/server.R serves `fonts/` with the immutable cache header used for
  `imports/vendor/`.
- editor.css:16-34 become:

  ```css
  --ember-ui-font: "Figtree", ui-sans-serif, system-ui, sans-serif;
  --ember-prose-font: "Source Serif 4", ui-serif, Georgia, serif;
  --ember-code-font: "IBM Plex Mono", ui-monospace, "SF Mono", Menlo, monospace;
  --sans-serif-font-stack: var(--ember-ui-font);
  --system-ui-font-stack: var(--ember-ui-font);
  --lato-ui-font-stack: var(--ember-ui-font);
  --julia-mono-font-stack: var(--ember-code-font);
  --roboto-mono-font-stack: var(--ember-code-font);
  --system-fonts-mono: var(--ember-code-font);
  --ember-prose-font-stack: var(--ember-prose-font);
  ```

  The hard-coded `font-family: monospace` at editor.css:825, 2679, 2757
  become `var(--ember-code-font)`; the header's
  `var(--roboto-mono-font-stack)` (editor.css:533) becomes the UI font.
  `--custom-code-font-stack` stays until piece 7 removes the setting.
- `inst/COPYRIGHTS` gets one entry per font. Exports grow by about 310 KB,
  since `export_html()` turns every local `url()` into a `data:` URL.

**Layout** (editor.css, replacing editor.css:67-74 and 88-96):

```css
:root {
    --ember-column: 720px;
    --ember-panel-width: 400px;
    --ember-header-height: 52px;
    --ember-column-left: clamp(16px, calc((100vw - var(--ember-column)) * 0.17), 120px);
}
pluto-editor main {
    align-self: flex-start;
    margin-left: var(--ember-column-left);
    margin-right: 0;
    max-width: calc(var(--ember-column) + 25px + 6px);
}
@media (max-width: 640px) {
    pluto-editor main { margin-left: 0; padding-left: 16px; padding-right: 16px; max-width: none; }
}
```

The 25 px and 6 px are Pluto's `main` padding where the cell's left
controls sit; piece 6 removes them when it moves the run button, making
the column exactly 720 px. The 0.17 factor gives 120 px at 1440 (Wide) and
64 px at 1100 (Laptop). The column doesn't depend on the panel. Docking
needs `left + 720 + 24 <= window - 400`, which first holds at 1240 px
(88 + 720 + 24 = 832 <= 840); ui-3.md's "roughly 1200 px" becomes 1240, the
nearest width that never overlaps. `html` gets `scroll-padding-top:
var(--ember-header-height)` so jumps to a cell land below the sticky
header.

**Header** (new `components/Header.js`, about 250 lines, replacing
Editor.js:1655-1743 and `EmberStatus.js` inside the kept `<header
id="pluto-nav">`):

- `position: sticky; top: 0; height: var(--ember-header-height)`, panel
  background, a line underneath, UI font. The export banner's
  `show_export` slide (editor.css:538-543) stays until piece 7.
- Logo: the flame as inline SVG with `fill: var(--ember-logo)`, 22 px,
  inside the kept `<a href="./">` and `<h1>`. `img#logo-big` and
  `img#logo-small` go (only ember-look.test.mjs reads them);
  `img/logo.svg` stays for exports and the start page.
- File name: piece 4's `#ember-file-name` button and MoveDialog, placed
  and styled here.
- "Saved": faint, shown while connected and no cell has local edits
  (`status.code_differs` false, the flag Preamble uses); hidden below
  720 px. The engine doesn't track whether the last write succeeded
  (state.R:477), and a failed save isn't shown today either.
- "Run N not run": `NotRunBar.js` becomes a header button, same data
  (`notebook.ember.not_run`) and action (`ember_run_all`), label
  `t_ember_run_not_run` ("Run {{count}} not run"), title "{{count}} cells
  haven't run". `#ember-not-run-bar` and its place (Editor.js:1764) go.
- R status: `<button id="ember-r-status">`, a dot and words, opens the
  panel at Status:

  | state | dot | words |
  |---|---|---|
  | not connected | faint | Reconnecting |
  | `preview` | faint | R not started |
  | `starting` | run | R starting |
  | `ready` | accent | R ready |
  | `busy` | run | Running {{i}} of {{n}} cells, then Stop (`interrupt_all`) |
  | `stopped` | red | R stopped |
  | ready, `plan.restart` non-empty | amber | R ready (title: Restart R to use the new versions of: …) |

  `i` and `n` come from a hook `use_run_progress(notebook)` taken out of
  ProgressBar.js:15-35 (its `recently_running`/`currently_running`
  counting), which ProgressBar then uses too: `n` = recently running,
  `i` = done + 1, capped at `n`. The process-status sentences and inline
  restart links (Editor.js:1718-1739) and their strings go.
- Panel icons: `<nav aria-label="Side panel">` with three 34 px icon
  buttons (Variables, Help, Packages), each `aria-pressed` while its tab
  shows. A click dispatches `open_bottom_right_panel` with the tab, or
  `null` when that tab is open.
- Export: today's `button.toggle_export` restyled as an icon button; it
  toggles `export_menu_open` until piece 7.
- ⋯: built on 7a's `useMenu`: Keyboard shortcuts (today's handler until
  piece 7's sheet), Settings (dispatches `pluto open settings`), a
  separator, Open another notebook (`./?secret=<secret>`, piece 4's start
  page; the editor reads the secret from its own URL, since `/` needs it
  in the query, server.R:1168). The footer's Settings and FAQ links go
  with the footer.
- Below 641 px: one "Side panel" icon opens the last tab used (Help by
  default); Export moves into ⋯; the R status shows only its dot, its words
  in `aria-label` and `title`.
- Icons are inline SVGs from the boards (stroke `currentColor`) in a new
  `common/Icons.js`; no new ionicons.

**Safe preview banner.** SafePreviewUI.js:19-76 becomes one bar under the
header (`#ember-safe-preview`, accent-bg), then the plan sentence from
`plan_text()` (kept, SafePreviewUI.js:12-17) when it installs or restarts
something, then a primary "Run this notebook" that calls `restart(true)`
as the popup's link does today. The outline, the info button and the popup
go. `SafePreviewOutput` and its use in Cell.js:302-303 go, so a cell in
preview shows its code and no output. `SafePreviewSanitizeMessage`
(CellOutput.js:30, TreeView.js:8) stays: it marks HTML not rendered.

**Side panel** (BottomRightPanel.js rewritten, about 250 lines; name and
exports kept, since Endeavor dispatches its event):

- DOM: `<aside id="helpbox-wrapper" class="ember-panel-{docked|over|sheet}">`
  holding `<pluto-helpbox>` with `<header>` (four `role="tab"` buttons in a
  `role="tablist"`) and `<section role="tabpanel">`. In sheet mode a
  sibling `div.ember-scrim` closes the panel on click.
- `PanelTabName` (BottomRightPanel.js:16) becomes `"variables" | "docs" |
  "packages" | "process" | null`; `"docs"` and `"process"` keep their names
  because Endeavor sends `"docs"`.
- CSS (replacing editor.css:2940-2973 and the `pluto-helpbox > header`
  rules after it):

  ```css
  #helpbox-wrapper { display: none; }
  #helpbox-wrapper.open { display: block; position: fixed; z-index: 50;
      top: var(--ember-header-height); right: 0; bottom: 0; width: var(--ember-panel-width);
      background: var(--ember-panel); border-left: 1px solid var(--ember-line); }
  @media (max-width: 1239px) { #helpbox-wrapper.open { width: 380px; box-shadow: var(--ember-panel-shadow); } }
  @media (max-width: 640px) { #helpbox-wrapper.open { top: auto; left: 0; width: auto;
      height: min(560px, 70dvh); border-radius: 14px 14px 0 0; border-left: 0;
      border-top: 1px solid var(--ember-line); } }
  ```

  Tabs per Panel3 (13 px, weight 500, 2 px accent underline). The
  picture-in-picture button, the close button, the busy outline and
  counter (BottomRightPanel.js:63-82) and the `console.log` (:52) go.
- `NotifyWhenDone` stays mounted (BottomRightPanel.js:210-213) with the
  `status` it gets today from `notebook.status_tree` via
  `useWithBackendStatus` (BottomRightPanel.js:63): it uses StatusTab.js's
  `is_finished` and `total_done` (NotifyWhenDone.js:4, 21, 39), so those
  two exports and that `status` plumbing stay. Piece 7 replaces
  NotifyWhenDone and deletes them then. `useStatusItem` and `total_tasks`
  go with the busy counter.

**Variables tab** (new `components/VariablesTab.js`, about 140 lines).
It collects piece 3's per-cell lists: for each id in `cell_order`, each
entry of `cell_results[id].ember.variables`, with the cell id and that
cell's `ember.stale`. Filter field (Panel3), then a table Name / Type /
Value (26%, 26%, rest), sorted by name with `localeCompare`. Value by
`kind`: `value` in mono, text colour; `shape` in faint; `str` in faint
italic; `none` empty. A stale row is all faint. Name is a link that scrolls
to and selects the cell (`scroll_cell_into_view`, Scroller.js, and
`selected_cells`). Footer: "{{count}} variables" and "R using {{mb}} MB"
(`ember.worker_memory`). Empty: "Variables appear here once a cell defines
one."; in preview: "Nothing has run yet."

**Help tab** (LiveDocsTab.js, about 60 lines added): back/forward over the
queries shown (an array and an index in component state; a query from the
cursor pushes like a typed one), two icon buttons before the kept
`.live-docs-searchbox`. R help HTML (Rd2HTML, R/editor-services.R:238-258):
`p`, `dd` and argument cells in the prose font; `pre` and `code` in the code
font on `--ember-code`; `h2` 20 px weight 600 and `h3` 13 px weight 600 in
the UI font; a "stats · follows the cursor" line above the title from the
package name the reply carries. Piece 2's notebook-function page
(`.ember-def-*`) gets the same styles.

**Packages tab** (PackagesTab.js restyled): Panel3's layout: "Versions as
of {{snapshot}}" with piece 4's Update, "The packages this notebook loads,
installed for it alone.", a table Package / Version / Status with pills
(accent-bg "Installed", a run-coloured bar for "Installing", red-bg
"Failed", faint "Missing"), and piece 4's failure cards. Only `row.direct`
rows are listed (dependencies hidden). `#ember-packages-tab` and
`.ember-package-row` stay (status-views.test.mjs reads them).

**Status tab** (StatusTab.js rewritten, about 200 lines; the task tree,
`friendly_name`, `global_order`, `PkgTerminalView` and DiscreteProgressBar
go, about 300 lines):

- "R": State (dot and words as in the header, plus "· {{seconds}} s" for
  the running cell from its `cell_results[id].running` start), Memory,
  Version (`ember.r_version`), Started ("14 minutes ago", from
  `ember.worker_started_at` and `useMyClockIsAheadBy`, re-rendered every
  30 s). Interrupt (`interrupt_all`, disabled unless busy) and Restart R
  (`restart(true)`, Editor.js:1591-1630), with "Restarting clears every
  variable; cells stay as they are, marked not run." When `plan.restart`
  is non-empty: "Restart R to use the new versions of: …".
- "Notebook": Cells (count of `cell_order`), Not run (`ember.not_run`,
  "Run them" = `ember_run_all`), Errors (cells with
  `cell_results[id].errored`, "Go to it" = scroll to the first).
- "When a cell changes": a radio group, "Rerun the cells that depend on it"
  (`autorun`) and "Mark them stale and let me run them" (`lazy`), checked
  from `ember.on_cell_change`; a change sends `ember_set_mode`. Disabled
  when read-only.
- `prettytime` is imported from piece 6's `common/prettytime.js` once that
  lands; until then from RunArea.js (StatusTab.js:4 imports it today).

**Engine and server**, one commit with the Status tab:

- `reduce_wk_hello()` (step.R:840-846) sets `state$worker$started_at <-
  event$at`; the places that reset the worker (step.R:195-200) set it to
  `NULL`.
- `project_ember()` (pluto-state.R:645-691) returns three more fields:

  ```r
  on_cell_change = state$file$header$on_cell_change,      # "autorun" | "lazy"
  r_version = state$worker$info$r_version %||% NULL,       # running R, from hello
  worker_started_at = if (is.null(state$worker$started_at)) NULL
                      else as.numeric(state$worker$started_at)
  ```

  `r_version` and `worker_started_at` are `NULL` in preview, before hello,
  and when stopped. `check_wire()` covers them unchanged.
- `ember_set_mode`, a request-table row:

  ```r
  #' | ember_set_mode | {mode}: "autorun" or "lazy", else refused; refused when read-only. set_cell_change_mode(nb, mode); flush. No reply |
  ember_set_mode = function(server, cl, hub, req) {
    if (is.null(hub)) return(invisible(NULL))
    mode <- req$body$mode
    if (!(is.character(mode) && length(mode) == 1 && mode %in% c("autorun", "lazy"))) {
      stop(refusal("ember_set_mode: mode must be \"autorun\" or \"lazy\""))
    }
    if (isTRUE(notebook_snapshot(hub$nb)$read_only)) stop(refusal("read-only notebook"))
    set_cell_change_mode(hub$nb, mode)
    flush_clients(server, hub)
  }
  ```

  (`refusal()` raises an `ember_refused` condition, caught and logged as
  `on_update_notebook` does, server.R:606.) The page adds
  `ember_set_mode(mode)` next to `ember_run_all`.

**Removed**: the footer (Editor.js:1836-1847), `EmberStatus.js`,
`NotRunBar.js` as a bar, the picture-in-picture code, Pluto's StatusTab
tree, the process-status strings only the old header used
(`t_process_restart_action*`, `t_process_exited_restart_action`,
`t_process_give_permission_to_run_code`, `t_panel_popout`,
`t_panel_close`, `t_panel_status_progress*`), the header's `.flex_grow_*`
rules and Pluto's logo sizing (editor.css:1005-1060).

### Tests

101-126: unit 101-107, request 108-109, end to end 110-126.

### Risks

- **The theme files are one big edit.** 200-odd names changing value at
  once can make an old Pluto rule unreadable (a white `--white` used as
  text on a now-light background). Check every screen in both themes by
  eye; keep names of deleted features at harmless values (test 105).
- **Endeavor's overrides.** Endeavor sets cell colours under
  `html[data-endeavor-look]` (theme.ts:146-149, 203-204) and restyles
  `pluto-helpbox` (drawer.ts:83-93). The panel's `position: fixed` on
  `#helpbox-wrapper` could fight its `position: static` on
  `pluto-helpbox`; Endeavor hides `#helpbox-wrapper` unless its drawer
  shows docs, then expects the helpbox to fill it. Test 123 covers the
  hooks, not the look; check in Endeavor by eye. Endeavor also follows the
  system theme (theme.ts:77, 139, 196), so an Ember set to Dark on a light
  system shows Endeavor's overrides in light colours (#62).
- **Exports get 310 KB larger.** If it matters, `export_html()` can embed
  only the Latin files (about 160 KB).
- **Sticky header** covers what Pluto scrolls to the top
  (`scroll_cell_into_view`, jump links); `scroll-padding-top` handles it.
  Check that SelectionArea.js still starts below the header.
- **`data-theme` before CSS** depends on the inline script; a
  Content-Security-Policy that blocks inline scripts would break it (Ember
  sets none). Without it the page renders light until `apply_theme()`.
- **Plex Mono is wider than Menlo**: code that fit on one line may scroll.
  The 720 px column is about 80 characters at 13 px with the gutter,
  matching R's 80-column style.

### Order within the piece

Each step ends with the page working and CI green.

1. Fonts: npm packages, copy-assets, `fonts.css`, server cache header,
   COPYRIGHTS: tests 103, 104, 107, 116.
2. Tokens and theme switching: new theme files, inline script,
   `common/theme.js`, `THEME`, the CodeMirror compartment, the Endeavor
   variables fixture: tests 105, 106, 115.
3. Layout: column, sticky header shell, `scroll-padding-top`: tests 110,
   114.
4. Side panel frame: three modes, tab strip, Endeavor hooks, deletions:
   tests 111-113, 123.
5. Engine and server: `started_at`, three `ember` fields,
   `ember_set_mode`: tests 101, 102, 108, 109.
6. Header contents: logo, file name, Saved, run button, R status with
   progress and Stop, panel icons, Export, ⋯; delete EmberStatus, the
   NotRunBar bar, the footer, old status strings: tests 117-119, 124-126.
7. Safe preview banner; delete the per-cell label: test 120.
8. Tabs: Status, Help history and styling, Packages layout, Variables:
   tests 117, 121, 122.

---
## 6. Cells and outputs

Every cell and output is restyled to the boards "Round 2 · Cells and status
rails" (Cells), "Round 4 · Outputs" (Outputs4) and "Round 5 · Adding cells;
text is just #' lines" (Insert5), with dark values from "Round 3 · Dark
mode" (Dark3). Mostly page code and one new stylesheet, plus small
additive worker and projection changes for data the design shows and the
page doesn't get: where an error happened and which package each traceback
call belongs to, the call behind a warning, NA cells and "more" counts in
tables, long vectors in trees. About 1,900 lines changed across 20 files:
about 900 lines of editor.css cell rules deleted and 650 in a new
`cells.css`, about 900 lines of JavaScript, 150 of R, 450 of tests. Two
branches: **6a** cell chrome (steps 1-4) and **6b** errors, outputs and
text cells (steps 5-9); each ends in a running page.

### Problem

Cells look and behave like Pluto's:

- The status bar is Pluto's striped `pluto-trafficlight`, hidden on folded
  and unhovered cells (editor.css:2020-2140), animating stripes while
  running.
- The run button and run time sit in `pluto-runarea` at the code's bottom
  right (RunArea.js:66-72; editor.css:2839-2910); a queued cell offers no
  Stop.
- The cell menu has Delete, Copy output and piece 1's Disable cell
  (CellInput.js:909-927); its button is titled "Actions", untranslated
  (CellInput.js:886). Hide code is the eye on `pluto-shoulder`
  (Cell.js:296-300).
- Status is small labels at the top right, "stale" and "code changed"
  (Cell.js:69-76, 284; editor.css:1781-1815), with the output dimmed to
  0.3.
- The "+" buttons are Pluto's (editor.css:2251-2273). An empty notebook
  shows "Enter cell code..." (english.json:66) and no hints.

Outputs:

- Errors use Pluto's `jlerror` layout: "Error message", "Show stack
  trace...", then every call at the same weight (ErrorMessage.js:566-622).
  The engine keeps only the message and the deparsed traceback
  (`new_run_error()`, state.R:227-230) and drops the worker's `call`
  (worker.R:372). Nothing records the cell's line or a call's package;
  `project_error()` sends `file = ""` and `source_package = NULL` for every
  frame (pluto-state.R:424-436).
- Tables put "more" in the last header cell and last row, without counts
  (TreeView.js:236, 248-250); the size reads "32 × 11"
  (pluto-state.R:368); NA can't be told from the text "NA" (worker.R:
  1185-1187).
- Trees show `list(a = 1, …)` collapsed (TreeView.js:179-187); a long
  vector is a leaf with the first line of `str()` (`leaf_text()`,
  worker.R:1207-1215).
- Console output is Pluto's log list: a coloured box, a dot per item, a
  link explaining stdout (Logs.js:108-171; editor.css:3750 on). A warning
  has no call (worker.R:1012 keeps only `conditionMessage(w)`).
- ANSI colours use ansi_up's default palette (ansi-colors.css:3-20); cli's
  256-colour codes (`38;5;n`) come out as inline `rgb()` that no theme can
  adjust (ansi_up's `use_classes` covers only the 16 base colours).
- Text cells use the page's default markdown styles; opening one means the
  fold eye.

### What the user sees

Exact values from the boards.

**Cell anatomy** (Cells). The output sits above the code. The code box has
a 34 px line-number gutter, 7 px 12 px padding, Plex Mono 13 px with 1.65
line height, and piece 5's syntax colours. Corners `0 6px 6px 0`, flush with
the rail. The output starts 12 px right of the rail, 12 px above the code.

**Rail.** A 4 px bar on the cell's left edge, the full height of the cell,
always shown, including on folded and text cells:

| state | light | dark | notes |
|---|---|---|---|
| idle: up to date, not run, stale, disabled | `#d3d8d2` | `#353c37` | |
| running | `#7f9ccc` | `#6f8cbf` | pulses: opacity 1 → 0.45 → 1 over 1.6 s; solid under reduced motion |
| queued | `#7f9ccc` at 0.4 | `#6f8cbf` at 0.4 | |
| edited, not run | `#cdb06e` | `#a8904f` | code box: 1 px inset outline `#e2cc95` / `#5a4b29`, gutter `#f6eedb` / `#2c2719` |
| error | `#d48b83` | `#b06a63` | |

Hovering an amber rail shows "Press Shift + Enter to run this cell" at its
top left (Figtree 11 px, weight 500, panel background, 1 px line border,
5 px radius). Precedence: running, queued, edited, error, idle; an edited
cell that also has an error shows amber, because the error belongs to code
that has since changed. "Edited" is the page's own unsubmitted edit
(`.code_differs`) or code changed outside the page (`ember.code_changed`);
there is no "code changed" label (Words6).

**Run button.** A 26 px accent circle with a play icon in `--ember-on-accent`,
on the code box's top-left corner (`left: -15px; top: -13px`), overlapping
the rail; shown on hover or keyboard focus within the cell, and always on
the focused cell on touch screens (`@media (hover: none)`). While the cell
runs or is queued it is Stop: rail-blue, a 10 px square. Name and tooltip:
"Run cell (Shift + Enter)" or "Stop (Ctrl + Q)". Not shown on a disabled
cell or a cell that depends on one: the disabled cell's action is the
menu's Enable cell, the dependent's is its chip's "Go to it".

**Run-time chip.** The last run time ("0.04 s", "1 min 3 s") on the code's
bottom-right corner (`right: 8px; bottom: -9px`): Figtree 10.5 px, weight
500, muted, panel background, 1 px line border, pill. Shown on hover or
focus; counts up while the cell runs.

**Cell menu.** ⋯, a 26 px button at the code's top right (`right: 6px;
top: 5px`), named "Cell options". A 200 px menu built on 7a's `useMenu`:
panel background, 1 px line border, 8 px radius, the panel shadow, Figtree
13 px. Items: Hide code (Show code when hidden); Disable cell (Enable cell
when disabled; code cells other than the setup cell, from
`ember.can_disable`); Copy output (only when there is something to copy);
Move up ("Alt ↑", ⌥ on a Mac); Move down ("Alt ↓"); a separator; Delete
cell in the error colour.

**Adding cells** (Insert5). Hovering the gap between cells, above the first
or below the last, shows a 1 px accent line at 0.45 opacity across the gap
with an 18 px circle at its left end (page background, 1 px accent border,
accent "+"). Both lie over the gap, so nothing moves. Name: "Add a cell
here".

**Chips** (Cells, "Tinted (in the notebook)"). Where the output is or would
be; Figtree 12 px, weight 500, a 12 px icon, pill, padding
`2px 10px 2px 8px`.

- "Not run yet": a circle icon, panel background, line border, muted text,
  no output. Shown when the cell has never run, isn't queued or running,
  isn't blank, isn't off, isn't text, and the page isn't in safe preview
  (piece 5's banner says it once).
- "Stale · `x` changed": a clock icon, `#f5ecd6` background, `#e6d3a3`
  border, `#6f5210` text (dark `#352d1b`, `#58492a`, `#dcb35a`). The old
  output is greyscale at 0.32 opacity on a wash (`--ember-wash`) joined to
  the code box, the chip under it inside the wash. `x` is the names this
  cell reads from an upstream cell that ran after it or is itself stale
  ("Stale · x, y changed"; just "Stale" when none is known, e.g. a sourced
  file changed). Only lazy mode produces stale cells.
- "Disabled": a slashed-circle icon, solid `#e6e9e5` background and border
  (dark `#262b27`), text `#5c655e` / `#a0aaa2` (the board's `#7d867f` is
  3.4 : 1; darkened to pass 4.5 : 1). The code sits on `--ember-dis-bg`
  with gutter and text at 0.5 opacity. A cell that depends on a disabled
  cell shows "Depends on a disabled cell. Go to it", with "Go to it" a
  link (Words6). Both keep the last output below the chip, greyed as for
  stale.

**Errors** (Cells, Outputs4). The error replaces the output as a red-tinted
box (`--ember-err-bg`) joined to the code box with no gap; the box's
corners are `0 6px 0 0` and the code box loses its top-right radius.
Padding 10 px 14 px. Inside:

- The message, 14 px, weight 600, `--ember-red`.
- A muted 12.5 px line: "Error in `predict(fit, newcars)` · line 1" when
  the failing call is the cell's own expression on that line; "Error in
  `model.frame.default(…)` · called from line 1" when it is deeper; "Error
  · line 2" when R gives no call (`stop()` at top level). The call is mono;
  longer than 48 characters it shows as `name(…)`.
- "▸ Show traceback (3 calls)", a text button; opened it becomes "▾ Hide
  traceback" above a dashed `--ember-err-line` border. The traceback is a
  3-column grid: number, call in mono (one line, ellipsis), and where it
  comes from in the UI font ("this cell, line 1", "notebook" for a function
  defined in another cell, or the package name). Notebook calls are full
  strength, package calls faint. Outermost first.
- Piece 1's "Another cell defining **x** contains errors." in italic, with
  `x` linking to that cell, and no traceback.
- A parse error: message and "line n", no traceback. "Interrupted": no
  line, no traceback.

**Outputs** (Outputs4).

- **Data frame.** The top-left header cell gives the size in words, muted,
  weight 500: "32 rows × 11 columns", "1 row × 1 column", "0 rows × 3
  columns". Column names mono 600, right-aligned; under each, its type
  without angle brackets ("dbl"), 11 px, faint, with a 1 px line under the
  type row. Row names in the UI font, left-aligned; values mono,
  right-aligned, padding `3px 14px 3px 0`; `NA` faint; a row tints on hover
  (`--ember-hover`). Under the table, accent text buttons "Show 26 more
  rows" and "Show 5 more columns", each only when its count is above 0;
  they load from R as today.
- **List.** A tree with the root open: "▾ list of 3" in the UI font, muted.
  Each item is a row of a 16 px disclosure, a 70 px key and the value. A
  nested list starts collapsed ("▸ list of 1"). A long atomic vector shows
  its first ten values, then "… int, 100 values" (UI font, 11 px, faint). A
  list with more items than shown ends in "Show 60 more".
- **Printed text**: exactly what R prints, mono 13 px, 1.55 line height, no
  box, no background.
- **Console output** below the code, no box: mono 12.5 px, padding
  `8px 12px 2px`. `message()` text muted, printed text normal, cli colours
  from the palette. A warning gets an amber wash (`--ember-due-bg`, 4 px
  radius, `3px 8px`) reading "**Warning** in `cor(cars$mpg, cars$hp)`: the
  standard deviation is zero", the bold word in `--ember-warn-text`
  (`#7a5a12` / `#e6c46f`); without a call, "**Warning**: …". The
  60-first / 20-last truncation stays (Logs.js:9-10), with "N lines not
  shown".
- **ANSI palette**: piece 5's `--ember-ansi-*` tokens. Black is the text
  colour, white muted, bright black faint; each other bright colour equals
  its normal one (the board has no bright variants). The 256 extended
  colours map to the nearest of these 16, so every colour on the page
  comes from the palette.
- **Figures**: no card, border, background or filter; in dark mode a plot
  stays exactly as R drew it. Real size (inches × 96 px) when it fits the
  column, scaled to the column when wider (piece 3's rule). No size label,
  no buttons.

**Text cells** (Insert5).

- A text cell shows its rendered text in Source Serif 4, 16 px, 1.6 line
  height; `##` headings 22 px weight 600, others in proportion. The code is
  folded.
- Clicking the rendered text opens the source below it: a 1 px line
  outline, `#'` prefixes in the comment colour, headings and `**bold**` in
  the keyword colour, `` `r expr` `` in `--ember-ansi-cyan`. Shift + Enter
  re-renders and closes it; Esc closes it when unchanged. Clicking a link
  follows it; clicking with a text selection, or ending a selection drag,
  doesn't open the editor. Opening is page-only, not saved to the file.
- In any cell, Enter on a line starting `#'` (after optional spaces) starts
  the next line with `#' ` at the same indent.
- An inline value shows on `--ember-accent-bg` (4 px radius, `0 4px`
  padding), background only, so copying gives plain text.
- A failed inline expression: the error box replaces the text and the
  source opens below it.
- A mixed cell: the error box titled "Text and code in one cell", the
  sentence "A cell is either text (only `#'` lines) or code. Nothing in it
  has run.", and piece 2's "Split into 2 cells" button (12.5 px, weight
  500, panel background, line border, 6 px radius, 26 px high).

**Empty notebook** (Insert5, "A new, empty notebook"). One cell with "Type R
code here" in faint mono, the code box outlined with a 1 px line. Under it,
16 px in, three hints in muted 13.5 px with key caps (mono 11.5 px, 1 px
line border, 2 px bottom border, 4 px radius): "[Shift] + [Enter] runs a
cell."; "[Ctrl] + [Enter] runs it and adds a cell below." (⌘ on a Mac);
"Start a line with [#'] to write text instead of code." The hints go once
there is a second cell or the cell has code. Empty4's "+ Code / + Text"
buttons were replaced by these hints in Round 5 and are not built.

**Static exports and isolated cells** (`pluto-editor.disable_ui`): no run
button, menu, "+", hints or "Not run yet" chips. Rails, washes, error boxes
and outputs look as in the live page.

### Shape

**Rules touched.** Error bodies keep `msg`, `stacktrace` and `plain_error`;
table and tree bodies keep `schema`, `rows`, `elements` and the `"more"`
markers. New body fields are prefixed `ember_`; the new tree leaf type is a
new MIME, `application/vnd.ember.vector+object`. No new requests and no new
worker message types: fields are added to the `done` report's `error`, to
console items and to table and tree displays, which the shell passes
through (shell.R:822, 843; step.R:850-856); worker and server still change
in one commit. Kept DOM hooks beyond ui-2's list, because Endeavor reads
them: `pluto-trafficlight` stays the rail element (endeavor
cells.ts:5-34); `jlerror` stays the error element with a `header` holding
the message `<p>` first and the location `<p>` second, and a `section`
holding the traceback (errors.ts:32-43, 282); `pluto-shoulder >
button.foldcode` stays, visually hidden (folded.ts:18, 144); `.errored`,
`.queued`, `.running`, `.code_folded`, `.selected`, `.code_differs`,
`button.add_cell.before/.after` and `pluto-output` keep their meaning.

#### 6.1 Colour variables

Piece 5 defines the rail, error, due, wash, disabled, syntax and ANSI
tokens. This piece adds only the ones its components need and piece 5
doesn't have, light / dark:

```
--ember-warn-text          #7a5a12 / #e6c46f
--ember-chip-stale-bg      #f5ecd6 / #352d1b
--ember-chip-stale-line    #e6d3a3 / #58492a
--ember-chip-stale-text    #6f5210 / #dcb35a
--ember-chip-dis-bg        #e6e9e5 / #262b27
--ember-chip-dis-text      #5c655e / #a0aaa2
```

`--ansi-*` (ansi-colors.css:3-20) move from one `:root` set into both theme
files, set from `--ember-ansi-*`; the background classes keep using them.
The `--ember-*-label-*` variables (light.css:81-89 and their dark copies)
go with the labels.

#### 6.2 Cell structure (Cell.js, CellInput.js, new RunButton.js, new cells.css)

```
pluto-cell#id.{running,queued,errored,code_differs,code_changed,stale,
               not_run_yet,running_disabled,depends_on_disabled_cells,
               text_cell,text_open,show_input,…}[data-rail]
  pluto-trafficlight                    the rail (absolute, full height)
  ember-rail-tip                        new: "Press Shift + Enter…" (amber only)
  button.add_cell.before
  pluto-shoulder[draggable] > button.foldcode     kept; foldcode hidden
  ember-chip                            new: chips (6.3)
  pluto-output                          CellOutput, as today
  pluto-input
    .cm-editor
    button.ember-run                    new: run/stop (RunButton.js)
    button.input_context_menu           ⋯, now "Cell options"
    div.input_context_menu              the menu
    ember-runtime                       new: the run-time chip
  pluto-logs-container                  console (6.6)
  button.add_cell.after
```

- `RunArea.js` is replaced by `components/RunButton.js` (about 70 lines),
  rendered by CellInput inside `pluto-input`, so it is positioned against
  the code box. Props: `running`, `queued`, `runtime`, `on_run`,
  `on_interrupt`; it is not rendered for off cells. It keeps
  `useMillisSinceTruthy` (moved from RunArea.js; ConfirmBeforeLongRuntime.js:
  10 imports it) and formats with `format_runtime(ns)`, exported for the
  e2e test. RunArea's "save" and "jump" actions go, with Cell.js's
  `disabled_jump` prop: the chip's "Go to it" does the jump.
  `pluto-runarea` and its CSS (editor.css:2839-2910) are deleted.
  `prettytime()` moves to `common/prettytime.js`, and StatusTab.js's import
  (StatusTab.js:4, used at :213) is repointed.
- `Cell.js`: drops `ember_label` and `<ember-cell-label>` (Cell.js:69-76,
  284); adds the classes `not_run_yet` and `text_cell`; computes the rail
  once, `rail = running ? "run" : queued || waiting_to_run ? "queued" :
  (class_code_differs || ember?.code_changed) ? "due" : errored ? "err" :
  "idle"`, set as `data-rail` on `pluto-cell` for cells.css (the classes
  stay for Endeavor); passes `running`, `queued`, `runtime`, `on_run`,
  `on_interrupt` to CellInput; renders the chips before `pluto-output`.
- `CellInput.js` InputContextMenu (CellInput.js:810-931) is rebuilt on
  `useMenu`: the button's title and `aria-label` are `t("t_cell_options")`;
  items `hide_code` (Cell.js's `on_code_fold`, Cell.js:215-221),
  piece 1's `disable_cell`, copy output, `move_up` and `move_down`
  (`pluto_actions.move_remote_cells([id], index - 1)` and `index + 2`, as
  `keyMapMoveLine`, CellInput.js:427), a separator, `delete`. Key hints use
  `alt_or_options_name` (common/KeyboardShortcuts.js:6).
- `Notebook.js` passes nothing new; the "+" is CSS only.
- **cells.css** (new, imported from all-styles.css after editor.css) holds
  everything above. These editor.css blocks go in the same commit:
  1752-1815 (dimmed states and labels; piece 1 kept the disabled ones,
  which cells.css now replaces); 1936-2273 (shoulder button, trafficlight
  stripes, runarea buttons, add_cell); 2275-2420 (menu); 2839-2910
  (runarea); the `pluto-logs` rules from 3750 on. Ranges are re-checked
  after pieces 5 and 7a.
- The running pulse is inside `@media (prefers-reduced-motion:
  no-preference)`, so the rail is solid blue under reduced motion.
- `.ember-run`, ⋯ and `ember-runtime` show for `pluto-cell:is(:hover,
  :focus-within)` under `@media (hover: hover)`, and for
  `pluto-cell:focus-within` under `(hover: none)`.
- The rail is `pointer-events: none`, except under `[data-rail=due]`,
  where a transparent 12 px `::before` is the hover target for
  `ember-rail-tip`.
- `button.add_cell` becomes a 0-height absolute strip over the 26 px gap,
  holding the line (`::before`) and the circle (`span`), shown on
  `:hover` and `:focus-visible` of the strip itself, so a pointer passing
  through shows it and nothing shifts.
- In DOM order, `button.ember-run`, `button.input_context_menu` and
  `button.add_cell.after` come after the code editor, for piece 7's Tab
  order.

#### 6.3 Chips and stale names (Cell.js, new common/stale_names.js)

- "Not run yet": `no_output_yet && !running && !queued && code.trim() !==
  "" && !process_waiting_for_permission && kind !== "markdown" &&
  !running_disabled && !depends_on_disabled_cells` (Cell.js's props;
  `no_output_yet` is Cell.js:162).
- "Stale": `ember.stale` (pluto-state.R:213). The names come from a pure
  page function:

  ```js
  /**
   * Names this cell reads whose defining cell ran after this cell's last
   * run, or is itself stale: what "Stale · x changed" lists. Sorted; [] when
   * none is known (a sourced file changed), and the chip then says "Stale".
   */
  export const stale_names = (notebook, cell_id) => string[]
  ```

  It reads `cell_dependencies[id].upstream_cells_map` and, per defining
  cell, `cell_results[d].output.last_run_timestamp` and
  `cell_results[d].ember.stale`. At most three names, then "and N more".
- The stale wash is drawn behind `pluto-output` and the chip with a CSS
  grid area, not a wrapper, so `pluto-output` stays a direct child of
  `pluto-cell` for Endeavor's `:scope >` selectors (test 152).
- "Disabled" from `metadata.disabled`; "Depends on a disabled cell. Go to
  it" from `depends_on_disabled_cells` and `ember.disabled_by` (checked in
  that order, since `depends_on_disabled_cells` is also true on the
  disabled cell itself, as in Pluto). "Go to it" dispatches `cell_focus`
  to `ember.disabled_by`. Off cells arrive with their last output and
  `ember.stale = FALSE` (piece 1).
- Each chip is a `<span role="status">` with its text; the icon is
  `aria-hidden`.

#### 6.4 Error data (worker, engine, projection)

Worker, error handler (worker.R:338-374):

```r
#' Added to the error report, beside message/call/traceback (kept):
#'   call   chr(1) | NULL   deparse of conditionCall(e), one line; NULL when
#'                          R gives none or it is the worker's own
#'                          `eval(e, globalenv())` (a top-level stop()).
#'   line   int(1) | NULL   the cell line where the failing top-level
#'                          expression starts: attr(exprs, "srcref")[[k]][1]
#'                          for the k the eval loop was on.
#'   deep   lgl(1)          TRUE when `call` is not the top-level expression
#'                          itself ("called from line n").
#'   frames list, outermost first, one per kept traceback call:
#'          list(call = chr, package = chr | NULL, cell = chr | NULL)
#'          package: environmentName(topenv(environment(sys.function(i)))),
#'          NULL for R_GlobalEnv. cell: the id of the cell that defined the
#'          function, from its srcref's file name; the first frame is the
#'          running cell.
```

- `parse(text = msg$code, keep.source = TRUE)` (worker.R:322) gets
  `srcfile = srcfilecopy(msg$cell, msg$code)`, so a function defined in a
  cell carries the cell's id as its source file name. R prints it only with
  `options(show.error.locations = TRUE)`.
- The eval loop (worker.R:330-335) keeps its index `k` where the handler
  can read it. `frames` uses the same `calls[!is_original]` selection as
  `traceback`, through a new `clean_frames(calls, fns)` applying
  `clean_calls()`'s start and end rules (worker.R:1468-1480), so the two
  always have the same length.
- Console warning (worker.R:1012): `add_item("warning", conditionMessage(w),
  call = <deparse(conditionCall(w)), one line, or NULL>)`; `add_item()`
  gains `call = NULL` and stores it only when set.

Engine: piece 1 gave `new_run_error()` `cells`, piece 2 `call` and `line`
(filled for text cells from the inline span). This piece adds `deep =
FALSE, frames = list()`, and step.R:992 passes the worker's `err$call`,
`err$line`, `err$deep` and `err$frames` for code cells. Graph errors and
other kinds keep the defaults.

Projection (pluto-state.R): `project_error()` (424-436) adds `ember_call`,
`ember_line` and `ember_deep`; its frames (still innermost first, as Pluto's
`stacktrace` is) set `source_package` from `frames[[k]]$package` and add
`ember_cell`; `call`, `file = ""` and the other Pluto fields stay, so
Endeavor's reader and `plain_error` are unchanged. `project_logs()`
(468-477) adds `ember = list(call = item$call)` to an entry with a call.
`notebook_snapshot()` (api.R:299-310) passes the new error and console
fields through.

Page, `ErrorMessage` (ErrorMessage.js:356-622): the rewriter table stays
(piece 7 trims the Julia-only rewriters; piece 1's upstream rewriter is
kept). The markup becomes:

```
jlerror.ember
  header
    p.ember-error-msg       matched_rewriter.display(msg)
    p.ember-error-where     "Error in <code>call</code> · line n" (t_error_where_*)
  section                   only when the rewriter allows a traceback and frames exist
    button.ember-tb-toggle  "Show traceback (n calls)" / "Hide traceback"
    ol.ember-tb             when open: li.{mine} > span.n, code, span.from
```

`mine` is `ember_cell != null`; `from` is "this cell, line n" for the first
frame, "notebook" for another cell, else the package. Not rendered any
more: Pluto's `Motivation` stickers (piece 7 deletes the setting),
`DocLink`, `LinePreview`, the `limited` "show more", and
`stacktrace_waiting_to_view`. `ParseError` (ErrorMessage.js:249) renders
the same `jlerror.ember` with the message and "line n", without a section.

#### 6.5 Tables and trees (worker, projection, TreeView.js)

- Worker `build_table()` (worker.R:1154-1193) adds `na`: per shown row, the
  1-based shown-column positions where `is.na(value[[j]][i])` is a single
  TRUE, for atomic columns only, in the same per-column `tryCatch`.
- Worker `display_tree_node()` (worker.R:1233-1253): an atomic vector with
  no class attribute and length above 1 becomes `list(type = "vector",
  values = <format() of the first 10>, type_sum = <column_type(x) without
  brackets>, length = n)`; every other leaf stays `type = "text"`.
- `project_table()` (pluto-state.R:355-370) replaces `ember_dims` with
  `ember_size = list(nrow, ncol, more_rows, more_cols)` and adds
  `ember_na = arr(arr(<0-based col>...), ...)`, one per row; the page
  formats the words with `t("t_table_size", {rows, cols})` and plurals.
- `project_tree()` (379-391) adds `ember_length`; a `"vector"` leaf becomes
  `arr(list(values, type_sum, length), "application/vnd.ember.vector+object")`.
- TreeView.js `TableView` (212-260): the size cell reads `ember_size`,
  falling back to `ember_dims` for older statefiles in exports; types
  without `<>`; `td.na` from `ember_na`; the two "Show N more…" buttons
  under the table call `actions_show_more` with dim 1 or 2; no in-table
  "more" cells. `case "r_list"` (179-187): prefix "list of N"
  (`t_list_of`), rows with disclosure, key and value, the root open, nested
  trees collapsed, "Show N more" from `ember_length`.
  `SimpleOutputBody`/`OutputBody` render the vector MIME as the values
  joined by spaces, then "… <type>, N values" in `span.ember-vector-count`.

#### 6.6 Printed text, console and ANSI (CellOutput.js, Logs.js, imports/AnsiUp.js)

- `ANSITextOutput` (CellOutput.js:785-793) keeps its markup; cells.css gives
  `pluto-output[mime="text/plain"] pre` no background, border or padding.
- `Logs.js`: each entry is one line in `pluto-logs > ember-log.{stdout,
  message, warning}`; a warning renders `<b>Warning</b> in
  <code>call</code>: text` when `log.ember?.call` is set; stdout keeps
  `LogViewAnsiUp`. `Dot`, `MoreInfo` and its popup, the
  `set_cm_highlighted_line` hover (console items have `line = -1`) and the
  progress-log branch (`LogLevel(-1)` is never sent, pluto-state.R:470)
  go. The `Logs` props stay, so `IsolatedCell` (Cell.js:384) is unchanged.
  `t_logs_truncated` becomes "{{count}} lines not shown".
- `imports/AnsiUp.js`:

  ```js
  /**
   * ansi_up with every 256-colour index from 16 to 255 mapped to the
   * nearest of the 16 base colours (by RGB distance; the greys 232-255 to
   * black, bright black, white or bright white by lightness), so that
   * `use_classes` gives a theme class for every colour and no inline rgb()
   * reaches the page. Truecolor (38;2;r;g;b) is left as ansi_up renders it.
   */
  export const ansi_to_html = (ansi, { use_classes = true } = {}) => string
  ```

  It rewrites `palette_256[n]` for n in 16..255 on the instance (a plain
  array property in ansi_up 6.0.6, which the vendor build pins), from one
  module-level table built once.

#### 6.7 Figures

cells.css: `pluto-output img` has no background, border, radius or
`filter` (the editor.css:216 block is reviewed), `max-width: 100%; height:
auto`. Piece 3's `EmberPlot` already sets `width: <inches * 96>px` and
redraws only for density; this piece keeps that rule.

#### 6.8 Text cells (Cell.js, new CellInput/text_cell.js)

- Cell.js: `text_open` is local state (`useState(false)`), not the fold
  flag, so reading a cell's source doesn't rewrite the file. `show_input`
  (Cell.js:172-173) adds `|| (kind === "markdown" && text_open)`. A click
  on a text cell's `pluto-output` sets it when
  `!e.target.closest("a, button")` and `getSelection().isCollapsed`;
  Shift + Enter (`on_submit`) and Esc with unchanged code clear it; an
  errored text cell forces it on.
- `components/CellInput/text_cell.js` (new, about 110 lines), in every
  cell's extensions (CellInput.js:640 area): `hash_quote_continue`, an
  Enter keymap entry at `Prec.high` that, when the line matches
  `/^(\s*)#'/` and the selection is empty, inserts `"\n" + indent + "#' "`
  (after the autocomplete keymap, so Enter still accepts a completion);
  `hash_quote_highlight`, a ViewPlugin marking visible `#'` lines: prefix
  `cm-ember-hq`, heading lines `cm-ember-md-h`, `**…**`/`__…__`
  `cm-ember-md-b`, `` `r …` `` `cm-ember-r`, by regex on line text only.
- Rendered text is styled under `pluto-cell.text_cell > pluto-output`;
  `.ember-inline` gets a background only (no `::before`/`::after`
  content).
- `button.ember-split` (piece 2) is styled here.

#### 6.9 Empty notebook (new components/EmptyNotebookHints.js)

```js
/** The three hints under the only cell of an empty notebook. */
export const EmptyNotebookHints = () => html`<ember-empty-hints>…</ember-empty-hints>`
```

Notebook.js renders it after the cells when `cell_order.length === 1`,
that cell's local and remote code are `""`, and it has no output; not under
`disable_ui`. Keys from `ctrl_or_cmd_name` (KeyboardShortcuts.js:5).
`t_cell_input_placeholder` becomes "Type R code here". The only cell's code
box gets `box-shadow: 0 0 0 1px var(--ember-line)` through
`pluto-notebook:has(> pluto-cell:only-of-type)`.

#### 6.10 Disable cell (page side)

Piece 1 built the engine, the patch, `ember.can_disable`,
`ember.disabled_by` and a minimal menu item. This piece gives it the
design: the menu item in the new menu (6.2), the two chips and the dimmed
code (6.3), no run button on off cells (6.2), and the idle rail. Pluto's
`t_jump_cell` and `t_cell_is_disabled` lose their last users with RunArea
and are deleted.

#### 6.11 Strings

New keys: `t_cell_options`, `t_hide_code`, `t_show_code`, `t_move_up`,
`t_move_down`, `t_add_cell_here`, `t_stop_cell`; `t_rail_due_hint`;
`t_chip_not_run`, `t_chip_stale`, `t_chip_stale_names`, `t_chip_disabled`,
`t_chip_depends_on_disabled`, `t_go_to_it`; `t_error_where_line`,
`t_error_where_called_from`, `t_error_where_no_call`; `t_show_traceback`,
`t_hide_traceback`, `t_tb_this_cell`, `t_tb_notebook`; `t_table_size`
(plurals), `t_show_more_rows`, `t_show_more_cols`, `t_list_of`,
`t_vector_values`, `t_show_more_items`; `t_warning_in`, `t_warning`;
`t_hint_run`, `t_hint_run_add`, `t_hint_text`. Reused: piece 1's
`t_disable_cell`/`t_enable_cell`, piece 2's `t_ember_split`, 7a's
`t_copy_output_failed`. Existing keys re-worded from Words6:
`t_cell_input_placeholder` "Type R code here", `t_add_cell` "Add a cell
here", `t_interrupt_cell` "Stop (Ctrl + Q)". Deleted: `t_show_hide_code`,
`t_show_stack_trace`, `t_ember_label_*`, `t_jump_cell`,
`t_cell_is_disabled`.

### Tests

127-152: unit 127-138, request 139, end to end 140-152; plus the changes
to existing tests listed under Piece 6 in the tests file.

### Risks

- **Endeavor's CSS** targets old shapes: striped `pluto-trafficlight
  ::after`, `jlerror > .error-header`, `section.stacktrace-waiting-to-view`
  (endeavor cells.ts:24-34, errors.ts:32-43). The elements stay, so nothing
  breaks, but some rules stop matching and its stripes may fight the new
  rail. That is Endeavor's change (#62).
- **ansi_up internals.** `palette_256` is not documented API; ansi_up is
  pinned, and test 147 fails if a version drops the property rather than
  the page silently showing inline colours.
- **srcfile name.** Naming a cell's srcfile by its id changes what
  `getSrcFilename()` and `utils::getParseData()` report inside the
  notebook; a function that inspects its own srcfile sees the cell id
  instead of `"<text>"`. `print(f)` is unchanged.
- **Frame packages.** `topenv()` of a closure from a package's function
  factory is that package, which is right; an S4 or R6 method may report
  the generic's package. The label is a hint only.
- **Overlay "+" and drag.** The "+" strip and `pluto-shoulder`'s drag
  target must not cover the run button's corner; tests 141 and 143 cover
  both.
- **Text-cell click.** The `isCollapsed` check covers mouse selection; a
  screen-reader user opens a text cell with the menu's Show code.
- **Stale names are a guess** from timestamps; when it finds nothing the
  chip says "Stale".
- **Size.** The 6a/6b split keeps each review under about 1,000 lines.

### Order within the piece

**6a**

1. Colour variables (6.1) and the contrast test 137.
2. Rail, run/stop button, run-time chip and cell menu (6.2); delete RunArea
   and the label CSS: tests 138, 140-142, 152.
3. "+" overlay and empty-notebook hints (6.2, 6.9): tests 143, 151.
4. Chips, stale names and the disabled states (6.3, 6.10): tests 144, 149.
5. Argument tooltips close when the cursor leaves their cell or the cell
   loses focus (the old gap list, "Argument tooltips stay on screen"); an e2e
   check alongside test 152.

**6b**

6. Error data: worker, engine and projection in one commit (6.4), then the
   ErrorMessage render: tests 127-129, 133, 139, 145.
7. Tables and trees: worker and projection, then TreeView (6.5): tests 131,
   132, 134, 135, 146.
8. Console and ANSI: the warning call, Logs.js, AnsiUp.js (6.6): tests 130,
   136, 147.
9. Figures CSS (6.7): test 148.
10. Text cells (6.8): test 150.

---
## 7. Menus, settings, shortcuts, accessibility, wording

The rest of piece 7 (its first part, 7a, is an earlier branch, above). All
frontend plus three server strings, on top of 7a's dialogs and menus:
the Export menu, the Settings dialog with live settings, the shortcuts
sheet, F1 as R help, the keyboard path, cell names and one announcement per
run, reduced motion, then a wording sweep and dead-code deletion that
file-scanning tests keep honest. No new requests, worker messages or
projection changes. About 1,100 lines added and 2,000 deleted (half CSS and
translation strings), in about 25 files.

### Problem

- **Export** is Pluto's banner dialog (ExportBanner.js:121-193): cards with
  coloured shapes, a June "pride" card (116-117, 161-165), "Edit
  frontmatter" (168-177, an event nothing listens for), "Start
  presentation" (178-188, calling `window.present`, which no longer
  exists), and a `confirm()` in safe preview (119). "Notebook file" opens
  the source in a tab instead of downloading it (125-129). The print title
  strips `.jl`, not `.R` (75).
- **Settings** (Settings.js) asks to reload after every change (32-45),
  offers motivational stickers (77-79) and a free-text code font (121-124),
  has a Dark mode row with no control (100-106), and no theme choice.
  Indentation defaults to Tab (200) and offers 4 spaces or Tab (114-117).
  Several settings are read once, when an editor is created or a module
  loads (CellInput.js:207, 460, 638; pluto_autocomplete.js:53, 328;
  tab_help_plugin.js:36).
- **Shortcuts** are an `alert()` on Ctrl + ? or F1 (Editor.js:1370-1405),
  advertising Ctrl + M "toggle markdown", which nothing binds, and reusing
  that text for the two fold keys (1393-1395).
- **Keyboard path.** Esc in a cell does nothing useful; the global Esc
  handler clears the selection (Editor.js:1406-1410). Run and the cell menu
  need a mouse; add-cell buttons have `tabindex="-1"` except on the first
  cell (Cell.js:292); there is no skip link; the Help search box removes
  its focus outline (editor.css:3138-3139).
- **Announcements.** Every output becomes an `aria-live="polite"` region
  after it changes once (CellOutput.js:101), so a screen reader reads every
  output during a run. Cells have no name.
- **Long runs.** The "Confirm?" dialog clicks Yes by itself after 20 s
  unless focus moves (ConfirmBeforeLongRuntime.js:14, 113-118).
- **Wording.** Pluto and Julia strings remain ("begin ... end" advice,
  "Oopsie!!", "UNDO", jokes under errors, Pkg step names), some
  hard-coded (`title="Actions"`, CellInput.js:886). 122 of the 331 keys in
  lang/english.json are never used (a scan of `t_…` literals; 11 more are
  read through computed keys).
- **Dead code**: the Julia-only error rewriters (ErrorMessage.js:365-414,
  467-470, 516-538) and `wrap_remote_cell` (Editor.js:515-529), which only
  the begin/end rewriter calls; binder support (`common/Binder.js`,
  `launch_params.binder_url`, the binder spinners, `wiggle_binder`: about
  83 lines across Editor.js, StatusTab.js, ProgressBar.js and
  BottomRightPanel.js today, fewer after piece 5's rewrites); Ember never
  sets `binder_url` or `pluto_server_url`, so `backend_launch_phase` is
  always null (Editor.js:379-382). Also the motivational stickers
  (ErrorMessage.js:617, 633-642), the AI CSS (editor.css:2449-2533) and the
  presentation, pride and frontmatter CSS (editor.css:575-600, 685-704,
  1195-1202, 4018-4062).

### What the user sees

- **Export**: the header's download icon opens a menu: "Download .R file"
  ("The notebook itself. Runs with Rscript."), "Download HTML" ("One file
  with every output. Opens offline."), "Print or save as PDF" ("Opens the
  browser's print dialog."). In safe preview an amber note says "This
  notebook hasn't run, so HTML and PDF have code but no outputs." and the
  last two items say "Code only, for now." Nothing pops up after a click.
- **Settings** (Menus6): Appearance: Theme (Match system / Light / Dark).
  Editing: Indent with (2 spaces, the default / 4 spaces / Tab); Suggest
  completions as I type; Check spelling in text cells; Tab key in code
  (Indents / Moves focus). Running: Ask before long runs (seconds field and
  toggle); Notify me when a long run finishes. Reset to defaults, Done.
  Every change applies at once.
- **Keyboard shortcuts**: an in-page sheet from ⋯ with four groups
  (Running, Cells, Editing code, Moving around), one key column for the
  computer in use (⌘ and ⌥ on a Mac). Esc closes it. Ctrl + ? no longer
  opens anything.
- **F1** in a cell opens the Help tab on the name at the cursor; outside a
  cell it opens the Help tab.
- **Keyboard path**: the first Tab shows "Skip to the notebook". Esc in a
  cell selects it (ringed); ↑/↓ move between cells, Enter goes back into
  the code, Tab reaches the run button, ⋯ and the "+" below. Esc in the
  side panel closes it and returns focus to its icon.
- **One focus ring**: 2 px accent outline, 2 px offset, keyboard focus
  only.
- **Screen readers**: cells are named ("Cell defining fit, error"); one
  polite message when a run you started ends ("Finished: 3 cells", "fit:
  error"); outputs are not announced one by one.
- **Reduced motion**: nothing pulses or slides.
- **Long runs**: "This reruns 4 cells that took about 3 min last time."
  Cancel / Run. It waits for an answer.
- **Wording**: the Words6 strings this piece owns (below). Server error
  pages say "This notebook isn't open in Ember." and similar.

### Shape

**Rules touched.** Nothing in the projection changes; no `ember` fields,
requests or worker messages. Kept: `header`, `pluto-cell[id]`,
`button.add_cell`, `pluto-output`, `main pluto-notebook`, `.selected` and
`selected_cells`, `/notebookfile` and `/notebookexport` (the Export links
are the same URLs). No CSS variable name in either list is removed;
`--custom-code-font-stack` is in neither.

#### 7b. Export menu

`components/ExportMenu.js` (about 110 lines, on 7a's `useMenu` and menu
CSS) replaces `components/ExportBanner.js` (195 lines, deleted with its
`alert`/`confirm`, ExportBanner.js:40, 119). The Editor.js import (18) and
render (1656-1667) change; `export_menu_open` and `header.show_export` go.

- Rendered at piece 5's Export button, which keeps the class
  `toggle_export` (e2e selectors and editor.css:706) and has `title` and
  `aria-label` "Export".
- Items are `<a role="menuitem">`: Download .R file
  (`href=${export_url("notebookfile")}`, `download=${basename(notebook.path)}`;
  the server already sends `Content-Disposition: inline; filename=…`,
  server.R:1137, and the `download` attribute makes it a download);
  Download HTML (`export_url("notebookexport", { offline_bundle: "true" })`,
  `download=""`, as today, 130-134); Print or save as PDF (`href="#"`,
  closes the menu and calls `window.print()`).
- In safe preview (`status.process_waiting_for_permission`) the note comes
  first and two descriptions change; nothing asks.
- The `beforeprint`/`afterprint` title handling (68-87) moves over,
  stripping `\.R$`.
- Not ported: the desktop-app branch, the pride card, the shapes, Edit
  frontmatter, Start presentation, the close button,
  `WarnForVisisblePasswords` (it checks password inputs inside bonds;
  Ember has no bonds yet, see #36). Old CSS (editor.css:549-704,
  1171-1202, 2178-2193) goes.

piece 5's ⋯ menu changes one item: "Keyboard shortcuts" opens 7d's sheet.

#### 7c. Settings

`components/Settings.js` is rewritten (about 230 lines):

```js
export const DEFAULT_SETTINGS = {
    THEME: "system",                    // piece 5
    CM_INDENT_UNIT: "2",                // "2" | "4" | "tab"; default was "tab"
    CM_AUTOCOMPLETE_ON_TYPE: true,
    CM_SPELLCHECK: false,               // text cells only
    CM_TAB_KEY_FOR_INDENT: true,        // Indents (true) / Moves focus (false)
    CONFIRM_LONG_RUNTIMES: true,        // new toggle beside the seconds field
    CONFIRM_LONG_RUNTIMES_SECONDS: 120,
    ALWAYS_NOTIFY_LONG_BUSY: false,     // "Notify me when a long run finishes"
}
// removed: MOTIVATIONAL_STICKERS, CUSTOM_CODE_FONT_STACK
```

- Storage keys stay `pluto_setting_<KEY>` (Settings.js:212, 230), so
  existing choices survive; removed keys are ignored. The reload prompt
  (Settings.js:32-45, its `confirm()` at :39) goes.
- `set_setting()` writes, then dispatches window `"ember settings
  changed"` with `{ key, value }`. Each user reads `get_settings()` when it
  acts (ConfirmBeforeLongRuntime, notifications, `detect_indent_unit`
  fallbacks) or listens and reconfigures:
  - **Theme**: the row calls piece 5's `apply_theme()`.
  - **CellInput** gets one `settings_compartment` holding the indent-unit
    fallback (`indentUnitField`, CellInput.js:205-208), the Tab keymap
    entry (460), the autocomplete extension with `activateOnTyping` and its
    Tab binding (pluto_autocomplete.js:53, 328), and the `spellcheck`
    attribute (CellInput.js:638), which is `CM_SPELLCHECK && kind ===
    "markdown"`. `tab_help_plugin` (tab_help_plugin.js:36) is always
    installed and reads the setting on keydown.
  - `detect_indent_unit` (CellInput/detect_indent_unit.js) learns 2
    spaces: the smallest common indent of indented lines, `"\t"` for tabs,
    else the fallback; its type becomes `"\t" | "  " | "    "`.
  - `--custom-code-font-stack` goes from editor.css:34 and 102 and
    Notebook.js:200-204; `--code-font-stack` becomes
    `var(--ember-code-font)`.
- Ask before long runs: `maybe_abort_long_runtime`
  (ConfirmBeforeLongRuntime.js:30-58) also checks `CONFIRM_LONG_RUNTIMES`.
  The dialog keeps its `<dialog>` and logic, worded "This reruns
  {{count}} cells that took about {{time}} last time." with Cancel / Run
  (count = roots + dependents). The 20-second auto-accept
  (ConfirmBeforeLongRuntime.js:14, 113-118), the random tip
  (`t_confirm_run_many_cells_bonus_a`, 123-131) and the debug
  `console.log` (40) go.
- Notify: turning it on calls `Notification.requestPermission()` from the
  toggle's click; if refused, the toggle turns off and a note says "Your
  browser blocks notifications from this page." The notification itself
  is 7f's.
- Layout from Menus6: 560 px wide, 10 px radius, section headings 12 px
  uppercase muted, rows with 1 px separators, segmented controls
  (`role="radiogroup"`, options `role="radio"`, ←/→ move), switches
  (`<button role="switch" aria-checked>`), seconds field 44 px Plex Mono;
  "Reset to defaults" (applies at once, stays open) and "Done". The class
  `psettings` stays (offline.test.mjs:79 waits for
  `dialog.psettings[open]`); its old CSS (editor.css:856-925, 3682-3700)
  is replaced.

#### 7d. Shortcuts sheet and F1

`components/ShortcutsSheet.js` (about 120 lines), a 7a `Dialog` with one
key column chosen by `is_mac_keyboard` (KeyboardShortcuts.js:2). Rows come
from a data table, so the sheet and its test read the same list:

```js
// [{ group: "t_shortcuts_running", rows: [{ label: "t_shortcut_run", keys: ["Shift", "Enter"], mac: ["Shift", "Enter"] }, ...] }, ...]
```

The rows are Keys6's four groups; keys are `<kbd>` in Plex Mono with a
2 px bottom border. It opens only from ⋯ → Keyboard shortcuts. The alert
and its Ctrl + ? / F1 handler (Editor.js:1370-1405) go, with `t_key_*`,
`t_key_ctrl_m`, the "fold" lines, `t_key_selection_description` and
`t_key_autosave_description`.

**F1** = R help at the cursor:

- CellInput keymap (beside `plutoKeyMaps`, CellInput.js:455-470):
  `{ key: "F1", run: (view) => { const q = get_selected_doc_from_state(view.state); if (q != null) on_update_doc_query(q); open_panel("docs"); return true } }`,
  using `get_selected_doc_from_state` (LiveDocsFromCursor.js:25) and
  `on_update_doc_query` (Cell.js:79).
- Outside an editor, the global keydown (Editor.js:1339) handles `F1` by
  opening the Help tab and calling `preventDefault()`.
- `open_panel(tab)` dispatches `open_bottom_right_panel` with `"docs"`.

Inside Endeavor, F1 doesn't reach Ember: Endeavor's page script takes F1
and Ctrl/⌘ + ? on `window` in the capture phase for its own sheet
(endeavor/frontend/src/actions.ts:161-172). That is an Endeavor change,
tracked in #62.

#### 7e. Keyboard path and focus

- **Focus ring** (editor.css, about 20 lines):
  `:focus-visible { outline: 2px solid var(--ember-accent); outline-offset: 2px }`.
  editor.css:3138-3139 (Help search) goes. editor.css:1675-1676
  (`pluto-output:focus`) stays, since outputs are focused by script; code
  editors show focus with piece 6's code-box border, so
  `.cm-editor.cm-focused` keeps `outline: none`.
- **Skip link**: the first child of `pluto-editor`, `<a class="skip-link"
  href="#">Skip to the notebook</a>`, visually hidden until focused; Enter
  focuses the first cell's `.cm-content`.
- **Cell selection**: `pluto-cell` gets `tabindex="-1"`, `role="group"` and
  `aria-label` (7f). A CellInput keymap entry at `Prec.low` (completion,
  signature hint and search get Esc first): `{ key: "Escape", run: () => {
  pluto_actions.select_cell(cell_id); return true } }`. New action
  `select_cell(id)` in Editor.js: `setState({ selected_cells: [id] })`, then
  focus the cell; `.selected` and `selected_cells` are what Endeavor reads
  (annotate.ts:269, runguard.ts:89). The global Escape branch
  (Editor.js:1406-1410) returns early if `e.defaultPrevented`. Cell.js's
  `onKeyDown` on `pluto-cell`, acting only when `e.target ===
  e.currentTarget`: ↑/↓ select the neighbour, Enter focuses the editor
  (Shift + Enter, Backspace and Alt + ↑/↓ already act on `selected_cells`,
  Editor.js:1358-1369). `delete_selected` (Editor.js:1278-1283) also
  requires `!in_textarea_or_input()`. `pluto-cell.selected:focus-visible`
  rings the whole cell (A11y6).
- **Tab order** comes from piece 6's DOM order: outputs' controls, the
  code, then the run button, ⋯ and the "+" below. This piece removes
  `tabindex=-1` from the add-cell button (Cell.js:292). With "Tab key:
  Moves focus", Tab leaves the code for the run button; with "Indents",
  Esc then Tab.
- **Side panel**: it follows `Main` in the DOM (Editor.js:1808). Esc inside
  it closes it and focuses the header icon that opened it: a keydown on the
  panel root, and the opener saved by the `open_bottom_right_panel`
  handler.

#### 7f. Names, announcements, notifications, motion

- **Icon buttons**: every icon-only button has `aria-label` equal to its
  `title`, both translated: the header and panel tabs (piece 5), run/stop,
  ⋯ and "+" (piece 6), and dialogs' close buttons.
- **Cell name**: `aria-label` on `pluto-cell` from `variables` (Cell.js:82,
  the cell's definitions) and the state: `t("t_cell_name", { defines })`
  + `", "` + one of error, running, queued, edited not run, stale,
  disabled (for a disabled cell or one depending on it), not run yet, or
  nothing when up to date. "Cell" when it defines nothing; "Text cell" for
  a text cell. Examples: "Cell defining fit, error", "Cell defining x and
  y, edited not run".
- **Run announcer**: new `components/RunTracker.js` (about 120 lines)
  replaces NotifyWhenDone.js (110 lines, deleted, with StatusTab.js's
  `is_finished` and `total_done` and the `status_tree` plumbing piece 5
  kept for it). A visually hidden `<div role="status" aria-live="polite">`.
  A run starts when this page sends one (`set_and_run_multiple`,
  `add_remote_cell_at`, `set_and_run_all_changed_remote_cells`); each
  update adds every `running || queued` cell to `seen`; the run ends at the
  first update with nothing running or queued. Then one message: "Finished:
  {{count}} cells" (plurals), or "{{name}}: error" (the first errored
  cell's first definition, else "A cell") plus " and {{more}} more errors".
  Runs started elsewhere and reactive reruns aren't announced.
  **Notification**: with `ALWAYS_NOTIFY_LONG_BUSY` on, a run of 60 s or
  more, and the page hidden: `new Notification("{{file}} finished", {
  body: "{{count}} cells ran in {{time}}", icon: url_logo_small })`;
  clicking it focuses the window (today's notified even when visible,
  NotifyWhenDone.js:31-52).
- **Outputs**: `aria-live`, `aria-atomic` and `aria-relevant` leave
  `pluto-output` (CellOutput.js:101-103); the labels (104-106) stay.
- **Reduced motion**: `@media (prefers-reduced-motion: reduce) { *,
  ::before, ::after { animation: none !important; transition: none
  !important; scroll-behavior: auto !important } }`. The older rules
  (editor.css:1140, 1438, 3170, 3972) go; ConfirmBeforeLongRuntime.js:83
  keeps its own check.
- **200% zoom** is piece 5's narrow layout (test 114).

#### 7g. Wording and deletions

A string on a surface another piece rebuilds is changed by that piece; this
piece changes the rest, and test 155 checks every "Today" string from
Words6.

| Words6 row (today → new) | owner |
|---|---|
| Enter cell code... → Type R code here | 6 |
| Interrupt (Ctrl + Q) → Stop (Ctrl + Q) | 6 |
| Add cell (Ctrl + Enter) → Add a cell here | 6 |
| Show/hide code → Hide code / Show code | 6 |
| Actions → Cell options (CellInput.js:886) | 6 |
| "This cell is disabled…" → Disabled | 6 |
| This cell depends on a disabled cell → Depends on a disabled cell. Go to it | 6 |
| Show stack trace... → Show traceback (n calls); Stack trace → Traceback; Error message from {package} → Error from {package} | 6 |
| This table has no rows → 0 rows × 3 columns | 6 |
| Blocked by an error upstream → Another cell defining x contains errors. | 1 |
| Run all bar, Running cells, R · MB, Restart notebook, Process exited…, Process status, status and Pkg step names; Search docs...; Welcome to Help…; Versions as of; Safe preview banner | 5 |
| start page; Are you sure? Will move…; Failed to move file; Forget; Save notebook... · Choose · Move | 4 |
| Oopsie!! … (twice) → Something went wrong in this page. Reload it; your notebook is saved.; Error copying cell output → Couldn't copy the output.; This browser window is too small… → removed; Delete 3 cells? | 7a |
| Cell deleted · UNDO → Cell deleted · Undo (`t_undo_delete_link`) | **7** |
| x has been disabled because it also defined y (`t_auto_disabled`, UndoDelete.js:55-66) → deleted: Ember never disables a cell itself | **7** |
| Multiple definitions for x… begin ... end → x is defined in more than one cell. Keep one, or put them in one cell. (`t_multiple_definitions_for`, plurals) | **7** |
| Cyclic references among x, y. → x and y depend on each other, so neither can run. (`t_cyclic_references_among`; "none of them" for 3 or more) | **7** |
| stickers → nothing | **7** |
| Pkg is currently busy…; Did you make a typo? → keys deleted (`t_pkg_currently_busy`, `t_pkg_not_found`) | **7** |
| Loading binder... → removed | **7** |
| long-run confirm → This reruns 4 cells that took about 3 min last time. Cancel / Run | **7** |
| Tip: You can edit multiple cells… → removed | **7** |
| Ember: notebook ready · ✓ All 5 steps completed → analysis.R finished · 5 cells ran in 3 min | **7** |
| File change detected, notebook updated → The file changed on disk; the notebook now shows it. (`t_file_change_detected`, Preamble.js) | **7** |
| no such notebook · could not open: … · forbidden → This notebook isn't open in Ember. · Couldn't open {path}: {reason}. · Ember didn't accept this request; open the link Ember printed when it started. | **7** (R/server.R:584, 1082, 1112, 1133, 1144, 1171, 1174) |
| Export... · Notebook file · Static HTML · PDF → the Export menu | **7** |

Also in this step:

- **Unused keys**: the 111 keys no code reads (122 found minus the 11 read
  through computed keys): welcome page, binder, frontmatter, pluto.land,
  Project.toml editor, AI, language picker, Pkg bubbles, feedback. And the
  keys of code deleted here: `t_key_*`, `t_settings_motivational_*`,
  `t_settings_code_typeface_*`, `t_settings_dark_mode_*`,
  `t_settings_reload_to_apply_changes_confirm`, `t_motivational_words_…`,
  `t_export_card_*`, `t_edit_frontmatter`, `t_start_presentation`,
  `t_wrap_all_code_in_a_begin_end_block`, `t_split_this_cell_into_cells`,
  `t_package_could_not_load*`, `t_might_find_info_in_pkg_log`,
  `t_package_not_found_manual_pkg_activate_hint`,
  `t_process_status_loading_binder`, `t_oopsie_pls_refresh`,
  `t_export_safe_preview_warning`, `t_safe_preview_julia_version_change_*`,
  `t_safe_preview_confirm_*`, `t_auto_disabled`, `t_auto_disabled_link`.
- **New keys**: menus, settings, sheet rows, cell names, announcements;
  about 60, sentence case.
- **Julia-only rewriters** deleted from ErrorMessage.js: "extra token after
  end of expression" (365-399), with `wrap_remote_cell` (Editor.js:515-529)
  and `split_remote_cell` (Editor.js:530-), whose only caller it is
  (ErrorMessage.js:382; piece 2's split uses its own `ember_split_cell`);
  "LoadError: cannot assign" (401-409); "MethodError … Closest candidates"
  (411-413); `^syntax:` (467-470); "ArgumentError: Package … not found"
  (516-538). Kept: cyclic (415-436) and multiple definitions (438-465),
  which match the engine's text (pluto-state.R:426-427), the empty message
  (472-474), and piece 1's upstream rewriter, which replaced the
  `UndefVarError` one and is not this piece's to change.
- **Stickers**: `Motivation` and `motivational_*` (ErrorMessage.js:617,
  633-642), the `.dont-panic` CSS (treeview.css:446-466, hide-ui.css:19,
  41).
- **Binder**: `common/Binder.js` deleted; `BackendLaunchPhase` and every
  `backend_launch_phase`/`backend_launch_logs` branch go (Editor.js:90-93,
  113-115, 339, 379-383, 964, 1413-1422, 1534-1537, 1654, 1812;
  ProgressBar.js:39-75; whatever StatusTab.js and BottomRightPanel.js still
  hold after piece 5), as do `binder_session_url`/`binder_session_token`
  (Editor.js:341-342, 385-386, 1013-1015, 1680), the binder spinners
  (1670-1676), the binder FilePicker branch (1697-1700),
  `launch_params.binder_url` and `pluto_server_url`
  (parse_launch_params.js:26, 28), and the `pluto-editor.binder` CSS
  (editor.css:1250-1292, 1444-1446). `trailingslash` moves to
  `common/URLTools.js` for SliderServerClient.js:1, which bonds will need.
  (Line numbers are today's; pieces 4 and 5 move them.)
- **Frontmatter and presentation**: the title fallback
  `metadata?.frontmatter?.title` (Editor.js:1659), the
  `frontmatter.language` reads (1499, 1546), and the `body.presentation`
  and `nav#slide_controls` CSS (editor.css:4018-4062).
- Not touched: `DesktopInterface.js` (other callers remain: Editor.js,
  PlutoConnection.js); the bonds code (`common/Bond.js`, `common/SliderServerClient.js`)
  for interactive inputs later.

**Test dependency.** `@axe-core/playwright` is added to tests/e2e as a
test-only dependency (never shipped in the package), for test 171.

### Tests

153-171: unit 153-158, request 159, end to end 160-171.

### Risks

- **Endeavor's Present, Record and Frontmatter actions**
  (actions.ts:1-5, 155-159) do nothing on Ember pages; they already did
  nothing, since the listeners were gone (#62).
- **Esc order in CodeMirror.** If our Esc ran before completion's or the
  search panel's, Esc would stop closing them; `Prec.low` and test 166
  cover it (plus a manual check with the completion list open).
- **Selection lasts longer**, so Backspace deletes a selected cell more
  often; the `in_textarea_or_input()` guard and the Undo toast limit it.
- **Live settings** go through compartments in every open editor; a missed
  consumer only applies after reload. Test 163 checks indent, Tab and
  theme; autocomplete and spellcheck are checked by hand.
- **Deleting binder branches** touches files piece 5 restyles; done last,
  it is a deletion on top of piece 5's files.
- **Wording ownership**: if pieces 4-6 leave a Words6 string, test 155
  fails here, on purpose, and this piece fixes it.
- **axe findings on Pluto's leftovers** may fail test 171 at first; each
  finding is fixed, not suppressed, unless it is in a vendored library
  (`imports/`), which is excluded by selector.

### Order within the piece

1. 7b + 7c: Export menu, Settings with live settings: tests 161-163.
2. 7d: shortcuts sheet and F1: tests 164, 165.
3. 7e + 7f: focus ring, skip link, cell selection, names, run announcer and
   notifications, reduced motion: tests 158, 160, 166-170.
4. 7g: wording, then the deletions (Julia rewriters, stickers, binder,
   frontmatter, CSS, unused keys), running the e2e "open" test after each
   batch: tests 153-157, 159.
5. MathJax loaded only when a cell's output has TeX, so the page makes no
   CDN request otherwise (the old gap list); offline.test.mjs checks that no
   request leaves the machine.
6. axe: test 171.

---

## Order of implementation

**1 → 2 → 3 → 7a → 4 → 5 → 6a → 6b → 7.**

- **Engine first** (the user's instruction). Pieces 1-3 change what the
  engine computes and what the page receives, each with only the minimal
  page change, so the frontend pieces build on final data.
- **1 before 2**: both edit `can_run()`, `reduce_run()`,
  `invalidate_dependents()`, `reduce_wk_done()` and `not_run_ids()`. Piece
  2 then uses `cell_runs()` in what piece 1 left; its `mixed_text` error is
  a graph error, so piece 1's rule (the broken cell can't run, its
  dependents can) applies; a text cell that reads a failed cell's name gets
  piece 1's upstream error because text cells get graph edges. Piece 1's
  `disable` op refuses text cells, and piece 2's `set_code` clears
  `disabled` when a cell becomes text. Piece 2's reader infers kinds after
  piece 1's un-commenting. Piece 2's docstring Help skips piece 1's off
  cells.
- **3 after 1**: piece 3 stores variables only for an ok result (after
  piece 1 a failed cell's globals are dropped) and none for an off cell
  (piece 1 removes them with `remove_cell`); its `#|` sizes come from the
  stored code, which for a disabled cell is already un-commented. Both edit
  `run_cell()`'s bookkeeping (worker.R:395-455) and `reduce_wk_done()`
  (step.R:990-1057): a merge, not a design conflict. A `#|` line is code to
  piece 2's `cell_kind()`; a cell of `#'` and `#|` lines is mixed. A
  variable defined by an inline assignment names a text cell as its
  definer.
- **7a before 4, 5 and 6**: it is small and has no dependencies. Piece 4's
  rename form uses its `Dialog`; piece 5's ⋯ menu and piece 6's cell menu
  use `useMenu` and its CSS; nobody builds a menu twice. Pop-ups whose code
  a later piece deletes anyway are converted cheaply now (Editor.js:1234,
  1249 become `ask`/`tell`; piece 4 deletes them), and the three left
  (Export, Settings reload, shortcut list) go with piece 7's rewrites. Test
  78 allows exactly those three; test 153 allows none.
- **4 before 5**: piece 5 then restyles a header, Packages tab and start
  page that already have their final controls. Piece 4 gives piece 5 the
  `#ember-file-name` button and MoveDialog to place, and the Update button,
  update states and failure cards to lay out; `start.css` uses the kept
  theme variable names, so piece 5's values apply with no edit, and
  start.html gains piece 5's inline theme script. Piece 4 gives piece 7 the
  start page URL for "Open another notebook" and leaves no `confirm()`.
  Piece 4 and pieces 1-3 touch different functions (`reduce_move()`,
  `reduce_wk_hello()`, packages-core.R); worker.R's `handle_next()` switch
  gains piece 1's `drop_globals` and piece 4's `chdir`.
- **5 before 6 and 7**: both build on its tokens (including the rail,
  error, syntax and ANSI ones), fonts, column, header and theme switching.
  Piece 5's Variables tab reads piece 3's `cell_results[id].ember.variables`
  (name, type, value, kind), greys rows by that cell's `ember.stale`, and
  links each name to the cell id. Its Status tab reads piece 1's
  `ember.not_run`, which counts cells below failed or broken cells and
  leaves out off cells. It keeps NotifyWhenDone and its two StatusTab
  exports for piece 7 to replace.
- **6 after 1, 2, 3 and 5**: 6a needs piece 1's states (no blocked state;
  disabled and depends-on-disabled with `ember.disabled_by` and
  `ember.can_disable`) and piece 5's tokens and column (it removes `main`'s
  25 px / 6 px padding and sets `max-width` to exactly the column). 6b
  needs piece 1's upstream error and rewriter, piece 2's `kind` rule,
  `.ember-inline`, `ember.split`, `button.ember-split` and the run error's
  `call`/`line`, and piece 3's `ember.figure` and EmberPlot. Piece 6 gives
  piece 7 the DOM order for Tab, translated titles, `data-rail` for cell
  names, and a running rail that is solid without animation.
- **7 last**: its wording sweep and binder deletions touch every earlier
  frontend piece's files, and test 155 checks their strings. Piece 1 has
  already replaced the `UndefVarError` rewriter, so piece 7 deletes only
  the Julia-only ones.

3a and 3b can be two branches. 4 can run in parallel with 1-3 if needed
(no shared functions), as long as 7a merges before its MoveDialog step.

## Open points

Everything the drafts asked has been decided (ui-3.md and the user's
decisions recorded above). The signature tooltip shows only the
arguments, also for notebook functions; a docstring is read in Help.
Nothing is left open. Endeavor follow-ups are tracked in #62 and
are not part of this increment.
