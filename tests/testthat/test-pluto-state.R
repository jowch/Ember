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
             "metadata", "nbpkg", "cell_dependencies", "cell_execution_order")) {
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
                        Md = cell("#' hi", kind = "markdown")))
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
      (length(patch$path) <= 1) ||
      # `ember`'s own fields (piece 5): a leaf one level under "ember" is as
      # much a "top-level scalar" as `process_status` is, just nested one
      # level deeper because Ember's additions share one map (ui-2.md, Rules
      # every piece follows).
      (length(patch$path) == 2 && identical(patch$path[[1]], "ember"))
    expect_true(ok, info = paste(patch$path, collapse = "/"))
  }
  expect_identical(p2$js$cell_inputs$S, p1$js$cell_inputs$S)
  expect_identical(p2$js$cell_results$B, p1$js$cell_results$B)
  expect_identical(p2$js$cell_results$C, p1$js$cell_results$C)
})

# ---- 9. Output mapping --------------------------------------------------------

#' A minimal `ember_cell_view` for project_output()'s precedence table.
fake_view <- function(kind = "code", status = "not_run", code = "", errors = list(),
                      output = NULL, last_run = NULL, code_differs = FALSE) {
  list(kind = kind, status = status, code = code, errors = errors,
      output = output, last_run = last_run, code_differs = code_differs)
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

  # markdown output
  o <- project_output(fake_view(output = new_display("text/markdown", "# h", "h")))
  expect_equal(o$mime, "text/html")
  expect_match(o$body, "<h1>h</h1>")

  # markdown cell (kind, not mime)
  o <- project_output(fake_view(kind = "markdown", code = "**bold**"))
  expect_equal(o$mime, "text/html")
  expect_match(o$body, "<strong>bold</strong>")

  # table becomes Pluto's table body
  table_data <- list(names = c("a", "b"), types = c("<dbl>", "<chr>"), nrow = 2L, ncol = 2L,
                     row_labels = c("1", "2"), rows = list(c("1", "x"), c("2", "y")),
                     more_rows = 0L, more_cols = 0L)
  o <- project_output(fake_view(output = new_display("application/vnd.ember.table", table_data, "a table")))
  expect_equal(o$mime, "application/vnd.pluto.table+object")
  expect_equal(o$body$schema$names, list("a", "b"))
  expect_equal(o$body$ember_size, list(2L, 2L, 0L, 0L))

  # tree becomes Pluto's tree body
  tree_data <- list(type = "list", path = "", length = 1L, named = TRUE,
                    items = list(list(key = "a", value = list(type = "text", text = "1"))), more = 0L)
  o <- project_output(fake_view(output = new_display("application/vnd.ember.tree", tree_data, "a tree")))
  expect_equal(o$mime, "application/vnd.pluto.tree+object")
  expect_equal(o$body$type, "r_list")
  expect_equal(o$body$elements, list(list("a", list("1", "text/plain"))))

  # latex falls back to the print() form
  o <- project_output(fake_view(output = new_display("text/latex", "$x$", "x")))
  expect_equal(o$mime, "text/plain"); expect_equal(o$body, "x")

  # no output
  o <- project_output(fake_view())
  expect_equal(o$mime, "text/plain"); expect_equal(o$body, "")
})

# ---- Inline values: project_text() via project_output() (48) ----------------

test_that("project_output() of a text cell: with and without inline values, code_differs, errors (48)", {
  code <- "#' Half of it is `r x / 2`."

  o_not_run <- project_output(fake_view(kind = "markdown", code = code))
  expect_equal(o_not_run$mime, "text/html")
  expect_match(o_not_run$body, "<code>r x / 2</code>")
  expect_true(check_wire(o_not_run))

  out_ok <- new_display("application/vnd.ember.inline", list(values = "10.5"), "10.5")
  o_ok <- project_output(fake_view(kind = "markdown", code = code, output = out_ok))
  expect_equal(o_ok$mime, "text/html")
  expect_equal(o_ok$body, '<p>Half of it is <span class="ember-inline">10.5</span>.</p>\n')
  expect_true(check_wire(o_ok))

  out_html <- new_display("application/vnd.ember.inline", list(values = "<b>"), "<b>")
  o_html <- project_output(fake_view(kind = "markdown", code = "#' `r x`", output = out_html))
  expect_match(o_html$body, "&lt;b&gt;", fixed = TRUE)

  o_differs <- project_output(fake_view(kind = "markdown", code = code, output = out_ok, code_differs = TRUE))
  expect_false(grepl("ember-inline", o_differs$body, fixed = TRUE))
  expect_match(o_differs$body, "<code>r x / 2</code>")

  o_err <- project_output(fake_view(kind = "markdown", code = "#' `r x`",
    errors = list(list(kind = "error", message = "boom", fixes = character(), names = character(),
                       cells = character(), traceback = character()))))
  expect_equal(o_err$mime, "application/vnd.pluto.stacktrace+object")
  expect_true(check_wire(o_err))
})

