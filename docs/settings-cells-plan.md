# Settings cells: implementation plan

This plans how to build [settings-cells.md](settings-cells.md): the setup
cell goes away, any cell may change a global setting, and a setting (or an
attached package) may be set in only one cell. It also folds in the design
gap "`library()` inside a function body counts as attaching"
([design-gaps.md](design-gaps.md), Engine), because "attaching is a
definition" changes the same code.

It is one branch, built in seven steps. Steps 1 and 2 leave the setup cell
working; step 3 removes it everywhere at once, because the graph, the
session and the worker each assume it. CI is green after step 2 and again
at the end. Roughly 1,400 changed lines: 550 of R, 150 in the worker, 60 in
the page, 600 of tests, plus docs.

1. **Static setting names**: the walker says which setting a call sets.
2. **Walker scope rules**: `local()` and function bodies stop counting.
3. **The graph without a setup cell**: settings cells, pass 1, setting
   edges, the two conflict errors.
4. **The file format**: `[setup]` read and ignored; `learned settings`.
5. **The session**: learned settings, the run message's settings context,
   no refusals.
6. **The worker**: per-cell after-values and the per-run reset.
7. **API, page, docs.**

## Rules this follows

- **design.md and settings-cells.md decide behaviour.** Where they are
  silent, this plan picks a default and marks it **Default:**, so it can be
  overridden without reading the code.
- **Worker messages change on both sides in one commit** (ui-3-plan.md's
  rule; the shell kills a worker that sends an unknown message type).
- **R/notebook.R is shared with the Bioconductor work**, which changes the
  header's `bioc_version` handling. This branch touches only the cell
  marker tag, the setup fallback, the two problems and the footer list in
  that file; nothing in the header.
- R code is ASCII only; man pages are hand-written; comments only for
  constraints.

---

## 1. Static setting names

### Problem

The walker records that a cell calls a setting function, not which
setting it sets. `record_setting()` (R/scope.R:241) stores `fn`, `line`,
`col`, `end_col`; the analysis's `settings` data frame has no name column
(R/analysis.R:42-47, 103). The one-cell-per-setting rule needs the name:
`options(digits = 3)` and `options(scipen = 999)` in two cells are fine,
`options(digits = 3)` twice is not.

### Shape

`settings` gains a `setting` column: the setting's key, or `NA` when the
call doesn't say (a computed name). One row per key, so
`options(digits = 3, scipen = 999)` gives two rows with the same position.

| Call | `setting` |
|---|---|
| `options(digits = 3)` | `option:digits` |
| `options(op)`, `options(list(...))` with a non-literal list | `NA` |
| `options(list(digits = 3))` (literal `list()`) | `option:digits` |
| `Sys.setenv(TZ = "UTC")` | `env:TZ` |
| `Sys.setenv(.list)` | `NA` |
| `Sys.unsetenv("TZ")`, `Sys.unsetenv(c("A", "B"))` | `env:TZ`; `env:A`, `env:B` |
| `Sys.unsetenv(x)` | `NA` |
| `setwd(...)`, `withr::local_dir(...)` | `wd` |
| `Sys.setlocale(...)`, `withr::local_locale(...)` | `locale` |
| `theme_set(...)` | `theme` |
| `attach(survey)`, `attach("survey")`, `attach(x, name = "s")` | `attach:survey`, `attach:survey`, `attach:s` |
| `attach(read.csv(f))` (no name) | `NA` |
| `withr::local_options(digits = 3)`, `local_options(list(digits = 3))`, `local_options(.new = list(...))` | `option:digits` |
| `withr::local_envvar(TZ = "UTC")`, `local_envvar(c(TZ = "UTC"))` | `env:TZ` |

`attach(x)` with no `name` takes R's own default, `deparse1(substitute(what))`,
which is the symbol's name or the literal string.

A new helper in R/walk-calls.R, `setting_keys(name, e)`, returns the keys
for one call; `dispatch_call_by_name()` (R/walk.R:173-197) records one row
per key. The table above lives next to `setting_functions` in R/rules.R
as `setting_kinds` (function name -> key prefix), so rules.R stays the one
place the rules are listed.

`resolve_cells()` (R/graph.R:296) adds `setting_names`: the unique
non-`NA` keys, and `computed_setting`: `TRUE` when any row's key is `NA`.

### Tests

test-walk.R: one case per row of the table, plus `options("digits")`
(a read, no row) and `options(digits = 3, scipen = 999)` (two rows, one
position).

---

## 2. Walker scope rules

### Problem

Two rules count too much:

