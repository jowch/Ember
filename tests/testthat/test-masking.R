# Data-masking calls (#107): `x` in `subset(df, x > 1)` is `df`'s column
# when `df` has one, and the global `x` otherwise, as under Rscript.

# ---- Reading ------------------------------------------------------------------

test_that("names in a data-masking call's other arguments are noted with their data", {
  a <- read_cell("d2 <- subset(df, x > cutoff, select = c(a, b))")
  expect_setequal(a$masked$name, c("x", "cutoff", "a", "b"))
  expect_true(all(a$masked$data == "df"))
  expect_true(all(a$masked$fn == "subset"))
  # Still references, so everything that reads references sees them.
  expect_true(all(c("x", "cutoff") %in% references_of(a)))
  expect_false("df" %in% a$masked$name)

  for (code in c("d <- transform(df, w = x * 2)", "d <- with(df, mean(x))",
                 "d <- within(df, w <- x * 2)", "d <- df |> subset(x > 1)",
                 "d <- base::subset(df, x > 1)", "d <- subset(x = df, x > 1)")) {
    a <- read_cell(code)
    expect_equal(a$masked$name, "x", info = code)
    expect_equal(a$masked$data, "df", info = code)
  }
})

test_that("a call's head and a data argument that isn't a bare name aren't masked", {
  a <- read_cell("d2 <- subset(df, f(x) > 1)")
  expect_equal(a$masked$name, "x")
  # `$` is a generic read (#41), but as a call head it is never a column.
  a <- read_cell("d2 <- subset(df, a$b > 1)")
  expect_equal(a$masked$name, "a")
  a <- read_cell("d2 <- subset(df[1:2, ], x > 1)")
  expect_equal(nrow(a$masked), 0)
  expect_true("x" %in% references_of(a))
  a <- read_cell("g <- function(df) subset(df, x > 1)")
  expect_equal(nrow(a$masked), 0)
  a <- read_cell("d2 <- dplyr::filter(df, x > 1)")
  expect_equal(nrow(a$masked), 0)
})

test_that("assignments inside with() and within() define no global", {
  a <- read_cell("d <- within(df, { z <- x * 2; w <- z + 1 })")
  expect_equal(definitions_of(a), "d")
  expect_equal(a$masked$name, "x")
  a <- read_cell("m <- with(df, { tmp <- x; tmp + y })")
  expect_equal(definitions_of(a), "m")
  expect_setequal(a$masked$name, c("x", "y"))
})

# ---- The graph ----------------------------------------------------------------------

issue_cells <- c(D = "df <- data.frame(x = 1:4, y = 1:4)",
                 F = "d2 <- subset(df, x > 1)",
                 X = "x <- seq(0, 1, by = 0.1); p <- nrow(d2)")

test_that("the issue's notebook: no false cycle before or after df's cell runs", {
  g <- notebook_graph(issue_cells)
  # Unknown columns: the edge is soft, and dropped because it closes a cycle.
  expect_length(g$errors, 0)
  g2 <- graph_learn(g, "D", columns = list(D = list(df = list(frame = TRUE, names = c("x", "y")))))
  expect_length(g2$errors, 0)
  expect_false("X" %in% g2$upstream$F)
  expect_true("F" %in% g2$upstream$X)
})

test_that("a name the data doesn't have is an ordinary edge", {
  g <- notebook_graph(issue_cells)
  g2 <- graph_learn(g, "D", columns = list(D = list(df = list(frame = TRUE, names = "y"))))
  expect_true("X" %in% g2$upstream$F)
  expect_equal(g2$errors[[1]]$kind, "cycle")

  g <- notebook_graph(c(D = "df <- data.frame(y = 1:4)", F = "d2 <- subset(df, x > 1)", X = "x <- 2"))
  expect_true("X" %in% g$upstream$F)  # soft, and closes no cycle
  g2 <- graph_learn(g, "D", columns = list(D = list(df = list(frame = TRUE, names = "y"))))
  expect_true("X" %in% g2$upstream$F)
  g3 <- graph_learn(g, "D", columns = list(D = list(df = list(frame = TRUE, names = c("x", "y")))))
  expect_false("X" %in% g3$upstream$F)
})

test_that("the answer is an edge whenever the columns can't decide it", {
  cols <- list(df = list(frame = TRUE, names = c("x", "y")))
  base <- c(D = "df <- data.frame(x = 1:4, y = 1:4)", F = "d2 <- subset(df, x > 1)", X = "x <- 2")
  has_edge <- function(cells, learned_cell = "D", columns = cols) {
    g <- graph_learn(notebook_graph(cells), learned_cell, columns = setNames(list(columns), learned_cell))
    "X" %in% g$upstream$F
  }
  expect_false(has_edge(base))
  # The run reported no names for df (its value is no data frame or list).
  expect_true(has_edge(base, columns = list()))
  # subset() masks only with a data frame; with() masks with a list too.
  lst <- list(df = list(frame = FALSE, names = c("x", "y")))
  expect_true(has_edge(base, columns = lst))
  expect_false(has_edge(c(base[c("D", "X")], F = "d2 <- with(df, x + 1)"), columns = lst))
  # The notebook defines subset() itself, or a method of it.
  expect_true(has_edge(c(base, S = "subset <- function(x, ...) x")))
  expect_true(has_edge(c(base, S = "subset.data.frame <- function(x, ...) x")))
  # df is defined by two cells, or by none (a package's data).
  expect_true(has_edge(c(base, E = "df <- 1")))
  expect_true(has_edge(c(F = "d2 <- subset(mtcars, x > 1)", X = "x <- 2"), learned_cell = "X"))
  # Read outside the call too.
  expect_true(has_edge(c(base[c("D", "X")], F = "d2 <- subset(df, x > 1); x + 1")))
})

