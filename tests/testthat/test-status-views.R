# Tests for piece 5 (ui-2.md, "Status views"): the top-level `ember`
# projection, per-cell `ember`, worker memory sampling, and the
# `ember_run_all` request. Covers ui-2-tests.md items 64-70.

# ---- 63. project_ember(): process, not_run, worker_memory, plan -----------

test_that("project_ember(): process, not_run, worker_memory and plan (64)", {
  s <- fake_state(list(S = cell(""), A = cell("1"), B = cell("2"), ERR = cell("y <- stop('x')"),
                       LOOP = cell("3"), MD = cell("# hi", kind = "markdown")))
  ctx0 <- view_context(s)
  e0 <- project_ember(s, ctx0)
  expect_equal(e0$process, "preview")
  expect_equal(e0$not_run, 0L)
  expect_null(e0$worker_memory)
  expect_equal(e0$plan$install, packages_view(s)$plan$install)

  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(10)))
  e1 <- project_ember(r$state, view_context(r$state))
  expect_equal(e1$not_run, 3L)  # B, ERR, LOOP; not S (blank) or MD (markdown)

  r <- drive(r$state, ev_run(NULL, at(11)))
  repeat {
    running <- r$state$worker$running
    if (is.null(running)) break
    rep <- if (identical(running$cell, "ERR")) report(error = list(message = "boom")) else report()
    r <- drive(r$state, wk_done(1, last_token(r), rep, at(r$state$clock + 1)))
  }
  e2 <- project_ember(r$state, view_context(r$state))
  expect_equal(e2$not_run, 0L)
})

# ---- 64. Per-cell ember: stale, code_changed, blocked_by -------------------

test_that("per-cell ember: stale after a lazy rerun, code_changed after an outside edit (65)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1")), on_cell_change = "lazy")
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))

  js0 <- pluto_state(r$state)$js
  expect_false(js0$cell_results$B$ember$stale)
  expect_false(js0$cell_results$A$ember$code_changed)

  # Rerunning A marks the (lazy) dependent B stale without rerunning it.
  r2 <- drive(r$state, ev_run("A", at(12)))
  r2 <- drive(r2$state, wk_done(1, last_token(r2), report(created = "x"), at(13)))
  js1 <- pluto_state(r2$state)$js
  expect_true(js1$cell_results$B$ember$stale)
  expect_false(js1$cell_results$B$ember$code_changed)
  expect_null(js1$cell_results$B$ember$blocked_by)
  expect_false(js1$cell_results$B$depends_on_disabled_cells)

  # An outside edit (the R API, not the page) changes B's code without a run.
  r3 <- drive(r2$state, ev_apply(list(op_set_code("B", "x + 2")), at(14)))
  js2 <- pluto_state(r3$state)$js
  expect_true(js2$cell_results$B$ember$code_changed)
})

test_that("per-cell ember: only the dependent that names a failed cell gets upstream_error (ui-3 11)", {
  s <- fake_state(list(S = cell(""), A = cell("1"), ERR = cell("y <- stop('boom')"), C = cell("y + 1")))
  r <- boot(s, c("ERR", "C"))
  r <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "boom")), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r),
                              report(status = "error", error = list(message = "object 'y' not found")), at(11)))

  js <- pluto_state(r$state)$js
  expect_equal(js$cell_results$C$ember$upstream_error, list(list(name = "y", cell = "ERR")))
  expect_false(js$cell_results$C$depends_on_disabled_cells)
  expect_null(js$cell_results$ERR$ember$upstream_error)
  expect_false(js$cell_results$ERR$depends_on_disabled_cells)
  for (id in c("S", "A")) {
    expect_null(js$cell_results[[id]]$ember$upstream_error)
  }
})

# ---- 65. worker_usage patches only ember/worker_memory ---------------------

test_that("a worker_usage change patches only ember/worker_memory; a stale generation is ignored (66)", {
  s <- fake_state(list(S = cell(""), A = cell("1")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(10)))
  gen <- r$state$worker$gen
  p1 <- pluto_state(r$state)

  r2 <- drive(r$state, ev_worker_usage(gen, 123456789, at(11)))
  p2 <- pluto_state(r2$state, p1)
  diffs <- fb_diff(p1$js, p2$js)
  expect_true(length(diffs) > 0)
  for (d in diffs) expect_equal(d$path, list("ember", "worker_memory"))
  expect_equal(p2$js$ember$worker_memory, 123456789)
  expect_true(check_wire(p2$js))

  r3 <- drive(r2$state, ev_worker_usage(gen + 99L, 1, at(12)))
  expect_identical(r3$state$worker_usage, r2$state$worker_usage)
})