test_that("project_text() matches spans line by line, never across a line break (review)", {
  # inline_spans() of this code finds exactly one span ("y"): line 1's
  # `r ` has no closing backtick on its own line, so it isn't one. A
  # whole-body regex (the old implementation) would instead match across
  # the line break, consuming "x" as a bogus second span.
  code <- "#' see `r \n#' x` and `r y`"
  out <- new_display("application/vnd.ember.inline", list(values = "Y"), "Y")
  o <- project_output(fake_view(kind = "markdown", code = code, output = out))
  expect_equal(o$mime, "text/html")
  expect_match(o$body, '<span class="ember-inline">Y</span>', fixed = TRUE)
  expect_match(o$body, "r", fixed = TRUE)  # the unmatched "`r " stays literal, rendered by commonmark itself
})

test_that("project_text() puts an inline value inside an href as plain escaped text, not a span (review)", {
  code <- "#' [link `r u`](http://e/`r v`)"
  out <- new_display("application/vnd.ember.inline", list(values = c("U", "V\"<x>")), "U, V")
  o <- project_output(fake_view(kind = "markdown", code = code, output = out))
  href <- regmatches(o$body, regexpr('href="[^"]*"', o$body))
  expect_equal(href, 'href="http://e/V&quot;&lt;x&gt;"')
  expect_no_match(href, "<span", fixed = TRUE)
  expect_match(o$body, '<span class="ember-inline">U</span>', fixed = TRUE)
})

# ---- 10. Errors ----------------------------------------------------------------

test_that("a parse error gives parseerror+object with one diagnostic on the right line (10)", {
  s <- fake_state(list(S = cell(""), A = cell("f <- function(\n  x <-\n 1")))
  v <- snapshot_of(s)$cells$A
  o <- project_output(v)
  expect_equal(o$mime, "application/vnd.pluto.parseerror+object")
  expect_equal(length(o$body$diagnostics), 1)
  # The syntax error is on line 2 (an unexpected assignment right after
  # "x <-"); the diagnostic must land there, not always on line 1.
  expect_equal(o$body$diagnostics[[1]]$line, 2L)
  expect_true(check_wire(o))
})

test_that("a private-name error projects with no cell id in its message (10)", {
  owner_id <- "ca1b0a64-d117-466f-898a-8603bbc24e75"
  reader_id <- "e2f5c0a1-8a8e-4e8e-9a0e-1a2b3c4d5e6f"
  cells <- setNames(list(cell(".tmp <- 1"), cell("print(.tmp)")), c(owner_id, reader_id))
  s <- fake_state(cells)
  v <- snapshot_of(s)$cells[[reader_id]]
  o <- project_output(v)
  expect_equal(o$mime, "application/vnd.pluto.stacktrace+object")
  expect_no_match(o$body$msg, owner_id, fixed = TRUE)
  expect_no_match(o$body$msg, reader_id, fixed = TRUE)
  expect_match(o$body$msg, ".tmp", fixed = TRUE)
})

