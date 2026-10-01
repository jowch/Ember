# The projection: Pluto's notebook object (notebook_to_js's shape) as a pure
# function of the engine's `ember_state`. It is never a second source of
# truth: nothing writes to it but this file, and the server never edits it
# except to record a client's own patches in that client's copy.
#
# Cheap because of reuse. `pluto_state(state, previous)` rebuilds only the
# cells whose engine inputs changed, and hands back the previous object for
# every part that came out equal, so consecutive projections share memory
# the way consecutive engine states do and fb_diff() meets identical R
# objects (design.md, Performance).
#
# Pure: reads only `state` and `previous`. No clock, no IO, no options.

PLUTO_VERSION <- "v1.0.3"

#' One constant metadata object shared by every cell input, so it is the same
#' R object in every projection. Ember has no per-cell metadata: a client
#' that changes one gets 👎 (see pluto_edits()).
CELL_METADATA <- list(disabled = FALSE, show_logs = TRUE, skip_as_script = FALSE)

# ---- The value ---------------------------------------------------------------

#' A projection.
#'
#' * `js`: the frontend notebook object (NotebookData in Editor.js), built
#'   per protocol.R's convention. This is what clients are diffed against.
#' * `state`: the `ember_state` it came from. `identical(state,
#'   previous$state)` (pointer-equal in practice) returns `previous` at once,
#'   which makes extra flushes free.
#' * `keys`: list aligned with `names(js$cell_inputs)`: per cell, the engine
#'   inputs its two entries were built from (see cell_key()). A cell whose
#'   key is identical() keeps its previous entries without rebuilding them.
#' * `graph`: the `ember_graph` `js$cell_dependencies` was built from.
new_pluto_state <- function(js, state, keys, graph) {
  structure(list(js = js, state = state, keys = keys, graph = graph),
            class = "ember_pluto_state")
}

#' Project the engine's state.
#'
#' @param state `ember_state` (notebook_state(nb)).
#' @param previous The last `ember_pluto_state` for this notebook, or NULL.
#' @return `ember_pluto_state`. Invariants (tested):
#'   * `pluto_state(s, p)$js` equals `pluto_state(s, NULL)$js` (reuse never
#'     changes values, only which objects hold them);
#'   * `check_wire(result$js)` passes;
#'   * if only cell `a`'s engine inputs changed, every patch of
#'     `fb_diff(previous$js, result$js)` is under `cell_results/a`,
#'     `cell_inputs/a` or a top-level scalar.
pluto_state <- function(state, previous = NULL) {
  if (!is.null(previous) && identical(state, previous$state)) return(previous)
  pj  <- previous$js
  ctx <- view_context(state)            # state.R: queued set, blocked set,
                                        # failed blockers, waiting, errors by
                                        # cell, running id, once per call
  ids <- ctx$ids; n <- length(ids)
  at  <- if (is.null(pj)) rep(NA_integer_, n) else match(ids, names(pj$cell_inputs))
                                             # one match, never `[[name]]`
                                             # in a loop (quadratic, spike)
  inputs <- results <- keys <- vector("list", n)
  for (i in seq_len(n)) {
    j <- at[i]
    prev_key <- if (!is.na(j) && !is.null(previous)) previous$keys[[j]] else NULL
    # `key_unchanged()` compares this cell's inputs against `prev_key`'s
    # fields directly, with no new list built: at 2000 cells, most calls
    # land here, and building a fresh `cell_key()` list just to throw it
    # away on an `identical()` match would cost as much as the rebuild it's
    # meant to avoid (the spike's 0.95ms-per-changed-cell number assumes
    # this). Every lookup inside is by position `i` (state.R's
    # view_context()), never by id: a 2000-cell notebook made the named
    # lookups alone cost tens of milliseconds (measured).
    if (!is.null(prev_key) && key_unchanged(state, ctx, i, prev_key)) {
      keys[[i]] <- prev_key
      inputs[i] <- pj$cell_inputs[j]; results[i] <- pj$cell_results[j]
    } else {
      keys[[i]] <- cell_key(state, ctx, i)
      view <- cell_view(state, ctx, i)          # state.R, shared with snapshot_of()
      old_input  <- if (!is.na(j)) pj$cell_inputs[[j]] else NULL
      old_result <- if (!is.na(j)) pj$cell_results[[j]] else NULL
      inputs[[i]]  <- reuse(project_cell_input(view),  old_input)
      results[[i]] <- reuse(project_cell_result(view), old_result)
    }
  }
  names(inputs) <- names(results) <- ids

  # `edges` and `cells` (for `attaches`) are everything project_dependencies()
  # reads from the graph; comparing just those, instead of the whole graph
  # object, skips a full O(cells) rebuild on a plain code edit that doesn't
  # touch any cell's references (the common case: `graph$analyses` and
  # `graph$cells` differ for the edited cell regardless, so the whole-graph
  # `identical()` a code edit would otherwise force can't be used as the
  # gate here).
  unchanged_deps <- !is.null(previous) && !is.null(previous$state$graph) &&
    identical(state$graph$edges, previous$state$graph$edges) &&
    identical(state$graph$cells, previous$state$graph$cells)
  deps <- if (unchanged_deps) {
    pj$cell_dependencies
  } else {
    project_dependencies(state$graph, if (!is.null(pj)) pj$cell_dependencies else NULL)
  }

  js <- list(
    pluto_version = PLUTO_VERSION,
    julia_version = paste("R", state$options$r$version),
    notebook_id = state$id, path = state$path, shortpath = basename(state$path),
    in_temp_dir = FALSE,
    process_status = project_process_status(state),
    last_save_time = 0, last_hot_reload_time = 0,   # unused by the frontend
    cell_inputs  = reuse(inputs,  if (!is.null(pj)) pj$cell_inputs else NULL),
    cell_results = reuse(results, if (!is.null(pj)) pj$cell_results else NULL),
    cell_order = reuse(as_arr(ids), if (!is.null(pj)) pj$cell_order else NULL),
    published_objects = emptymap(), bonds = emptymap(), metadata = emptymap(),
    nbpkg = reuse(project_nbpkg(state), if (!is.null(pj)) pj$nbpkg else NULL),
    status_tree = reuse(project_status_tree(state), if (!is.null(pj)) pj$status_tree else NULL),
    cell_dependencies = deps,
    cell_execution_order = reuse(as_arr(state$graph$order), if (!is.null(pj)) pj$cell_execution_order else NULL))
  new_pluto_state(js, state, keys, state$graph)
}

