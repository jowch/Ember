# Waits with no time limit. A test waits for its condition however slow
# the machine is; it never gives up because a set number of seconds
# passed (Ember #468). What still ends a wait that truly hangs is
# HANG_GUARD: that many seconds in which nothing changed. The error then
# says what the test was waiting for and what the notebook showed.
#
# - settle(nb, predicate, label): wait_for() with no deadline.
# - run_settled(nb, ids, label): run_cells(wait = TRUE) with no deadline.
# - waiting_for(label, expr, nb): any wait that services `later` (the API's
#   own, a preview_date(), a loop over later::run_now()) under the guard.
#   Without `nb`, the guard is HANG_GUARD seconds in total.
# - wait_until(check, label, nb): a loop on any condition, under the guard.
# - run_guarded(command, args): processx::run() that fails after HANG_GUARD
#   seconds with no output, not after a set time.
# - quiet_wait(nb, predicate, quiet): TRUE, or FALSE after `quiet` seconds
#   with nothing changing, for a caller that reports the failure itself.
#
# Worker-protocol waits (helper-worker.R's next_frame()) already work this
# way: they wait for the frame, fail at once if the worker exited, and
# after HANG_GUARD seconds of silence from a live one.

#' Seconds with no change before a wait counts as hung. Not a step's time
#' limit: a slow step still changes something (a cell starts, a line of
#' output, a status) well within it.
HANG_GUARD <- 600

#' What can change while a test waits on `nb`: the process, each cell's
#' status and output, the prompt, the packages. Not run times, which
#' change by themselves.
progress_of <- function(nb) {
  snap <- tryCatch(notebook_snapshot(nb), error = function(e) NULL)
  if (is.null(snap)) return(NULL)
  list(process = snap$process,
       cells = lapply(snap$cells, function(c) list(c$id, c$status, c$queued, c$running, c$stale,
                                                   c$output$text, c$prompt$id)),
       packages = list(snap$packages$library$status, snap$packages$proposal$status,
                       snap$packages$snapshot))
}

#' What the notebook shows, for a hung wait's error.
describe_notebook <- function(nb) {
  snap <- tryCatch(notebook_snapshot(nb), error = function(e) NULL)
  if (is.null(snap)) return("  (no snapshot: the notebook is closed)")
  cells <- vapply(snap$cells, function(c) {
    flags <- c(if (isTRUE(c$running)) "running", if (isTRUE(c$queued)) "queued",
               if (isTRUE(c$stale)) "stale", if (!is.null(c$prompt)) "waiting on a prompt")
    out <- utils::tail(strsplit(c$output$text %||% "", "\n", fixed = TRUE)[[1]], 2)
    sprintf("  %s: %s%s%s", c$id, c$status, if (length(flags)) paste0(" (", paste(flags, collapse = ", "), ")") else "",
            if (length(out)) paste0(", output ends: ", paste(out, collapse = " | ")) else "")
  }, character(1))
  c(sprintf("  process: %s%s", snap$process %||% "?",
            if (!is.null(snap$worker_message)) paste0(" (", snap$worker_message, ")") else ""),
    sprintf("  packages: %s%s%s", snap$packages$library$status %||% "?",
            if (!is.null(snap$packages$library$message)) paste0(" (", snap$packages$library$message, ")") else "",
            if (!is.null(snap$packages$proposal)) paste0(", proposal ", snap$packages$proposal$status) else ""),
    cells)
}

#' Run `expr`, a wait that services `later`, failing it if nothing changes
#' in `nb` for HANG_GUARD seconds. Without `nb` there is no progress to
#' watch, so the guard is HANG_GUARD seconds in total: pass `nb` whenever
#' one is in scope. The error names `label`, says how long the wait had
#' gone on, and shows `nb`.
#' The check runs as a `later` callback, so its error ends the wait from
#' inside the wait's own later::run_now().
waiting_for <- function(label, expr, nb = NULL) {
  started <- Sys.time()
  quiet_since <- started
  last <- if (!is.null(nb)) progress_of(nb)
  armed <- TRUE
  tick <- function() {
    if (!armed) return()
    now <- Sys.time()
    if (!is.null(nb)) {
      p <- progress_of(nb)
      if (!identical(p, last)) { last <<- p; quiet_since <<- now }
    }
    quiet <- as.numeric(now - quiet_since, units = "secs")
    if (quiet >= HANG_GUARD) {
      armed <<- FALSE
      stop(paste(c(sprintf("hung: waited %.0f s for %s, %.0f s of it with nothing changing",
                           as.numeric(now - started, units = "secs"), label, quiet),
                   if (!is.null(nb)) describe_notebook(nb)), collapse = "\n"), call. = FALSE)
    }
    later::later(tick, 5)
  }
  later::later(tick, 5)
  on.exit(armed <- FALSE)
  force(expr)
}