# ---- 66. ember$packages$rows mirrors packages_view() -----------------------

test_that("ember$packages$rows mirrors packages_view(); an NA version is NULL on the wire (67)", {
  s <- fake_state(list(S = cell(""), A = cell("1")))
  s$file$header$extra_packages <- "ggplot2"
  s$packages$problems <- data.frame(kind = "not_found", package = "ggplot2",
                                    message = "no package called 'ggplot2'", fixes = NA_character_,
                                    stringsAsFactors = FALSE)
  pv <- packages_view(s)
  js <- pluto_state(s)$js

  expect_equal(length(js$ember$packages$rows), nrow(pv$packages))
  row <- js$ember$packages$rows[[1]]
  expect_equal(row$name, "ggplot2")
  expect_null(row$version)
  expect_null(row$source)
  expect_equal(row$status, "not_found")
  expect_true(check_wire(js))
})

# ---- 67. reduce_worker_usage(), notifications(), notebook_snapshot() ------

test_that("reduce_worker_usage() stores the value; notifications() reports it alone (68)", {
  s <- fake_state(list(S = cell(""), A = cell("1")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(10)))
  before <- r$state

  r2 <- drive(before, ev_worker_usage(before$worker$gen, 55e6, at(11)))
  expect_equal(r2$state$worker_usage, list(gen = before$worker$gen, rss = 55e6))

  nts <- notifications(before, r2$state)
  kinds <- vapply(nts, function(n) n$kind, character(1))
  expect_true("worker_usage" %in% kinds)
  expect_false("cell_state" %in% kinds)
})

test_that("notebook_snapshot() carries worker_memory for the current worker generation only (68)", {
  s <- fake_state(list(S = cell(""), A = cell("1")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(10)))
  gen <- r$state$worker$gen

  r2 <- drive(r$state, ev_worker_usage(gen, 55e6, at(11)))
  nb <- structure(list(state = r2$state), class = "ember_notebook")
  expect_equal(notebook_snapshot(nb)$worker_memory, 55e6)

  stale <- r2$state
  stale$worker_usage$gen <- gen + 99L
  nb2 <- structure(list(state = stale), class = "ember_notebook")
  expect_null(notebook_snapshot(nb2)$worker_memory)
})

# ---- 68. Worker memory sampling (shell.R), with a fake process ------------

#' A minimal shell handle for sample_worker_memory(), without a real worker
#' process or file IO: `state$read_only <- TRUE` makes `drain()`'s
#' `save_if_changed()` a no-op, and nothing here ever calls `schedule_poll()`
#' (no `later` callback is scheduled, so nothing runs this except the test
#' calling `sample_worker_memory()` itself).
fake_shell <- function(state) {
  nb <- new.env(parent = emptyenv())
  nb$state <- state
  nb$inbox <- list()
  nb$draining <- FALSE
  nb$written <- format_notebook(notebook_file_of(state))
  nb$saved <- FALSE
  nb$save_failed_text <- NULL
  nb$listeners <- list()
  nb$proc <- NULL
  nb$proc_gen <- 0L
  nb$watch <- list()
  nb$last_watch_check <- NULL
  nb$last_mem_check <- NULL
  nb$worker_rss_reported <- NULL
  nb$closing <- FALSE
  class(nb) <- "ember_notebook"
  nb
}

#' A fake processx handle whose `get_memory_info()` returns each of
#' `mb_sequence` (MB) in turn, as `rss`; `NA` makes that call error, as a
#' real one can on an unsupported platform or a process that just exited.
fake_proc <- function(mb_sequence) {
  i <- 0L
  list(get_memory_info = function() {
    i <<- i + 1L
    mb <- mb_sequence[i]
    if (is.na(mb)) stop("get_memory_info: unsupported")
    c(rss = mb * 1024^2)
  })
}

test_that("sample_worker_memory() reports on a 16 MB/5% move only; an error reports nothing (69)", {
  s <- fake_state(list(S = cell(""), A = cell("1")))
  s$read_only <- TRUE
  s$worker$gen <- 1L
  s$worker$status <- "ready"
  nb <- fake_shell(s)
  nb$proc <- fake_proc(c(100, 105, 130, NA))
  nb$proc_gen <- 1L

  sample_worker_memory(nb, at(1))
  expect_equal(nb$state$worker_usage$rss, 100 * 1024^2)

  sample_worker_memory(nb, at(2))  # 105 MB: under both thresholds since 100
  expect_equal(nb$state$worker_usage$rss, 100 * 1024^2)

  sample_worker_memory(nb, at(3))  # 130 MB: 30 MB/30% past the last report
  expect_equal(nb$state$worker_usage$rss, 130 * 1024^2)

  before <- nb$state
  sample_worker_memory(nb, at(4))  # get_memory_info() errors
  expect_identical(nb$state, before)
})