test_that("a cycle error projects with no cell id in its message (10)", {
  id_a <- "ca1b0a64-d117-466f-898a-8603bbc24e75"
  id_b <- "e2f5c0a1-8a8e-4e8e-9a0e-1a2b3c4d5e6f"
  cells <- setNames(list(cell("a <- 1\nb"), cell("b <- 1\na")), c(id_a, id_b))
  s <- fake_state(cells)
  v <- snapshot_of(s)$cells[[id_a]]
  o <- project_output(v)
  expect_equal(o$mime, "application/vnd.pluto.stacktrace+object")
  expect_no_match(o$body$msg, id_a, fixed = TRUE)
  expect_no_match(o$body$msg, id_b, fixed = TRUE)
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

test_that("project_error() adds ember_call/line/deep and frames' source_package/ember_cell, innermost first, without changing today's fields (ui-3-tests 133)", {
  tb <- c("outer()", "inner()")  # innermost last, as new_run_error() documents
  frames <- list(list(call = "outer()", package = NULL, cell = "A"),
                 list(call = "inner()", package = "stats", cell = NULL))
  err <- new_run_error("error", message = "boom", traceback = tb,
                       call = "inner()", line = 3L, deep = TRUE, frames = frames)
  o <- project_error(err)
  expect_equal(o$ember_call, "inner()")
  expect_equal(o$ember_line, 3L)
  expect_equal(o$ember_deep, TRUE)
  expect_equal(vapply(o$stacktrace, `[[`, character(1), "call"), rev(tb))
  expect_equal(o$stacktrace[[1]]$source_package, "stats")
  expect_equal(o$stacktrace[[1]]$ember_cell, NULL)
  expect_equal(o$stacktrace[[2]]$source_package, NULL)
  expect_equal(o$stacktrace[[2]]$ember_cell, "A")

  # Without the new fields, every other field is exactly what it was
  # before this piece.
  without_new <- lapply(o$stacktrace, function(f) {
    f[setdiff(names(f), c("source_package", "ember_cell"))]
  })
  baseline <- new_run_error("error", message = "boom", traceback = tb)
  baseline_stacktrace <- project_error(baseline)$stacktrace
  baseline_without_new <- lapply(baseline_stacktrace, function(f) {
    f[setdiff(names(f), c("source_package", "ember_cell"))]
  })
  expect_equal(without_new, baseline_without_new)
  expect_equal(o$msg, project_error(baseline)$msg)
  expect_equal(o$plain_error, project_error(baseline)$plain_error)
})

test_that("project_error() drops ember_cell when it isn't a known cell id (item 4)", {
  tb <- c("outer()", "inner()")  # innermost last, as new_run_error() documents
  frames <- list(list(call = "outer()", package = NULL, cell = "A"),
                 list(call = "inner()", package = NULL, cell = "<text>"))
  err <- new_run_error("error", message = "boom", traceback = tb, frames = frames)

  # With no known_ids, every frame's cell passes through unchecked.
  o_unchecked <- project_error(err)
  expect_equal(o_unchecked$stacktrace[[1]]$ember_cell, "<text>")
  expect_equal(o_unchecked$stacktrace[[2]]$ember_cell, "A")

  # "<text>" (a text cell's per-line parse, which keeps no srcfile) isn't
  # one of the notebook's real cell ids, so it's dropped; "A" is kept.
  o <- project_error(err, known_ids = c("A", "B"))
  expect_null(o$stacktrace[[1]]$ember_cell)
  expect_equal(o$stacktrace[[2]]$ember_cell, "A")
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

test_that("project_logs(): a warning with a call gives ember$call; an item without one has no ember field (ui-3-tests 136)", {
  console <- list(list(kind = "warning", text = "careful", call = "g()"),
                  list(kind = "warning", text = "top-level"),
                  list(kind = "message", text = "m"))
  logs <- project_logs(console, "A")
  expect_identical(logs[[1]]$ember, list(call = "g()"))
  expect_false("ember" %in% names(logs[[2]]))
  expect_false("ember" %in% names(logs[[3]]))
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
#
# Increment 2 (ui-2.md, 5) narrows `depends_on_disabled_cells` to
# "blocked by a failed ancestor" alone, and gives stale and code-changed
# cells their own `ember$stale`/`ember$code_changed` labels instead (piece 5
# decision: "depends_on_disabled_cells becomes blocked_by only").

test_that("stale sets ember$stale, not depends_on_disabled_cells (12)", {
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
  expect_true(cr$ember$stale)
  expect_false(cr$depends_on_disabled_cells)
})

test_that("a run cell with a parse error projects as errored, not code_changed, with no cell id in the message", {
  id <- "ca1b0a64-d117-466f-898a-8603bbc24e75"
  cells <- list(S = cell(""))
  cells[[id]] <- cell("x <- 1")
  r <- boot(fake_state(cells), id)
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  r <- drive(r$state, ev_apply(list(op_set_code(id, "x <- (.3,.6)")), at(11)),
             ev_run(id, at(12)))

  cr <- pluto_state(r$state)$js$cell_results[[id]]
  expect_true(cr$errored)
  expect_false(cr$ember$code_changed)
  expect_equal(cr$output$mime, "application/vnd.pluto.parseerror+object")
  diags <- cr$output$body$diagnostics
  expect_length(diags, 1)
  expect_equal(diags[[1]]$message, "Syntax error: unexpected ','")
})

test_that("project_cell_result(): ember$split for a mixed_text cell, NULL for a text cell (49)", {
  s <- fake_state(list(S = cell(""), M = cell("#' a\nx <- 1"), T = cell("#' hi", kind = "markdown")))
  vm <- snapshot_of(s)$cells$M
  expect_equal(project_cell_result(vm)$ember$split, 2L)

  vt <- snapshot_of(s)$cells$T
  expect_null(project_cell_result(vt)$ember$split)
})

test_that("ember$variables matches the view; a run of A patches only cell_results/A; export_html()'s state has no variables (ui-3 71)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- 1")))
  r <- boot(s, "A")
  p1 <- pluto_state(r$state)
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a",
             globals = list(a = list(type = "numeric", value = "1", kind = "value"))), at(10)))
  p2 <- pluto_state(r$state, p1)

  js <- p2$js
  expect_true(check_wire(js))
  view <- snapshot_of(r$state)$cells$A
  expect_equal(js$cell_results$A$ember$variables, as_arr(view$variables))
  expect_equal(js$cell_results$A$ember$variables, list(list(name = "a", type = "numeric", value = "1", kind = "value")))

  d <- fb_diff(p1$js, p2$js)
  expect_true(length(d) > 0)
  for (patch in d) {
    ok <- length(patch$path) <= 1 ||
      (length(patch$path) >= 2 && identical(patch$path[[1]], "cell_results") && identical(patch$path[[2]], "A")) ||
      (length(patch$path) == 2 && identical(patch$path[[1]], "ember"))
    expect_true(ok, info = paste(patch$path, collapse = "/"))
  }

  html <- export_html(r$state)
  start <- regexpr('window.pluto_statefile = "data:;base64,', html, fixed = TRUE)
  rest <- substring(html, start + attr(start, "match.length"))
  statefile_b64 <- substr(rest, 1, regexpr('"', rest, fixed = TRUE) - 1)
  decoded <- mp_decode(jsonlite::base64_dec(statefile_b64))
  for (id in names(decoded$cell_results)) {
    expect_null(decoded$cell_results[[id]]$ember$variables)
  }
})

