# Tests for the pure core: R/state.R's `new_state()` and R/step.R's
# `step()`/`schedule()`/the reducers. No process, no IO: `drive()`
# (helper-core.R) folds `step()` over synthetic events and checks
# `check_state()` after each one.
#
# Most fixtures start with an empty cell `S`, kept from when every notebook
# had a setup cell: an empty cell has no edges, so it changes nothing.
#
# Covers engine-tests.md items 21-66 ("Core: editing", "Core: scheduling",
# "Core: interrupt, restart, crashes").

# ---- Editing -------------------------------------------------------------

test_that("open requests sourced files, then the graph picks them up (21)", {
  s <- fake_state(list(S = cell(""), A = cell('source("h.R")')))
  r <- drive(s, ev_open(at(1)))
  reads <- Filter(function(e) identical(e$type, "read_files"), r$effects)
  expect_true(length(reads) > 0)
  expect_true("h.R" %in% reads[[1]]$paths)

  r2 <- drive(r$state, ev_files_read(list("h.R" = list(text = "z <- 1", hash = "abc")), at(2)))
  expect_true("z" %in% r2$state$graph$cells$A$definitions)
})

test_that("an edit rebuilds the graph only (22)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("y <- x", kind = "code")))
  r <- drive(s, ev_apply(list(op_set_code("A", "x <- 2")), at(1)))
  expect_equal(r$state$cells$A$code, "x <- 2")
  expect_true("x" %in% r$state$graph$cells$A$definitions)
  expect_false(any(vapply(r$effects, function(e) identical(e$type, "send"), logical(1))))
  expect_equal(r$state$results, list())
  expect_equal(r$state$pending, character())
})

test_that("editing a cell that ran shows code_differs and keeps the output (23)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  expect_equal(last_sent(r)$cell, "A")
  out <- new_display("text/plain", "1", "[1] 1")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x", output = out), at(10)))

  r2 <- drive(r$state, ev_apply(list(op_set_code("A", "x <- 2")), at(11)))
  v <- snapshot_of(r2$state)$cells$A
  expect_true(v$code_differs)
  expect_equal(v$output, out)
})

test_that("running a cell whose code has a parse error shows only the error, not code_differs", {
  id <- "ca1b0a64-d117-466f-898a-8603bbc24e75"
  cells <- list(S = cell(""))
  cells[[id]] <- cell("x <- 1")
  r <- boot(fake_state(cells), id)
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))

  r <- drive(r$state, ev_apply(list(op_set_code(id, "x <- (.3,.6)")), at(11)))
  expect_true(snapshot_of(r$state)$cells[[id]]$code_differs)

  r <- drive(r$state, ev_run(id, at(12)))
  expect_equal(r$reply$skipped, id)
  v <- snapshot_of(r$state)$cells[[id]]
  expect_false(v$code_differs)
  expect_length(v$errors, 1)
  expect_equal(v$errors[[1]]$kind, "parse")
  expect_equal(v$errors[[1]]$message, "Syntax error: unexpected ','")
  drops <- Filter(function(e) identical(e$type, "send") && identical(e$msg$type, "drop_globals"),
                  r$effects)
  expect_equal(vapply(drops, function(e) e$msg$cell, character(1)), id)
})

test_that("running a cell with a cycle, double definition or mixed text clears code_differs; an unrun edit keeps it", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- 1"),
                       C = cell("c <- 1"), D = cell("d <- 1")))
  r <- boot(s, c("A", "B", "C", "D"))
  for (n in c("a", "b", "c", "d")) {
    r <- drive(r$state, wk_done(1, last_token(r), report(created = n), at(10)))
  }
  r <- drive(r$state, ev_apply(list(op_set_code("A", "a <- b"), op_set_code("B", "b <- a"),
                                    op_set_code("C", "d <- 2"),
                                    op_set_code("D", "#' hi\nd <- 1")), at(20)))
  kinds <- function(v) vapply(v$errors, function(e) e$kind, character(1))
  snap <- snapshot_of(r$state)$cells
  expect_true(all(vapply(snap[c("A", "B", "C", "D")], function(v) v$code_differs, logical(1))))

  r <- drive(r$state, ev_run(c("A", "C", "D"), at(21)))
  snap <- snapshot_of(r$state)$cells
  expect_false(snap$A$code_differs); expect_equal(kinds(snap$A), "cycle")
  expect_false(snap$C$code_differs); expect_equal(kinds(snap$C), "multiple_definitions")
  expect_false(snap$D$code_differs); expect_true("mixed_text" %in% kinds(snap$D))
  expect_true(snap$B$code_differs)
})

test_that("apply is atomic: a bad `expected` refuses the whole batch (24)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("y <- 2"), C = cell("z <- 3")))
  r <- drive(s, ev_apply(list(
    op_set_code("A", "x <- 10"),
    op_set_code("B", "y <- 20", expected = "wrong"),
    op_set_code("C", "z <- 30")
  ), at(1)))
  expect_true(inherits(r$reply, "ember_refused"))
  expect_equal(r$reply$op$cell, "B")
  expect_identical(r$state, at_clock(s, 1))
})

test_that("inserted ids come from the ops, in op order (25)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  n1 <- "11111111-1111-4111-8111-111111111111"
  n2 <- "22222222-2222-4222-8222-222222222222"
  r <- drive(s, ev_apply(list(op_insert(n1, 3, "a <- 1"), op_insert(n2, 4, "b <- 2")), at(1)))
  expect_equal(r$reply$inserted, c(n1, n2))
  expect_equal(names(r$state$cells), c("S", "A", n1, n2))
})

test_that("a non-UUID insert id is refused (review4 item 6)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- drive(s, ev_apply(list(op_insert("not a uuid\n# ///", 3, "a <- 1")), at(1)))
  expect_s3_class(r$reply, "ember_refused")
  expect_equal(names(r$state$cells), c("S", "A"))
})

test_that("deleting the first cell is allowed: no cell is special (26, settings-cells.md)", {
  s <- fake_state(list(S = cell("options(digits = 3)"), A = cell("x <- 1")))
  r <- drive(s, ev_apply(list(op_delete("S")), at(1)))
  expect_false(inherits(r$reply, "ember_refused"))
  expect_equal(names(r$state$cells), "A")
})

test_that("code containing a marker line is refused (27)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- drive(s, ev_apply(list(op_set_code("A", "x <- 1\n# %% id=y")), at(1)))
  expect_true(inherits(r$reply, "ember_refused"))
})

test_that("move and fold change display order and fold, not run order (28)", {
  s <- fake_state(list(A = cell("x <- 1"), B = cell("y <- x")))
  before_order <- s$graph$order
  r <- drive(s, ev_apply(list(op_move("B", 1), op_fold("A", TRUE)), at(1)))
  expect_equal(names(r$state$cells), c("B", "A"))
  expect_true(r$state$cells$A$folded)
  expect_equal(r$state$graph$order, before_order)  # A->B edge still forces A first
})

test_that("deleting a run cell removes its variables and invalidates readers (29)", {
  s <- fake_state(list(A = cell("x <- 1"), B = cell("y <- x")))
  r <- boot(s, NULL)
  expect_equal(last_sent(r)$cell, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  expect_equal(last_sent(r)$cell, "B")
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))
  expect_true(!is.null(r$state$results$A) && !is.null(r$state$results$B))

  r2 <- drive(r$state, ev_apply(list(op_delete("A")), at(12)))
  sends <- Filter(function(e) identical(e$type, "send") && identical(e$msg$type, "remove_cell"),
                  r2$effects)
  expect_equal(sends[[1]]$msg$cell, "A")
  expect_null(r2$state$results$A)
  expect_true(isTRUE(r2$state$results$B$stale))
  expect_false("B" %in% r2$state$pending)
})

test_that("set_code of a run code cell to text folds it, drops the result, emits remove_cell, and marks readers stale (43)", {
  s <- fake_state(list(A = cell("x <- 1"), B = cell("y <- x")))
  r <- boot(s, NULL)
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))
  expect_true(!is.null(r$state$results$A) && !is.null(r$state$results$B))

  r2 <- drive(r$state, ev_apply(list(op_set_code("A", "#' now text", expected = "x <- 1")), at(12)))
  expect_equal(r2$state$cells$A$kind, "markdown")
  expect_true(isTRUE(r2$state$cells$A$folded))
  expect_null(r2$state$results$A)
  sends <- Filter(function(e) identical(e$type, "send") && identical(e$msg$type, "remove_cell"), r2$effects)
  expect_equal(sends[[1]]$msg$cell, "A")
  expect_true(isTRUE(r2$state$results$B$stale))

  r3 <- drive(r2$state, ev_apply(list(op_set_code("A", "x <- 2", expected = "#' now text")), at(13)))
  expect_equal(r3$state$cells$A$kind, "code")
})

test_that("set_code of a disabled cell to text clears disabled (43)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- drive(s, ev_apply(list(op_disable("A")), at(1)))
  expect_true(r$state$cells$A$disabled)

  r2 <- drive(r$state, ev_apply(list(op_set_code("A", "#' now text", expected = "x <- 1")), at(2)))
  expect_equal(r2$state$cells$A$kind, "markdown")
  expect_false(r2$state$cells$A$disabled)
})

test_that("forget_run() marks the currently running cell discard when its own id is edited mid-run (review)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1")))
  r <- boot(s, "A")
  expect_equal(r$state$worker$running$cell, "A")

  r2 <- drive(r$state, ev_apply(list(op_set_code("A", "#' now text", expected = "x <- 1")), at(5)))
  expect_true(isTRUE(r2$state$worker$running$discard))

  r3 <- drive(r2$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  expect_null(r3$state$results$A)
  expect_equal(r3$state$cells$A$kind, "markdown")
  expect_equal(r3$state$worker$status, "ready")
  expect_null(r3$state$graph$learned$definitions$A)
})

test_that("a cell that read a removed name is still invalidated on rerun (30)", {
  s <- fake_state(list(A = cell("x <- 1"), B = cell("y <- x")))
  r <- boot(s, NULL)
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))

  r2 <- drive(r$state, ev_apply(list(op_set_code("A", "z <- 1")), at(12)))
  expect_false("A" %in% r2$state$graph$upstream$B)

  r3 <- drive(r2$state, ev_run("A", at(13)))
  expect_true(isTRUE(r3$state$results$B$stale))
})

test_that("a read-only notebook refuses apply, run and restart (31)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  s$read_only <- TRUE
  r1 <- drive(s, ev_apply(list(op_set_code("A", "x <- 2")), at(1)))
  expect_true(inherits(r1$reply, "ember_refused"))
  r2 <- drive(s, ev_run(NULL, at(1)))
  expect_true(inherits(r2$reply, "ember_refused"))
  r3 <- drive(s, ev_restart(at(1)))
  expect_true(inherits(r3$reply, "ember_refused"))
  expect_identical(r1$state, at_clock(s, 1))
  expect_identical(r2$state, at_clock(s, 1))
})

test_that("a no-op event leaves seq unchanged (32)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- drive(s, wk_done(99, 99, report(), at(1)))  # stale gen/token on an idle state
  expect_equal(r$state$seq, s$seq)
})

# ---- Scheduling ------------------------------------------------------------

test_that("the first run allows execution and starts a worker (33)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- drive(s, ev_run(NULL, at(1)))
  expect_true(r$state$allowed)
  starts <- Filter(function(e) identical(e$type, "start_worker"), r$effects)
  expect_equal(starts[[1]]$gen, 1L)
  expect_null(last_sent(r))
})