test_that("a cell that defines its own data settles the name on its first run", {
  cells <- c(F = "df <- data.frame(x = 1:4); d2 <- subset(df, x > 1)",
             X = "x <- 0.5; p <- nrow(d2)")
  g <- notebook_graph(cells)
  expect_length(g$errors, 0)
  g2 <- graph_learn(g, "F", columns = list(F = list(df = list(frame = TRUE, names = "x"),
                                           d2 = list(frame = TRUE, names = "x"))))
  expect_length(g2$errors, 0)
  g3 <- graph_learn(g, "F", columns = list(F = list(df = list(frame = TRUE, names = "y"))))
  expect_equal(g3$errors[[1]]$kind, "cycle")
})

# ---- Running (the core, with a fake worker) --------------------------------------

frame_cols <- function(...) list(frame = TRUE, names = c(...))

#' Answer each run the core sends with `reports[[cell]]` (an empty report
#' for a cell not named) until nothing is running.
run_to_idle <- function(r, reports = list(), at0 = 100) {
  i <- 0
  while (identical(r$state$worker$status, "busy")) {
    cell_id <- r$state$worker$running$cell
    rep <- reports[[cell_id]] %||% report()
    i <- i + 1
    r <- drive(r$state, wk_done(1, r$state$worker$running$token, rep, at(at0 + i)))
  }
  r
}

test_that("the data cell's report decides the edge before the reader runs", {
  s <- fake_state(list(S = cell(""), D = cell("df <- data.frame(y = 1:4)"),
                       F = cell("d2 <- subset(df, x > 1)"), X = cell("x <- 2")))
  r <- boot(s, c("D", "F"))
  expect_equal(last_sent(r)$cell, "D")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "df", columns = list(df = frame_cols("y"))), at(10)))
  # df has no x: F reads the global, so X runs first.
  expect_equal(last_sent(r)$cell, "X")
  expect_true("X" %in% r$state$graph$upstream$F)
})

data_reports <- function(df_cols) {
  list(D = report(created = "df", columns = list(df = do.call(frame_cols, as.list(df_cols)))),
       F = report(created = "d2", columns = list(d2 = do.call(frame_cols, as.list(df_cols)))),
       X = report(created = "x"), K = report(created = "k"))
}

test_that("editing x doesn't rerun a reader whose data has the column", {
  s <- fake_state(list(S = cell(""), D = cell("df <- data.frame(x = 1:4)"),
                       F = cell("d2 <- subset(df, x > 1)"), X = cell("x <- 2")))
  r <- run_to_idle(boot(s, NULL), data_reports("x"))
  expect_false("X" %in% r$state$graph$upstream$F)
  r2 <- drive(r$state, ev_apply(list(op_set_code("X", "x <- 3")), at(200)), ev_run("X", at(201)))
  expect_equal(last_sent(r2)$cell, "X")
  r2 <- run_to_idle(r2, data_reports("x"), at0 = 210)
  expect_false(isTRUE(r2$state$results$F$stale))
  expect_false("F" %in% sent_cells(r2))
})

test_that("a failed run of the data cell forgets its columns", {
  s <- fake_state(list(S = cell(""), D = cell("df <- data.frame(x = 1:4)"),
                       F = cell("d2 <- subset(df, x > 1)"), X = cell("x <- 2")))
  r <- boot(s, "D")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "df", columns = list(df = frame_cols("x"))), at(10)))
  expect_false("X" %in% r$state$graph$upstream$F)
  r <- drive(r$state, ev_run("D", at(11)))
  r <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "no"), created = "df",
                                                       columns = list(df = frame_cols("x"))), at(12)))
  expect_null(r$state$data_columns$D)
  expect_true("X" %in% r$state$graph$upstream$F)
})

test_that("a restart or R exiting forgets every cell's columns", {
  s <- fake_state(list(S = cell(""), D = cell("df <- data.frame(x = 1:4)"),
                       F = cell("d2 <- subset(df, x > 1)"), X = cell("x <- 2")))
  r <- run_to_idle(boot(s, NULL), data_reports("x"))
  expect_false("X" %in% r$state$graph$upstream$F)
  r2 <- drive(r$state, ev_restart(at(200)))
  expect_length(r2$state$data_columns, 0)
  expect_true("X" %in% r2$state$graph$upstream$F)
  r3 <- drive(r$state, wk_exited(1, status = 1L, message = "gone", at = at(200)))
  expect_length(r3$state$data_columns, 0)
  expect_true("X" %in% r3$state$graph$upstream$F)
})

