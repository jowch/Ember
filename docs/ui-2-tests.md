# Tests for increment 2

The same three layers as increment 1 (docs/ui-tests.md): pure unit tests
(testthat, no process), request handling (testthat, real engine, fake
sockets from `helper-server.R`), and end to end (Playwright in
`tests/e2e/`, real server and worker). Worker tests source `inst/worker.R`
into an environment and call its functions directly, as
`test-worker.R` does. Numbers continue across pieces so the design
(docs/ui-2.md) can cite them.

New fixtures:

- `tests/e2e/fixtures/rich.R`: cells `DF` (`df <- mtcars`), `TBL` (`df`),
  `FIT` (`lm(mpg ~ wt, df)`), `LST` (`list(a = 1, b = list(c = "x"), long =
  as.list(1:100))`), `PLT` (`plot(1:10)`), `ANSI`
  (`cat("\033[31mred\033[39m\n"); structure("x", class = "ansi_demo")` with
  a `print.ansi_demo` in the setup cell that prints coloured text), `PARSE`
  (`x <- (`), `MD` (markdown, `folded` in the footer, with a fenced R block).
- `tests/e2e/fixtures/lazy.R`: `on_cell_change = "lazy"` in the header;
  `A` (`x <- 1`), `B` (`x + 1`).
- `tests/e2e/fixtures/widget.R`: `library(htmltools)`, `library(jquerylib)`;
  two cells each returning
  `attachDependencies(tags$div(id = "w1", "?"), jquery_core())` plus a
  `tags$script` that writes `typeof jQuery` into the div. Its packages
  install for real, so scenarios using it run only when
  `EMBER_E2E_INSTALLS=1` (set in CI on ubuntu-latest).
- `tests/testthat/fixtures/pluto-css-variables.txt`: every CSS variable name
  defined in Pluto v1.0.3's `themes/light.css`, one per line (taken from the
  vendoring commit).
- `tests/testthat/fixtures/endeavor-css-variables.txt`: the variables
  Endeavor's page code reads (the list in docs/ui-2.md is from
  `endeavor/frontend/src/*.ts`).

## Piece 1: Ember's look

**Unit**

1. `project_cell_input()` gives `kind = "markdown"` for a markdown cell and
   `"code"` for a code cell; `check_wire()` passes on the projection of
   every engine fixture.
2. `pluto_edits()`: the patches of "undo delete" for a markdown cell (the
   whole `cell_inputs` entry re-added, with `kind = "markdown"`) give
   `insert_cell(i, code, kind = "markdown", id = <client id>)`; a new cell
   added by the page (no `kind`) gives `kind = "code"`.
3. `edit_notebook(nb, insert_cell(2, "# Hi", kind = "markdown"))`: the
   snapshot shows the cell `folded`, and the written file lists it as
   `<id> folded`. A code cell inserted the same way is not folded.
