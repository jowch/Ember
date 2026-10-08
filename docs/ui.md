# UI server, increment 1: candidate A (the Pluto state is a pure projection)

## Problem

Step 4 puts Pluto's frontend (v1.0.3, barely modified) in front of the
engine. The frontend keeps one notebook object in sync with the server
through Firebasey patches, and changes it in two ways: the server sends
patches when anything changes, and the page sends its own patches
(`update_notebook`) for edits, which it has already applied locally. Pluto's
server keeps a mutable `Notebook` struct, rebuilds the whole object with
`notebook_to_js()` after each change, diffs it against a copy kept per
client, and applies client patches directly to its struct.

Ember is shaped differently, and these constraints decide the design:

- The engine already owns all notebook state, as one immutable
  `ember_state` per notebook, changed only by `step()`. The UI must not
  become a second copy that can disagree with it (brief, scope 2).
- Edits must go through `edit_notebook()`, which is atomic and can refuse
  (the `expected` check, read-only files). Endeavor's agent
  edits the same notebook through the same call.
- Diffs are cheap only when each new object is made from the previous one,
  so unchanged parts are the same R objects (spike: 0.95 ms per changed
  cell at 2000 cells; 2.2 ms with no sharing). Rebuilding the frontend
  object from scratch each time, as `notebook_to_js()` does, loses that.
- The encoding rules from the spike: arrays always lists, empty objects
  named, null via `list(NULL)`, one numeric type per field.
- One server hosts several notebooks, never blocks, and must answer every
  request type the editor sends, including ones Ember can't serve yet,
  because some frontend code awaits replies.

## Usage (caller's view)

**At the console.** One call; the server runs in a child process.

```r
library(ember)
srv <- start_server("growth.R")     # opens the browser on the notebook
srv
#> <ember_server> http://127.0.0.1:52341/?secret=Xq3...
srv$open("other.R")                 # a second notebook, same server
srv$stop()
```

**Endeavor's host, starting the blocking server in its own R process.**
The adapter opens notebooks with the R API and hands them to the server;
the browser and the agent then edit the same `ember_notebook`.

```r
library(ember)
serve(port = 0L, secret = Sys.getenv("ENDEAVOR_EMBER_SECRET"),
      on_ready = function(server) {
        adapter_start(on_open = function(path) {
          nb <- open_notebook(path)
          url <- host_notebook(server, nb)       # edit URL with the secret
          register(nb, url)
          url
        })
      })
# never returns until stop_server(server) is called from a callback
```

**The browser.** Nothing new for the page: Pluto's flow, served by R.

```
GET  /edit?id=<nb>&secret=<s>        editor.html, cookie set
WS   /?secret=<s>                    connect -> "👋"
     update_notebook {updates: []}   -> notebook_diff: replace [] with the projection
     (user edits cell, Shift+Enter)
     update_notebook {updates: [replace cell_inputs/<id>/code]}
                                     -> edit_notebook(set_code(id, code, expected = old))
                                     -> notebook_diff {patches: [], response: 👍}
     run_multiple_cells {cells: [id]} -> run_feedback; run_cells(nb, id)
                                     -> notebook_diff queued, running, output, ...
```

**A protocol test.** Real engine, fake socket, no httpuv.

```r
nb <- open_notebook(local_fixture("chain.R"))     # a -> b -> c, safe preview
server <- new_server(secret = "s", throttle = 0)
host_notebook(server, nb)
ws <- fake_socket()
id <- notebook_state(nb)$id
handle_message(server, ws, wire("connect", notebook_id = id))
handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))
b <- names(notebook_state(nb)$cells)[2]
handle_message(server, ws, wire("update_notebook", notebook_id = id,
  updates = list(patch("replace", list("cell_inputs", b, "code"), "y <- x * 2"))))
expect_equal(notebook_snapshot(nb)$cells[[2]]$code, "y <- x * 2")
expect_equal(ws$last()$message$response$update_went_well, "👍")
expect_equal(ws$page()$cell_inputs[[b]]$code, "y <- x * 2")   # patches applied to {}
```

