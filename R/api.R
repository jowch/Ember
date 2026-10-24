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
#'   opens as a notebook too (see `parse_notebook()`). A path that doesn't
#'   exist or names a folder is an error that says which (`open_path_error()`).
#' @param repos `ember_repos()`: where indexes and packages come from.
#' @param cache `cache_dir()`: where libraries, indexes and renv's cache
#'   live.
#' @return An `ember_notebook`.
#' @export
open_notebook <- function(path, repos = ember_repos(), cache = cache_dir()) {
  bad <- open_path_error(path)
  if (!is.null(bad)) stop(bad)
  text <- read_file_utf8(path)
  file <- parse_notebook(text, new_id = uuid)
  state <- new_state(file, path = path, id = uuid(),
                     options = list(repos = repos, cache = cache, r = r_info()),
                     at = Sys.time())
  nb <- session_start(state)
  dispatch(nb, ev_open(at = Sys.time()))
  nb
}

#' Why `path` can't be opened as a notebook file, as a condition, or `NULL`
#' when it names a file. Checked before reading, because reading a missing
#' file or a folder fails with R's generic "cannot open the connection" and
#' leaves the reason in a warning (#559). Classed `ember_no_file` (with
#' `kind` "missing", "folder" or "empty") so the start page can add what to
#' do there.
#' The path is shown in full, so the message says which path was tried.
#' An empty path (Open a file submitted with nothing typed) has none to show.
open_path_error <- function(path) {
  full <- normalizePath(path, mustWork = FALSE)
  kind <- if (!nzchar(path)) "empty" else if (dir.exists(path)) "folder"
          else if (!file.exists(path)) "missing" else return(NULL)
  text <- switch(kind,
    empty = "No file was given. Type the path of a notebook file",
    folder = sprintf("%s is a folder, not a notebook file", full),
    missing = sprintf("%s doesn't exist. Check the spelling", full))
  structure(class = c("ember_no_file", "error", "condition"),
            list(message = paste0("ember: ", text), call = NULL, text = text, kind = kind))
}

