# Timing helpers and fixtures for the performance tests, shared with
# bench/cases.R (which sources this file and helper-core.R).
#
# Shared CI runners differ from each other, and from run to run, by 2x or
# more, so no test here compares a time against a fixed number of
# milliseconds near what the code takes today. Each one compares two
# timings taken in the same process, interleaved so that a slow patch of
# the machine hits both:
#
# - the same call at two sizes, which catches a change in complexity (a
#   per-cell named lookup turning a linear pass quadratic), or
# - the cheap path against the expensive one it exists to avoid (an
#   incremental projection against a full one), which catches the cheap
#   path silently falling back to the expensive one.
#
# An absolute ceiling stays on each as a backstop, set around ten times
# today's cost. What none of these can see is the same shape getting a
# constant factor slower (PR #3's chip views: 33 ms to 41 ms at 2000
# cells). Where that comes from work done once per cell, a test counts the
# calls instead (test-pluto-state.R); bench/ looks for the rest, by
# running these fixtures on a pull request and on its base branch on one
# machine, and flags only slowdowns over 25%.

#' Seconds for `inner` calls of `f()`.
time_calls <- function(f, inner = 1L) {
  t0 <- proc.time()[["elapsed"]]
  for (i in seq_len(inner)) f()
  proc.time()[["elapsed"]] - t0
}

#' Median seconds per call of `f()` over `samples` samples of `inner`
#' calls each, after one warm-up call.
time_median <- function(f, samples = 9L, inner = 1L) {
  f()
  stats::median(vapply(seq_len(samples), function(i) time_calls(f, inner) / inner, numeric(1)))
}

#' The smallest `inner`, doubling from the given one, for which `inner`
#' calls of `f()` take at least `min_secs`. Windows' elapsed-time clock
#' ticks every 10-16 ms, so a sample shorter than that can read as 0.
calibrate_inner <- function(f, inner = 1L, min_secs = 0.05) {
  while (time_calls(f, inner) < min_secs && inner < 1e6) inner <- inner * 2L
  inner
}

#' Median seconds per call of `a()` and of `b()`, sampled alternately (one
#' sample of `a`, one of `b`, `samples` times, after a warm-up call of
#' each), and `ratio = a / b`. `inner_*` repeats a fast call within one
#' sample; each is raised (calibrate_inner()) until a sample lasts well
#' above the clock's resolution, which is coarse on Windows.
time_ratio <- function(a, b, samples = 9L, inner_a = 1L, inner_b = 1L) {
  a(); b()
  inner_a <- calibrate_inner(a, inner_a)
  inner_b <- calibrate_inner(b, inner_b)
  ta <- tb <- numeric(samples)
  for (i in seq_len(samples)) {
    ta[i] <- time_calls(a, inner_a) / inner_a
    tb[i] <- time_calls(b, inner_b) / inner_b
  }
  ma <- stats::median(ta); mb <- stats::median(tb)
  if (!(mb > 0)) stop("time_ratio(): b() timed as 0 s even after calibration")
  list(a = ma, b = mb, ratio = ma / mb)
}

#' `S` and `n` independent cells `c1`..`cn` (`x<i> <- <i>`).
perf_cells <- function(n) {
  cells <- list(S = cell(""))
  for (i in seq_len(n)) cells[[sprintf("c%d", i)]] <- cell(sprintf("x%d <- %d", i, i))
  cells
}

#' A projection of an `n`-cell notebook (`previous`) and the state after
#' one cell's code changed (`state`), for `pluto_state(state, previous)`.
#' With `results`, every cell has a result, the case where a per-cell
#' lookup into `state$results` by name turns quadratic.
perf_projection <- function(n, results = FALSE) {
  s <- fake_state(perf_cells(n))
  if (results) {
    s$allowed <- TRUE
    ids <- names(s$cells)
    s$results <- stats::setNames(lapply(ids, function(id) {
      list(status = "ok", code = s$cells[[id]]$code,
           output = list(mime = "text/plain", data = "1", text = "1"), console = list(),
           started_at = 1, runtime = 0.01, stale = FALSE, error = NULL, defined = character())
    }), ids)
  }
  previous <- pluto_state(s)
  list(state = drive(s, ev_apply(list(op_set_code("c7", "x7 <- 999")), at(1)))$state,
       previous = previous)
}