**A projection test.** Pure: states in, objects out.

```r
p1 <- pluto_state(s1)
p2 <- pluto_state(s2, previous = p1)                 # s2: cell b finished
expect_equal(p2$js, pluto_state(s2)$js)              # reuse changes no values
touched <- vapply(fb_diff(p1$js, p2$js), function(p) p$path[[2]], "")   # every patch is under cell_results/<id>/...
expect_equal(unique(touched), b)
```

## Shape

Four files, each owning one piece of knowledge.

| file | owns | pure |
|---|---|---|
| `protocol.R` | the wire: msgpack, `fb_diff`/`fb_apply`, request parsing, the encoding convention | yes |
| `pluto-state.R` | what the frontend object looks like, from engine state | yes |
| `pluto-edits.R` | what a client's patches mean as engine ops | yes |
| `server.R` | httpuv, sockets, clients, hubs, request table, HTTP routes, starting | no |

Plus three small engine changes (`engine-changes.R`).

**Data.** The server holds two kinds of mutable record, and nothing else
about notebooks:

- a **hub** per hosted notebook: the `ember_notebook` and the last
  projection (`ember_pluto_state`);
- a **client** per browser tab: its socket, its notebook id, and `sent`, the
  frontend object as that tab has it.

`ember_pluto_state` is `list(js, state, keys, graph)`: the frontend object,
the engine state it came from, a per-cell key of the engine parts each
cell's entries were built from, and the graph its dependencies came from.

**One rule for everything a page sees.** `flush_clients(server, hub, req,
response)` computes `pluto_state(notebook_state(nb), hub$proj)`, then for
each client sends `fb_diff(client$sent, js)` and sets `client$sent <- js`.
It is idempotent: with no engine change and no request, it sends nothing.
So the server calls it freely: from the engine listener (throttled to one
per 30 ms per notebook during bursts) and at the end of every request that
needs an answer. No handler decides what changed, which is the same move the
engine made with `notifications(old, new)`.

**The projection is pure and incremental.** `pluto_state(state, previous)`:

1. returns `previous` when `state` is the same object (extra flushes are
   free);
2. computes the notebook-wide facts once (`view_context()`: queued, blocked,
   failed blockers (replaced in increment 3, piece 1), errors by cell),
   shared with `snapshot_of()` so the rules live in one place;
3. per cell, builds a key from the engine's own shared objects
   (`cells[[id]]`, `results[[id]]`, the running console, a few flags); if it
   is identical to the previous key, the previous entries are kept as they
   are, otherwise the cell's view is built and projected;
4. passes every new part through `reuse(new, old)`, which keeps the old
   object when the values are equal.

So consecutive projections share memory the way consecutive engine states
do, and `fb_diff` meets pointer-equal subtrees. The mapping decisions (MIME
table, errors, logs, process status, `nbpkg`, `status_tree`, which increment 3
removed) each sit in one
function with its table in the doc comment.

**Edits are compared, not interpreted.** `pluto_edits(before, patches)`
applies the client's patches to its copy, then diffs `before` against
`after` and reads the result: removed ids -> `delete_cell`, added ids ->
`insert_cell` with the client's id, changed `code` -> `set_code` with
`expected` = the code in `before`, `code_folded` -> `fold_cell`, a new
`cell_order` -> the fewest moves (cells on a longest increasing subsequence
stay put), `path` -> `move_notebook`. All ops go to one `edit_notebook()`
call, so a request is atomic. Anything else (cell metadata, notebook
metadata, bonds) is refused with 👎.

**Refusal costs no code.** The client's copy is set to `after` whatever the
engine says, because the browser already shows `after`. If the engine
refuses, its state doesn't change, and the next flush's diff for that
client, `fb_diff(after, projection)`, is exactly the reversal. Pluto's
frontend already rolls back from that diff. There is no undo path anywhere.

