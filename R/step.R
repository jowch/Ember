# The core: `step(state, event)` -> `list(state, effects, reply)`.
#
# Every input is an event: an API call, a worker message, a timer, a file
# read. `step()` is pure: it reads only its arguments (the time comes in
# `event$at`, new cell ids come in the event, file contents come in
# `ev_files_read`), and it says what should happen outside as effects,
# which the shell (shell.R) carries out. Tests drive it with synthetic
# events and no process at all.
#
# Saving the file and sending notifications are not effects: the shell
# derives them from the change in state over a whole dispatch
# (`notebook_file_of()`, `notifications()` in state.R), so no branch below
# has to remember to save or to notify.

# ---- Events ------------------------------------------------------------------
# One constructor per event. Every event has `type` and `at` (POSIXct,
# stamped by the shell). Worker events also carry `gen`; run events carry
# the run `token`.

event <- function(type, at, ...) {
  structure(list(type = type, at = at, ...), class = "ember_event")
}

#' A 36-character UUID (any version/variant, case-insensitive): the shape
#' `uuid()` (api.R) generates and the only shape a cell id is allowed to
#' have. Checked on every insert op before it reaches `state$cells`
#' (`reduce_apply()`): an id from the frontend is untrusted input, and a
#' non-UUID id (a stray `# ///` or `# %%` line, a newline, an empty string)
#' written into the notebook file as a cell's id corrupts the file's format.
is_uuid <- function(x) {
  is.character(x) && length(x) == 1 && !is.na(x) &&
    grepl("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", x)
}

# From the API
ev_open        <- function(at) event("open", at)
ev_allow       <- function(at) event("allow", at)
ev_apply       <- function(ops, at) event("apply", at, ops = ops)   # ops carry ids
ev_run         <- function(ids, at) event("run", at, ids = ids)     # NULL = all
ev_interrupt   <- function(at) event("interrupt", at)
ev_restart     <- function(at) event("restart", at)
ev_shutdown    <- function(at) event("shutdown", at)
ev_move        <- function(path, at) event("move", at, path = path)
ev_set_mode    <- function(mode, at) event("set_mode", at, mode = mode)
ev_render      <- function(cell, width, height, at, res = 96)
  event("render", at, cell = cell, width = width, height = height, res = res)
ev_show_more   <- function(cell, path, dim, at)
  event("show_more", at, cell = cell, path = path, dim = dim)

# From the shell's own IO
ev_files_read  <- function(files, at) event("files_read", at, files = files)  # path -> list(text, hash)
ev_save_failed <- function(message, at) event("save_failed", at, message = message)

# From the worker (built by `worker_event()` in shell.R from wire messages)
wk_started  <- function(gen, pid, at) event("wk_started", at, gen = gen, pid = pid)
wk_failed   <- function(gen, message, at) event("wk_failed", at, gen = gen, message = message)
wk_hello    <- function(gen, info, at) event("wk_hello", at, gen = gen, info = info)
wk_console  <- function(gen, token, item, at)
  event("wk_console", at, gen = gen, token = token, item = item)
wk_source   <- function(gen, token, path, text, at)
  event("wk_source", at, gen = gen, token = token, path = path, text = text)
wk_done     <- function(gen, token, report, at)
  event("wk_done", at, gen = gen, token = token, report = report)
wk_rendered <- function(gen, cell, display, at)
  event("wk_rendered", at, gen = gen, cell = cell, display = display)
wk_exited   <- function(gen, status, message, at)
  event("wk_exited", at, gen = gen, status = status, message = message)

#' From the shell's own periodic sampling (processx's `get_memory_info()`,
#' not a worker protocol message; ui-2.md, Worker memory). `rss` is bytes.
ev_worker_usage <- function(gen, rss, at) event("worker_usage", at, gen = gen, rss = rss)

# From timers the core asked for
tm_offer_restart <- function(gen, token, at)
  event("tm_offer_restart", at, gen = gen, token = token)

# ---- Effects -----------------------------------------------------------------
# Plain data. The shell's `run_effect()` is the only code that acts on them.

#' Equality for generations and tokens: `identical()` would treat `1` and
#' `1L` as different, which the wire format (or a test) can easily cross.
eq <- function(x, y) !is.null(x) && !is.null(y) && isTRUE(x == y)

effect <- function(type, ...) structure(list(type = type, ...), class = "ember_effect")

fx_start_worker <- function(gen, library, wd) effect("start_worker", gen = gen, library = library, wd = wd)
fx_kill_worker  <- function(gen) effect("kill_worker", gen = gen)
fx_interrupt    <- function(gen) effect("interrupt", gen = gen)              # SIGINT
fx_send         <- function(gen, msg) effect("send", gen = gen, msg = msg)  # msg: worker protocol, see worker.R
fx_timer        <- function(delay, event) effect("timer", delay = delay, event = event)
fx_read_files   <- function(paths) effect("read_files", paths = paths)
fx_move_file    <- function(from, to) effect("move_file", from = from, to = to)
fx_close        <- function() effect("close")

# A reply for the caller of the API function that dispatched the event.
refused <- function(reason, op = NULL) {
  structure(class = c("ember_refused", "error", "condition"),
            list(message = reason, call = NULL, op = op))
}

# ---- step --------------------------------------------------------------------

#' Advance the session by one event.
#'
#' @return `list(state, effects, reply)`. `reply` is `NULL` except for
#'   events dispatched by an API call that returns something (apply, run,
#'   allow, restart, shutdown, move).
#'
#' Shape: `reduce()` applies the event; `schedule()` then moves the worker
#' and the queue forward from whatever state resulted (start a worker, send
#' the next cell); `missing_file_reads()` asks for sourced files the graph
#' wants and the state lacks. Splitting it this way means no event handler
#' starts a run itself: whichever event frees the worker or adds to
#' `pending`, the same `schedule()` decides what runs next.
#'
#' Idempotence: worker events from an old generation or with a stale token
#' change nothing; timers carry the token they were set for; running
#' `step()` twice on a duplicated worker event is a no-op the second time.
step <- function(state, event) {
  if (isTRUE(state$closed)) return(list(state = state, effects = list(), reply = NULL))
  state$clock <- event$at
  r <- reduce(state, event)
  pk <- schedule_packages(r$state, old = state)
  s <- schedule(pk$state)
  reads <- missing_file_reads(s$state)
  new <- s$state
  if (!identical(new, state)) new$seq <- state$seq + 1L
  reply <- r$reply
  # `reduce_apply()` reports the `seq` its edit will take effect at before
  # `step()` has decided whether anything actually changed (a true no-op,
  # e.g. folding a cell to the fold it already has, leaves `seq` where it
  # was). Patching it here, after that decision, is simpler than every
  # reducer predicting it.
  if (is.list(reply) && !is.null(reply$seq)) reply$seq <- new$seq
  list(state = new, effects = c(r$effects, pk$effects, s$effects, reads), reply = reply)
}

