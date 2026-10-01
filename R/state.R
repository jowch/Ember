# The session state: one immutable value holding everything the server
# knows about one open notebook, and the pure projections read from it
# (the snapshot, the file, the notifications, the files to watch).
#
# Only `step()` (step.R) makes a new state, always by modifying the previous
# one, so unchanged parts stay the same R objects and `identical()` on them
# returns at once. That is what makes the projections below cheap enough to
# recompute after every dispatch, and what the step-4 UI's Pluto state
# diff relies on (design.md, Performance).
#
# Nothing here does IO, reads the clock, or makes random ids.

`%||%` <- function(x, y) if (is.null(x)) y else x

# ---- The state ---------------------------------------------------------------

#' The session state.
#'
#' Fields (all always present):
#'
#' * `id`: notebook id (UUID), fixed for the session.
#' * `path`: the file's path.
#' * `read_only`: `TRUE` when the file was saved by a newer Ember. Then no
#'   edit, run or save happens.
#' * `problems`: data frame `kind`, `detail` of what `parse_notebook()`
#'   repaired on open (duplicate ids, missing footer, ...). Shown, not acted
#'   on.
#' * `file`: the non-cell parts of the file, carried through unchanged
#'   unless something edits them: `header` (`ember_header`; its
#'   `on_cell_change` is the session's mode, changed by `ev_set_mode`), `lock`
#'   (character, one line per package, verbatim), `extra_blocks`, `format`
#'   (the format the file was read in).
#' * `cells`: named list, id -> `list(code, kind, folded)`, in display
#'   order. `kind` is `"code"` or `"markdown"`. The names are the display
#'   order; there is no separate order field.
#' * `setup`: the setup cell's id. Always a code cell in `cells`.
#' * `files`: named list, path -> `list(text, hash)`, the sourced files as
#'   last read (`text = NA` when the file is missing). The graph reads
#'   sourced files only from here, so building it stays pure.
#' * `computed_sources`: named list, cell id -> character paths the worker
#'   reported through `source()` with a computed path on the cell's latest
#'   run. Cleared for a cell when it starts running or is deleted.
#' * `footer_sources`: computed paths read from the footer, which doesn't
#'   say which cell sourced them. They stand in until every code cell has
#'   run in this worker, after which `computed_sources` is complete.
#' * `exports`: named list, package -> exported names, as the worker
#'   reported for packages it attached. Kept across restarts.
#' * `graph`: the `ember_graph` of the current code. Derived: see the
#'   invariant below.
#' * `options`: `list(library, grace)`; `grace` is the
#'   seconds after an interrupt before a restart is offered (default 3).
#' * `allowed`: execution allowed this session.
#' * `closed`: the session was shut down; every later event is a no-op.
#' * `worker`: `ember_worker_state`, below.
#' * `pending`: character ids wanted to run. Not ordered: the next cell is
#'   always the first of `run_order(graph, pending)` that can run, so an
#'   edit or a learned definition during a run reorders the queue for free.
#' * `results`: named list, id -> `ember_result`, for cells that ran in the
#'   current worker. A cell with no entry is "not run".
#' * `clock`: the `at` of the last event; the only time the core knows.
#' * `seq`: integer, advanced by every event that changed the state
#'   (Endeavor's `seq`).
#' * `next_token`: integer, the next run token.
#'
#' Invariants (checked by `check_state()` in tests after every step):
#' * `graph` is `notebook_graph(code_of(cells), setup, exports,
#'   graph$learned, read_file = reader_of(files))` for the current fields:
#'   every step that changes `cells`, `setup`, `exports` or `files` rebuilds
#'   it with `previous = graph` (`rebuild_graph()` in step.R) and nothing
#'   else assigns it.
#' * `pending` holds only code cells in `cells`, and never the running cell
#'   unless it was asked for again while running.
#' * `results` holds only ids in `cells`.
#' * `setup` names a code cell in `cells`.
#' * `worker$running` is not `NULL` iff `worker$status == "busy"`.
#' * `!allowed` implies `worker$status == "off"`, `pending` and `results`
#'   empty.
new_state <- function(file, path, id, options, at) {
  if (is.null(options)) options <- list()
  if (is.null(options$grace)) options$grace <- 3
  cells <- file$cells
  setup <- file$setup
  files <- list()
  learned <- list(definitions = file$learned, references = list())
  graph <- notebook_graph(code_of(cells), setup = setup, exports = list(),
                          learned = learned, read_file = reader_of(files))

  # Seed `files` and `footer_sources` from the footer's "sourced files"
  # block (design.md: "Before the first run, the last path recorded in the
  # footer stands in"). Without this, a path the static analysis can't see
  # (a computed `source()`, learned only when the cell last ran) is
  # forgotten the moment the notebook opens, and the next save drops its
  # footer line even though nothing was edited. Seeding `files[[p]]$hash`
  # (not `$text`: unread, same as never having opened it, which
  # `reader_of()` already treats as "missing" either way) only changes what
  # `notebook_file_of()` can write, not what the graph was built from above,
  # so this doesn't disturb the `graph` invariant.
  sourced <- file$sourced
  footer_sources <- character()
  if (!is.null(sourced) && nrow(sourced) > 0) {
    literal <- unique(unlist(lapply(graph$analyses, function(a) {
      if (is.null(a$sourced) || nrow(a$sourced) == 0) character() else a$sourced$path
    }), use.names = FALSE))
    for (i in seq_len(nrow(sourced))) {
      p <- sourced$path[[i]]
      files[[p]] <- list(text = NA_character_, hash = sourced$hash[[i]])
      if (!(p %in% literal)) footer_sources <- union(footer_sources, p)
    }
  }

  structure(list(
    id = id, path = path, read_only = isTRUE(file$read_only),
    problems = file$problems,
    file = list(header = file$header, lock = file$lock,
               extra_blocks = file$extra_blocks, format = file$format),
    cells = cells, setup = setup, files = files, computed_sources = list(),
    footer_sources = footer_sources,
    exports = list(), graph = graph, options = options,
    allowed = FALSE, closed = FALSE, worker = new_worker_state(),
    pending = character(), results = list(), clock = at, seq = 0L,
    next_token = 1L
  ), class = "ember_state")
}