- **Settings inside `local()`** count (R/walk.R:318-324, gated on
  `!in_function(scope)`). settings-cells.md drops this: the base-R pattern
  `local({ op <- options(digits = 3); on.exit(options(op)); ... })` is a
  scoped change, and the worker still sees any change that outlives the
  cell.
- **`library()` inside a function body** counts as attaching
  (`walk_package_call()`, R/walk-calls.R:11-54, has no scope check). Under
  "attaching is a definition" that makes
  `load_all <- function() library(dplyr)` conflict with a top-level
  `library(dplyr)` in another cell, and today it already makes the cell
  run in pass 2 (design-gaps.md, Engine).

### Shape

- Settings: record only when the scope chain from the call to the top has
  no `"function"` and no `"local"` scope. A new `in_function_or_local()`
  beside `in_function()` (R/scope.R:117). `source()` and `data()` keep
  their current rule (still counted inside `local()`).
- Packages: inside a function, `library(pkg)` records the package with
  `attached = FALSE`. It is still a package the notebook needs (so it is
  installed and locked), but it attaches nothing statically: no pass 2,
  no `package` edges, no conflict. At run time the worker still tracks
  what the call attached (`attach_requests`), so the search path stays
  right.

### Tests

test-walk.R: `local(options(digits = 3))` has no setting;
`f <- function() options(digits = 3)` has none (unchanged);
`f <- function() library(dplyr)` has `dplyr` with `attached = FALSE`;
top-level `library(dplyr)` unchanged. test-graph.R: a cell defining
`f <- function() library(dplyr)` is not in pass 2.

---

## 3. The graph without a setup cell

About 250 changed lines in R/graph.R.

### Problem

`setup` is threaded through `notebook_graph()`, `resolve_edges()`,
`find_errors()` and `compute_order()` (R/graph.R:144, 360-441, 498-692).
Every other cell gets a `via = "setup"` edge (R/graph.R:435-439);
`global_setting` is an error on any other cell with a setting
(R/graph.R:580-591).

### Shape

**Inputs.** `notebook_graph(cells, exports, learned, disabled, previous,
read_file)`: `setup` is gone. `learned` gains `settings` (id ->
character keys), filtered to known ids like the other two parts.
`graph_learn()` gains a `settings` argument, same replace semantics.

**Which cells are settings cells.** `settings_cells(cells_resolved,
learned, disabled)`: an enabled cell whose `setting_names` plus learned
settings is non-empty, or whose `computed_setting` is `TRUE`. A cell's
full key set (static plus learned) is stored on `cells[[id]]$settings_keys`
with where each was found (`"code"` or `"run"`) for the view.

**Order.** `compute_order(ids, settings, upstream, attaches, comp_of,
is_markdown)`. Pass 1 is `for (s in settings) emit(s)` in display order,
replacing `emit(setup)`. `emit()` already emits a cell's ancestors first,
so a settings cell's reads come before it. Passes 2 and 3 are unchanged.

**Setting edges.** After the order is fixed, each non-markdown cell gets
one edge to every settings cell before it in the order, with
`via = "setting"` and `name` the first key of that settings cell (so a
message can say why; one row per (from, to), not per key, to keep the
edge count at cells x settings cells). "Non-markdown" uses the same
`is_markdown` as the order (empty analysed code), so a text cell with an
inline expression gets the edges and runs under the settings, as it would
under `Rscript`.

These edges are added after `scc_components()`, `find_errors()` and the
order, so they never feed the cycle check. They agree with the order by
construction: a cell after a settings cell in the order is never its
ancestor, except inside a cycle that is already an error.

`upstream`/`downstream` are rebuilt from the full edge set, so running a
settings cell marks every later cell stale (`invalidate_dependents()`,
R/step.R:512) and running any cell first runs its unfresh settings cells
(`unfresh_ancestors()`), as the setup edge did.

**Default: `off` ignores setting edges.** `compute_off()` (R/graph.R:243)
walks the downstream lists built *without* setting edges. Otherwise a
settings cell that is off because it reads from a disabled cell would turn
off the whole rest of the notebook. settings-cells.md says a disabled
settings cell adds no edges for the same reason; this covers a settings
cell that is off without being disabled itself. An off settings cell is
simply not in effect.

**Errors.**