#' What a cell's two entries depend on, as a list whose big parts are the
#' engine's own shared objects, so comparing two keys is pointer comparisons
#' plus a few scalars.
#'
#' `list(cell = state$cells[[id]], result = state$results[[id]],
#'       console = <worker$running$console when this cell runs, else NULL>,
#'       flags = ctx$flags[[id]],   # queued, running, blocked, blocked_by, waiting_for
#'       errors = ctx$errors[[id]], # graph errors on this cell: shared within one graph
#'       allowed = state$allowed)   # sanitize/preview only changes with this
#'
#' Must cover every input cell_view() reads for this cell; a missed input
#' shows as a stale cell in the browser. Tested by building every engine
#' fixture's projection with and without `previous` and comparing.
#'
#' Fields are raw `ctx` lookups, not the normalised (`%||%`-defaulted)
#' values `cell_view()` shows: the key only ever answers "did this cell's
#' inputs change", so `NULL` (not queued, no error, nothing waiting) is as
#' good a sentinel as a filled-in default. Every lookup is by position `i`
#' (`ctx$ids[i]` is this cell's id), never by id: see view_context()'s doc
#' in state.R for why that matters at 2000 cells.
cell_key <- function(state, ctx, i) {
  id <- ctx$ids[[i]]
  running <- ctx$running
  is_running <- !is.null(running) && identical(running$cell, id)
  list(cell = state$cells[[i]], result = state$results[[id]],
       is_running = is_running, console = if (is_running) running$console else NULL,
       queued = ctx$queued[[i]], blocked = ctx$blocked[[i]],
       blocked_by = ctx$blocked_by[[i]], waiting_for = ctx$waiting[[i]],
       errors = ctx$errors_by_cell[[i]], allowed = state$allowed)
}

