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

#' The exports the graph is built with: the installed packages' (from the
#' active library's manifest), overridden by what the worker reported for
#' packages it attached. Replaces the bare `state$exports` in
#' `rebuild_graph()` (step.R) and `check_state()`'s graph invariant, so a
#' cell that attaches dplyr gets dplyr's edges before it ever runs.
#'
#' At `new_state()` time `state$packages` doesn't exist yet, so the initial
#' graph is built with `exports = list()` directly; that is equal to
#' `exports_of()` at that point anyway, since a fresh `packages` state's
#' `active` is always the empty library (no exports) and `state$exports`
#' starts empty too.
exports_of <- function(state) {
  utils::modifyList(state$packages$active$exports, state$exports)
}

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
#' * `cells`: named list, id -> `list(code, kind, folded, disabled)`, in
#'   display order. `kind` is always `cell_kind(code, setup = <is this the
#'   setup cell>)` (text-cells.R): `"code"` or `"markdown"` ("text", in
#'   ui-3.md's words -- the field keeps Pluto's name). The names are the
#'   display order; there is no separate order field. `disabled` is the
#'   user's choice (`disable_cell()`); always `FALSE` for a markdown cell.
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
#' * `worker_usage`: `NULL` or `list(gen, rss)`, the worker's last-reported
#'   memory (bytes), from `ev_worker_usage()` (shell.R samples it every 2s
#'   with processx's `get_memory_info()`). Top-level, not part of `worker`,
#'   so a memory change doesn't make `notifications()`'s cheap
#'   `identical(old$worker, new$worker)` check see every cell's snapshot as
#'   possibly changed (ui-2.md, Worker memory). A `gen` from an old worker is
#'   left in place until the new one reports; readers compare it against
#'   `worker$gen` themselves.
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
#' Default `r_info()` (library.R), computed inline so state.R doesn't take a
#' hard dependency on library.R's version of it: callers (`open_notebook()`)
#' are expected to pass `options$r <- r_info()` themselves; this is only the
#' fallback for tests and for opening with no options at all.
default_r_info <- function() {
  list(version = paste(R.version$major, R.version$minor, sep = "."),
      minor = paste(R.version$major, strsplit(R.version$minor, "\\.", fixed = FALSE)[[1]][1], sep = "."),
      platform = R.version$platform)
}

