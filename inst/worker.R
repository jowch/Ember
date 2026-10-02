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
# baseline, display data) and reports facts; it never judges graph rules.
# The server's core decides what a fact means (a learned definition, a
# "Multiple definitions" error, a global setting error).
#
# ---- Wire protocol -----------------------------------------------------------
# Frames both ways: 4-byte big-endian length, then serialize(msg, NULL)
# (xdr, version 3). msg is a list with `type`.
#
# Server -> worker
#   run          cell, token, code, role ("setup"|"cell"), order (code cell
#                ids in run order), formulas (list of formula_site)
#   remove_cell  cell, order         drop the cell's globals, display data,
#                                    and rebuild the search path
#   source_reply allow, message      only while a `source` request waits
#   more         cell, path, dim     grow a table's or tree's paging limit
#                                    at `path` (dim 1 rows/items, 2 columns)
#   render       cell, width, height, res   re-render the cell's recorded plot
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
#
# Ordering: the server sends at most one `run` at a time and sends the next
# only after `done`. `remove_cell`, `more` and `render` may arrive while a
# cell runs (the worker reads them only between runs, or while waiting for a
# `source_reply`, when they are queued in `deferred` and handled after the
# run). Nothing else needs ordering.

# ---- State (the worker's own; lives in this private environment) -------------