#' `identical(cell_key(state, ctx, i), prev_key)`, field by field against an
#' already-built key, with no new list allocated to do the comparison. At
#' 2000 cells this is what keeps an edit to one cell cheap: building a fresh
#' key for all 1999 untouched cells just to `identical()` it away would cost
#' as much as the `reuse()` it's meant to avoid. Must compare exactly the
#' fields `cell_key()` builds.
key_unchanged <- function(state, ctx, i, prev_key) {
  if (!identical(state$cells[[i]], prev_key$cell)) return(FALSE)
  id <- ctx$ids[[i]]
  if (!identical(state$results[[id]], prev_key$result)) return(FALSE)
  running <- ctx$running
  is_running <- !is.null(running) && identical(running$cell, id)
  if (!identical(is_running, prev_key$is_running)) return(FALSE)
  if (!identical(if (is_running) running$console else NULL, prev_key$console)) return(FALSE)
  if (!identical(ctx$queued[[i]], prev_key$queued)) return(FALSE)
  if (!identical(ctx$blocked[[i]], prev_key$blocked)) return(FALSE)
  if (!identical(ctx$blocked_by[[i]], prev_key$blocked_by)) return(FALSE)
  if (!identical(ctx$waiting[[i]], prev_key$waiting_for)) return(FALSE)
  if (!identical(ctx$errors_by_cell[[i]], prev_key$errors)) return(FALSE)
  identical(state$allowed, prev_key$allowed)
}

# ---- Cells -------------------------------------------------------------------

#' CellInputData. `metadata` is the shared CELL_METADATA.
project_cell_input <- function(view) {
  list(cell_id = view$id, code = view$code, code_folded = view$folded,
       metadata = CELL_METADATA)
}

#' CellResultData from an `ember_cell_view` (state.R).
#'
#' * `queued`, `running`: the view's.
#' * `errored`: any error on the view, or status "error"/"interrupted".
#' * `runtime`: seconds -> nanoseconds as a double, or NULL when not run.
#' * `depends_on_disabled_cells`: `stale || !is.na(blocked_by)`. Pluto dims a
#'   cell with this class; that is the increment-1 stand-in for "stale" and
#'   "an ancestor failed" until the fork has its own label (increment 2).
#' * `output`: project_output() of the view.
#' * `logs`: project_logs() of the view's console.
#' * `published_object_keys = list()`, `depends_on_skipped_cells = FALSE`.
project_cell_result <- function(view) {
  errored <- length(view$errors) > 0 || view$status %in% c("error", "interrupted")
  list(cell_id = view$id,
      queued = isTRUE(view$queued), running = isTRUE(view$running),
      errored = errored,
      runtime = if (is.null(view$runtime)) NULL else as.double(view$runtime) * 1e9,
      depends_on_disabled_cells = isTRUE(view$stale) || !is.na(view$blocked_by),
      output = project_output(view),
      logs = project_logs(view$console, view$id),
      published_object_keys = list(), depends_on_skipped_cells = FALSE)
}

#' The `output` field: `list(body, mime, rootassignee = NULL,
#' last_run_timestamp, persist_js_state = FALSE, has_pluto_hook_features =
#' FALSE)`. `last_run_timestamp` is `as.numeric(view$last_run)` or 0.
#'
#' Precedence: an error on the view wins over the display, as Pluto shows a
#' cell's error in place of its output.
#'
#' | view                         | mime                                     | body                       |
#' |------------------------------|------------------------------------------|----------------------------|
#' | graph error, kind "parse"    | application/vnd.pluto.parseerror+object  | list(diagnostics = ...)    |
#' | any other error              | application/vnd.pluto.stacktrace+object  | project_error()            |
#' | status "interrupted"         | application/vnd.pluto.stacktrace+object  | msg "Interrupted", no frames |
#' | no output (not run, NULL)    | text/plain                               | ""                         |
#' | text/plain                   | text/plain                               | data (ANSI kept; the frontend colours it) |
#' | text/html                    | text/html                                | data (deps: increment 2)   |
#' | image/png                    | image/png                                | data (raw -> msgpack bin)  |
#' | image/svg+xml                | image/svg+xml                            | data                       |
#' | text/markdown (and markdown cells) | text/html if commonmark is installed in the server's library, else text/plain | rendered / text |
#' | text/latex, vnd.ember.table, vnd.ember.tree, anything else | text/plain | `text` (the print() form; views are increment 2) |
#'
#' The running cell shows its previous output, as the snapshot does.
project_output <- function(view) {
  last_ts <- if (is.null(view$last_run)) 0 else as.numeric(view$last_run)
  wrap <- function(mime, body) list(body = body, mime = mime, rootassignee = NULL,
                                    last_run_timestamp = last_ts, persist_js_state = FALSE,
                                    has_pluto_hook_features = FALSE)

  # Markdown cells never run (step.R's can_run() refuses them), so they
  # have no `output`: their displayed body is their own code, rendered
  # directly, every time, not something a graph or run error could pre-empt.
  if (identical(view$kind, "markdown")) {
    if (commonmark_available()) return(wrap("text/html", render_markdown(view$code)))
    return(wrap("text/plain", view$code))
  }

  parse_err <- Find(function(e) identical(e$kind, "parse"), view$errors)
  if (!is.null(parse_err)) {
    return(wrap("application/vnd.pluto.parseerror+object",
               project_parse_error(parse_err, view$code)))
  }
  if (length(view$errors) > 0) {
    return(wrap("application/vnd.pluto.stacktrace+object",
               project_error(view$errors[[length(view$errors)]])))
  }
  if (identical(view$status, "interrupted")) {
    return(wrap("application/vnd.pluto.stacktrace+object",
               list(msg = "Interrupted", stacktrace = list(), plain_error = "Interrupted")))
  }

  out <- view$output
  if (is.null(out)) return(wrap("text/plain", ""))

  switch(out$mime,
    "text/plain" = wrap("text/plain", out$data %||% out$text),
    "text/html" = wrap("text/html", out$data),
    "image/png" = wrap("image/png", out$data),
    "image/svg+xml" = wrap("image/svg+xml", out$data),
    "text/markdown" = if (commonmark_available()) wrap("text/html", render_markdown(out$data))
                      else wrap("text/plain", out$data),
    wrap("text/plain", out$text))
}

