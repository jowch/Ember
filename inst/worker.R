# Ember worker. Base R and the packages shipped with R only (utils, tools,
# grDevices, graphics, stats, methods). Never loaded as a package.
#
# Started by the server as
#   Rscript --vanilla -e '<boot>' <port>
# where <boot> sources this file into a private environment whose parent is
# baseenv(), then calls main():
#   local({e <- new.env(parent = baseenv()); sys.source(Sys.getenv("EMBER_WORKER"), e); e$main()})
# so nothing here is visible from, or shadowed by, the notebook's globals
# (a user's `send <- 1` can't break the worker). Every call to a non-base
# function is written `utils::`, `grDevices::`, ... for the same reason.
# Sourcing the file only defines functions; the boot line calls main().
# Tests source it into an environment and call the pieces directly (see
# TESTS.md). Running notebook code with eval() is the worker's purpose:
# the code is the user's, and safe preview is what gates it.
#
# The worker is a plain loop: receive a message, act, reply. It keeps the
# notebook's runtime bookkeeping that only the process can know (which
# globals each cell owns, which packages each cell attached, the settings
# baseline and each cell's setting changes, display data) and reports
# facts; it never judges graph rules. The server's core decides what a
# fact means (a learned definition or setting, a "Multiple definitions"
# error).
#
# ---- Wire protocol -----------------------------------------------------------
# Frames both ways: 4-byte big-endian length, then serialize(msg, NULL)
# (xdr, version 3). msg is a list with `type`.
#
# Server -> worker
#   run          cell, token, code, role ("cell"|"text"), order (code
#                cell ids in run order), settings (the settings cells in
#                effect before this one, in order: their changes are
#                applied over the baseline first; apply_settings_context()),
#                formulas (list of formula_site),
#                fig (list(width, height, problems), inches: the figure
#                size to open the plot device at).
#                For role "text", each line of `code` is one inline
#                expression (a text cell's `` `r expr` `` spans, one per
#                line); the report's `output` is an "inline" display
#                (values, text, no plot) instead of display_value()'s.
#   remove_cell  cell, order         drop the cell's globals, display data,
#                                    and rebuild the search path
#   drop_globals cell                drop a failed cell's globals, keeping
#                                    its attached packages
#   source_reply allow, message      only while a `source` request waits
#   more         cell, path, dim     grow a table's or tree's paging limit
#                                    at `path` (dim 1 rows/items, 2 columns)
#   render       cell, res, width?, height?   re-render the cell's recorded
#                plot at its own figure size and `res`, or at `width`/
#                `height` pixels when both are given (render_png())
#   complete     id, line, cursor     line: the current line up to the cursor
#   help         id, topic, package   package NULL: search attached, then all installed
#   signature    id, name, package
#   quit
#
# Worker -> server
#   hello        secret, pid, r_version, lib_paths
#   console      cell, token, item = list(kind, text)   streamed during a run
#   source       cell, token, path, text                before a computed
#                                                       source() runs; waits
#   done         cell, token, report (see run_cell())
#   rendered     cell, token, display   display is NULL when the cell has no
#                                       kept value to page or re-render
#   completions  id, token, items = list(name, kind, notebook), too_long
#   help_page    id, found, topic, package, html, matches (packages, when several)
#   signature    id, text             NULL if not a function
#
# complete/help/signature are answered outside the run loop's ordering
# rules: the shell's `worker_query()` sends them only when the worker is
# idle (shell.R), so they never arrive mid-run and never need the
# `deferred` queue's ordering -- except while a `source_reply` is awaited,
# when `handle_next()` defers everything until the run finishes (below).
#
# Ordering: the server sends at most one `run` at a time and sends the next
# only after `done`. `remove_cell`, `more` and `render` may arrive while a
# cell runs (the worker reads them only between runs, or while waiting for a
# `source_reply`, when they are queued in `deferred` and handled after the
# run). Nothing else needs ordering.

# ---- State (the worker's own; lives in this private environment) -------------

`%||%` <- function(x, y) if (is.null(x)) y else x

FIG_RES <- 192                            # first-draw pixel density (2x, for fig.retina = 2)
FIGURE_DEFAULT <- list(width = 7.5, height = 5)  # mirrors notebook.R's; this file is sourced alone
MAX_FIGURE_PX <- 6000                     # neither side of a device or redraw ever exceeds this

con <- NULL            # socket to the server
owned <- list()        # cell id -> character: globals the cell's runs created
attached <- list()     # cell id -> character: packages its runs attached, attach order
ever_attached <- character()  # every package any cell has ever attached (never shrinks;
                               # rebuild_search_path() needs this even after the cell that
                               # attached a package is edited or deleted)
attach_requests <- list()  # cell id -> character: packages library() named during the current run
cell_order <- character()  # code cell ids in run order, as last sent
display <- list()      # cell id -> list(value, token, kind, limits, text, truncated):
                        # what a cell's output needs kept to be paged or
                        # re-rendered. `value` is the data frame, the plain
                        # list, or the recorded plot; `token` the run that
                        # made it; `kind` "table" | "tree" | "plot"; `limits`
                        # the paging state (table: list(rows, cols); tree:
                        # path -> list(items)). Dropped on rerun or delete
                        # (remove_cell()).
cell_settings <- list() # cell id -> list(kind, name, after): the settings its own
                        # code changed on its last run, applied again before
                        # each later cell it is in effect for
touched <- list()       # every list(kind, name) any cell has changed this session;
                        # reset to the baseline before each run. Never shrinks.
search_added <- character()  # every attach() entry any cell has added this session
running <- NULL        # list(cell, token) during a run (for the source trace)
deferred <- list()     # messages read while waiting for a source_reply
load_log <- NULL       # settings changes made inside loadNamespace/library during a run
settings_base <- NULL  # the baseline settings: snapshotted once at boot, then
                       # every change a package load makes is copied in, so a
                       # package's own option survives a reset
load_stack <- list()   # stack of settings snapshots, one per nested loadNamespace/library
loader_originals <- list()  # the real loadNamespace/library/require functions
                             # install_traces() replaced, kept so tracebacks can drop
                             # the wrapper's own frame (identified by identity, not text)

#' Base packages, duplicated from lock.R's `base_packages`: the worker is a
#' separate process that sees only base R, so it can't source the server's
#' R/ code to share the one list.
ember_base_packages <- c("base", "compiler", "datasets", "graphics", "grDevices",
                         "grid", "methods", "parallel", "splines", "stats",
                         "stats4", "tcltk", "tools", "utils")

#' Non-base namespaces loaded in this process, with their versions: named
#' character, namespace -> version. Reported in the hello and every `done`
#' (design.md, "The worker follows the library"), so the server knows which
#' loaded namespaces a library switch would change.
loaded_namespace_versions <- function() {
  ns <- setdiff(loadedNamespaces(), ember_base_packages)
  stats::setNames(vapply(ns, function(n) as.character(getNamespaceVersion(n)), character(1)), ns)
}

main <- function() {
  port <- as.integer(commandArgs(trailingOnly = TRUE)[1])
  con <<- socketConnection("127.0.0.1", port, blocking = TRUE, open = "r+b",
                           timeout = 60 * 60 * 24 * 365)
  install_traces()
  # Baseline, not a cell's change: a colour terminal under Rscript has these
  # on, and a settings cell can still change them (each run resets to this
  # baseline, same as any other setting).
  options(cli.num_colors = 256L, crayon.enabled = TRUE, crayon.colors = 256L)
  # So `library(` completion includes installed package names (complete_line()).
  tryCatch(utils::rc.settings(ipck = TRUE), error = function(e) NULL)
  send(list(type = "hello", secret = Sys.getenv("EMBER_SECRET"),
            pid = Sys.getpid(), r_version = R.version.string,
            lib_paths = .libPaths(), loaded = loaded_namespace_versions()))
  Sys.unsetenv("EMBER_SECRET")      # cells must not see it
  settings_base <<- snapshot_settings()
  # An interrupt that arrives between cells (late, or while a message is
  # read) has nothing to stop: it is resumed where it landed. While a cell
  # runs, run_cell()'s own handlers are nearer and catch it first.
  repeat {
    withCallingHandlers(handle_next(), interrupt = ignore_interrupt)
  }
}

#' Continue after an interrupt as if it hadn't happened. R offers a
#' "resume" restart for a real SIGINT; a re-signalled one (see
#' `uninterrupted()`) has none, and returning simply carries on.
ignore_interrupt <- function(i) {
  if (!is.null(findRestart("resume"))) invokeRestart("resume")
}

#' Evaluate `expr` without letting an interrupt cut it short, then pass the
#' interrupt on. Used for wire reads and writes, where stopping partway
#' would leave half a frame, and for a cell's bookkeeping.
#' `suspendInterrupts()` isn't enough: on Linux a socket wait delivers the
#' interrupt anyway (seen in CI).
uninterrupted <- function(expr) {
  interrupted <- FALSE
  value <- withCallingHandlers(expr, interrupt = function(i) {
    interrupted <<- TRUE
    if (!is.null(findRestart("resume"))) invokeRestart("resume")
  })
  if (interrupted) {
    signalCondition(structure(class = c("interrupt", "condition"),
                              list(message = "", call = NULL)))
  }
  value
}

#' Read the next message (or take a deferred one) and act on it.
handle_next <- function() {
  msg <- if (length(deferred)) {
    m <- deferred[[1]]
    deferred <<- deferred[-1]
    m
  } else {
    receive()
  }
  if (is.null(msg)) quit(save = "no")  # server gone
  trace_line("message", msg$type)
  on.exit(trace_line("handled", msg$type))
  switch(msg$type,
    run = send(list(type = "done", cell = msg$cell, token = msg$token,
                     report = run_cell(msg))),
    remove_cell = {
      remove_cell(msg$cell)
      cell_order <<- msg$order
      rebuild_search_path()
    },
    drop_globals = drop_globals(msg$cell),
    chdir = {
      # getwd() is always the OS's canonical, symlink-resolved form (POSIX
      # getcwd()); `msg$from`/`msg$to` are the engine's own path strings,
      # which may not be (macOS's /tmp and /var are themselves symlinks).
      # Both sides are resolved once here, or every notebook under such a
      # path would fail the comparison below and never actually chdir,
      # and a resolved `cell_settings`/`settings_base` value would never
      # match an unresolved `from` on a later move.
      resolve <- function(p) tryCatch(normalizePath(p, winslash = "/", mustWork = FALSE), error = function(e) p)
      from <- resolve(msg$from)
      to <- resolve(msg$to)
      # `setwd()` throws if `to` is gone (deleted, or never created, by
      # the time this message is handled); nothing in handle_next()
      # catches an error that escapes here, so an uncaught one would kill
      # the worker over what the move's own form already warns can
      # happen (a relative read's folder changing underneath a running
      # notebook). The baseline still moves to `to`, matching a notebook
      # that did `setwd()` itself before the folder went away.
      if (identical(resolve(getwd()), from)) tryCatch(setwd(to), error = function(e) NULL)
      # The baseline and every cell's `setwd()` target move with the
      # notebook: a folder under the old one is the same folder under the
      # new one.
      move_path <- function(p) {
        rp <- resolve(p)
        if (identical(rp, from)) return(to)
        if (startsWith(rp, paste0(from, "/"))) return(paste0(to, substring(rp, nchar(from) + 1L)))
        p
      }
      settings_base$wd <<- move_path(settings_base$wd)
      cell_settings <<- lapply(cell_settings, function(chgs) {
        lapply(chgs, function(chg) {
          if (identical(chg$kind, "wd")) chg$after <- move_path(chg$after)
          chg
        })
      })
    },
    more = send(show_more(msg)),
    render = send(render_plot(msg)),
    complete = {
      r <- complete_line(msg$line, msg$cursor)
      send(list(type = "completions", id = msg$id, token = r$token, items = r$items, too_long = r$too_long))
    },
    help = {
      r <- help_lookup(msg$topic, msg$package, isTRUE(msg$all_packages))
      send(list(type = "help_page", id = msg$id, found = r$found, topic = r$topic,
               package = r$package, html = r$html, matches = r$matches))
    },
    signature = send(list(type = "signature", id = msg$id, text = worker_signature(msg$name, msg$package))),
    quit = quit(save = "no"),
    NULL  # noop, or an unknown type: ignored
  )
  invisible()
}

#' Write one wire frame, whole even if an interrupt arrives meanwhile.
send <- function(msg) {
  # Forced first: `msg` is often a promise for run_cell(), whose cell must
  # stay interruptible.
  force(msg)
  trace_line("send", msg$type)
  on.exit(trace_line("sent", msg$type))
  uninterrupted({
    payload <- serialize(msg, NULL)
    writeBin(length(payload), con, endian = "big")
    writeBin(payload, con)
    flush(con)
  })
  invisible()
}

