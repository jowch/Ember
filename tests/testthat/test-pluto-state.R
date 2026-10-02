# Tests for R/pluto-state.R: the pure projection from `ember_state` to
# Pluto's frontend object. Pure: no server, no process. States are built
# with `new_state()`/`fake_state()` and driven with `drive()`/`boot()`
# (tests/testthat/helper-core.R), the same way the engine's own tests do.
#
# Covers docs/ui-tests.md items 6-14.

# ---- 6. A fresh notebook in safe preview ------------------------------------

test_that("a fresh notebook projects a complete, wire-clean NotebookData (6)", {
  s <- fake_state(list(S = cell(""), A = cell("1 + 1"), B = cell("2 + 2")))
  p <- pluto_state(s)
  js <- p$js

  for (f in c("pluto_version", "julia_version", "notebook_id", "path", "shortpath",
             "in_temp_dir", "process_status", "last_save_time", "last_hot_reload_time",
             "cell_inputs", "cell_results", "cell_order", "published_objects", "bonds",
             "metadata", "nbpkg", "status_tree", "cell_dependencies", "cell_execution_order")) {
    expect_true(f %in% names(js), info = f)
  }
  expect_equal(js$process_status, "waiting_for_permission")
  for (id in names(s$cells)) {
    expect_false(js$cell_results[[id]]$queued, info = id)
  }
  expect_true(check_wire(js))
})

# ---- 7. Reuse is invisible ---------------------------------------------------

test_that("reuse never changes values, for a spread of engine fixtures (7)", {
  check_invisible <- function(prev, s) {
    p1 <- pluto_state(prev)
    p2 <- pluto_state(s, p1)
    expect_equal(p2$js, pluto_state(s, NULL)$js,
                info = "reuse vs. fresh build must agree on values")
    expect_true(check_wire(p2$js))
  }

  s0 <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a"),
                        Md = cell("# hi", kind = "markdown")))
  r1 <- boot(s0, "A")
  check_invisible(s0, r1$state)

  r2 <- drive(r1$state, wk_done(1, last_token(r1), report(created = "a"), at(10)))
  check_invisible(r1$state, r2$state)

  r3 <- drive(r2$state, ev_apply(list(op_set_code("B", "b <- a + 1")), at(11)))
  check_invisible(r2$state, r3$state)

  new1 <- "44444444-4444-4444-8444-444444444444"
  r4 <- drive(r3$state, ev_apply(list(op_insert(new1, 2, "z <- 1")), at(12)))
  check_invisible(r3$state, r4$state)

  r5 <- drive(r4$state, ev_apply(list(op_delete(new1)), at(13)))
  check_invisible(r4$state, r5$state)
})

# ---- 8. Reuse is real --------------------------------------------------------

test_that("after one cell finishes, every patch sits under its own cell_results or a top-level scalar (8)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- 1"), C = cell("c <- 1")))
  r <- boot(s, "A")
  p1 <- pluto_state(r$state)
  out <- new_display("text/plain", "1", "[1] 1")
  r2 <- drive(r$state, wk_done(1, last_token(r), report(output = out, created = "a"), at(10)))
  p2 <- pluto_state(r2$state, p1)

  d <- fb_diff(p1$js, p2$js)
  expect_true(length(d) > 0)
  for (patch in d) {
    ok <- length(patch$path) == 0 ||
      (length(patch$path) >= 2 && identical(patch$path[[1]], "cell_results") && identical(patch$path[[2]], "A")) ||
      (length(patch$path) <= 1)
    expect_true(ok, info = paste(patch$path, collapse = "/"))
  }
  expect_identical(p2$js$cell_inputs$S, p1$js$cell_inputs$S)
  expect_identical(p2$js$cell_results$B, p1$js$cell_results$B)
  expect_identical(p2$js$cell_results$C, p1$js$cell_results$C)
})

# ---- 9. Output mapping --------------------------------------------------------

#' A minimal `ember_cell_view` for project_output()'s precedence table.
fake_view <- function(kind = "code", status = "not_run", code = "", errors = list(),
                      output = NULL, last_run = NULL) {
  list(kind = kind, status = status, code = code, errors = errors,
      output = output, last_run = last_run)
}

