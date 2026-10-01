# The R API: what a person at the console, a test, Endeavor's adapter and
# the step-4 UI server call. Every function here is a thin wrapper: it turns
# its arguments into one event, hands it to the session's shell
# (`dispatch()` in shell.R), and returns the reply. No logic lives here
# beyond argument checking at the boundary (per boundary-discipline): ids
# given as display indexes become cell ids, new cell ids are generated, and
# the time is stamped.
#
# A notebook handle (`ember_notebook`) is an environment owned by the shell.
# Callers never touch its fields; they read the notebook through
# `notebook_snapshot()`, `dependency_graph()` and `notebook_state()`, all of
# which return immutable values.

# ---- ids and argument checking ------------------------------------------------

#' A fresh UUID-shaped id. Not cryptographic; only needs to be unique
#' within a notebook.
uuid <- function() {
  hex <- function(n) paste(sample(c(0:9, letters[1:6]), n, replace = TRUE), collapse = "")
  paste(hex(8), hex(4), paste0("4", hex(3)),
        paste0(sample(c("8", "9", "a", "b"), 1), hex(3)), hex(12), sep = "-")
}

#' A cell id or a 1-based display index -> the cell's id, against `nb`'s
#' current cells. This is where a caller's numeric index is resolved,
#' before the event reaches the pure core (which only ever sees ids).
resolve_cell_id <- function(nb, cell) {
  ids <- names(nb$state$cells)
  if (is.numeric(cell)) {
    idx <- as.integer(cell)
    if (length(idx) != 1 || is.na(idx) || idx < 1 || idx > length(ids)) {
      stop(sprintf("ember: no cell at index %s", format(cell)))
    }
    return(ids[idx])
  }
  if (is.character(cell) && length(cell) == 1 && cell %in% ids) return(cell)
  stop(sprintf("ember: unknown cell %s", format(cell)))
}

#' Read a whole file as UTF-8 text, without the line-splitting/rejoining
#' `readLines()` would do (which can lose information about the file's
#' final newline).
read_file_utf8 <- function(path) {
  raw <- readBin(path, "raw", n = file.info(path)$size)
  text <- rawToChar(raw)
  Encoding(text) <- "UTF-8"
  text
}

# ---- Opening and closing ------------------------------------------------------

#' Open a notebook file in safe preview.
#'
#' Reads and parses the file, builds the graph, and returns a handle. No
#' worker starts and nothing runs: execution is allowed by the first
#' `run_cells()` or by `allow_execution()`. A file saved by a newer Ember
#' opens read-only (`notebook_snapshot(nb)$read_only`); a file from an older
#' Ember opens normally and is converted when it is next saved.
#'
#' The worker always starts from the notebook's own package library (its
#' lock, resolved and installed as needed): there is no separate `library`
#' argument to hand it a different one.
#'
#' @param path Path to an existing `.R` file. A file without Ember's header
#'   opens as a notebook too (see `parse_notebook()`).
#' @param repos `ember_repos()`: where indexes and packages come from.
#' @param cache `cache_dir()`: where libraries, indexes and renv's cache
#'   live.
#' @return An `ember_notebook`.
#' @export
open_notebook <- function(path, repos = ember_repos(), cache = cache_dir()) {
  text <- read_file_utf8(path)
  file <- parse_notebook(text, new_id = uuid)
  state <- new_state(file, path = path, id = uuid(),
                     options = list(repos = repos, cache = cache, r = r_info()),
                     at = Sys.time())
  nb <- session_start(state)
  dispatch(nb, ev_open(at = Sys.time()))
  nb
}

#' Create a new notebook file and open it.
#'
#' Writes a file with the current header (ember_version, r_version, today's
#' snapshot date), one empty setup cell and one empty code cell, then opens
#' it as `open_notebook()` does. Refuses to overwrite an existing file.
#' @export
new_notebook <- function(path, repos = ember_repos(), cache = cache_dir()) {
  if (file.exists(path)) stop(sprintf("ember: %s already exists", path))
  setup_id <- uuid()
  code_id <- uuid()
  cells <- list()
  cells[[setup_id]] <- list(code = "", kind = "code", folded = FALSE)
  cells[[code_id]] <- list(code = "", kind = "code", folded = FALSE)
  header <- new_header(ember_version = as.character(utils::packageVersion("ember")),
                       r_version = paste(R.version$major, R.version$minor, sep = "."),
                       snapshot = format(Sys.Date()))
  file <- new_notebook_file(
    header = header, cells = cells, setup = setup_id, run_order = names(cells),
    learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = empty_lock(), extra_blocks = list(), format = ember_format)
  ok <- write_atomic(path, format_notebook(file))
  if (!ok) stop(sprintf("ember: could not write %s", path))
  open_notebook(path, repos = repos, cache = cache)
}