#' Read one frame, or `NULL` when the server has gone. Whole even if an
#' interrupt arrives meanwhile: stopping partway would leave the rest on the
#' wire to be misread as the next frame's length.
receive <- function() {
  uninterrupted({
    header <- read_exactly(4L)
    if (is.null(header)) NULL else {
      n <- readBin(header, "integer", n = 1, endian = "big")
      payload <- read_exactly(n)
      if (is.null(payload)) NULL else unserialize(payload)
    }
  })
}

#' Exactly `n` bytes from the server, or `NULL` once it has closed the
#' socket. A signal can cut a blocking read short with nothing read (seen
#' on Linux), which looks like end of file; so each read waits until the
#' socket is readable, and only a readable socket that gives no bytes counts
#' as closed.
read_exactly <- function(n) {
  out <- raw(0)
  while (length(out) < n) {
    ready <- socketSelect(list(con), timeout = 1)
    trace_line("select", n, length(out), ready)
    if (!isTRUE(ready)) next
    more <- readBin(con, "raw", n = n - length(out))
    trace_line("read", length(more))
    if (length(more) == 0) return(NULL)
    out <- c(out, more)
  }
  out
}

#' With EMBER_WORKER_TRACE set, a line on stderr per step of the message
#' loop, for diagnosing a worker that stops answering on a machine we can't
#' log into.
trace_line <- function(...) {
  if (nzchar(Sys.getenv("EMBER_WORKER_TRACE"))) {
    cat("[worker]", format(Sys.time(), "%H:%M:%OS3"), ..., "\n", file = stderr())
  }
}

# ---- Running a cell ----------------------------------------------------------

#' Run one cell in globalenv() and return the report.
#'
#' Report: list(status = "ok"|"error"|"interrupted", output (display bundle
#' or NULL), console (list of items, also streamed), error (NULL or
#' list(message, call, traceback, span)), runtime, created, changed, removed,
#' settings, load_notes, attached (package -> exports, for packages newly
#' attached), formula_misses, globals (see summarise_globals())).
#' `error$span` is set only for role "text": the 1-based index of the
#' failing line (into `inline_spans()`'s rows).
#'
#' An interrupt that lands during the comparison steps (after the cell's
#' code) is caught around the whole function and reported as
#' "interrupted" with whatever facts were gathered so far, so bookkeeping
#' can't be left half done silently.
run_cell <- function(msg) {
  # Converging on the active library the way the search path converges on
  # `order` (worker.R's file header): a new package just needs `.libPaths()`
  # updated before the code runs, no restart, as long as nothing already
  # loaded changes version (the server's `switch_library()` is what decides
  # *when* it's safe to send a `library` that would change one).
  if (!is.null(msg$library) && !identical(.libPaths()[1], msg$library)) {
    .libPaths(msg$library)
  }

  rc <- list(status = "ok", output = NULL, console = list(), error = NULL,
             runtime = NA_real_, created = character(), changed = character(),
             removed = character(), settings = list(), load_notes = character(),
             attached = list(), formula_misses = character(), loaded = character(),
             globals = list())

  # `dev`/`console` are closed here (not just at their normal point of use
  # below) so an interrupt landing anywhere in this function -- including
  # after the cell's code finished, while display or bookkeeping is still
  # running -- can never leave a sink or a device open. Once the bookkeeping
  # block below (wrapped in `uninterrupted()`) has closed them itself,
  # it sets these back to NULL so this doesn't try to close them twice.
  dev <- NULL
  console <- NULL
  on.exit({
    if (!is.null(dev)) close_device(dev)
    if (!is.null(console)) console$finish()
    running <<- NULL
  })

  tryCatch({
    # `remove_cell()`/`apply_settings_context()` must be inside this same
    # guarded block, not before it: an interrupt landing in that narrow
    # window (between one cell's "done" and the next cell's code actually
    # starting) is otherwise uncaught, which halts the whole worker process
    # instead of reporting an "interrupted" cell (found via a test that
    # interrupts a cell within milliseconds of it starting).
    cell_order <<- msg$order
    remove_cell(msg$cell)
    apply_settings_context(msg$settings %||% character())

    before_names <- ls(globalenv(), all.names = TRUE)
    before <- snapshot_globals(before_names)
    settings0 <- snapshot_settings()
    load_log <<- list()
    attach_requests[[msg$cell]] <<- character()
    running <<- list(cell = msg$cell, token = msg$token)
    search0 <- search()
    fig <- msg$fig %||% FIGURE_DEFAULT
    dev <- open_device(fig)
    console <- console_collector(msg$cell, msg$token)
    for (p in fig$problems %||% character()) console$warning(simpleWarning(p))
    t0 <- proc.time()

    value <- NULL
    visible <- FALSE
    err <- NULL
    is_text <- identical(msg$role, "text")
    text_lines <- if (is_text) strsplit(msg$code, "\n", fixed = TRUE)[[1]] else character()
    inline_values <- character(length(text_lines))
    at <- 0L   # the text line being evaluated; reported as error$span
    # `srcfile = srcfilecopy(msg$cell, msg$code)` stamps the cell's id as
    # this parse's source file name, so a function defined here carries
    # it in its own srcref -- `clean_frames()` reads it back to say which
    # cell defined a traceback call's function.
    if (!is_text) exprs <- parse(text = msg$code, keep.source = TRUE,
                                 srcfile = srcfilecopy(msg$cell, msg$code))
    trace_line("eval", msg$cell)

    tryCatch(
      withCallingHandlers({
        if (is_text) {
          for (li in seq_along(text_lines)) {
            at <- li
            line_exprs <- parse(text = text_lines[[li]], keep.source = TRUE)
            # A line can hold more than one expression (`` `r a <- 2; a *
            # 3` ``, as knitr allows); all of them run, in order, and the
            # line's value is the last one's, with its own visibility.
            r <- withVisible(NULL)
            for (line_e in line_exprs) r <- withVisible(eval(line_e, globalenv()))
            inline_values[[li]] <- if (r$visible) inline_text(r$value) else ""
          }
        } else {
          for (k in seq_along(exprs)) {
            at <- k   # the top-level expression index; error$line reads its srcref
            r <- withVisible(eval(exprs[[k]], globalenv()))
            if (r$visible) {
              if (visible) console$print(value)
              value <- r$value
              visible <- TRUE
            }
          }
        }
      },
      message = function(m) { console$message(m); invokeRestart("muffleMessage") },
      warning = function(w) { console$warning(w); invokeRestart("muffleWarning") },
      error   = function(e) {
        # `sys.calls()` here always ends with this handler's own frame
        # (it's the currently executing call), so it's dropped
        # unconditionally rather than matched by text -- the fix for a
        # classed condition (stop(<condition object>), as every
        # rlang/cli error raises) whose signalling never passes through
        # the simpleError dispatch helpers the text patterns below catch.
        calls <- sys.calls()
        calls <- calls[-length(calls)]
        # One function object per call, by frame index, kept alongside
        # `calls` for `clean_frames()` below (sys.function(i) is only
        # answerable from inside this handler, while the stack is live).
        fns <- lapply(seq_along(calls), function(i) tryCatch(sys.function(i), error = function(e2) NULL))
        # A frame inside one of install_traces()'s loadNamespace/
        # library/require wrappers (identified by identity against the
        # real function it replaced, not by name: the wrapper always
        # calls it through a local variable named `original`, so by text
        # every such frame deparses identically regardless of which of
        # the three it is).
        is_original <- vapply(fns, function(fn) {
          !is.null(fn) && any(vapply(loader_originals, identical, logical(1), y = fn))
        }, logical(1))
        call <- conditionCall(e)
        if (!is.null(call) && identical(call, quote(original(...)))) {
          # The real loadNamespace()/library()/require() built its own
          # error's call from *its* caller, which -- from inside our
          # wrapper -- is the wrapper's own `original(...)` line, not the
          # line the notebook wrote (e.g. `library(notapkg)`). Report the
          # frame just above it instead, which is exactly that line: our
          # wrapper's `sys.call()` always returns the call as the
          # notebook wrote it, regardless of what the binding resolved to.
          idx <- which(vapply(calls, identical, logical(1), y = call))
          if (length(idx) && idx[1] > 1) call <- calls[[idx[1] - 1]]
        }
        # One line, for the wire and for the "is it the loop's own eval"
        # and "is it the top-level expression itself" checks below --
        # deparse() can return more than one element for a long call, and
        # `deparse_one_line()` also squashes a multi-line call's interior
        # indentation (`local({ ... })`'s body) to single spaces.
        call_text <- if (is.null(call)) NULL else deparse_one_line(call)
        # A bare top-level stop() (or any error raised with call. = FALSE)
        # leaves `call` as this loop's own eval() line -- `exprs[[k]]` for
        # a code cell, `line_e` for a text cell -- not anything the
        # notebook wrote; treated the same as no call at all. That
        # specific case has nothing worth a traceback either: its one
        # surviving frame is the failing call itself, already named by
        # `line`, so `frames` stays empty for it alone (test 127).
        is_bare_toplevel <- is_loop_eval_text(call_text)
        if (is_bare_toplevel) call_text <- NULL
        kept_calls <- calls[!is_original]
        kept_fns <- fns[!is_original]
        err_line <- NULL
        err_deep <- FALSE
        if (!is_text) {
          sr <- attr(exprs, "srcref")
          if (!is.null(sr) && at >= 1 && at <= length(sr)) err_line <- sr[[at]][1]
          if (!is.null(call_text)) {
            kept_texts <- vapply(kept_calls, deparse_one_line, character(1))
            outer_idx <- clean_range(kept_texts)
            outer_text <- if (length(outer_idx)) kept_texts[[outer_idx[1]]] else NULL
            toplevel_text <- deparse_one_line(exprs[[at]])
            err_deep <- !identical(call_text, outer_text) && !identical(call_text, toplevel_text)
          }
        }
        err <<- list(message = conditionMessage(e), call = call_text,
                     traceback = clean_calls(kept_calls),
                     # `e$package` is set by R's own loadNamespace()/library()
                     # for a packageNotFoundError regardless of locale, so the
                     # server can recognise a missing package without matching
                     # the (locale-translated) message text.
                     package = if (inherits(e, "packageNotFoundError")) e$package else NULL,
                     # Which text line (`inline_spans()$line` of the cell's
                     # analysed code) failed, for a text cell only.
                     span = if (is_text) at else NULL,
                     line = err_line,
                     deep = err_deep,
                     # Frames and traceback always have the same length,
                     # except for a bare top-level stop() (see
                     # `is_bare_toplevel` above): nothing the page would
                     # show beyond the message, which already says
                     # "Error" then a middle dot then "line n" with no
                     # call.
                     frames = if (is_bare_toplevel) list() else clean_frames(kept_calls, kept_fns))
      }),
      interrupt = function(i) rc$status <<- "interrupted",
      error     = function(e) rc$status <<- "error")

    # Everything from here on is bookkeeping, not cell evaluation: it must
    # finish once started, or the worker's own state (owned globals, the
    # settings baseline, attached packages) falls out of step with reality.
    # An interrupt arriving inside is passed on once the block completes
    # (caught by the `interrupt=` below), so the cell is reported
    # "interrupted" with the bookkeeping done.
    trace_line("evaluated", msg$cell, rc$status)
    uninterrupted({
      rc$runtime <- unname((proc.time() - t0)[["elapsed"]])
      if (!is.null(err)) rc$error <- err

      # Displaying runs the value's print and format methods, which are
      # the user's code too, so it can be interrupted like the cell.
      output <- NULL
      if (rc$status == "ok") {
        output <- tryCatch({
          if (is_text) {
            # A plot drawn by an inline expression is dropped: the display
            # step below only builds text (`inline_text()`, run already,
            # in the eval loop above).
            list(kind = "inline", mime = "application/vnd.ember.inline",
                values = inline_values, text = paste(inline_values, collapse = "\n"),
                truncated = FALSE)
          } else if (visible) {
            display_value(value, msg$cell, msg$token, dev, console)
          } else {
            display_plot(msg$cell, msg$token, dev)
          }
        }, interrupt = function(i) { rc$status <<- "interrupted"; NULL },
           error = function(e) NULL)
      }
      close_device(dev)
      dev <- NULL
      console$finish()
      rc$output <- output
      rc$console <- console$items
      console <- NULL
      running <<- NULL

      facts <- compare_globals(before_names, before)
      owned[[msg$cell]] <<- facts$created
      rc$created <- facts$created
      rc$changed <- facts$changed
      rc$removed <- facts$removed

      by_code <- settings_by_code(settings0, snapshot_settings(), load_log)
      settings_diffs <- by_code$settings
      rc$load_notes <- by_code$load_notes

      # Kept, not reverted: the next run's apply_settings_context() decides
      # whether this cell's changes apply (the server sends which settings
      # cells are in effect), so a cell found to set something at run
      # time becomes a settings cell instead of an error.
      cell_settings[[msg$cell]] <<- lapply(settings_diffs, function(d) {
        if (identical(d$kind, "search")) {
          search_added <<- union(search_added, setdiff(d$after, d$before))
          list(kind = "search", name = "search", added = setdiff(d$after, d$before))
        } else {
          list(kind = d$kind, name = d$name, after = d$after)
        }
      })
      for (d in settings_diffs) {
        key <- list(kind = d$kind, name = d$name)
        if (!any(vapply(touched, identical, logical(1), y = key))) touched[[length(touched) + 1]] <<- key
        # The starting theme normally comes from ggplot2's own load
        # (settings_by_code()); if that load wasn't seen, ggplot2's default.
        if (identical(d$kind, "theme") && is.null(settings_base$theme))
          settings_base$theme <<- get("theme_grey", envir = asNamespace("ggplot2"))()
      }
      # The server reads only kind and name (and a search diff's entries);
      # a theme's values are whole ggplot2 objects, which the server
      # process would have to unserialize, so they stay here.
      rc$settings <- lapply(settings_diffs, function(d) {
        if (identical(d$kind, "theme")) return(list(kind = "theme", name = "theme"))
        list(kind = d$kind, name = d$name, before = d$before, after = d$after)
      })

      # `attached[[cell]]` (for rebuild_search_path()) is every package the
      # cell's code named to library() this run, whether or not attaching it
      # was a no-op because it was already on the path (a plain search()
      # diff would miss that case, and so would wrongly drop the package
      # from the desired path on the next rebuild).
      attached[[msg$cell]] <<- attach_requests[[msg$cell]]
      ever_attached <<- union(ever_attached, attach_requests[[msg$cell]])
      rc$loaded <- loaded_namespace_versions()

      new_pkgs <- setdiff(packages_on_search(search()), packages_on_search(search0))
      rc$attached <- stats::setNames(
        lapply(new_pkgs, function(p) tryCatch(getNamespaceExports(p), error = function(e) character())),
        new_pkgs)

      rebuild_search_path()

      rc$formula_misses <- check_formulas(msg$formulas)
      trace_line("bookkept", msg$cell)
    })

    # Outside uninterrupted(), as display is (worker.R's doc above): a
    # user's str() or format() method may be slow, so an interrupt here
    # stops the summaries, not the cell's already-gathered facts. Only an
    # "ok" run's globals are ever kept by the engine (its result's
    # variables are about to be dropped otherwise), so a failed or
    # interrupted run skips the work entirely.
    if (identical(rc$status, "ok")) {
      rc$globals <- tryCatch(summarise_globals(facts$created),
                             interrupt = function(i) list(), error = function(e) list())
    }
    trace_line("summarised", msg$cell)
  }, interrupt = function(i) {
    rc$status <<- "interrupted"
  })

  rc
}