test_that("project_cell_result(): ember$figure comes from the cell's code, not the stored image's pixel size; none for a text output; check_wire() passes (ui-3 67)", {
  s <- fake_state(list(S = cell(""), A = cell("#| fig-width: 8\n#| fig-height: 4\nplot(1)")))
  # Deliberately mismatched against the code's 8 x 4: an API render_png()
  # call can leave the stored image at any pixel size, and ember$figure
  # must not follow it (review: ember$figure from the cell's code).
  out <- new_display("image/png", as.raw(1:4), "[plot]", size = list(width = 999, height = 999, res = 100))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(output = out), at(10)))

  js <- pluto_state(r$state)$js
  expect_true(check_wire(js))
  expect_equal(js$cell_results$A$ember$figure, list(width = 8, height = 4))

  s2 <- fake_state(list(S = cell(""), A = cell("1")))
  r2 <- boot(s2, "A")
  r2 <- drive(r2$state,
             wk_done(1, last_token(r2), report(output = new_display("text/plain", "1", "1")), at(10)))
  js2 <- pluto_state(r2$state)$js
  expect_null(js2$cell_results$A$ember$figure)
})

test_that("an upstream error projects ember$upstream_error, not depends_on_disabled_cells (ui-3 11)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("a + 1")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "boom")), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r),
                              report(status = "error", error = list(message = "object 'a' not found")), at(11)))

  js <- pluto_state(r$state)$js
  expect_true(check_wire(js))
  cr <- js$cell_results$B
  expect_false(cr$depends_on_disabled_cells)
  expect_equal(cr$ember$upstream_error, list(list(name = "a", cell = "A")))
  expect_equal(cr$output$mime, "application/vnd.pluto.stacktrace+object")
  expect_equal(cr$output$body$msg, "Another cell defining a contains errors.")
  expect_equal(cr$output$body$stacktrace, list())
  expect_equal(cr$output$body$plain_error, "Another cell defining a contains errors.\nobject 'a' not found")

  for (id in c("S", "A")) {
    expect_null(js$cell_results[[id]]$ember$upstream_error)
  }
})

test_that("two names in an upstream error join with 'or' (ui-3 11)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- 2"), C = cell("a + b")))
  r <- boot(s, c("A", "B", "C"))
  r <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "boom a")), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "boom b")), at(11)))
  r <- drive(r$state, wk_done(1, last_token(r),
                              report(status = "error", error = list(message = "neither found")), at(12)))

  cr <- pluto_state(r$state)$js$cell_results$C
  expect_equal(cr$ember$upstream_error, list(list(name = "a", cell = "A"), list(name = "b", cell = "B")))
  expect_equal(cr$output$body$msg, "Another cell defining a or b contains errors.")
})

test_that("code that differs from the last run sets ember$code_changed, not depends_on_disabled_cells (12)", {
  # An edit made outside the page (the R API, Endeavor) leaves the old
  # output showing under the new code; the page dims it and shows a
  # "code changed" label from `ember$code_changed` (CellInput.js's own
  # `.code_differs` class, from the page's *unsubmitted* edit, is unrelated).
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  p1 <- pluto_state(r$state)
  expect_false(p1$js$cell_results$A$ember$code_changed)
  r2 <- drive(r$state, ev_apply(list(op_set_code("A", "x <- 2")), at(11)))
  p2 <- pluto_state(r2$state, p1)
  expect_equal(p2$js$cell_inputs$A$code, "x <- 2")
  expect_true(p2$js$cell_results$A$ember$code_changed)
  expect_false(p2$js$cell_results$A$depends_on_disabled_cells)
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
  g <- notebook_graph(c(S = "", A = "x <- 1", B = "y <- x", C = "z <- y"))
  deps <- project_dependencies(g, NULL)
  expect_equal(deps$B$upstream_cells_map$x, list("A"))
  expect_equal(deps$A$downstream_cells_map$x, list("B"))
  expect_equal(deps$C$upstream_cells_map$y, list("B"))
})

test_that("cell_dependencies for a library() cell uses the exported name (14)", {
  g <- notebook_graph(c(S = "", A = "library(dplyr)", B = "filter(df, x > 1)"), exports = list(dplyr = c("filter", "select")))
  deps <- project_dependencies(g, NULL)
  expect_equal(deps$B$upstream_cells_map$filter, list("A"))
  expect_equal(deps$A$precedence_heuristic, 5L)
  expect_equal(deps$B$precedence_heuristic, 9L)
})

test_that("a definition no cell reads is still in its cell's downstream_cells_map, with an empty array (53)", {
  g <- notebook_graph(c(S = "", A = "x <- 1; unread <- 2"))
  deps <- project_dependencies(g, NULL)
  expect_equal(deps$A$downstream_cells_map$unread, list())
})

test_that("an edit that changes one cell's references changes only its own and its neighbours' entries (14)", {
  g1 <- notebook_graph(c(S = "", A = "x <- 1", B = "y <- x", C = "z <- 1"))
  d1 <- project_dependencies(g1, NULL)
  g2 <- notebook_graph(c(S = "", A = "x <- 1", B = "y <- 2", C = "z <- 1"), previous = g1)
  d2 <- project_dependencies(g2, d1)
  expect_identical(d2$C, d1$C)
  expect_false(identical(d2$A, d1$A))
  expect_false(identical(d2$B, d1$B))
})

# ---- Sharing and performance (engine.md, Performance) ---------------------------