#' Stop the worker, stop watching files, and detach the handle.
#'
#' Returns `TRUE` if the notebook was still in safe preview (Endeavor's
#' `shutdown` reply). The file is already saved; nothing is written here.
#' Calling it twice is harmless.
#' @export
close_notebook <- function(nb) {
  dispatch(nb, ev_shutdown(at = Sys.time()))
}

#' Move the notebook file. The handle stays valid; returns the new path.
#' @export
move_notebook <- function(nb, path) {
  dispatch(nb, ev_move(path, at = Sys.time()))
}

# ---- Editing ------------------------------------------------------------------

#' Apply a batch of edits at once.
#'
#' Edits are staged: they change the code, the graph and the file, never
#' run anything. Either every op applies or none does: if any `set_code`'s
#' `expected` differs from the current code, if an id is unknown, if an op
#' would delete the setup cell, or if code contains a line Ember uses as a
#' cell or footer marker (`# %%`, `# ///`), the whole batch is refused with
#' an `ember_refused` condition naming the op and the reason.
#'
#' @param ... Ops made by `set_code()`, `insert_cell()`, `delete_cell()`,
#'   `move_cell()`, `fold_cell()`, applied in order. Indexes are display
#'   positions after the previous ops.
#' @return Invisibly, `list(inserted = <ids of inserted cells, in op order>,
#'   seq = <the state's seq after the batch>)`.
#' @export
edit_notebook <- function(nb, ...) {
  ops <- list(...)
  resolved <- lapply(ops, function(op) {
    if (identical(op$op, "insert")) {
      op$id <- uuid()
    } else if (!is.null(op$cell)) {
      op$cell <- resolve_cell_id(nb, op$cell)
    }
    op
  })
  reply <- dispatch(nb, ev_apply(resolved, at = Sys.time()))
  if (inherits(reply, "ember_refused")) stop(reply)
  invisible(reply)
}

#' Edit ops. Plain data; `edit_notebook()` applies them.
#'
#' `cell` is a cell id or a display index (1-based). `expected` is the code
#' the caller believes the cell has (Endeavor's check); `NULL` skips it.
#' @export
set_code <- function(cell, code, expected = NULL) {
  structure(list(op = "set_code", cell = cell, code = code,
                 expected = expected), class = "ember_op")
}
#' @export
insert_cell <- function(index, code = "", kind = c("code", "markdown")) {
  structure(list(op = "insert", index = index, code = code,
                 kind = match.arg(kind)), class = "ember_op")
}
#' @export
delete_cell <- function(cell) {
  structure(list(op = "delete", cell = cell), class = "ember_op")
}
#' @export
move_cell <- function(cell, index) {
  structure(list(op = "move", cell = cell, index = index), class = "ember_op")
}
#' @export
fold_cell <- function(cell, folded = TRUE) {
  structure(list(op = "fold", cell = cell, folded = folded), class = "ember_op")
}

#' Switch between autorun and lazy. The mode is the header's
#' `on_cell_change`, so this edits the file and the change is saved.
#' @export
set_cell_change_mode <- function(nb, on_cell_change = c("autorun", "lazy")) {
  on_cell_change <- match.arg(on_cell_change)
  dispatch(nb, ev_set_mode(on_cell_change, at = Sys.time()))
  invisible(NULL)
}

# ---- Running ------------------------------------------------------------------

#' Allow execution without running anything: starts the worker.
#'
#' Returns `TRUE` if execution was already allowed.
#' @export
allow_execution <- function(nb) {
  dispatch(nb, ev_allow(at = Sys.time()))
}

