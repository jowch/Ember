# Tests for increment 1

Three layers. Most cases sit in the first, because the three pure parts
(wire, projection, translation) take values and return values. The second
drives the server's request handling with fake sockets and a real engine.
The third is a real browser against a real server and worker.

## 1. Pure unit tests (testthat, no process, no network)

**`test-protocol.R`**
1. Encoding rules, each checked by decoding what was encoded: a one-element
   `arr("a")` arrives as an array; `emptymap()` as `{}` and `list()` as `[]`;
   a NULL field as nil; raw as bin; integer stays integer.
2. `fb_apply_all(old, fb_diff(old, new))` equals `new` for generated pairs
   (random nested maps and arrays, including NULL values, removed keys,
   arrays that shrink, grow and change).
3. Append-only arrays: a log list grown by two items gives exactly two `add`
   patches at indexes `n` and `n + 1` (0-based); a log whose first item
   changed gives one `replace`.
4. Diff of identical objects is empty, and a 2000-cell projection with one
   changed cell diffs in under 5 ms (timed with the same CI allowance as
   `packages_view()`'s test).
5. `parse_request()` refuses a missing `type`, a non-string `client_id`,
   and a body that is not a map.

**`test-pluto-state.R`** (states built with `new_state()` and `drive()`, as
the engine's tests do)
6. A fresh notebook in safe preview: every field of NotebookData is present,
   `process_status` is "waiting_for_permission", every cell has a
   `cell_results` entry with `queued = FALSE` (a missing entry shows as
   queued in the frontend), `check_wire()` passes.
7. Reuse is invisible: for every engine fixture state `s` and its
   predecessor, `pluto_state(s, pluto_state(prev))$js` equals
   `pluto_state(s, NULL)$js`. This is the test that catches a `cell_key()`
   missing an input.
8. Reuse is real: after one cell finishes running, every patch of
   `fb_diff(p1$js, p2$js)` is under that cell's `cell_results` or a
   top-level scalar.
9. Output mapping, one case per row of the table in `project_output()`:
   plain text with ANSI codes, HTML, PNG (body is raw), SVG, markdown with
   and without commonmark, table and tree fall back to `text`, no output.
10. Errors: a parse error gives `parseerror+object` with one diagnostic on
    the right line; a multiple-definitions error's `msg` starts "Multiple
    definitions for x" and its fixes follow on separate lines; a run error
    with a traceback gives frames innermost first with `file = ""`; an
    interrupted cell gives "Interrupted".
11. Console: stdout, message and warning become log levels
    "LogLevel(-555)", "Info", "Warn" in order; a running cell's console that
    grows gives an `add` patch, not a `replace`.
12. Stale and blocked-by-failure set `depends_on_disabled_cells`; code that
    differs from the last run shows only in `cell_inputs` (the frontend
    derives "code differs" from its local copy).
13. `process_status` for each worker status; `nbpkg` in preview with three
    missing packages, during an install, after one failed; a restart offer
    sets `restart_recommended_msg`.
14. `cell_dependencies` for a three-cell chain and for a `library(dplyr)`
    cell; an edit that changes one cell's references changes only its own
    and its neighbours' entries.

**`test-pluto-edits.R`**, table-driven: each row is the patches a frontend
action produces (copied from immer's output for that action in Editor.js)
and the ops expected.
15. Set code and run: one `set_code` with `expected` = the code in `before`.
16. Add a cell at index 3 (`add_remote_cell_at`): one `insert_cell(3, "", id
    = <client id>)`.
17. Paste three cells, split a cell, undo a delete: inserts at the right
    indexes, client ids kept, the split's original cell deleted.
18. Delete two cells: two `delete_cell`, no moves.
19. Drag one cell from first to last: exactly one `move_cell`.
20. Drag three selected cells: three moves at most, never more than the
    number of cells whose relative order changed.
21. Fold: one `fold_cell`.
22. Move the file (`path` replace): `move_to` set, no ops.
23. Refusals, each with `after` still containing the client's change:
    `show_logs`, `disabled`, `skip_as_script`, notebook `metadata`, a bond.
24. Races: (a) `cell_order` replaced from a view missing cell C that another
    writer inserted: C keeps its place, the client's move still applies;
    (b) a code edit to a cell another writer deleted: refused "that cell was
    deleted", not turned into an insert; (c) `cell_order` naming a deleted
    cell: the id is dropped.
25. `lis()` against brute force on random permutations up to length 8.

## 2. Request handling (testthat, real engine, fake sockets)

A fake socket is an environment with `send(raw)` that decodes and keeps
every message, and a `page()` that applies all received patches to `{}`,
which is what the browser's notebook object would be. A real engine
notebook is opened from a fixture copy in a temporary directory. The server
is `new_server(secret, throttle = 0)`, with no httpuv.

26. connect then `update_notebook {updates: []}`: one "👋" reply with
    `notebook_exists = TRUE`, then a notebook_diff whose single patch is a
    replace at `[]`, carrying the request id. `page()` equals the
    projection.
27. Edit a cell's code: the engine has the new code, the file on disk has
    it, the reply says 👍, and a second client gets the patch.
28. Refused edit (stale `expected`: change the cell through `edit_notebook()`
    between the page's sync and its edit): reply 👎 with the engine's
    reason; after applying all patches, `page()` shows the engine's code,
    not the client's.
29. `run_multiple_cells`: "run_feedback" with `disabled_cells = {}` comes
    first; the cell shows `queued`, then `running`, then its output (after
    `wait_for()`); a 2000-line `cat()` loop arrives as add patches.
30. `run_multiple_cells {cells: []}` runs nothing; for a new empty cell in
    safe preview it doesn't start the worker (`notebook_snapshot()$process`
    stays "preview").
31. `interrupt_all` during `Sys.sleep(10)` stops the cell; `restart_process`
    in preview runs all, otherwise restarts and leaves cells not run.
32. `reset_shared_state`: the next message is a full replace with
    `from_reset = TRUE`.
33. Two notebooks on one server: a client connected to one never receives
    the other's diffs.
34. A socket whose `send` errors is dropped; the others keep receiving.
35. Unknown type and malformed bytes: logged, nothing sent, no error.
36. Every Julia-only request type gets the answer the table in server.R
    gives (so no frontend promise waits forever).

**`test-server-http.R`**: `http_app(server)$call(req)` with hand-built
Rook requests: 403 without the secret on `/edit`, `/open`,
`/notebookfile`, `/notebookexport`; the cookie is set on `/edit`; `/open`
302s to the edit URL and reuses an open notebook; `/notebookfile` returns
the file text; a websocket opened without the secret is closed.

**`test-start-server.R`** (skipped on CRAN): `start_server()` returns a
handle whose `url` answers `/` with 200, and `stop()` ends the child and
its worker.

## 3. End to end (Playwright, real Chromium, real server and worker)

`tests/e2e/` (in `.Rbuildignore`, so R CMD check never sees it): a
`package.json` with Playwright, `server.mjs` (copies a fixture notebook to a
temp folder, starts `Rscript -e "ember::serve(paths = ..., port = 0)"` with
a fixed secret, reads the "listening" line, kills it after), and one
`node --test` file per scenario. Each scenario asserts on Pluto's DOM hooks,
the same ones Endeavor relies on (`pluto-cell[id]`, `.running`, `.queued`,
`.code_differs`, `pluto-output`, `jlerror`), and on the file on disk where
it matters.

37. Open: the page loads with every cell, safe preview banner shown, no
    console errors, R code highlighted (a `.cm-keyword` span on `function`).
38. Run a cell: `[1] 55` appears; its ancestors ran first.
39. Edit and Shift+Enter: new output; the file on disk has the new code.
40. Interrupt: a `Sys.sleep(30)` cell loses `.running` within 2 s of
    clicking stop.
41. Add a cell below, type, run; delete it; reload: the order and code
    survive the reload and match the file.
42. Plot: a `plot(1:10)` cell shows an `<img>` with a blob URL.
43. Error: `stop("boom")` shows the error element with "boom".
44. Two tabs: an edit run in one appears in the other.
45. No secret: `/edit` without it gives 403.

**Running locally**: `R CMD INSTALL .` then `npm --prefix tests/e2e ci`
then `npm --prefix tests/e2e test`. Chromium comes from `npx playwright
install chromium`, or from `EMBER_CHROMIUM` (the path browser3.mjs uses on
this Mac).

**In CI**: a job `e2e` on ubuntu-latest and macos-latest:
`r-lib/actions/setup-r` and `setup-r-dependencies`, `R CMD INSTALL .`,
`actions/setup-node` (22), `npm ci` in `tests/e2e`, `npx playwright install
--with-deps chromium`, `npm test`, and the server logs and a screenshot per
failed scenario uploaded as artifacts. Windows waits for its interrupt
spike. The page loads its modules from jsdelivr and esm.sh until the
offline bundle exists, so a CDN outage fails this job; a retry of one is
allowed for page load only.