test_that("a one-cell change at 2000 cells keeps every other cell's projection identical(), and costs a fraction of a full projection", {
  x <- perf_projection(2000)
  s2 <- x$state; p1 <- x$previous
  p2 <- pluto_state(s2, p1)
  for (id in names(s2$cells)) {
    if (identical(id, "c7")) next
    expect_identical(p2$js$cell_inputs[[id]], p1$js$cell_inputs[[id]], info = id)
    expect_identical(p2$js$cell_results[[id]], p1$js$cell_results[[id]], info = id)
  }
  expect_false(identical(p2$js$cell_inputs$c7, p1$js$cell_inputs$c7))

  # Timed against the same state projected from scratch, not a fixed
  # budget (helper-perf.R): about 0.12 of it here. Reusing nothing would be
  # all of it.
  r <- time_ratio(function() pluto_state(s2, p1), function() pluto_state(s2), samples = 5L, inner_a = 3L)
  cat(sprintf("\n[timing] pluto_state() at 2000 cells, one changed cell: %.1f ms, from scratch %.1f ms (%.3f)\n",
              r$a * 1000, r$b * 1000, r$ratio))
  expect_lt(r$ratio, 0.35)

  # Ten times the cells should cost at most about ten times as much: a
  # per-cell lookup by name (90 ms here before keying by position) grows
  # with the square. About 6x here, as fixed costs weigh more at 200.
  y <- perf_projection(200)
  g <- time_ratio(function() pluto_state(s2, p1), function() pluto_state(y$state, y$previous),
                  inner_a = 3L, inner_b = 20L)
  cat(sprintf("[timing] pluto_state(), one changed cell: 2000 cells %.1f ms, 200 cells %.2f ms (%.1fx)\n",
              g$a * 1000, g$b * 1000, g$ratio))
  expect_lt(g$ratio, 20)
  # Backstop: about 40 ms on a cloud container.
  expect_lt(g$a, 0.5)
})

test_that("a one-cell change at 2000 cells stays fast when every cell has a result (review4 item 7)", {
  # The quadratic case the bare timing test above didn't catch: with no
  # results at all, `state$results[[id]]` is a named lookup into an empty
  # list, which is cheap regardless of the loop around it. Once every cell
  # has run, that same per-cell lookup is a linear scan over a 2000-entry
  # named list, done once per cell per flush -- 0.95ms a cell, ~2s total,
  # before view_context() aligned `results` by position with match().
  x <- perf_projection(2000, results = TRUE)
  s2 <- x$state; p1 <- x$previous
  p2 <- pluto_state(s2, p1)
  for (id in names(s2$cells)) {
    if (identical(id, "c7")) next
    expect_identical(p2$js$cell_results[[id]], p1$js$cell_results[[id]], info = id)
  }

  # So with results it should cost about twice what it does without (the
  # results themselves are compared and projected): the quadratic lookup
  # made it some thirty-five times as much.
  y <- perf_projection(2000)
  r <- time_ratio(function() pluto_state(s2, p1), function() pluto_state(y$state, y$previous),
                  inner_a = 3L, inner_b = 3L)
  cat(sprintf("\n[timing] pluto_state() at 2000 cells, one changed: %.1f ms with every result, %.1f ms with none (%.2fx)\n",
              r$a * 1000, r$b * 1000, r$ratio))
  expect_lt(r$ratio, 8)
  expect_lt(r$a, 0.5)
})

# ---- ui-2-tests.md 1: markdown kind on the wire -----------------------------

test_that("project_cell_input() gives kind markdown/code; check_wire() passes on every engine fixture (ui-2 1)", {
  s0 <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a"),
                        Md = cell("#' hi", kind = "markdown")))
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

# ---- ui-2-tests.md 29-30: project_table()/project_tree() -------------------

test_that("project_table() ends names/types/rows in 'more' when truncated, each cell a text/plain pair (ui-2 28)", {
  table_data <- list(names = paste0("c", 1:8), types = rep("<dbl>", 8), nrow = 32L, ncol = 11L,
                     row_labels = as.character(1:10),
                     rows = lapply(1:10, function(i) paste0("v", i, "_", 1:8)),
                     more_rows = 22L, more_cols = 3L)
  body <- project_table(table_data)
  expect_equal(body$objectid, "")
  expect_equal(body$ember_size, list(32L, 11L, 22L, 3L))
  expect_equal(utils::tail(body$schema$names, 1), list("more"))
  expect_equal(utils::tail(body$schema$types, 1), list("more"))
  expect_equal(length(body$schema$names), 9)
  expect_equal(length(body$rows), 11)  # 10 rows + a final "more" row
  expect_equal(utils::tail(body$rows, 1), list("more"))
  row1 <- body$rows[[1]]
  expect_equal(row1[[1]], "1")
  cells <- row1[[2]]
  expect_equal(utils::tail(cells, 1), list("more"))
  expect_equal(cells[[1]], list("v1_1", "text/plain"))

  s0 <- fake_state(list(S = cell(""), A = cell("mtcars")))
  js0 <- pluto_state(s0)$js
  expect_true(check_wire(js0))
})