`%||%` <- function(x, y) if (is.null(x)) y else x

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
setup_restore <- NULL  # list(kind, name, value) to put back before setup reruns
running <- NULL        # list(cell, token) during a run (for the source trace)
deferred <- list()     # messages read while waiting for a source_reply
load_log <- NULL       # settings changes made inside loadNamespace/library during a run
settings_start <- NULL # the worker's own settings, snapshotted once at boot
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
  # on, and a setup cell can still change them (a rerun resets to this
  # baseline, same as any other setting).
  options(cli.num_colors = 256L, crayon.enabled = TRUE, crayon.colors = 256L)
  settings_start <<- snapshot_settings()
  send(list(type = "hello", secret = Sys.getenv("EMBER_SECRET"),
            pid = Sys.getpid(), r_version = R.version.string,
            lib_paths = .libPaths(), loaded = loaded_namespace_versions()))
  Sys.unsetenv("EMBER_SECRET")      # cells must not see it
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
    more = send(show_more(msg)),
    render = send(render_plot(msg)),
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
#' list(message, call, traceback)), runtime, created, changed, removed,
#' settings, load_notes, attached (package -> exports, for packages newly
#' attached), formula_misses).
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
             attached = list(), formula_misses = character(), loaded = character())

  # `dev`/`console` are closed here (not just at their normal point of use
  # below) so an interrupt landing anywhere in this function — including
  # after the cell's code finished, while display or bookkeeping is still
  # running — can never leave a sink or a device open. Once the bookkeeping
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
    # `remove_cell()`/`restore_setup_settings()` must be inside this same
    # guarded block, not before it: an interrupt landing in that narrow
    # window (between one cell's "done" and the next cell's code actually
    # starting) is otherwise uncaught, which halts the whole worker process
    # instead of reporting an "interrupted" cell (found via a test that
    # interrupts a cell within milliseconds of it starting).
    cell_order <<- msg$order
    remove_cell(msg$cell)
    if (identical(msg$role, "setup")) restore_setup_settings()

    before_names <- ls(globalenv(), all.names = TRUE)
    before <- snapshot_globals(before_names)
    settings0 <- snapshot_settings()
    load_log <<- list()
    attach_requests[[msg$cell]] <<- character()
    running <<- list(cell = msg$cell, token = msg$token)
    search0 <- search()
    dev <- open_device()
    console <- console_collector(msg$cell, msg$token)
    t0 <- proc.time()

    value <- NULL
    visible <- FALSE
    err <- NULL
    exprs <- parse(text = msg$code, keep.source = TRUE)
    trace_line("eval", msg$cell)

    tryCatch(
      withCallingHandlers({
        for (e in exprs) {
          r <- withVisible(eval(e, globalenv()))
          if (r$visible) {
            if (visible) console$print(value)
            value <- r$value
            visible <- TRUE
          }
        }
      },
      message = function(m) { console$message(m); invokeRestart("muffleMessage") },
      warning = function(w) { console$warning(w); invokeRestart("muffleWarning") },
      error   = function(e) {
        # `sys.calls()` here always ends with this handler's own frame
        # (it's the currently executing call), so it's dropped
        # unconditionally rather than matched by text — the fix for a
        # classed condition (stop(<condition object>), as every
        # rlang/cli error raises) whose signalling never passes through
        # the simpleError dispatch helpers the text patterns below catch.
        calls <- sys.calls()
        calls <- calls[-length(calls)]
        # A frame inside one of install_traces()'s loadNamespace/
        # library/require wrappers (identified by identity against the
        # real function it replaced, not by name: the wrapper always
        # calls it through a local variable named `original`, so by text
        # every such frame deparses identically regardless of which of
        # the three it is).
        is_original <- vapply(seq_along(calls), function(i) {
          fn <- tryCatch(sys.function(i), error = function(e2) NULL)
          !is.null(fn) && any(vapply(loader_originals, identical, logical(1), y = fn))
        }, logical(1))
        call <- conditionCall(e)
        if (!is.null(call) && identical(call, quote(original(...)))) {
          # The real loadNamespace()/library()/require() built its own
          # error's call from *its* caller, which — from inside our
          # wrapper — is the wrapper's own `original(...)` line, not the
          # line the notebook wrote (e.g. `library(notapkg)`). Report the
          # frame just above it instead, which is exactly that line: our
          # wrapper's `sys.call()` always returns the call as the
          # notebook wrote it, regardless of what the binding resolved to.
          idx <- which(vapply(calls, identical, logical(1), y = call))
          if (length(idx) && idx[1] > 1) call <- calls[[idx[1] - 1]]
        }
        err <<- list(message = conditionMessage(e), call = call,
                     traceback = clean_calls(calls[!is_original]),
                     # `e$package` is set by R's own loadNamespace()/library()
                     # for a packageNotFoundError regardless of locale, so the
                     # server can recognise a missing package without matching
                     # the (locale-translated) message text.
                     package = if (inherits(e, "packageNotFoundError")) e$package else NULL)
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
          if (visible) display_value(value, msg$cell, msg$token, dev, console)
          else display_plot(msg$cell, msg$token, dev)
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

      if (identical(msg$role, "setup")) {
        setup_restore <<- lapply(settings_diffs, function(d) {
          list(kind = d$kind, name = d$name, value = d$before)
        })
      } else if (length(settings_diffs)) {
        for (d in settings_diffs) {
          tryCatch(apply_setting(d$kind, d$name, d$before), error = function(e) NULL)
        }
      }
      rc$settings <- lapply(settings_diffs, function(d) {
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

#' The global settings, as one comparable value.
snapshot_settings <- function() {
  list(options = options(), env = as.list(Sys.getenv()), wd = getwd(),
       locale = snapshot_locale(), search = search_non_package())
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
      start_val <- get_setting(settings_start, chg$kind, chg$name)
      notebook_set <- !identical(baseline_val, start_val)
      if (notebook_set && !identical(baseline_val, chg$after)) {
        notes <- c(notes, sprintf("package %s changed %s %s, which the notebook set",
                                   entry$package, chg$kind, chg$name))
      }
      baseline <- set_setting(baseline, chg$kind, chg$name, chg$after)
    }
  }
  list(settings = diff_settings(baseline, after), load_notes = notes)
}

#' Before the setup cell reruns: put back every setting a previous setup
#' run changed, to its value before that run.
restore_setup_settings <- function() {
  if (is.null(setup_restore)) return(invisible())
  for (chg in setup_restore) {
    tryCatch(apply_setting(chg$kind, chg$name, chg$value), error = function(e) NULL)
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
      # the next rebuild — see the note at attach_requests's use).
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

  add_item <- function(kind, text) {
    if (self$capped) return(invisible())
    self$total <- self$total + nchar(text, type = "bytes")
    if (self$total > self$limit) {
      item <- list(kind = "text", text = "output truncated")
      self$items[[length(self$items) + 1]] <- item
      self$capped <- TRUE
      send(list(type = "console", cell = cell, token = token, item = item))
      return(invisible())
    }
    item <- list(kind = kind, text = text)
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
  self$warning <- function(w) { flush_stdout(); add_item("warning", conditionMessage(w)) }
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

#' A fresh device per cell: ragg::agg_png if the notebook's library has
#' ragg, else grDevices::png, into a temp file, with
#' dev.control(displaylist = "enable") so recordPlot() works.
open_device <- function() {
  path <- tempfile(fileext = ".png")
  if (requireNamespace("ragg", quietly = TRUE)) {
    ragg::agg_png(filename = path, width = 720, height = 480, res = 96, background = "white")
  } else {
    grDevices::png(filename = path, width = 720, height = 480, res = 96, bg = "white")
  }
  grDevices::dev.control(displaylist = "enable")
  list(path = path, dev = grDevices::dev.cur())
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
#' lexical parents — which for a worker frame never reaches globalenv(), so
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
column_type <- function(col) {
  if (requireNamespace("pillar", quietly = TRUE)) {
    ts <- tryCatch(pillar::type_sum(col), error = function(e) NA_character_)
    if (!is.na(ts)) return(paste0("<", ts, ">"))
  }
  switch(class(col)[1],
    numeric = "<dbl>", integer = "<int>", character = "<chr>",
    logical = "<lgl>", factor = "<fct>", Date = "<date>",
    POSIXct = "<dttm>", list = "<list>", "<cls>")
}

#' The structural part of a table display (names, types, shown rows), built
#' fresh from the kept data frame and the current paging limits; shared by
#' `display_table()` and `show_more()`. Each column is formatted separately
#' in `tryCatch` so one odd column can't fail the whole table.
build_table <- function(value, limits) {
  ncol_total <- tryCatch({ n <- as.integer(ncol(value)); if (is.na(n)) 0L else n },
                         error = function(e) 0L)
  nrow_total <- tryCatch({ n <- as.integer(nrow(value)); if (is.na(n)) 0L else n },
                         error = function(e) 0L)
  if (ncol_total == 0) {
    return(list(kind = "table", mime = "application/vnd.ember.table",
               names = character(), types = character(), nrow = nrow_total, ncol = 0L,
               row_labels = character(), rows = list(), more_rows = 0L, more_cols = 0L))
  }
  rows_n <- min(limits$rows %||% 10L, nrow_total)
  cols_n <- min(limits$cols %||% 8L, ncol_total)
  all_names <- names(value)
  names_shown <- utils::head(all_names, cols_n)

  types_shown <- vapply(names_shown, function(n) column_type(value[[n]]), character(1), USE.NAMES = FALSE)
  col_values <- lapply(names_shown, function(n) {
    tryCatch({
      col_head <- utils::head(value[[n]], rows_n)
      as.character(eval_in_notebook(quote(format(v)), col_head))
    }, error = function(e) rep("<error>", rows_n))
  })
  row_labels <- tryCatch({
    rn <- rownames(value)
    if (is.null(rn)) as.character(seq_len(rows_n)) else utils::head(as.character(rn), rows_n)
  }, error = function(e) as.character(seq_len(rows_n)))

  rows <- lapply(seq_len(rows_n), function(i) {
    vapply(col_values, function(cv) if (length(cv) >= i) cv[i] else NA_character_, character(1))
  })

  list(kind = "table", mime = "application/vnd.ember.table",
      names = names_shown, types = types_shown, nrow = nrow_total, ncol = ncol_total,
      row_labels = row_labels, rows = rows,
      more_rows = max(0L, nrow_total - rows_n), more_cols = max(0L, ncol_total - cols_n))
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
    return(list(type = "text", text = leaf_text(x)))
  }
  items_limit <- tree_limit_get(limits, path)$items %||% 20L
  n <- length(x)
  show_n <- min(n, items_limit)
  nms <- names(x)
  named <- !is.null(nms)
  items <- lapply(seq_len(show_n), function(i) {
    key <- if (named && nzchar(nms[[i]] %||% "")) nms[[i]] else ""
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
#' (`display[[cell]]`) so a resize can replay it at a new size.
display_plot_value <- function(value, cell, token, dev) {
  if (is.null(dev)) return(display_text(value))
  grDevices::dev.set(dev$dev)
  eval_in_notebook(quote(print(v)), value)
  rp <- tryCatch(grDevices::recordPlot(), error = function(e) NULL)
  grDevices::dev.off(dev$dev)
  png_bytes <- read_png(dev$path)
  display[[cell]] <<- list(value = rp, token = token, kind = "plot")
  tf <- text_form(value)
  list(kind = "plot", mime = "image/png", data = png_bytes,
      size = list(width = 720L, height = 480L, res = 96L),
      text = tf$text, truncated = tf$truncated)
}

#' A plot drawn as a side effect (base graphics) with no visible value:
#' recordPlot(), PNG bytes, kept in display[[cell]].
display_plot <- function(cell, token, dev) {
  if (is.null(dev) || !(dev$dev %in% grDevices::dev.list())) return(NULL)
  grDevices::dev.set(dev$dev)
  rp <- tryCatch(grDevices::recordPlot(), error = function(e) NULL)
  if (is.null(rp) || length(rp[[1]]) == 0) return(NULL)
  grDevices::dev.off(dev$dev)
  png_bytes <- read_png(dev$path)
  display[[cell]] <<- list(value = rp, token = token, kind = "plot")
  list(kind = "plot", mime = "image/png", data = png_bytes,
      size = list(width = 720L, height = 480L, res = 96L),
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

#' replayPlot() display[[cell]]$value on a new device at the asked size and
#' pixel density; return a `rendered` message carrying the run's token.
render_plot <- function(msg) {
  rec <- display[[msg$cell]]
  if (is.null(rec) || !identical(rec$kind, "plot")) {
    return(list(type = "rendered", cell = msg$cell, token = if (!is.null(rec)) rec$token else NULL, display = NULL))
  }
  res <- msg$res %||% 96
  path <- tempfile(fileext = ".png")
  if (requireNamespace("ragg", quietly = TRUE)) {
    ragg::agg_png(filename = path, width = msg$width, height = msg$height, res = res, background = "white")
  } else {
    grDevices::png(filename = path, width = msg$width, height = msg$height, res = res, bg = "white")
  }
  tryCatch(grDevices::replayPlot(rec$value), error = function(e) NULL)
  grDevices::dev.off()
  list(type = "rendered", cell = msg$cell, token = rec$token,
      display = list(kind = "plot", mime = "image/png", data = read_png(path),
                     size = list(width = msg$width, height = msg$height, res = res)))
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
clean_calls <- function(calls) {
  texts <- vapply(calls, function(c) paste(deparse(c), collapse = " "), character(1))
  start_idx <- which(texts == "eval(e, globalenv())")
  start <- if (length(start_idx)) max(start_idx) + 1L else 1L
  if (start > length(texts)) return(character())
  tail_idx <- seq.int(start, length(texts))
  internal <- which(startsWith(texts[tail_idx], ".handleSimpleError(") |
                     startsWith(texts[tail_idx], ".handleSimpleCondition(") |
                     startsWith(texts[tail_idx], ".handleSimpleWarning(") |
                     startsWith(texts[tail_idx], ".signalSimpleWarning("))
  end <- if (length(internal)) tail_idx[min(internal)] - 1L else length(texts)
  if (end < start) return(character())
  texts[start:end]
}

# ---- Editor services (later) -----------------------------------------------------------
# complete / help messages: stubbed, answer `list(type = "completions",
# items = list())`. utils:::.completeToken and tools::Rd2HTML in step 4.