reduce <- function(state, event) {
  switch(event$type,
    open             = list(state = state, effects = list(), reply = NULL),
    allow            = reduce_allow(state, event),
    apply            = reduce_apply(state, event),
    run              = reduce_run(state, event),
    interrupt        = reduce_interrupt(state, event),
    restart          = reduce_restart(state, event),
    shutdown         = reduce_shutdown(state, event),
    move             = reduce_move(state, event),
    set_mode         = reduce_set_mode(state, event),
    render           = reduce_render(state, event),
    show_more        = reduce_show_more(state, event),
    files_read       = reduce_files_read(state, event),
    save_failed      = reduce_save_failed(state, event),
    wk_started       = reduce_wk_started(state, event),
    wk_failed        = reduce_wk_failed(state, event),
    wk_hello         = reduce_wk_hello(state, event),
    wk_console       = reduce_wk_console(state, event),
    wk_source        = reduce_wk_source(state, event),
    wk_done          = reduce_wk_done(state, event),
    wk_rendered      = reduce_wk_rendered(state, event),
    wk_exited        = reduce_wk_exited(state, event),
    worker_usage     = reduce_worker_usage(state, event),
    tm_offer_restart = reduce_offer_restart(state, event),
    preview_date     = reduce_preview_date(state, event),
    set_date         = reduce_set_date(state, event),
    index_fetched    = reduce_index_fetched(state, event),
    index_failed     = reduce_index_failed(state, event),
    library_checked  = reduce_library_checked(state, event),
    install_progress = reduce_install_progress(state, event),
    install_done     = reduce_install_done(state, event),
    stop("unknown event type: ", event$type)
  )
}

# ---- Scheduling --------------------------------------------------------------

#' Move the worker and the queue forward. Pure; called after every event.
#'
#' If execution isn't allowed, or the notebook is read-only, nothing moves.
#' A worker that is `"off"`, or `"stopped"` with something pending, is
#' (re)started; a stopped worker with nothing pending stays stopped, so a
#' notebook that crashes the worker on load can't loop. Otherwise, while the
#' worker is `"ready"`, the first runnable cell of the pending set (in run
#' order) is sent, dropping blocked cells from the queue as they are found.
schedule <- function(state) {
  if (!isTRUE(state$allowed) || isTRUE(state$read_only)) {
    return(list(state = state, effects = list()))
  }
  # A conflicting library switch is waiting for the running cell to finish
  # (switch_library() in packages-core.R): send nothing new meanwhile, so no
  # further cell loads the version about to be replaced.
  if (switch_pending(state)) return(list(state = state, effects = list()))
  w <- state$worker
  if (identical(w$status, "off") ||
      (identical(w$status, "stopped") && length(state$pending) > 0)) {
    gen <- w$gen + 1L
    state$worker$status <- "starting"
    state$worker$gen <- gen
    state$worker$running <- NULL
    state$worker$interrupt <- NULL
    state$worker$restart_offered <- FALSE
    # The worker that answers `gen` has nothing loaded yet; a stale value
    # here (left by whatever worker just stopped) would read as a version
    # conflict the moment the new one reports anything, restarting it for a
    # phantom reason (packages-core.R, `switch_library()`'s mismatch check).
    state$worker$loaded <- character()
    return(list(state = state,
               effects = list(fx_start_worker(gen, state$packages$active$path, dirname(state$path)))))
  }
  if (!identical(w$status, "ready")) return(list(state = state, effects = list()))

  id <- NULL
  fblocked <- failed_blockers(state)
  waiting <- waiting_cells(state)
  # A target library that failed can never bring in the packages these
  # cells are waiting for; drop them from `pending` instead of leaving them
  # queued forever (packages-core.R, waiting_cells()).
  if (identical(state$packages$target$status, "failed") && length(waiting) > 0) {
    state$pending <- setdiff(state$pending, names(waiting))
    waiting <- list()
  }
  repeat {
    queue <- run_order(state$graph, state$pending)
    if (length(queue) == 0) return(list(state = state, effects = list()))
    candidate <- queue[1]
    if (!is.null(waiting[[candidate]])) {
      # Leave it queued (it isn't blocked, just not ready yet) and look
      # further down the queue for something that can run now, dropping
      # anything else along the way that can't (same rule as below).
      found <- NULL
      for (q in queue[-1]) {
        if (!is.null(waiting[[q]])) next
        if (can_run(state, q, fblocked)) { found <- q; break }
        state$pending <- setdiff(state$pending, q)
      }
      if (is.null(found)) return(list(state = state, effects = list()))
      id <- found
      break
    }
    if (can_run(state, candidate, fblocked)) { id <- candidate; break }
    state$pending <- setdiff(state$pending, candidate)
  }

  token <- state$next_token
  state$next_token <- state$next_token + 1L
  state$pending <- setdiff(state$pending, id)
  state$computed_sources[[id]] <- NULL
  prev <- state$results[[id]]
  state <- invalidate_dependents(state, id, if (!is.null(prev)) prev$defined else character())
  state$worker$status <- "busy"
  state$worker$running <- list(cell = id, token = token, code = state$cells[[id]]$code,
                               started_at = state$clock, console = list())
  list(state = state, effects = list(fx_send(state$worker$gen, run_message(state, id, token))))
}

#' Can `id` run now? Not if it is markdown, has a graph error, has an
#' ancestor with a graph error (`blocked_cells()` and their downstream), or
#' has an ancestor whose last result errored or was interrupted (engine.md,
#' Decisions: "dependents of a cell that errored don't run"). A cell dropped
#' from the queue the moment its ancestor fails is handled by
#' `drop_downstream()`; this check is for a cell added back to `pending`
#' later (autorun rerunning an unrelated ancestor, or a fresh `ev_run`)
#' while the failure still stands.
#'
#' `blocked_by_failed`: the `failed_blockers()` map, passed in by callers
#' that check many ids against the same state so the (usually empty) set of
#' failed cells is found once rather than per id.
can_run <- function(state, id, blocked_by_failed = NULL) {
  cell <- state$cells[[id]]
  if (is.null(cell) || identical(cell$kind, "markdown")) return(FALSE)
  blocked <- blocked_cells(state$graph)
  if (id %in% blocked) return(FALSE)
  down <- unlist(lapply(blocked, function(b) downstream(state$graph, b, transitive = TRUE)),
                 use.names = FALSE)
  if (id %in% down) return(FALSE)
  if (is.null(blocked_by_failed)) blocked_by_failed <- failed_blockers(state)
  is.null(blocked_by_failed[[id]])
}

