# Tests for increment 3

The same three layers as increments 1 and 2 (docs/ui-tests.md,
docs/ui-2-tests.md): pure unit tests (testthat, no process), request
handling (testthat, real engine, fake sockets from `helper-server.R`, or a
real session as `test-session.R` does), and end to end (Playwright in
`tests/e2e/`, real server and worker). Engine tests use `test-step.R`'s
`fake_state()`, `boot()`, `drive()` and `report()`. Worker tests source
`inst/worker.R` into an environment and call its functions directly, as
`test-worker.R` does. Numbers continue across pieces so the plan
(docs/ui-3-plan.md) can cite them. Pieces are listed in branch order.

New fixtures:

- `tests/e2e/fixtures/upstream.R` (piece 1): setup `S`, `A`
  (`a <- 1; stop("boom")`), `B` (`a + 1`), `C` (`1 + 1`).
- `tests/e2e/fixtures/disabled.R` (piece 1): `S`, `A` (`x <- 1`), `B`
  (`x + 1`), `C` (`2`).
- `tests/e2e/fixtures/text.R` (piece 2): `S` (setup, empty), `A`
  (`x <- 21`), `T` (`#' Half of it is `r x / 2`.`), `M`
  (`#' ## The model\n#' A line.\nfit <- lm(mpg ~ wt, cars)`), `E`
  (`#' The heaviest car weighs `r max(carz$wt)` thousand lb.`), `FN`
  (`# Drop rows with a missing value.\n#\n# Returns a data frame.\nclean <- function(df) df[complete.cases(df), ]`).
  `basic.R` and `rich.R` keep their `[markdown]` markers, so they also test
  reading the old layout.
- `tests/e2e/fixtures/rich.R` gains a cell `FIG` (piece 3):
  `#| fig-width: 5` / `#| fig-height: 4` / `plot(1:10)`.
- `tests/testthat/fixtures/failing-installer.R` (piece 4): a stand-in for
  installer.R (through `options(ember.installer_script)`, library.R:196).
  It prints a captured `brokenpkg` failure (renv's block, the clang error,
  `ERROR: compilation failed for package 'brokenpkg'`, `Error: failed to
  install "brokenpkg"`) over about 1 s with `Sys.sleep()` between lines,
  so the shell reads it while the process is alive, then exits 1.
- `tests/testthat/fixtures/install-output/` (piece 4): captured installer
  output for `install_failures()`: compile (ASCII and curly quotes),
  dependency, configure, download, and a run with two failures.
- `tests/e2e/fixtures/failing.R` (piece 4): setup cell `library(brokenpkg)`
  with the lock line `brokenpkg 0.1.0 CRAN`. The e2e server sets
  `ember.installer_script` to failing-installer.R in its `-e` expression.