**Interface depth.** Public surface: `serve()`, `start_server()` (a handle
with `url`, `open`, `stop`), `host_notebook()`, `stop_server()`. Behind it:
the whole protocol, the projection, edit translation, per-client sync,
throttling, auth, the child process. The pure parts' entry points
(`pluto_state`, `pluto_edits`, `fb_diff`) are internal but tested directly.
Wire types never leave `protocol.R` and `server.R` (per boundary-discipline);
the projection and translation see decoded R lists only.

**What it deliberately does not do.** It keeps no UI-side notebook state, so
nothing needs to be kept in step. It never edits `js` except to record a
client's own patches in that client's copy. It never runs anything in
response to an edit (the engine's rule: edit, then run).

## Where the direction strains

Pushed as far as it goes, the pure projection holds for everything the
engine owns. These are the places it strains, and what each costs:

1. **The client names new cells.** The page picks a cell's id, shows the
   cell, and then asks to run that id. A projection can only show ids the
   engine has, so `insert_cell()` must accept the caller's id (an engine
   change). Small, and it doesn't weaken the engine: it already refuses a
   reused id.
2. **Fields with no engine source.** `show_logs`, `disabled`,
   `skip_as_script`, notebook `metadata`, `bonds`. The projection emits
   constants, and a client that changes one gets 👎 and the reversal. That's
   honest, but the menu items must be hidden, or the user clicks and nothing
   happens. Bonds are the large one: when interactive inputs come, they need
   engine state (a bond value per name) before this design can show them.
3. **Optimistic edits racing an engine change.** A client's patches are
   applied to `sent`, the last thing the server sent it, but the client
   edited the version it had seen, which can be one flush older. Cases:
   - *Code.* `expected` is the code in `sent`. If another writer changed the
     cell and the server already sent that change, `expected` matches the
     engine and the client's older edit wins silently. The window is one
     message on loopback (milliseconds), and code is sent only on run, not
     per keystroke. If the change hadn't been sent yet (inside the 30 ms
     throttle window), `expected` is stale and the edit is refused, which is
     the safe outcome. The frontend doesn't say which counter it had seen,
     so this can't be closed without a frontend change.
   - *Order.* The page replaces the whole `cell_order` array. If it was
     built before another writer's insert arrived, it lacks that cell. The
     translation treats order as intent, not as the full truth: a cell that
     exists but is missing from the new order keeps its place next to its
     old neighbour. Pluto would orphan it.
   - *A deleted cell.* A code edit to a cell another writer just deleted
     would come out of before/after comparison as a new cell holding only
     `code`. Patches are therefore checked against `before` first, and this
     one is refused. Comparing before and after can't tell "re-add" from
     "edit of something gone", so this check is a rule on the raw patches.
4. **Code normalisation.** The engine strips trailing blank lines and
   `\r\n`. The projection then sends the normalised code back, and the page
   replaces its editor text with it (CellInput applies remote code when it
   differs). The user sees a trailing newline vanish after running. That's
   acceptable, and it is the engine's rule shown truthfully.