new_state <- function(file, path, id, options, at) {
  if (is.null(options)) options <- list()
  if (is.null(options$grace)) options$grace <- 3
  if (is.null(options$repos)) options$repos <- ember_repos()
  if (is.null(options$cache)) options$cache <- tempfile("ember-cache-")
  # `[[` (exact), not `$`: `options$r` partial-matches `options$repos` via
  # `$`'s partial-matching on lists whenever `repos` is already set and `r`
  # isn't, which would make this check always find a (wrong) non-NULL value
  # and skip filling in the real `r`.
  if (is.null(options[["r"]])) options$r <- default_r_info()
  cells <- file$cells
  setup <- file$setup
  files <- list()
  learned <- list(definitions = file$learned, references = list())
  graph <- notebook_graph(code_of(cells), setup = setup, exports = list(),
                          learned = learned, disabled = disabled_ids(cells),
                          read_file = reader_of(files))

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

  wanted <- wanted_packages(graph, file$header)
  packages <- new_packages_state(file$lock, wanted, options$r, options$cache)

  structure(list(
    id = id, path = path, read_only = isTRUE(file$read_only),
    problems = file$problems,
    file = list(header = file$header, lock = file$lock,
               extra_blocks = file$extra_blocks, format = file$format),
    cells = cells, setup = setup, files = files, computed_sources = list(),
    footer_sources = footer_sources,
    exports = list(), graph = graph, options = options, packages = packages,
    allowed = FALSE, closed = FALSE, worker = new_worker_state(),
    worker_usage = NULL,
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
#' * `loaded`: named character, namespace -> version, for non-base
#'   namespaces loaded in this worker (from the hello and every `done`
#'   report). Reset with the worker: `restart_worker()` makes a fresh
#'   `new_worker_state()`.
new_worker_state <- function() {
  structure(list(status = "off", gen = 0L, running = NULL, interrupt = NULL,
                 restart_offered = FALSE, info = NULL, exit = NULL,
                 loaded = character()),
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
#' `kind`: `"error"` (R signalled one), `"upstream"` (a cell this one reads
#' from failed or has a graph error; `names`/`cells` say which names and
#' which cells, aligned), `"multiple_definitions"` (the cell changed or
#' removed another cell's global), `"global_setting"` (the cell's own code
#' changed options, env vars, wd, locale or the search path outside the
#' setup cell), `"source_conflict"` (a computed `source()` was refused),
#' `"worker_exited"`. `message`, `traceback` (character, innermost last),
#' `names`, `fixes` as on `ember_graph_error`. `call`/`line` are set only
#' for a text cell's inline expression that errored (the `` `r expr` ``
#' text and its line in the cell, from `inline_spans()`); piece 6 fills
#' them for code cells too and shows "Error in `call` · line n".
new_run_error <- function(kind, message, traceback = character(),
                          names = character(), fixes = character(),
                          cells = character(), call = NULL, line = NULL) {
  structure(list(kind = kind, message = message, traceback = traceback,
                 names = names, fixes = fixes, cells = cells,
                 call = call, line = line), class = "ember_run_error")
}

#' A cell's displayed output, as the worker built it.
#'
#' `mime` is the primary type (`"text/html"`, `"image/png"`,
#' `"image/svg+xml"`, `"text/markdown"`, `"text/latex"`,
#' `"application/vnd.ember.table"`, `"application/vnd.ember.tree"`,
#' `"application/vnd.ember.inline"` (a text cell's inline values; `data`
#' is `list(values = <chr>)`, one per `` `r expr` `` span), `"text/plain"`);
#' `data` its body (character, or raw for PNG, or the
#' table/tree structure); `text` the truncated `print()` form, always
#' present; `deps` the htmlwidget dependencies (name, version, folder) for
#' the server's static paths; `size` the plot size for an image, else
#' `NULL`; `token` the run (or re-render) that made this display, so a late
#' reply for an older run or resize can be told apart from the current one
#' (`reduce_wk_rendered()`, step.R); `rendered_at` the time of the last
#' re-render or page ("more"), or `NULL` for a plain run -- this is what
#' makes `project_output()`'s `last_run_timestamp` advance so the page
#' redraws a paged table or a resized plot.
new_display <- function(mime, data, text, deps = list(), size = NULL,
                        token = NULL, rendered_at = NULL) {
  structure(list(mime = mime, data = data, text = text, deps = deps,
                 size = size, token = token, rendered_at = rendered_at),
            class = "ember_display")
}

# ---- Projections -------------------------------------------------------------

#' The snapshot: the notebook as Endeavor and the console see it.
#'
#' `list(cells, process, restart_offered, worker_message, seq)`. Per cell,
#' an `ember_cell_view`: `id`, `index` (display), `kind`, `code`, `folded`,
#' `setup`, `queued`, `running`, `status` (`"not_run"`, `"ok"`, `"error"`,
#' `"interrupted"`), `stale`, `code_differs`, `errors` (graph errors then
#' the run error, each with `kind`, `message`, `fixes`, `names`, and, for an
#' `"upstream"` run error, `cells`), `output` (`ember_display` or `NULL`),
#' `console`, `last_run`, `runtime`, `disabled` (the user's own choice),
#' `disabled_by` (the disabled cell a dependent is off because of, `NA`
#' otherwise -- including for the disabled cell itself).
#'
#' For the running cell, `console` is what has streamed so far and `output`
#' is the previous result's, shown as stale.
#'
#' Built from `view_context()` (the notebook-wide facts, computed once) and
#' `cell_view()` (one cell's view), so the step-4 UI's projection
#' (`pluto_state()`, pluto-state.R) can share exactly the same rules
#' instead of keeping a second copy of "what queued/stale/errored means".
snapshot_of <- function(state) {
  ctx <- view_context(state)
  ids <- ctx$ids
  views <- stats::setNames(lapply(seq_along(ids), function(i) cell_view(state, ctx, i)), ids)

  process <- if (!isTRUE(state$allowed)) "preview" else state$worker$status
  list(cells = views, process = process,
      restart_offered = isTRUE(state$worker$restart_offered),
      worker_message = if (!is.null(state$worker$exit)) state$worker$exit$message else NULL,
      seq = state$seq, packages = packages_view(state))
}

#' Everything `snapshot_of()` and `pluto_state()` compute once for the whole
#' notebook, so no per-cell loop repeats a notebook-wide pass (`%in%` over
#' every queued id, `cell_errors()`'s `Filter()` over every graph error)
#' once per cell: that would make a 2000-cell snapshot or projection
#' quadratic.
#'
#' Every per-cell field here is a plain (unnamed) vector or list in display
#' order, read by callers with `[[i]]` (the cell's position in `ids`,
#' 1-based), never `[[id]]`: R's named `[[` is a linear scan over the names,
#' so at 2000 cells a handful of named lookups per cell (one per field this
#' used to be keyed by id) cost tens of milliseconds on their own (measured).
#' `waiting` arrives keyed by id (from `waiting_cells()`, which only names
#' the few cells it's about), so it is re-keyed to position once here, not
#' per cell.
#'
#' * `ids`: `names(state$cells)`, fixed once so callers don't call it again.
#' * `running`: `state$worker$running`, or `NULL`; `running_idx` its cell's
#'   position in `ids`, or `NA`.
#' * `queued`: logical, position -> queued (not the running cell).
#' * `waiting`: list, position -> `waiting_cells()`'s value, or `NULL`.
#' * `errors_by_cell`: list, position -> the graph errors naming it
#'   (`cell_errors(graph, id)`'s result), grouped once over `graph$errors`.
#'   A cell with its own graph error can't run (`can_run()`, step.R); it
#'   shows that error rather than running at all.
#' * `off`: logical, position -> `ids[i] %in% names(state$graph$off)`
#'   (disabled, or a dependent of a disabled cell).
#' * `disabled_by`: character, position -> the disabled cell `ids[i]`'s off
#'   status comes from, or `NA` for a disabled cell itself (it maps to
#'   itself in `graph$off`, which isn't a "disabled by" relationship) or a
#'   cell that isn't off. Built from `graph$off` alone, a loop bounded by
#'   the (usually small) off set, not by the whole notebook.
#' * `results`: list, position -> `state$results[[id]]` or `NULL`, aligned
#'   once with `match()`: `results` isn't stored in display order (it's
#'   keyed by id, and holds only cells that have run), so without this a
#'   per-cell loop reading it by id is a named-list scan repeated once per
#'   cell -- quadratic at a few thousand cells (measured: 0.95ms a cell with
#'   every cell holding a result).
view_context <- function(state) {
  graph <- state$graph
  ids <- names(state$cells)
  n <- length(ids)
  results <- state$results
  results <- if (is.null(results) || length(results) == 0) {
    vector("list", n)
  } else {
    results[match(ids, names(results))]
  }

  running <- state$worker$running
  running_idx <- if (!is.null(running)) match(running$cell, ids) else NA_integer_
  running_cell <- if (!is.null(running)) running$cell else NA_character_
  queued_ids <- setdiff(run_order(graph, state$pending), running_cell)
  queued <- ids %in% queued_ids

  waiting <- waiting_cells(state)
  waiting_vec <- vector("list", n)
  if (length(waiting) > 0) {
    at <- match(names(waiting), ids)
    ok <- !is.na(at)
    waiting_vec[at[ok]] <- waiting[ok]
  }

  # A cell with no entry here has no graph error; callers read `NULL` as
  # "no errors" rather than every slot being pre-filled with `list()`, which
  # would cost one allocation per cell on every call even when nothing ever
  # errors.
  errors_by_cell <- vector("list", n)
  for (e in graph$errors) {
    for (cid in e$cells) {
      at <- match(cid, ids)
      if (!is.na(at)) errors_by_cell[[at]] <- c(errors_by_cell[[at]], list(e))
    }
  }

  off_src <- graph$off
  off_ids <- names(off_src)
  off <- ids %in% off_ids
  disabled_by <- rep(NA_character_, n)
  for (oid in off_ids) {
    src <- off_src[[oid]]
    if (!identical(src, oid)) {
      at <- match(oid, ids)
      if (!is.na(at)) disabled_by[[at]] <- src
    }
  }

  list(ids = ids, running = running, running_idx = running_idx,
      queued = queued, waiting = waiting_vec,
      errors_by_cell = errors_by_cell, off = off, disabled_by = disabled_by,
      results = results)
}

#' One cell's `ember_cell_view`, from `state` and the `view_context()` it
#' belongs to, at position `i` (1-based, `ctx$ids[i]`'s position).
cell_view <- function(state, ctx, i) {
  id <- ctx$ids[[i]]
  cell <- state$cells[[i]]            # `state$cells` is in display order:
                                      # position, not a named lookup
  result <- ctx$results[[i]]          # view_context() already aligned this by position
  is_running <- !is.na(ctx$running_idx) && ctx$running_idx == i

  g_errors <- lapply(ctx$errors_by_cell[[i]], function(e) {
    list(kind = e$kind, message = e$message, fixes = e$fixes,
        names = e$names, cells = character(), traceback = character())
  })
  r_error <- if (!is.null(result) && !is.null(result$error)) {
    list(list(kind = result$error$kind, message = result$error$message,
              fixes = result$error$fixes, names = result$error$names,
              cells = result$error$cells, traceback = result$error$traceback,
              call = result$error$call, line = result$error$line))
  } else {
    list()
  }

  structure(list(
    id = id, index = i, kind = cell$kind, code = cell$code,
    folded = isTRUE(cell$folded), setup = identical(id, state$setup),
    queued = ctx$queued[[i]], running = is_running,
    status = if (!is.null(result)) result$status else "not_run",
    stale = !is.null(result) && isTRUE(result$stale),
    code_differs = !is.null(result) && !identical(result$code, cell$code),
    errors = c(g_errors, r_error),
    output = if (!is.null(result)) result$output else NULL,
    console = if (is_running) ctx$running$console
              else if (!is.null(result)) result$console else list(),
    last_run = if (!is.null(result)) result$started_at else NULL,
    runtime = if (!is.null(result)) result$runtime else NULL,
    waiting_for = ctx$waiting[[i]] %||% character(),
    disabled = isTRUE(cell$disabled), disabled_by = ctx$disabled_by[[i]]
  ), class = "ember_cell_view")
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

  # Off code cells that aren't themselves disabled are written commented
  # out too: the disabled cells carry their own `disabled` flag instead,
  # and a text cell is never commented (its `#'` lines already are
  # comments).
  off_ids <- names(state$graph$off)
  commented <- Filter(function(id) {
    !isTRUE(state$cells[[id]]$disabled) && identical(state$cells[[id]]$kind, "code")
  }, off_ids)

  new_notebook_file(header = header, cells = state$cells, setup = state$setup,
                    run_order = state$graph$order, learned = learned,
                    sourced = sourced, lock = state$file$lock,
                    extra_blocks = state$file$extra_blocks,
                    format = state$file$format, read_only = state$read_only,
                    problems = state$problems, commented = commented)
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

  pkg_same <- identical(old$packages, new$packages) &&
    identical(old$file$lock, new$file$lock) && identical(old$file$header, new$file$header) &&
    identical(old$worker$loaded, new$worker$loaded) && identical(old$graph, new$graph)
  if (!pkg_same && !identical(packages_view(old), packages_view(new))) {
    nts <- c(nts, list(list(kind = "packages_changed")))
  }

  if (!identical(old$worker_usage, new$worker_usage)) {
    nts <- c(nts, list(list(kind = "worker_usage")))
  }

  nts
}

#' Code cells with non-blank code, no result, and neither queued nor
#' running: the set the "N cells not run" bar counts
#' (`project_ember()`, pluto-state.R) and `ember_run_all` runs
#' (server.R). Empty whenever `!state$allowed` (safe preview): nothing has
#' had a chance to run yet, so there is nothing to offer running.
#'
#' A cell `ember_run_all` can't run -- one with a graph error of its own
#' (`ctx$errors_by_cell`) -- is excluded too: otherwise the bar's count
#' never reaches zero and "Run all" has nothing left to do about it (the
#' same check `can_run()`, step.R, makes before running a cell). A
#' dependent of a failed or graph-broken cell still counts: it runs on its
#' own and "Run all" can bring it to zero. An off cell (disabled, or a
#' dependent of one) is excluded too: it never runs until enabled.
not_run_ids <- function(state, ctx) {
  if (!isTRUE(state$allowed)) return(character())
  ids <- ctx$ids
  out <- character()
  for (i in seq_along(ids)) {
    cell <- state$cells[[i]]
    if (!cell_runs(cell)) next
    if (!nzchar(trimws(cell$code %||% ""))) next
    if (!is.null(ctx$results[[i]])) next
    if (isTRUE(ctx$queued[[i]])) next
    if (!is.na(ctx$running_idx) && ctx$running_idx == i) next
    if (!is.null(ctx$errors_by_cell[[i]])) next
    if (isTRUE(ctx$off[[i]])) next
    out <- c(out, ids[[i]])
  }
  out
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

#' Code per cell for `notebook_graph()`: a text cell's inline expressions
#' (`inline_code()`, "" when it has none), so they take part in the graph
#' like any other code; a code cell's own code unchanged.
code_of <- function(cells) {
  vapply(cells, function(c) if (c$kind == "markdown") inline_code(c$code) else c$code,
         character(1))
}

#' Disabled ids for `notebook_graph()`, in display order.
disabled_ids <- function(cells) {
  names(cells)[vapply(cells, function(c) isTRUE(c$disabled), logical(1))]
}

#' Test helper: stop with a message naming each broken invariant.
check_state <- function(state) {
  problems <- character()

  expected <- notebook_graph(code_of(state$cells), setup = state$setup,
                             exports = exports_of(state), learned = state$graph$learned,
                             disabled = disabled_ids(state$cells),
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
            any(vapply(state$pending, function(id) !cell_runs(state$cells[[id]]), logical(1)))) {
    problems <- c(problems, "pending has a cell that doesn't run")
  } else if (any(state$pending %in% names(state$graph$off))) {
    problems <- c(problems, "pending has an off cell")
  }

  if (!all(names(state$results) %in% names(state$cells))) {
    problems <- c(problems, "results has ids not in cells")
  }

  setup_cell <- state$cells[[state$setup]]
  if (is.null(setup_cell) || !identical(setup_cell$kind, "code")) {
    problems <- c(problems, "setup is not a code cell")
  }

  bad_kind <- Filter(function(id) {
    !identical(state$cells[[id]]$kind, cell_kind(state$cells[[id]]$code, setup = identical(id, state$setup)))
  }, names(state$cells))
  if (length(bad_kind) > 0) problems <- c(problems, "kind is not cell_kind(code)")

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

  p <- state$packages
  target_info <- library_for(state$file$lock, state$options$r, state$options$cache)
  if (!identical(p$target$key, target_info$key)) {
    problems <- c(problems, "packages$target is not library_for(state$file$lock)")
  }
  if (!identical(p$active$status, "ready")) {
    problems <- c(problems, "packages$active is not ready")
  }
  if (!isTRUE(state$allowed) && !is.null(p$install)) {
    problems <- c(problems, "packages$install running in safe preview")
  }

  if (length(problems) > 0) stop(paste(problems, collapse = "; "))
  invisible(state)
}