#' The worker as the core sees it. The process handle and socket are the
#' shell's; the core knows only this.
#'
#' * `status`: `"off"` (never started this session), `"starting"`
#'   (spawned, no hello yet), `"ready"`, `"busy"`, `"stopped"` (exited,
#'   crashed or failed to start; the next run starts a new one).
#' * `gen`: integer generation, +1 per start. Every worker event carries the
#'   generation it came from; events from an older generation are ignored,
#'   which is what makes kill-then-start safe against messages in flight.
#' * `running`: `NULL` or `list(cell, token, code, started_at, console)`;
#'   `console` grows as the worker streams console items.
#' * `interrupt`: `NULL` or `list(at, token)` once SIGINT was sent for that
#'   run.
#' * `restart_offered`: logical.
#' * `info`: what the hello said (pid, R version, library paths), or `NULL`.
#' * `exit`: `NULL` or `list(status, message)` from the last exit.
new_worker_state <- function() {
  structure(list(status = "off", gen = 0L, running = NULL, interrupt = NULL,
                 restart_offered = FALSE, info = NULL, exit = NULL),
            class = "ember_worker_state")
}

#' The result of one run of one cell in the current worker.
#'
#' * `code`: the code that ran. `code != cells[[id]]$code` is "code
#'   differs" (an edit not yet run), derived rather than stored.
#' * `status`: `"ok"`, `"error"` or `"interrupted"`.
#' * `output`: `ember_display` or `NULL` (no visible value).
#' * `console`: list of `list(kind = "stdout" | "message" | "warning",
#'   text)`, in order.
#' * `error`: `NULL` or `ember_run_error`.
#' * `started_at`, `runtime` (seconds).
#' * `defined`: the global names this run created (the worker's report);
#'   when the cell next runs these are the names it removes, so their
#'   readers are invalidated even if the new code no longer defines them.
#' * `stale`: `TRUE` once an ancestor ran (or a sourced file changed) after
#'   this result was made. Running the cell clears it.
new_result <- function(code, status, output, console, error, started_at,
                       runtime, defined, stale = FALSE) {
  structure(list(code = code, status = status, output = output,
                 console = console, error = error, started_at = started_at,
                 runtime = runtime, defined = defined, stale = stale),
            class = "ember_result")
}