#' Remove a cell's globals and display data (before a rerun, or on delete).
remove_cell <- function(cell) {
  globals <- owned[[cell]]
  if (length(globals)) {
    existing <- intersect(globals, ls(globalenv(), all.names = TRUE))
    if (length(existing)) rm(list = existing, envir = globalenv())
  }
  owned[[cell]] <<- NULL
  display[[cell]] <<- NULL
  attached[[cell]] <<- NULL
  cell_settings[[cell]] <<- NULL
}

#' Remove a failed cell's globals, keeping what it attached to the search
#' path (unlike remove_cell(), which also detaches and drops display data).
drop_globals <- function(cell) {
  globals <- owned[[cell]]
  if (length(globals)) {
    existing <- intersect(globals, ls(globalenv(), all.names = TRUE))
    if (length(existing)) rm(list = existing, envir = globalenv())
  }
  owned[[cell]] <<- character()
}

#' A snapshot of the named globals, for later comparison. Active bindings
#' are captured by their function (never called: calling one could run
#' code or have side effects, e.g. a counter).
snapshot_globals <- function(names) {
  out <- vector("list", length(names))
  names(out) <- names
  for (n in names) {
    if (bindingIsActive(n, globalenv())) {
      out[[n]] <- list(active = TRUE, fn = activeBindingFunction(n, globalenv()))
    } else {
      out[[n]] <- list(active = FALSE, value = get(n, envir = globalenv(), inherits = FALSE))
    }
  }
  out
}

#' Compare globals after a run with the references kept before.
#'
#' `before` is a `snapshot_globals()` result. `.Random.seed` is skipped.
#' Active bindings are compared by binding (the function), not value.
compare_globals <- function(before_names, before) {
  now <- setdiff(ls(globalenv(), all.names = TRUE), ".Random.seed")
  before_names <- setdiff(before_names, ".Random.seed")
  created <- setdiff(now, before_names)
  removed <- setdiff(before_names, now)
  common <- intersect(before_names, now)
  changed <- character()
  for (n in common) {
    b <- before[[n]]
    now_active <- bindingIsActive(n, globalenv())
    if (b$active || now_active) {
      before_fn <- if (b$active) b$fn else NULL
      now_fn <- if (now_active) activeBindingFunction(n, globalenv()) else NULL
      if (b$active != now_active || !identical(before_fn, now_fn)) changed <- c(changed, n)
    } else {
      now_val <- get(n, envir = globalenv(), inherits = FALSE)
      if (!identical(b$value, now_val)) changed <- c(changed, n)
    }
  }
  list(created = created, changed = changed, removed = removed)
}

#' At most 80 characters, cut with "\u2026" (the whole string, ellipsis
#' included, never exceeds 80).
truncate80 <- function(text) {
  if (nchar(text) <= 80) return(text)
  paste0(substr(text, 1, 79), "\u2026")
}

#' `"<n> rows \u00d7 <m> columns"` ("1 row"/"1 column" singular), `n`/`m`
#' with a thousands separator.
shape_text <- function(nr, nc) {
  rows <- if (identical(nr, 1L) || identical(nr, 1)) "1 row" else paste(format(nr, big.mark = ","), "rows")
  cols <- if (identical(nc, 1L) || identical(nc, 1)) "1 column" else paste(format(nc, big.mark = ","), "columns")
  paste0(rows, " \u00d7 ", cols)
}

#' One global's type and a short value, summarise_globals()'s table.
#' `x` is the value itself (never an active binding -- the caller handles
#' that without calling it).
summarise_value <- function(x) {
  if (is.null(x)) return(list(value = "NULL", kind = "value"))
  if (is.function(x)) {
    args <- paste(names(formals(args(x))), collapse = ", ")
    return(list(value = paste0("function(", args, ")"), kind = "value"))
  }
  if (is.data.frame(x)) return(list(value = shape_text(nrow(x), ncol(x)), kind = "shape"))
  if (is.matrix(x) || is.array(x)) {
    d <- dim(x)
    if (length(d) == 2) return(list(value = shape_text(d[[1]], d[[2]]), kind = "shape"))
    return(list(value = paste(paste(d, collapse = " \u00d7 "), "array"), kind = "shape"))
  }
  if ((is.atomic(x) && is.null(attr(x, "class"))) || inherits(x, c("Date", "POSIXct", "difftime"))) {
    if (length(x) == 0) return(list(value = deparse(x), kind = "value"))
    vals <- eval_in_notebook(
      quote(format(head(v, 20), trim = TRUE, justify = "none", na.encode = FALSE)), x)
    if (is.character(x)) vals <- encodeString(vals, quote = "\"")
    return(list(value = paste(vals, collapse = " "), kind = "value"))
  }
  lines <- utils::capture.output(
    eval_in_notebook(quote(utils::str(v, max.level = 0, give.attr = FALSE, vec.len = 2)), x))
  list(value = trimws(lines[[1]]), kind = "str")
}

#' One global's type, kind and value, or (`type_only`) just its type with
#' kind "none" (the over-budget path). Both branches check
#' `bindingIsActive()` before any `get()`, so an active binding is never
#' called either way.
#'
#' Bounded to `remaining` seconds with `setTimeLimit()`, `transient =
#' TRUE` and reset with `on.exit()`: a single slow `format()`/`str()`
#' method (the user's own code) can't hold up the whole `done` report by
#' blowing the per-run budget on its own, and the limit can never leak
#' into the user's later code or an interrupt sent afterwards, since it's
#' always cleared before this returns, on every path including an error.
#' A timeout raises same as any other error, so the existing `tryCatch`
#' below turns it into kind "none" with no special case.
summarise_one <- function(name, remaining, type_only = FALSE) {
  if (bindingIsActive(name, globalenv())) {
    return(list(type = "active binding", value = NULL, kind = "none"))
  }
  x <- get(name, envir = globalenv(), inherits = FALSE)
  type <- tryCatch(class(x)[1], error = function(e) "unknown")
  if (type_only) return(list(type = type, value = NULL, kind = "none"))
  setTimeLimit(elapsed = max(remaining, 0), transient = TRUE)
  on.exit(setTimeLimit(elapsed = Inf, transient = TRUE))
  r <- tryCatch(summarise_value(x), error = function(e) list(value = NULL, kind = "none"))
  list(type = type, value = if (is.null(r$value)) NULL else truncate80(r$value), kind = r$kind)
}

#' One line per global the cell owns: type and a short value.
#' Names in alphabetical order; stops summarising after 0.25 s in total and
#' gives the rest kind = "none" (type only). A dot-name's value is never
#' computed either, type only, same as over budget: the engine drops it
#' before it ever reaches a page. Active bindings are never called. Every
#' format()/str() call goes through eval_in_notebook() so the notebook's
#' own S3 methods are used, in a tryCatch (an error, or a timeout against
#' what's left of the 0.25 s, gives kind "none").
#' @return named list name -> list(type, value, kind); `value` NULL when
#'   kind is "none". At most 80 characters, cut with "\u2026".
summarise_globals <- function(names) {
  names <- sort(names)
  out <- stats::setNames(vector("list", length(names)), names)
  budget <- 0.25
  t0 <- proc.time()[["elapsed"]]
  for (name in names) {
    # A dot-name (private, as the graph treats it) is dropped by the
    # engine before it ever reaches a page, so its value is never worth
    # computing -- or worth spending any of the shared budget on.
    private <- startsWith(name, ".")
    remaining <- budget - (proc.time()[["elapsed"]] - t0)
    out[[name]] <- summarise_one(name, remaining, type_only = private || remaining <= 0)
  }
  out
}

# ---- Global settings -----------------------------------------------------------

#' The non-package part of the search path: attach()ed data and
#' environments. Package entries are handled by the attach bookkeeping,
#' not as a setting.
search_non_package <- function() {
  s <- search()
  s[s != ".GlobalEnv" & !grepl("^package:", s)]
}

#' Package names currently on the search path, in `search()` order.
packages_on_search <- function(s = search()) {
  sub("^package:", "", grep("^package:", s, value = TRUE))
}

#' The locale categories snapshotted and restored individually. Not every
#' category exists on every platform (LC_MESSAGES is absent on Windows),
#' so `snapshot_locale()` only keeps the ones `Sys.getlocale()` answers.
locale_category_names <- c("LC_COLLATE", "LC_CTYPE", "LC_MONETARY",
                            "LC_NUMERIC", "LC_TIME", "LC_MESSAGES")

#' Each available locale category's current value, as a named list.
#'
#' Not the combined `Sys.getlocale()` string: macOS's `Sys.setlocale()`
#' refuses a combined string passed back via `category = "LC_ALL"` (the
#' locale a cell leaves behind can't be restored), so categories are
#' snapshotted and later restored one at a time instead.
snapshot_locale <- function() {
  out <- list()
  for (cat in locale_category_names) {
    val <- tryCatch(Sys.getlocale(cat), error = function(e) NA_character_)
    if (!is.na(val)) out[[cat]] <- val
  }
  out
}

#' ggplot2's current theme, or `NULL` while ggplot2 isn't loaded. ggplot2
#' keeps the theme in its namespace, so comparing options alone would never
#' see `theme_set()` (settings-cells.md, Open questions: ggplot2's theme).
current_theme <- function() {
  if (!("ggplot2" %in% loadedNamespaces())) return(NULL)
  tryCatch(get("theme_get", envir = asNamespace("ggplot2"))(), error = function(e) NULL)
}

#' The global settings, as one comparable value.
snapshot_settings <- function() {
  list(options = options(), env = as.list(Sys.getenv()), wd = getwd(),
       locale = snapshot_locale(), search = search_non_package(),
       theme = current_theme())
}