#' Map id -> id of the ancestor whose last result errored or was
#' interrupted, for every cell downstream of such a cell. One
#' `downstream()` walk per failed cell (usually none), reused by every `id`
#' checked against the same state rather than walking upstream from each one.
failed_blockers <- function(state) {
  failed <- Filter(function(fid) {
    r <- state$results[[fid]]
    !is.null(r) && r$status %in% c("error", "interrupted")
  }, names(state$results))
  out <- list()
  for (f in failed) {
    for (d in downstream(state$graph, f, transitive = TRUE)) {
      if (is.null(out[[d]])) out[[d]] <- f
    }
  }
  out
}

#' The worker's `run` message for `id`. See the protocol in worker.R.
#'
#' `list(type = "run", cell, token, code, role = "setup" | "cell",
#' order = <code cell ids in run order>, formulas = graph$analyses[[id]]$formulas,
#' library = state$packages$active$path)`.
#' `order` is what the worker rebuilds the search path from (attaching
#' cells' packages in file order); sending it with every run keeps the
#' worker converging on the current order without a separate sync. `library`
#' is sent the same way: the worker calls `.libPaths()` when it differs from
#' its own, so a newly installed package is picked up with no restart
#' (packages-core.R, "The worker follows the library").
run_message <- function(state, id, token) {
  order <- Filter(function(i) identical(state$cells[[i]]$kind, "code"), state$graph$order)
  list(type = "run", cell = id, token = token, code = state$cells[[id]]$code,
      role = if (identical(id, state$setup)) "setup" else "cell",
      order = order, formulas = state$graph$analyses[[id]]$formulas,
      library = state$packages$active$path)
}

#' Cells that need to run before `id` can: its transitive upstream that is
#' not fresh. Fresh = has a result with status "ok", not stale, and
#' `code` equal to the current code.
unfresh_ancestors <- function(state, id) {
  anc <- upstream(state$graph, id, transitive = TRUE)
  Filter(function(a) !is_fresh(state, a), anc)
}

#' Transitive upstream of every id in `ids`, as one walk: each node is
#' visited at most once regardless of how many of `ids` it is an ancestor
#' of. `reduce_run()` uses this instead of calling `unfresh_ancestors()`
#' (and so `upstream(..., transitive = TRUE)`) once per requested id, which
#' made "run all" quadratic in the number of cells.
upstream_of_set <- function(graph, ids) {
  seen <- character()
  visit <- function(i) {
    for (u in graph$upstream[[i]]) {
      if (!(u %in% seen)) {
        seen <<- c(seen, u)
        visit(u)
      }
    }
  }
  for (id in ids) visit(id)
  run_order(graph, seen)
}

#' Has a result with status "ok", not stale, matching the current code.
is_fresh <- function(state, id) {
  r <- state$results[[id]]
  !is.null(r) && identical(r$status, "ok") && !isTRUE(r$stale) &&
    identical(r$code, state$cells[[id]]$code)
}

#' Mark the dependents of a cell that is about to run (or just learned new
#' definitions) as invalid.
#'
#' Dependents: `downstream(graph, id, transitive = TRUE)` plus the cells
#' whose references include any of `names` (what the cell's previous run
#' defined; a cell that read a name the edit removed has no edge any more
#' but its result was computed from that name), plus their transitive
#' downstream. Only cells with a result are touched: a cell that hasn't run
#' stays not run, in both modes.
#'
#' Every touched result gets `stale = TRUE`. In autorun, and when `queue` is
#' `TRUE`, they are also added to `pending`; running clears `stale`. In lazy
#' they stay stale until run. So "dropped from the queue without running"
#' (an interrupt, an upstream error) leaves a cell correctly stale with no
#' extra code.
#'
#' `queue = FALSE` is for an edit (including delete): engine.md's Decisions
#' say an edit never runs anything, in either mode, so deleting a cell marks
#' its dependents stale without adding them to `pending` even in autorun.
#' The default (`TRUE`) is for a cell about to run or one that just finished,
#' where autorun queuing dependents is the whole point of the mode.
#'
#' This replaces step 1's `affected(old, new)` here: the session doesn't
#' keep the graph from before an edit, because what matters is what the
#' worker's globals came from, which `results[[id]]$defined` records
#' directly.
invalidate_dependents <- function(state, id, names, queue = TRUE) {
  dependents <- downstream(state$graph, id, transitive = TRUE)
  if (length(names) > 0) {
    readers <- Filter(function(cid) {
      !identical(cid, id) && length(intersect(names, state$graph$cells[[cid]]$references)) > 0
    }, state$graph$ids)
    extra <- unlist(lapply(readers, function(r) {
      c(r, downstream(state$graph, r, transitive = TRUE))
    }), use.names = FALSE)
    dependents <- union(dependents, extra)
  }
  dependents <- setdiff(dependents, id)

  autorun <- identical(state$file$header$on_cell_change, "autorun")
  for (cid in dependents) {
    r <- state$results[[cid]]
    if (is.null(r)) next
    r$stale <- TRUE
    state$results[[cid]] <- r
    if (queue && autorun && isTRUE(state$allowed) && identical(state$cells[[cid]]$kind, "code")) {
      state$pending <- union(state$pending, cid)
    }
  }
  state
}

#' After a cell fails or is interrupted: remove its transitive downstream
#' from `pending`. They keep (or get) `stale = TRUE`.
drop_downstream <- function(state, id) {
  down <- downstream(state$graph, id, transitive = TRUE)
  state$pending <- setdiff(state$pending, down)
  for (cid in down) {
    r <- state$results[[cid]]
    if (!is.null(r)) {
      r$stale <- TRUE
      state$results[[cid]] <- r
    }
  }
  state
}