5. **Console streaming.** A running cell's console grows on every poll. Its
   key changes each time, so the cell is re-projected per flush, and logs
   would be resent whole. `fb_diff` treats a list that only grew as appends
   (Pluto's AppendonlyMarker), and the throttle caps flushes at about 33 per
   second per notebook.
6. **Cost per flush.** Every flush walks all cells to compare keys (pointer
   comparisons, about a microsecond per cell) and diffs per client. At 2000
   cells during "Run all" that is a few ms per flush and at most 33 flushes
   a second: under 10% of a core, to be measured (TESTS.md 4).
7. **Julia-shaped fields.** `nbpkg` and `status_tree` (removed in
   increment 3) are filled from `packages_view()`, and the "restart recommended" banner carries the
   interrupt's restart offer. That is a mapping by meaning onto Pluto's
   names. It is documented in one place and replaced by Ember's own views in
   increment 2.

## Synthesis decision

Two candidates were drafted on two models. A is the base: the page talks
Pluto's own protocol, the server derives Pluto's notebook object from the
engine's state with a pure function, and the page's edits (Pluto's
`update_notebook` patches) are translated into `edit_notebook()` ops by
comparing that tab's copy before and after.

B kept the server-to-page diffs but replaced the page's edit path with
explicit messages that map one to one onto Ember's API. It removes the
patch-to-op translation, but rewrites ten functions in `Editor.js` for good,
gives up Pluto's optimistic local edits and page-chosen cell ids, and needs a
new message and R verb for every future feature that writes state (bonds in
step 5 first). Endeavor's injected script also relies on the page behaving
as Pluto's does. A keeps the frontend's protocol and divergence small.

Taken from B: a non-blocking server object, with `serve()` as the blocking
loop around it and an `on_ready` callback for hosts; `start_server()` reads
the URL from a line the child prints; the secret is checked on every route
that reaches R and on the websocket, not on static files; Pluto's ANSI text
output and its error-message strings ("Multiple definitions for …",
"Cyclic references among …") are kept so their rendering works unchanged.

Both found that the R grammar can't be loaded beside Pluto's CodeMirror
bundle: the bundle doesn't export the Lezer pieces a grammar needs, and a
second copy of `@lezer/common` breaks highlighting. The bundle is rebuilt
with the R grammar inside, committed, and checked by CI.

### Decisions

- **"Run notebook code" in safe preview** (`restart_process`) allows
  execution and runs every cell, as the button says.
- **Markdown cells are editable**: refusing `set_code` on them was a bug in
  the engine, fixed with this step.
- **The page names new cells**: `insert_cell()` takes an optional `id`.
- **Exports highlight as Julia** until the offline bundle (increment 2).
- **Pluto's usage reporting** (`stats.plutojl.org`) is switched off.
- **The websocket never accepts the `ember_secret` cookie, only `?secret=`
  in its own URL**, and every route that reaches R (including the
  websocket) also checks `Origin`/`Host` against the server's own
  `127.0.0.1:<port>`/`localhost:<port>`. The cookie, once set, is attached
  by the browser to *every* request to this host regardless of which page's
  script sent it and regardless of port (cookies ignore port, RFC 6265);
  accepting it on the websocket let any other page on the machine connect
  and run code. Plain navigations (`/edit`, `/notebookfile`,
  `/notebookexport`) still accept the cookie, since those can only be
  initiated by the page itself, not by a cross-origin script. The cookie is
  named per port (`ember_secret_<port>`) so two Ember servers on
  127.0.0.1 don't overwrite each other's.

## Tradeoffs accepted

- We accept a full key comparison over all cells per flush in exchange for
  no change tracking anywhere: the projection can't miss a change that the
  engine made.
- We accept that unsupported client edits are reverted with 👎, rather than
  stored on the side, in exchange for one writer. Hiding their menu items is
  part of increment 1.
- We accept `client$sent` as the base for `expected`, knowing it can be one
  message newer than what the user saw, because the frontend gives nothing
  better. Pluto has the same race without any check.
- We accept throttled flushes (30 ms) in exchange for bounded work during
  bursts. Request replies are never delayed: each request flushes itself.
- We accept that exports load Pluto v1.0.3 from jsdelivr (code highlighted
  as Julia) until increment 2's offline bundle exists.
- We accept that markdown cells' output is rendered on the server with
  commonmark only when it is installed, and shown as text otherwise.

## Alternatives considered

- **A mutable Pluto object kept next to the engine and patched by the
  listener** (Pluto's structure, ported): the listener reads
  `cell_state`/`topology_changed` ids and updates those entries in place.
  It is closer to Pluto's code, but each notification kind needs its own
  update code. A missed case shows a stale page, and there are then two
  copies of the notebook to keep in step. It exposes the same small public
  surface but hides less, because correctness depends on every
  notification being complete. It lost on single source of truth.
- **Rebuild the whole object per flush with no reuse**
  (`notebook_to_js()` literally). This is simpler, but every diff walks
  every cell by value (spike: 2.2 ms vs 0.95 at 2000 cells, plus building
  2000 cell objects per flush), and it allocates the whole object each time.
  `reuse()` costs little code and keeps the spike's numbers.
- **Interpret client patches path by path** (Pluto's
  `effects_of_changed_state`). This is direct, but immer's patch shapes vary
  (whole cell vs field, array replaced whole), and the same edit can arrive
  in several shapes. Diffing before and after reduces them to one shape.
  Path rules remain only for validation (strain 3).

## Open questions and risks

- Can httpuv reject a websocket handshake with 403 (perhaps through
  `onHeaders`), or only close the socket after accepting it? Closing at once
  is safe, but a 403 matches Pluto.
- `ScopeStateField` and go-to-definition read Julia node names. Do they fail
  quietly on an R tree, or throw? The e2e suite will show which; the
  switch-off assumes they must go.
- Does codemirror-pluto-setup's repository build from source as-is today,
  for the rebuild that adds `r()`? If not, the fallback is a minimal bundle
  of the same CM6 package versions plus the grammar, which then has to cover
  everything the frontend imports from that module (the export list above).
- Log entries have no line number (`line = -1`). Where does Pluto's Logs
  component put them? It may need `line = 1`.
- Risk: the CDN-loaded page makes the e2e job depend on jsdelivr and esm.sh
  until the offline bundle exists.
- Risk: the listener runs on the server thread after every drain. During a
  2000-cell "Run all" the throttle bounds this, but it is unmeasured.

## Deferred (increment 2 and later)

Removals and theme; the offline bundle (and a local `pluto-cdn-root` for
exports); table and tree views; widget dependency static paths (htmlwidgets
render without their JavaScript until then); completion and help from the
worker; bonds and interactive inputs; Ember's own package view, "N cells not
run" with a "Run all" button, and a stale label (today: dimmed only); plot
re-rendering on resize; creating markdown cells from the page; read-only
mode in the page for files from a newer Ember (today: every edit is
refused); a frontend-sent acknowledgement counter to close the edit race.

## Next implementation step

Write `protocol.R` and `pluto-state.R` against the engine's existing
fixtures, together with TESTS.md 1-14 (with `view_context()`/`cell_view()`
split out of `snapshot_of()` first), then drive them through
`handle_message()` with fake sockets before touching httpuv or the browser.

## Summary

1. The engine's `ember_state` is the only notebook state. The Pluto object is `pluto_state(state, previous)`, a pure function.
2. Each projection reuses the previous object's parts wherever the engine's parts are identical, so `fb_diff` stays near 1 ms per changed cell.
3. The server keeps one hub per notebook (the handle and the last projection) and one record per tab (the object last sent to it).
4. `flush_clients()` diffs each tab against a fresh projection. It is idempotent, and it is the only way anything reaches a page.
5. Page edits are applied to that tab's copy, compared before and after, and sent as one atomic `edit_notebook()` call.
6. A refusal needs no undo: the next diff from the tab's copy to the projection is the reversal Pluto's frontend already handles.
7. Four files: wire (`protocol.R`), projection, translation (all pure), and the httpuv shell (`server.R`). Public surface: `serve`, `start_server`, `host_notebook`, `stop_server`.
8. The engine needs three changes: client-chosen insert ids, editable markdown cells, and `snapshot_of()` split into a shared context plus a per-cell view.
9. The frontend gets the R grammar through a rebuilt CodeMirror bundle (not a second Lezer copy) and has its Julia-only features switched off. Everything else loads from CDNs until increment 2.
10. Main risk: optimistic edits race engine changes. Code edits are guarded only by `expected` against the last-sent copy, which can be one message newer than what the user saw. Order edits are merged as intent.