test_that("running a cell runs its unrun ancestors first, one per wk_done (34)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a"), C = cell("c <- b")))
  r <- boot(s, "C")
  expect_equal(last_sent(r)$cell, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(10)))
  expect_equal(last_sent(r)$cell, "B")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "b"), at(11)))
  expect_equal(last_sent(r)$cell, "C")
})

test_that("a fresh ancestor is not rerun (35)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a")))
  r <- boot(s, "A")
  expect_equal(last_sent(r)$cell, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(10)))

  r2 <- drive(r$state, ev_run("B", at(11)))
  expect_equal(last_sent(r2)$cell, "B")
})

test_that("an edited ancestor is rerun before the cell (36)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(10)))

  r <- drive(r$state, ev_apply(list(op_set_code("A", "a <- 2")), at(11)))
  r2 <- drive(r$state, ev_run("B", at(12)))
  expect_equal(last_sent(r2)$cell, "A")
})

test_that("autorun reruns dependents that had run; never-run cells stay not run (37)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a"), C = cell("c <- 1")))
  r <- boot(s, c("A", "B"))
  expect_equal(last_sent(r)$cell, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(10)))
  expect_equal(last_sent(r)$cell, "B")
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))
  expect_equal(snapshot_of(r$state)$cells$C$status, "not_run")

  r2 <- drive(r$state, ev_run("A", at(12)))
  expect_equal(last_sent(r2)$cell, "A")
  r3 <- drive(r2$state, wk_done(1, last_token(r2), report(created = "a"), at(13)))
  expect_equal(last_sent(r3)$cell, "B")
  expect_equal(snapshot_of(r3$state)$cells$C$status, "not_run")
})

test_that("lazy marks dependents stale instead of queuing them (38)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a")), on_cell_change = "lazy")
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))

  r2 <- drive(r$state, ev_run("A", at(12)))
  r2 <- drive(r2$state, wk_done(1, last_token(r2), report(created = "a"), at(13)))
  expect_true(isTRUE(r2$state$results$B$stale))
  expect_false("B" %in% r2$state$pending)
})

test_that("running a stale cell clears its stale flag (39)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a")), on_cell_change = "lazy")
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))
  r <- drive(r$state, ev_run("A", at(12)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(13)))
  expect_true(isTRUE(r$state$results$B$stale))

  r2 <- drive(r$state, ev_run("B", at(14)))
  r2 <- drive(r2$state, wk_done(1, last_token(r2), report(), at(15)))
  expect_false(isTRUE(r2$state$results$B$stale))
})

test_that("a graph error blocks only the cell itself, not its dependents (ui-3 7a)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), A2 = cell("z <- 9"),
                       C = cell("y <- x"), F = cell("2")))
  r0 <- drive(s, ev_apply(list(op_set_code("A2", "x <- 2")), at(1)))
  expect_equal(r0$effects, list())
  expect_equal(r0$state$pending, character())

  r1 <- drive(r0$state, ev_run(NULL, at(2)))
  expect_setequal(r1$reply$skipped, c("A", "A2"))

  r2 <- drive(r1$state, wk_started(1, 99, at(3)), wk_hello(1, list(), at(4)))
  expect_equal(last_sent(r2)$cell, "S")   # run all: the empty first cell is first in the order
  r3 <- drive(r2$state, wk_done(1, last_token(r2), report(), at(5)))
  expect_equal(last_sent(r3)$cell, "C")   # A and A2 are blocked; C is not
})

test_that("drop_graph_error_results clears a stale graph-error cell before the next run (ui-3 7b)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), A2 = cell("z <- 9"),
                       E = cell("x + 1"), F = cell("2")))
  r <- boot(s, c("A", "E"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))
  expect_equal(r$state$results$A$status, "ok")
  expect_equal(r$state$results$E$status, "ok")

  r2 <- drive(r$state, ev_apply(list(op_set_code("A2", "x <- 2")), at(20)))
  expect_equal(r2$effects, list())
  expect_equal(r2$state$pending, character())
  expect_equal(r2$state$results$A$status, "ok")   # an edit alone changes nothing in the worker

  r3 <- drive(r2$state, ev_run("F", at(21)))
  sends <- Filter(function(e) identical(e$type, "send"), r3$effects)
  expect_equal(sends[[1]]$msg, list(type = "drop_globals", cell = "A"))   # before F's run
  expect_equal(sends[[length(sends)]]$msg$cell, "F")
  expect_null(r3$state$results$A)
  expect_true(isTRUE(r3$state$results$E$stale))
  expect_equal(r3$state$pending, character())   # E stays stale, not queued (autorun too)

  r4 <- drive(r3$state, wk_done(1, last_token(r3), report(), at(22)))
  r5 <- drive(r4$state, ev_run("E", at(23)))
  expect_false(any(vapply(r5$effects, function(e) {
    identical(e$type, "send") && identical(e$msg$type, "drop_globals")
  }, logical(1))))
})

test_that("two definers of the same name give one upstream entry, the first in display order (ui-3 7c, fix 2)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), A2 = cell("x <- 2"), C = cell("x + 1")))
  r <- boot(s, "C")
  expect_true(all(c("A", "A2") %in% blocked_cells(r$state$graph)))
  tok <- last_token(r)
  r2 <- drive(r$state, wk_done(1, tok, report(status = "error", error = list(message = "object 'x' not found")), at(10)))
  err <- r2$state$results$C$error
  expect_equal(err$kind, "upstream")
  expect_equal(err$names, "x")
  expect_equal(err$cells, "A")
})

test_that("an error lets a dependent run on its own instead of dropping it from pending (ui-3 9)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a")))
  r <- boot(s, "B")
  expect_equal(last_sent(r)$cell, "A")
  expect_true("B" %in% r$state$pending)

  r2 <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "boom")), at(10)))
  expect_equal(last_sent(r2)$cell, "B")
  expect_false("B" %in% r2$state$pending)
  r3 <- drive(r2$state, wk_done(1, last_token(r2), report(), at(11)))
  expect_equal(r3$state$results$B$status, "ok")
})

test_that("a dependent with no result stays not run after an ancestor errors (ui-3 9)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "boom")), at(10)))
  expect_equal(snapshot_of(r$state)$cells$B$status, "not_run")
  expect_false("B" %in% r$state$pending)
  expect_false("B" %in% sent_cells(r))
})

test_that("run_order follows the current graph, not display order alone (42)", {
  s <- fake_state(list(S = cell(""), C = cell(""), B = cell("")))
  expect_equal(run_order(s$graph, c("C", "B")), c("C", "B"))

  r <- drive(s, ev_apply(list(op_set_code("C", "z <- b"), op_set_code("B", "b <- 1")), at(1)))
  expect_equal(run_order(r$state$graph, c("C", "B")), c("B", "C"))
})

test_that("asking for the running cell again queues it once more (43)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  expect_equal(r$state$worker$running$cell, "A")

  r2 <- drive(r$state, ev_run("A", at(10)))
  expect_true("A" %in% r2$state$pending)
})

test_that("a learned definition adds an edge and runs its new reader (44)", {
  s <- fake_state(list(S = cell(""), A = cell("load('x.rds')"), B = cell("print(fits)")))
  r <- boot(s, c("A", "B"))
  expect_equal(last_sent(r)$cell, "A")

  r2 <- drive(r$state, wk_done(1, last_token(r), report(created = "fits"), at(10)))
  expect_true("A" %in% r2$state$graph$upstream$B)
  expect_equal(last_sent(r2)$cell, "B")
})

test_that("a learned name owned elsewhere blocks both cells (45)", {
  s <- fake_state(list(S = cell(""), A = cell("load('x.rds')"), B = cell("y <- 1")))
  r <- boot(s, "A")
  r2 <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(10)))
  errs <- cell_errors(r2$state$graph, "A")
  expect_true(any(vapply(errs, function(e) identical(e$kind, "multiple_definitions"), logical(1))))
  expect_true(all(c("A", "B") %in% blocked_cells(r2$state$graph)))
})

test_that("changing a foreign global is a multiple_definitions run error (46)", {
  # Written through eval() so static reading can't see it as a replacement
  # of `df` (that would make it a graph-level error before the cell ever
  # runs); the worker discovers the change at run time instead.
  s <- fake_state(list(S = cell(""), B = cell("df <- 1"),
                       A = cell("eval(parse(text = \"df$x <- 2\"))")))
  r <- boot(s, "A")
  r2 <- drive(r$state, wk_done(1, last_token(r), report(changed = "df"), at(10)))
  err <- r2$state$results$A$error
  expect_equal(err$kind, "multiple_definitions")
  expect_true(length(err$fixes) > 0)
  # ui-3 8: the server's own run errors drop the failed cell's globals too.
  expect_true(any(vapply(r2$effects, function(e) {
    identical(e$type, "send") && identical(e$msg$type, "drop_globals") && identical(e$msg$cell, "A")
  }, logical(1))))
})

test_that("a setting found at run time makes a settings cell, not an error (47, settings-cells.md)", {
  # Written so static reading can't see it; this exercises the learned
  # settings built from the worker's report.
  s <- fake_state(list(S = cell(""), B = cell("y <- 2"),
                       A = cell("eval(parse(text = \"options(digits = 3)\"))")))
  settings <- list(list(kind = "option", name = "digits", before = 7, after = 3))

  r <- boot(s, c("B", "A"))
  expect_equal(last_sent(r)$cell, "B")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(10)))
  expect_equal(last_sent(r)$cell, "A")
  r2 <- drive(r$state, wk_done(1, last_token(r), report(settings = settings), at(11)))
  expect_null(r2$state$results$A$error)
  expect_equal(r2$state$results$A$status, "ok")
  expect_equal(r2$state$graph$learned$settings, list(A = "option:digits"))
  expect_equal(r2$state$graph$settings, "A")
  expect_equal(r2$state$results$A$settings_found, "digits")
  expect_equal(snapshot_of(r2$state)$cells$A$settings, list(list(name = "digits", found = "run")))
  # B now comes after A and depends on it: stale, and (autorun) rerun.
  expect_equal(r2$state$graph$order[r2$state$graph$order != "S"], c("A", "B"))
  expect_true(r2$state$results$B$stale)
  expect_equal(last_sent(r2)$cell, "B")
  expect_equal(last_sent(r2)$settings, "A")

  # A second run that changes nothing keeps the learned setting.
  r3 <- drive(r2$state, wk_done(1, last_token(r2), report(created = "y"), at(12)),
              ev_run("A", at(13)))
  r3 <- drive(r3$state, wk_done(1, last_token(r3), report(), at(14)))
  expect_equal(r3$state$graph$learned$settings, list(A = "option:digits"))
  expect_equal(r3$state$results$A$settings_found, character())

  # Editing the cell drops it.
  r4 <- drive(r3$state, ev_apply(list(op_set_code("A", "1")), at(15)))
  expect_length(r4$state$graph$learned$settings, 0)
  expect_equal(r4$state$graph$settings, character())
})

test_that("a computed options(op) cell is already a settings cell: no run-time note (review)", {
  s <- fake_state(list(A = cell("options(op)"), B = cell("x <- 1")))
  expect_equal(s$graph$settings, "A")
  r <- boot(s, "A")
  digits <- list(list(kind = "option", name = "digits", before = 7, after = 3))
  r <- drive(r$state, wk_done(1, last_token(r), report(settings = digits), at(10)))
  expect_equal(r$state$results$A$settings_found, character())
  expect_equal(r$state$graph$learned$settings, list(A = "option:digits"))
})

test_that("two cells found at run time to set one option get setting_conflict", {
  s <- fake_state(list(A = cell("f()"), B = cell("g()")))
  digits <- list(list(kind = "option", name = "digits", before = 7, after = 3))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(settings = digits), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(settings = digits), at(11)))
  err <- Filter(function(e) e$kind == "setting_conflict", r$state$graph$errors)
  expect_length(err, 1)
  expect_setequal(err[[1]]$cells, c("A", "B"))
})