#' Rebuild the graph after `cells`, `setup`, `exports` or `files` changed.
#' The only place `state$graph` is assigned besides `graph_learn()` calls
#' in `reduce_wk_done()`/`reduce_wk_source()`.
#'
#' Keeps the previous `graph` object when the rebuild is equal to it apart
#' from `read_file` (a closure freshly made over `state$files` on every
#' call, so never `identical()` to the old one even when nothing a graph
#' build depends on actually changed) and `reread`. Without this, a no-op
#' edit (an `apply` that changes nothing observable, e.g. folding a cell to
#' the fold it already has) would still replace `state$graph` with an
#' unequal-by-identity copy, so `step()`'s `!identical(new, state)` check
#' would advance `seq` and `notifications()` would see the whole state as
#' changed for no real reason.
rebuild_graph <- function(state) {
  new_graph <- notebook_graph(code_of(state$cells), setup = state$setup,
                              exports = exports_of(state),
                              learned = state$graph$learned,
                              previous = state$graph,
                              read_file = reader_of(state$files))
  old_cmp <- state$graph; old_cmp$read_file <- NULL; old_cmp$reread <- NULL
  new_cmp <- new_graph; new_cmp$read_file <- NULL; new_cmp$reread <- NULL
  if (!identical(old_cmp, new_cmp)) state$graph <- new_graph
  state
}

#' Ask the shell for sourced files the graph references but `files` lacks.
#' Returns `list(fx_read_files(paths))` or `list()`.
missing_file_reads <- function(state) {
  wanted <- watched_files(state)
  missing <- Filter(function(p) is.null(state$files[[p]]), wanted)
  if (length(missing) == 0) return(list())
  list(fx_read_files(missing))
}

# ---- API events --------------------------------------------------------------

#' Allow execution. Reply: `TRUE` if it was already allowed.
#' `schedule()` starts the worker. Also records the running R version into
#' the header when it differs (design.md, Decisions: "records the new
#' version once the user runs the notebook on it"), so a notebook written on
#' one R and reopened on another doesn't silently claim the wrong one.
reduce_allow <- function(state, event) {
  reply <- isTRUE(state$allowed)
  state$allowed <- TRUE
  state <- record_r_version(state)
  list(state = state, effects = list(), reply = reply)
}

#' Record the running R version into the header when it differs
#' (design.md, Decisions: "records the new version once the user runs the
#' notebook on it"), so a notebook written on one R and reopened on another
#' doesn't silently claim the wrong one. Shared by `reduce_allow()` (the
#' "Allow execution" button) and `reduce_run()` (asking to run cells also
#' allows execution, and must record the version the same way allow does).
record_r_version <- function(state) {
  r_version <- state$options$r$version
  if (!is.null(r_version) && !identical(state$file$header$r_version, r_version)) {
    state$file$header$r_version <- r_version
  }
  state
}

#' Normalise code the way the file format requires: trailing blank lines
#' dropped, "\r\n" turned into "\n", so a save round-trips byte for byte.
normalise_code <- function(code) {
  code <- gsub("\r\n", "\n", code, fixed = TRUE)
  lines <- strsplit(code, "\n", fixed = TRUE)[[1]]
  while (length(lines) > 0 && grepl("^\\s*$", lines[length(lines)])) {
    lines <- lines[-length(lines)]
  }
  paste(lines, collapse = "\n")
}

#' Apply a batch of edit ops atomically.
#'
#' Ops are plain lists: `set_code(cell, code, expected)`, `insert(id, index,
#' code, kind)` (the id is assigned by the caller, outside the pure core, so
#' `step()` stays deterministic), `delete(cell)`, `move(cell, index)`,
#' `fold(cell, folded)`.
#'
#' Every op is validated against the cells as they will be when it applies;
#' the first failure refuses the whole batch and returns `state` untouched.
#' Edits never run anything and never mark anything stale by themselves:
#' until a cell runs, every other result still matches the globals in the
#' worker. The edited cell shows `code_differs`.
reduce_apply <- function(state, event) {
  if (isTRUE(state$read_only)) {
    return(list(state = state, effects = list(), reply = refused("notebook is read-only")))
  }
  ops <- event$ops
  cells <- state$cells
  header <- state$file$header
  inserted <- character()
  deleted <- character()

  for (op in ops) {
    bad <- NULL
    if (identical(op$op, "set_code")) {
      if (!(op$cell %in% names(cells))) {
        bad <- refused(sprintf("unknown cell %s", op$cell), op)
      } else {
        code <- normalise_code(op$code)
        if (!is.null(op$expected) &&
            !identical(normalise_code(op$expected), cells[[op$cell]]$code)) {
          bad <- refused(sprintf("%s's code has changed", op$cell), op)
        } else if (any(grepl("^# %%|^# ///", strsplit(code, "\n", fixed = TRUE)[[1]]))) {
          bad <- refused("code contains a cell or footer marker line", op)
        } else {
          cells[[op$cell]]$code <- code
        }
      }
    } else if (identical(op$op, "insert")) {
      if (!is_uuid(op$id)) {
        bad <- refused("cell id must be a UUID", op)
      } else if (op$id %in% names(cells)) {
        bad <- refused("id already used", op)
      } else if (op$index < 1 || op$index > length(cells) + 1) {
        bad <- refused("index out of range", op)
      } else {
        code <- normalise_code(op$code %||% "")
        if (any(grepl("^# %%|^# ///", strsplit(code, "\n", fixed = TRUE)[[1]]))) {
          bad <- refused("code contains a cell or footer marker line", op)
        } else {
          new_cell <- list(code = code, kind = op$kind %||% "code",
                           folded = identical(op$kind, "markdown"))
          cells <- append(cells, setNames(list(new_cell), op$id), after = op$index - 1)
          inserted <- c(inserted, op$id)
        }
      }
    } else if (identical(op$op, "delete")) {
      if (!(op$cell %in% names(cells))) {
        bad <- refused(sprintf("unknown cell %s", op$cell), op)
      } else if (identical(op$cell, state$setup)) {
        bad <- refused("cannot delete the setup cell; empty it instead", op)
      } else {
        deleted <- c(deleted, op$cell)
        cells[[op$cell]] <- NULL
      }
    } else if (identical(op$op, "move")) {
      if (!(op$cell %in% names(cells))) {
        bad <- refused(sprintf("unknown cell %s", op$cell), op)
      } else if (op$index < 1 || op$index > length(cells)) {
        bad <- refused("index out of range", op)
      } else {
        ord <- setdiff(names(cells), op$cell)
        ord <- append(ord, op$cell, after = op$index - 1)
        cells <- cells[ord]
      }
    } else if (identical(op$op, "fold")) {
      if (!(op$cell %in% names(cells))) {
        bad <- refused(sprintf("unknown cell %s", op$cell), op)
      } else {
        cells[[op$cell]]$folded <- isTRUE(op$folded)
      }
    } else if (identical(op$op, "add_extra_package")) {
      header$extra_packages <- sort(unique(c(header$extra_packages, op$name)))
    } else if (identical(op$op, "remove_extra_package")) {
      # Refused when the name is also named directly in code: removing it
      # from [extra_packages] would do nothing (schedule_packages() would
      # just put it back), so the refusal is a more honest answer than a
      # silent no-op.
      code_only_header <- header
      code_only_header$extra_packages <- character()
      code_wanted <- wanted_packages(state$graph, code_only_header)
      if (op$name %in% code_wanted) {
        bad <- refused(sprintf("%s is named in code; remove it there instead", op$name), op)
      } else {
        header$extra_packages <- setdiff(header$extra_packages, op$name)
      }
    } else {
      bad <- refused(sprintf("unknown op %s", op$op), op)
    }
    if (!is.null(bad)) return(list(state = state, effects = list(), reply = bad))
  }

  state$cells <- cells
  state$file$header <- header
  effects <- list()
  for (id in deleted) {
    old_result <- state$results[[id]]
    state$results[[id]] <- NULL
    state$computed_sources[[id]] <- NULL
    state$pending <- setdiff(state$pending, id)
    state <- invalidate_dependents(state, id,
                                   if (!is.null(old_result)) old_result$defined else character(),
                                   queue = FALSE)
    if (state$worker$status %in% c("starting", "ready", "busy")) {
      order <- Filter(function(i) {
        !is.null(state$cells[[i]]) && identical(state$cells[[i]]$kind, "code")
      }, state$graph$order)
      effects <- c(effects, list(fx_send(state$worker$gen,
                                         list(type = "remove_cell", cell = id, order = order))))
    }
  }
  state <- rebuild_graph(state)
  list(state = state, effects = effects,
      reply = list(inserted = inserted, seq = state$seq + 1L))
}