test_that("output mapping: one case per row of the precedence table (9)", {
  # plain text, ANSI kept
  o <- project_output(fake_view(output = new_display("text/plain", "\033[31mred\033[0m", "x")))
  expect_equal(o$mime, "text/plain"); expect_equal(o$body, "\033[31mred\033[0m")

  # HTML
  o <- project_output(fake_view(output = new_display("text/html", "<b>x</b>", "x")))
  expect_equal(o$mime, "text/html"); expect_equal(o$body, "<b>x</b>")

  # PNG: raw body passed through
  raw_png <- as.raw(1:4)
  o <- project_output(fake_view(output = new_display("image/png", raw_png, "x")))
  expect_equal(o$mime, "image/png"); expect_identical(o$body, raw_png)

  # SVG
  o <- project_output(fake_view(output = new_display("image/svg+xml", "<svg/>", "x")))
  expect_equal(o$mime, "image/svg+xml"); expect_equal(o$body, "<svg/>")

  # markdown output, with commonmark
  skip_if_not_installed("commonmark")
  o <- project_output(fake_view(output = new_display("text/markdown", "# h", "h")))
  expect_equal(o$mime, "text/html")
  expect_match(o$body, "<h1>h</h1>")

  # markdown cell (kind, not mime), with commonmark
  o <- project_output(fake_view(kind = "markdown", code = "**bold**"))
  expect_equal(o$mime, "text/html")
  expect_match(o$body, "<strong>bold</strong>")

  # table/tree/latex fall back to the print() form
  o <- project_output(fake_view(output = new_display("application/vnd.ember.table", list(), "a table")))
  expect_equal(o$mime, "text/plain"); expect_equal(o$body, "a table")
  o <- project_output(fake_view(output = new_display("application/vnd.ember.tree", list(), "a tree")))
  expect_equal(o$mime, "text/plain"); expect_equal(o$body, "a tree")
  o <- project_output(fake_view(output = new_display("text/latex", "$x$", "x")))
  expect_equal(o$mime, "text/plain"); expect_equal(o$body, "x")

  # no output
  o <- project_output(fake_view())
  expect_equal(o$mime, "text/plain"); expect_equal(o$body, "")
})

test_that("markdown falls back to text/plain without commonmark (9)", {
  local_mocked_bindings(commonmark_available = function() FALSE)
  o <- project_output(fake_view(kind = "markdown", code = "# h"))
  expect_equal(o$mime, "text/plain")
  expect_equal(o$body, "# h")
})

# ---- 10. Errors ----------------------------------------------------------------

test_that("a parse error gives parseerror+object with one diagnostic on the right line (10)", {
  s <- fake_state(list(S = cell(""), A = cell("f <- function(\n  x <-\n 1")))
  v <- snapshot_of(s)$cells$A
  o <- project_output(v)
  expect_equal(o$mime, "application/vnd.pluto.parseerror+object")
  expect_equal(length(o$body$diagnostics), 1)
  expect_true(o$body$diagnostics[[1]]$line >= 1)
  expect_true(check_wire(o))
})

test_that("a multiple-definitions error message starts right, with fixes on separate lines (10)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x <- 2")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(changed = "x"), at(11)))
  v <- snapshot_of(r$state)$cells$B
  o <- project_output(v)
  expect_equal(o$mime, "application/vnd.pluto.stacktrace+object")
  expect_match(o$body$msg, "^Multiple definitions for x")
  expect_true(grepl("\n", o$body$msg))
})

test_that("a run error's stack trace is innermost first with no file/line (10)", {
  tb <- c("outer()", "inner()")  # innermost last, as new_run_error() documents
  err <- new_run_error("error", message = "boom", traceback = tb)
  o <- project_error(err)
  expect_equal(vapply(o$stacktrace, `[[`, character(1), "call"), rev(tb))
  for (f in o$stacktrace) {
    expect_equal(f$file, ""); expect_equal(f$line, -1L)
  }
})

test_that("an interrupted cell shows 'Interrupted' with no frames (10)", {
  v <- fake_view(status = "interrupted")
  o <- project_output(v)
  expect_equal(o$mime, "application/vnd.pluto.stacktrace+object")
  expect_equal(o$body$msg, "Interrupted")
  expect_equal(o$body$stacktrace, list())
})

# ---- 11. Console --------------------------------------------------------------

test_that("console items map to Pluto's log levels, in order (11)", {
  console <- list(list(kind = "stdout", text = "a"), list(kind = "message", text = "b"),
                  list(kind = "warning", text = "c"))
  logs <- project_logs(console, "A")
  expect_equal(vapply(logs, `[[`, character(1), "level"),
              c("LogLevel(-555)", "Info", "Warn"))
  expect_equal(logs[[1]]$cell_id, "A")
  expect_equal(logs[[1]]$msg, list("a", "text/plain"))
})

test_that("a running cell's growing console gives an add patch, not a replace (11)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  p1 <- pluto_state(r$state)
  r2 <- drive(r$state, wk_console(1, last_token(r), list(kind = "stdout", text = "hi"), at(10)))
  p2 <- pluto_state(r2$state, p1)
  d <- fb_diff(p1$js, p2$js)
  logs_patches <- Filter(function(p) "logs" %in% as.character(p$path), d)
  expect_true(length(logs_patches) > 0)
  expect_true(all(vapply(logs_patches, function(p) identical(p$op, "add"), logical(1))))
})