#' `TRUE` when the commonmark package can be used to render markdown. A
#' `Suggests` dependency, not `Imports`: the server runs without it, falling
#' back to plain text (design.md, "Tradeoffs accepted").
commonmark_available <- function() requireNamespace("commonmark", quietly = TRUE)

#' Markdown text to an HTML string, via commonmark.
render_markdown <- function(text) commonmark::markdown_html(text %||% "")

#' Join names the way the frontend's rewritten messages read: one name as
#' is, two with "and", more as a comma list with "and" before the last.
join_names <- function(names) {
  if (length(names) <= 1) return(if (length(names) == 0) "" else names)
  if (length(names) == 2) return(paste(names, collapse = " and "))
  paste0(paste(names[-length(names)], collapse = ", "), " and ", names[length(names)])
}

#' A stack-trace body: `list(msg, stacktrace, plain_error)`.
#'
#' `msg` is written to match the frontend's rewriters where Pluto has one:
#' "Multiple definitions for x and y" and "Cyclic references among a, b."
#' are built from the error's `names` (the engine's own `message` reads
#' differently); every other kind uses the engine's `message`. Each of the
#' error's `fixes` is a further line (ErrorMessage.js is changed to show
#' those lines as they are instead of Julia's "begin ... end" hint).
#'
#' `stacktrace`: one frame per traceback call, innermost first:
#' `list(call, call_short, func, inlined = FALSE, from_c = FALSE, file = "",
#' path = "", line = -1L, linfo_type = "", url = NULL, source_package =
#' NULL, parent_module = NULL)`. R tracebacks have no file and line unless
#' srcrefs are kept; `file = ""` keeps the frontend from linking frames to
#' cells.
project_error <- function(error) {
  msg <- switch(error$kind,
    multiple_definitions = sprintf("Multiple definitions for %s", join_names(error$names)),
    cycle = sprintf("Cyclic references among %s.", join_names(error$names)),
    error$message)
  text <- paste(c(msg, error$fixes), collapse = "\n")
  stacktrace <- lapply(rev(error$traceback %||% character()), function(call) {
    list(call = call, call_short = call, func = NULL, inlined = FALSE, from_c = FALSE,
        file = "", path = "", line = -1L, linfo_type = "", url = NULL,
        source_package = NULL, parent_module = NULL)
  })
  list(msg = text, stacktrace = stacktrace, plain_error = text)
}

#' Parse-error diagnostics: `list(list(message, from, to, line))` from the
#' graph error's `lines`; `from`/`to` are the 0-based character offsets of
#' that whole line in the cell's code (the engine has no column).
project_parse_error <- function(error, code) {
  lines <- strsplit(code, "\n", fixed = TRUE)[[1]]
  if (length(lines) == 0) lines <- ""
  nch <- nchar(lines, type = "chars")
  starts <- cumsum(c(0, nch[-length(nch)] + 1))
  ends <- starts + nch

  rows <- error$lines
  if (is.null(rows) || nrow(rows) == 0) {
    return(list(list(message = error$message, from = 0L,
                    to = as.integer(ends[1]), line = 1L)))
  }
  lapply(seq_len(nrow(rows)), function(i) {
    ln <- min(max(as.integer(rows$line[i]), 1L), length(lines))
    list(message = error$message, from = as.integer(starts[ln]),
        to = as.integer(ends[ln]), line = as.integer(rows$line[i]))
  })
}