test_that("an input found after the run was asked for, from a stale cell, leaves the result stale", {
  # Lazy: K's rerun leaves X stale. Running F reruns D, whose new df has
  # no column x, so F now reads X; X wasn't asked for, so F's result
  # (from X's old value) is stale, and running F again runs X first.
  s <- fake_state(list(S = cell(""), K = cell("k <- 1"), X = cell("x <- k"),
                       D = cell("df <- data.frame(x = 1:4)"), F = cell("d2 <- subset(df, x > 1)")),
                  on_cell_change = "lazy")
  r <- run_to_idle(boot(s, NULL), data_reports("x"))
  expect_false("X" %in% r$state$graph$upstream$F)
  r <- run_to_idle(drive(r$state, ev_run("K", at(200))), data_reports("x"), at0 = 210)
  expect_true(isTRUE(r$state$results$X$stale))

  r <- drive(r$state, ev_apply(list(op_set_code("D", "df <- data.frame(y = 1:4)")), at(300)), ev_run("F", at(301)))
  expect_equal(last_sent(r)$cell, "D")
  r <- drive(r$state, wk_done(1, last_token(r), data_reports("y")$D, at(310)))
  expect_true("X" %in% r$state$graph$upstream$F)
  expect_equal(last_sent(r)$cell, "X")
  r <- run_to_idle(r, data_reports("y"), at0 = 320)
  expect_false(isTRUE(r$state$results$F$stale))
  expect_false(isTRUE(r$state$results$X$stale))
})

test_that("an input a cell's own run finds, from a stale cell, leaves its result stale", {
  # The formula check is the other way a run finds an input: x is taken
  # as a column of df until F's run finds it isn't.
  s <- fake_state(list(S = cell(""), K = cell("k <- 1"), X = cell("x <- k"),
                       F = cell("fit <- lm(y ~ x, data = df)")),
                  on_cell_change = "lazy")
  r <- run_to_idle(boot(s, c("K", "X")))
  r <- run_to_idle(drive(r$state, ev_run("K", at(200))), at0 = 210)
  expect_true(isTRUE(r$state$results$X$stale))
  expect_false("X" %in% r$state$graph$upstream$F)
  r <- drive(r$state, ev_run("F", at(300)))
  expect_equal(last_sent(r)$cell, "F")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "fit", formula_misses = "x"), at(310)))
  expect_true("X" %in% r$state$graph$upstream$F)
  expect_true(isTRUE(r$state$results$F$stale))
  r <- drive(r$state, ev_run("F", at(400)))
  expect_equal(last_sent(r)$cell, "X")
})

# ---- Running (a real worker) -------------------------------------------------

test_that("the issue's notebook runs, and follows R as the data's columns change", {
  cells <- list(S = cell(""),
                D = cell("df <- data.frame(x = 1:4, y = 1:4)"),
                F = cell("d2 <- subset(df, x > 1); nrow(d2)"),
                X = cell("x <- seq(0, 1, by = 0.1); p <- nrow(d2)"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 30)
  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  for (id in c("D", "F", "X")) expect_equal(snap_view(snap, id)$status, "ok", info = id)
  expect_equal(snap_view(snap, "F")$output$text, "[1] 3")

  # df without x: subset() reads the global x, so F and X form a real
  # cycle, as they would under Rscript.
  edit_notebook(nb, set_code("D", "df <- data.frame(y = 1:4)"))
  res <- run_cells(nb, "D", wait = TRUE, timeout = 30)
  expect_false(res$timed_out)
  errs <- snap_view(notebook_snapshot(nb), "F")$error
  expect_true(any(vapply(errs, function(e) identical(e$kind, "cycle"), logical(1))))

  # And back. Run all skips F and X while they're still in the cycle
  # (D hasn't rerun yet), so it takes a second run, as for any cycle.
  edit_notebook(nb, set_code("D", "df <- data.frame(x = 1:4, y = 1:4)"))
  res <- run_cells(nb, wait = TRUE, timeout = 30)
  expect_false(res$timed_out)
  res <- run_cells(nb, wait = TRUE, timeout = 30)
  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  for (id in c("D", "F", "X")) expect_equal(snap_view(snap, id)$status, "ok", info = id)
  expect_equal(snap_view(snap, "F")$output$text, "[1] 3")
})

test_that("a global the data doesn't shadow is read, and its edit reruns the reader", {
  cells <- list(S = cell(""),
                D = cell("df <- data.frame(y = 1:4)"),
                F = cell("nrow(subset(df, y > cutoff))"),
                C = cell("cutoff <- 1"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 30)
  expect_false(res$timed_out)
  expect_equal(snap_view(notebook_snapshot(nb), "F")$output$text, "[1] 3")
  edit_notebook(nb, set_code("C", "cutoff <- 3"))
  res <- run_cells(nb, "C", wait = TRUE, timeout = 30)
  expect_false(res$timed_out)
  expect_equal(snap_view(notebook_snapshot(nb), "F")$output$text, "[1] 1")
})