test_that("project_table(): ember_size and ember_na, one array per row; ember_dims is gone; check_wire() passes (ui-3-tests 134)", {
  table_data <- list(names = paste0("c", 1:8), types = rep("<dbl>", 8), nrow = 32L, ncol = 11L,
                     row_labels = as.character(1:10),
                     rows = lapply(1:10, function(i) paste0("v", i, "_", 1:8)),
                     more_rows = 22L, more_cols = 3L,
                     na = c(list(integer()), list(c(2L, 5L)), rep(list(integer()), 8)))
  body <- project_table(table_data)
  expect_equal(body$ember_size, list(32L, 11L, 22L, 3L))
  expect_null(body$ember_dims)
  expect_equal(length(body$ember_na), 10)
  expect_equal(body$ember_na[[1]], list())
  expect_equal(body$ember_na[[2]], list(1L, 4L))

  s0 <- fake_state(list(S = cell(""), A = cell("data.frame(a = c(1, NA), b = c('x', NA))")))
  js0 <- pluto_state(s0)$js
  expect_true(check_wire(js0))
  r1 <- boot(s0, "A")
  js1 <- pluto_state(r1$state)$js
  expect_true(check_wire(js1))
})

test_that("project_tree() nests nodes under vnd.pluto.tree+object, 'more' last, objectid is path (ui-2 29)", {
  node <- list(type = "list", path = "", length = 3L, named = TRUE,
              items = list(
                list(key = "a", value = list(type = "text", text = "1")),
                list(key = "b", value = list(type = "list", path = "2", length = 1L, named = TRUE,
                                            items = list(list(key = "c", value = list(type = "text", text = "\"x\""))),
                                            more = 0L))
              ), more = 1L)
  body <- project_tree(node)
  expect_equal(body$objectid, "")
  expect_equal(body$type, "r_list")
  expect_equal(body$elements[[1]], list("a", list("1", "text/plain")))
  nested <- body$elements[[2]]
  expect_equal(nested[[1]], "b")
  expect_equal(nested[[2]][[2]], "application/vnd.pluto.tree+object")
  expect_equal(nested[[2]][[1]]$objectid, "2")
  expect_equal(utils::tail(body$elements, 1), list("more"))
})

test_that("project_tree(): ember_length is set; a vector leaf gets the ember.vector+object MIME (ui-3-tests 135)", {
  node <- list(type = "list", path = "", length = 3L, named = TRUE,
              items = list(
                list(key = "a", value = list(type = "text", text = "1")),
                list(key = "long", value = list(type = "vector", values = as.character(1:10),
                                               type_sum = "int", length = 100L))
              ), more = 1L)
  body <- project_tree(node)
  expect_equal(body$ember_length, 3L)
  vector_el <- body$elements[[2]]
  expect_equal(vector_el[[1]], "long")
  expect_equal(vector_el[[2]][[2]], "application/vnd.ember.vector+object")
  expect_equal(vector_el[[2]][[1]]$type_sum, "int")
  expect_equal(vector_el[[2]][[1]]$length, 100L)
  expect_equal(vector_el[[2]][[1]]$values, as.list(as.character(1:10)))
})

# ---- ui-2-tests.md 33: HTML output with widget dependencies -----------------

test_that("project_output() prepends dependency tags in order; staticRender only for htmlwidgets (ui-2 32)", {
  deps <- list(
    list(name = "jquery", version = "3.6.0", dir = "/lib", href = NULL,
        script = "jquery.js", stylesheet = "jquery.css", head = NULL),
    list(name = "htmlwidgets", version = "1.5", dir = "/lib2", href = NULL,
        script = "htmlwidgets.js", stylesheet = character(), head = NULL)
  )
  o <- project_output(fake_view(output = new_display("text/html", "<div>hi</div>", "hi", deps = deps)))
  expect_equal(o$mime, "text/html")
  link_pos <- regexpr('<link rel="stylesheet" href="deps/jquery-3.6.0/jquery.css">', o$body)
  script_pos <- regexpr('<script src="deps/jquery-3.6.0/jquery.js"></script>', o$body)
  widgets_pos <- regexpr('<script src="deps/htmlwidgets-1.5/htmlwidgets.js"></script>', o$body)
  static_render_pos <- regexpr("HTMLWidgets.staticRender", o$body, fixed = TRUE)
  div_pos <- regexpr("<div>hi</div>", o$body, fixed = TRUE)
  expect_true(link_pos < script_pos)
  expect_true(script_pos < widgets_pos)
  expect_true(widgets_pos < div_pos)
  expect_gt(static_render_pos, 0)

  # an href-only dependency uses its href directly
  o2 <- project_output(fake_view(output = new_display("text/html", "<p/>", "p",
    deps = list(list(name = "cdnlib", version = "1", dir = NULL, href = "https://example.org/",
                     script = "a.js", stylesheet = character(), head = NULL)))))
  expect_match(o2$body, '<script src="https://example.org/a.js">', fixed = TRUE)

  # no dependencies: unchanged
  o3 <- project_output(fake_view(output = new_display("text/html", "<p/>", "p")))
  expect_equal(o3$body, "<p/>")
})