#' LogEntryData per console item, in order:
#' `list(id = "<cell>_<i>", cell_id, level, msg = arr(text, "text/plain"),
#' file = "", line = -1L, kwargs = list())` with level "LogLevel(-555)"
#' (stdout: the frontend joins consecutive ones), "Info" (message) or
#' "Warn" (warning). Built so a growing console gives a list whose prefix is
#' identical to the previous one: fb_diff() then sends only the new items.
project_logs <- function(console, cell_id) {
  level_of <- function(kind) switch(kind, stdout = "LogLevel(-555)",
                                    message = "Info", warning = "Warn", "Info")
  lapply(seq_along(console), function(i) {
    item <- console[[i]]
    list(id = sprintf("%s_%d", cell_id, i), cell_id = cell_id,
        level = level_of(item$kind), msg = arr(item$text, "text/plain"),
        file = "", line = -1L, kwargs = list())
  })
}

# ---- Graph -------------------------------------------------------------------

#' `cell_dependencies`: per cell, `list(cell_id, downstream_cells_map,
#' upstream_cells_map, precedence_heuristic)`.
#'
#' From `graph$edges` (`from` depends on `to` through `name`): a cell's
#' upstream map is name -> arr(cells it reads that name from), its downstream
#' map name -> arr(cells reading a name it defines or exports). Setup edges
#' (name NA) are left out; package edges are kept under the exported name.
#' `precedence_heuristic` is 5L for a cell that attaches packages, else 9L
#' (Pluto's "runs early" hint, display only).
#'
#' Built only when the graph object changed; each cell's entry goes through
#' reuse() against `previous`, so an edit that changes one cell's edges sends
#' only that cell's (and its neighbours') entries. Splits `edges` by `from`
#' and by `to` once (vectorised), never filters per cell.
project_dependencies <- function(graph, previous) {
  ids <- graph$ids
  edges <- graph$edges
  e <- if (is.null(edges) || nrow(edges) == 0) edges else edges[!is.na(edges$name), , drop = FALSE]
  up_groups <- if (!is.null(e) && nrow(e) > 0) split(e, e$from) else list()
  down_groups <- if (!is.null(e) && nrow(e) > 0) split(e, e$to) else list()

  #' A cell's name -> arr(other cells) map, built from its rows of `e`
  #' (already split by `from` or `to`), reading the *other* endpoint
  #' (`other_col`) per distinct name.
  name_map <- function(rows, other_col) {
    if (is.null(rows) || nrow(rows) == 0) return(emptymap())
    out <- list()
    for (nm in unique(rows$name)) {
      others <- unique(rows[[other_col]][rows$name == nm])
      others <- others[order(match(others, ids))]
      out[[nm]] <- as_arr(others)
    }
    out
  }

  entries <- stats::setNames(lapply(ids, function(id) {
    list(cell_id = id,
        downstream_cells_map = name_map(down_groups[[id]], "from"),
        upstream_cells_map = name_map(up_groups[[id]], "to"),
        precedence_heuristic = if (length(graph$cells[[id]]$attaches) > 0) 5L else 9L)
  }), ids)
  if (is.null(previous)) return(entries)
  stats::setNames(lapply(ids, function(id) reuse(entries[[id]], previous[[id]])), ids)
}

# ---- Notebook-level fields ---------------------------------------------------

#' ProcessStatus (frontend/common/ProcessStatus.js):
#'
#' | engine                                 | Pluto                    |
#' |----------------------------------------|--------------------------|
#' | `!allowed` (safe preview)              | "waiting_for_permission" |
#' | worker "off" or "starting"             | "starting"               |
#' | worker "ready" or "busy"               | "ready"                  |
#' | worker "stopped" (exited, crashed)     | "no_process"             |
#'
#' "no_process" shows Pluto's "process exited" bar with a restart link,
#' which sends restart_process; the server maps that to restart_notebook().
project_process_status <- function(state) {
  if (!isTRUE(state$allowed)) return("waiting_for_permission")
  switch(state$worker$status,
    off = , starting = "starting",
    ready = , busy = "ready",
    stopped = "no_process",
    "no_process")
}