# ---- 12. Stale / blocked-by-failure / code_differs ----------------------------

test_that("stale sets depends_on_disabled_cells (12)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("y <- x")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(11)))
  # Editing A alone doesn't mark B stale (an edit never marks anything
  # stale by itself); re-running A does, the moment it is sent to the
  # worker (schedule()'s invalidate_dependents()), before it even finishes.
  r2 <- drive(r$state, ev_run("A", at(12)))
  v <- snapshot_of(r2$state)$cells$B
  expect_true(v$stale)
  cr <- project_cell_result(v)
  expect_true(cr$depends_on_disabled_cells)
})

test_that("blocked-by-failure sets depends_on_disabled_cells (12)", {
  s <- fake_state(list(S = cell(""), A = cell('x <- stop("boom")'), B = cell("y <- x")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(error = list(message = "boom")), at(10)))
  v <- snapshot_of(r$state)$cells$B
  expect_false(is.na(v$blocked_by))
  cr <- project_cell_result(v)
  expect_true(cr$depends_on_disabled_cells)
})

test_that("code that differs from the last run also marks cell_results stale (12)", {
  # An edit made outside the page (the R API, Endeavor) leaves the old
  # output showing under the new code until something tells the frontend to
  # dim it: `depends_on_disabled_cells` is the only field Pluto's Cell.js
  # reads for that, so `code_differs` has to show up there, not only in
  # `cell_inputs` (review4 item 4).
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  p1 <- pluto_state(r$state)
  expect_false(p1$js$cell_results$A$depends_on_disabled_cells)
  r2 <- drive(r$state, ev_apply(list(op_set_code("A", "x <- 2")), at(11)))
  p2 <- pluto_state(r2$state, p1)
  expect_equal(p2$js$cell_inputs$A$code, "x <- 2")
  expect_true(p2$js$cell_results$A$depends_on_disabled_cells)
})

# ---- 13. process_status / nbpkg ------------------------------------------------

test_that("process_status reads safe preview and every worker status (13)", {
  s <- fake_state(list(S = cell("")))
  expect_equal(project_process_status(s), "waiting_for_permission")

  s$allowed <- TRUE
  for (st in c("off", "starting")) {
    s$worker$status <- st
    expect_equal(project_process_status(s), "starting")
  }
  for (st in c("ready", "busy")) {
    s$worker$status <- st
    expect_equal(project_process_status(s), "ready")
  }
  s$worker$status <- "stopped"
  expect_equal(project_process_status(s), "no_process")
})

test_that("nbpkg reflects missing, installing and failed packages, and a restart offer (13)", {
  lock <- new_lock(name = c("a", "b", "c"), version = c("1.0", "2.0", "3.0"),
                   source = rep("CRAN", 3))
  file <- fake_file(list(S = cell(""), A = cell("1")), lock = lock)
  s <- new_state(file, path = "nb.R", id = "n1", options = list(), at = 0)

  v <- project_nbpkg(s)
  pv <- packages_view(s)
  expect_equal(sum(pv$packages$status == "missing"), 3)
  expect_equal(length(v$installed_versions), 0)

  s$packages$target$status <- "installing"
  s$packages$install <- list(token = 1L, key = s$packages$target$key)
  v2 <- project_nbpkg(s)
  expect_true(length(v2$busy_packages) > 0)

  s$packages$target$status <- "failed"
  s$packages$target$message <- "network unreachable"
  s$packages$install <- NULL
  v3 <- project_nbpkg(s)
  expect_match(v3$terminal_outputs$nbpkg_sync, "network unreachable")

  s$worker$restart_offered <- TRUE
  v4 <- project_nbpkg(s)
  expect_match(v4$restart_recommended_msg, "Restart R to stop it")
})

# ---- 14. cell_dependencies ------------------------------------------------------

test_that("cell_dependencies for a three-cell chain (14)", {
  g <- notebook_graph(c(S = "", A = "x <- 1", B = "y <- x", C = "z <- y"), setup = "S")
  deps <- project_dependencies(g, NULL)
  expect_equal(deps$B$upstream_cells_map$x, list("A"))
  expect_equal(deps$A$downstream_cells_map$x, list("B"))
  expect_equal(deps$C$upstream_cells_map$y, list("B"))
})

test_that("cell_dependencies for a library() cell uses the exported name (14)", {
  g <- notebook_graph(c(S = "", A = "library(dplyr)", B = "filter(df, x > 1)"),
                      setup = "S", exports = list(dplyr = c("filter", "select")))
  deps <- project_dependencies(g, NULL)
  expect_equal(deps$B$upstream_cells_map$filter, list("A"))
  expect_equal(deps$A$precedence_heuristic, 5L)
  expect_equal(deps$B$precedence_heuristic, 9L)
})