#' Compare two settings snapshots. Returns list(kind, name, before, after)
#' for every option, environment variable, locale category and the
#' (non-package) search path that differ, plus the working directory.
diff_settings <- function(before, after) {
  diff_named <- function(b, a, kind) {
    diffs <- list()
    for (n in union(names(b), names(a))) {
      bv <- if (n %in% names(b)) b[[n]] else NULL
      av <- if (n %in% names(a)) a[[n]] else NULL
      if (!identical(bv, av)) diffs[[length(diffs) + 1]] <- list(kind = kind, name = n, before = bv, after = av)
    }
    diffs
  }
  diffs <- c(diff_named(before$options, after$options, "option"),
             diff_named(before$env, after$env, "env"),
             diff_named(before$locale, after$locale, "locale"))
  if (!identical(before$wd, after$wd))
    diffs <- c(diffs, list(list(kind = "wd", name = "wd", before = before$wd, after = after$wd)))
  if (!identical(before$search, after$search))
    diffs <- c(diffs, list(list(kind = "search", name = "search", before = before$search, after = after$search)))
  # ggplot2 loading takes the theme from NULL to its default. Inside a
  # package load that is the load's own change (settings_by_code() makes it
  # part of the starting values), so a `library(ggplot2); theme_set(...)`
  # cell still shows its theme_set(). Unloading (to NULL) is no change.
  if (!is.null(after$theme) && !identical(before$theme, after$theme))
    diffs <- c(diffs, list(list(kind = "theme", name = "theme", before = before$theme, after = after$theme)))
  diffs
}

#' Read one setting's value out of a `snapshot_settings()` value.
get_setting <- function(settings, kind, name) {
  switch(kind,
    option = settings$options[[name]],
    env = settings$env[[name]],
    wd = settings$wd,
    locale = settings$locale[[name]],
    search = settings$search,
    theme = settings$theme,
    NULL)
}

#' Return `settings` with one key replaced, for forward-propagating a
#' package load's change onto a baseline snapshot.
set_setting <- function(settings, kind, name, value) {
  switch(kind,
    option = { settings$options[[name]] <- value; settings },
    env = { settings$env[[name]] <- value; settings },
    wd = { settings$wd <- value; settings },
    locale = { settings$locale[[name]] <- value; settings },
    search = { settings$search <- value; settings },
    theme = { settings$theme <- value; settings },
    settings)
}

#' Put one setting change back into the live process. For `locale`, `name`
#' is the category (e.g. "LC_COLLATE") and `value` that category's own
#' locale string, set individually rather than through "LC_ALL" (see
#' `snapshot_locale()`).
apply_setting <- function(kind, name, value) {
  switch(kind,
    option = {
      args <- stats::setNames(list(value), name)
      options(args)
    },
    env = {
      if (is.null(value)) Sys.unsetenv(name)
      else do.call(Sys.setenv, stats::setNames(list(value), name))
    },
    wd = setwd(value),
    locale = Sys.setlocale(category = name, locale = value),
    search = revert_search(value),
    theme = if (!is.null(value) && "ggplot2" %in% loadedNamespaces()) {
      get("theme_set", envir = asNamespace("ggplot2"))(value)
    },
    NULL)
  invisible()
}

#' Best-effort reversal of a change to the non-package search path
#' (attach()/detach() of data and environments): detach whatever is on
#' the path now but wasn't in `target`. A position removed from the path
#' (something was detach()ed by the cell) can't be recreated, since its
#' contents are gone; this is a known limitation (see the worker's report
#' to the core).
revert_search <- function(target) {
  now <- search_non_package()
  extra <- setdiff(now, target)
  for (nm in extra) {
    pos <- match(nm, search())
    if (!is.na(pos)) tryCatch(detach(pos = pos), error = function(e) NULL)
  }
  invisible()
}

#' Changes made by the cell's own code: settings changes not explained by
#' package loads. Returns list(settings = list(kind, name, before, after),
#' load_notes = character()).
settings_by_code <- function(settings0, after, load_log) {
  baseline <- settings0
  notes <- character()
  for (entry in load_log) {
    for (chg in entry$changes) {
      baseline_val <- get_setting(baseline, chg$kind, chg$name)
      start_val <- get_setting(settings_base, chg$kind, chg$name)
      notebook_set <- !identical(baseline_val, start_val)
      if (notebook_set && !identical(baseline_val, chg$after)) {
        notes <- c(notes, sprintf("package %s changed %s %s, which the notebook set",
                                   entry$package, chg$kind, chg$name))
      }
      baseline <- set_setting(baseline, chg$kind, chg$name, chg$after)
      # A package's own change is part of the starting values from now on.
      settings_base <<- set_setting(settings_base, chg$kind, chg$name, chg$after)
    }
  }
  list(settings = diff_settings(baseline, after), load_notes = notes)
}

#' Before a cell runs (settings-cells.md, What the worker does before each
#' run): put every setting any cell has changed back to the baseline, then
#' apply the changes of the settings cells in effect, `ids`, in order.
#' Settings no cell touched are left alone. `attach()` is best effort:
#' entries a cell added are detached unless that cell is in `ids`, and
#' nothing detached is re-attached (its contents are gone).
apply_settings_context <- function(ids) {
  for (key in touched) {
    if (identical(key$kind, "search")) next
    value <- get_setting(settings_base, key$kind, key$name)
    tryCatch(apply_setting(key$kind, key$name, value), error = function(e) NULL)
  }
  keep <- settings_base$search
  for (id in ids) {
    for (chg in cell_settings[[id]] %||% list()) {
      if (identical(chg$kind, "search")) {
        keep <- union(keep, chg$added)
      } else {
        tryCatch(apply_setting(chg$kind, chg$name, chg$after), error = function(e) NULL)
      }
    }
  }
  if (length(search_added) > 0) {
    revert_search(union(keep, setdiff(search_non_package(), search_added)))
  }
  invisible()
}

# ---- Tracing package loads and source() ---------------------------------------

#' Push a load frame (called from the `loadNamespace`/`library` wrapper
#' `install_traces()` installs, with the package name already read
#' unevaluated from the call, so a bare `library(dplyr)` with no object
#' named `dplyr` is never forced and never errors).
ember_load_enter <- function(pkg) {
  load_stack[[length(load_stack) + 1]] <<- list(package = pkg, before = snapshot_settings())
}

#' Called at the end of `loadNamespace()`/`library()`. Diffs against the
#' snapshot `ember_load_enter()` pushed, records the change in `load_log`,
#' and forward-propagates it onto any still-open outer frame (a nested
#' load, from a Depends/Imports chain) so the outer frame's own diff
#' doesn't report the same change again.
ember_load_exit <- function() {
  if (!length(load_stack)) return(invisible())
  frame <- load_stack[[length(load_stack)]]
  stack <- load_stack[-length(load_stack)]
  after <- snapshot_settings()
  diffs <- diff_settings(frame$before, after)
  if (length(diffs)) {
    load_log[[length(load_log) + 1]] <<- list(package = frame$package, changes = diffs)
    if (length(stack)) {
      for (i in seq_along(stack)) {
        for (d in diffs) stack[[i]]$before <- set_setting(stack[[i]]$before, d$kind, d$name, d$after)
      }
    }
  }
  load_stack <<- stack
  invisible()
}

#' Attach tracking for `library()`/`require()`: which package name the
#' call actually resolved to, for `attach_requests`.
#'
#' A bare `library(dplyr)` is read off the unevaluated call text (`pe`),
#' same as always, so an object named `dplyr` existing in the notebook is
#' never forced. `character.only = TRUE` (and `require()`'s default
#' `character.only` behaviour when `pe` is itself a symbol bound to a
#' string) means the package name is a value, not a literal, so the
#' literal-text reading above would get the variable's name ("p") instead
#' of what it holds ("emberfix2"); evaluating `pe` is safe exactly when
#' `character.only` is set, since that's the caller declaring the argument
#' is a value to be read, not a name to capture unevaluated. Either way
#' this is cross-checked against which package(s) actually newly appeared
#' on the search path (`before_search`/`after_search`): if the text-based
#' name doesn't resolve to one of them, but exactly one new package did
#' appear, that's used instead, so a `character.only` call whose argument
#' couldn't be evaluated here still gets tracked.
resolve_attach_name <- function(pe, char_only, call_env, before_search, after_search) {
  pkg <- NA_character_
  if (isTRUE(char_only)) {
    pkg <- tryCatch(as.character(eval(pe, envir = call_env))[1], error = function(e) NA_character_)
  } else {
    pkg <- tryCatch({
      if (is.character(pe)) pe[1]
      else if (is.name(pe)) as.character(pe)
      else deparse(pe)
    }, error = function(e) NA_character_)
  }
  if (!is.na(pkg) && pkg %in% after_search) return(pkg)
  newly <- setdiff(after_search, before_search)
  if (length(newly) == 1) return(newly)
  NA_character_
}

#' Replace loadNamespace, library and require in baseenv() with a wrapper
#' that records a settings snapshot before and after the real function
#' runs, plus traces on base::source and sys.source for computed source()
#' tracking.
#'
#' This does not use `trace(..., exit = ...)`: `trace()` implements `exit`
#' by inserting `on.exit(<exit expr>, add = TRUE)` into the TRACED
#' function's own body, but `loadNamespace()`'s own code calls bare
#' `on.exit()` (no arguments, clearing its frame's pending exit
#' expressions) near the end of a successful load, which silently drops
#' our exit hook along with it (measured: `ember_load_enter()` fired,
#' `ember_load_exit()` never did). A deviation from the sketch, which
#' called for `trace(..., tracer = quote(ember_load_enter()), exit =
#' quote(ember_load_exit()))`; replacing the binding instead puts our
#' `on.exit()` in a frame of our own that the real function never touches,
#' so it always fires, and lets us read the package name off our own
#' `sys.call()` directly, with no `substitute()`/`parent.frame()` games.
#' `library()`'s `.onAttach` hooks can set options too (openxlsx,
#' tidyverse); nested loads (a Depends/Imports chain) nest on the
#' `load_stack`, so each change is attributed once. Because the wrapper
#' replaces the binding in `baseenv()` itself, a nested call from inside
#' real `library()`'s own code to `loadNamespace()` resolves to our
#' wrapper too (lexical scoping from a base closure starts at `baseenv()`),
#' with no extra plumbing. `require()` is wrapped the same way: it never
#' calls user-visible `library()` internally, so without its own wrapper
#' `require(pkg)` would attach the package but never show up in
#' `attach_requests`, and `rebuild_search_path()` would detach it again on
#' the next edit or delete.
#'
#' `original` (the real function this installs over) is kept in
#' `loader_originals` so a traceback can recognize, and drop, the
#' wrapper's own frame by identity rather than by matching its deparsed
#' text (see `clean_calls()`'s caller).
install_traces <- function() {
  base_env <- baseenv()
  wrap_loader <- function(name) {
    original <- get(name, envir = base_env, inherits = FALSE)
    loader_originals[[length(loader_originals) + 1]] <<- original
    wrapped <- function(...) {
      mc <- sys.call()
      call_env <- parent.frame()
      matched <- tryCatch(match.call(original, mc), error = function(e) NULL)
      pe <- if (!is.null(matched)) matched[["package"]] else NULL
      char_arg <- if (!is.null(matched)) matched[["character.only"]] else NULL
      char_only <- isTRUE(tryCatch(eval(char_arg, envir = call_env), error = function(e) FALSE))
      attachable <- identical(name, "library") || identical(name, "require")
      before_search <- if (attachable) packages_on_search(search()) else character()
      pkg <- if (!is.null(pe)) {
        if (char_only) NA_character_
        else tryCatch({
          if (is.character(pe)) pe[1]
          else if (is.name(pe)) as.character(pe)
          else deparse(pe)
        }, error = function(e) NA_character_)
      } else NA_character_
      ember_load_enter(pkg)
      on.exit(ember_load_exit(), add = TRUE)
      # Called as the notebook wrote it (`library(x)`, not `original(...)`),
      # so the error call and the function's own sys.call() are the user's.
      real_call <- mc
      real_call[[1]] <- as.name(name)
      result <- withVisible(eval(real_call, list2env(stats::setNames(list(original), name),
                                                     parent = call_env)))
      # library()/require(): record that this cell named a package for
      # attaching, whether or not attaching it was a no-op because it was
      # already on the path (a plain search() diff would miss that case,
      # and so would wrongly drop the package from the desired path on
      # the next rebuild -- see the note at attach_requests's use).
      if (attachable && !is.null(running) && !is.null(pe)) {
        after_search <- packages_on_search(search())
        resolved <- resolve_attach_name(pe, char_only, call_env, before_search, after_search)
        if (!is.na(resolved)) {
          attach_requests[[running$cell]] <<- union(attach_requests[[running$cell]], resolved)
        }
      }
      if (result$visible) result$value else invisible(result$value)
    }
    unlockBinding(name, base_env)
    assign(name, wrapped, envir = base_env)
    lockBinding(name, base_env)
  }
  wrap_loader("loadNamespace")
  wrap_loader("library")
  wrap_loader("require")

  source_call <- bquote((.(ember_trace_source))())
  trace(base::source, where = base_env, print = FALSE, tracer = source_call)
  trace(sys.source, where = base_env, print = FALSE, tracer = source_call)
  protect_closeall(base_env)
  invisible()
}