#' Ask to run cells.
#'
#' Also retries a failed target library once, and any failed index whose
#' wanted set hasn't changed: `schedule_packages()`'s install and resolve
#' stages don't loop on a broken package by themselves (no retry storm while
#' offline), but asking to run again is "I want this to work now", the same
#' way a stopped worker restarts only when something is asked to run.
reduce_run <- function(state, event) {
  if (isTRUE(state$read_only)) {
    return(list(state = state, effects = list(), reply = refused("notebook is read-only")))
  }
  state$allowed <- TRUE
  state <- record_r_version(state)
  if (identical(state$packages$target$status, "failed")) {
    state$packages$target$status <- "missing"
    state$packages$target$message <- NULL
    state$packages$target$log <- character()
  }
  failed_keys <- Filter(function(k) identical(state$packages$indexes[[k]]$status, "failed"),
                        names(state$packages$indexes))
  for (k in failed_keys) state$packages$indexes[[k]] <- NULL
  code_ids <- Filter(function(i) identical(state$cells[[i]]$kind, "code"), names(state$cells))
  ids <- event$ids %||% code_ids
  ids <- ids[ids %in% names(state$cells)]
  ancestors <- upstream_of_set(state$graph, ids)
  unfresh <- Filter(function(a) !is_fresh(state, a), ancestors)
  want <- union(unfresh, ids)
  fblocked <- failed_blockers(state)
  skipped <- Filter(function(id) !can_run(state, id, fblocked), want)
  to_add <- setdiff(want, skipped)
  state$pending <- union(state$pending, to_add)
  reply <- list(accepted = TRUE, queued = run_order(state$graph, state$pending), skipped = skipped)
  list(state = state, effects = list(), reply = reply)
}

#' Interrupt.
reduce_interrupt <- function(state, event) {
  state$pending <- character()
  effects <- list()
  w <- state$worker
  if (identical(w$status, "busy")) {
    effects <- list(fx_interrupt(w$gen))
    if (is.null(w$interrupt)) {
      state$worker$interrupt <- list(at = state$clock, token = w$running$token)
      effects <- c(effects, list(fx_timer(state$options$grace,
                                          tm_offer_restart(w$gen, w$running$token, at = NA))))
    }
  }
  list(state = state, effects = effects, reply = NULL)
}

#' Restart the worker. Refused in safe preview.
reduce_restart <- function(state, event) {
  if (isTRUE(state$read_only)) {
    return(list(state = state, effects = list(), reply = refused("notebook is read-only")))
  }
  if (!isTRUE(state$allowed)) {
    return(list(state = state, effects = list(),
               reply = refused("safe preview: nothing to restart")))
  }
  r <- restart_worker(state, reason = NULL)
  list(state = r$state, effects = r$effects, reply = TRUE)
}

#' Kill and restart the worker: a fresh generation, no running cell, every
#' result cleared and nothing left pending (every cell shows not run).
#' Shared by `reduce_restart()` and `switch_library()` (packages-core.R),
#' which calls this when a ready target library changes the version of a
#' namespace the worker has loaded. `reason`, when given, becomes
#' `worker$exit$message`, so the snapshot says why every cell is not run
#' ("dplyr changed 1.1.4 -> 1.2.1; R restarted").
restart_worker <- function(state, reason = NULL) {
  w <- state$worker
  effects <- list()
  if (w$status %in% c("starting", "ready", "busy")) effects <- list(fx_kill_worker(w$gen))
  gen <- w$gen + 1L
  state$worker <- structure(list(status = "starting", gen = gen, running = NULL,
                                 interrupt = NULL, restart_offered = FALSE,
                                 info = NULL,
                                 exit = if (!is.null(reason)) list(status = NA_integer_, message = reason) else NULL,
                                 loaded = character()),
                            class = "ember_worker_state")
  effects <- c(effects, list(fx_start_worker(gen, state$packages$active$path, dirname(state$path))))
  state$results <- list()
  state$pending <- character()
  list(state = state, effects = effects)
}

