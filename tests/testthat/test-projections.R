# Tests for the state.R projections: snapshot_of(), notifications(),
# notebook_file_of(), watched_files(), plus the sharing and performance
# properties the design depends on (engine.md, Performance; the spike).
#
# Covers engine-tests.md items 67-75, plus the sharing test (116 in the
# design doc's numbering) and a timing check on a 2000-cell notebook.

test_that("snapshot fields are right for every cell status (67)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a"),
                       Md = cell("#' notes", kind = "markdown")))
  r <- boot(s, c("A", "B"))
  expect_equal(last_sent(r)$cell, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(10)))
  expect_equal(last_sent(r)$cell, "B")
  out <- new_display("text/plain", "2", "[1] 2")
  r <- drive(r$state, wk_done(1, last_token(r), report(output = out), at(11)))

  snap <- snapshot_of(r$state)
  a <- snap$cells$A
  expect_equal(a$id, "A"); expect_equal(a$index, 2); expect_equal(a$kind, "code")
  expect_equal(a$settings, list()); expect_false(a$queued); expect_false(a$running)
  expect_equal(a$status, "ok"); expect_false(a$stale); expect_false(a$code_differs)

  b <- snap$cells$B
  expect_equal(b$status, "ok"); expect_equal(b$output, out)

  md <- snap$cells$Md
  expect_equal(md$kind, "markdown"); expect_equal(md$status, "not_run")

  s2 <- snapshot_of(fake_state(list(S = cell("options(digits = 3)\nSys.setenv(TZ = 'UTC')"))))
  expect_equal(s2$cells$S$settings, list(list(name = "digits", found = "code"),
                                          list(name = "TZ", found = "code")))
})

test_that("the running cell's snapshot shows the streamed console (68)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  expect_equal(r$state$worker$running$cell, "A")
  r <- drive(r$state, wk_console(1, last_token(r), list(kind = "stdout", text = "hi"), at(10)))
  v <- snapshot_of(r$state)$cells$A
  expect_true(v$running)
  expect_equal(v$console, list(list(kind = "stdout", text = "hi")))
})

test_that("notifications list only the cells whose view changed (69)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("y <- 2")))
  r <- drive(s, ev_apply(list(op_set_code("A", "x <- 2")), at(1)))
  n <- notifications(s, r$state)
  cs <- Find(function(x) identical(x$kind, "cell_state"), n)
  expect_equal(cs$cells, "A")
})

test_that("notifications list topology_changed only when edges change (70)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("y <- x")))

  r1 <- drive(s, ev_apply(list(op_set_code("A", "x <- 2")), at(1)))  # keeps the edge
  n1 <- notifications(s, r1$state)
  expect_null(Find(function(x) identical(x$kind, "topology_changed"), n1))

  r2 <- drive(s, ev_apply(list(op_set_code("A", "z <- 2")), at(1)))  # drops the edge
  n2 <- notifications(s, r2$state)
  topo <- Find(function(x) identical(x$kind, "topology_changed"), n2)
  expect_true(!is.null(topo) && "B" %in% topo$cells)
})

test_that("execution_done fires once, when the queue drains (71)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  expect_equal(r$state$worker$running$cell, "A")
  before <- r$state
  r2 <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  n <- notifications(before, r2$state)
  expect_true(!is.null(Find(function(x) identical(x$kind, "execution_done"), n)))
})

test_that("a burst of events folded into one before/after pair gives one cell_state (72)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("y <- 2")))
  r <- drive(s, ev_apply(list(op_set_code("A", "x <- 2")), at(1)),
            ev_apply(list(op_set_code("B", "y <- 3")), at(2)),
            ev_apply(list(op_fold("A", TRUE)), at(3)))
  n <- notifications(s, r$state)
  cs <- Filter(function(x) identical(x$kind, "cell_state"), n)
  expect_equal(length(cs), 1)
  expect_setequal(cs[[1]]$cells, c("A", "B"))
})

test_that("notebook_file_of() round-trips the fields of a fake state (73)", {
  s <- fake_state(list(S = cell("s <- 1"), A = cell("a <- 1"), B = cell("b <- a")))
  f <- notebook_file_of(s)
  expect_equal(f$cells, s$cells)
  expect_equal(f$run_order, s$graph$order)
  expect_equal(f$lock, s$file$lock)
})