#' An error found while running, as opposed to a graph error.
#'
#' `kind`: `"error"` (R signalled one), `"multiple_definitions"` (the cell
#' changed or removed another cell's global), `"global_setting"` (the cell's
#' own code changed options, env vars, wd, locale or the search path outside
#' the setup cell), `"source_conflict"` (a computed `source()` was refused),
#' `"worker_exited"`. `message`, `traceback` (character, innermost last),
#' `names`, `fixes` as on `ember_graph_error`.
new_run_error <- function(kind, message, traceback = character(),
                          names = character(), fixes = character()) {
  structure(list(kind = kind, message = message, traceback = traceback,
                 names = names, fixes = fixes), class = "ember_run_error")
}

#' A cell's displayed output, as the worker built it.
#'
#' `mime` is the primary type (`"text/html"`, `"image/png"`,
#' `"image/svg+xml"`, `"text/markdown"`, `"text/latex"`,
#' `"application/vnd.ember.table"`, `"application/vnd.ember.tree"`,
#' `"text/plain"`); `data` its body (character, or raw for PNG); `text` the
#' truncated `print()` form, always present; `deps` the htmlwidget
#' dependencies (name, version, folder) for the server's static paths;
#' `size` the plot size for an image, else `NULL`.
new_display <- function(mime, data, text, deps = list(), size = NULL) {
  structure(list(mime = mime, data = data, text = text, deps = deps,
                 size = size), class = "ember_display")
}

# ---- Projections -------------------------------------------------------------

#' The snapshot: the notebook as Endeavor and the console see it.
#'
#' `list(cells, process, restart_offered, worker_message, seq)`. Per cell,
#' an `ember_cell_view`: `id`, `index` (display), `kind`, `code`, `folded`,
#' `setup`, `queued`, `running`, `status` (`"not_run"`, `"ok"`, `"error"`,
#' `"interrupted"`), `stale`, `code_differs`, `blocked` (a graph error on
#' the cell or an ancestor), `blocked_by` (the id of the upstream cell whose
#' failed result blocks this one, or `NA`; separate from `blocked`, which is
#' about graph errors), `errors` (graph errors then the run error, each with
#' `kind`, `message`, `fixes`), `output` (`ember_display` or `NULL`),
#' `console`, `last_run`, `runtime`.
#'
#' For the running cell, `console` is what has streamed so far and `output`
#' is the previous result's, shown as stale.
snapshot_of <- function(state) {
  graph <- state$graph
  blocked_direct <- blocked_cells(graph)
  blocked_down <- unlist(lapply(blocked_direct, function(b) {
    downstream(graph, b, transitive = TRUE)
  }), use.names = FALSE)
  blocked_ids <- union(blocked_direct, blocked_down)
  fblocked <- failed_blockers(state)

  running <- state$worker$running
  running_cell <- if (!is.null(running)) running$cell else NA_character_
  queued <- setdiff(run_order(graph, state$pending), running_cell)

  ids <- names(state$cells)
  views <- list()
  for (i in seq_along(ids)) {
    id <- ids[i]
    cell <- state$cells[[id]]
    result <- state$results[[id]]
    is_running <- !is.null(running) && identical(running$cell, id)

    g_errors <- lapply(cell_errors(graph, id), function(e) {
      list(kind = e$kind, message = e$message, fixes = e$fixes)
    })
    r_error <- if (!is.null(result) && !is.null(result$error)) {
      list(list(kind = result$error$kind, message = result$error$message,
                fixes = result$error$fixes))
    } else {
      list()
    }

    views[[id]] <- structure(list(
      id = id, index = i, kind = cell$kind, code = cell$code,
      folded = isTRUE(cell$folded), setup = identical(id, state$setup),
      queued = id %in% queued, running = is_running,
      status = if (!is.null(result)) result$status else "not_run",
      stale = !is.null(result) && isTRUE(result$stale),
      code_differs = !is.null(result) && !identical(result$code, cell$code),
      blocked = id %in% blocked_ids,
      blocked_by = fblocked[[id]] %||% NA_character_,
      errors = c(g_errors, r_error),
      output = if (!is.null(result)) result$output else NULL,
      console = if (is_running) running$console
                else if (!is.null(result)) result$console else list(),
      last_run = if (!is.null(result)) result$started_at else NULL,
      runtime = if (!is.null(result)) result$runtime else NULL
    ), class = "ember_cell_view")
  }

  process <- if (!isTRUE(state$allowed)) "preview" else state$worker$status
  list(cells = views, process = process,
      restart_offered = isTRUE(state$worker$restart_offered),
      worker_message = if (!is.null(state$worker$exit)) state$worker$exit$message else NULL,
      seq = state$seq)
}