test_that("an edit that changes one cell's references changes only its own and its neighbours' entries (14)", {
  g1 <- notebook_graph(c(S = "", A = "x <- 1", B = "y <- x", C = "z <- 1"), setup = "S")
  d1 <- project_dependencies(g1, NULL)
  g2 <- notebook_graph(c(S = "", A = "x <- 1", B = "y <- 2", C = "z <- 1"), setup = "S", previous = g1)
  d2 <- project_dependencies(g2, d1)
  expect_identical(d2$C, d1$C)
  expect_false(identical(d2$A, d1$A))
  expect_false(identical(d2$B, d1$B))
})

# ---- Sharing and performance (engine.md, Performance) ---------------------------

test_that("a one-cell change at 2000 cells keeps every other cell's projection identical(), under 60ms (90 ms before keying by position; CI machines run 24-33 ms)", {
  cells <- list(S = cell(""))
  for (i in 1:2000) cells[[sprintf("c%d", i)]] <- cell(sprintf("x%d <- %d", i, i))
  s <- fake_state(cells, setup = "S")
  p1 <- pluto_state(s)

  s2 <- drive(s, ev_apply(list(op_set_code("c7", "x7 <- 999")), at(1)))$state

  tt <- system.time(p2 <- pluto_state(s2, p1))[["elapsed"]]
  cat(sprintf("\n[timing] pluto_state() at 2000 cells, one changed cell: %.1f ms\n", tt * 1000))

  for (id in names(s2$cells)) {
    if (identical(id, "c7")) next
    expect_identical(p2$js$cell_inputs[[id]], p1$js$cell_inputs[[id]], info = id)
    expect_identical(p2$js$cell_results[[id]], p1$js$cell_results[[id]], info = id)
  }
  expect_false(identical(p2$js$cell_inputs$c7, p1$js$cell_inputs$c7))
  expect_lt(tt, 0.06)
})

test_that("a one-cell change at 2000 cells stays fast when every cell has a result (review4 item 7)", {
  # The quadratic case the bare timing test above didn't catch: with no
  # results at all, `state$results[[id]]` is a named lookup into an empty
  # list, which is cheap regardless of the loop around it. Once every cell
  # has run, that same per-cell lookup is a linear scan over a 2000-entry
  # named list, done once per cell per flush -- 0.95ms a cell, ~2s total,
  # before view_context() aligned `results` by position with match().
  cells <- list(S = cell(""))
  for (i in 1:2000) cells[[sprintf("c%d", i)]] <- cell(sprintf("x%d <- %d", i, i))
  s <- fake_state(cells, setup = "S")
  s$allowed <- TRUE
  ids <- names(s$cells)
  s$results <- stats::setNames(lapply(ids, function(id) {
    list(status = "ok", code = s$cells[[id]]$code,
        output = list(mime = "text/plain", data = "1", text = "1"), console = list(),
        started_at = 1, runtime = 0.01, stale = FALSE, error = NULL, defined = character())
  }), ids)
  p1 <- pluto_state(s)

  s2 <- drive(s, ev_apply(list(op_set_code("c7", "x7 <- 999")), at(1)))$state

  tt <- system.time(p2 <- pluto_state(s2, p1))[["elapsed"]]
  cat(sprintf("\n[timing] pluto_state() at 2000 cells, every cell has a result, one changed: %.1f ms\n",
             tt * 1000))

  for (id in ids) {
    if (identical(id, "c7")) next
    expect_identical(p2$js$cell_results[[id]], p1$js$cell_results[[id]], info = id)
  }
  # Loose enough for slow CI runners (60 ms on Windows), still far below ~2s.
  expect_lt(tt, 0.5)
})

# ---- ui-2-tests.md 1: markdown kind on the wire -----------------------------

test_that("project_cell_input() gives kind markdown/code; check_wire() passes on every engine fixture (ui-2 1)", {
  s0 <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a"),
                        Md = cell("# hi", kind = "markdown")))
  js0 <- pluto_state(s0)$js
  expect_equal(js0$cell_inputs$Md$kind, "markdown")
  expect_equal(js0$cell_inputs$A$kind, "code")
  expect_true(check_wire(js0))

  r1 <- boot(s0, "A")
  js1 <- pluto_state(r1$state)$js
  expect_equal(js1$cell_inputs$Md$kind, "markdown")
  expect_true(check_wire(js1))

  r2 <- drive(r1$state, wk_done(1, last_token(r1), report(created = "a"), at(10)))
  js2 <- pluto_state(r2$state)$js
  expect_equal(js2$cell_inputs$Md$kind, "markdown")
  expect_true(check_wire(js2))
})
