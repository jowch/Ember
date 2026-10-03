# Engine without UI (build step 2)

## Problem

Step 2 turns the step-1 graph into a working engine without a UI. It has four parts: the file format, a base-R worker, a scheduler that lives in a server that must never block, and an R API. That API serves three callers: a person or a test at the console, Endeavor's adapter (loaded into the server process), and the step-4 UI, which will diff a Pluto-shaped state.

The shape is not obvious because many independent inputs change the same small amount of state:

- user edits and run requests
- worker messages (console lines, results, `source()` requests that the worker blocks on)
- the worker process exiting
- an interrupt timer
- sourced files changing on disk

The design adds rules that cut across those inputs:

- safe preview
- autorun versus lazy
- unrun or stale ancestors run first
- dependents of a failed cell run anyway (as Pluto); a failed cell's globals are removed
- restart leaves every cell not run
- deleting a cell removes its globals
- a stale output is always visibly marked

Constraints carried in from earlier work:

- Step 1's `ember_graph` is immutable and rebuilt from inputs, and run-time facts enter only through `graph_learn()`.
- The spike measured that `identical()` makes state diffs cheap only when each state is built by modifying the previous one.
- The worker can use base R only and must not see Ember's code.
- Endeavor needs a `seq`, atomic `apply` with an `expected` check, and change notifications.

## Usage (caller's view)

**At the console, or in a test.** The handle is opaque. You read the notebook through snapshots.

```r
library(ember)
nb <- open_notebook("growth.R")            # safe preview: no R process yet
nb                                         # 6 cells, 6 not run
run_cells(nb, 4, wait = TRUE)              # display index or id; runs ancestors first
snap <- notebook_snapshot(nb)
snap$cells[[4]]$output$text                # "[1] 0.93"
edit_notebook(nb, set_code(2, "deg <- 3")) # staged: nothing runs, the file is saved
run_cells(nb, 2, wait = TRUE)              # autorun: cell 4 reruns too
interrupt_notebook(nb); restart_notebook(nb)
close_notebook(nb)
```

**Endeavor's adapter, answering `apply`, `run` and `snapshot`.** It runs inside the server process, so it never blocks. It subscribes to events instead.

```r
on_apply <- function(nid, ops) {
  nb <- registry[[nid]]
  tryCatch({
    r <- do.call(edit_notebook, c(list(nb), lapply(ops, endeavor_op_to_ember)))
    list(inserted = r$inserted, seq = r$seq)
  }, ember_refused = function(e) list(error = conditionMessage(e)))
}
on_run <- function(nid, cells, wait, timeout) {
  r <- run_cells(registry[[nid]], cells, wait = FALSE)
  if (wait) pending_waits[[nid]] <- list(cells = r$queued, deadline = Sys.time() + timeout)
  list(accepted = r$accepted, skipped = r$skipped)
}
on_notebook_event(nb, function(note) {
  push_notification(nid, note$kind, seq = note$seq, cells = note$cells)
  if (note$kind == "execution_done") resolve_waits(nid)
})
on_snapshot <- function(nid) to_endeavor_snapshot(notebook_snapshot(registry[[nid]]))
on_graph <- function(nid) {
  g <- dependency_graph(registry[[nid]])     # step 1's value; always the current code
  lapply(g$order, function(id) cell_summary(g, id))
}
on_validate <- function(code) read_cell(code)$parse_error   # step 1, no new API
```

**The step-4 UI server, reacting to an edit from the browser.** Pluto's `update_notebook` becomes ops. Its client state is a projection of the session state.

```r
on_update_notebook <- function(client, patches) {
  do.call(edit_notebook, c(list(nb), pluto_patches_to_ops(patches)))  # then reply "👍"
}
on_notebook_event(nb, function(note) {
  s <- notebook_state(nb)
  for (cl in clients) {
    new <- pluto_state(s, previous = cl$last)  # reuses cl$last's parts where s's are identical()
    send_patches(cl, fb_diff(cl$last, new)); cl$last <- new
  }
})
```

**A test of the scheduler, with no process.**