- `global_setting` is removed.
- `setting_conflict`: one key in two or more enabled cells (static or
  learned). `cells` = those cells, `names` = the key's display name
  (`digits`, `TZ`, `wd`, `locale`, `theme`, `attach(survey)`), `lines`
  from the static rows (a learned key has `line = NA`). Message:
  "**digits** is set in two cells." (or "in N cells"). Fix by kind:
  "Set it in one cell, or use withr::with_options() to change it for one
  piece of code" (`with_envvar()`, `with_dir()`, `with_locale()`; theme:
  "add the theme to the plot (p + theme_minimal())"; attach:
  "use with(survey, ...) or survey$col").
- `package_conflict`: one package attached at the top level of two or
  more enabled cells. Message "**tidyverse** is attached in two cells.",
  fix "Keep one library(tidyverse) and remove the other". Only literal
  names count; `requireNamespace()`, `pkg::fn` and a computed name never
  conflict.
- `mixed_text` loses its setup exception.
- The cycle error's `inside` filter (R/graph.R:631) drops `"setting"`
  instead of `"setup"`.

A cell with a conflict error is blocked, as any graph error is. Its
dependents still run (errors flow downstream), and since
`failed_definers()` only follows `definition` and `package` edges
(R/step.R:303), they fail with their own R error, if any, not an
"upstream" one. That is the setup edge's rule today.

**Rule 3-4 fallback** (`resolve_edges()`, the disabled-definer edges):
the setup cell's exception goes. A settings cell reading a name only a
disabled cell provides becomes off, and by the default above that turns
off only itself and its own readers.

### Tests

test-graph.R, replacing the setup cases (about 70 references):

- The worked example in settings-cells.md ("Run order"): order 2, 4, 3, 1,
  5, and cells 1 and 5 have a setting edge to 3; 2 and 4 don't.
- The four cycle cases in "Why every cell depends on every settings cell
  fails": two settings cells; a settings cell using another cell's
  package; a setting inside a helper (as a learned setting); a setting
  computed from another cell. None is a cycle.
- Two settings cells in display order: the second has an edge to the
  first.
- `setting_conflict` for `options(digits)` in two cells, for a static key
  against a learned key, and none for `digits` and `scipen` apart.
- `package_conflict` for `library(tidyverse)` twice; none for
  `library(tidyverse)` and `library(ggplot2)`; none for a function body.
- A disabled settings cell adds no edges; an off settings cell (reading a
  disabled cell) adds edges to nothing off.
- A markdown cell gets no setting edge; a text cell with `` `r x` `` does.
- `notebook_graph(previous = g)` gives an identical graph (the
  idempotence invariant).

---

## 4. The file format

About 60 changed lines in R/notebook.R, kept to the parts listed in
"Rules".

### Shape

- The marker parser (R/notebook.R:269) still accepts `[setup]` so a file
  parses, and ignores it. The writer stops writing it (R/notebook.R:733).
- The setup fallback (R/notebook.R:613-624) and its problems
  `no_setup_marker` and `disabled_setup_cell` are removed. A file with no
  cells gets one empty cell, since the graph needs at least one.
- `cell_kind(code)` loses `setup` (R/text-cells.R:19). **Default:** an old
  setup cell whose code is only `#'` lines becomes a text cell; until now
  it was forced to be code.
- New footer block `learned settings`, between `learned definitions` and
  `lock`, written only when non-empty:

  ```r
  # /// learned settings
  # c93b... option:digits wd
  # ///
  ```

  `parse_learned_block()` already reads this shape; it is reused.
  `known_footer` gains the name, so an old file's block isn't kept twice.
- `new_notebook_file()` loses `setup` and gains `learned_settings`.
- Format number stays 1 (settings-cells.md, File format).

### Tests

test-notebook-file.R: the format-1 fixtures in `tests/testthat/files`
lose `[setup]`, except one kept as `setup-tag.R`, which parses with the
tag ignored and round-trips without it; a `learned settings` block
round-trips byte for byte; an old setup cell with only `library()` is an
ordinary cell; an empty old setup cell is kept as an empty cell. The
problem-kind tests for the two removed problems go.

---

## 5. The session

About 200 changed lines across R/step.R, R/state.R, R/pluto-state.R.

### Problem

`state$setup` exists (R/state.R:54, 125, 163, 460, 523, 558, 690-696).
Delete and disable refuse it (R/step.R:698-699, 723-724). The run message
has `role = "setup"` (R/step.R:446). `reduce_wk_done()` turns any
reported setting change outside the setup cell into a `global_setting`
run error (R/step.R:1293-1297).

### Shape

**State.** `state$setup` and every reference go. `check_state()` drops
its two setup checks. `new_state()` seeds `learned$settings` from the
file.