#' Run cells, and the unrun, stale or failed ancestors they need, first.
#'
#' The first call allows execution for the session. The cells are queued at
#' once; they run in run order, one at a time, in the worker. Cells that
#' can't run (a graph error on the cell or on an ancestor) are not queued
#' and come back in `skipped`.
#'
#' @param ids Cell ids or display indexes; `NULL` runs every code cell.
#' @param wait `TRUE` blocks until the queue is empty or `timeout` passes,
#'   servicing the `later` loop meanwhile. Only for the console and tests:
#'   code that itself runs inside a `later` callback (the server, Endeavor's
#'   adapter) must use `wait = FALSE` and `on_notebook_event()`.
#' @return Invisibly, `list(accepted, queued, skipped, finished, timed_out)`;
#'   `finished`/`timed_out` are empty unless `wait`. `accepted` is `FALSE`
#'   only for a read-only notebook or a closed handle.
#' @export
run_cells <- function(nb, ids = NULL, wait = FALSE, timeout = 60) {
  resolved <- if (is.null(ids)) NULL else {
    vapply(ids, function(x) resolve_cell_id(nb, x), character(1))
  }
  reply <- dispatch(nb, ev_run(resolved, at = Sys.time()))

  if (is.null(reply) || inherits(reply, "ember_refused")) {
    return(invisible(list(accepted = FALSE, queued = character(), skipped = character(),
                          finished = character(), timed_out = FALSE)))
  }

  result <- list(accepted = reply$accepted, queued = reply$queued, skipped = reply$skipped,
                 finished = character(), timed_out = FALSE)
  if (isTRUE(wait)) {
    ok <- wait_for(nb, is_idle, timeout = timeout)
    result$timed_out <- !ok
    result$finished <- if (ok) reply$queued else character()
  }
  invisible(result)
}

#' Interrupt the running cell and clear the queue.
#'
#' Sends SIGINT. If the cell hasn't stopped `grace` seconds later, the
#' snapshot's `restart_offered` turns `TRUE` (with the cells a restart would
#' leave not run); it turns back to `FALSE` if the cell stops after all.
#' @export
interrupt_notebook <- function(nb) {
  dispatch(nb, ev_interrupt(at = Sys.time()))
  invisible(NULL)
}

#' Replace the worker with a new one. Every cell is left not run.
#'
#' Refused (an `ember_refused` condition) in safe preview.
#' @export
restart_notebook <- function(nb) {
  reply <- dispatch(nb, ev_restart(at = Sys.time()))
  if (inherits(reply, "ember_refused")) stop(reply)
  invisible(reply)
}

# ---- Reading ------------------------------------------------------------------

#' What the notebook looks like now: a plain list, safe to keep.
#'
#' `list(id, path, seq, read_only, allowed, process, restart_offered,
#' worker_message, problems, order, cells, packages)` where `process` is one
#' of `"preview"`, `"starting"`, `"ready"`, `"busy"`, `"stopped"`, `cells`
#' is a named list (display order) of `ember_cell_view` (see
#' `snapshot_of()` in state.R), and `packages` is `package_status(nb)`'s
#' value (packages-core.R's `packages_view()`). Endeavor's `snapshot` maps
#' onto this one to one.
#' @export
notebook_snapshot <- function(nb) {
  s <- snapshot_of(nb$state)
  list(id = nb$state$id, path = nb$state$path, seq = s$seq,
      read_only = isTRUE(nb$state$read_only), allowed = isTRUE(nb$state$allowed),
      process = s$process, restart_offered = s$restart_offered,
      worker_message = s$worker_message, problems = nb$state$problems,
      order = names(nb$state$cells), cells = s$cells, packages = s$packages)
}

#' The notebook's current `ember_graph` (step 1's type).
#'
#' Always reflects the current code, including staged edits, so it answers
#' Endeavor's `graph(fresh = TRUE)` without extra work. Query it with step
#' 1's functions: `cell_summary()`, `upstream()`, `blocked_cells()`, ...
#' @export
dependency_graph <- function(nb) nb$state$graph