test_that("the run message has role cell and the settings cells in effect before the cell (48)", {
  s <- fake_state(list(S1 = cell("options(digits = 3)"), S2 = cell("Sys.setenv(TZ = 'UTC')"),
                       D = cell("n <- 1"), S3 = cell("options(scipen = n)"),
                       S4 = cell("options(width = 60)"), A = cell("x <- 1")))
  r <- drive(s, ev_apply(list(op_disable("S4")), at(0)))
  r <- boot(r$state, "A")
  expect_equal(last_sent(r)$cell, "S1")
  expect_equal(last_sent(r)$role, "cell")
  expect_equal(last_sent(r)$settings, character())
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(10)))
  expect_equal(last_sent(r)$cell, "S2")
  expect_equal(last_sent(r)$settings, "S1")
  # S2 fails: it is no longer in effect for the cells after it.
  r <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "no")), at(11)))
  expect_equal(last_sent(r)$cell, "D")
  expect_equal(last_sent(r)$settings, "S1")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "n"), at(12)))
  expect_equal(last_sent(r)$cell, "S3")
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(13)))
  expect_equal(last_sent(r)$cell, "A")
  # S4 is disabled, S2 failed: neither is in effect.
  expect_equal(last_sent(r)$settings, c("S1", "S3"))
})

test_that("disabling or deleting a settings cell marks the cells after it stale", {
  s <- fake_state(list(S = cell("options(digits = 3)"), A = cell("x <- 1")), on_cell_change = "lazy")
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(11)))
  expect_false(r$state$results$A$stale)
  r2 <- drive(r$state, ev_apply(list(op_disable("S")), at(12)))
  expect_false(inherits(r2$reply, "ember_refused"))
  expect_true(r2$state$results$A$stale)
  expect_equal(r2$state$pending, character())
  r3 <- drive(r$state, ev_apply(list(op_delete("S")), at(12)))
  expect_true(r3$state$results$A$stale)
})

test_that("editing the setting out of a settings cell marks later cells stale, and running it queues them in autorun (review)", {
  for (mode in c("lazy", "autorun")) {
    s <- fake_state(list(S = cell("options(digits = 3); y <- 1"), A = cell("x <- 1")), on_cell_change = mode)
    r <- boot(s, "A")
    r <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(10)))
    r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(11)))
    expect_false(r$state$results$A$stale)
    expect_true(r$state$results$S$setting)

    # The edit alone: A was computed under S's digits, which no cell sets now.
    r2 <- drive(r$state, ev_apply(list(op_set_code("S", "y <- 1")), at(12)))
    expect_equal(r2$state$graph$settings, character())
    expect_true(r2$state$results$A$stale, info = mode)
    expect_equal(r2$state$pending, character())

    # Running S: the last run was as a settings cell, so A counts as its
    # dependent though no setting edge is left.
    r3 <- drive(r2$state, ev_run("S", at(13)))
    expect_equal(last_sent(r3)$cell, "S")
    r3 <- drive(r3$state, wk_done(1, last_token(r3), report(created = "y"), at(14)))
    expect_true(r3$state$results$A$stale, info = mode)
    if (mode == "autorun") expect_equal(last_sent(r3)$cell, "A") else expect_equal(r3$state$pending, character())
    expect_false(r3$state$results$S$setting)
  }
})

test_that("a settings cell newly blocked by a setting_conflict marks later cells stale (review)", {
  s <- fake_state(list(S = cell("options(digits = 3)"), A = cell("x <- 1"), B = cell("y <- 2")),
                  on_cell_change = "lazy")
  r <- boot(s, "B")
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(11)))
  r <- drive(r$state, ev_run("A", at(12)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(13)))
  expect_false(r$state$results$B$stale)
  r2 <- drive(r$state, ev_apply(list(op_set_code("A", "options(digits = 4)")), at(14)))
  expect_true("S" %in% blocked_cells(r2$state$graph))
  expect_true(r2$state$results$B$stale)
})

test_that("lazy mode: running a settings cell marks later cells stale and queues nothing", {
  s <- fake_state(list(S = cell("options(digits = 3)"), A = cell("x <- 1")), on_cell_change = "lazy")
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(11)))
  r <- drive(r$state, ev_run("S", at(12)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(13)))
  expect_true(r$state$results$A$stale)
  expect_equal(r$state$pending, character())
})

test_that("attached exports from a report add a package edge (49)", {
  s <- fake_state(list(S = cell(""), A = cell("library(dplyr)"), B = cell("mutate(df)")))
  # Step 3's waiting rule (packages-core.R) holds a cell naming a package
  # that isn't installed; marking dplyr already installed in the (empty,
  # test-only) active library keeps this test about the exports edge, not
  # about resolving or installing dplyr.
  s$packages$active$installed <- c(dplyr = "1.0.0")
  expect_false("A" %in% s$graph$upstream$B)
  r <- boot(s, "A")
  r2 <- drive(r$state, wk_done(1, last_token(r), report(attached = list(dplyr = "mutate")), at(10)))
  expect_true("A" %in% r2$state$graph$upstream$B)
})

test_that("formula_misses become learned references and an edge (50)", {
  # A bare term in a formula with `data` is read as a column by default (no
  # edge to whatever defines `x` globally); formula_misses retracts that
  # once the worker finds `x` isn't actually a column of `df`.
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("lm(y ~ x, data = df)")))
  expect_false("A" %in% s$graph$upstream$B)
  r <- boot(s, "B")  # the report comes from running B, the cell with the formula
  expect_equal(last_sent(r)$cell, "B")
  r2 <- drive(r$state, wk_done(1, last_token(r), report(created = character(), formula_misses = "x"), at(10)))
  expect_equal(r2$state$graph$learned$references$B, "x")
  expect_true("A" %in% r2$state$graph$upstream$B)
})

test_that("an allowed computed source() learns its definitions (51)", {
  s <- fake_state(list(S = cell(""), A = cell("source(file.path('.', 'h.R'))")))
  r <- boot(s, "A")
  r2 <- drive(r$state, wk_source(1, last_token(r), "h.R", "z <- 1", at(10)))
  reply_msg <- last_sent(r2)
  expect_true(reply_msg$allow)
  expect_true("z" %in% r2$state$graph$cells$A$definitions)
})

test_that("a conflicting computed source() is refused, naming the clashing name but no cell id (52)", {
  s <- fake_state(list(S = cell(""), B = cell("z <- 1"), A = cell("source(file.path('.', 'h.R'))")))
  r <- boot(s, "A")
  r2 <- drive(r$state, wk_source(1, last_token(r), "h.R", "z <- 2", at(10)))
  reply_msg <- last_sent(r2)
  expect_false(reply_msg$allow)
  expect_match(reply_msg$message, "z")
  expect_no_match(reply_msg$message, "B")
})

test_that("a sourced file's change invalidates the sourcing cell (53)", {
  s <- fake_state(list(S = cell(""), A = cell('source("h.R")')))
  r <- boot(s, "A")
  tok <- r$state$worker$running$token  # `ev_files_read` sends nothing, so last_token() would miss this
  r <- drive(r$state, ev_files_read(list("h.R" = list(text = "z <- 1", hash = "v1")), at(10)))
  r <- drive(r$state, wk_done(1, tok, report(created = "z"), at(11)))
  expect_true(!is.null(r$state$results$A))

  r2 <- drive(r$state, ev_files_read(list("h.R" = list(text = "z <- 2", hash = "v2")), at(12)))
  expect_true(isTRUE(r2$state$results$A$stale) || "A" %in% r2$state$pending)
})

test_that("every run message carries the current code-cell run order (54)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), M = cell("#' doc", kind = "markdown"),
                       B = cell("y <- x")))
  r <- boot(s, "A")
  msg <- last_sent(r)
  expect_equal(msg$cell, "A")
  expect_false("M" %in% msg$order)
  expect_true(all(c("S", "A", "B") %in% msg$order))
})

# ---- Inline values: autorun, lazy, run_cells() (44, 45) --------------------

test_that("autorun: after A runs, a text cell reading x is queued with role text (44)", {
  # T has never run yet, so it must be requested alongside A the first time
  # (invalidate_dependents() only re-queues a cell that already has a
  # result -- the same rule a brand-new code cell follows); a *second* run
  # of A, below, is what shows T being re-queued on its own.
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), T = cell("#' `r x / 2`", kind = "markdown")))
  r <- boot(s, c("A", "T"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  # schedule() both queues and sends T within this one dispatch, so by now
  # it's already the running cell, not merely pending.
  expect_equal(r$state$worker$running$cell, "T")
  msg <- last_sent(r)
  expect_equal(msg$cell, "T")
  expect_equal(msg$role, "text")
  expect_equal(msg$code, "x / 2")

  out <- new_display("application/vnd.ember.inline", list(values = "0.5"), "0.5")
  r <- drive(r$state, wk_done(1, last_token(r), report(output = out), at(11)))

  r2 <- drive(r$state, ev_apply(list(op_set_code("A", "x <- 2", expected = "x <- 1")), at(12)))
  r2 <- drive(r2$state, ev_run("A", at(13)))
  expect_true("T" %in% r2$state$pending)
})

test_that("in lazy mode, a dependent text cell goes stale and isn't queued when its ancestor reruns", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), T = cell("#' `r x / 2`", kind = "markdown")),
                  on_cell_change = "lazy")
  r <- boot(s, c("A", "T"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  out <- new_display("application/vnd.ember.inline", list(values = "0.5"), "0.5")
  r <- drive(r$state, wk_done(1, last_token(r), report(output = out), at(11)))

  r2 <- drive(r$state, ev_apply(list(op_set_code("A", "x <- 2", expected = "x <- 1")), at(12)))
  r3 <- drive(r2$state, ev_run("A", at(13)))
  expect_false("T" %in% r3$state$pending)
  expect_true(isTRUE(r3$state$results[["T"]]$stale))
})

test_that("reduce_run(): a text cell without inline values is skipped, not queued (45)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), MD = cell("#' just text", kind = "markdown")))
  r <- drive(s, ev_run("MD", at(1)))
  expect_false("MD" %in% r$state$pending)
  expect_true("MD" %in% r$reply$skipped)
})

test_that("reduce_wk_done(): a text cell's error gets line/call from the failed span (46)", {
  s <- fake_state(list(S = cell(""), E = cell("#' `r max(carz$wt)`", kind = "markdown")))
  r <- boot(s, "E")
  r <- drive(r$state, wk_done(1, last_token(r),
    report(status = "error", error = list(message = "object 'carz' not found", span = 1L)), at(10)))
  err <- r$state$results[["E"]]$error
  expect_equal(err$kind, "error")
  expect_equal(err$line, 1L)
  expect_equal(err$call, "`r max(carz$wt)`")
})

test_that("reduce_wk_done(): a span maps onto the code that ran, not an edit made meanwhile (review)", {
  s <- fake_state(list(S = cell(""), E = cell("#' `r a` `r stop('x')`", kind = "markdown")))
  r <- boot(s, "E")
  r2 <- drive(r$state, ev_apply(list(op_set_code(
    "E", "#' `r q` and `r b`\n#' `r a` `r stop('x')`",
    expected = "#' `r a` `r stop('x')`")), at(5)))
  r3 <- drive(r2$state, wk_done(1, last_token(r),
    report(status = "error", error = list(message = "x", span = 2L)), at(10)))
  err <- r3$state$results[["E"]]$error
  expect_equal(err$line, 1L)
  expect_equal(err$call, "`r stop('x')`")
})

