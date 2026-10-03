# Test-only helpers for the pure core (R/state.R, R/step.R). These build an
# `ember_notebook_file` directly with the constructors from R/notebook.R,
# bypassing `parse_notebook()` so a core test's fixture is exactly the
# state it says and not incidentally shaped by the parser, and build fake
# worker reports.

#' `state` with its clock set to `time`: `step()` stamps `state$clock <-
#' event$at` before dispatching, even for a refused or ignored event, so an
#' "unchanged" comparison after such an event must still account for the
#' clock having moved.
at_clock <- function(state, time) { state$clock <- at(time); state }

#' A fake, deterministic "time". The core only ever compares or subtracts
#' `at` values, so a plain integer counter does the job. Named `at()`, not
#' `t()`, to never collide with base R's `t()` (matrix transpose).
at <- function(n) n

#' One cell for a fake file's `cells` list.
cell <- function(code = "", kind = c("code", "markdown"), folded = FALSE,
                 disabled = FALSE) {
  list(code = code, kind = match.arg(kind), folded = folded, disabled = disabled)
}

#' An `ember_notebook_file` built straight from cells, without going through
#' `parse_notebook()`.
fake_file <- function(cells, setup = names(cells)[1], on_cell_change = "autorun",
                      learned = list(), lock = empty_lock(), extra_blocks = list(),
                      format = 1L, read_only = FALSE) {
  new_notebook_file(
    header = new_header(ember_version = "0.1.0", r_version = "4.3.0",
                        snapshot = "2026-01-01", on_cell_change = on_cell_change),
    cells = cells, setup = setup, run_order = names(cells), learned = learned,
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = lock, extra_blocks = extra_blocks, format = format,
    read_only = read_only, problems = NULL)
}

#' A fresh session state over `cells` (named list from `cell()`), ready to
#' drive with events. `S` is the default setup id unless given.
fake_state <- function(cells, setup = names(cells)[1], on_cell_change = "autorun",
                       learned = list(), options = list(library = NULL), at = 0) {
  file <- fake_file(cells, setup = setup, on_cell_change = on_cell_change, learned = learned)
  new_state(file, path = "nb.R", id = "n1", options = options, at = at)
}

#' A fake `wk_done` report. `created`/`changed`/`removed` are character;
#' `settings` a list of `list(kind, name, before, after)`; `attached` a
#' named list package -> exports; `error` `NULL` or `list(message, traceback)`.
#' `loaded` (step 3): named character, namespace -> version, as the worker's
#' `done` report carries it. `globals` (3b): named list name ->
#' `list(type, value, kind)`, as `summarise_globals()` reports it.
report <- function(status = "ok", output = NULL, console = list(), error = NULL,
                   runtime = 0, created = character(), changed = character(),
                   removed = character(), settings = list(), load_notes = character(),
                   attached = list(), formula_misses = NULL, loaded = character(),
                   globals = list()) {
  list(status = status, output = output, console = console, error = error,
      runtime = runtime, created = created, changed = changed, removed = removed,
      settings = settings, load_notes = load_notes, attached = attached,
      formula_misses = formula_misses, loaded = loaded, globals = globals)
}

#' Fold `step()` over a sequence of events, checking invariants after each
#' one. Returns `list(state, effects, replies, reply)`: `effects` is every
#' effect from every event, in order; `reply` is the last event's reply.
drive <- function(state, ...) {
  events <- list(...)
  effects <- list()
  replies <- list()
  for (ev in events) {
    r <- step(state, ev)
    check_state(r$state)
    state <- r$state
    effects <- c(effects, r$effects)
    replies <- c(replies, list(r$reply))
  }
  list(state = state, effects = effects, replies = replies,
      reply = if (length(replies) > 0) replies[[length(replies)]] else NULL)
}

#' The `msg` of the last `fx_send` effect in a `drive()` result (or a plain
#' effects list).
last_sent <- function(result) {
  effects <- if (!is.null(result$effects)) result$effects else result
  sends <- Filter(function(e) identical(e$type, "send"), effects)
  if (length(sends) == 0) return(NULL)
  sends[[length(sends)]]$msg
}

#' The `token` of the last `fx_send` run message.
last_token <- function(result) {
  m <- last_sent(result)
  if (is.null(m)) NULL else m$token
}

#' Every `fx_send` message's `cell`, in order: the sequence of cells the
#' core asked the worker to run.
sent_cells <- function(result) {
  effects <- if (!is.null(result$effects)) result$effects else result
  sends <- Filter(function(e) identical(e$type, "send") && identical(e$msg$type, "run"), effects)
  vapply(sends, function(e) e$msg$cell, character(1))
}

#' Run `ids`, start and hello the worker, and drain the setup cell's run if
#' it was queued (every first run queues the setup cell as an unfresh
#' ancestor of everything, so it always runs before any other cell). Returns
#' a `drive()` result positioned right after that: the worker is "ready"
#' and whatever `ids` asked for is next in the queue. `at0` is the first
#' timestamp used; later events in the test should use `at0 + 10` or more to
#' leave room.
boot <- function(s, ids, at0 = 1) {
  r <- drive(s, ev_run(ids, at(at0)), wk_started(1, 99, at(at0 + 1)), wk_hello(1, list(), at(at0 + 2)))
  if (!is.null(r$state$worker$running) && identical(r$state$worker$running$cell, s$setup)) {
    r <- drive(r$state, wk_done(1, last_token(r), report(), at(at0 + 3)))
  }
  r
}

#' Op constructors matching the shape `reduce_apply()` expects (ids already
#' resolved, as the API layer would do before dispatching `ev_apply()`).
op_set_code <- function(cell, code, expected = NULL) {
  list(op = "set_code", cell = cell, code = code, expected = expected)
}
op_insert <- function(id, index, code = "", kind = "code") {
  list(op = "insert", id = id, index = index, code = code, kind = kind)
}
op_delete <- function(cell) list(op = "delete", cell = cell)
op_move <- function(cell, index) list(op = "move", cell = cell, index = index)
op_fold <- function(cell, folded = TRUE) list(op = "fold", cell = cell, folded = folded)
op_disable <- function(cell, disabled = TRUE) list(op = "disable", cell = cell, disabled = disabled)

#' Build a chain notebook with `n` dependent code cells after a setup cell,
#' for the performance test: `S`, then `c1` (defines `x1`), `c2` (refs `x1`,
#' defines `x2`), ..., so running the last cell forces the whole chain.
make_chain_cells <- function(n) {
  cells <- list(S = cell(""))
  for (i in seq_len(n)) {
    code <- if (i == 1) sprintf("x%d <- %d", i, i) else sprintf("x%d <- x%d + 1", i, i - 1)
    cells[[sprintf("c%d", i)]] <- cell(code)
  }
  cells
}