4. A file whose footer lists a markdown cell without `folded` opens with it
   unfolded (fold state is the file's).
5. `test-frontend-files.R`: no file under `system.file("frontend", package =
   "ember")` contains `EMBER`, `plutojl.org`, `fonsp.com`,
   `stats.plutojl`, `openai.com` or `firebasejs`; `common/EmberFlags.js`,
   `common/Feedback.js`, `components/FixWithAIButton.js` and
   `components/welcome/` don't exist.
6. Every name in `pluto-css-variables.txt` is defined in both
   `themes/light.css` and `themes/dark.css` of the installed frontend.
7. `inst/COPYRIGHTS` exists and names "Pluto.jl"; DESCRIPTION's
   `Authors@R` has a person with role `"cph"` whose name mentions Pluto.jl.

**End to end**

8. Open `basic.R`: the header's logo is `img/logo.svg` with `alt="Ember"`;
   `document.title` is `basic.R — Ember`; `document.body.innerText`
   contains neither "Pluto" nor "Julia"; no console errors.
9. Open, run B, then type `x <- (` in a new cell and run it: no request
   goes to `plutojl.org`, `fonsp.com`, `openai.com`, `gstatic.com` or
   `api.github.com` (Playwright's request log), and no "Fix with AI"
   button appears next to the parse error.
10. The cell menu on B lists "Delete cell" and "Copy output" and none of
    the classes `ask_ai`, `disable_cell`, `skip_as_script`, `hide_logs`,
    `show_logs`; there is no `form#feedback` on the page.
11. Markdown (`rich.R`): `MD` shows rendered text and is folded; unfolding
    it shows an editor whose syntax tree's top node is markdown's
    (`Document`, read through `.cm-content`'s `cmView`), with R tokens
    inside the fenced block; a code cell's top node is the R grammar's. The
    increment-1 markdown scenario still passes.
12. Endeavor's hooks: `pluto-cell[id]` for every cell, `pluto-input
    .cm-content`, `button.add_cell.before` and `.after` in each cell,
    `header`, `main pluto-notebook`, `pluto-output`, and
    `window.editor_state.notebook.cell_order` exist; every name in
    `endeavor-css-variables.txt` resolves to a non-empty value on `:root`,
    with `prefers-color-scheme` emulated as light and as dark.

## Piece 2: Offline bundle

**Unit**

13. `test-frontend-files.R`: no `.js`, `.css` or `.html` file in the
    installed frontend has an `http://` or `https://` URL in an `import`,
    `from`, `src=`, `href=` or `url()` position, except the allowlist
    (MathJax, while it stays on the CDN). Planting a CDN import in a copy of
    one file makes the check fail (the test runs the checker on a temp
    copy).
14. The installed `frontend` folder is under 3 MB;
    `imports/vendor/THIRD-PARTY.txt` exists; every package it names also
    appears in `inst/COPYRIGHTS`.
15. `export_html(state)` has no `src="./`, `href="./` or `url(./` left, and
    no external URL other than MathJax; its `#ember-modules` holds every
    `.js` and `.json` file under the frontend, and no embedded module has a
    relative import specifier left. No frontend `.js` file uses
    `import.meta` or an `import(` whose argument isn't a string literal
    (Environment.js's data-URL import is the one allowed exception). A
    notebook with an htmlwidget output exports with its dep files as data:
    URLs.
15a. `serve()` answers a hashed file under `imports/vendor/` with
    `Cache-Control: public, max-age=31536000, immutable`, and `editor.js`
    and `edit?...` with `Cache-Control: no-cache`. Every
    `imports/vendor/*-<hash>.js` named by a shim exists, and no other hashed
    file does.

**Build (CI job `frontend-build`, not testthat)**

16. `npm ci && npm run build` in `frontend-build/` leaves `git diff
    --exit-code inst/frontend/imports inst/frontend/img/icons` clean, and a
    second build changes nothing.
17. `scripts/check-imports.mjs` passes on the real frontend, and fails when
    run against a frontend file that imports a name the bundle doesn't
    export.

**End to end**

18. Offline: Playwright aborts every request whose host isn't 127.0.0.1.
    Open `rich.R`, run all, edit and rerun a cell, open the settings and the
    export menu: no console errors, no failed requests other than aborted
    MathJax, code is highlighted as R, and the run button's icon loads
    (its `--icon` image request returns 200).
19. Each vendored library does its job offline: the page renders (Preact,
    htm); an edit round-trips (immer, msgpack); the coloured output in
    `ANSI` has a `span.ansi-red-fg` (ansi_up); the export dialog opens
    (dialog-polyfill); the fenced R block in `MD` has `.hljs-keyword` spans
    (highlight.js).
20. Export: fetch `/notebookexport?id=…` after running `rich.R`, save it to
    a temp file, and open it as `file://` with every network request
    aborted (MathJax aside): every cell shows, code cells have R
    highlighting, `B`'s output shows, the table in `TBL` shows, and the DT
    widget renders rows. The same with `&offline_bundle=true`.
21. Cache: load the page, reload it; the second load makes no request for
    any `imports/vendor/*-<hash>.js` file (served from the browser cache).

## Piece 3: Rich outputs

**Worker (unit)**

21. `display_value()`: an `lm` fit and a `t.test()` result give kind
    `"text"` with their `print()` text ("Coefficients", "t = "); `list(a =
    1)` gives `"tree"`; `mtcars` gives `"table"`.
22. `display_table(mtcars, ...)`: 8 names, types all `"<dbl>"`, `nrow` 32,
    `ncol` 11, 10 rows, `row_labels[1]` `"Mazda RX4"`, `more_rows` 22,
    `more_cols` 3. A data frame with a column whose `format()` method
    errors shows `"<error>"` in that column and the others intact. A 0-row
    data frame has names and no rows; a 0-column one has neither.
23. `display_tree()`: a list nested 5 deep shows one-line text at depth 4; a
    100-item list shows 20 items and `more = 80`; unnamed items have empty
    keys; leaves read `"1"` for `1` and `" int [1:10] 1 2 3 4 5 6 7 8 9 10"`
    for `1:10`.
24. Paging: after a table display, a `more` message with path `""`, dim 1
    gives 70 rows; dim 2 gives all 11 columns; for a tree, path `"3"` dim 1
    shows 80 items of that sublist. Each reply is a `rendered` message
    carrying the run's token. After the cell reruns, the limits start over.
25. `display_html()` with an `htmlDependency(src = c(file = <temp dir>),
    script = "a.js", stylesheet = "a.css")` gives one dep with `dir` that
    temp dir (absolute), `script` `"a.js"`, `stylesheet` `"a.css"`; two
    versions of one name give only the newer. Skipped without htmltools.
26. `render_plot()` with `width = 1400, height = 933, res = 192` returns a
    PNG whose header says 1400 × 933, and `size = list(1400, 933, 192)`.
27. Colours: at boot `getOption("cli.num_colors")` is 256 and is part of
    `settings_start`, so a cell that doesn't touch it reports no
    global-setting change, and a non-setup cell that sets it is a global
    setting error. `text_form()` of a value printing 5000 coloured
    characters never ends in a partial escape sequence.

**Engine and projection (unit)**

28. `project_table()` of the mtcars display: `schema$names` and
    `schema$types` end in `"more"`; 10 row entries then `"more"`; each
    row's cell list ends in `"more"`; each cell is `arr(text,
    "text/plain")`; `ember_dims` is `"32 × 11"`; `check_wire()` passes.
29. `project_tree()` of a nested display: elements are `arr(key, arr(body,
    mime))`, a nested node has mime `application/vnd.pluto.tree+object`,
    `"more"` is last when items are hidden, `objectid` is the node's path.
30. `reduce_show_more()` sends `more` when the worker is ready or busy and
    the output is a table or tree; nothing for a text output or with the
    worker off.
31. `reduce_wk_rendered()` replaces a table, tree or PNG output when the
    token matches, drops a reply whose token is from an older run, and sets
    `rendered_at`. The projection's `last_run_timestamp` becomes
    `rendered_at`, and every patch of `fb_diff()` between the two
    projections is under that cell's `cell_results`.
32. `project_output()` for HTML with dependencies: `<link>` and `<script>`
    tags in dependency order with `/deps/<name>-<version>/` paths; an
    href-only dependency uses its href; the `staticRender()` script is
    appended only when one dependency is named `htmlwidgets`; HTML without
    dependencies is unchanged.
33. `notebook_snapshot()` has no ANSI escapes in output `text` or console
    items; `notebook_state()` still has them.

**Request handling and server**

34. `register_deps()`: a folder inside the active library path is
    registered once across two notes; a folder outside it, or a path with
    `..`, is refused and logged; a symlink inside the library pointing
    outside it is accepted; `drop_hub()` removes only that notebook's keys,
    and a key two notebooks use stays until both are gone.
35. `reshow_cell {cell_id, objectid: "", dim: 1}` on a `mtcars` cell (real
    worker): after `wait_for()`, `page()` shows 70 table rows.
36. `ember_render_plot` clamps width, height and res; for a plot cell the
    page's image bytes change and `last_run_timestamp` grows; for a text
    cell nothing happens.
37. With a real httpuv server (skipped on CRAN): after registration,
    `GET /deps/x-1.0/x.js` returns the file without the secret; an
    unregistered `/deps/y-1/` path is 404.

**End to end**

38. Table and print (`rich.R`): `TBL` shows `table.pluto-table` with 10 body
    rows, a "more" row and a `<dbl>` types row; clicking "more" shows all
    32 rows; `FIT` shows text containing "Coefficients", not a tree.
39. Tree: `LST` shows a collapsed `pluto-tree`; clicking expands it to show
    `a`, `b`, `long`; the "more" in `long` loads more items.
40. Plot (ui-tests.md 42, not yet built): `PLT` shows an `<img>`; after
    `setViewportSize()` to half the width, the image's `naturalWidth`
    changes to the container width × `devicePixelRatio` (±10%) within 5 s.
41. Two tabs of different widths on `rich.R` (also covers ui-tests.md 44:
    an edit run in one tab appears in the other): over 10 s after both
    load, the server log shows at most one render request per tab, not an
    alternating series.
42. Colours: `ANSI`'s log and output contain `span.ansi-red-fg` and no
    visible `\x1b`.
43. Widgets (`widget.R`, `EMBER_E2E_INSTALLS=1`): after running both cells,
    both divs read `function`; `document.head` has exactly one `<script>`
    whose `src` starts with `/deps/jquery-`.

## Piece 4: Editor services

**Worker (unit)**

44. `complete_line()`: `"me"` includes `mean`; with `mtcars` defined,
    `"mtcars$m"` includes `mtcars$mpg`; `"library(sta"` includes `stats`;
    `"lm(fo"` includes `formula = ` with kind `"argument"`; a global
    `my_var` is `notebook = TRUE`; an active binding in `globalenv()` is
    not evaluated (its counter doesn't move).
45. `help` for `mean`: `found`, HTML contains "Arithmetic Mean" and no
    `<html>` or `<head>`; for `no_such_topic`: not found; for a topic in two
    attached packages: `matches` lists both.
46. `signature`: `lm` gives text starting `lm(formula, data`; `pi` gives
    `NULL`.
47. `handle_next()` answers `complete`, `help` and `signature` with the
    request's `id`, and these messages are deferred, not lost, while a
    `source` reply is awaited.

**Shell (unit, real worker)**

48. `worker_query()` with an idle worker calls back with the reply; with a
    cell running (`Sys.sleep(3)`) it calls back with `NULL` at once; in safe
    preview it calls back with `NULL` and starts no worker. A reply that
    arrives after the timeout is dropped and the worker is not killed. A
    worker exit calls every pending callback with `NULL`.

**Pure (unit)**

49. `completion_context()`: `"x <- dplyr::fil"` gives namespace `dplyr`,
    token `fil`, start at byte 12; `"é <- me"` counts `é` as 2 bytes; for a
    multi-line `query_full` only the last line is the line.
50. `fallback_completions()` on a state where one cell defines `fil_x` and
    another attaches a package whose exports include `filter`: prefix `fil`
    gives `fil_x` first, then `filter`, then base names (`file.path`);
    `"dplyr::"` gives that package's exports from the state; more than 500
    matches sets `too_long`.
51. `completion_reply()`: each result is a six-element array of the types
    the page reads (CellInput.js:700-708), `"keyword_argument"` for
    arguments, `"path"` for files; `start`/`stop` are byte offsets.
52. `project_dependencies()`: a definition no cell reads is in its cell's
    `downstream_cells_map` with an empty array.
53. `rewrite_help_links()`: `../../stats/help/sd` becomes `@ref stats::sd`;
    other links are unchanged.
54. `span_offsets()`: a tab before the name, a two-byte character and an
    astral character (two UTF-16 units) each give the right offsets.
    `ember_spans` for `y <- x + 1` is defs `[["y", 0, 1]]`, refs `[["x", 5,
    6]]`; rows from a sourced file and rows with `col` NA are left out;
    the spans change exactly when the code does.
55. `signature_fallback("lm")` gives the stats signature;
    `signature_fallback("my_fun")` gives `NULL`.

**Request handling**

56. `complete` in safe preview: the reply (from the fallback) is sent
    within the same `handle_message()` call and the process stays
    `"preview"`. With an idle worker and `df <- mtcars` run, `complete`
    with `query_full = "df$"` replies with `df$mpg` after `wait_for()`.
57. `docs`: in preview, for `mean`, the "Help pages need R running" reply;
    for a notebook-defined `f`, the defining cell's code; with a worker,
    the help page with rewritten links.
58. `ember_signature` with a worker and without one.

**End to end**

59. Completion: typing `me` then Ctrl+Space in a new cell shows a list
    containing `mean`; Enter inserts it. After running `DF`, typing `df$`
    shows `mpg`. While `LOOP` (basic.R) runs, typing `su` shows `sum`
    within 1 s.
60. Help: with the cursor inside `mean(`, the Help tab shows "Arithmetic
    Mean"; clicking a link inside it loads that page in the panel; an
    example block has `.hljs-keyword` spans.
61. Signature: with the cursor after `lm(`, a tooltip containing
    `formula` appears within 1 s.
62. Go-to-definition: Ctrl/Cmd-click on `x` in B focuses cell A; typing
    in B removes the marks until B is run again. No module
    `scopestate_statefield.js` is loaded.

## Piece 5: Status views

**Unit**

63. `project_ember()` in safe preview: process `"preview"`, `not_run` 0,
    `worker_memory` `NULL`, `plan$install` equal to `packages_view()`'s.
    After running only A in basic.R: `not_run` counts B, ERR, LOOP (3);
    the blank setup cell and `MD` are not counted; after `run_cells(nb,
    NULL)` it is 0.
64. Per-cell `ember`: in lazy mode, after A reruns, B has `stale = TRUE`;
    after `edit_notebook()` changes B outside the page, B has
    `code_changed = TRUE`; a cell below a failed one has `blocked_by` that
    cell's id. `depends_on_disabled_cells` is `TRUE` only for the blocked
    cell.
65. A change of `worker_usage` alone gives patches only under
    `ember/worker_memory`. A usage from an older worker generation is
    ignored.
66. `ember$packages$rows` mirrors `packages_view()$packages`; an `NA`
    version is `NULL` on the wire; `check_wire()` passes.
67. `reduce_worker_usage()` stores the value; `notifications()` returns a
    `worker_usage` note and no `cell_state` note; `notebook_snapshot()`
    has `worker_memory`.
68. Memory sampling with a fake process whose `get_memory_info()` returns
    100, 105, 130 MB: an event for 100 and 130 only; an error from
    `get_memory_info()` dispatches nothing.

**Request handling**

69. `ember_run_all` queues the code cells that are not run (and what they
    need), then flushes; a cell already run with its code unchanged is not
    rerun (its `last_run` is unchanged).

**End to end**

70. After the first run, the header shows `R · <n> MB` with n > 0; in safe
    preview it shows nothing.
71. Run B, then restart R from the header: the bar reads "4 cells not run"
    (A, B, ERR, LOOP); "Run all" makes it disappear once they finish
    (ERR's error counts as run).
72. `lazy.R`: run all, edit A to `x <- 2` and run it: B shows the "stale"
    label and dimmed output; running B removes the label.
73. Packages tab in safe preview on a notebook with `library(htmltools)`:
    one row per locked package with status "missing", and the preview
    banner says it will install that many packages.
74. Endeavor's fields survive: `window.editor_state.notebook.nbpkg`,
    `status_tree` and `process_status` are present and filled as in
    increment 1.