test_that("a wk_done with a stale token or generation is ignored (55)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  before <- r$state
  r2 <- drive(r$state, wk_done(1, last_token(r) + 100L, report(created = "x"), at(10)))
  expect_identical(r2$state, at_clock(before, 10))
  r3 <- drive(r$state, wk_done(99, last_token(r), report(created = "x"), at(10)))
  expect_identical(r3$state, at_clock(before, 10))
})

# ---- Interrupt, restart, crashes -------------------------------------------

test_that("interrupt sends SIGINT, sets a timer, and clears the queue (56)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("y <- 2")))
  r <- boot(s, c("A", "B"))
  expect_true(length(r$state$pending) > 0 || !is.null(r$state$worker$running))

  r2 <- drive(r$state, ev_interrupt(at(10)))
  expect_equal(r2$state$pending, character())
  expect_true(any(vapply(r2$effects, function(e) identical(e$type, "interrupt"), logical(1))))
  expect_true(any(vapply(r2$effects, function(e) identical(e$type, "timer"), logical(1))))
})

test_that("the grace period offers a restart for the running token (57)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  tok <- r$state$worker$running$token
  r2 <- drive(r$state, ev_interrupt(at(10)))
  r3 <- drive(r2$state, tm_offer_restart(1, tok, at(11)))
  expect_true(r3$state$worker$restart_offered)
})

test_that("a late interrupt result withdraws the restart offer (58)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  tok <- r$state$worker$running$token
  r2 <- drive(r$state, ev_interrupt(at(10)))
  r3 <- drive(r2$state, tm_offer_restart(1, tok, at(11)))
  expect_true(r3$state$worker$restart_offered)

  r4 <- drive(r3$state, wk_done(1, tok, report(status = "interrupted"), at(12)))
  expect_false(r4$state$worker$restart_offered)
})

test_that("a stale restart-offer timer does nothing (59)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  tok <- r$state$worker$running$token
  r2 <- drive(r$state, wk_done(1, tok, report(), at(10)))  # finished before the timer fires
  r3 <- drive(r2$state, tm_offer_restart(1, tok, at(11)))
  expect_identical(r3$state, at_clock(r2$state, 11))
})

test_that("restart leaves every cell not run (60)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  expect_true(!is.null(r$state$results$A))

  r2 <- drive(r$state, ev_restart(at(11)))
  expect_equal(r2$state$results, list())
  expect_equal(r2$state$pending, character())
  expect_equal(r2$state$worker$gen, 2L)
  kill_i <- Position(function(e) identical(e$type, "kill_worker"), r2$effects)
  start_i <- Position(function(e) identical(e$type, "start_worker"), r2$effects)
  expect_true(kill_i < start_i)
})

test_that("restart is refused in safe preview (61)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- drive(s, ev_restart(at(1)))
  expect_true(inherits(r$reply, "ember_refused"))
})

test_that("events from a generation before a restart are ignored (62)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  r2 <- drive(r$state, ev_restart(at(11)))
  before <- r2$state
  r3 <- drive(r2$state, wk_done(1, 1L, report(created = "x"), at(12)))
  expect_identical(r3$state, at_clock(before, 12))
  r4 <- drive(r2$state, wk_exited(1, 1L, "killed", at(12)))
  expect_identical(r4$state, at_clock(before, 12))
})

test_that("the worker exiting while running fails that cell and clears others (63)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("y <- 2")))
  r <- boot(s, c("A", "B"))
  expect_true(!is.null(r$state$worker$running))
  running_cell <- r$state$worker$running$cell

  r2 <- drive(r$state, wk_exited(1, 139L, "segfault", at(10)))
  expect_equal(r2$state$results[[running_cell]]$error$kind, "worker_exited")
  expect_equal(length(r2$state$results), 1)
  expect_equal(r2$state$worker$status, "stopped")
})

test_that("a crash doesn't start a new worker until the next run (64)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  r2 <- drive(r$state, wk_exited(1, 139L, "segfault", at(10)))
  expect_equal(r2$state$worker$status, "stopped")
  r3 <- drive(r2$state, ev_allow(at(11)))  # already allowed; shouldn't restart on its own
  expect_equal(r3$state$worker$status, "stopped")
})

test_that("a worker that fails to start clears the queue (65)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- drive(s, ev_run("A", at(1)))
  r2 <- drive(r$state, wk_failed(1, "no Rscript found", at(2)))
  expect_equal(r2$state$worker$status, "stopped")
  expect_equal(r2$state$pending, character())
  expect_equal(snapshot_of(r2$state)$worker_message, "no Rscript found")
})

test_that("shutdown kills the worker and closes; later events are no-ops (66)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- drive(s, ev_shutdown(at(1)))
  expect_true(r$reply)  # was in preview
  expect_true(r$state$closed)
  close_i <- any(vapply(r$effects, function(e) identical(e$type, "close"), logical(1)))
  expect_true(close_i)

  r2 <- drive(r$state, ev_run("A", at(2)))
  expect_identical(r2$state, r$state)
})

# ---- Review fixes -----------------------------------------------------------
#
# Regressions found in review: a performance fix (unfresh ancestors), two
# design-decision fixes (errored ancestors block dependents; an edit, even a
# delete, never runs anything), a crash fix (a cell deleted while running),
# a computed-`source()` footer fix, a learned-definitions fix, an insert-op
# validation gap, and several lower-severity reducer fixes.

test_that("running all of a 2000-cell chain grows about linearly, not with the square (item 4)", {
  # Before the fix, `reduce_run()` called `unfresh_ancestors()` (a full
  # `upstream(..., transitive = TRUE)` walk) once per requested id, making
  # "run all" quadratic: 0.58s at 500 cells, 22s at 2000 (38x for 4x the
  # cells). `upstream_of_set()` does one walk for the whole requested set
  # instead: about 6.5x here. Timed against the 500-cell chain rather than
  # a fixed budget (helper-perf.R).
  big <- fake_state(make_chain_cells(2000))
  small <- fake_state(make_chain_cells(500))
  r <- time_ratio(function() step(big, ev_run(NULL, at(1))), function() step(small, ev_run(NULL, at(1))),
                  samples = 3L, inner_b = 4L)
  cat(sprintf("\n[timing] ev_run(NULL): 2000-cell chain %.2f s, 500-cell chain %.3f s (%.1fx)\n",
              r$a, r$b, r$ratio))
  expect_lt(r$ratio, 16)
  # Backstop: about 0.25 s on a cloud container.
  expect_lt(r$a, 5)
  expect_equal(length(step(big, ev_run(NULL, at(1)))$reply$skipped), 0)
})

test_that("requesting a dependent re-queues its failed ancestor; it runs once the ancestor fails again (ui-3 3)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "boom")), at(10)))
  expect_equal(r$state$results$A$status, "error")

  r2 <- drive(r$state, ev_run("B", at(11)))
  expect_equal(r2$reply$skipped, character())
  expect_equal(r2$reply$queued, c("A", "B"))

  r3 <- drive(r2$state, wk_done(1, last_token(r2), report(status = "error", error = list(message = "boom")), at(12)))
  expect_equal(last_sent(r3)$cell, "B")
})

test_that("a dependent's own R error becomes kind upstream, naming the failed ancestor (ui-3 4a)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("a + 1")))
  r <- boot(s, c("A", "B"))
  r1 <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "boom")), at(10)))
  expect_equal(last_sent(r1)$cell, "B")   # the dependent runs on its own right after

  r2 <- drive(r1$state, wk_done(1, last_token(r1),
                                report(status = "error", error = list(message = "object 'a' not found")), at(11)))
  err <- r2$state$results$B$error
  expect_equal(err$kind, "upstream")
  expect_equal(err$names, "a")
  expect_equal(err$cells, "A")
  expect_equal(err$message, "object 'a' not found")
})

test_that("an error's kind stays plain when the referenced ancestor is ok (ui-3 4b)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("a + 1")))
  r <- boot(s, c("A", "B"))
  r1 <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(10)))
  expect_equal(last_sent(r1)$cell, "B")

  r2 <- drive(r1$state, wk_done(1, last_token(r1), report(status = "error", error = list(message = "boom")), at(11)))
  expect_equal(r2$state$results$B$error$kind, "error")
})

test_that("a dependent's own missing_package or source_conflict kind is not rewritten to upstream (ui-3 4c)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("a + 1")))
  r <- boot(s, c("A", "B"))
  r1 <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "boom")), at(10)))
  expect_equal(last_sent(r1)$cell, "B")

  r2 <- drive(r1$state, wk_done(1, last_token(r1),
                                report(error = list(message = "irrelevant", package = "brokenpkg")), at(11)))
  err <- r2$state$results$B$error
  expect_equal(err$kind, "missing_package")
  expect_equal(err$names, "brokenpkg")
})

test_that("only a setting edge between two cells never gives an upstream error (ui-3 4d)", {
  s <- fake_state(list(S = cell("options(digits = 3); stop('setup boom')"), A = cell("1")))
  r <- drive(s, ev_run("A", at(1)), wk_started(1, 99, at(2)), wk_hello(1, list(), at(3)))
  expect_equal(last_sent(r)$cell, "S")

  r1 <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "setup boom")), at(4)))
  expect_equal(last_sent(r1)$cell, "A")   # A's only edge to S is a setting edge
  r2 <- drive(r1$state, wk_done(1, last_token(r1), report(status = "error", error = list(message = "A boom")), at(5)))
  expect_equal(r2$state$results$A$error$kind, "error")
})

test_that("a dependent's own source_conflict kind is not rewritten to upstream (ui-3 4g)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), Z = cell("z <- 1"),
                       DEP = cell("source('h.R'); a + 1")))
  r <- boot(s, c("A", "DEP"))
  r1 <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "boom")), at(10)))
  expect_equal(last_sent(r1)$cell, "DEP")
  tok <- r1$state$worker$running$token
  r1b <- drive(r1$state, wk_source(1, tok, "h.R", "z <- 2", at(10.5)))
  refused_msg <- last_sent(r1b)$message

  r2 <- drive(r1b$state, wk_done(1, tok, report(error = list(message = refused_msg)), at(11)))
  expect_equal(r2$state$results$DEP$error$kind, "source_conflict")
})

test_that("a package edge doesn't give upstream once the provider has attached (ui-3 4e, fix 1)", {
  s <- fake_state(list(S = cell(""), A = cell('library(pkgx); stop("late")'), B = cell("qux(1, 2, 3)")))
  s$packages$active$installed <- c(pkgx = "1.0.0")
  r <- boot(s, c("A", "B"))
  r1 <- drive(r$state, wk_done(1, last_token(r),
                               report(status = "error", error = list(message = "late"),
                                      attached = list(pkgx = "qux")), at(10)))
  expect_true("A" %in% r1$state$graph$upstream$B)
  expect_equal(last_sent(r1)$cell, "B")   # the dependent runs on its own

  r2 <- drive(r1$state, wk_done(1, last_token(r1),
                                report(status = "error", error = list(message = "unused arguments")), at(11)))
  # A's attachment survived its failure (drop_globals keeps attachments), so
  # B's own unrelated error is not rewritten to "upstream".
  expect_equal(r2$state$results$B$error$kind, "error")
})