#' Shut down: kill the worker, close the shell. Reply: `!allowed`.
#' An install still running is left for the shell's job table (library.R):
#' this session no longer cares (`fx_cancel_install`), but another session
#' wanting the same library keeps the job alive. Any index fetch still
#' "fetching" gets the same treatment (`fx_cancel_fetch_index`): leaving
#' this session's subscription in place would keep a closed session
#' referenced in the job's subscriber list, and the fetch running (or its
#' subprocess never reaped) for no subscriber that can still hear about it.
reduce_shutdown <- function(state, event) {
  reply <- !isTRUE(state$allowed)
  w <- state$worker
  effects <- list()
  if (w$status %in% c("starting", "ready", "busy")) effects <- list(fx_kill_worker(w$gen))
  if (!is.null(state$packages$install)) {
    effects <- c(effects, list(fx_cancel_install(state$packages$install$token, state$packages$install$key,
                                                 state$packages$install$path)))
  }
  fetching <- Filter(function(k) identical(state$packages$indexes[[k]]$status, "fetching"),
                     names(state$packages$indexes))
  for (k in fetching) {
    effects <- c(effects, list(fx_cancel_fetch_index(k, repo_url(state$options$repos, k))))
  }
  effects <- c(effects, list(fx_close()))
  state$closed <- TRUE
  list(state = state, effects = effects, reply = reply)
}

#' Move: `path` changes; `fx_move_file(old, new)`. The shell moves the file
#' before it compares the file text, so no second copy is written.
reduce_move <- function(state, event) {
  old_path <- state$path
  state$path <- event$path
  list(state = state, effects = list(fx_move_file(old_path, event$path)), reply = event$path)
}

reduce_set_mode <- function(state, event) {
  state$file$header$on_cell_change <- event$mode
  list(state = state, effects = list(), reply = NULL)
}

#' Re-render a plot at a new size and pixel density: `fx_send(render)` if
#' the cell's output is an image and the worker is alive; the answer comes
#' as `wk_rendered`.
reduce_render <- function(state, event) {
  r <- state$results[[event$cell]]
  alive <- state$worker$status %in% c("ready", "busy")
  if (is.null(r) || is.null(r$output) || !identical(r$output$mime, "image/png") || !alive) {
    return(list(state = state, effects = list(), reply = NULL))
  }
  msg <- list(type = "render", cell = event$cell, width = event$width, height = event$height,
             res = event$res %||% 96)
  list(state = state, effects = list(fx_send(state$worker$gen, msg)), reply = NULL)
}

#' "more" paging, for a table or tree output (ui-2.md, 3c): `fx_send(more)`
#' if the cell's output is a table or tree and the worker is alive;
#' otherwise nothing. `dim` is 1 (rows or items) or 2 (columns). The answer
#' comes as a `rendered` message (`wk_rendered`/`reduce_wk_rendered()`),
#' same as a plot re-render.
reduce_show_more <- function(state, event) {
  r <- state$results[[event$cell]]
  alive <- state$worker$status %in% c("ready", "busy")
  pageable <- !is.null(r) && !is.null(r$output) &&
    r$output$mime %in% c("application/vnd.ember.table", "application/vnd.ember.tree")
  if (!pageable || !alive) return(list(state = state, effects = list(), reply = NULL))
  msg <- list(type = "more", cell = event$cell, path = event$path, dim = event$dim)
  list(state = state, effects = list(fx_send(state$worker$gen, msg)), reply = NULL)
}

#' Sourced files arrived (first read, or the watcher saw a change).
reduce_files_read <- function(state, event) {
  changed_paths <- Filter(function(p) {
    old <- state$files[[p]]
    !is.null(old) && !isTRUE(identical(old$hash, event$files[[p]]$hash))
  }, names(event$files))

  state$files <- utils::modifyList(state$files, event$files)
  state <- rebuild_graph(state)

  if (length(changed_paths) > 0) {
    autorun <- identical(state$file$header$on_cell_change, "autorun")
    for (id in state$graph$ids) {
      a <- state$graph$analyses[[id]]
      lit <- if (!is.null(a$sourced) && nrow(a$sourced) > 0) a$sourced$path else character()
      comp <- state$computed_sources[[id]] %||% character()
      if (length(intersect(c(lit, comp), changed_paths)) == 0) next
      r <- state$results[[id]]
      if (is.null(r)) next
      r$stale <- TRUE
      state$results[[id]] <- r
      if (autorun && isTRUE(state$allowed)) state$pending <- union(state$pending, id)
      # design.md: a sourced-file change marks the cell *and its
      # dependents* stale (autorun also queues them), not the sourcing
      # cell alone.
      state <- invalidate_dependents(state, id, character())
    }
  }
  list(state = state, effects = list(), reply = NULL)
}

#' A save failed: kept in `problems` so the snapshot shows it. The next
#' change tries again (the shell compares against the last text written,
#' which a failed write didn't update).
reduce_save_failed <- function(state, event) {
  row <- data.frame(kind = "save_failed", detail = event$message, stringsAsFactors = FALSE)
  state$problems <- if (is.null(state$problems) || nrow(state$problems) == 0) {
    row
  } else {
    rbind(state$problems, row)
  }
  list(state = state, effects = list(), reply = NULL)
}

# ---- Worker events -----------------------------------------------------------

reduce_wk_started <- function(state, event) {
  if (!eq(event$gen, state$worker$gen)) return(list(state = state, effects = list(), reply = NULL))
  state$worker$info <- list(pid = event$pid)
  list(state = state, effects = list(), reply = NULL)
}

#' The worker couldn't start (no Rscript, port in use). status "stopped",
#' exit message kept, pending cleared.
reduce_wk_failed <- function(state, event) {
  if (!eq(event$gen, state$worker$gen)) return(list(state = state, effects = list(), reply = NULL))
  state$worker$status <- "stopped"
  state$worker$running <- NULL
  state$worker$exit <- list(status = NA_integer_, message = event$message)
  state$pending <- character()
  # No process ever started: whatever `loaded` recorded belongs to a worker
  # that no longer exists, and would otherwise look like a conflict against
  # `active` the moment any later event runs `switch_library()`.
  state$worker$loaded <- character()
  list(state = state, effects = list(), reply = NULL)
}

#' gen check; status "ready"; info kept.
reduce_wk_hello <- function(state, event) {
  if (!eq(event$gen, state$worker$gen)) return(list(state = state, effects = list(), reply = NULL))
  state$worker$status <- "ready"
  state$worker$info <- event$info
  state$worker$loaded <- event$info$loaded %||% character()
  list(state = state, effects = list(), reply = NULL)
}

#' gen and token check; append the item to `worker$running$console`.
reduce_wk_console <- function(state, event) {
  w <- state$worker
  if (!eq(event$gen, w$gen) || is.null(w$running) ||
      !eq(event$token, w$running$token)) {
    return(list(state = state, effects = list(), reply = NULL))
  }
  state$worker$running$console <- c(w$running$console, list(event$item))
  list(state = state, effects = list(), reply = NULL)
}