**Learned settings.** In `reduce_wk_done()`, the report's `settings`
(list of kind, name, before, after) become keys: `option` -> `option:<name>`,
`env` -> `env:<name>`, `wd` -> `wd`, any `locale` category -> `locale`,
`theme` -> `theme`, `search` -> `attach:<entry>` for each entry added or
removed. New keys are unioned into `learned$settings[[id]]` and the graph
is rebuilt with `graph_learn(settings = ...)` only when that changes the
set (the same guard learned definitions have, R/step.R:1315). Learned
settings are never shrunk by a run, only by an edit (below).

When a run adds a key the cell didn't have:

1. The rebuild moves the cell to pass 1 and gives later cells setting
   edges.
2. `invalidate_dependents(state, id, character())` marks them stale and,
   in autorun, queues them (they now depend on the cell).
3. The result gets `settings_found = <display names>`, shown once.

**Dropping learned settings on edit.** In `reduce_apply()`, a `set_code`
that changes a cell's code removes `learned$settings[[cell]]`
(settings-cells.md, "kept until the cell's code changes"). Learned
definitions keep their current rule.

**The run message.** `run_message()` (R/step.R:442) drops `role = "setup"`
(roles are `"cell"` and `"text"`) and adds
`settings = <settings cells in effect before id, in order>`: settings
cells before `id` in `graph$order` that are not disabled, not off, have
no graph error, and whose last result is not `"error"` or
`"interrupted"`. A settings cell that has never run is in effect (it has
no after-values yet, so it adds nothing); `schedule()` already runs it
first because it is an unfresh ancestor.

**Run errors.** `global_setting` is removed from `new_run_error()`'s
kinds and from `reduce_wk_done()`. A cell that changes a setting now runs
"ok".

**Delete and disable.** Both refusals go. `disable_cell()` still refuses
text cells.

**Views and projection.**

- `cell_view()` replaces `setup` with `settings`: a list of
  `list(name = <display name>, found = "code" | "run")`, empty for an
  ordinary cell; and `settings_found` from the result.
- `project_cell_result()`: `can_disable` is `TRUE` for every code cell;
  `ember$settings` (present when non-empty) and `ember$settings_found`
  (present only on the run that found it).
- `project_dependencies()` leaves `"setting"` edges out, as it leaves
  out the unnamed setup edges today.
- `precedence_heuristic`: settings cells 3L, attaching cells 5L, else 9L.

### Tests

test-step.R, test-session.R, test-queries.R, test-pluto-state.R,
test-projections.R (about 60 references to rewrite, mostly dropping
`setup =`). New:

- Deleting a settings cell, and disabling one, are accepted; later cells
  go stale and (autorun) rerun.
- A run that reports `options(digits)` from `prep()` adds a learned
  setting, reorders, queues the later cells once; a second run reporting
  nothing keeps it; editing the cell drops it.
- The run message's `settings` excludes a disabled, off, failed or
  conflicting settings cell, and cells after the target.
- Lazy mode: running a settings cell marks later cells stale and queues
  nothing.
- Two cells found at run time to set `digits` get `setting_conflict`.

---

## 6. The worker

About 150 changed lines in inst/worker.R. One field is added to `run`
(`settings`); `role` loses `"setup"`.

### Problem

The worker keeps `setup_restore` (worker.R:100), reverts a non-setup
cell's setting changes after it runs (worker.R:448-452) and restores the
setup cell's before-values before it reruns (worker.R:251, 671-679).

### Shape

New worker state, replacing `setup_restore`:

- `settings_base`: the baseline. Starts as `settings_start` (the boot
  snapshot); every change a package load makes (`load_log`) is copied
  into it, so a package's own option survives a reset.
- `cell_settings`: cell id -> list of `list(kind, name, after)`, the
  after-values of the cell's own last run (what `settings_by_code()`
  reports).
- `touched`: every `(kind, name)` any cell has changed this session.
  Never shrinks.

`apply_settings_context(ids)`, called in `run_cell()` where
`restore_setup_settings()` is now (inside the guarded block, for the
interrupt reason given there):

1. For every touched key, set `settings_base`'s value.
2. For each id in `ids`, in order, apply its after-values.

Errors from a single `apply_setting()` are swallowed, as today. After the
run, the cell's diffs become `cell_settings[[cell]]` and join `touched`;
nothing is reverted. `remove_cell()` drops `cell_settings[[cell]]` (it
is called before every rerun and on delete, so a rerun starts clean).

**`wd` after a move.** The `chdir` handler (worker.R:152-178) rewrites
`settings_base$wd` and every `wd` after-value equal to `from`, or under
`from/`, to the same path under `to`. Today only an exact match is
rewritten.