#' `TRUE` when nothing is queued or running. The default `wait_for()`
#' predicate; takes a snapshot.
is_idle <- function(snapshot) {
  !any(vapply(snapshot$cells, function(c) c$queued || c$running, logical(1)))
}

#' The file this state would write: an `ember_notebook_file` (notebook.R).
#'
#' Cells in display order with fold state, setup id, the graph's run order
#' (the order cells are written in), learned definitions from
#' `graph$learned$definitions`, sourced-file hashes from `files` for every
#' literal and computed `source()` path, the lock and header unchanged.
#' The header's `ember_version` is the running Ember's.
notebook_file_of <- function(state) {
  header <- state$file$header
  header$ember_version <- as.character(utils::packageVersion("ember"))

  paths <- watched_files(state)
  if (length(paths) == 0) {
    sourced <- data.frame(path = character(), hash = character(),
                          stringsAsFactors = FALSE)
  } else {
    hashes <- vapply(paths, function(p) {
      h <- state$files[[p]]$hash
      if (is.null(h) || (length(h) == 1 && is.na(h))) NA_character_ else h
    }, character(1))
    # A path with no hash yet (not read, or read but missing on disk) is
    # left out of the footer entirely rather than writing "NA": the footer
    # records known hashes, and an unknown one is exactly what
    # `missing_file_reads()` is still asking the shell for.
    known <- !is.na(hashes)
    sourced <- data.frame(path = paths[known], hash = hashes[known], stringsAsFactors = FALSE)
  }

  learned <- state$graph$learned$definitions
  learned <- learned[vapply(learned, length, integer(1)) > 0]

  new_notebook_file(header = header, cells = state$cells, setup = state$setup,
                    run_order = state$graph$order, learned = learned,
                    sourced = sourced, lock = state$file$lock,
                    extra_blocks = state$file$extra_blocks,
                    format = state$file$format, read_only = state$read_only,
                    problems = state$problems)
}

#' Notifications for the change from `old` to `new` (one dispatch).
#'
#' Derived, never emitted by `step()`: whatever path a change took, the
#' same rule reports it, and a burst of events gives one notification of
#' each kind.
#'
#' * `notebook_opened` when `old` is `NULL`.
#' * `cell_state` with the ids whose `ember_cell_view` differs (compare
#'   `snapshot_of(old)$cells` with `snapshot_of(new)$cells` per id, after
#'   an `identical()` short cut on `cells`, `results`, `pending`, `worker`).
#' * `topology_changed` with `changed_cells(old$graph, new$graph)` when
#'   non-empty.
#' * `execution_done` when `old` had a running cell or pending ids and
#'   `new` has neither.
#' * `notebook_shut_down` when `new$closed && !old$closed`.
#'
#' `file_saved` is not here: only the shell knows a write succeeded.
notifications <- function(old, new) {
  if (is.null(old)) return(list(list(kind = "notebook_opened")))

  nts <- list()
  quick_same <- identical(old$cells, new$cells) &&
    identical(old$results, new$results) &&
    identical(old$pending, new$pending) &&
    identical(old$worker, new$worker) &&
    identical(old$graph, new$graph) &&
    identical(old$allowed, new$allowed) &&
    identical(old$setup, new$setup)
  if (!quick_same) {
    old_views <- snapshot_of(old)$cells
    new_views <- snapshot_of(new)$cells
    ids <- union(names(old_views), names(new_views))
    changed <- Filter(function(id) !identical(old_views[[id]], new_views[[id]]), ids)
    if (length(changed) > 0) nts <- c(nts, list(list(kind = "cell_state", cells = changed)))
  }

  topo <- changed_cells(old$graph, new$graph)
  if (length(topo) > 0) nts <- c(nts, list(list(kind = "topology_changed", cells = topo)))

  old_busy <- !is.null(old$worker$running) || length(old$pending) > 0
  new_busy <- !is.null(new$worker$running) || length(new$pending) > 0
  if (old_busy && !new_busy) nts <- c(nts, list(list(kind = "execution_done")))

  if (isTRUE(new$closed) && !isTRUE(old$closed)) {
    nts <- c(nts, list(list(kind = "notebook_shut_down")))
  }

  nts
}