```r
s <- new_state(parse_notebook(text, new_id = ids()), "nb.R", "n1", opts, at = t(0))
r <- drive(s, ev_run("c", t(1)), wk_started(1, 99, t(2)), wk_hello(1, info, t(3)))
expect_equal(last_sent(r)$cell, "a")                    # the unrun ancestor goes first
r <- drive(r$state, wk_done(1, 1L, report(created = "x"), t(4)))
expect_equal(last_sent(r)$cell, "b")
```

## Shape

**Data first.** `ember_state` (state.R) is one immutable list holding everything the server knows about a notebook:

- `cells`: a named list in display order. The names are the order.
- `setup`
- `graph`: derived. Invariant: it equals `notebook_graph()` of the other fields.
- `files`: the sourced files' text, so the graph is built without IO.
- `exports`
- `allowed`
- `worker`: status, generation, running cell and token, interrupt, restart offer. No handles.
- `pending`: an unordered set.
- `results`: one record per cell that ran in this worker.
- `clock`, `seq`, `next_token`

Each derived fact has one source:

- "Queued" is `run_order(graph, pending)` minus the running cell.
- "Code differs" is `result$code != cells[[id]]$code`.
- "Not run" means the cell has no result.
- "Blocked" (can't run at all) is step 1's `blocked_cells()`: a cell with a graph error of its own. A dependent of a failed or graph-broken cell is not blocked; it runs and fails on its own if it needs what the broken cell would have provided.
- "Off" (ui-3, piece 1b: disable cell) is `names(state$graph$off)`: a disabled cell, or a dependent that needs a name only a disabled cell provides. `can_run()` and `reduce_run()` treat it like blocked, but it is the user's own choice, not an error.
- Only `stale` is stored, because it records history (an ancestor ran after this result) that the current code can't reveal.

**One pure transition.** `step(state, event)` returns `list(state, effects, reply)` (step.R). It has three stages:

1. `reduce()` applies the event.
2. `schedule()` moves the worker and queue forward from whatever state resulted: start a worker if allowed and none exists, or send the first runnable cell of the pending set when the worker is ready.
3. `missing_file_reads()` asks for sourced files the graph wants.

No event handler starts a run itself. So a learned definition, an edit during a run, or a crash all reorder or drain the queue through the same code. Time, cell ids and file contents enter only inside events, so the core is deterministic. Effects are data: start or kill the worker, send a message, SIGINT, set a timer, read files, move the file, close.

**Saving and notifying are derived, not emitted.** At the end of each drain the shell compares the file text from `notebook_file_of(state)` with the last text written, and writes only if they differ. It computes `notifications(old, new)` from the two states. No branch in `step()` can forget to save or notify, a burst of worker messages gives one `cell_state`, and opening an Ember-written file never writes it. This is cheap because states share unchanged parts (per the spike).

**Invalidation is one rule.** When a cell starts, the worker removes its old globals. So `schedule()` invalidates, at that moment, its transitive downstream plus every cell reading a name its *previous* run created. When it finishes, `reduce_wk_done()` invalidates again with the post-learning graph. Invalidating marks a cell with a result `stale`, and in autorun also adds it to `pending`. Cells never run stay not run. A cell dropped from the queue (interrupt) is already stale, so the snapshot is right without extra code. This replaces step 1's `affected(old, new)` for the session: what matters is what the worker's globals came from, and `result$defined` records that directly.

**Generations and tokens make worker events idempotent.** Every worker event carries the generation it came from, and run events carry a token. Events for an old generation or token are no-ops. That is what makes kill-then-start, late interrupts and stale timers safe without locks.

**The shell (shell.R) is thin and imperative.** It owns the processx handle, the sockets, a chunked receive buffer (a big output never blocks the server), the `later` poll, timers, file mtimes and listeners. It validates wire messages into events at the boundary (`worker_event()`, which also checks the secret). The protocol types never leave shell.R and worker.R (per boundary-discipline). A drain never re-enters: effects enqueue, and listeners run after the drain, so their API calls get real replies.

**The file (notebook.R).** It is pure `parse_notebook(text, new_id)` and `format_notebook(file, order)`:

- Every choice is canonical, so Ember-written text round-trips byte for byte.
- Every irregularity becomes a repair plus a `problems` row, so any `.R` file opens.
- The setup cell is marked `# %% id=… [setup]`, because cells are written in run order and a position can't be trusted. A file with no marker uses its first code cell.
- A newer `ember_version` opens read-only. An older format goes through text converters and is written in the current format on the next save.

**The worker (inst/worker.R).** It reports facts and never judges. Facts are:

- names created, changed and removed
- setting changes made by the cell's own code, with `loadNamespace` and `library` traced so package loads are excluded
- packages attached, with their exports
- formula columns missing from the data
- the display bundle

The core turns those facts into learned definitions, "Multiple definitions" errors and global-setting errors. Rules stay in the server, testable without a process.

Bookkeeping that only the process can do stays in the worker:

- which globals each cell owns
- the setup cell's settings to restore
- the search-path rebuild, converging on the `order` sent with every run

It is sourced into an environment whose parent is `baseenv()`, so user globals can't shadow it.

**Interface depth.** The public surface has about 20 functions:

- open, new, close, move
- `edit_notebook` plus 5 op constructors
- run, allow, interrupt, restart
- snapshot, graph, state, `render_png`
- `on_notebook_event`, `wait_for`

Behind it sit all scheduling, invalidation, safe preview, worker lifecycle, framing, the save policy, version conversion and notification coalescing. Callers never coordinate two calls to finish one operation. Graph queries reuse step 1's functions rather than adding wrappers.

## Where the direction strains

- **Replies.** API calls need answers (inserted ids, refusals, `skipped`), so `step()` returns a third field. It is honest but not pure Elm.
- **IO the graph needs.** `read_cell()` follows `source()` through a reader. To stay pure, file text lives in the state and arrives by `fx_read_files` → `ev_files_read`. Opening a notebook with sourced files takes two steps inside one drain, so callers never see the gap.
- **A blocking request from the worker.** A computed `source()` makes the worker wait for a reply. That works because the reply is sent within the same drain, and the worker queues anything else it reads while waiting (`deferred`). The pure core can't express "wait". It only answers.
- **Waiting.** `run_cells(wait = TRUE)` and `wait_for()` are shell loops over `later::run_now()`. They are outside the core and unusable inside `later` callbacks, so the adapter must use events.
- **The worker is a second program.** Its globals, settings and search-path logic are impure by nature and get only harness tests. The pure-core benefit covers the server, not the worker.
- **Derived saves cost a comparison per drain.** That is fine while the state is shared, and would be slow if some code rebuilt `cells` from scratch. `check_state()` can't catch that. A test (116) checks that sharing holds.

## Synthesis decision

Three candidates were drafted on three models. A is the base: one immutable
state per notebook, one pure `step(state, event)`, effects as data carried out
by a thin shell, saving and notifications derived from the state before and
after each dispatch.

- From B (a session object with methods, a job queue, one request and reply
  per cell): code normalised where it enters, so the file round-trips byte
  for byte and `expected` comparisons are exact; a file is written only when
  its bytes differ; the first implementation step drives a real worker
  before any session code. B's shape was not taken: every method would have
  to remember to save, notify and drain the queue, and its tests need a
  process. A's pending set, re-ordered on every step, removes B's queue.
- From C (the worker runs a whole plan): nothing structural. C's plan needs
  a second message to extend it when the worker learns a definition, and an
  abort-and-resend round trip when a queued cell is edited; A sends one cell
  at a time and re-reads the pending set after every event, so both cases
  need no code. C's idea of sending the worker a table of which cell owns
  which name is not needed either: a name created at run time becomes a
  learned definition, and the graph raises "Multiple definitions" if another
  cell defines it.
- Changed from A: the open questions below were decided (see Decisions).

### Decisions

- **The cell-change mode is stored in the file**, as a header key
  `on_cell_change = "lazy"`; absent means autorun. `set_cell_change_mode()`
  writes it.
- **An edit never runs anything**, in either mode, as in Pluto (edit, then
  run) and Endeavor (`apply`, then `run`). Running a cell reruns its
  dependents (autorun) or marks them stale (lazy).
- **Dependents of a failed cell run anyway (as Pluto); a failed cell's
  globals are removed.** A dependent that needs what the failed cell would
  have defined fails on its own, naming the failed cell; one that doesn't
  need it runs normally.
- **A disabled cell defines nothing; it and its dependents don't run; their
  variables are removed; enabling makes them stale.** `disable_cell()`
  refuses the setup cell ("empty it instead") and text cells. Turning a
  cell off sends `remove_cell`, as for a delete, and the graph excludes it
  from `find_errors()`'s rules but `parse`, so disabling one of two cells
  defining the same name clears "Multiple definitions".
- **A setting changed outside the setup cell is put back** by the worker
  and the cell shows the "global setting" error, so later cells never run
  under it.
- **Sourced-file hashes are MD5**, computed by the shell from the file
  (`tools::md5sum()` on a path works on every supported R; hashing text in
  memory needs R 4.5). The footer line is `helpers.R md5:<hex>`.
- **Computed `source()` paths are kept for the session only**; the learned
  definitions they produce go into the footer like any other.
- **Formula checks** evaluate the `data` argument only when it is a symbol
  or a `$`/`[[` path.
- **knitr's `knit_print`** is tried only when knitr is installed in the
  notebook's library; the worker loads it the first time a value reaches
  that step.

## Tradeoffs accepted

- We accept storing sourced files' text in the state in exchange for a graph build with no IO, so the core stays pure and the watcher is just another event source.
- We accept recomputing `notifications()` and the file text per drain, guarded by `identical()` short cuts, in exchange for no save or notify calls scattered through handlers.
- We accept that an edit by itself never runs anything, even in autorun. This matches Pluto (update then run) and Endeavor (apply then run). Autorun means "running a cell reruns its dependents", not "editing runs".
- We accept storing `stale` rather than deriving it, because it records history the current graph doesn't hold (a removed edge). Running is the only thing that clears it.
- We accept that a cell whose code broke a rule (changed another cell's global, set an option) is an error even though R ran it fine. The worker reverts a non-setup setting change so later cells don't run under it.
- We accept the `[setup]` marker as a format addition now, at format 1, in exchange for a setup cell that survives moves and inserts.

## Alternatives considered

- **A mutable session object with methods per operation** (R6 or an environment: `nb$run()`, with handlers updating fields in place). It hides about as much behind a similar API, but every handler must remember to save, notify and pump the queue, and tests need a process or mocks. It lost on testability and on the number of places a rule can be missed.
- **Pluto-style run tasks** (a run request becomes a task that loops over its cells, waiting on the worker with promises). This is natural with `later` and promises, but two tasks can interleave over one worker, and an edit during a run needs cancellation logic. The pending set that is re-ordered on every step removes both problems.
- **Notifications and saves as effects emitted by `step()`.** This is more explicit, but every reducer would then need to know which notifications its change implies. Deriving them from the before and after states is one rule.

## Open questions and risks

Follow-ups to act on are in [design-gaps.md](design-gaps.md).

- **Measured:** rebuilding the graph after an edit takes 30 ms at 100
  cells, 64 ms at 500 and 590 ms at 2000, spread across step 1's
  `notebook_graph()` with no single hot spot. Fine for typical notebooks;
  worth optimising before very large ones are common.
- **Measured:** once `later` has run callbacks in a process,
  `socketSelect()` with a positive timeout returns `FALSE` at once even
  when a socket is readable (R 4.6.1, later 1.4.8); a zero timeout still
  works. The shell polls with a zero timeout, so it is unaffected; any
  future blocking wait on a socket in the server process must not rely on
  `socketSelect()`'s timeout.
- **Risk:** a listener that is slow (the UI encoding a large diff) runs on the server thread after every drain. Coalescing helps, but a 2000-cell `cell_state` storm during "Run all" needs measuring.
- **Risk:** `later`'s global loop is shared with anything else the host runs. A host callback that blocks stalls the poll. Should the session use a private loop that the server services?

## Next implementation step

Three parts in parallel, each against the sketch: the file format with its
tests; the worker driven by a harness over a real socket; the pure core
(`step()` and the projections) with `drive()` and fake worker events. Then
the shell and the API, with end-to-end tests. The test list is in
[engine-tests.md](engine-tests.md).