**attach().** Best effort, as today. A `search` diff records which
entries the cell added. Reset detaches every entry a cell added whose
cell is not in `ids`; entries of cells in effect stay where they are.
Nothing is re-attached, since a detached entry's contents are gone.

**Default: ggplot2's theme is a setting the worker sees** (the open
question in settings-cells.md). When the `ggplot2` namespace is loaded,
`snapshot_settings()` adds `theme = ggplot2::theme_get()` (called through
`getNamespace()`, since the worker only sees base R), and
`apply_setting("theme", ...)` calls `theme_set()`. Without this, deleting
a `theme_set()` cell would leave its theme in place until a restart, which
is the hidden state settings cells exist to remove. It also finds
`theme_set()` inside a helper. Cost: one `theme_get()` per snapshot.

`.Random.seed` is never touched (unchanged).

### Tests

test-worker.R (the worker sourced alone):

- Cell A sets `digits`, cell B prints with `settings = "A"` and with
  `settings = character()`: 3 then 7 digits.
- `setwd("sub")` run twice with the same context lands in `sub`, not
  `sub/sub`.
- A deleted settings cell's option is back to the base on the next run.
- An option a package sets on load survives a reset.
- `theme_set()` in a cell; a later cell's `theme_get()` matches with the
  cell in context and is the default without it (skipped without
  ggplot2).
- `chdir` rewrites a `wd` after-value under the old folder.

---

## 7. API, page, docs

### R API (~40 lines, R/api.R)

- `new_notebook()` writes one empty code cell.
- `edit_notebook()` and `disable_cell()` docs drop the setup refusals.
- `notebook_snapshot()` and the cell views show `settings` as they are.

### Page (~60 lines)

- Cell.js: a settings chip when `ember.settings` is non-empty, in the
  chip slot, below the state chips (a disabled, stale or not-run chip
  still wins the slot, as today). Text: "Setting · digits" or
  "Settings · digits, wd" (at most three names, then "and N more", as the
  stale chip does). Hover: "This cell changes a global setting. It runs
  before the cells that don't feed it, and they rerun when it changes."
  plus "Found when it ran." when any name was found at run time.
- Cell.js: when `ember.settings_found` is present, one line above the
  output: "Found a global setting (digits) when this cell ran; the cells
  after it rerun."
- The cell menu's "Disable cell" shows for every code cell (it already
  follows `can_disable`).
- Notebook.js: the empty-notebook check's comment changes; the check
  itself already works for one blank cell.
- lang/english.json: the chip, hover and note strings.

### Docs

- engine.md and cell-graph.md: the setup cell sections describe settings
  cells instead.
- design.md: remove the "planned" marks the gap-list thread is adding to
  the three "no setup cell" passages.
- design-gaps.md is owned by another thread: on merge, ask it to tick
  "Replace the setup cell" and "`library()` inside a function body".

### Tests

test-api (new notebook has one cell), the e2e tests that open a new
notebook (`tests/e2e/tests/cells.test.mjs`, `panel-default.test.mjs`
count cells), and test-frontend-files.R for the new strings.

---

## Release notes

Two changes in what counts as an error, from settings-cells.md:

- A setting outside the old setup cell was an error; it is now a settings
  cell, unless the old setup cell sets the same thing.
- A package attached in the old setup cell and again in another cell is
  now "attached in two cells".

## Risks

- **"Attached in two cells" will be the most common new error.** R
  scripts repeat `library()` calls habitually, and every notebook
  converted from a script will hit it. The design accepts this (it keeps
  the search path one-to-one with cells). If it proves noisy, the cheap
  softening is to make the duplicate a note instead of an error when both
  cells attach exactly the same package, which costs the
  one-to-one property only for identical lines.
- **A false settings cell reruns the notebook.** A package function that
  sets an option as a side effect (`future::plan()` is a real one; a
  progress bar setting a `cli.*` option would be a false one) makes its
  cell a settings cell on first run. Today such a cell is a
  `global_setting` error, so this is milder than now, but the rerun is
  visible. Watch for it in the package-loading spike (design.md,
  spikes).
- **attach() stays best effort.** A cell before an `attach()` cell in
  the order still sees the attached entry if it ran after it once.
- **The graph rebuild cost** grows by one edge per (cell, earlier
  settings cell). At 2000 cells and five settings cells that is 10,000
  edge rows, against about 2,000 setup edges today. Measure with the
  existing 2000-cell timing test; if it regresses, store setting edges
  as a per-cell count instead of rows.