test_that("project_dep_tags() adds a '/' between a bare href and its file (ui-2 review)", {
  tags <- project_dep_tags(list(list(name = "cdnlib", version = "1", dir = NULL,
    href = "https://example.org/lib", script = "a.js", stylesheet = "a.css", head = NULL)))
  expect_match(tags, '<link rel="stylesheet" href="https://example.org/lib/a.css">', fixed = TRUE)
  expect_match(tags, '<script src="https://example.org/lib/a.js"></script>', fixed = TRUE)

  # an href that already ends in "/" isn't doubled
  tags2 <- project_dep_tags(list(list(name = "cdnlib", version = "1", dir = NULL,
    href = "https://example.org/lib/", script = "a.js", stylesheet = character(), head = NULL)))
  expect_match(tags2, '<script src="https://example.org/lib/a.js"></script>', fixed = TRUE)
  expect_false(grepl("lib//a.js", tags2, fixed = TRUE))
})

test_that("project_dep_tags() accepts htmltools' list form for a script entry (ui-2 review)", {
  tags <- project_dep_tags(list(list(name = "mod", version = "1", dir = "/lib", href = NULL,
    script = list(list(src = "a.js", type = "module")), stylesheet = character(), head = NULL)))
  expect_match(tags, '<script src="deps/mod-1/a.js" type="module"></script>', fixed = TRUE)

  # a mix of plain names and list entries
  tags2 <- project_dep_tags(list(list(name = "mod", version = "1", dir = "/lib", href = NULL,
    script = list("plain.js", list(src = "a.js", type = "module")),
    stylesheet = character(), head = NULL)))
  expect_match(tags2, '<script src="deps/mod-1/plain.js"></script>', fixed = TRUE)
  expect_match(tags2, '<script src="deps/mod-1/a.js" type="module"></script>', fixed = TRUE)
})

# ---- Disable cell (ui-3 33) --------------------------------------------------

test_that("CELL_METADATA_DISABLED, depends_on_disabled_cells, disabled_by and can_disable (ui-3 33)", {
  # B never runs: its change after disabling A has to come from disabled_by
  # entering cell_key(), not from any change to its own result.
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1"), T = cell("#' hi", kind = "markdown")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(created = "x"), at(10)))

  p0 <- pluto_state(r$state)
  check_wire(p0$js)
  expect_null(p0$js$cell_results$B$ember$disabled_by)
  expect_false(p0$js$cell_results$B$depends_on_disabled_cells)

  r2 <- drive(r$state, ev_apply(list(op_disable("A")), at(20)))
  p1 <- pluto_state(r2$state, p0)
  check_wire(p1$js)

  expect_identical(p1$js$cell_inputs$A$metadata, CELL_METADATA_DISABLED)
  expect_identical(p1$js$cell_inputs$B$metadata, CELL_METADATA)
  expect_identical(p1$js$cell_inputs$S$metadata, CELL_METADATA)

  expect_true(p1$js$cell_results$A$depends_on_disabled_cells)
  expect_true(p1$js$cell_results$B$depends_on_disabled_cells)
  expect_false(p1$js$cell_results$S$depends_on_disabled_cells)

  expect_null(p1$js$cell_results$A$ember$disabled_by)
  expect_equal(p1$js$cell_results$B$ember$disabled_by, "A")
  expect_false(p1$js$cell_results$A$ember$stale)
  expect_false(p1$js$cell_results$B$ember$stale)

  expect_true(p1$js$cell_results$S$ember$can_disable)  # no cell is special (settings-cells.md)
  expect_false(p1$js$cell_results$T$ember$can_disable)
  expect_true(p1$js$cell_results$A$ember$can_disable)
  expect_true(p1$js$cell_results$B$ember$can_disable)

  # Disabling A changed exactly A's and B's entries: S, T and their own
  # cell_inputs stayed the same R objects, reused from p0.
  ids0 <- names(p1$js$cell_results)
  changed0 <- Filter(function(id) !identical(p0$js$cell_results[[id]], p1$js$cell_results[[id]]), ids0)
  expect_setequal(changed0, c("A", "B"))

  r3 <- drive(r2$state, ev_apply(list(op_set_code("T", "#' hi there", expected = "#' hi")), at(21)))
  p2 <- pluto_state(r3$state, p1)
  ids <- names(p2$js$cell_results)
  changed <- Filter(function(id) !identical(p1$js$cell_results[[id]], p2$js$cell_results[[id]]), ids)
  expect_setequal(changed, "T")
})

# ---- 82: project_ember()'s packages$library$log/failures -------------------