#' Replace closeAllConnections() with a version that leaves the worker's
#' own socket (`con`) open: a notebook cell that calls it (to clean up its
#' own leaked connections) would otherwise sever the worker from the
#' server with no way to recover, since R has no "protected connection"
#' flag to ask for instead. Same binding-replacement approach as
#' `wrap_loader()`.
protect_closeall <- function(base_env) {
  wrapped <- function() {
    keep <- tryCatch(as.integer(con), error = function(e) NA_integer_)
    ids <- getAllConnections()
    ids <- ids[ids > 2L & ids != keep]
    for (i in ids) tryCatch(close(getConnection(i)), error = function(e) NULL)
    invisible()
  }
  unlockBinding("closeAllConnections", base_env)
  assign("closeAllConnections", wrapped, envir = base_env)
  lockBinding("closeAllConnections", base_env)
  invisible()
}

#' Wrapper called (by value) at the start of source()/sys.source(): reads
#' `file` from the traced function's own frame (safe to force; source()
#' needs it immediately too) and hands it to `trace_source()`.
ember_trace_source <- function() {
  caller <- parent.frame()
  file_val <- tryCatch(get("file", envir = caller), error = function(e) NULL)
  trace_source(file_val)
}

#' Tracer body for base::source and sys.source, active only during a run.
#' Literal paths go through the same request; the server answers at once.
#'
#' `loadNamespace()` uses `sys.source()` internally to build a package's
#' namespace (measured: triggers even for a plain fixture package with no
#' explicit `source()` call anywhere). `length(load_stack) > 0` means
#' we're inside a traced `loadNamespace()`/`library()` call, so this isn't
#' the cell's own code calling `source()`; it's package loading, which is
#' already exempt from cell-code rules the same way a setting change
#' inside a package load is (a deviation from the sketch, which checked
#' only `running`).
trace_source <- function(file) {
  if (is.null(running) || length(load_stack) > 0 || inherits(file, "connection")) return(invisible())
  trace_line("source", file)
  path <- tryCatch(normalizePath(file, mustWork = FALSE), error = function(e) as.character(file))
  text <- tryCatch(paste(readLines(path, warn = FALSE), collapse = "\n"), error = function(e) NA_character_)
  send(list(type = "source", cell = running$cell, token = running$token, path = path, text = text))
  reply <- NULL
  repeat {
    reply <- receive()
    if (is.null(reply)) quit(save = "no")  # server gone
    if (identical(reply$type, "source_reply")) break
    deferred[[length(deferred) + 1]] <<- reply
  }
  if (!isTRUE(reply$allow)) {
    msg <- if (is.null(reply$message)) "source refused" else reply$message
    stop(msg, call. = FALSE)
  }
  invisible()
}

# ---- Attached packages ---------------------------------------------------------

#' Keep the search path in step with the notebook (design.md, Attached
#' packages): detach what the notebook attached, reattach the current
#' desired set in file order. Namespaces stay loaded; only attachment
#' changes. Packages a notebook package attaches itself (Depends) come
#' back with it, and masking then follows file order.
rebuild_search_path <- function() {
  # `desired` is in ATTACH order (library() is called down this list, so
  # the last entry ends up on top of search()). `search()`/`on_path` are
  # in the opposite order (most-recently-attached first), so the
  # no-op check compares against `rev(desired)`, not `desired` itself.
  desired <- unique(unlist(attached[cell_order], use.names = FALSE))
  known <- ever_attached
  on_path <- packages_on_search(search())
  managed_on_path <- on_path[on_path %in% union(desired, known)]
  if (identical(managed_on_path, rev(desired))) return(invisible())
  for (p in managed_on_path) {
    tryCatch(detach(paste0("package:", p), character.only = TRUE, unload = FALSE, force = TRUE),
             error = function(e) NULL)
  }
  for (p in desired) {
    tryCatch(library(p, character.only = TRUE), error = function(e) NULL)
  }
  invisible()
}

# ---- Formulas ------------------------------------------------------------------------

#' Is `e` a symbol, or a `$`/`[[` chain (with a literal index) on one?
#' These are the only `data` expressions safe to re-evaluate after the
#' cell ran: anything else (a function call) could have side effects.
is_data_path <- function(e) {
  if (is.symbol(e)) return(TRUE)
  if (is.call(e) && length(e) == 3 && is.symbol(e[[1]])) {
    head <- as.character(e[[1]])
    if (identical(head, "$")) return(is_data_path(e[[2]]))
    if (identical(head, "[[")) {
      idx <- e[[3]]
      if (is.character(idx) || is.numeric(idx)) return(is_data_path(e[[2]]))
    }
  }
  FALSE
}

#' After the run: which names taken as columns are not in the data.
check_formulas <- function(formulas) {
  misses <- character()
  for (site in formulas) {
    data_text <- site$data
    if (is.null(data_text) || !nzchar(data_text)) next
    expr <- tryCatch(parse(text = data_text, keep.source = FALSE)[[1]], error = function(e) NULL)
    if (is.null(expr) || !is_data_path(expr)) next
    val <- tryCatch(eval(expr, envir = globalenv()), error = function(e) NULL)
    nms <- tryCatch(names(val), error = function(e) NULL)
    if (is.null(nms)) next
    miss <- setdiff(site$columns, nms)
    if (length(miss)) misses <- c(misses, miss)
  }
  unique(misses)
}

# ---- Console and devices -----------------------------------------------------------------

#' Collect console items in order and stream each to the server.
#'
#' stdout is captured with sink() into a textConnection; before a message
#' or warning item is added, whatever stdout has accumulated becomes a
#' "stdout" item first, so the order is kept. Each item is sent as a
#' `console` frame as soon as it is complete. Total console text per cell
#' is capped (1 MB); past it a single "output truncated" item is added and
#' the rest dropped.
console_collector <- function(cell, token) {
  self <- new.env()
  self$items <- list()
  self$capped <- FALSE
  self$total <- 0L
  self$read_pos <- 0
  self$limit <- 1024L * 1024L
  # A real file, not textConnection(): textConnectionValue() only surfaces
  # complete (newline-terminated) lines, so cat("a") with no trailing
  # newline would stay invisible until something else wrote a newline,
  # arriving out of order relative to a message()/warning() that follows
  # it immediately (measured: this is exactly what happened). A file,
  # read back by byte position after flush(), has no such buffering.
  self$path <- tempfile("ember_console_")
  self$out <- file(self$path, open = "wt")
  self$base_sink_level <- sink.number()  # see self$finish(): a sink() in
                                          # the cell's own code must not be
                                          # able to pop our diversion
  sink(self$out, type = "output")

  # `call` is the deparsed call behind a warning item (one line), kept
  # only when set -- a message item, or a warning with none, carries no
  # `call` key at all, rather than an explicit NULL.
  add_item <- function(kind, text, call = NULL) {
    if (self$capped) return(invisible())
    self$total <- self$total + nchar(text, type = "bytes")
    if (self$total > self$limit) {
      item <- list(kind = "text", text = "output truncated")
      self$items[[length(self$items) + 1]] <- item
      self$capped <- TRUE
      send(list(type = "console", cell = cell, token = token, item = item))
      return(invisible())
    }
    item <- if (is.null(call)) list(kind = kind, text = text) else list(kind = kind, text = text, call = call)
    self$items[[length(self$items) + 1]] <- item
    send(list(type = "console", cell = cell, token = token, item = item))
  }

  flush_stdout <- function() {
    flush(self$out)
    size <- file.info(self$path)$size
    if (is.na(size) || size <= self$read_pos) return(invisible())
    con <- file(self$path, open = "rb")
    on.exit(close(con))
    seek(con, self$read_pos)
    raw_bytes <- readBin(con, "raw", n = size - self$read_pos)
    self$read_pos <- size
    # The sink file is in text mode, which writes "\r\n" on Windows.
    txt <- gsub("\r\n", "\n", rawToChar(raw_bytes), fixed = TRUE)
    if (nzchar(txt)) add_item("stdout", txt)
  }

  self$message <- function(m) { flush_stdout(); add_item("message", conditionMessage(m)) }
  self$warning <- function(w) {
    flush_stdout()
    call <- conditionCall(w)
    call_text <- if (is.null(call)) NULL else deparse_one_line(call)
    # A bare top-level warning() carries the eval loop's own call, not
    # anything the notebook wrote (the same case `run_cell()`'s error
    # handler nulls out); treated as no call at all. Code and text cells
    # loop over different variables (`exprs[[k]]`, `line_e`), so both
    # eval() calls are checked.
    if (is_loop_eval_text(call_text)) call_text <- NULL
    add_item("warning", conditionMessage(w), call = call_text)
  }
  self$print <- function(v) {
    flush_stdout()
    txt <- paste(utils::capture.output(eval_in_notebook(quote(print(v)), v)), collapse = "\n")
    add_item("stdout", txt)
  }
  self$finish <- function() {
    flush_stdout()
    # The cell's own code may have called sink() (removing our diversion,
    # or pushing and popping its own on top of it): pop back down to
    # exactly the level this collector started at, rather than assuming
    # our one sink() call is still the top of the stack to undo.
    while (sink.number() > self$base_sink_level) sink(type = "output")
    close(self$out)
    unlink(self$path)
  }
  self
}

#' `fig$width`/`height` when both are finite numbers above 0, else
#' `FIGURE_DEFAULT`'s matching side. A hand-built `run`/`render` message
#' (a test, or any future caller) must not reach `figure_pixels()` with a
#' missing or non-numeric side: `round(NULL * res)` is `numeric(0)`, which
#' crashes `ragg::agg_png()`/`grDevices::png()`'s `width=`/`height=` with
#' an uncaught error -- fatal here, since nothing in `handle_next()`
#' catches one.
safe_fig <- function(fig) {
  side <- function(x, default) {
    if (is.numeric(x) && length(x) == 1 && is.finite(x) && x > 0) x else default
  }
  list(width = side(fig$width, FIGURE_DEFAULT$width), height = side(fig$height, FIGURE_DEFAULT$height))
}

#' Pixel size for a figure device or redraw: `fig` (list(width, height),
#' inches; sanitised by `safe_fig()`) at `res` dpi, `res` lowered -- never
#' raised -- just enough that neither side exceeds `MAX_FIGURE_PX`. A 7.5
#' x 5 in figure stays at `res` (192 for the first draw, nowhere near the
#' cap); a hand-built `fig`/`res` pair that would otherwise allocate an
#' unreasonably large bitmap (a 30 in figure asked for at `res` 384, say)
#' is capped instead. `res`'s own type is kept when it isn't lowered, so
#' an integer `res` (as the wire sends it) stays comparable to one.
#' @return list(width, height, res)
figure_pixels <- function(fig, res) {
  fig <- safe_fig(fig)
  cap_res <- MAX_FIGURE_PX / max(fig$width, fig$height)
  if (cap_res < res) res <- cap_res
  list(width = round(fig$width * res), height = round(fig$height * res), res = res)
}

#' `width`/`height` pixels each capped at `MAX_FIGURE_PX`, for
#' `render_plot()`'s explicit-size path (`render_png()`'s API): two
#' independent pixel counts, not a figure size times a density, so each
#' side is simply capped on its own rather than scaled together. Each
#' side's own type (integer, as the wire sends it) is kept when it isn't
#' capped.
clamp_pixels <- function(width, height) {
  list(width = if (width > MAX_FIGURE_PX) MAX_FIGURE_PX else width,
      height = if (height > MAX_FIGURE_PX) MAX_FIGURE_PX else height)
}