#' Paths the shell should watch: every literal `source()` path in the
#' analyses plus `computed_sources` and `footer_sources`, relative to the notebook's folder.
watched_files <- function(state) {
  lit <- unlist(lapply(state$graph$analyses, function(a) {
    if (is.null(a$sourced) || nrow(a$sourced) == 0) character() else a$sourced$path
  }), use.names = FALSE)
  comp <- unlist(state$computed_sources, use.names = FALSE)
  unique(c(lit, comp, state$footer_sources))
}

#' The reader the graph is built with: `files` as a function.
#'
#' Returns the text for a read file, `NULL` for a missing or not-yet-read
#' one (both show as a "missing_file" note until the read arrives).
reader_of <- function(files) {
  function(path) {
    f <- files[[path]]
    if (is.null(f) || is.na(f$text)) NULL else f$text
  }
}

#' Code per cell for `notebook_graph()`: markdown cells as `""`.
code_of <- function(cells) {
  vapply(cells, function(c) if (c$kind == "markdown") "" else c$code,
         character(1))
}

#' Test helper: stop with a message naming each broken invariant.
check_state <- function(state) {
  problems <- character()

  expected <- notebook_graph(code_of(state$cells), setup = state$setup,
                             exports = state$exports, learned = state$graph$learned,
                             previous = state$graph, read_file = reader_of(state$files))
  # `read_file` is a closure freshly made over `state$files`; it is never
  # the same object as the one already stored on the graph even when it
  # behaves identically. `reread` records what was recomputed relative to
  # whatever `previous` a build happened to use, so comparing it against a
  # graph rebuilt with `previous = state$graph` (which makes everything
  # cached, `reread` empty) isn't meaningful. Both are excluded.
  actual_cmp <- state$graph; actual_cmp$read_file <- NULL; actual_cmp$reread <- NULL
  expected_cmp <- expected; expected_cmp$read_file <- NULL; expected_cmp$reread <- NULL
  if (!identical(expected_cmp, actual_cmp)) {
    problems <- c(problems, "graph is not notebook_graph() of the current fields")
  }

  if (!all(state$pending %in% names(state$cells))) {
    problems <- c(problems, "pending has ids not in cells")
  } else if (length(state$pending) > 0 &&
            any(vapply(state$pending, function(id) state$cells[[id]]$kind != "code", logical(1)))) {
    problems <- c(problems, "pending has a non-code cell")
  }

  if (!all(names(state$results) %in% names(state$cells))) {
    problems <- c(problems, "results has ids not in cells")
  }

  setup_cell <- state$cells[[state$setup]]
  if (is.null(setup_cell) || !identical(setup_cell$kind, "code")) {
    problems <- c(problems, "setup is not a code cell")
  }

  busy_consistent <- identical(state$worker$status, "busy") == !is.null(state$worker$running)
  if (!busy_consistent) {
    problems <- c(problems, "worker$running inconsistent with status busy")
  }

  if (!isTRUE(state$allowed)) {
    if (!identical(state$worker$status, "off")) {
      problems <- c(problems, "!allowed but worker not off")
    }
    if (length(state$pending) > 0) problems <- c(problems, "!allowed but pending nonempty")
    if (length(state$results) > 0) problems <- c(problems, "!allowed but results nonempty")
  }

  if (length(problems) > 0) stop(paste(problems, collapse = "; "))
  invisible(state)
}