#' The worker asks before a computed `source()` runs its file.
reduce_wk_source <- function(state, event) {
  w <- state$worker
  if (!eq(event$gen, w$gen) || is.null(w$running) ||
      !eq(event$token, w$running$token)) {
    return(list(state = state, effects = list(), reply = NULL))
  }
  id <- w$running$cell
  a <- read_cell(event$text)
  defs <- definitions_of(a)

  owner_of <- function(n) {
    Find(function(cid) !identical(cid, id) && n %in% state$graph$cells[[cid]]$definitions,
        state$graph$ids)
  }
  clash <- character()
  owner <- NULL
  for (n in defs) {
    o <- owner_of(n)
    if (!is.null(o)) { clash <- n; owner <- o; break }
  }

  if (length(clash) > 0) {
    msg <- sprintf("%s defines %s, which cell %s defines", basename(event$path), clash, owner)
    # The worker raises an R error with this exact message when the denial
    # stops the `source()` call; `reduce_wk_done()` matches it against
    # `w$running$refused_source` to report it as `"source_conflict"`
    # instead of a plain `"error"`.
    state$worker$running$refused_source <- msg
    effects <- list(fx_send(w$gen, list(type = "source_reply", allow = FALSE, message = msg)))
    return(list(state = state, effects = effects, reply = NULL))
  }

  # The worker asks before *every* `source()`, literal or computed, with
  # the path run through `normalizePath()`. A literal one is already
  # tracked (as written in the code) in `graph$analyses[[id]]$sourced`; only
  # a path the static analysis couldn't see (built at run time) is new
  # information worth recording here. Recording it again under its
  # normalized form would duplicate the one footer line as two.
  analysis <- state$graph$analyses[[id]]
  literal <- if (!is.null(analysis$sourced) && nrow(analysis$sourced) > 0) {
    vapply(analysis$sourced$path, function(p) literal_source_path_abs(state, p), character(1))
  } else {
    character()
  }
  if (!(event$path %in% literal)) {
    stored <- relative_to_notebook(state, event$path)
    state$computed_sources[[id]] <- union(state$computed_sources[[id]] %||% character(), stored)
    # No `state$files[[stored]]` entry yet: leaving it unset is what makes
    # `missing_file_reads()` ask the shell to read and hash the file, so a
    # computed source gets the same real hash a literal one does instead of
    # an `NA` written straight to the footer.
  }
  prev_learned <- state$graph$learned$definitions[[id]] %||% character()
  state$graph <- graph_learn(state$graph, id, definitions = union(prev_learned, defs))
  effects <- list(fx_send(w$gen, list(type = "source_reply", allow = TRUE)))
  list(state = state, effects = effects, reply = NULL)
}

#' A literal `source()` path (as `read_cell()` parsed it, relative to the
#' notebook's folder unless already absolute), resolved to the same
#' absolute form the worker's normalized `wk_source` path arrives in, for
#' comparison. Mirrors shell.R's `is_absolute_path()` classification but
#' does no filesystem IO, so the core stays pure.
literal_source_path_abs <- function(state, p) {
  if (is_absolute_path(p)) p else file.path(dirname(state$path), p)
}

#' `path` relative to the notebook's folder when it falls inside it, else
#' unchanged. String comparison only (no filesystem access): this is how a
#' computed source's path is stored, matching the convention literal
#' sourced paths are already written in.
relative_to_notebook <- function(state, path) {
  base <- sub("/+$", "", dirname(state$path))
  prefix <- paste0(base, "/")
  if (startsWith(path, prefix)) substring(path, nchar(prefix) + 1) else path
}

#' A cell finished. This is where the worker's facts become graph facts.
reduce_wk_done <- function(state, event) {
  w <- state$worker
  if (!eq(event$gen, w$gen) || is.null(w$running) ||
      !eq(event$token, w$running$token)) {
    return(list(state = state, effects = list(), reply = NULL))
  }
  id <- w$running$cell
  report <- event$report

  if (!(id %in% names(state$cells))) {
    # The cell was deleted while it was running: `reduce_apply()` already
    # sent `remove_cell` and dropped its result. There is nothing left to
    # learn or invalidate for an id that no longer exists; just free the
    # worker so the next pending cell can go.
    state$worker$status <- "ready"
    state$worker$running <- NULL
    state$worker$interrupt <- NULL
    state$worker$restart_offered <- FALSE
    return(list(state = state, effects = list(), reply = NULL))
  }

  if (!is.null(report$attached) && length(report$attached) > 0) {
    state$exports <- utils::modifyList(state$exports, report$attached)
    state <- rebuild_graph(state)  # graph_learn() below would otherwise keep the old exports
  }

  if (!is.null(report$loaded) && length(report$loaded) > 0) {
    loaded <- state$worker$loaded
    loaded[names(report$loaded)] <- report$loaded
    state$worker$loaded <- loaded
  }

  error <- NULL
  if (!is.null(report$error)) {
    err <- report$error
    if (is.character(err)) err <- list(message = err)
    if (!is.null(err$package)) {
      # R's own packageNotFoundError, not a message match (works in every
      # locale): packages-core.R's missing_package_error() both classifies
      # it and, when the active library claims the package is installed,
      # marks the library to be checked again (another process may have
      # cleaned it).
      mp <- missing_package_error(state, err$package)
      state <- mp$state
      error <- mp$error
    } else {
      msg <- err$message %||% "error"
      # A denied computed `source()` makes the worker raise an R error whose
      # message is exactly what `reduce_wk_source()` sent back; recognising it
      # here reports the real cause (`source_conflict`) instead of a plain
      # `error`.
      kind <- if (!is.null(w$running$refused_source) &&
                 identical(msg, w$running$refused_source)) "source_conflict" else "error"
      error <- new_run_error(kind, message = msg, traceback = err$traceback %||% character())
    }
  } else {
    changed_removed <- union(report$changed %||% character(), report$removed %||% character())
    owners <- unique(unlist(lapply(changed_removed, function(n) {
      Find(function(cid) !identical(cid, id) && n %in% state$graph$cells[[cid]]$definitions,
          state$graph$ids)
    }), use.names = FALSE))
    if (length(owners) > 0) {
      error <- new_run_error("multiple_definitions",
        message = sprintf("%s changed a global defined elsewhere.", paste(changed_removed, collapse = ", ")),
        names = changed_removed,
        fixes = sprintf("Move the line into the cell that defines %s, or name the result (%s2 <- ...)",
                        changed_removed[1], changed_removed[1]))
    } else if (length(report$settings %||% list()) > 0 && !identical(id, state$setup)) {
      error <- new_run_error("global_setting",
        message = "This cell changes a global setting outside the setup cell.",
        fixes = "Move it to the setup cell, or use withr::with_options() for one piece of code")
    }
  }
  status <- if (!is.null(error)) "error" else (report$status %||% "ok")

  static_defs <- definitions_of(state$graph$analyses[[id]])
  reported_defs <- setdiff(report$created %||% character(), static_defs)
  cur_defs <- state$graph$learned$definitions[[id]] %||% character()
  cur_refs <- state$graph$learned$references[[id]] %||% character()
  # An errored or interrupted run's `created` is only what ran before the
  # failure stopped it, not the full set the cell's code defines when it
  # succeeds: keep the existing learned definitions (union with anything
  # new) rather than replacing them with that partial list. Only a
  # successful run's report is trusted as the complete picture.
  learned_defs <- if (identical(status, "ok")) reported_defs else union(cur_defs, reported_defs)
  # graph_learn() rebuilds the whole graph, so it's only worth calling when
  # it would actually change something: most cells report nothing new to
  # learn on every run, and a 2000-cell rebuild on every wk_done would blow
  # the per-event time budget for no reason.
  defs_changed <- !setequal(cur_defs, learned_defs)
  refs_changed <- !is.null(report$formula_misses) && !setequal(cur_refs, report$formula_misses)
  if (defs_changed || refs_changed) {
    state$graph <- graph_learn(state$graph, id,
                               definitions = if (defs_changed) learned_defs else NULL,
                               references = if (refs_changed) report$formula_misses else NULL)
  }

  runtime <- as.numeric(event$at) - as.numeric(w$running$started_at)
  result <- new_result(code = w$running$code, status = status, output = report$output,
                       console = w$running$console, error = error,
                       started_at = w$running$started_at, runtime = runtime,
                       defined = report$created %||% character())
  state$results[[id]] <- result
  if (length(state$footer_sources) && all_code_cells_ran(state)) {
    state$footer_sources <- character()
  }

  state$worker$status <- "ready"
  state$worker$running <- NULL
  state$worker$interrupt <- NULL
  state$worker$restart_offered <- FALSE

  if (identical(status, "ok")) {
    state <- invalidate_dependents(state, id, report$created %||% character())
  } else {
    state <- drop_downstream(state, id)
  }
  list(state = state, effects = list(), reply = NULL)
}