#' A fresh device per cell: ragg::agg_png if the notebook's library has
#' ragg, else grDevices::png, into a temp file, with
#' dev.control(displaylist = "enable") so recordPlot() works.
#'
#' Opened at `fig` (list(width, height), inches) and `FIG_RES` (192, a 2x
#' first draw so 1x and 2x screens never ask for a redraw) through
#' `figure_pixels()`, which lowers the density instead when that would
#' put either side over `MAX_FIGURE_PX`.
open_device <- function(fig) {
  px <- figure_pixels(fig, FIG_RES)
  path <- tempfile(fileext = ".png")
  if (requireNamespace("ragg", quietly = TRUE)) {
    ragg::agg_png(filename = path, width = px$width, height = px$height, res = px$res, background = "white")
  } else {
    grDevices::png(filename = path, width = px$width, height = px$height, res = px$res, bg = "white")
  }
  grDevices::dev.control(displaylist = "enable")
  list(path = path, dev = grDevices::dev.cur(), width = px$width, height = px$height, res = px$res,
      fig = safe_fig(fig))
}

#' Close a device opened by `open_device()`, if it's still open.
close_device <- function(devinfo) {
  if (!is.null(devinfo) && devinfo$dev %in% grDevices::dev.list()) {
    tryCatch(grDevices::dev.off(devinfo$dev), error = function(e) NULL)
  }
  invisible()
}

#' Bytes of the PNG a device was drawing to.
read_png <- function(path) {
  readBin(path, "raw", file.info(path)$size)
}

# ---- Display ---------------------------------------------------------------------------

#' Build `expr` (written with `v` standing for the value) and evaluate it
#' in globalenv(), so generics like print(), utils::head() and format()
#' dispatch to S3 methods the notebook defined there.
#'
#' Every worker function lives in a private environment whose ultimate
#' parent is baseenv() (see the file header), never globalenv(). Calling
#' `print(value)` directly from one of them resolves the generic fine, but
#' UseMethod()'s method search starts from the calling frame and walks its
#' lexical parents -- which for a worker frame never reaches globalenv(), so
#' a `print.myclass` the notebook defined is invisible to it (measured:
#' confirmed with a plain `environment(f) <- e; f()` repro, not just
#' reasoning about scoping rules). Evaluating the call itself in
#' globalenv() puts the method search exactly where the notebook's own
#' top-level code runs, which does see it.
#' `extra` adds further bindings (e.g. `n` for a head() call), so a single
#' environment, with `v` and friends, is what the dispatch happens in.
eval_in_notebook <- function(expr, v, extra = list()) {
  eval(expr, c(list(v = v), extra), globalenv())
}

#' The value's print() text, truncated (first 50 lines, 4000 chars). Colour
#' is on throughout the worker (boot sets `cli.num_colors`); when truncation
#' lands inside an escape sequence, the partial sequence is dropped and a
#' reset code appended so the cut text never leaves the terminal mid-colour.
text_form <- function(value) {
  txt <- tryCatch(utils::capture.output(eval_in_notebook(quote(print(v)), value)),
                   error = function(e) "<unprintable>")
  truncated <- length(txt) > 50
  if (truncated) txt <- txt[1:50]
  txt <- paste(txt, collapse = "\n")
  if (nchar(txt) > 4000) {
    txt <- substr(txt, 1, 4000)
    truncated <- TRUE
  }
  if (truncated) {
    txt <- sub("\033\\[[0-9;]*$", "", txt)
    txt <- paste0(txt, "\033[0m")
  }
  list(text = txt, truncated = truncated)
}

#' print() text, with colour on so tibble/cli output keeps its colours.
display_text <- function(value) {
  tf <- text_form(value)
  list(kind = "text", mime = "text/plain", text = tf$text, truncated = tf$truncated)
}

#' A column's type abbreviation: `pillar::type_sum()` when pillar is loaded
#' (tibble users have it), else a fixed table (design.md, 3b).
#' `isNamespaceLoaded()`, not `requireNamespace()`: the latter loads
#' pillar (and cli, vctrs) as a side effect on every data frame display,
#' even in a notebook that never asked for it.
column_type <- function(col) {
  if (isNamespaceLoaded("pillar")) {
    ts <- tryCatch(pillar::type_sum(col), error = function(e) NA_character_)
    if (!is.na(ts)) return(paste0("<", ts, ">"))
  }
  switch(class(col)[1],
    numeric = "<dbl>", integer = "<int>", character = "<chr>",
    logical = "<lgl>", factor = "<fct>", Date = "<date>",
    POSIXct = "<dttm>", list = "<list>", "<cls>")
}

#' One formatted string per row of `col_head` (already `head()`-ed to the
#' rows being shown, in display order). A plain vector formats in one
#' call, same as `print()`. A matrix column, or a nested data frame column
#' (jsonlite's `fromJSON` makes these often), formats one *cell* or
#' sub-column at a time, not one string per outer row -- `format()` on the
#' whole structure returns one string per matrix cell or per nested
#' column, which would misalign `build_table()`'s per-row lookup (each
#' row would show values pulled from the wrong row, or past the end of
#' `col_head` altogether). Those are formatted row by row instead, each
#' row's own values joined into one string. Always returns exactly
#' `length(col_head)` (`nrow()` for a matrix/data frame) strings.
format_column <- function(col_head) {
  if (is.data.frame(col_head) || is.matrix(col_head)) {
    n <- NROW(col_head)
    return(vapply(seq_len(n), function(i) {
      row <- if (is.data.frame(col_head)) col_head[i, , drop = TRUE] else col_head[i, ]
      vals <- tryCatch(as.character(eval_in_notebook(quote(format(v)), row)),
                       error = function(e) "<error>")
      paste(vals, collapse = ", ")
    }, character(1)))
  }
  as.character(eval_in_notebook(quote(format(v)), col_head))
}

#' The structural part of a table display (names, types, shown rows), built
#' fresh from the kept data frame and the current paging limits; shared by
#' `display_table()` and `show_more()`. Each column is formatted separately
#' in `tryCatch` so one odd column can't fail the whole table. Columns are
#' read by position (`value[[i]]`), never by name (`value[[names_shown[i]]]`
#' would read the *first* column of that name twice over for a data frame
#' with duplicate column names).
build_table <- function(value, limits) {
  ncol_total <- tryCatch({ n <- as.integer(ncol(value)); if (is.na(n)) 0L else n },
                         error = function(e) 0L)
  nrow_total <- tryCatch({ n <- as.integer(nrow(value)); if (is.na(n)) 0L else n },
                         error = function(e) 0L)
  if (ncol_total == 0) {
    return(list(kind = "table", mime = "application/vnd.ember.table",
               names = character(), types = character(), nrow = nrow_total, ncol = 0L,
               row_labels = character(), rows = list(), more_rows = 0L, more_cols = 0L,
               na = list()))
  }
  rows_n <- min(limits$rows %||% 10L, nrow_total)
  cols_n <- min(limits$cols %||% 8L, ncol_total)
  all_names <- names(value)
  names_shown <- utils::head(all_names, cols_n)

  types_shown <- vapply(seq_len(cols_n), function(i) column_type(value[[i]]), character(1), USE.NAMES = FALSE)
  col_values <- lapply(seq_len(cols_n), function(i) {
    tryCatch({
      col_head <- utils::head(value[[i]], rows_n)
      format_column(col_head)
    }, error = function(e) rep("<error>", rows_n))
  })
  # NA per shown cell, atomic columns only (a list column, or a matrix/
  # data.frame column whose own cell isn't one scalar, is never NA here):
  # in the same per-column tryCatch as `col_values`, so one odd column
  # can't fail the whole table's NA detection either.
  col_na <- lapply(seq_len(cols_n), function(i) {
    tryCatch({
      col_head <- utils::head(value[[i]], rows_n)
      if (is.atomic(col_head) && !is.matrix(col_head)) is.na(col_head) else logical(rows_n)
    }, error = function(e) logical(rows_n))
  })
  row_labels <- tryCatch({
    rn <- rownames(value)
    if (is.null(rn)) as.character(seq_len(rows_n)) else utils::head(as.character(rn), rows_n)
  }, error = function(e) as.character(seq_len(rows_n)))

  # A msgpack nil (R's NA) is forbidden on this wire: a column formatted
  # to fewer strings than there are shown rows (an odd column's own
  # format() shrank it) contributes "" for the missing rows rather than
  # NA.
  rows <- lapply(seq_len(rows_n), function(i) {
    vapply(col_values, function(cv) if (length(cv) >= i) cv[i] else "", character(1))
  })
  na <- lapply(seq_len(rows_n), function(i) {
    which(vapply(col_na, function(v) length(v) >= i && isTRUE(v[i]), logical(1)))
  })

  list(kind = "table", mime = "application/vnd.ember.table",
      names = names_shown, types = types_shown, nrow = nrow_total, ncol = ncol_total,
      row_labels = row_labels, rows = rows,
      more_rows = max(0L, nrow_total - rows_n), more_cols = max(0L, ncol_total - cols_n),
      na = na)
}

#' A data frame, tibble or data.table: the first `limits$rows` rows and
#' `limits$cols` columns, formatted as print() would; the value itself is
#' kept (`display[[cell]]`) so "more" can rebuild with wider limits.
display_table <- function(value, cell, token, limits = list(rows = 10L, cols = 8L)) {
  tf <- text_form(value)
  display[[cell]] <<- list(value = value, token = token, kind = "table",
                           limits = limits, text = tf$text, truncated = tf$truncated)
  c(build_table(value, limits), list(text = tf$text, truncated = tf$truncated))
}

#' One line of text for a tree leaf: format() for a length-1 value, else
#' the first line of str().
leaf_text <- function(x) {
  tryCatch({
    if (length(x) == 1 && !identical(class(x), "list")) {
      as.character(eval_in_notebook(quote(format(v)), x))[1]
    } else {
      utils::capture.output(utils::str(x))[1]
    }
  }, error = function(e) "<unprintable>")
}

#' A tree's paging limits are keyed by path, and the root's path is `""`:
#' R's `[[`/`[[<-` on a list silently fail to round-trip a `""` name
#' (`l[[""]] <- x; l[[""]]` gives `NULL`, measured), so every lookup and
#' store goes through these two instead of indexing `limits` directly.
tree_limit_key <- function(path) if (identical(path, "")) "\001root" else path
tree_limit_get <- function(limits, path) limits[[tree_limit_key(path)]]
tree_limit_set <- function(limits, path, value) {
  limits[[tree_limit_key(path)]] <- value
  limits
}

#' One tree node (or leaf), to `max_depth` levels, each level showing the
#' first `limits[[path]]$items` elements (default 20). A value is a node
#' only when its class is exactly "list" (3a: every classed object, e.g. an
#' lm fit, is a leaf, printed as R prints it) and the depth limit isn't
#' reached yet.
display_tree_node <- function(x, path, depth, limits, max_depth = 4) {
  if (depth >= max_depth || !identical(class(x), "list")) {
    # A long plain vector (no class attribute, e.g. not a factor or Date;
    # not a matrix or array, which has a dim but no class; and unnamed,
    # since the values alone would silently drop the names) becomes an
    # expandable leaf of its own: the first 10 formatted values, its type
    # and its full length, so the page can show "... int, 100 values"
    # instead of str()'s one-line summary.
    if (is.atomic(x) && is.null(attr(x, "class")) && is.null(dim(x)) &&
        is.null(names(x)) && length(x) > 1) {
      head_x <- utils::head(x, 10)
      vals <- tryCatch({
        if (is.character(head_x)) {
          # format() doesn't quote a character vector; quoted the way
          # print() shows one.
          encodeString(head_x, quote = '"')
        } else {
          as.character(eval_in_notebook(quote(format(v, trim = TRUE)), head_x))
        }
      }, error = function(e) rep("<unprintable>", min(10L, length(x))))
      return(list(type = "vector", values = vals,
                 type_sum = gsub("[<>]", "", column_type(x)), length = length(x)))
    }
    return(list(type = "text", text = leaf_text(x)))
  }
  items_limit <- tree_limit_get(limits, path)$items %||% 20L
  n <- length(x)
  show_n <- min(n, items_limit)
  nms <- names(x)
  named <- !is.null(nms)
  items <- lapply(seq_len(show_n), function(i) {
    # `nzchar(NA)` is TRUE, so an NA name (possible in `names()`, distinct
    # from "" meaning no name) would otherwise become a bare `NA` --
    # a msgpack nil, forbidden as a tree key. print(list()) shows an NA
    # name as "<NA>"; this does the same.
    nm <- nms[[i]]
    key <- if (!named) "" else if (is.na(nm)) "<NA>" else if (nzchar(nm)) nm else ""
    child_path <- if (nzchar(path)) paste0(path, "/", i) else as.character(i)
    list(key = key, value = display_tree_node(x[[i]], child_path, depth + 1, limits, max_depth))
  })
  list(type = "list", path = path, length = n, named = named, items = items,
      more = max(0L, n - show_n))
}