test_that("maybe_sample_worker_memory() gates sampling to every 2s", {
  s <- fake_state(list(S = cell(""), A = cell("1")))
  s$read_only <- TRUE
  s$worker$gen <- 1L
  nb <- fake_shell(s)
  nb$proc <- fake_proc(c(100, 999))
  nb$proc_gen <- 1L

  t0 <- Sys.time()
  maybe_sample_worker_memory(nb, t0)  # not connected yet: nothing sampled
  expect_null(nb$state$worker_usage$rss)

  nb$con <- "connected"
  maybe_sample_worker_memory(nb, t0)
  expect_equal(nb$state$worker_usage$rss, 100 * 1024^2)

  maybe_sample_worker_memory(nb, t0 + 1)  # too soon: not sampled again
  expect_equal(nb$state$worker_usage$rss, 100 * 1024^2)

  maybe_sample_worker_memory(nb, t0 + 2.5)
  expect_equal(nb$state$worker_usage$rss, 999 * 1024^2)
})

# ---- 69. ember_run_all: only not-run cells, nothing already fresh ----------

test_that("ember_run_all runs only not-run cells; a fresh one keeps its last_run (70)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1"), B = cell("2")),
                                 on_cell_change = "lazy")
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  cells <- names(notebook_state(nb)$cells)
  a <- cells[2]; b <- cells[3]

  ws <- fake_socket()
  handle_message(server, ws, wire("connect", notebook_id = id))
  handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))

  handle_message(server, ws, wire("run_multiple_cells", notebook_id = id, cells = list(a)))
  expect_true(wait_for(nb, timeout = 20))
  a_started <- notebook_state(nb)$results[[a]]$started_at

  handle_message(server, ws, wire("ember_run_all", notebook_id = id))
  expect_true(wait_for(nb, timeout = 20))

  snap <- notebook_snapshot(nb)
  not_run <- Filter(function(c) identical(c$status, "not_run") && !c$setup, snap$cells)
  expect_length(not_run, 0)
  expect_identical(notebook_state(nb)$results[[a]]$started_at, a_started)
  expect_false(is.null(notebook_state(nb)$results[[b]]))
})

# ---- not_run_ids() excludes cells "Run all" can't run -----------------------

test_that("not_run_ids() excludes cells with their own graph error (ui-3 10)", {
  s <- fake_state(list(S = cell(""), A = cell("z <- 1"), B = cell("z <- 2"), C = cell("z + 1"),
                       OK = cell("5")))
  r <- boot(s, "OK")
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(10)))

  ctx <- view_context(r$state)
  expect_false(is.null(ctx$errors_by_cell[[match("A", ctx$ids)]]))
  expect_false(is.null(ctx$errors_by_cell[[match("B", ctx$ids)]]))
  expect_null(ctx$errors_by_cell[[match("C", ctx$ids)]])

  ids <- not_run_ids(r$state, ctx)
  expect_false("A" %in% ids)
  expect_false("B" %in% ids)
  expect_false("OK" %in% ids)  # already ran
  expect_true("C" %in% ids)    # a not-run dependent of the graph-error cells still counts
})

test_that("not_run_ids() counts a not-run dependent of a failed cell (ui-3 10)", {
  s <- fake_state(list(S = cell(""), A = cell("1"), ERR = cell("y <- stop('boom')"), C = cell("y + 1")),
                  on_cell_change = "lazy")
  r <- boot(s, "ERR")
  r <- drive(r$state, wk_done(1, last_token(r), report(error = list(message = "boom")), at(10)))

  ctx <- view_context(r$state)
  expect_null(ctx$errors_by_cell[[match("C", ctx$ids)]])
  expect_null(r$state$results[["C"]])

  ids <- not_run_ids(r$state, ctx)
  expect_true("C" %in% ids)   # a dependent of a failed cell still runs; it counts
  expect_true("A" %in% ids)   # not run, not blocked: still counted
})

test_that("view_context() and the snapshot have no blocked/blocked_by fields (ui-3 10)", {
  s <- fake_state(list(S = cell(""), A = cell("z <- 1"), B = cell("z <- 2")))
  r <- boot(s, "A")
  ctx <- view_context(r$state)
  expect_null(ctx$blocked)
  expect_null(ctx$blocked_by)
  v <- snapshot_of(r$state)$cells$A
  expect_false("blocked" %in% names(v))
  expect_false("blocked_by" %in% names(v))
})