#' The immutable session state, for the step-4 UI's projection.
#'
#' Consecutive values share every unchanged part (they are made by
#' modifying the previous one), so `identical()` on a sub-part is a cheap
#' "did this change" test. Callers must treat its fields as read-only and
#' undocumented except where state.R documents them.
#' @export
notebook_state <- function(nb) nb$state

#' A PNG of a cell's output, for Endeavor's `view_cell_output`.
#'
#' Plots are already PNGs and come back at once. With `width`/`height`
#' different from the stored image, the worker re-renders the recorded
#' plot (the call waits up to `timeout`). Other outputs return `NULL`; the
#' caller reads their `text/plain` form from the snapshot.
#' @return `list(png = <raw> | NULL, mime = <the output's mime type>)`.
#' @export
render_png <- function(nb, cell, width = NULL, height = NULL, timeout = 5) {
  id <- resolve_cell_id(nb, cell)
  find_view <- function() {
    snap <- notebook_snapshot(nb)
    Find(function(v) identical(v$id, id), snap$cells)
  }
  view <- find_view()
  if (is.null(view) || is.null(view$output) || !identical(view$output$mime, "image/png")) {
    return(list(png = NULL, mime = if (!is.null(view$output)) view$output$mime else NULL))
  }
  if (is.null(width) && is.null(height)) {
    return(list(png = view$output$data, mime = "image/png"))
  }

  before <- view$output
  dispatch(nb, ev_render(id, width, height, at = Sys.time()))
  deadline <- Sys.time() + timeout
  repeat {
    now_view <- find_view()
    if (!is.null(now_view$output) && !identical(now_view$output, before)) {
      return(list(png = now_view$output$data, mime = "image/png"))
    }
    remaining <- as.numeric(deadline - Sys.time(), units = "secs")
    if (remaining <= 0) return(list(png = NULL, mime = "image/png"))
    later::run_now(timeout = remaining)
  }
}

# ---- Events and waiting -------------------------------------------------------

#' Call `fn(note)` for every notification from this notebook.
#'
#' `note` is `list(kind, seq, ...)` with `kind` one of `"notebook_opened"`,
#' `"cell_state"` (`cells`: ids whose snapshot view changed), `"topology_changed"`
#' (`cells`: ids from `changed_cells()`), `"file_saved"`, `"execution_done"`,
#' `"notebook_shut_down"`. Notifications are derived from the change in
#' state over one dispatch, so a burst of worker messages handled together
#' gives one `cell_state`. `fn` is called once the dispatch is complete,
#' so it may call the API and gets ordinary replies.
#' @return A function that unsubscribes.
#' @export
on_notebook_event <- function(nb, fn) {
  key <- uuid()
  nb$listeners[[key]] <- fn
  function() {
    nb$listeners[[key]] <- NULL
    invisible(NULL)
  }
}

#' Block until `predicate(notebook_snapshot(nb))` is `TRUE` or `timeout`
#' seconds pass, servicing `later` meanwhile. No sleeps: it waits on
#' `later::run_now()`, which returns as soon as a callback ran.
#'
#' `predicate` defaults to "nothing queued or running". Returns `TRUE` if
#' the predicate held, `FALSE` on timeout. For tests and the console.
#' @export
wait_for <- function(nb, predicate = is_idle, timeout = 10) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(predicate(notebook_snapshot(nb)))) return(TRUE)
    remaining <- as.numeric(deadline - Sys.time(), units = "secs")
    if (remaining <= 0) return(FALSE)
    later::run_now(timeout = remaining)
  }
}

#' @export
print.ember_notebook <- function(x, ...) {
  snap <- notebook_snapshot(x)
  not_run <- sum(vapply(snap$cells, function(c) identical(c$status, "not_run"), logical(1)))
  stale <- sum(vapply(snap$cells, function(c) isTRUE(c$stale), logical(1)))
  cat(sprintf("<ember_notebook> %s (%s)\n", snap$path, snap$process))
  cat(sprintf("%d cells, %d not run, %d stale\n", length(snap$cells), not_run, stale))
  for (c in snap$cells) {
    first_line <- strsplit(c$code, "\n", fixed = TRUE)[[1]]
    first_line <- if (length(first_line) == 0) "" else first_line[1]
    cat(sprintf("  [%d] %-40s %s\n", c$index, first_line, c$status))
  }
  invisible(x)
}