#' Plain lists and nested structures as an expandable tree; the value is
#' kept (`display[[cell]]`) so "more" can rebuild with wider limits.
display_tree <- function(value, cell, token, limits = list()) {
  tf <- text_form(value)
  display[[cell]] <<- list(value = value, token = token, kind = "tree",
                           limits = limits, text = tf$text, truncated = tf$truncated)
  list(kind = "tree", mime = "application/vnd.ember.tree",
      tree = display_tree_node(value, "", 0, limits), text = tf$text, truncated = tf$truncated)
}

#' ggplot, trellis, recordedplot or grob: print to draw it, then PNG
#' bytes via recordPlot()/the device's file. The recorded plot is kept
#' (`display[[cell]]`), with the figure size it was drawn at (inches), so
#' a later `render` can replay it at a new pixel density.
#'
#' `text_form()` (which also calls `print()`) runs before `dev.off()`:
#' with no device open, printing a ggplot/trellis/recordedplot opens R's
#' default device (pdf), writing an `Rplots.pdf` into the notebook's
#' folder as a side effect. `dev$dev` is still current here, so this
#' second print draws onto it instead -- harmless, since `png_bytes` is
#' only read after, from the final frame.
display_plot_value <- function(value, cell, token, dev) {
  if (is.null(dev)) return(display_text(value))
  grDevices::dev.set(dev$dev)
  eval_in_notebook(quote(print(v)), value)
  rp <- tryCatch(grDevices::recordPlot(), error = function(e) NULL)
  tf <- text_form(value)
  grDevices::dev.off(dev$dev)
  png_bytes <- read_png(dev$path)
  display[[cell]] <<- list(value = rp, token = token, kind = "plot", fig = dev$fig)
  list(kind = "plot", mime = "image/png", data = png_bytes,
      size = list(width = dev$width, height = dev$height, res = dev$res),
      text = tf$text, truncated = tf$truncated)
}

#' A plot drawn as a side effect (base graphics) with no visible value:
#' recordPlot(), PNG bytes, kept in display[[cell]] with its figure size.
display_plot <- function(cell, token, dev) {
  if (is.null(dev) || !(dev$dev %in% grDevices::dev.list())) return(NULL)
  grDevices::dev.set(dev$dev)
  rp <- tryCatch(grDevices::recordPlot(), error = function(e) NULL)
  if (is.null(rp) || length(rp[[1]]) == 0) return(NULL)
  grDevices::dev.off(dev$dev)
  png_bytes <- read_png(dev$path)
  display[[cell]] <<- list(value = rp, token = token, kind = "plot", fig = dev$fig)
  list(kind = "plot", mime = "image/png", data = png_bytes,
      size = list(width = dev$width, height = dev$height, res = dev$res),
      text = "<plot>", truncated = FALSE)
}

knit_print_method_exists <- function(cl) {
  length(utils::getS3method("knit_print", cl, optional = TRUE)) > 0
}

#' `knit_print()`, tried only when knitr is in the notebook's library and
#' a method exists for `class(value)`; knitr is loaded the first time a
#' value reaches this step.
try_knit_print <- function(value) {
  if (!requireNamespace("knitr", quietly = TRUE)) return(NULL)
  if (!any(vapply(class(value), knit_print_method_exists, logical(1)))) return(NULL)
  out <- tryCatch(knitr::knit_print(value), error = function(e) NULL)
  if (is.null(out)) return(NULL)
  tf <- text_form(value)
  list(kind = "html", mime = "text/html", html = paste(out, collapse = "\n"),
       text = tf$text, truncated = tf$truncated)
}

#' repr::repr_html() etc. (IRkernel's MIME types).
try_repr <- function(value) {
  if (!requireNamespace("repr", quietly = TRUE)) return(NULL)
  html <- tryCatch(repr::repr_html(value), error = function(e) NULL)
  if (is.null(html)) return(NULL)
  tf <- text_form(value)
  list(kind = "html", mime = "text/html", html = html, text = tf$text, truncated = tf$truncated)
}

#' One `htmltools::htmlDependency` as the wire shape (design.md, Widget
#' files): `dir` is the absolute folder the files live in (resolved through
#' `system.file()` when the dependency names a package), or `NULL` when the
#' dependency has only an `href`.
dep_to_wire <- function(d) {
  dir <- NULL
  if (!is.null(d$src$file)) {
    dir <- if (!is.null(d$package)) {
      tryCatch(system.file(d$src$file, package = d$package), error = function(e) "")
    } else {
      d$src$file
    }
    if (is.null(dir) || !nzchar(dir)) dir <- NA_character_
    else dir <- tryCatch(normalizePath(dir, mustWork = FALSE), error = function(e) dir)
  }
  list(name = d$name, version = as.character(d$version), dir = dir, href = d$src$href,
      script = d$script %||% character(), stylesheet = d$stylesheet %||% character(),
      head = d$head)
}

#' htmlwidgets / htmltools HTML and its dependencies, resolved
#' (`htmltools::resolveDependencies()` keeps the newest of each name).
display_html <- function(value) {
  if (!requireNamespace("htmltools", quietly = TRUE)) return(display_text(value))
  rendered <- tryCatch(htmltools::renderTags(value), error = function(e) NULL)
  if (is.null(rendered)) return(display_text(value))
  tf <- text_form(value)
  deps <- tryCatch({
    resolved <- htmltools::resolveDependencies(rendered$dependencies %||% list())
    lapply(resolved, dep_to_wire)
  }, error = function(e) list())
  list(kind = "html", mime = "text/html", html = paste(rendered$html, collapse = "\n"),
       deps = deps, text = tf$text, truncated = tf$truncated)
}

#' knitr's inline formatting (knitr 1.52, `.inline.hook` and
#' `round_digits`), so an inline `` `r expr` `` value reads the same as in
#' knitr::spin's report: a numeric value rounded to `getOption("digits")`,
#' a vector joined with ", ".
inline_text <- function(x) {
  if (is.numeric(x)) x <- as.character(round(x, getOption("digits")))
  paste(as.character(x), collapse = ", ")
}

#' Turn the output value into a display bundle (design.md, How values
#' display): htmlwidgets -> knit_print -> repr -> Ember's own views ->
#' print() text, always with a truncated text/plain form. A failure
#' inside a display method becomes the text form plus a console warning;
#' it never makes the cell an error (`console` is passed in for exactly
#' this note, a small addition to the sketch's signature).
#'
#' 3a: a list is shown as a tree only when its class is exactly "list"; a
#' classed object built on a list (an `lm` fit, a `t.test()` result) falls
#' through to `print()` text like anything else, matching design.md's "How
#' values display" (Ember's own views are for data frames, plots and plain
#' lists; everything else prints).
display_value <- function(value, cell, token, dev, console) {
  tryCatch({
    if (inherits(value, c("htmlwidget", "shiny.tag", "shiny.tag.list", "html"))) {
      return(display_html(value))
    }
    kp <- try_knit_print(value)
    if (!is.null(kp)) return(kp)
    rp <- try_repr(value)
    if (!is.null(rp)) return(rp)
    if (is.data.frame(value)) return(display_table(value, cell, token))
    if (inherits(value, c("gg", "ggplot", "trellis", "recordedplot", "grob"))) {
      return(display_plot_value(value, cell, token, dev))
    }
    if (identical(class(value), "list")) return(display_tree(value, cell, token))
    display_text(value)
  }, error = function(e) {
    if (!is.null(console)) {
      tryCatch(console$warning(simpleWarning(paste("display failed:", conditionMessage(e)))),
               error = function(e2) NULL)
    }
    display_text(value)
  })
}

#' Worker message `more`: grow the paging limit at `path` (dim 1 rows for a
#' table or items for a tree, dim 2 columns for a table) and rebuild the
#' display from the kept value (`display[[cell]]`), as a `rendered` message
#' carrying the run's token. `path` is `""` for a table (one level); for a
#' tree it addresses the sublist (e.g. "2/1"). Pluto's own paging steps:
#' rows/items +60, columns +30.
show_more <- function(msg) {
  rec <- display[[msg$cell]]
  if (is.null(rec) || !(rec$kind %in% c("table", "tree"))) {
    return(list(type = "rendered", cell = msg$cell, token = rec$token, display = NULL))
  }
  if (identical(rec$kind, "table")) {
    cur <- rec$limits %||% list(rows = 10L, cols = 8L)
    if (identical(msg$dim, 1L)) cur$rows <- (cur$rows %||% 10L) + 60L
    if (identical(msg$dim, 2L)) cur$cols <- (cur$cols %||% 8L) + 30L
    rec$limits <- cur
    display[[msg$cell]] <<- rec
    bundle <- c(build_table(rec$value, cur), list(text = rec$text, truncated = rec$truncated))
  } else {
    limits <- rec$limits
    cur <- tree_limit_get(limits, msg$path) %||% list(items = 20L)
    if (identical(msg$dim, 1L)) cur$items <- (cur$items %||% 20L) + 60L
    limits <- tree_limit_set(limits, msg$path, cur)
    rec$limits <- limits
    display[[msg$cell]] <<- rec
    bundle <- list(kind = "tree", mime = "application/vnd.ember.tree",
                   tree = display_tree_node(rec$value, "", 0, limits), text = rec$text,
                   truncated = rec$truncated)
  }
  list(type = "rendered", cell = msg$cell, token = rec$token, display = bundle)
}

#' replayPlot() display[[cell]]$value on a new device and return a
#' `rendered` message carrying the run's token.
#'
#' Without `msg$width`/`height`: drawn at the cell's own figure size
#' (`rec$fig`, inches) and `msg$res`, through `figure_pixels()` -- the
#' same cap `open_device()` uses, so a redraw at a high `res` can't
#' allocate an unreasonably large bitmap either. With both: drawn at
#' those pixels (`render_png()`'s API, api.R), each capped on its own by
#' `clamp_pixels()`.
#'
#' Opening the device and reading the file back are a `tryCatch`: either
#' can fail (a bad size, a file that can't be reread), and nothing in
#' `handle_next()` catches an error that escapes here, which would end
#' the worker process; a failure reports `display = NULL`, as for no kept
#' value at all, and the device, if one opened, is always closed.
#' `replayPlot()` itself fails open (its own inner `tryCatch`, as
#' `display_plot_value()`'s `recordPlot()` is read regardless of
#' `print()` failing): an unreplayable recorded plot -- seen replaying a
#' base-graphics plot across devices on some platforms -- leaves a blank
#' but correctly sized image rather than losing the redraw entirely.
render_plot <- function(msg) {
  rec <- display[[msg$cell]]
  if (is.null(rec) || !identical(rec$kind, "plot")) {
    return(list(type = "rendered", cell = msg$cell, token = if (!is.null(rec)) rec$token else NULL, display = NULL))
  }
  res <- msg$res %||% 96
  if (!is.null(msg$width) && !is.null(msg$height)) {
    px <- clamp_pixels(msg$width, msg$height)
    px$res <- res
  } else {
    px <- figure_pixels(rec$fig, res)
  }
  bytes <- tryCatch({
    path <- tempfile(fileext = ".png")
    if (requireNamespace("ragg", quietly = TRUE)) {
      ragg::agg_png(filename = path, width = px$width, height = px$height, res = px$res, background = "white")
    } else {
      grDevices::png(filename = path, width = px$width, height = px$height, res = px$res, bg = "white")
    }
    dev_id <- grDevices::dev.cur()
    # A safety net for a failure between here and the explicit dev.off()
    # below: the explicit close already made on the success path means
    # dev.list() no longer has it, so this is a no-op then.
    on.exit(if (dev_id %in% grDevices::dev.list()) grDevices::dev.off(dev_id), add = TRUE)
    tryCatch(grDevices::replayPlot(rec$value), error = function(e) NULL)
    grDevices::dev.off(dev_id)
    read_png(path)
  }, error = function(e) NULL)

  if (is.null(bytes)) {
    return(list(type = "rendered", cell = msg$cell, token = rec$token, display = NULL))
  }
  list(type = "rendered", cell = msg$cell, token = rec$token,
      display = list(kind = "plot", mime = "image/png", data = bytes,
                     size = list(width = px$width, height = px$height, res = px$res)))
}

#' One line for a call or expression, long-form deparse() output joined
#' and runs of interior whitespace -- the indentation a multi-line body
#' such as `local({ ... })` leaves behind -- squashed to single spaces.
deparse_one_line <- function(x) {
  gsub("[ \t]+", " ", paste(deparse(x), collapse = " "))
}

#' `TRUE` for either eval() call the run loop uses to execute a
#' notebook's own code -- `exprs[[k]]` for a code cell's top-level
#' expressions, `line_e` for a text cell's per-line expressions -- so a
#' condition raised with no deeper call (a bare top-level stop() or
#' warning()) is recognised the same way for both.
is_loop_eval_text <- function(text) {
  identical(text, "eval(exprs[[k]], globalenv())") || identical(text, "eval(line_e, globalenv())")
}