test_that("a package edge gives upstream when the provider's last failure is missing_package (ui-3 4f, fix 1)", {
  s <- fake_state(list(S = cell(""), A = cell("library(pkgx)"), B = cell("qux(1)")))
  s$packages$active$installed <- c(pkgx = "1.0.0")
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(attached = list(pkgx = "qux")), at(10)))
  expect_true("A" %in% r$state$graph$upstream$B)
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))
  expect_equal(r$state$results$B$status, "ok")

  r2 <- drive(r$state, ev_run("A", at(20)))
  r2 <- drive(r2$state, wk_done(1, last_token(r2), report(error = list(message = "irrelevant", package = "pkgx")), at(21)))
  expect_equal(r2$state$results$A$error$kind, "missing_package")
  expect_equal(last_sent(r2)$cell, "B")

  r3 <- drive(r2$state, wk_done(1, last_token(r2),
                                report(status = "error", error = list(message = "object 'qux' not found")), at(22)))
  err <- r3$state$results$B$error
  expect_equal(err$kind, "upstream")
  expect_equal(err$names, "qux")
  expect_equal(err$cells, "A")
})

test_that("a chain of upstream errors links one step at a time (ui-3 5)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a"), C = cell("c <- b")))
  r <- boot(s, c("A", "B", "C"))
  r1 <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "boom")), at(10)))
  expect_equal(last_sent(r1)$cell, "B")

  r2 <- drive(r1$state, wk_done(1, last_token(r1),
                                report(status = "error", error = list(message = "object 'a' not found")), at(11)))
  err_b <- r2$state$results$B$error
  expect_equal(err_b$kind, "upstream")
  expect_equal(err_b$names, "a")
  expect_equal(err_b$cells, "A")
  expect_equal(last_sent(r2)$cell, "C")

  r3 <- drive(r2$state, wk_done(1, last_token(r2),
                                report(status = "error", error = list(message = "object 'b' not found")), at(12)))
  err_c <- r3$state$results$C$error
  expect_equal(err_c$kind, "upstream")
  expect_equal(err_c$names, "b")
  expect_equal(err_c$cells, "B")
})

test_that("a dependent reruns and fails on its own once its failed ancestor stays failed (item 6, ui-3)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- 2"), C = cell("cc <- a + b")))
  r <- boot(s, "C")
  for (val in c("a", "b", "cc")) {
    r <- drive(r$state, wk_done(1, last_token(r), report(created = val), at(10)))
  }
  expect_equal(snapshot_of(r$state)$cells$C$status, "ok")

  r <- drive(r$state, ev_apply(list(op_set_code("B", "b <- stop('boom')")), at(20)), ev_run("B", at(21)))
  r <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "boom")), at(22)))
  expect_equal(r$state$results$B$status, "error")

  # C had a result and is a dependent of B: autorun reruns it on its own.
  expect_equal(last_sent(r)$cell, "C")
  r2 <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "boom")), at(23)))
  expect_equal(r2$state$results$C$status, "error")

  r3 <- drive(r2$state, ev_run("A", at(30)))
  r3 <- drive(r3$state, wk_done(1, last_token(r3), report(created = "a"), at(31)))
  expect_null(r3$state$results$A$error)
})

test_that("wk_done for a cell deleted while running is dropped, not crashed (item 8)", {
  s <- fake_state(list(S = cell(""), A = cell("load('x.rda')"), B = cell("1")))
  r <- boot(s, "A")
  tok <- r$state$worker$running$token
  st <- step(r$state, ev_apply(list(op_delete("A")), at(20)))$state
  expect_null(st$results$A)

  res <- step(st, wk_done(1, tok, report(created = "fits"), at(21)))
  expect_null(res$state$results$A)
  expect_equal(res$state$worker$status, "ready")
  expect_null(res$state$worker$running)
  expect_false("A" %in% names(res$state$graph$learned$definitions))
  check_state(res$state)
})

test_that("a literal source()'s own wk_source isn't recorded again as a computed path (item 9)", {
  s <- fake_state(list(S = cell(""), A = cell('source("h.R")')))
  s$path <- "/proj/nb.R"
  r <- drive(s, ev_files_read(list("h.R" = list(text = "f <- function() 1", hash = "md5:aaa")), at(1)))
  r <- boot(r$state, "A", at0 = 2)
  tok <- r$state$worker$running$token
  r <- drive(r$state, wk_source(1, tok, "/proj/h.R", "f <- function() 1", at(11)))
  expect_null(unlist(r$state$computed_sources, use.names = FALSE))
  r <- drive(r$state, wk_done(1, tok, report(created = "f"), at(12)))
  expect_equal(sum(watched_files(r$state) == "h.R"), 1)
})

test_that("a computed source() path is stored relative to the notebook folder, and gets no NA hash in the footer (item 9)", {
  s <- fake_state(list(S = cell(""), A = cell("source(file.path('sub', 'h.R'))")))
  s$path <- "/proj/nb.R"
  r <- boot(s, "A")
  tok <- r$state$worker$running$token
  r2 <- drive(r$state, wk_source(1, tok, "/proj/sub/h.R", "g <- 1", at(11)))
  expect_equal(unlist(r2$state$computed_sources, use.names = FALSE), "sub/h.R")
  reads <- Filter(function(e) identical(e$type, "read_files"), r2$effects)
  expect_true(length(reads) == 1 && "sub/h.R" %in% reads[[1]]$paths)

  r3 <- drive(r2$state, wk_done(1, tok, report(created = "g"), at(12)))
  txt <- format_notebook(notebook_file_of(r3$state), r3$state$graph$order)
  expect_false(grepl("sub/h.R", txt, fixed = TRUE))  # hash still unknown: left out, not written as NA
  expect_false(grepl("NA", txt, fixed = TRUE))

  r4 <- drive(r3$state, ev_files_read(list("sub/h.R" = list(text = "g <- 1", hash = "md5:ccc")), at(13)))
  txt2 <- format_notebook(notebook_file_of(r4$state), r4$state$graph$order)
  expect_true(grepl("sub/h.R md5:ccc", txt2, fixed = TRUE))
})

test_that("an errored rerun keeps previously learned definitions instead of replacing them (item 11)", {
  s <- fake_state(list(S = cell(""), A = cell("load('f.rda')"), B = cell("summary(fits)")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "fits"), at(11)))
  expect_true("A" %in% r$state$graph$upstream$B)

  r2 <- drive(r$state, ev_run("A", at(20)))
  r2 <- drive(r2$state, wk_done(1, last_token(r2),
                                report(status = "error", error = list(message = "file gone")), at(21)))
  expect_true("A" %in% r2$state$graph$upstream$B)
  expect_equal(r2$state$graph$learned$definitions$A, "fits")
})

test_that("an insert op containing a marker line is refused, like set_code (item 17)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  n1 <- "33333333-3333-4333-8333-333333333333"
  r <- drive(s, ev_apply(list(op_insert(n1, 3, "x <- 1\n# %% id=evil\ny <- 2")), at(1)))
  expect_true(inherits(r$reply, "ember_refused"))
  expect_identical(r$state, at_clock(s, 1))
})

test_that("notifications catch a graph-only change (quick check now includes graph/allowed)", {
  s <- fake_state(list(S = cell(""), A = cell("source('h.R')"), B = cell("f <- 2")))
  r1 <- drive(s, ev_files_read(list(h.R = list(text = "x <- 1", hash = "md5:1")), at(1)))
  r2 <- drive(r1$state, ev_files_read(list(h.R = list(text = "f <- function() 1", hash = "md5:2")), at(2)))
  expect_identical(r1$state$cells, r2$state$cells)
  expect_identical(r1$state$results, r2$state$results)
  expect_identical(r1$state$pending, r2$state$pending)
  expect_identical(r1$state$worker, r2$state$worker)

  n <- notifications(r1$state, r2$state)
  cs <- Find(function(x) identical(x$kind, "cell_state"), n)
  expect_true(!is.null(cs))
  expect_true("A" %in% cs$cells || "B" %in% cs$cells)
})

test_that("lazy: a sourced-file change marks the sourcing cell's dependents stale too", {
  s <- fake_state(list(S = cell(""), A = cell("source('h.R')"), B = cell("y <- f()")), on_cell_change = "lazy")
  r <- drive(s, ev_files_read(list(h.R = list(text = "f <- function() 1", hash = "md5:1")), at(1)))
  r <- boot(r$state, "B", at0 = 2)
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "f"), at(11)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(12)))

  r2 <- drive(r$state, ev_files_read(list(h.R = list(text = "f <- function() 2", hash = "md5:2")), at(20)))
  v <- snapshot_of(r2$state)$cells
  expect_true(v$A$stale)
  expect_true(v$B$stale)
})

test_that("a restart offer is cleared when the worker exits", {
  s <- fake_state(list(S = cell(""), A = cell("repeat{}")))
  r <- boot(s, "A")
  tok <- r$state$worker$running$token
  r <- drive(r$state, ev_interrupt(at(20)), tm_offer_restart(1, tok, at(23)))
  expect_true(r$state$worker$restart_offered)

  r2 <- drive(r$state, wk_exited(1, 1L, "killed", at(30)))
  expect_false(r2$state$worker$restart_offered)
})

test_that("restart is refused on a read-only notebook even when allowed", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  s$read_only <- TRUE
  r <- drive(s, ev_allow(at(1)), ev_restart(at(2)))
  expect_true(inherits(r$reply, "ember_refused"))
  expect_equal(r$state$worker$status, "off")
})

test_that("wk_rendered replaces only the image data, keeping the text form", {
  s <- fake_state(list(S = cell(""), A = cell("plot(1)")))
  tok <- 7L
  out <- new_display("image/png", "old-bytes", "[plot]", size = list(width = 400, height = 300), token = tok)
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(output = out), at(10)))

  new_disp <- new_display("image/png", "new-bytes", "ignored-text",
                          size = list(width = 800, height = 600), token = tok)
  r2 <- drive(r$state, wk_rendered(1, "A", new_disp, at(11)))
  v <- r2$state$results$A$output
  expect_equal(v$data, "new-bytes")
  expect_equal(v$size, list(width = 800, height = 600))
  expect_equal(v$text, "[plot]")
  expect_equal(v$rendered_at, at(11))

  # a reply from an older run (token mismatch) is dropped
  stale <- new_display("image/png", "stale-bytes", "x", token = 999L)
  r3 <- drive(r2$state, wk_rendered(1, "A", stale, at(12)))
  expect_equal(r3$state$results$A$output$data, "new-bytes")
})

test_that("cell_view()'s variables is sorted, leaves out dot-names, and empty after wk_exited or for an off cell (ui-3 70)", {
  s <- fake_state(list(S = cell(""), A = cell("b <- 2; a <- 1; .c <- 3")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r),
                              report(created = c("a", "b", ".c"),
                                     globals = list(
                                       a = list(type = "numeric", value = "1", kind = "value"),
                                       b = list(type = "numeric", value = "2", kind = "value"),
                                       .c = list(type = "numeric", value = "3", kind = "value"))),
                              at(10)))
  vars <- snapshot_of(r$state)$cells$A$variables
  expect_equal(vapply(vars, `[[`, character(1), "name"), c("a", "b"))

  js <- notebook_snapshot(list(state = r$state))
  av <- Find(function(v) identical(v$name, "a"), js$cells$A$variables)
  expect_equal(names(av), c("name", "type"))

  r2 <- drive(r$state, wk_exited(1, 1L, "killed", at(20)))
  expect_equal(snapshot_of(r2$state)$cells$A$variables, list())
})