- `tests/e2e/fixtures/cells.R` (piece 6): `A` (`x <- 1`), `B` (`x + 1`),
  `F` (`f <- function(d) lm(mpg ~ wt, data = d)`), `ERR`
  (`bad <- list(wt = list(1)); f(bad)`: an error inside stats called from a
  notebook function), `TOP` (`y <- 2\nstop("boom")`: an error at line 2
  with no call), `W` (`message("Reading"); warning("careful");
  cli::cli_alert_success("ok"); 1`, with
  `cat("\033[38;5;246mgrey\033[39m\n")` in place of the cli call when cli
  isn't installed), `NA` (`data.frame(a = c(1, NA), b = c("x", NA))`),
  `VEC` (`list(a = 1, long = 1:100, sub = list(c = "x"))`), `NEVER`
  (`z <- 3`, never run), `TXT` (`#' ## Results\n#' Mean is `r mean(1:3)`.`).
- `tests/e2e/fixtures/cells-lazy.R` (piece 6): `on_cell_change = "lazy"`;
  `A` (`x <- 1`), `B` (`x + 1`).
- `tests/testthat/fixtures/retired-wording.txt` (piece 7): the "Today"
  column of board Words6, one string per line (about 45 lines).
- `tests/testthat/fixtures/endeavor-css-variables.txt` gains
  `--normal-cell-color`, `--selected-cell-color` and
  `--code-differs-cell-color` (piece 5), which Endeavor reads
  (endeavor/frontend/src/errors.ts:29-31).

## Piece 1: Errors flow downstream, and Disable cell

### Errors flow downstream

**Unit**

1. Autorun: A (`a <- 1`) and B (`b <- a`) have run. Rerun A and report
   `status = "error"` with `created = "a"`. The effects are, in order, a
   `drop_globals` for A and then a `run` for B. B is no longer in
   `pending` once sent.
2. Lazy: the same failure leaves B stale and out of `pending`, and sends
   `drop_globals` for A.
3. Rewrites test-step.R:538-556 ("item 6"). With A failed, `ev_run("B")`
   queues A then B; `reply$skipped` is empty. After A fails again, B is
   sent.
4. Classification: B errors after A failed. B's error has
   `kind = "upstream"`, `names = "a"`, `cells = "A"`, and R's message
   kept. If B errors while A is ok, the kind is `"error"`. If B's own
   failure is `missing_package` or `source_conflict` instead of a plain
   error, its kind is unchanged (not rewritten to `"upstream"`), even
   though A failed. Through a package edge: if A attached a package and
   then failed on something else, B calling one of A's exports gets its
   own `"error"`, not `"upstream"` (the package is still attached); if
   A's own last failure is `missing_package`, B gets `"upstream"` through
   that edge. With only the setup edge between them (the setup cell
   failed), the kind is `"error"`.
5. A chain: A fails, B reads A and C reads B. B's error links A, and C's
   links B.
6. Interrupt: interrupting A's run sends `drop_globals` for A, leaves B out
   of `pending` and leaves B's result stale.
7. Rewrites test-step.R:232-237 (increment 1's test 40). A and A2 both
   define `x`; C reads `x`; F (`2`) is unrelated. The edit that creates
   the clash sends nothing and queues nothing. `ev_run(NULL)` skips only A
   and A2, and C is sent. Separately: A has a result from before the
   clash and E (`x + 1`) has one too; `ev_run("F")` gives effects that
   include `drop_globals` for A before F's `run`, `results$A` is `NULL`,
   E's result is stale, and `pending` holds only F (E is not queued, in
   autorun too). A second `step()` with nothing new sends no second
   `drop_globals`.
8. The server's own run errors (test-step.R:286-, "changing a foreign
   global", and a `global_setting` report) send `drop_globals` for that
   cell.
9. Rewrites test-step.R:239-248 (increment 1's test 41). After A's error,
   a dependent with no result is still not run, and one with a result is
   pending in autorun.
10. Replaces test-status-views.R:263-291. `not_run_ids()` counts a not-run
    cell below a failed cell and one below a graph error, and does not
    count a cell with its own graph error. `view_context()` has no
    `blocked`/`blocked_by`, and a snapshot view has neither field
    (test-projections.R:23 drops its `blocked` line).
11. Replaces test-pluto-state.R:246-255 and test-status-views.R:60-68. For
    B's upstream error, `project_cell_result()` gives
    `depends_on_disabled_cells = FALSE` and
    `ember$upstream_error = list(list(name = "a", cell = "A"))`. The output
    is the stacktrace mime with `msg` "Another cell defining a contains
    errors." and no frames, and `plain_error` holds R's message on a
    second line. Two names give "a or b". `check_wire()` passes. Every
    other cell has no `upstream_error`.
12. Worker: after a run creating `x` and calling `library(tools)`,
    `drop_globals` removes `x` and `"package:tools"` is still on
    `search()`. A later `run` of the same cell works.

**Request handling**

13. Real session: A `a <- 1; stop("boom")`, B `a + 1`, C `exists("a")`
    (a string, so C has no edge to A). After
    `run_cells(nb, NULL, wait = TRUE)`, B's status is "error" with kind
    `"upstream"`, and C's output text is `[1] FALSE`. Fix A to `a <- 1`
    and run it: in autorun B reruns and is "ok".

**End to end**

14. Open `upstream.R` and run all. A shows "boom". B shows a `jlerror`
    reading "Another cell defining a contains errors." with no traceback
    button, and its `a` is a link; clicking it puts A's `pluto-cell` in the
    viewport. C shows `2`. No element contains "upstream error".

### Disable cell

**Unit, file format** (test-notebook-file.R)

15. A disabled cell whose code is the lines `x <- 1`, an empty line,
    `  y`, `# note`, `#' not text`, `#| fig-width: 4`, `##`, `%% 2` is
    written as `## x <- 1`, `##`, `##   y`, `## # note`, `## #' not text`,
    `## #| fig-width: 4`, `## ##`, `## %% 2`, and its footer line is
    `# <id> disabled` (`# <id> folded disabled` when folded too). Parsing
    gives the same code exactly, `disabled = TRUE`, and `problems` `NULL`.
    `format_notebook(parse_notebook(text)) == text`.
16. The `%% 2` line from test 15, and a `/// x` line, produce no extra cell
    and no footer block: the file has exactly the cells written.
17. A `commented` cell reads back with its exact code and
    `disabled = FALSE`. `notebook_file_of()` for S, A (`x <- 1`,
    disabled), B (`x + 1`), C (`2`) gives `commented = "B"` (A carries
    `disabled`); the text has `## x + 1` and `# B commented`, and C is
    written plainly. With A2 (`x <- 2`, enabled) added, B reads A2 and is
    written plainly.
18. Repairs: a line without `##` in a disabled cell is kept as is, with
    problem `uncommented_line`. `disabled` on a text cell gives
    `disabled_text_cell` and the cell unchanged. On the setup cell it gives
    `disabled_setup_cell`, the code un-commented and `disabled = FALSE`.
19. `ember_format` is still `1L`, every file in `files/format-1` still
    round-trips (existing test), and `round_trip_generated` now marks a
    random third of non-setup code cells disabled and another third
    commented. All 200 still round-trip byte for byte.

**Unit, graph** (test-graph.R)

20. `notebook_graph()` of S, A (`x <- 1`), A2 (`x <- 2`), C (`x + 1`) with
    `disabled = "A"`: no `multiple_definitions` error; C's only edge for
    `x` goes to A2 with `via = "definition"`; `off` is `c(A = "A")`.
    Without `disabled`: the error, and edges from C to both.
21. S, A (`x <- 1`), C (`y <- x`), E (`y + 1`), F (`2`) with
    `disabled = "A"`: C has one edge to A with `via = "disabled"`; `off` is
    `c(A = "A", C = "A", E = "A")`; F is not off; `downstream(g, "A",
    transitive = TRUE)` is `c("C", "E")`. `order` puts A before C with and
    without `disabled`. With A and C both disabled, C maps to itself.
22. Packages: exports `list(tools = "file_ext")`, A (`library(tools)`)
    disabled, B (`file_ext("a.R")`): B has a `"disabled"` edge to A and is
    off. When the setup cell also attaches tools, B has a package edge to
    the setup cell and is not off. `wanted_packages()` includes tools in
    both cases.
23. Errors: A disabled reads `y`, C defines `y` and reads A's `x`: no
    cycle error; with A enabled, one. A disabled cell with a syntax error
    keeps its `parse` error. A disabled non-setup cell calling
    `options(...)` gets no `global_setting` error. `graph_learn()` keeps
    `disabled` and `off`, and building with `previous` gives an identical
    graph.

**Unit, engine** (test-step.R)

24. Autorun; S, A (`x <- 1`), B (`x + 1`), C (`2`) have run. Apply
    `disable_cell("A")`: the effects are `remove_cell` for A and then for
    B, and no `run`. A's and B's results are kept with `stale = TRUE`, C's
    is untouched, and `pending` is empty.
25. `ev_run(NULL)`: `skipped` holds A and B. `ev_run("A")` with S made
    stale: nothing is queued, not even S.
26. Enable A (`disable_cell("A", FALSE)`): no effects, nothing pending.
    Then `ev_run("A")` sends A; after A's `done` (ok), B is pending and
    sent. In lazy mode the same steps leave B stale and not pending.
27. An edit makes a cell off: D (`y <- 3`) has run. Setting D to `x * 2`
    sends `remove_cell` for D and marks its result stale. Setting it back
    sends nothing.
28. Disabled while running: A is running and is disabled. The effects
    include `remove_cell` for A. A's later `done` (ok) stores a stale
    result, queues nothing and sends no `run` for B.
29. Refusals: disabling the setup cell, a text cell, or an unknown id is
    refused with the plan's wording. A batch of `fold` plus a refused
    `disable` changes nothing.
30. Safe preview (`allowed = FALSE`): disabling A has no worker effects,
    and A is disabled in `state$cells`.
31. Two definers: A and A2 define `x`, C reads `x`; A2 and C have results.
    Disabling A sends `remove_cell` for A only; A2's and C's results are
    stale; `pending` is empty; `graph$errors` is empty. `ev_run("C")` then
    queues A2 before C.
32. Views: `not_run_ids()` leaves out a never-run cell below A and counts
    one that isn't. The snapshot gives A `disabled = TRUE,
    disabled_by = NA`, B `disabled = FALSE, disabled_by = "A"`, and
    `stale = TRUE` for both. `check_state()` passes.
33. Projection: A's `metadata` is identical to `CELL_METADATA_DISABLED`,
    the others' to `CELL_METADATA`. `depends_on_disabled_cells` is `TRUE`
    for A and B. `ember$disabled_by` is absent for A and `"A"` for B, and
    `ember$stale` is `FALSE` for both. `can_disable` is `FALSE` for S and a
    text cell. `check_wire()` passes. With `previous`, only A's and B's
    entries are rebuilt.
34. Rewrites test-pluto-edits.R:195-: a `metadata.disabled` patch gives
    `list(disable_cell("A", TRUE))`; `show_logs` and `skip_as_script` are
    still refused.

**Request handling**

35. Real session: S, A (`x <- 1; library(tools)`), B (`x + 1`), H
    (`c(exists("x"), "package:tools" %in% search())`). After running
    everything, disable A and run H: H prints `[1] "FALSE" "FALSE"`. Run
    `Rscript` on the saved file
    (`system2(file.path(R.home("bin"), "Rscript"), path)`): exit status 0.
    Enable A and run it: B reruns and is "ok".
36. Server: in safe preview, an `update_notebook` with the
    `metadata.disabled` patch gets a thumbs-up, and the
    `run_multiple_cells` for A that the page sends next leaves the session
    not allowed (`process_status` stays the preview status).

**End to end**

37. `disabled.R`: run all. A's menu shows "Disable cell"; S's menu has no
    such item. Click it: A's `pluto-cell` has `running_disabled`, B has
    `depends_on_disabled_cells`, C has neither. The file on disk contains
    `## x <- 1` and `# <A> disabled`. Reload: the classes are still there.
    A's menu now reads "Enable cell"; click it: A runs, B reruns, and B's
    output is `2`.

## Piece 2: Text cells and inline r expressions

**Unit**

38. `cell_kind()`: `"#' a\n#'\n#' b"` and `"##' a"` give `"markdown"`;
    `"x <- 1"`, `""`, `"\n\n"`, `"#' a\nx"` and `"#| fig-width: 8"` give
    `"code"`; `cell_kind("#' a", setup = TRUE)` gives `"code"`.
39. `split_mixed()`: `M`'s code gives
    `c("#' ## The model\n#' A line.", "fit <- lm(mpg ~ wt, cars)")`;
    `"#' a\n\nx\n#' b"` gives `c("#' a", "x", "#' b")`;
    `"# note\n#' a"` gives `c("# note", "#' a")`.
40. `inline_spans()`:
    ``"#' The average is `r round(mean(x), 1)` mpg, across `r nrow(d)` cars."``
    gives lines `c(1, 1)` and exprs `c("round(mean(x), 1)", "nrow(d)")`;
    `` "#' `rx` and `r`" `` gives none; an `` `r x` `` on a code line gives
    none; a span on line 3 has `line = 3`.
41. `parse_notebook()` of `files/format-1/canonical.R`: its `[markdown]`
    cell has code starting `"#' "` and kind `"markdown"`.
    `format_notebook()` writes it without `[markdown]`, and parsing the
    result gives the same `cells`. A new-layout file round-trips byte for
    byte. A `[markdown]` cell with an unprefixed line `"Plain"` reads as
    `"#' Plain"`.
42. `notebook_graph(code_of(cells))`: `T` has `A` upstream and comes after
    it in `order`; a text cell without inline values keeps its place
    beside its neighbours (the existing `compute_order` fixture,
    unchanged); `M` has a `mixed_text` error; a setup cell with `#'` lines
    has none.
43. `reduce_apply()`: `insert` of `"#' Hi"` gives kind `"markdown"` and
    `folded`. `set_code` of a code cell that has a result to `"#' Hi"`
    gives kind `"markdown"` and `folded`, drops the result, emits
    `remove_cell`, and marks its readers stale. `set_code` back to
    `"x <- 1"` gives kind `"code"`. `set_code` of a disabled cell to
    `"#' Hi"` clears `disabled`.
44. Autorun: after `A` runs, `T` is queued; its `run` message has
    `role = "text"` and `code = "x / 2"`. Edit and run `A`: `T` is queued
    again. In lazy mode, `T` goes stale and is not queued.
45. `reduce_run()` with the id of a text cell without inline values queues
    nothing and lists it in `skipped`.
46. `reduce_wk_done()` for `E` with
    `error = list(message = "object 'carz' not found", span = 1L)` gives a
    run error with `line = 1L` and `call = "`r max(carz$wt)`"`.
47. Worker: `run_cell()` with `role = "text"` and
    `code = "1/3\nnrow(mtcars)\ninvisible(1)\nc(1.5, 2)\nletters[1:3]"`
    gives `output$values`
    `c("0.3333333", "32", "", "1.5, 2", "a, b, c")`; when knitr is
    installed, each equals `knitr:::.inline.hook()` of the same value.
    `code = "y <- 1\nstop('no')"` gives status `"error"`, `error$span`
    `2L`, and `y` exists in `globalenv()`.
48. `project_output()` of `T`: not run, text/html containing
    `<code>r x / 2</code>`; with an ok result `values = "10.5"`,
    `Half of it is <span class="ember-inline">10.5</span>.`; with a value
    `"<b>"`, `&lt;b&gt;`; with `code_differs`, no span; with a run error,
    the stacktrace mime; with commonmark mocked unavailable, text/plain
    `"Half of it is 10.5."`. `check_wire()` passes on each.
49. `project_cell_result()` of `M`: `ember$split == 2L`; of `T`:
    `ember$split` is `NULL`.
50. `pluto_edits()`: undo-delete of a text cell gives
    `insert_cell(i, "#' # Hi", id = <id>)`, which inserts a text cell.
    ui-2-tests.md 2 and 3 are rewritten without the `kind` argument.
51. `function_docs()` on `FN`'s code gives one row: name `clean`,
    signature `clean(df)`, doc `"Drop rows with a missing value.\n\nReturns a data frame."`.
    The same with `clean = \(df) ...` and with `clean = function(df)`.
    A blank line between the comments and the function gives no doc; a
    `#|` line above it is not part of the doc; `clean <- memoise(f)` and a
    function defined inside `local()` give no row; code that doesn't parse
    gives none.
52. `notebook_definition_doc(state, "clean")` for `FN`: the HTML has
    `<code>clean(df)</code>`, the doc as a paragraph, "Defined in a cell",
    a link with `data-ember-cell="FN"`, and the code inside a closed
    `<details>`. A name defined without a doc gives the signature (for a
    function) or nothing, then the folded code. A `<script>` in a doc
    comment is removed.

**Request handling**

53. `ember_split_cell` `{cell_id: "M", code: <M's code>}`: the notebook
    then has `M` with the text and a new code cell right after it, and the
    saved file has no mixed cell. With an out-of-date `code`, or on `T`,
    nothing changes.
54. `update_notebook` setting `A`'s code to `"#' # Title"`, then
    `run_multiple_cells`: the next projection has `kind = "markdown"`,
    `code_folded = TRUE`, and an output with `<h1>Title</h1>`.
55. `docs` with query `clean` on `text.R` (no worker running) replies with
    the HTML of test 52.

**End to end**

56. Open `text.R` and run it: `T`'s output reads "Half of it is 10.5." and
    `span.ember-inline` has the text "10.5".
57. Set `A` to `x <- 42` and run only `A`: `T` changes to "21" without
    being run.
58. `E`'s output has "object 'carz' not found"; no other cell shows an
    error.
59. `M` shows the mixed error and a "Split into 2 cells" button. After
    clicking it there are two cells: the first is rendered as text, the
    second is code that has not run.
60. markdown.test.mjs: the edited code becomes
    `"#' # Changed\n#'\n#' New text."`. A new case types `#' Hello` into a
    new cell, runs it, and finds "Hello" rendered and the cell folded.
61. Help for a notebook function: put the cursor on `clean` in a new cell;
    the Help tab shows `clean(df)`, "Drop rows with a missing value.",
    and "Go to it", which scrolls `FN` into view.

## Piece 3: Figures and Variables data

**Unit**

62. `cell_figure_size()`: no `#|` lines gives 7.5 x 5 and no problems;
    `"#| fig-width: 8\n#| fig-height: 4\nplot(1)"` gives 8 x 4;
    `fig.width: 6` works; a `#| fig-width: 3` after a code line is
    ignored; `"\n\n#| fig-width: 6"` counts; `#| fig-width: wide` and
    `#| fig-width: 0` give 7.5 and one problem each naming the line;
    `#| echo: false` alone gives the default with no problem.
63. `run_message()` carries `fig` from the cell's current code.
64. Worker: `run_cell()` of `plot(1:10)` with no `fig` gives a PNG whose
    header says 1440 x 960 and `size = list(1440, 960, 192)`; with
    `fig = list(width = 8, height = 4)`, 1536 x 768; with
    `fig = list(width = 30, height = 30)`, 5760 x 5760 at res 192 (under
    the 6000 px cap; the cap matters on a redraw asked at a high `res`
    instead, render_plot()'s own test); a `problems` entry appears as a
    console warning item.
65. Worker: `render_plot(list(cell, res = 288))` after the 8 x 4 run gives
    2304 x 1152 at 288; with `width`/`height` given it uses those pixels
    (replaces ui-2-tests.md 27's size expectation).
66. `reduce_render()` with NULL width and height sends `render {cell, res}`
    without those fields.
67. `project_cell_result()` of an 8 x 4 plot result: `ember$figure` is
    `list(width = 8, height = 4)`; a text output has none; `check_wire()`
    passes.
68. Worker `summarise_globals()`: `cars <- mtcars[1:21, 1:3]` gives
    `data.frame`, `shape`, "21 rows × 3 columns"; `cutoff <- 4` gives
    `numeric`, `value`, `4`; `labels <- rownames(mtcars)` starts
    `"Mazda RX4" "Mazda RX4 Wag"` and ends with "…", at most 80
    characters; `fit <- lm(mpg ~ wt, mtcars)` gives `lm`, `str`,
    `List of 12`; `stat <- function(d, i) 1` gives `function(d, i)`;
    `NULL`, `character(0)`, a `Sys.Date()` and a 3 x 4 matrix give their
    rows from the plan's table; an active binding is not called (a counter
    binding stays at 0) and gives type `active binding`, kind `none`; a
    class whose `str` method errors gives kind `none`; a class whose
    `format` method sleeps 1 s leaves the names after it with kind `none`.
69. Worker: `run_cell()` of `a <- 1; .b <- 2` reports `globals` for both
    names; a rerun that drops `a` no longer reports it.
70. Engine: after `wk_done` with `globals`, `cell_view()`'s `variables` is
    sorted and leaves out `.b`; `notebook_snapshot()` has `name` and
    `type` only; after `wk_exited` no cell has variables. A `done` with
    `status = "error"` and `globals`, and an ok `done` the server turns
    into a `global_setting` error, store no variables. An off cell
    (piece 1) has none in its view.
71. Projection: `ember$variables` matches the view; a run of cell A
    changes only `cell_results/A` patches (`fb_diff`); `export_html()`'s
    decoded state has no `variables` under any cell.

**Request handling**

72. `ember_render_plot {cell_id, res: 1000}` on a plot cell (real worker)
    re-renders at res 384 at the cell's figure size; `width`/`height` in
    the body are ignored; a text-output cell does nothing (replaces
    ui-2-tests.md 37).
73. Editing a cell's `#|` line through `update_notebook` marks it
    `code_differs`; running it gives the new `ember$figure`.

**End to end**

74. `PLT` shows an `<img>` 720 CSS px wide at a 1280 px viewport; after
    `setViewportSize({width: 600})`, no `ember_render_plot` request reaches
    the server within 3 s and `naturalWidth` is unchanged; the image fits
    its column (replaces ui-2-tests.md 41).
75. `FIG`'s image is 480 x 384 CSS px.
76. Two browser contexts, `deviceScaleFactor` 1 and 3, on `rich.R`: the 3x
    tab sends one `ember_render_plot` for `PLT` with res 288; over the next
    10 s the server log shows no other render request for `PLT` (replaces
    ui-2-tests.md 42).
77. Running `A` (`x <- 1`) puts `{name: "x", type: "numeric", value: "1",
    kind: "value"}` in
    `window.editor_state.notebook.cell_results[A].ember.variables`.

## Piece 7a: Shared dialogs and menus

**Unit**

78. `test-frontend-files.R`: `alert(` and `confirm(` calls (comments
    stripped, as `external_url_hits()` does) appear only in `Settings.js`,
    `ExportBanner.js` and `Editor.js`'s shortcut list, once each. Test 153
    tightens this to none.

**End to end**

79. Delete several (`basic.R`): select A and B (through
    `window.editor_state_set`, as Endeavor does), press Backspace. An
    in-page dialog "Delete 2 cells?" appears with Delete and Cancel and
    focus on Delete; Tab stays inside it; Esc closes it, keeps both cells,
    and returns focus to where it was. Delete removes both. No native
    dialog.

## Piece 4: Notebooks and packages from the browser

**Unit**

80. `install_failures()` on each captured output gives the expected
    `package`/`kind`/`detail` rows; output with no failure gives 0 rows.
81. `reduce_install_done()` with `failures` for `rlang` (lock: broom,
    rlang; index: broom needs rlang): `packages_view()` rows are broom
    `"failed"` and rlang `"failed"`; `library$failures` has rlang with
    `needed_by = "broom"`; problems has one row with `package = "rlang"`.
    With no index loaded, `needed_by` is empty and broom is
    `"not_installed"`.
82. `project_ember()`: `library$log` is set only when failed;
    `check_wire()` passes; a second flush with the same state gives no
    patch under `ember/packages`.
83. `ev_preview_date(d, apply = TRUE)` then `ev_index_fetched` with no
    worker: the header's snapshot is `d`, the lock is the fresh resolution,
    `proposal` is NULL, and the target is reset (`"unknown"` or
    `"checking"`).
84. The same with `worker$loaded` containing a package whose version
    changes: the proposal stays `"ready"` with `restart` naming it, and the
    header is unchanged. `ev_set_date(d)` then applies it;
    `ev_cancel_preview` clears it.
85. `reduce_move()` with the worker `"ready"`: the effects are `move_file`
    and `send` with `type = "chdir"` and `from`/`to` the two folders. With
    the worker `"off"`, only `move_file`. A worker that was `"starting"`:
    `wk_hello` afterwards sends `chdir`.
86. `notebook_target_path()`: "fit" in an existing folder gives
    `<folder>/fit.R`; "fit.r" keeps its extension; "a/b", "..", "" and a
    missing or non-writable folder are refused with the page's wording;
    "~/x" expands.
87. `remember_notebook()` and `forget_notebook()` on a temp
    `R_USER_DATA_DIR`: newest first, no duplicates, at most 50, `replaces`
    drops the old path; a missing file reads as `character()`; an
    unwritable folder gives no error.
88. `complete_path()` on a temp folder with `a.R`, `ab/`, `.hidden`:
    "<dir>/a" gives `a.R` and `ab/`, with `start` at the byte after the
    last "/"; `dirs_only` gives only `ab/`; ".h" shows `.hidden`.
89. Worker: `chdir` from the current wd moves `getwd()` and
    `settings_start$wd`. After a cell's `setwd(tempdir())`, `chdir` leaves
    `getwd()` alone but still updates the baseline.

**Request handling**

90. The empty-log regression (real session): open a notebook with the
    failing-installer option and run it. `notebook_snapshot()$packages`
    has library `"failed"`, a `message` containing `compilation failed for
    package`, a `log` longer than 10 lines, and
    `failures$package == "brokenpkg"`.
91. Real session: run a cell, `move_notebook()` to a new temp folder, run
    `getwd()`: the new folder (normalised). The worker's pid is unchanged.
92. `ember_new_notebook {name: "fit", folder}` replies with a `url`
    starting `edit?id=`; the file exists with Ember's header; the server
    hosts it as owned; the recent file lists it. The same name again
    replies with an `error` naming the file.
93. `ember_start_page` lists the hosted notebook under `open` with
    `process = "preview"`, and a remembered, closed path under `recent`; a
    remembered path whose file is gone is left out.
94. `ember_move_notebook` to an existing name replies with an `error`, and
    the file has not moved. A valid move replies with `path`, and the next
    flush patches `path` and `shortpath`.
95. `ember_update_packages` dispatches the preview with `apply = TRUE`
    (the toy repos at tests/testthat/fixtures/repos, dates 2026-09-01 to
    2026-09-30, the clock set to 2026-09-30): after the index is fetched,
    the file's snapshot is 2026-09-30.
96. `GET /?secret=` serves start.html with the cookie; without the secret
    it gives 403.

**End to end**

97. Start page: New notebook, type "first", Create. The page goes to the
    editor, the file exists in the server's start folder, and going back
    lists it under My notebooks. Close it with the round button: it moves
    to the recent rows. Forget removes it, and the file is still on disk.
98. Rename from the header: click the name, set Name "renamed", Save. The
    title becomes "renamed.R — Ember", the old file is gone, the cells keep
    their outputs (R wasn't restarted), and a cell running
    `basename(getwd())` gives the new folder's name.
99. `failing.R`: run; the Packages tab shows "brokenpkg couldn't install"
    with the build sentence; "Show the error" shows text containing
    `compilation failed`.
100. Open a file: type the fixture's folder, choose the file from the
     completion list, Open: the editor shows it.

## Piece 5: Identity and layout

**Unit**

101. `project_ember()`: on `basic.R` in safe preview, `on_cell_change` is
     `"autorun"`, `r_version` and `worker_started_at` are `NULL`. After
     `reduce_wk_hello()` with `info = list(r_version = "4.6.1")` at time
     1000, they are `"4.6.1"` and `1000`. After `ev_set_mode("lazy")`,
     `on_cell_change` is `"lazy"`. `check_wire()` passes on each.
102. A worker restart (`ev_restart`, then the worker going to `starting`)
     makes `worker_started_at` `NULL` until the next hello.
103. `test-frontend-files.R`: `fonts.css` exists; every `url()` in it names
     a file under `fonts/`; the three families each have a `@font-face`;
     `fonts/OFL-figtree.txt`, `OFL-source-serif-4.txt` and
     `OFL-ibm-plex-mono.txt` exist and contain "SIL Open Font License";
     `inst/COPYRIGHTS` names Figtree, Source Serif 4 and IBM Plex Mono.
104. The frontend stays under 3 MB (ui-2-tests.md 14, unchanged; it now
     includes the fonts).
105. Every name in `pluto-css-variables.txt` and
     `endeavor-css-variables.txt` is defined in both `themes/light.css` and
     `themes/dark.css` (ui-2-tests.md 6, plus the Endeavor list). Neither
     file contains `prefers-color-scheme`; dark.css's only selector is
     `:root[data-theme="dark"]`.
106. Contrast: each `--ember-*` hex value is read from both theme files and
     checked with the WCAG formula: at least 4.5 : 1 for text, muted, faint
     and accent on page, panel and code; for the five syntax tokens on
     code; for red on red-bg and amber on amber-bg; for on-accent on
     accent.
107. No frontend file sets `font-family: monospace` or
     `font-family: system-ui` outside the token definitions.

**Request handling**

108. `ember_set_mode {mode: "lazy"}` on `basic.R`: the flushed projection
     has `ember/on_cell_change = "lazy"`, and the file on disk has
     `# on_cell_change = "lazy"` in its header. `{mode: "autorun"}`
     removes the line.
109. `ember_set_mode {mode: "sometimes"}` and `{mode: 1}`: refused, no
     flush, file unchanged. On a read-only notebook (a fixture saved by a
     newer Ember): refused.

**End to end** (new `layout.test.mjs` unless noted)

110. At 1440 x 900: `main`'s content box starts at x = 120 ± 1 and is
     720 + 31 px wide; `header#pluto-nav` is 52 px high and stays at y = 0
     after scrolling 1000 px.
111. At 1440: click the Variables icon. `#helpbox-wrapper` is 400 px wide
     at the right edge, `main`'s bounding box is unchanged, and the two
     don't overlap. Click Variables again: the panel closes. Click Help,
     then Packages: one panel, the tab changes.
112. At 1100 x 800: `main` starts at x = 64 ± 1; opening the panel leaves
     `main` where it was and the panel (380 px, with a box-shadow) covers
     its right part.
113. At 390 x 844: the panel opens as a sheet at the bottom; clicking the
     scrim closes it; the header shows one "Side panel" icon; no
     horizontal scroll (`scrollWidth <= clientWidth`).
114. At 640 x 800 (1280 px at 200% zoom): no horizontal scroll with the
     panel closed or open.
115. Dark mode: with `emulateMedia({ colorScheme: "dark" })` and no
     setting, `<html data-theme="dark">` and the body background is
     `rgb(21, 25, 23)`. With `localStorage.pluto_setting_THEME =
     "\"light\""` and a reload, it is light (`rgb(245, 246, 243)`) despite
     the dark media. Changing the media to light while the setting is
     `"system"` switches without a reload.
116. Fonts (added to `offline.test.mjs`, which blocks every non-local
     request): after load, `document.fonts.check("16px Figtree")`,
     `"16px 'Source Serif 4'"` and `"13px 'IBM Plex Mono'"` are true, and
     no request left localhost.
117. R status and Status tab (`lazy.R`): the header reads "R ready" after
     the first run; clicking it opens Status with "Mark them stale…"
     checked; choosing "Rerun the cells…" and reloading keeps it checked,
     and the file has no `on_cell_change` line. Status shows a Version
     starting "4." and a Started time.
118. Busy (`basic.R`'s `LOOP`, 8 s): while it runs, the header reads
     "Running 1 of 1 cells" (or the plural rule's form) and shows Stop;
     clicking Stop ends the run and the status returns to "R ready".
119. "Run N not run" (replaces ui-2-tests.md 72): after a restart, the
     header button reads "Run 4 not run"; clicking it runs them and the
     button disappears. There is no `#ember-not-run-bar`.
120. Safe preview (replaces safe-preview.test.mjs's `.safe-preview button`
     and `.safe-preview-info` steps): `#ember-safe-preview` shows the
     sentence and "Run this notebook"; no cell contains "not executed";
     clicking the button runs the notebook and the banner goes.
121. Variables tab: after running `basic.R`, the rows are in alphabetical
     order and are collected from every cell's `ember.variables`; clicking
     `x` scrolls its defining cell into view and selects it; typing in
     Filter hides other rows; in `lazy.R`, a stale cell's rows are faint.
122. Help tab: put the cursor on `lm` in a cell; Help shows "Fitting Linear
     Models"; search `mean`; Back shows `lm` again, Forward `mean`.
123. Endeavor's hooks (added to `ember-look.test.mjs`): the existing check
     (ui-2-tests.md 12: every name in both variable lists resolves on
     `:root`) still passes. New: `#helpbox-wrapper`, `pluto-helpbox >
     header` and `#live-docs-search` exist once the panel has opened at
     Help; `window.dispatchEvent(new CustomEvent("open_bottom_right_panel",
     {detail: "docs"}))` opens Help and `{detail: null}` closes the panel;
     `header#pluto-nav` and `main pluto-notebook` exist.
124. `ember-look.test.mjs`'s logo steps (`img#logo-big`, `img#logo-small`)
     become: the header's `h1 svg` has a computed fill of
     `rgb(232, 89, 12)` in light and `rgb(240, 112, 50)` in dark.
125. Existing tests that read removed elements change in the same commit:
     `#ember-status` and `#ember-status-restart` (status-views: memory is
     now in Status and the Variables footer; restart is Status's button);
     the footer's `form#feedback` check (ember-look: assert no `footer`
     element).
126. The ⋯ menu by keyboard: focus ⋯, Enter opens it with focus on
     "Keyboard shortcuts"; ↓ moves to "Settings"; Esc closes it and focus
     is back on ⋯.

## Piece 6: Cells and outputs

**Unit**

127. Worker `run_cell()` on `TOP`: `error$call` is NULL, `error$line` 2,
     `error$deep` FALSE, `frames` empty.
128. Worker, a notebook function calling `lm()` with a bad `data`:
     `error$call` starts with `model.frame.default(`, `deep` TRUE, `line`
     1; `frames[[1]]$cell` is the running cell; some frame has
     `package == "stats"`; `length(frames) == length(traceback)`.
129. Worker: a function defined in cell `F` and called from cell `ERR`:
     the frame for `f(bad)` has `cell == "F"`.
130. Worker console: `warning("careful")` inside
     `g <- function() warning(...)` gives an item with `kind = "warning"`
     and `call = "g()"`. A `message()` item has no `call` field.
131. Worker `build_table(data.frame(a = c(1, NA), b = c("x", NA)), ...)`:
     `na` is `list(integer(), c(1L, 2L))`. A list column never appears in
     `na`.
132. Worker `display_tree_node(list(long = 1:100), ...)`: the item's value
     is `type = "vector"`, 10 values, `type_sum = "int"`, `length = 100`. A
     length-1 value and a factor stay `type = "text"`.
133. `project_error()` on an error with frames: `ember_call`, `ember_line`
     and `ember_deep` are set; frames are innermost first, with
     `source_package` and `ember_cell` from `frames`. `msg`, `plain_error`
     and every Pluto frame field equal today's output for the same message
     (compared with the new fields removed).
134. `project_table()`: `ember_size` is `list(32, 11, 22, 3)` for mtcars at
     the default limits; `ember_na` has one array per row; `ember_dims` is
     gone. `check_wire()` passes on the projection of every engine
     fixture.
135. `project_tree()`: `ember_length` is set; a vector leaf has MIME
     `application/vnd.ember.vector+object`.
136. `project_logs()`: an item with `call` gives `ember$call`; one without
     gives no `ember` field. A growing console still diffs to only the new
     items (the existing prefix test).
137. Contrast (extends test 106): in light and dark, at least 4.5 : 1 for
     the chips' text on their backgrounds, `--ember-red` on
     `--ember-err-bg`, `--ember-warn-text` on `--ember-due-bg`, each
     `--ember-ansi-*` on page and code, faint on `--ember-wash`, and muted
     on `--ember-dis-bg`.
138. `test-frontend-files.R`: `RunArea.js` and `ember-cell-label` are gone
     from the installed frontend; `cells.css` is imported by
     `all-styles.css`.

**Request handling**

139. Run `ERR` through `helper-server.R`: the flushed patch's
     `cell_results[ERR].output.body` has `ember_call` and
     `ember_line = 1`, and `stacktrace[[1]]$source_package` is "stats" or
     "base".

**End to end**

140. Rail (`cells.R`): before running, every rail's computed background is
     `--ember-rail-idle`. Type in `B` without running: `B`'s rail is amber,
     its `.cm-gutters` background is `--ember-due-bg`, and hovering the
     rail shows "Press Shift + Enter to run this cell". Run `ERR`: its rail
     is red. While a `Sys.sleep(2)` cell runs, its `data-rail` is `run` and
     the next queued cell's is `queued`. With `reducedMotion: "reduce"`,
     the running rail has no animation.
141. Run/stop and run time: hovering `A` shows `button.ember-run` named
     "Run cell (Shift + Enter)"; clicking it runs `A`. On a `Sys.sleep(3)`
     cell the same button is named "Stop (Ctrl + Q)", and clicking it
     interrupts: the cell shows the "Interrupted" box. After a run,
     `ember-runtime` matches `/^\d+(\.\d+)? s$|min/`.
142. Cell menu on `A`: the ⋯ button is named "Cell options". Items in
     order: Hide code, Disable cell, Copy output, Move up, Move down,
     Delete cell. Move down moves `A` below `B` in `cell_order`. Hide code
     folds it, and the item then reads Show code. The setup cell's menu has
     no Disable cell.
143. "+": hovering the gap between `A` and `B` shows `button.add_cell`'s
     line and circle, and `B`'s `getBoundingClientRect().top` is unchanged
     before and after the hover. Clicking adds a cell between them.
144. Chips: `NEVER` shows "Not run yet" and no output. In `cells-lazy.R`,
     run all, then edit and run `A`: `B` shows "Stale · x changed", and its
     output has `filter: grayscale(1)`. In safe preview no "Not run yet"
     chip is shown.
145. Errors: `TOP` shows "boom" and "Error · line 2", and no traceback
     button. `ERR` shows "Error in `model.frame.default(…)` · called from
     line 1" and "Show traceback (n calls)" with n the frame count;
     clicking it lists the frames outermost first: the first reads "this
     cell, line 1" at full opacity, a frame labelled "stats" is faint, and
     the `f(bad)` frame says "notebook". `jlerror > header > p` exists.
146. Outputs: `NA` shows "2 rows × 2 columns", types without `<>`, and two
     `td.na`. `rich.R`'s `TBL` shows "Show 22 more rows" and "Show 3 more
     columns"; clicking the first gives 70 body rows. `VEC` shows "list of
     3" open, `sub` collapsed, and `long` as "1 2 3 4 5 6 7 8 9 10 … int,
     100 values". `rich.R`'s `FIT` shows a `pre` with a transparent
     background.
147. Console and colours: `W` shows "Reading" in the muted colour, then a
     warning line with a bold "Warning". The cli or 256-colour line has a
     `span[class*="ansi-"]` and no `style*="rgb("`. After switching to
     dark, the green span's colour is `#86d19f`.
148. Figures (`rich.R`'s `PLT`): the `img` has no border, background or
     filter in light and dark, and its CSS width is at most the column
     width. A cell with `#| fig-width: 4` shows its image 384 px wide.
149. Disabled states (`disabled.R`): disable A. A shows the "Disabled" chip
     and dimmed code and has no run button; B shows "Depends on a disabled
     cell. Go to it", and clicking "Go to it" focuses A; neither shows
     "Not run yet".
150. Text cells (`TXT`): the rendered `h2`'s font family starts with
     "Source Serif 4"; `span.ember-inline` has the tint background, and
     `getSelection().toString()` over the paragraph equals the plain
     sentence; clicking the text opens the editor, clicking a link inside
     it doesn't; in the open editor, End then Enter on a `#'` line gives a
     new line starting `#' `; Shift + Enter closes it.
151. Empty notebook (a new notebook from the start page): the placeholder
     reads "Type R code here", and the three hints show "⌘" when the user
     agent is a Mac. Typing in the cell removes the hints.
152. Endeavor's hooks (extends ui-2-tests.md 12): `pluto-cell >
     pluto-trafficlight`, `pluto-cell > pluto-output`, `pluto-shoulder >
     button.foldcode`, `button.add_cell.before/.after` and `jlerror >
     header` exist; `.errored`, `.queued`, `.running` and `.code_differs`
     are set as before.

Existing tests that change with this piece: ui-2-tests.md 10 (the menu's
items are the new list), 39 (the table's "more" control is a button under
the table), 40 (the tree root starts open), 43 (ANSI classes unchanged,
colours from the theme), 73 ("stale" is a chip, not `ember-cell-label`).
`error.test.mjs` still passes; it only reads `jlerror` text.

## Piece 7: Menus, settings, shortcuts, accessibility, wording

**Unit** (`test-frontend-files.R`, on the installed frontend)

153. No `alert(`, `confirm(` or `prompt(` call in any `.js` file outside
     `imports/` (comments stripped). Replaces test 78.
154. Every key in `lang/english.json` appears as a string literal in some
     source, except keys starting with `t_ember_packages_status_`,
     `t_ember_packages_library_status_` or `t_status_names`, and
     `t_language_direction` and `t_time_format_unit_override`. Every
     literal passed to `t(` or `th(` is a key, ignoring the plural
     suffixes `_zero`, `_one` and `_other`.
155. No string from `retired-wording.txt` appears in english.json's values
     or in any `.js` source. The same check runs on R/server.R for the
     server's three strings.
156. No hard-coded English in `title=`, `aria-label=` or `placeholder=`
     attributes of component templates: `(title|aria-label|placeholder)="[A-Za-z]`
     finds nothing in `components/` or `common/`.
157. Gone: `components/ExportBanner.js`, `common/Binder.js`,
     `components/NotifyWhenDone.js`. No source contains `binder_url`,
     `frontmatter`, `window.present`, `begin ... end`,
     `MOTIVATIONAL_STICKERS` or `CUSTOM_CODE_FONT_STACK`.
158. CSS: the only `outline: none` rules are `pluto-output:focus` and the
     focused CodeMirror editor; a `:focus-visible` rule sets
     `outline: 2px solid`.

**Request handling** (`test-server.R`)

159. `GET /notebookfile?id=nope` returns 404 with "This notebook isn't open
     in Ember." A cross-origin request returns 403 with the new "Ember
     didn't accept…" text. `/open` of a missing file returns 400
     "Couldn't open <path>: <reason>."

**End to end** (`basic.R` unless stated)

160. Names: with the ⋯ menu open, every visible `button`,
     `[role=menuitem]` and `a` has a non-empty accessible name, and where a
     `title` exists `aria-label` equals it. Repeated on Settings and the
     shortcuts sheet.
161. Export menu: clicking `button.toggle_export` gives `[role=menu]` with
     three items. "Download .R file" produces a download named `<file>.R`
     whose first line is `### An Ember notebook ###`. "Download HTML"
     produces the self-contained export (`id="ember-modules"`). Esc closes
     the menu and focus is back on the button. Replaces both scenarios in
     export-menu.test.mjs.
162. Safe preview: before "Run this notebook", the menu shows the amber
     note and "Code only, for now." twice; Download HTML downloads with no
     native dialog.
163. Settings: ⋯ → Settings opens `dialog.psettings` with focus inside, and
     Tab cycles within it. Theme Dark sets `html[data-theme=dark]` and
     changes `--main-bg-color` with no reload (the page's `performance`
     navigation count stays 1). Indent 4 spaces: typing
     `f <- function() {` then Enter in cell A gives a line starting with 4
     spaces; after Reset to defaults the same gives 2. With Tab key: Moves
     focus, Tab in cell A's code moves focus out of `.cm-content`. After a
     reload the Theme is still Dark.
164. Shortcuts: ⋯ → Keyboard shortcuts opens a dialog containing "Run this
     cell" and "Ctrl"; with `navigator.platform` set to "MacIntel" by an
     init script it shows "⌘" and no "Ctrl" in the Running group except
     Stop. Esc closes it and focus is on ⋯. Neither F1 nor Ctrl + ? opens
     it.
165. F1: in cell B (`sum(x)`) with the cursor in `sum`, F1 opens the Help
     tab showing `sum`'s page.
166. Keyboard path: from a fresh load, Tab focuses "Skip to the notebook"
     (visible), and Enter puts focus in the first cell's `.cm-content`. Esc
     leaves the cell focused (`document.activeElement` is the
     `pluto-cell`, with `.selected`). ↓ moves focus and `.selected` to the
     next cell; Enter puts focus in its editor; Esc then Tab focuses that
     cell's run button, named "Run cell (Shift + Enter)". With the panel
     open, Esc inside it closes it and focuses the header icon that opened
     it.
167. Focus ring: after keyboard focus on the Export button, the computed
     outline is 2 px solid in the accent colour with a 2 px offset; after a
     mouse click on it, the outline style is `none`.
168. Cell names and announcement: run B, and the `[role=status]` text
     becomes "Finished: 1 cell"; run ERR, and it becomes "A cell: error".
     ERR's `pluto-cell` `aria-label` ends with ", error"; A's starts with
     "Cell defining x".
169. Long runs: set the threshold to 1 s, run LOOP (8 s), edit LOOP and
     press Shift + Enter. The dialog reads "This reruns 1 cell that took
     about 8 seconds last time."; after 25 s it is still open (no
     auto-accept); Cancel leaves LOOP not run.
170. Reduced motion: with `emulateMedia({ reducedMotion: "reduce" })`,
     while LOOP runs its rail's computed `animation-name` is `none`, and the
     ⋯ menu opens with no transition.
171. Automated checks: `@axe-core/playwright` (a test-only dependency of
     tests/e2e) runs on `basic.R` and `cells.R` after a run, on the start
     page, and with Settings and the shortcuts sheet open, in light and
     dark. It fails on any finding of impact "serious" or "critical".

Every existing e2e scenario also checks that no native dialog appears,
through `newPage()` (tests/e2e/browser.mjs:40). 200% zoom is test 114.