#' Every code cell has an "ok" result in this worker, so every computed
#' `source()` path has been reported by the cell that runs it.
all_code_cells_ran <- function(state) {
  code <- names(state$cells)[vapply(state$cells, function(c) c$kind == "code", logical(1))]
  all(vapply(code, function(id) identical(state$results[[id]]$status, "ok"), logical(1)))
}

#' gen check; replace `results[[cell]]$output` if the cell still has a
#' result and `event$display`'s token matches it (a reply for an older run,
#' or for a run that has since been superseded, is dropped). Works for any
#' mime now, not only `image/png`: a plot resize, or a "more" page of a
#' table or tree, both arrive as `wk_rendered`.
#'
#' A plot resize only replaces the image bytes and size; `text` (the
#' `print()` form, used where an image can't be shown) came from the
#' original run and a resize has no new value to offer in its place. A
#' table or tree page is rebuilt whole by the worker, so it replaces the
#' output outright. Either way `rendered_at` is stamped, which is what
#' makes `project_output()`'s `last_run_timestamp` advance so the page
#' redraws (pluto-state.R).
reduce_wk_rendered <- function(state, event) {
  if (!eq(event$gen, state$worker$gen)) return(list(state = state, effects = list(), reply = NULL))
  r <- state$results[[event$cell]]
  if (is.null(r) || is.null(r$output) || is.null(event$display) ||
      !eq(event$display$token, r$output$token)) {
    return(list(state = state, effects = list(), reply = NULL))
  }
  out <- r$output
  if (identical(out$mime, "image/png") && identical(event$display$mime, "image/png")) {
    out$data <- event$display$data
    out$size <- event$display$size
  } else {
    out <- event$display
    out$token <- r$output$token
  }
  out$rendered_at <- event$at
  r$output <- out
  state$results[[event$cell]] <- r
  list(state = state, effects = list(), reply = NULL)
}

#' The worker process exited.
reduce_wk_exited <- function(state, event) {
  if (!eq(event$gen, state$worker$gen)) return(list(state = state, effects = list(), reply = NULL))
  running <- state$worker$running
  state$results <- list()
  if (!is.null(running)) {
    state$results[[running$cell]] <- new_result(
      code = running$code, status = "error", output = NULL, console = running$console,
      error = new_run_error("worker_exited",
        message = sprintf("R exited while running this cell (status %s). Run a cell to start a new R process.",
                          event$status)),
      started_at = running$started_at,
      runtime = as.numeric(event$at) - as.numeric(running$started_at),
      defined = character())
  }
  state$pending <- character()
  state$worker$status <- "stopped"
  state$worker$running <- NULL
  state$worker$restart_offered <- FALSE
  state$worker$exit <- list(status = event$status, message = event$message)
  # A fresh worker has nothing loaded; leaving the old process's `loaded`
  # here would make the next worker's actual (empty) namespace set look
  # like a version conflict the moment it reports anything, restarting it
  # for a conflict that doesn't exist and dropping whatever run the user
  # just asked for.
  state$worker$loaded <- character()
  list(state = state, effects = list(), reply = NULL)
}

#' A memory sample from the shell. gen check (same rule as every other
#' worker event): a sample from a worker that has since been replaced is
#' dropped, not stored as if it were the new one's.
reduce_worker_usage <- function(state, event) {
  if (!eq(event$gen, state$worker$gen)) return(list(state = state, effects = list(), reply = NULL))
  state$worker_usage <- list(gen = event$gen, rss = event$rss)
  list(state = state, effects = list(), reply = NULL)
}

#' Grace period after an interrupt passed.
#' If gen and token still match the running cell: restart_offered <- TRUE.
#' Otherwise (the cell stopped, or a different one runs) no-op.
reduce_offer_restart <- function(state, event) {
  w <- state$worker
  if (eq(event$gen, w$gen) && !is.null(w$running) &&
      eq(w$running$token, event$token)) {
    state$worker$restart_offered <- TRUE
  }
  list(state = state, effects = list(), reply = NULL)
}