test_that("opening a notebook never changes its text (74)", {
  # parse_notebook() -> new_state() -> notebook_file_of() -> format_notebook(),
  # with no step() in between (no run, no files_read). `notebook_file_of()`
  # always writes the graph's own run order and the running Ember's version,
  # so "the original text" here means text already in that canonical shape
  # (built by one real save, below) rather than a fixture's literal bytes:
  # lazy-unicode.R, for instance, deliberately lays display order and run
  # order out differently (the "cells written in run order" test), which
  # `notebook_file_of()` could never itself have produced.
  new_id <- local({ i <- 0; function() { i <<- i + 1; sprintf("open-%03d", i) } })
  paths <- list.files("files/format-1", full.names = TRUE)
  expect_true("files/format-1/computed-source.R" %in% paths)
  running <- as.character(utils::packageVersion("ember"))

  for (path in paths) {
    raw <- readChar(path, file.info(path)$size, useBytes = TRUE)
    file0 <- parse_notebook(raw, new_id = new_id, version = running)
    s0 <- new_state(file0, path = path, id = "n1", options = list(), at = 0)
    text <- format_notebook(notebook_file_of(s0), s0$graph$order)  # one real save

    file <- parse_notebook(text, new_id = new_id, version = running)
    s <- new_state(file, path = path, id = "n1", options = list(), at = 0)
    out <- format_notebook(notebook_file_of(s), s$graph$order)
    expect_identical(out, text, info = path)
  }

  # The regression this item is about: a computed `source()` path recorded
  # in the footer must survive a plain open, not just a save-then-reopen
  # round trip (new_state() used to ignore `file$sourced` entirely).
  path <- "files/format-1/computed-source.R"
  raw <- readChar(path, file.info(path)$size, useBytes = TRUE)
  file0 <- parse_notebook(raw, new_id = new_id, version = running)
  expect_equal(file0$sourced$path, "helpers/dyn.R")
  s0 <- new_state(file0, path = "nb.R", id = "n1", options = list(), at = 0)
  out0 <- format_notebook(notebook_file_of(s0), s0$graph$order)
  expect_match(out0, "helpers/dyn\\.R md5:deadbeef")
})

test_that("watched_files lists literal and computed source paths (75)", {
  s <- fake_state(list(S = cell(""), A = cell('source("h.R")')))
  r <- boot(s, "A")
  expect_equal(r$state$worker$running$cell, "A")
  r <- drive(r$state, wk_source(1, last_token(r), "computed.R", "w <- 1", at(10)))
  wf <- watched_files(r$state)
  expect_true("h.R" %in% wf)
  expect_true("computed.R" %in% wf)
})

# ---- Sharing and performance ------------------------------------------------

test_that("an unrelated edit shares unchanged parts of the state (identical())", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("y <- 2"), C = cell("z <- 3")))
  r <- drive(s, ev_apply(list(op_set_code("A", "x <- 2")), at(1)))
  expect_identical(s$cells$B, r$state$cells$B)
  expect_identical(s$cells$C, r$state$cells$C)
  expect_identical(s$graph$analyses$B, r$state$graph$analyses$B)
  expect_identical(s$graph$analyses$C, r$state$graph$analyses$C)
  expect_identical(s$worker, r$state$worker)
})

test_that("one step on a 2000-cell notebook stays well under 50ms", {
  # An event that doesn't touch `cells`/`exports`/`files` never
  # rebuilds the graph (rebuild_graph() is only called from the handlers
  # that change one of those); this is the common case while a notebook is
  # running (a cell finishing, console output, a timer). Rebuilding 2000
  # cells' edges/order/errors from scratch is step 1's (graph.R) cost, not
  # measured here.
  cells <- list(S = cell(""))
  for (i in 1:2000) cells[[sprintf("c%d", i)]] <- cell(sprintf("x%d <- %d", i, i))
  s <- fake_state(cells)
  r <- drive(s, ev_run(NULL, at(1)), wk_started(1, 99, at(2)), wk_hello(1, list(), at(3)))

  times <- numeric(20)
  st <- r$state
  for (i in seq_along(times)) {
    tok <- st$worker$running$token
    tt <- system.time(res <- step(st, wk_done(1, tok, report(), at(10 + i))))[["elapsed"]]
    times[i] <- tt
    st <- res$state
  }
  cat(sprintf("\n[timing] step() on a 2000-cell notebook (no rebuild): median %.1f ms, max %.1f ms\n",
             stats::median(times) * 1000, max(times) * 1000))
  expect_lt(stats::median(times), 0.05)
})