#' Create a new notebook file and open it.
#'
#' Writes a file with the current header (ember_version, r_version, today's
#' snapshot date) and one empty code cell, then opens
#' it as `open_notebook()` does. Refuses to overwrite an existing file.
#' @export
new_notebook <- function(path, repos = ember_repos(), cache = cache_dir()) {
  if (file.exists(path)) stop(sprintf("ember: %s already exists", path))
  code_id <- uuid()
  cells <- list()
  cells[[code_id]] <- list(code = "", kind = "code", folded = FALSE, disabled = FALSE)
  header <- new_header(ember_version = as.character(utils::packageVersion("ember")),
                       r_version = paste(R.version$major, R.version$minor, sep = "."),
                       snapshot = format(Sys.Date()))
  file <- new_notebook_file(
    header = header, cells = cells, run_order = names(cells),
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
#'
#' Validated before anything changes (an `ember_refused` condition, same as
#' `edit_notebook()`'s refusals, so a caller catches both the same way):
#' `path` must be absolute (a relative path is ambiguous -- relative to the
#' notebook's folder? the process's cwd? -- so it is refused rather than
#' guessed), the target must not already exist (a silent overwrite of
#' another file), and its folder must already exist (so the state is never
#' left pointing at a path nothing can write: the UI server's
#' on_update_notebook() relies on this to keep a bad move from being
#' followed by a save loop, shell.R's save_if_changed()).
#'
#' Two cases are not "already exists": a `path` that normalizes to the
#' notebook's own current path does nothing at all (no dispatch, no file
#' operation -- the dialog's Save with nothing changed, or Folder's
#' "Change..." round-tripping the same value) and is not an error either;
#' and a rename that only changes case (`"a.R"` to `"A.R"`) in the same
#' folder is let through even though `file.exists()` already says `TRUE`
#' on a case-insensitive filesystem (macOS, Windows) -- there, a
#' same-folder path differing only in case can only ever be the same
#' directory entry, never a distinct file, so it is never a real conflict.
#' @export
move_notebook <- function(nb, path) {
  if (!is_absolute_path(path)) {
    stop(refused(sprintf("%s is not an absolute path", path)))
  }
  # The folder is normalised, but `basename(path)` is kept exactly as
  # given, not run through `normalizePath()`: on a case-insensitive,
  # case-preserving filesystem (macOS, Windows), `normalizePath()`
  # resolves an *existing* path to its real on-disk case regardless of
  # the case asked for, which would make `target` and `current` compare
  # `identical()` even for a genuine case-only rename request ("a.R" to
  # "A.R") and silently turn it into a no-op.
  target_dir <- normalizePath(dirname(path), mustWork = FALSE, winslash = "/")
  target <- file.path(target_dir, basename(path))
  current <- normalizePath(notebook_state(nb)$path, mustWork = FALSE, winslash = "/")
  if (identical(target, current)) {
    return(target)
  }
  case_only_rename <- identical(tolower(target), tolower(current)) &&
    identical(dirname(target), dirname(current))
  if (file.exists(target) && !case_only_rename) {
    stop(refused(sprintf("%s already exists", target)))
  }
  if (!dir.exists(target_dir)) {
    stop(refused(sprintf("the folder %s does not exist", target_dir)))
  }
  dispatch(nb, ev_move(target, at = Sys.time()))
}

# ---- Editing ------------------------------------------------------------------

#' Apply a batch of edits at once.
#'
#' Edits are staged: they change the code, the graph and the file, never
#' run anything. Either every op applies or none does: if any `set_code`'s
#' `expected` differs from the current code, if an id is unknown, or if
#' code contains a line Ember uses as a
#' cell or footer marker (`# %%`, `# ///`), the whole batch is refused with
#' an `ember_refused` condition naming the op and the reason.
#'
#' @param ... Ops made by `set_code()`, `insert_cell()`, `delete_cell()`,
#'   `move_cell()`, `fold_cell()`, applied in order. Indexes are display
#'   positions after the previous ops. An op may name, by id, a cell an
#'   earlier `insert_cell()` in the same batch adds.
#' @return Invisibly, `list(inserted = <ids of inserted cells, in op order>,
#'   seq = <the state's seq after the batch>)`.
#' @export
edit_notebook <- function(nb, ...) {
  ops <- list(...)
  # An op may name a cell an earlier insert in the same batch adds (the
  # page's undo-delete of a folded cell is an insert and then a fold).
  inserted <- character()
  resolved <- lapply(ops, function(op) {
    if (identical(op$op, "insert")) {
      if (is.null(op$id)) op$id <- uuid()
      inserted <<- c(inserted, op$id)
    } else if (is.character(op$cell) && length(op$cell) == 1 && op$cell %in% inserted) {
      # already an id
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
#' `id`, when given, is kept by `edit_notebook()` instead of generating a
#' fresh one (it must be 1 to 64 letters, digits, `.`, `_` or `-`, such as
#' a UUID or a hand-written file's short id, and not already in use; a
#' reused id is refused). The step-4 UI server passes the id the page already
#' shows the new cell under, so inserting never makes the browser's cell
#' flicker away and a run requested for it right after never misses. The
#' inserted cell's kind is always `cell_kind(code)`: there is no separate
#' argument for it.
#' @export
insert_cell <- function(index, code = "", id = NULL) {
  structure(list(op = "insert", index = index, code = code, id = id), class = "ember_op")
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
#' Disable (or re-enable) a cell: it and every cell that depends on it stop
#' running, keep their last output dimmed, and lose their globals, as if
#' deleted. Refused for a text cell.
#' @export
disable_cell <- function(cell, disabled = TRUE) {
  structure(list(op = "disable", cell = cell, disabled = disabled), class = "ember_op")
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
#' can't run (a graph error of their own, a disabled cell, or a dependent
#' of one) are not queued and come back in `skipped`; a dependent of a
#' failed or graph-broken cell still runs, and fails on its own if it needs
#' what that cell would have provided.
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
#' leave not run); it turns back to `FALSE` if the cell stops after all. If
#' the interrupt can't be delivered at all (Windows, #48), both
#' `restart_offered` and `interrupt_failed` turn `TRUE` at once.
#' @export
interrupt_notebook <- function(nb) {
  dispatch(nb, ev_interrupt(at = Sys.time()))
  invisible(NULL)
}

#' Answer the prompt the running cell waits on (#186).
#'
#' A cell that asks a question (`readline()`, `menu()`, `askYesNo()`,
#' `select.list()`, so a package's "Do you want to download...?") waits for
#' an answer, as in an R console. The snapshot shows the question as the
#' running cell's `prompt`, `list(id, text, choices)`; `choices` are
#' `menu()`'s, answered by number or by the choice itself. Interrupting the
#' cell stops the wait.
#'
#' @param text The answer, one string, as typed at the prompt.
#' @param cell The cell the answer is for (id or index), or `NULL` for
#'   whichever cell runs. Given, an answer meant for a cell that has since
#'   stopped waiting is refused rather than given to another cell's prompt.
#' @param id The prompt's `id` from the snapshot, or `NULL` for whichever
#'   question waits. Given, an answer to a question already answered (and
#'   asked again, as `menu()` does after a bad answer) is refused.
#' @return `TRUE`, invisibly. With nothing waiting (or another cell
#'   waiting), an `ember_refused` error.
#' @export
answer_input <- function(nb, text, cell = NULL, id = NULL) {
  if (!is.character(text) || length(text) != 1 || is.na(text)) stop("ember: `text` must be one string")
  if (!is.null(cell)) cell <- resolve_cell_id(nb, cell)
  reply <- dispatch(nb, ev_answer_input(text, at = Sys.time(), cell = cell, id = id))
  if (inherits(reply, "ember_refused")) stop(reply)
  invisible(TRUE)
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

#' Give an input a new value, as moving its widget does (docs/inputs.md).
#'
#' `name` is the variable the input is bound to (`n` for
#' `n <- input_slider(10, 500)`). The input's cell must have run and be
#' neither stale nor edited since. The worker checks the value against the
#' input (a dropdown's value must be one of its choices) and assigns it;
#' the input's own cell doesn't rerun. The cells that read `name` rerun in
#' autorun, or are marked stale in lazy mode. The value lasts for the
#' session: it is not saved, and editing the input's code resets it.
#'
#' @param value The R value, as the input would return it.
#' @param wait `TRUE` blocks until the worker has answered and the reruns
#'   have finished, or `timeout` passes (as `run_cells()`'s `wait`). A
#'   value the input doesn't allow is then an error.
#' @return Invisibly, `list(accepted, cell, value, cells, timed_out)`:
#'   `cell` is the input's cell; `value` (the value as assigned) and
#'   `cells` (the readers rerun or marked stale) are filled in only with
#'   `wait`, and stay empty if the wait timed out. A refused change (no such input, its cell not fresh, another
#'   value still being set) is an `ember_refused` error.
#' @export
set_input <- function(nb, name, value, wait = FALSE, timeout = 60) {
  if (!is.character(name) || length(name) != 1 || is.na(name)) stop("ember: `name` must be one string")
  reply <- dispatch(nb, ev_set_input(name, value, at = Sys.time()))
  if (inherits(reply, "ember_refused")) stop(reply)
  if (is.null(reply)) stop("ember: the notebook is closed")
  result <- list(accepted = TRUE, cell = reply$cell, value = NULL, cells = character(), timed_out = FALSE)
  if (isTRUE(wait)) {
    # Done once this value is no longer with the worker (a page value sent
    # after it may be) and the reruns have finished. Its own outcome, by
    # token: a page value answered meanwhile has none.
    mine <- function() identical(nb$state$worker$input$token, reply$token)
    ok <- wait_for(nb, function(s) !mine() && is_idle(s), timeout = timeout)
    result$timed_out <- !ok
    out <- nb$state$input_outcome
    if (ok && !is.null(out) && identical(out$token, reply$token)) {
      if (!isTRUE(out$ok)) stop(sprintf("ember: %s", out$error), call. = FALSE)
      result$value <- out$value
      result$cells <- out$cells
    }
  }
  invisible(result)
}

# ---- Reading ------------------------------------------------------------------

#' What the notebook looks like now: a plain list, safe to keep.
#'
#' `list(id, path, seq, read_only, allowed, process, restart_offered,
#' interrupt_failed, worker_message, worker_memory, problems, order, cells,
#' packages)` where
#' `process` is one of `"preview"`, `"starting"`, `"ready"`, `"busy"`,
#' `"stopped"`, `cells` is a named list (display order) of `ember_cell_view`
#' (see `snapshot_of()` in state.R) with each cell's `variables` carrying
#' only `name` and `type` (no `value`/`kind`: a value the notebook never
#' printed stays out of the API), `packages` is `package_status(nb)`'s
#' value (packages-core.R's `packages_view()`), and `worker_memory` is the
#' worker's last-reported RSS in bytes, or `NULL` when none has been sampled
#' yet for the current worker (shell.R samples it every 2s; ui-2.md, Worker
#' memory). Endeavor's `snapshot` maps onto this one to one.
#' @export
notebook_snapshot <- function(nb) {
  s <- snapshot_of(nb$state)
  cells <- lapply(s$cells, function(v) strip_variable_values(strip_ansi_from_view(v)))
  wu <- nb$state$worker_usage
  worker_memory <- if (!is.null(wu) && identical(wu$gen, nb$state$worker$gen)) wu$rss else NULL
  list(id = nb$state$id, path = nb$state$path, seq = s$seq,
      read_only = isTRUE(nb$state$read_only), allowed = isTRUE(nb$state$allowed),
      process = s$process, restart_offered = s$restart_offered,
      interrupt_failed = s$interrupt_failed,
      worker_message = s$worker_message, worker_memory = worker_memory,
      problems = nb$state$problems,
      order = names(nb$state$cells), cells = cells, packages = s$packages)
}

#' Strip ANSI escape codes (design.md, Terminal colours), so a program
#' reading output as text (Endeavor's agent) sees `tibble [32 x 11]`, not
#' escape codes. `notebook_state()` keeps the coloured text, for the page.
strip_ansi <- function(x) {
  if (is.null(x)) return(x)
  gsub("\033\\[[0-9;]*[A-Za-z]", "", x)
}

#' `view` (an `ember_cell_view`) with ANSI stripped from its output text and
#' console item text; everything else unchanged.
strip_ansi_from_view <- function(view) {
  if (!is.null(view$output) && !is.null(view$output$text)) {
    view$output$text <- strip_ansi(view$output$text)
  }
  if (length(view$console) > 0) {
    view$console <- lapply(view$console, function(item) {
      item$text <- strip_ansi(item$text)
      item
    })
  }
  view
}

#' `view` with its `variables`' `value` and `kind` dropped, keeping only
#' `name` and `type`: `notebook_snapshot()` is read by API callers
#' (Endeavor's agent), which should see what a global is, never a value
#' the notebook itself never printed.
strip_variable_values <- function(view) {
  view$variables <- lapply(view$variables, function(v) list(name = v$name, type = v$type))
  view
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
#' undocumented except where state.R documents them. Unlike
#' `notebook_snapshot()`, each cell's `variables` here carries its
#' globals' actual values, not just their names and types.
#' @export
notebook_state <- function(nb) nb$state

#' A PNG of a cell's output, for Endeavor's `view_cell_output`.
#'
#' Plots are already PNGs and come back at once. With `width`/`height`,
#' the worker re-renders the recorded plot at that size (the call waits up
#' to `timeout`, and a busy worker answers once its run ends). The new
#' image is only returned: the cell's stored image, the one every page
#' shows, stays as it was (#28). `png` is `NULL` when no answer came in
#' time, or the cell ran again meanwhile. Other outputs return `NULL`; the
#' caller reads their `text/plain` form from the snapshot.
#' @return `list(png = <raw> | NULL, mime = <the output's mime type>)`.
#' @export
render_png <- function(nb, cell, width = NULL, height = NULL, res = 96, timeout = 5) {
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

  # A worker query, not an event: the reply goes to this call alone and
  # never reaches the state, so the page keeps the cell's own image.
  token <- nb$state$results[[id]]$output$token
  msg <- c(list(type = "render", cell = id, res = res),
          if (!is.null(width)) list(width = width),
          if (!is.null(height)) list(height = height))
  reply <- "unset"
  worker_query(nb, msg, function(r) reply <<- r, timeout = timeout, busy_ok = TRUE)
  while (identical(reply, "unset")) later::run_now(timeout = timeout)
  display <- if (!is.null(reply) && eq(reply$token, token)) as_display(reply$display)
  if (is.null(display) || !identical(display$mime, "image/png")) {
    return(list(png = NULL, mime = "image/png"))
  }
  list(png = display$data, mime = "image/png")
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