#' wait_for(nb, predicate) with no deadline, under the guard. Returns TRUE.
settle <- function(nb, predicate = is_idle, label = NULL) {
  label <- label %||% paste(deparse(substitute(predicate), width.cutoff = 500L), collapse = " ")
  invisible(waiting_for(label, wait_for(nb, predicate, timeout = Inf), nb))
}

#' run_cells(nb, ids, wait = TRUE) with no deadline, under the guard: the
#' same result, with `finished` the queued cells and `timed_out` FALSE.
run_settled <- function(nb, ids = NULL, label = NULL) {
  res <- run_cells(nb, ids)
  label <- label %||% sprintf("the run of %s to finish",
                              if (is.null(ids)) "every cell" else paste(ids, collapse = ", "))
  settle(nb, is_idle, label)
  res$finished <- res$queued
  invisible(res)
}

#' Wait until `check()` is TRUE, servicing `later`, under the guard.
wait_until <- function(check, label, nb = NULL) {
  invisible(waiting_for(label, {
    while (!isTRUE(check())) later::run_now(timeout = 0.1)
    TRUE
  }, nb))
}

#' processx::run(command, args, ...) with no time limit: it fails only
#' after HANG_GUARD seconds with no output from the process, showing the
#' end of what it wrote. Returns run()'s list (status, stdout, stderr).
run_guarded <- function(command, args = character(), ..., wd = NULL, env = NULL, error_on_status = TRUE) {
  p <- processx::process$new(command, args, wd = wd, env = env %||% "current",
                             stdout = "|", stderr = "|", ...)
  out <- character(); err <- character()
  quiet_since <- Sys.time()
  repeat {
    p$poll_io(1000)
    o <- p$read_output(); e <- p$read_error()
    if (nzchar(o) || nzchar(e)) { out <- c(out, o); err <- c(err, e); quiet_since <- Sys.time() }
    if (!p$is_alive()) break
    if (as.numeric(Sys.time() - quiet_since, units = "secs") >= HANG_GUARD) {
      p$kill()
      stop(sprintf("hung: %s wrote nothing for %d s; its output ends:\n%s", command, HANG_GUARD,
                   paste(utils::tail(strsplit(paste(c(out, err), collapse = ""), "\n")[[1]], 20), collapse = "\n")),
           call. = FALSE)
    }
  }
  out <- paste(c(out, p$read_all_output()), collapse = "")
  err <- paste(c(err, p$read_all_error()), collapse = "")
  status <- p$get_exit_status()
  if (error_on_status && !identical(status, 0L)) stop(sprintf("%s exited with status %s:\n%s", command, status, err), call. = FALSE)
  list(status = status, stdout = out, stderr = err, timeout = FALSE)
}

#' Wait until `predicate(notebook_snapshot(nb))` is TRUE, or until `quiet`
#' seconds pass with nothing in `nb` changing (progress_of()): TRUE or
#' FALSE. For a wait whose failure the caller reports itself.
quiet_wait <- function(nb, predicate, quiet = HANG_GUARD) {
  last <- progress_of(nb)
  quiet_since <- Sys.time()
  repeat {
    if (isTRUE(predicate(notebook_snapshot(nb)))) return(TRUE)
    p <- progress_of(nb)
    if (!identical(p, last)) { last <- p; quiet_since <- Sys.time() }
    if (as.numeric(Sys.time() - quiet_since, units = "secs") >= quiet) return(FALSE)
    later::run_now(timeout = 1)
  }
}