test_that("a done with status error, or an ok done the server turns into an error, stores no variables (ui-3 70)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r),
                              report(status = "error", error = list(message = "boom"),
                                     created = "a",
                                     globals = list(a = list(type = "numeric", value = "1", kind = "value"))),
                              at(10)))
  expect_equal(snapshot_of(r$state)$cells$A$variables, list())

  s2 <- fake_state(list(S = cell("x <- 1"), A = cell("1")))
  r2 <- boot(s2, "A")
  r2 <- drive(r2$state, wk_done(1, last_token(r2),
                                report(changed = "x",
                                       globals = list(x = list(type = "numeric", value = "1", kind = "value"))),
                                at(10)))
  expect_equal(r2$state$results$A$error$kind, "multiple_definitions")
  expect_equal(snapshot_of(r2$state)$cells$A$variables, list())
})

test_that("an off cell has no variables in its view, even though its result keeps them underneath (ui-3 70)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x",
             globals = list(x = list(type = "numeric", value = "1", kind = "value"))), at(10)))
  expect_length(r$state$results$A$variables, 1)   # really has one, while enabled

  r2 <- drive(r$state, ev_apply(list(op_disable("A")), at(20)))
  expect_true("A" %in% names(r2$state$graph$off))
  # the result (and its variables) are kept underneath, for the dimmed
  # output -- only the view suppresses them while the cell is off.
  expect_length(r2$state$results$A$variables, 1)

  ctx <- view_context(r2$state)
  va <- Find(function(i) identical(ctx$ids[[i]], "A"), seq_along(ctx$ids))
  expect_equal(cell_view(r2$state, ctx, va)$variables, list())
})

test_that("reduce_render() with NULL width and height sends render {cell, res} without those fields (ui-3 66)", {
  s <- fake_state(list(S = cell(""), A = cell("plot(1)")))
  out <- new_display("image/png", "bytes", "[plot]", size = list(width = 1440, height = 960, res = 192))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(output = out), at(10)))

  r2 <- drive(r$state, ev_render("A", NULL, NULL, at(11), res = 288))
  msg <- last_sent(r2)
  expect_equal(msg$type, "render")
  expect_equal(msg$cell, "A")
  expect_equal(msg$res, 288)
  expect_false("width" %in% names(msg))
  expect_false("height" %in% names(msg))
})

test_that("reduce_show_more sends 'more' for a table/tree output while the worker is alive, nothing otherwise (ui-2 30)", {
  s <- fake_state(list(S = cell(""), A = cell("mtcars"), B = cell("1")))
  table_out <- new_display("application/vnd.ember.table",
                           list(names = "a", types = "<dbl>", nrow = 1L, ncol = 1L,
                               row_labels = "1", rows = list("1"), more_rows = 0L, more_cols = 0L),
                           "mtcars", token = 1L)
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(output = table_out), at(10)))

  r2 <- drive(r$state, ev_show_more("A", path = "", dim = 1L, at = at(11)))
  sent <- Filter(function(e) identical(e$type, "send"), r2$effects)
  expect_length(sent, 1)
  expect_equal(sent[[1]]$msg, list(type = "more", cell = "A", path = "", dim = 1L))

  more_sent <- function(effects) Filter(function(e) identical(e$type, "send") && identical(e$msg$type, "more"), effects)

  # a text output: no "more" is sent
  s3 <- fake_state(list(S = cell(""), A = cell("1")))
  r3 <- boot(s3, "A")
  r3 <- drive(r3$state, wk_done(1, last_token(r3), report(output = new_display("text/plain", NULL, "x", token = 1L)), at(12)))
  r4 <- step(r3$state, ev_show_more("A", path = "", dim = 1L, at = at(13)))
  expect_length(more_sent(r4$effects), 0)

  # the worker off: nothing is sent
  s2 <- fake_state(list(S = cell(""), A = cell("mtcars")))
  r5 <- step(s2, ev_show_more("A", path = "", dim = 1L, at = at(1)))
  expect_length(more_sent(r5$effects), 0)
})

test_that("apply's reply seq matches the actual final seq, even on a no-op", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- step(s, ev_apply(list(op_fold("A", FALSE)), at(1)))  # already unfolded: a true no-op
  expect_equal(r$state$seq, s$seq)
  expect_equal(r$reply$seq, r$state$seq)
})

test_that("a denied computed source() reports run error kind source_conflict", {
  s <- fake_state(list(S = cell(""), B = cell("z <- 1"), A = cell("source(file.path('.', 'h.R'))")))
  r <- boot(s, "A")
  tok <- r$state$worker$running$token
  r2 <- drive(r$state, wk_source(1, tok, "h.R", "z <- 2", at(10)))
  msg <- last_sent(r2)$message
  r3 <- drive(r2$state, wk_done(1, tok, report(error = list(message = msg)), at(11)))
  expect_equal(r3$state$results$A$error$kind, "source_conflict")
  expect_equal(r3$state$results$A$error$message, msg)
})

test_that("a computed path from the footer stands in until every code cell has run", {
  file <- fake_file(list(A = cell("source(p)")))
  file$sourced <- data.frame(path = "gen/h.R", hash = "md5:abc", stringsAsFactors = FALSE)
  s <- new_state(file, path = "nb.R", id = "n1", options = list(library = NULL), at = 0)
  expect_identical(s$footer_sources, "gen/h.R")
  expect_true("gen/h.R" %in% notebook_file_of(s)$sourced$path)

  r <- boot(s, "A")
  expect_identical(r$state$footer_sources, "gen/h.R")
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(20)))
  expect_length(r$state$footer_sources, 0)
  expect_false("gen/h.R" %in% notebook_file_of(r$state)$sourced$path)
})

test_that("all_code_cells_ran() excludes an off cell, so the footer source still clears (review)", {
  file <- fake_file(list(A = cell("source(p)"), B = cell("x <- 1", disabled = TRUE)))
  file$sourced <- data.frame(path = "gen/h.R", hash = "md5:abc", stringsAsFactors = FALSE)
  s <- new_state(file, path = "nb.R", id = "n1", options = list(library = NULL), at = 0)
  expect_identical(s$footer_sources, "gen/h.R")
  expect_true("B" %in% names(s$graph$off))

  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(20)))
  # B is disabled and never runs; without excluding it, all_code_cells_ran()
  # would stay FALSE forever and the footer source would never clear.
  expect_length(r$state$footer_sources, 0)
})

#' Save `state` and open the saved text as a fresh session, as closing
#' and reopening the notebook would.
reopen <- function(state) {
  text <- format_notebook(notebook_file_of(state), state$graph$order)
  file <- parse_notebook(text, new_id = function() stop("no new ids expected"))
  new_state(file, path = state$path, id = "n2", options = list(library = NULL), at = 0)
}

test_that("a learned reference is saved, so its edge survives a reopen without running", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("lm(y ~ x, data = df)")))
  r <- boot(s, "B")
  r <- drive(r$state, wk_done(1, last_token(r), report(formula_misses = "x"), at(10)))
  expect_true("A" %in% r$state$graph$upstream$B)

  s2 <- reopen(r$state)
  expect_equal(s2$graph$learned$references$B, "x")
  expect_true("A" %in% s2$graph$upstream$B)
  expect_equal(s2$graph$order, r$state$graph$order)
})

test_that("editing a cell drops its learned references, so a stale one can't hold it in a cycle (review)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"),
                       B = cell("fit <- lm(y ~ x, data = df)"), C = cell("q <- 1")),
                  on_cell_change = "lazy")
  r <- boot(s, "B")
  r <- drive(r$state, wk_done(1, last_token(r), report(formula_misses = "x"), at(10)))
  expect_equal(r$state$graph$learned$references$B, "x")

  # Move x into C, which reads B's fit: B <-> C is a real cycle while B
  # uses x. Editing B so it doesn't must break it without running B.
  r <- drive(r$state, ev_apply(list(op_set_code("A", "z <- 1"),
                                    op_set_code("C", "x <- predict(fit)")), at(20)))
  expect_true("C" %in% r$state$graph$upstream$B)
  expect_true("B" %in% r$state$graph$upstream$C)
  r <- drive(r$state, ev_apply(list(op_set_code("B", "fit <- lm(y ~ w, data = df)")), at(30)))
  expect_null(r$state$graph$learned$references$B)
  expect_false("C" %in% r$state$graph$upstream$B)

  # Nor does the reopened file bring it back.
  s2 <- reopen(r$state)
  expect_null(s2$graph$learned$references$B)
  expect_false("C" %in% s2$graph$upstream$B)
})

test_that("an edit that leaves the code as it was keeps the learned references", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("lm(y ~ x, data = df)")))
  r <- boot(s, "B")
  r <- drive(r$state, wk_done(1, last_token(r), report(formula_misses = "x"), at(10)))
  r <- drive(r$state, ev_apply(list(op_set_code("B", "lm(y ~ x, data = df)"), op_fold("B", TRUE)), at(20)))
  expect_equal(r$state$graph$learned$references$B, "x")
})

test_that("a learned sources line naming a path with no hash is not seeded (review)", {
  file <- fake_file(list(A = cell("source(p)")))
  file$sourced <- data.frame(path = "gen/h.R", hash = "md5:abc", stringsAsFactors = FALSE)
  file$learned_sources <- list(A = c("gen/h.R", "gen/gone.R"))
  s <- new_state(file, path = "nb.R", id = "n1", options = list(library = NULL), at = 0)
  expect_equal(s$computed_sources, list(A = "gen/h.R"))
  expect_false("gen/gone.R" %in% watched_files(s))
})

test_that("a computed source() path is saved with the cell that sourced it", {
  s <- fake_state(list(S = cell(""), A = cell("source(p)"), B = cell("y <- 1")))
  s$path <- "/proj/nb.R"
  r <- boot(s, "A")
  tok <- r$state$worker$running$token
  r <- drive(r$state, wk_source(1, tok, "/proj/gen/h.R", "g <- 1", at(11)),
             ev_files_read(list("gen/h.R" = list(text = "g <- 1", hash = "md5:abc")), at(12)),
             wk_done(1, tok, report(created = "g"), at(13)))
  file <- notebook_file_of(r$state)
  expect_equal(file$learned_sources, list(A = "gen/h.R"))
  expect_true("gen/h.R" %in% file$sourced$path)

  # Reopened, A's path is A's again: watched and saved, but no stand-in
  # for every cell.
  s2 <- reopen(r$state)
  expect_equal(s2$computed_sources, list(A = "gen/h.R"))
  expect_length(s2$footer_sources, 0)
  expect_true("gen/h.R" %in% watched_files(s2))
  expect_equal(notebook_file_of(s2)$learned_sources, list(A = "gen/h.R"))

  # Rerunning A without the source() drops the path at once, though B
  # hasn't run in this worker.
  r2 <- boot(s2, "A")
  r2 <- drive(r2$state, wk_done(1, last_token(r2), report(), at(20)))
  expect_null(r2$state$results$B)
  expect_false("gen/h.R" %in% watched_files(r2$state))
  expect_length(notebook_file_of(r2$state)$learned_sources, 0)
  expect_false("gen/h.R" %in% notebook_file_of(r2$state)$sourced$path)
})

test_that("a computed source() path of a deleted cell leaves the footer", {
  file <- fake_file(list(A = cell("source(p)"), B = cell("y <- 1")))
  file$sourced <- data.frame(path = "gen/h.R", hash = "md5:abc", stringsAsFactors = FALSE)
  file$learned_sources <- list(A = "gen/h.R")
  s <- new_state(file, path = "nb.R", id = "n1", options = list(library = NULL), at = 0)
  expect_equal(s$computed_sources, list(A = "gen/h.R"))
  r <- drive(s, ev_apply(list(op_delete("A")), at(1)))
  expect_false("gen/h.R" %in% notebook_file_of(r$state)$sourced$path)
  expect_length(notebook_file_of(r$state)$learned_sources, 0)
})