#' Package status in Pluto's `nbpkg` shape, from packages_view(state). The
#' frontend's package bubbles hang off Julia `using` lines and never appear;
#' what remains visible are the restart banners and the Pkg terminal in the
#' status tab, and that is what this fills:
#'
#' * `enabled = TRUE`, `waiting_for_permission = !allowed`,
#'   `waiting_for_permission_but_probably_disabled = FALSE`.
#' * `installed_versions`: name -> version for rows with status "installed".
#' * `busy_packages`: arr(names with status "installing").
#' * `terminal_outputs`: `list(nbpkg_sync = <library message, the install
#'   progress line, and any failed/not_found rows, one per line>)`.
#' * `restart_required_msg`: when `plan$restart` is non-empty, "Restart R to
#'   use the new versions of: <names>".
#' * `restart_recommended_msg`: when the snapshot's `restart_offered` (a
#'   cell ignored the interrupt), "The running cell hasn't stopped. Restart R
#'   to stop it; every cell will be left not run." Pluto's banner for this
#'   has a restart link, which is the action Ember offers.
#' * `install_time_ns = NULL`, `instantiated = library status is "ready"`.
#'
#' Increment 2 replaces this with Ember's own package view; until then
#' Endeavor's page adapter reads the same fields.
project_nbpkg <- function(state) {
  pv <- packages_view(state)
  p <- state$packages
  pkgs <- pv$packages

  installed_rows <- pkgs[pkgs$status == "installed", , drop = FALSE]
  installed <- if (nrow(installed_rows) == 0) emptymap() else {
    stats::setNames(as.list(installed_rows$version), installed_rows$name)
  }
  busy <- as_arr(pkgs$name[pkgs$status == "installing"])

  lines <- character()
  if (!is.null(p$target$progress)) {
    pr <- p$target$progress
    lines <- c(lines, sprintf("Installing %s (%d/%d)...",
                              pr$current %||% "", pr$done %||% 0L, pr$total %||% 0L))
  }
  nf <- pkgs[pkgs$status == "not_found", , drop = FALSE]
  if (nrow(nf) > 0) lines <- c(lines, sprintf("%s: %s", nf$name, nf$message))
  if (identical(p$target$status, "failed") && !is.null(p$target$message)) {
    lines <- c(lines, p$target$message)
  }

  restart_required <- if (!is.null(pv$plan) && length(pv$plan$restart) > 0) {
    sprintf("Restart R to use the new versions of: %s", paste(pv$plan$restart, collapse = ", "))
  } else NULL
  restart_recommended <- if (isTRUE(state$worker$restart_offered)) {
    "The running cell hasn't stopped. Restart R to stop it; every cell will be left not run."
  } else NULL

  list(enabled = TRUE, waiting_for_permission = !isTRUE(state$allowed),
      waiting_for_permission_but_probably_disabled = FALSE,
      installed_versions = installed, busy_packages = busy,
      terminal_outputs = list(nbpkg_sync = paste(lines, collapse = "\n")),
      restart_required_msg = restart_required,
      restart_recommended_msg = restart_recommended,
      install_time_ns = NULL,
      instantiated = identical(p$active$status, "ready"))
}

#' StatusEntryData for the status tab: root "notebook" with subtasks
#' "workspace" (the worker starting: success once "ready") and, when the
#' plan installs anything or an install runs, "pkg" with one subtask per
#' package (success TRUE when installed, FALSE when failed). `started_at` /
#' `finished_at` are NULL: the engine records no per-step times, and putting
#' `state$clock` here would change the tree on every event.
project_status_tree <- function(state) {
  business <- function(name, success, subtasks = emptymap()) {
    list(name = name, success = success, started_at = NULL, finished_at = NULL,
        subtasks = subtasks)
  }

  ready <- state$worker$status %in% c("ready", "busy")
  started <- !identical(state$worker$status, "off")
  subtasks <- list(workspace = business("workspace", if (started) ready else NULL))

  pv <- packages_view(state)
  pkgs <- pv$packages
  touched <- pkgs[pkgs$status %in% c("installed", "installing", "missing", "failed", "not_found"), , drop = FALSE]
  if (nrow(touched) > 0) {
    pkg_subtasks <- stats::setNames(lapply(seq_len(nrow(touched)), function(i) {
      st <- touched$status[i]
      success <- if (st %in% c("installing", "missing")) NULL else identical(st, "installed")
      business(touched$name[i], success)
    }), touched$name)
    pkg_success <- if (any(vapply(pkg_subtasks, function(x) is.null(x$success), logical(1)))) {
      NULL
    } else {
      all(vapply(pkg_subtasks, function(x) isTRUE(x$success), logical(1)))
    }
    subtasks$pkg <- business("pkg", pkg_success, pkg_subtasks)
  }

  business("notebook", NULL, subtasks)
}