#' An `n`-cell notebook partway through "run all": the worker is running a
#' cell, so `wk_done()` for it is the common event that touches no cell,
#' export or file and so rebuilds no graph.
perf_running <- function(n) {
  s <- fake_state(perf_cells(n))
  drive(s, ev_run(NULL, at(1)), wk_started(1, 99, at(2)), wk_hello(1, list(), at(3)))$state
}

#' A notebook with `n_packages` locked packages and 200 cells that load
#' them, after its library was checked: what `packages_view()` sees.
perf_packages <- function(n_packages) {
  nm <- sprintf("pkg%04d", seq_len(n_packages))
  lock <- new_lock(nm, rep("1.0.0", n_packages), rep("CRAN", n_packages))
  cells <- c(list(S = cell("")),
             stats::setNames(lapply(seq_len(200), function(i) {
               cell(sprintf("library(%s)\nx%d <- %d", nm[(i %% n_packages) + 1], i, i))
             }), sprintf("c%d", 1:200)))
  file <- new_notebook_file(
    header = new_header(ember_version = "0.1.0", r_version = "4.3.0", snapshot = "2026-09-01",
                        bioc_version = NA_character_, on_cell_change = "autorun",
                        extra_packages = character()),
    cells = cells, run_order = names(cells), learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = lock, extra_blocks = list(), format = 1L, read_only = FALSE, problems = NULL)
  s <- new_state(file, path = "nb.R", id = "n1", options = list(), at = 0)
  r <- drive(s, ev_open(at(1)))
  drive(r$state, ev_library_checked(r$state$packages$target$key,
                                    list(installed = lock_versions(lock), exports = list()), at(2)))$state
}

#' A synthetic `n`-cell notebook-shaped object, built the same way bench4.R
#' did in the spike: each cell carries ~170 B of code and a ~1 KB text
#' output. pluto-state.R's real builder isn't needed to drive fb_diff():
#' its cost depends only on shape and size, not on where the shape comes
#' from.
big_notebook <- function(n) {
  ids <- sprintf("cell_%05d", seq_len(n))
  code <- paste(rep("x", 170), collapse = "")
  body <- paste(rep("y", 1024), collapse = "")
  metadata <- list(disabled = FALSE, show_logs = TRUE, skip_as_script = FALSE)
  inputs <- stats::setNames(lapply(ids, function(id) {
    list(cell_id = id, code = code, code_folded = FALSE, metadata = metadata)
  }), ids)
  results <- stats::setNames(lapply(ids, function(id) {
    list(cell_id = id, depends_on_disabled_cells = FALSE,
         output = list(body = body, mime = "text/plain", rootassignee = NULL,
                       last_run_timestamp = 0, persist_js_state = FALSE,
                       has_pluto_hook_features = FALSE),
         published_object_keys = list(), queued = FALSE, running = FALSE,
         errored = FALSE, runtime = 0, logs = list(), depends_on_skipped_cells = FALSE)
  }), ids)
  list(cell_inputs = inputs, cell_results = results, cell_order = as.list(ids))
}

#' `big_notebook(n)` and a copy with the middle cell's result changed.
perf_diff_pair <- function(n) {
  old <- big_notebook(n)
  new <- old
  changed_id <- names(new$cell_results)[n %/% 2]
  new$cell_results[[changed_id]]$running <- TRUE
  new$cell_results[[changed_id]]$output$body <- "changed"
  list(old = old, new = new, changed_id = changed_id)
}