test_that("every cell in a cycle shows the cycle error, over a stale run error, and none runs", {
  s <- fake_state(list(S = cell(""), A = cell("x <- z"), B = cell("y <- 1")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(status = "error",
                              error = list(message = "object 'z' not found")), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(11)))
  expect_equal(r$state$results$A$status, "error")

  r2 <- drive(r$state, ev_apply(list(op_set_code("B", "y <- x + 1"),
                                     op_set_code("A", "x <- y + 1")), at(20)),
              ev_run(c("A", "B"), at(21)))
  expect_equal(sent_cells(r2), character())
  expect_setequal(r2$reply$skipped, c("A", "B"))
  for (id in c("A", "B")) {
    v <- snapshot_of(r2$state)$cells[[id]]
    expect_equal(vapply(v$errors, function(e) e$kind, ""), "cycle")
    expect_match(project_output(v)$body$msg, "^Cyclic references among")
  }
})

test_that("two cells inserted as a cycle both show the cycle error and neither runs", {
  s <- fake_state(list(S = cell("")))
  a <- "11111111-1111-4111-8111-111111111111"
  b <- "22222222-2222-4222-8222-222222222222"
  r <- drive(s, ev_apply(list(op_insert(a, 2, "x <- y + 1"), op_insert(b, 3, "y <- x + 1")), at(1)),
             ev_run(c(a, b), at(2)))
  expect_setequal(r$reply$skipped, c(a, b))
  for (id in c(a, b)) {
    v <- snapshot_of(r$state)$cells[[id]]
    expect_equal(vapply(v$errors, function(e) e$kind, ""), "cycle")
  }
})

# ---- ui-3, piece 1: errors flow downstream (docs/ui-3-tests.md) -----------

test_that("autorun: a failed ancestor's effects are drop_globals then the dependent's run (ui-3 1)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))
  expect_equal(r$state$results$B$status, "ok")

  r2 <- drive(r$state, ev_run("A", at(12)))
  r2 <- drive(r2$state, wk_done(1, last_token(r2),
                               report(status = "error", error = list(message = "boom")), at(13)))
  sends <- Filter(function(e) identical(e$type, "send"), r2$effects)
  expect_equal(sends[[1]]$msg, list(type = "drop_globals", cell = "A"))
  expect_equal(sends[[length(sends)]]$msg$cell, "B")
  expect_false("B" %in% r2$state$pending)
})

test_that("lazy: a failed ancestor sends drop_globals and leaves dependents stale (ui-3 2)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a")), on_cell_change = "lazy")
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))
  expect_equal(r$state$results$B$status, "ok")

  r2 <- drive(r$state, ev_run("A", at(12)))
  r2 <- drive(r2$state, wk_done(1, last_token(r2),
                               report(status = "error", error = list(message = "boom")), at(13)))
  expect_true(any(vapply(r2$effects, function(e) {
    identical(e$type, "send") && identical(e$msg$type, "drop_globals") && identical(e$msg$cell, "A")
  }, logical(1))))
  expect_true(isTRUE(r2$state$results$B$stale))
  expect_false("B" %in% r2$state$pending)
})

test_that("interrupting a cell sends drop_globals and leaves dependents stale (ui-3 6)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))
  expect_equal(r$state$results$B$status, "ok")

  r2 <- drive(r$state, ev_apply(list(op_set_code("A", "a <- 2")), at(20)), ev_run("A", at(21)))
  tok <- r2$state$worker$running$token
  r3 <- drive(r2$state, ev_interrupt(at(22)))
  r4 <- drive(r3$state, wk_done(1, tok, report(status = "interrupted"), at(23)))
  expect_true(any(vapply(r4$effects, function(e) {
    identical(e$type, "send") && identical(e$msg$type, "drop_globals") && identical(e$msg$cell, "A")
  }, logical(1))))
  expect_false("B" %in% r4$state$pending)
  expect_true(isTRUE(r4$state$results$B$stale))
})

test_that("interrupting a cell marks a reader of its reported names stale even with no learned edge yet (ui-3 6, fix 6)", {
  # R references "fits" before any run of A has taught the graph that A
  # defines it, so there is no edge from A to R; only invalidate_dependents()'s
  # "names" path (not a plain downstream() walk) can find R.
  s <- fake_state(list(S = cell(""), A = cell("load('x.rds')"), R = cell("print(fits)")))
  expect_false("A" %in% s$graph$upstream$R)

  r <- boot(s, "R")
  r <- drive(r$state, wk_done(1, last_token(r),
                              report(status = "error", error = list(message = "object 'fits' not found")), at(10)))
  expect_equal(r$state$results$R$status, "error")

  r2 <- drive(r$state, ev_run("A", at(20)))
  tok <- r2$state$worker$running$token
  r3 <- drive(r2$state, ev_interrupt(at(21)))
  r4 <- drive(r3$state, wk_done(1, tok, report(status = "interrupted", created = "fits"), at(22)))

  expect_true(any(vapply(r4$effects, function(e) {
    identical(e$type, "send") && identical(e$msg$type, "drop_globals") && identical(e$msg$cell, "A")
  }, logical(1))))
  expect_false("R" %in% r4$state$pending)
  expect_true(isTRUE(r4$state$results$R$stale))
})

# ---- Disable cell: engine (ui-3 24-31) ---------------------------------------

test_that("disabling a cell removes it and its dependent, keeping both results stale (ui-3 24)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1"), C = cell("2")))
  r <- boot(s, c("A", "B", "C"))
  expect_equal(r$state$worker$running$cell, "A")
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(created = "x"), at(10)))
  expect_equal(r$state$worker$running$cell, "B")
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(), at(11)))
  expect_equal(r$state$worker$running$cell, "C")
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(), at(12)))
  expect_null(r$state$worker$running)

  r2 <- drive(r$state, ev_apply(list(op_disable("A")), at(20)))
  sends <- Filter(function(e) identical(e$type, "send"), r2$effects)
  expect_equal(length(sends), 2)
  expect_equal(vapply(sends, function(e) e$msg$type, character(1)), c("remove_cell", "remove_cell"))
  expect_equal(vapply(sends, function(e) e$msg$cell, character(1)), c("A", "B"))
  expect_true(isTRUE(r2$state$results$A$stale))
  expect_true(isTRUE(r2$state$results$B$stale))
  expect_false(isTRUE(r2$state$results$C$stale))
  expect_equal(r2$state$pending, character())
})

test_that("ev_run(NULL) skips off cells; a run request naming an off cell doesn't queue its stale ancestors (ui-3 25)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1"), C = cell("2")))
  r <- boot(s, c("A", "B", "C"))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(), at(11)))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(), at(12)))
  r2 <- drive(r$state, ev_apply(list(op_disable("A")), at(20)))

  r3 <- drive(r2$state, ev_run(NULL, at(21)))
  expect_setequal(r3$reply$skipped, c("A", "B"))

  s4 <- r2$state
  s4$results$S$stale <- TRUE
  r4 <- drive(s4, ev_run("A", at(22)))
  expect_equal(r4$state$pending, character())
  expect_equal(r4$reply$queued, character())
  expect_null(r4$state$worker$running)
  expect_false(any(vapply(r4$effects, function(e) {
    identical(e$type, "send") && identical(e$msg$type, "run")
  }, logical(1))))
})

test_that("enabling a cell runs it and queues its dependent, in both modes (ui-3 26)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1"), C = cell("2")))
  r <- boot(s, c("A", "B", "C"))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(), at(11)))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(), at(12)))
  r2 <- drive(r$state, ev_apply(list(op_disable("A")), at(20)))

  r5 <- drive(r2$state, ev_apply(list(op_disable("A", FALSE)), at(23)))
  expect_equal(r5$effects, list())
  expect_equal(r5$state$pending, character())

  r6 <- drive(r5$state, ev_run("A", at(24)))
  expect_equal(r6$state$worker$running$cell, "A")
  r7 <- drive(r6$state, wk_done(1, r6$state$worker$running$token, report(created = "x"), at(25)))
  expect_equal(r7$state$worker$running$cell, "B")   # autorun: B queued and immediately sent

  s_lazy <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1"), C = cell("2")),
                       on_cell_change = "lazy")
  rl <- boot(s_lazy, c("A", "B", "C"))
  rl <- drive(rl$state, wk_done(1, rl$state$worker$running$token, report(created = "x"), at(10)))
  rl <- drive(rl$state, wk_done(1, rl$state$worker$running$token, report(), at(11)))
  rl <- drive(rl$state, wk_done(1, rl$state$worker$running$token, report(), at(12)))
  rl2 <- drive(rl$state, ev_apply(list(op_disable("A")), at(20)))
  rl5 <- drive(rl2$state, ev_apply(list(op_disable("A", FALSE)), at(23)))
  rl6 <- drive(rl5$state, ev_run("A", at(24)))
  rl7 <- drive(rl6$state, wk_done(1, rl6$state$worker$running$token, report(created = "x"), at(25)))
  expect_true(isTRUE(rl7$state$results$B$stale))
  expect_false("B" %in% rl7$state$pending)
  expect_null(rl7$state$worker$running)
})

test_that("an edit that makes a cell read a name only a disabled cell provides turns it off (ui-3 27)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1", disabled = TRUE), D = cell("y <- 3")))
  r <- boot(s, "D")
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(created = "y"), at(10)))
  expect_true("D" %in% names(r$state$results))

  r2 <- drive(r$state, ev_apply(list(op_set_code("D", "x * 2")), at(20)))
  sends <- Filter(function(e) identical(e$type, "send"), r2$effects)
  expect_equal(length(sends), 1)
  expect_equal(sends[[1]]$msg$type, "remove_cell")
  expect_equal(sends[[1]]$msg$cell, "D")
  expect_true(isTRUE(r2$state$results$D$stale))

  r3 <- drive(r2$state, ev_apply(list(op_set_code("D", "y <- 3", expected = "x * 2")), at(21)))
  expect_equal(Filter(function(e) identical(e$type, "send"), r3$effects), list())
})

test_that("disabling the running cell still sends remove_cell; its later done is stored stale with nothing queued (ui-3 28)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1")))
  r <- boot(s, "A")
  expect_equal(r$state$worker$running$cell, "A")
  tok <- r$state$worker$running$token

  r2 <- drive(r$state, ev_apply(list(op_disable("A")), at(20)))
  sends <- Filter(function(e) identical(e$type, "send"), r2$effects)
  expect_true(any(vapply(sends, function(e) {
    identical(e$msg$type, "remove_cell") && identical(e$msg$cell, "A")
  }, logical(1))))
  expect_equal(r2$state$worker$running$cell, "A")   # the run itself isn't interrupted

  r3 <- drive(r2$state, wk_done(1, tok, report(created = "x"), at(21)))
  expect_true(isTRUE(r3$state$results$A$stale))
  expect_false("B" %in% r3$state$pending)
  expect_null(r3$state$worker$running)
  expect_equal(Filter(function(e) identical(e$type, "send") && identical(e$msg$type, "run"), r3$effects),
              list())
})

test_that("disabling refuses a text cell and an unknown id, and refuses the whole batch (ui-3 29)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), T = cell("#' hi", kind = "markdown")))

  r <- drive(s, ev_apply(list(op_disable("S")), at(1)))
  expect_false(inherits(r$reply, "ember_refused"))

  r2 <- drive(s, ev_apply(list(op_disable("T")), at(2)))
  expect_equal(r2$reply$message, "text cells can't be disabled")

  ghost_id <- "ca1b0a64-d117-466f-898a-8603bbc24e75"
  r3 <- drive(s, ev_apply(list(op_disable(ghost_id)), at(3)))
  # No cell id in the message (cell ids are UUIDs and never belong in
  # user-facing text): exactly "unknown cell", not "unknown cell <id>".
  expect_equal(r3$reply$message, "unknown cell")
  expect_no_match(r3$reply$message, ghost_id, fixed = TRUE)

  r4 <- drive(s, ev_apply(list(op_fold("A", TRUE), op_disable("T")), at(4)))
  expect_s3_class(r4$reply, "ember_refused")
  expect_false(isTRUE(unname(r4$state$cells$A$folded)))
})