#' Strip the worker's own frames from sys.calls(): everything up to and
#' including the eval of the cell (above the user's code), and the
#' condition-dispatch machinery below it (`.handleSimpleError()` and
#' friends, which run inside stop()'s own call stack before our calling
#' handler is reached and are never part of the user's code). What's left
#' is deparsed to one line per call.
#'
#' `calls` has already had the error handler's own frame, and any
#' `install_traces()` wrapper frame, removed by the caller using function
#' identity (`sys.function(i)`), not text: those can't be told apart from
#' the user's own code by matching their deparsed call text alone (a
#' classed condition's dispatch never goes through the `.handleSimpleError`
#' family this function still filters for simple conditions).
#'
#' The indices of `calls` (deparsed to `texts`, one line each) that are
#' the user's own code, shared by `clean_calls()` and `clean_frames()` so
#' the two always select the same frames in the same order.
clean_range <- function(texts) {
  start_idx <- which(vapply(texts, is_loop_eval_text, logical(1)))
  start <- if (length(start_idx)) max(start_idx) + 1L else 1L
  if (start > length(texts)) return(integer())
  tail_idx <- seq.int(start, length(texts))
  internal <- which(startsWith(texts[tail_idx], ".handleSimpleError(") |
                     startsWith(texts[tail_idx], ".handleSimpleCondition(") |
                     startsWith(texts[tail_idx], ".handleSimpleWarning(") |
                     startsWith(texts[tail_idx], ".signalSimpleWarning("))
  end <- if (length(internal)) tail_idx[min(internal)] - 1L else length(texts)
  if (end < start) return(integer())
  start:end
}

clean_calls <- function(calls) {
  texts <- vapply(calls, deparse_one_line, character(1))
  texts[clean_range(texts)]
}

#' One frame per element of `clean_calls(calls)`, in the same order
#' (outermost first): `list(call, package, cell)` for each surviving call,
#' from the function executing in that frame (`fns[[i]]`, `sys.function(i)`
#' captured by the caller while the stack was live).
#'
#' `package` is `environmentName(topenv(environment(fn)))`, `NULL` for
#' `"R_GlobalEnv"` (a notebook-defined function); "base" for a primitive. `cell` is that function's
#' srcref's file name -- the id of the cell that defined it, from
#' `srcfilecopy(msg$cell, msg$code)` at parse time -- `NULL` when the
#' function carries no srcref (a package function, normally built without
#' one).
clean_frames <- function(calls, fns) {
  texts <- vapply(calls, deparse_one_line, character(1))
  idx <- clean_range(texts)
  lapply(idx, function(i) {
    fn <- fns[[i]]
    package <- NULL
    cell <- NULL
    if (is.primitive(fn)) {
      # .Internal(eval()) and other builtins run in a frame of their own
      # whose function has no environment.
      package <- "base"
    } else if (!is.null(fn)) {
      env <- tryCatch(environment(fn), error = function(e) NULL)
      if (!is.null(env)) {
        pkg_name <- tryCatch(environmentName(topenv(env)), error = function(e) "R_GlobalEnv")
        if (!identical(pkg_name, "R_GlobalEnv")) package <- pkg_name
      }
      sr <- attr(fn, "srcref")
      sf <- if (!is.null(sr)) attr(sr, "srcfile") else NULL
      if (!is.null(sf) && !is.null(sf$filename) && nzchar(sf$filename)) cell <- sf$filename
    }
    list(call = texts[[i]], package = package, cell = cell)
  })
}

# ---- Editor services ---------------------------------------------------------
# complete / help / signature: answered between runs (handle_next()), never
# while a cell runs. `utils:::.completeToken` and `utils:::.getHelpFile` are
# internal and can change in any R release, so every call here is guarded
# by tryCatch: a change shows as "no results", never an error in a cell
# (design.md, "Editor services"; ui-2.md, 4, Risks).

#' utils' own completer evaluates any global that might be a function (it
#' calls `exists(name, mode = "function")` to decide whether to append
#' `(`, among other checks), which forces an active binding just to
#' classify it -- not only the token's own bindings, since it ranks every
#' candidate in `globalenv()`. Swap every active binding for an inert
#' placeholder for the call, then put the real ones back: this is the only
#' way to keep the completer from running a notebook's active-binding code
#' (`makeActiveBinding()`), since there's no argument that turns the
#' check off. `activeBindingFunction()` is what makes putting the original
#' back possible.
mask_active_bindings <- function(envir) {
  names <- ls(envir, all.names = TRUE)
  active <- names[vapply(names, function(n) tryCatch(bindingIsActive(n, envir), error = function(e) FALSE), logical(1))]
  fns <- stats::setNames(lapply(active, function(n) tryCatch(activeBindingFunction(n, envir), error = function(e) NULL)), active)
  # `rm()` removes a binding even when it's locked (measured: lockBinding()
  # only blocks assigning or removing it through the normal binding
  # operations that check the lock, not `rm()`); `makeActiveBinding()`
  # then creates a fresh, unlocked one, so without re-locking here a
  # locked active binding would come back unlocked once completion is
  # done -- silently removing a notebook's own protection.
  locked <- stats::setNames(vapply(active, function(n) tryCatch(bindingIsLocked(n, envir), error = function(e) FALSE), logical(1)), active)
  for (n in active) {
    if (!is.null(fns[[n]])) {
      rm(list = n, envir = envir)
      assign(n, NULL, envir = envir)
    }
  }
  function() {
    for (n in active) {
      if (!is.null(fns[[n]])) {
        if (exists(n, envir = envir, inherits = FALSE)) rm(list = n, envir = envir)
        makeActiveBinding(n, fns[[n]], envir)
        if (isTRUE(locked[[n]])) lockBinding(n, envir)
      }
    }
  }
}

#' utils' own line completion, as IRkernel does: `.assignLinebuffer()` and
#' `.assignEnd()` set the line and cursor the internal completer reads,
#' `.guessTokenFromLine()` finds the token being typed, `.completeToken()`
#' runs the completer, and `.retrieveCompletions()` collects the results.
#' `rc.settings(ipck = TRUE)` (set once at boot, below) is what makes
#' `library(` completion include installed package names.
#'
#' Returns `list(token, items, too_long)`, `items` a list of `list(name,
#' kind, notebook)`: `kind` is `"argument"` (the completion ends in `" = "`),
#' `"package"` (inside a `library(`/`require(` call), `"function"`,
#' `"path"`, or `"other"`; `notebook` is `TRUE` when the name is bound
#' directly in `globalenv()`. A completion's value is read with `get0()`
#' only when its binding isn't active (`bindingIsActive()`), so an active
#' binding is never evaluated just to classify it.
complete_line <- function(line, cursor) {
  tryCatch({
    unmask <- mask_active_bindings(globalenv())
    on.exit(unmask(), add = TRUE)
    utils:::.assignLinebuffer(line)
    utils:::.assignEnd(cursor)
    utils:::.guessTokenFromLine()
    utils:::.completeToken()
    comps <- utils:::.retrieveCompletions()
    token <- tryCatch(utils:::.CompletionEnv$token, error = function(e) NULL) %||% ""

    too_long <- length(comps) > 500
    if (too_long) comps <- comps[seq_len(500)]

    before_cursor <- substr(line, 1, cursor)
    in_library_call <- grepl("\\b(library|require)\\s*\\(\\s*[[:alnum:]._]*$", before_cursor)

    items <- lapply(comps, function(name) {
      # `rc.getOption("funarg.suffix")` (default `"="`) is what
      # `.completeToken()` appends to a function argument name; not
      # necessarily with surrounding spaces, so this matches the suffix
      # itself rather than a literal `" = "`.
      if (grepl("=\\s*$", name)) {
        list(name = name, kind = "argument", notebook = FALSE)
      } else if (in_library_call) {
        list(name = name, kind = "package", notebook = FALSE)
      } else if (grepl("[/\\\\]$", name)) {
        list(name = name, kind = "path", notebook = FALSE)
      } else {
        active <- tryCatch(bindingIsActive(name, globalenv()), error = function(e) FALSE)
        val <- if (!active) tryCatch(get0(name, envir = globalenv(), inherits = FALSE), error = function(e) NULL) else NULL
        kind <- if (is.function(val)) "function" else "other"
        in_global <- tryCatch(exists(name, envir = globalenv(), inherits = FALSE), error = function(e) FALSE)
        list(name = name, kind = kind, notebook = in_global)
      }
    })
    list(token = token, items = items, too_long = too_long)
  }, error = function(e) list(token = "", items = list(), too_long = FALSE))
}

#' `utils::help()`, called through `do.call()` because it quotes its first
#' argument (so a plain `help(topic)` can't take a variable). `package`
#' `NULL` searches attached packages first, then, only if none match and
#' `all_packages` is `TRUE` (a search typed in the Help box, not the cursor
#' moving), every installed package. Several matches (the same topic in more than one
#' package): no page is rendered, `matches` lists each `pkg::topic` for the
#' server to offer as links. One match: `.getHelpFile()` reads the parsed
#' Rd, `Rd2HTML()` renders it to a temp file (`dynamic = TRUE`, so
#' cross-reference links are the short `../../pkg/help/topic` form the
#' server's `rewrite_help_links()` expects), and only the `<body>` is
#' returned -- the page already has its own `<html>`/`<head>`.
help_lookup <- function(topic, package, all_packages = FALSE) {
  tryCatch({
    matches <- if (!is.null(package)) {
      do.call(utils::help, list(topic, package = package, help_type = "text"))
    } else {
      found <- do.call(utils::help, list(topic, help_type = "text"))
      if (length(found) == 0 && all_packages) {
        found <- do.call(utils::help, list(topic, help_type = "text", try.all.packages = TRUE))
      }
      found
    }
    if (length(matches) == 0) {
      return(list(found = FALSE, topic = topic, package = package, html = NULL, matches = list()))
    }

    # A help path is <libpath>/<package>/help/<topic> (index.search()'s
    # layout, used whether `package` was given or every installed package
    # was searched); no attribute carries the package name.
    pkgs <- vapply(as.character(matches), function(p) basename(dirname(dirname(p))), character(1), USE.NAMES = FALSE)
    if (length(matches) > 1) {
      matches_list <- Map(function(p, path) list(package = p, topic = basename(path)),
                          pkgs, as.character(matches))
      return(list(found = TRUE, topic = topic, package = package, html = NULL,
                  matches = unname(matches_list)))
    }

    rd_path <- as.character(matches)[1]
    pkg_name <- pkgs[1]
    rd <- utils:::.getHelpFile(rd_path)
    out <- tempfile(fileext = ".html")
    on.exit(unlink(out), add = TRUE)
    tools::Rd2HTML(rd, out, package = pkg_name, dynamic = TRUE)
    full <- paste(readLines(out, warn = FALSE), collapse = "\n")
    body <- sub("(?s).*<body>", "", full, perl = TRUE)
    body <- sub("(?s)</body>.*", "", body, perl = TRUE)
    list(found = TRUE, topic = topic, package = pkg_name, html = body, matches = list())
  }, error = function(e) list(found = FALSE, topic = topic, package = package, html = NULL, matches = list()))
}

#' `args(fn)` deparsed into `name(arg1, arg2 = default, ...)`, the trailing
#' `NULL` body dropped. `fn` is looked up with `get()` starting from
#' `globalenv()`, so it follows the real search path (a notebook definition,
#' or any attached package) the way the cell's own code would; `package`
#' not `NULL` looks in that namespace instead -- but only when `package` is
#' already loaded: `asNamespace()` loads an unloaded package as a side
#' effect, and typing `pkg::fn(` must never do that. `NULL` when `name`
#' isn't a function (editor-services.R's `signature_fallback()` shares the
#' deparse step as `format_signature()`).
worker_signature <- function(name, package) {
  tryCatch({
    fn <- if (!is.null(package)) {
      if (!isNamespaceLoaded(package)) return(NULL)
      get(name, envir = asNamespace(package), inherits = FALSE)
    } else {
      get(name, envir = globalenv(), inherits = TRUE, mode = "function")
    }
    if (!is.function(fn)) return(NULL)
    a <- tryCatch(args(fn), error = function(e) NULL)
    if (is.null(a)) return(NULL)
    d <- deparse(a)
    d <- d[seq_len(max(0, length(d) - 1))]
    text <- gsub("\\s+", " ", paste(d, collapse = " "))
    sub("^function\\s*", name, trimws(text))
  }, error = function(e) NULL)
}