test_that("project_ember(): library$log is set only when failed; check_wire() passes; a repeat flush emits no ember/packages patch (82)", {
  lock <- new_lock("brokenpkg", "0.1.0", "CRAN")
  s <- fake_state(list(S = cell(""), A = cell("library(brokenpkg)")), lock = lock)
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(2)))
  r <- drive(r$state, ev_allow(at(3)))
  key <- r$state$packages$target$key
  token <- r$state$packages$install$token

  # Before any failure: not failed yet, so no log and no failures.
  js0 <- pluto_state(r$state)$js
  expect_true(check_wire(js0))
  expect_null(js0$ember$packages$library$log)
  expect_equal(length(js0$ember$packages$library$failures), 0)

  failures <- data.frame(package = "brokenpkg", kind = "compile", detail = NA_character_,
                         stringsAsFactors = FALSE)
  lines <- c("Installing brokenpkg ...", "ERROR: compilation failed for package 'brokenpkg'")
  r2 <- drive(r$state, ev_install_done(token, key, NULL, "install failed: compilation failed for package 'brokenpkg'",
                                       lines, at(4), failures = failures))

  p1 <- pluto_state(r2$state)
  js1 <- p1$js
  expect_true(check_wire(js1))
  expect_match(js1$ember$packages$library$log, "compilation failed for package 'brokenpkg'", fixed = TRUE)
  expect_equal(length(js1$ember$packages$library$failures), 1)
  expect_equal(js1$ember$packages$library$failures[[1]]$package, "brokenpkg")

  # A second flush of the exact same state must emit no patch at all under
  # ember/packages: nothing changed, so `reuse_fields()` keeps the old
  # `packages` object whole (including `log`), not just its scalar fields.
  p2 <- pluto_state(r2$state, p1)
  d <- fb_diff(p1$js, p2$js)
  under_packages <- Filter(function(patch) {
    length(patch$path) >= 2 && identical(patch$path[[1]], "ember") && identical(patch$path[[2]], "packages")
  }, d)
  expect_equal(length(under_packages), 0)
})

# ---- 101-102: project_ember()'s on_cell_change/r_version/worker_started_at -

test_that("project_ember(): read_only mirrors state$read_only (101)", {
  s <- fake_state(list(S = cell("")))
  expect_false(pluto_state(s)$js$ember$read_only)

  s$read_only <- TRUE
  expect_true(pluto_state(s)$js$ember$read_only)
})

test_that("project_ember(): on_cell_change, r_version and worker_started_at track the header and the running worker (101)", {
  s <- fake_state(list(S = cell("")))
  js0 <- pluto_state(s)$js
  expect_true(check_wire(js0))
  expect_equal(js0$ember$on_cell_change, "autorun")
  expect_null(js0$ember$r_version)
  expect_null(js0$ember$worker_started_at)

  r <- drive(s, ev_run("S", at(1)), wk_started(1, 99, at(2)))
  gen <- r$state$worker$gen
  r <- drive(r$state, wk_hello(gen, list(r_version = "4.6.1"), at(1000)))
  js1 <- pluto_state(r$state)$js
  expect_true(check_wire(js1))
  expect_equal(js1$ember$r_version, "4.6.1")
  expect_equal(js1$ember$worker_started_at, 1000)

  r2 <- drive(r$state, ev_set_mode("lazy", at(1001)))
  js2 <- pluto_state(r2$state)$js
  expect_true(check_wire(js2))
  expect_equal(js2$ember$on_cell_change, "lazy")
})

test_that("a worker restart clears worker_started_at until the next hello (102)", {
  s <- fake_state(list(S = cell("")))
  r <- drive(s, ev_run("S", at(1)), wk_started(1, 99, at(2)))
  gen <- r$state$worker$gen
  r <- drive(r$state, wk_hello(gen, list(r_version = "4.6.1"), at(3)))
  expect_equal(pluto_state(r$state)$js$ember$worker_started_at, 3)

  r2 <- drive(r$state, ev_restart(at(4)))
  expect_null(r2$state$worker$started_at)
  expect_equal(r2$state$worker$status, "starting")
  expect_null(pluto_state(r2$state)$js$ember$worker_started_at)

  r3 <- drive(r2$state, wk_hello(r2$state$worker$gen, list(r_version = "4.6.1"), at(5)))
  expect_equal(pluto_state(r3$state)$js$ember$worker_started_at, 5)
})

test_that("the worker exiting or failing to start clears worker_started_at and r_version (102)", {
  s <- fake_state(list(S = cell("")))
  r <- drive(s, ev_run("S", at(1)), wk_started(1, 99, at(2)), wk_hello(1, list(r_version = "4.6.1"), at(3)))
  js1 <- pluto_state(r$state)$js
  expect_equal(js1$ember$worker_started_at, 3)
  expect_equal(js1$ember$r_version, "4.6.1")

  r2 <- drive(r$state, wk_exited(1, 1L, "boom", at(4)))
  expect_null(r2$state$worker$started_at)
  expect_null(r2$state$worker$info)
  js2 <- pluto_state(r2$state)$js
  expect_null(js2$ember$worker_started_at)
  expect_null(js2$ember$r_version)

  # A worker that reported a version, then a *next* generation that never
  # sends hello (fails to start): the previous generation's r_version must
  # not leak into the new one's "stopped" projection.
  r3 <- drive(r2$state, ev_run("S", at(5)))
  gen2 <- r3$state$worker$gen
  r4 <- drive(r3$state, wk_failed(gen2, "no Rscript", at(6)))
  expect_null(r4$state$worker$started_at)
  expect_null(r4$state$worker$info)
  js4 <- pluto_state(r4$state)$js
  expect_null(js4$ember$worker_started_at)
  expect_null(js4$ember$r_version)
})

test_that("project_error() gives a setting or package conflict's cells, so the page links the other (review)", {
  err <- list(kind = "setting_conflict", message = "digits is set in two cells.",
              fixes = "Keep one", cells = c("A", "B"))
  o <- project_error(err)
  expect_equal(o$ember_cells, list("A", "B"))
  expect_null(project_error(list(kind = "error", message = "boom"))$ember_cells)
})