test_that("disabling in safe preview has no worker effects but still marks the cell disabled (ui-3 30)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- drive(s, ev_apply(list(op_disable("A")), at(1)))
  expect_true(isTRUE(r$state$cells$A$disabled))
  expect_equal(Filter(function(e) identical(e$type, "send"), r$effects), list())
})

test_that("disabling one of two definers clears the clash and marks both the other definer and the dependent stale (ui-3 31)", {
  a2 <- "22222222-2222-4222-8222-222222222222"
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), C = cell("x + 1")))
  r <- boot(s, c("A", "C"))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(), at(11)))
  expect_equal(r$state$results$A$status, "ok")
  expect_equal(r$state$results$C$status, "ok")

  # A2 defines an unrelated name at first, so it gets a result of its own
  # before it ever clashes with A: the spec's "A2 and C have results" means
  # A2 really has run, not merely that the graph would let it.
  r2 <- drive(r$state, ev_apply(list(op_insert(a2, 3, "y <- 1")), at(20)))
  r2 <- drive(r2$state, ev_run(a2, at(21)))
  r2 <- drive(r2$state, wk_done(1, r2$state$worker$running$token, report(created = "y"), at(22)))
  expect_equal(r2$state$results[[a2]]$status, "ok")

  # Editing A2 to also define x creates the clash; the edit alone keeps A2's
  # old result (an edit never invalidates anything by itself).
  r2 <- drive(r2$state, ev_apply(list(op_set_code(a2, "x <- 2", expected = "y <- 1")), at(23)))
  expect_length(Filter(function(e) e$kind == "multiple_definitions", r2$state$graph$errors), 1)
  expect_equal(r2$state$results[[a2]]$status, "ok")
  expect_false(isTRUE(r2$state$results[[a2]]$stale))
  expect_equal(r2$state$results$A$status, "ok")   # the clash alone invalidates nothing

  r3 <- drive(r2$state, ev_apply(list(op_disable("A")), at(24)))
  expect_length(r3$state$graph$errors, 0)
  sends <- Filter(function(e) identical(e$type, "send"), r3$effects)
  expect_equal(length(sends), 1)
  expect_equal(sends[[1]]$msg$type, "remove_cell")
  expect_equal(sends[[1]]$msg$cell, "A")
  expect_true(isTRUE(r3$state$results$A$stale))
  expect_true(isTRUE(r3$state$results[[a2]]$stale))   # marked by the owners pass
  expect_true(isTRUE(r3$state$results$C$stale))
  expect_equal(r3$state$pending, character())

  r4 <- drive(r3$state, ev_run("C", at(25)))
  expect_equal(r4$reply$queued, c(a2, "C"))
})

test_that("not_run_ids(), the snapshot's disabled/disabled_by, and check_state() (ui-3 32)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1"), N = cell("3")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(), at(11)))
  check_state(r$state)

  ctx0 <- view_context(r$state)
  expect_true("N" %in% not_run_ids(r$state, ctx0))

  r2 <- drive(r$state, ev_apply(list(op_disable("A")), at(20)))
  check_state(r2$state)
  ctx <- view_context(r2$state)
  expect_false("A" %in% not_run_ids(r2$state, ctx))
  expect_false("B" %in% not_run_ids(r2$state, ctx))
  expect_true("N" %in% not_run_ids(r2$state, ctx))

  snap <- snapshot_of(r2$state)
  expect_true(snap$cells$A$disabled)
  expect_true(is.na(snap$cells$A$disabled_by))
  expect_false(snap$cells$B$disabled)
  expect_equal(snap$cells$B$disabled_by, "A")
  expect_true(isTRUE(snap$cells$A$stale))
  expect_true(isTRUE(snap$cells$B$stale))
})

test_that("notebook_file_of() writes a disabled cell's dependent commented, and a cell with an enabled alternative plainly (ui-3 17)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1"), C = cell("2")))
  r <- boot(s, c("A", "B", "C"))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(), at(11)))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(), at(12)))
  r2 <- drive(r$state, ev_apply(list(op_disable("A")), at(20)))

  file <- notebook_file_of(r2$state)
  expect_equal(file$commented, "B")
  expect_true(file$cells$A$disabled)
  text <- format_notebook(file)
  expect_true(grepl("## x \\+ 1", text))
  expect_true(grepl("# B commented", text))
  expect_true(grepl("# A disabled", text))
  expect_false(grepl("## 2", text))   # C resolves plainly, no enabled definer needed

  a2 <- "33333333-3333-4333-8333-333333333333"
  r3 <- drive(r2$state, ev_apply(list(op_insert(a2, 3, "x <- 2")), at(21)))
  file3 <- notebook_file_of(r3$state)
  expect_false("B" %in% file3$commented)
})

test_that("a sourced-file change doesn't re-queue an off cell (review)", {
  s <- fake_state(list(S = cell(""), A = cell('source("h.R"); x <- 1'), B = cell("x + 1"), C = cell("2")))
  r <- boot(s, c("A", "B"))
  # Seed the initial hash for h.R: the first `ev_files_read` for a path never
  # seen before only records it (state$files[[p]] was NULL, so it isn't
  # "changed"); a later one with a different hash is what reduce_files_read()
  # treats as a real change.
  r <- drive(r$state, ev_files_read(list("h.R" = list(text = "z <- 1", hash = "v1")), at(9)))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(), at(11)))
  expect_false(is.null(r$state$results$A))
  expect_false(is.null(r$state$results$B))

  r2 <- drive(r$state, ev_apply(list(op_disable("A")), at(20)))
  r3 <- drive(r2$state, ev_run("C", at(21)))
  expect_equal(r3$state$worker$running$cell, "C")

  r4 <- drive(r3$state, ev_files_read(list("h.R" = list(text = "z <- 2", hash = "v2")), at(22)))
  expect_false("A" %in% r4$state$pending)
  expect_true(isTRUE(r4$state$results$A$stale))
})

test_that("reduce_wk_done() records attached/loaded namespaces even for an off cell (review)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1")))
  r <- boot(s, "A")
  r2 <- drive(r$state, ev_apply(list(op_disable("A")), at(20)))
  expect_equal(r2$state$worker$running$cell, "A")   # disabling mid-run doesn't stop it
  tok <- r2$state$worker$running$token

  r3 <- drive(r2$state, wk_done(1, tok, report(created = "x", attached = list(mypkg = "f"),
                                               loaded = c(mypkg = "1.0.0")), at(21)))
  expect_true(isTRUE(r3$state$results$A$stale))
  expect_equal(r3$state$exports$mypkg, "f")
  expect_equal(unname(r3$state$worker$loaded["mypkg"]), "1.0.0")
})

test_that("run_message() carries fig from the cell's current code (ui-3 63)", {
  s <- fake_state(list(S = cell(""), A = cell("#| fig-width: 8\n#| fig-height: 4\nplot(1)")))
  r <- boot(s, "A")
  msg <- last_sent(r)
  expect_equal(msg$fig$width, 8)
  expect_equal(msg$fig$height, 4)

  s2 <- fake_state(list(S = cell(""), A = cell("plot(1)")))
  r2 <- boot(s2, "A")
  msg2 <- last_sent(r2)
  expect_equal(msg2$fig$width, 7.5)
  expect_equal(msg2$fig$height, 5)
})

test_that("reduce_move() tells a ready/busy worker to chdir; an off one needs nothing; a starting one waits for wk_hello (ui-3 85)", {
  s <- fake_state(list(S = cell(""), A = cell("1")))

  r1 <- drive(s, ev_move("/new/dir/nb.R", at(1)))
  types1 <- vapply(r1$effects, `[[`, character(1), "type")
  expect_equal(types1, "move_file")

  r2 <- boot(s, "A")
  r3 <- drive(r2$state, ev_move("/other/dir/nb.R", at(10)))
  types3 <- vapply(r3$effects, `[[`, character(1), "type")
  expect_setequal(types3, c("move_file", "send"))
  send_fx <- Find(function(e) identical(e$type, "send"), r3$effects)
  expect_equal(send_fx$msg$type, "chdir")
  expect_equal(send_fx$msg$from, dirname(s$path))
  expect_equal(send_fx$msg$to, "/other/dir")
  expect_equal(r3$state$worker$wd, "/other/dir")

  s4 <- r2$state
  s4$worker$status <- "starting"
  s4$worker$running <- NULL
  s4$worker$gen <- s4$worker$gen + 1L
  r4 <- drive(s4, ev_move("/elsewhere/nb.R", at(20)))
  types4 <- vapply(r4$effects, `[[`, character(1), "type")
  expect_equal(types4, "move_file")
  expect_equal(r4$state$worker$wd, s4$worker$wd)  # left behind, for wk_hello to notice

  r5 <- drive(r4$state, wk_hello(s4$worker$gen, list(), at(21)))
  send_fx5 <- Find(function(e) identical(e$type, "send"), r5$effects)
  expect_equal(send_fx5$msg$type, "chdir")
  expect_equal(send_fx5$msg$from, s4$worker$wd)
  expect_equal(send_fx5$msg$to, "/elsewhere")
  expect_equal(r5$state$worker$wd, "/elsewhere")
})

# ---- A failed install lets waiting cells run (schedule()) ------------------

test_that("after a failed install, a cell waiting on the package runs instead of going silent", {
  # `cli` is only in the lock (so waiting_cells() holds "A" on it): a real
  # check_library/install_done round trip that fails, same as a renv
  # install actually failing, rather than poking `target$status` directly
  # (ev_run()'s "I want this to work now" retry, reduce_run(), would
  # otherwise immediately flip a hand-set "failed" back to "missing").
  lock <- new_lock(name = "cli", version = "3.6.0", source = "CRAN")
  s <- fake_state(list(A = cell("library(cli)")), lock = lock)
  key <- s$packages$target$key

  r <- drive(s, ev_run("A", at(1)), wk_started(1, 99, at(2)), wk_hello(1, list(), at(3)))
  r <- drive(r$state, ev_library_checked(key, NULL, at(4)))
  tok <- r$state$packages$install$token
  r <- drive(r$state, ev_install_done(tok, key, NULL, "install failed", character(), at(5),
                                      failures = data.frame(package = "cli", kind = "build_error",
                                                            detail = "boom", stringsAsFactors = FALSE)))
  expect_equal(r$state$packages$target$status, "failed")
  # Without the fix, schedule() drops "A" from pending here and nothing runs.
  expect_equal(r$state$worker$running$cell, "A")

  r2 <- drive(r$state, wk_done(r$state$worker$gen, r$state$worker$running$token, report(
    error = list(message = "there is no package called 'cli'", package = "cli")), at(7)))
  err <- r2$state$results$A$error
  expect_equal(err$kind, "missing_package")
  expect_match(err$message, "its install may have failed")
})

test_that("missing_package_error() for a locked, uninstalled package points at the install failure", {
  lock <- new_lock(name = "cli", version = "3.6.0", source = "CRAN")
  s <- fake_state(list(S = cell(""), A = cell("library(cli)")), lock = lock)
  s$packages$target$status <- "failed"

  out <- missing_package_error(s, "cli")
  expect_equal(out$error$kind, "missing_package")
  expect_match(out$error$message, "there is no package called 'cli'; its install may have failed")
})
