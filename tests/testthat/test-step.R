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

test_that("an insert id that isn't a cell id is refused (review4 item 6)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  for (bad in list("not a uuid\n# ///", "", "a b", "# %%", "a\"", strrep("a", 65), NA_character_, 1)) {
    r <- drive(s, ev_apply(list(op_insert(bad, 3, "a <- 1")), at(1)))
    expect_s3_class(r$reply, "ember_refused")
    expect_equal(names(r$state$cells), c("S", "A"))
  }
})

test_that("a short id from a hand-written file can be inserted again, as undo-delete does (#27)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1")))
  r <- drive(s, ev_apply(list(op_delete("B")), at(1)))
  r <- drive(r$state, ev_apply(list(op_insert("B", 3, "x + 1")), at(2)))
  expect_false(inherits(r$reply, "ember_refused"))
  expect_equal(names(r$state$cells), c("S", "A", "B"))
  for (id in c("md1", "load_1", "cell.2", "x-y", strrep("a", 64))) {
    r2 <- drive(r$state, ev_apply(list(op_insert(id, 1, "")), at(3)))
    expect_false(inherits(r2$reply, "ember_refused"), info = id)
  }
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

test_that("set_code of a run code cell to text leaves it unfolded, drops the result, emits remove_cell, and marks readers stale (43)", {
  s <- fake_state(list(A = cell("x <- 1"), B = cell("y <- x")))
  r <- boot(s, NULL)
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))
  expect_true(!is.null(r$state$results$A) && !is.null(r$state$results$B))

  r2 <- drive(r$state, ev_apply(list(op_set_code("A", "#' now text", expected = "x <- 1")), at(12)))
  expect_equal(r2$state$cells$A$kind, "markdown")
  expect_false(isTRUE(r2$state$cells$A$folded))
  expect_null(r2$state$results$A)
  sends <- Filter(function(e) identical(e$type, "send") && identical(e$msg$type, "remove_cell"), r2$effects)
  expect_equal(sends[[1]]$msg$cell, "A")
  expect_true(isTRUE(r2$state$results$B$stale))

  r3 <- drive(r2$state, ev_apply(list(op_set_code("A", "x <- 2", expected = "#' now text")), at(13)))
  expect_equal(r3$state$cells$A$kind, "code")
})

test_that("a cell's fold survives becoming text and going back: only a fold op changes it", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("y <- 2", folded = TRUE)))
  r <- drive(s, ev_apply(list(op_set_code("A", "#' text", expected = "x <- 1"),
                              op_set_code("B", "#' text", expected = "y <- 2")), at(1)))
  expect_equal(r$state$cells$A$kind, "markdown")
  expect_false(isTRUE(r$state$cells$A$folded))
  expect_true(isTRUE(r$state$cells$B$folded))

  r2 <- drive(r$state, ev_apply(list(op_fold("A", TRUE), op_set_code("B", "y <- 2", expected = "#' text")), at(2)))
  expect_true(isTRUE(r2$state$cells$A$folded))
  expect_equal(r2$state$cells$B$kind, "code")
  expect_true(isTRUE(r2$state$cells$B$folded))

  r3 <- drive(r2$state, ev_apply(list(op_set_code("A", "#' edited", expected = "#' text")), at(3)))
  expect_true(isTRUE(r3$state$cells$A$folded))
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

test_that("running a cell into a parse error queues its dependents in autorun (#272)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))
  expect_equal(r$state$results$B$status, "ok")

  r1 <- drive(r$state, ev_apply(list(op_set_code("A", "x <- (")), at(20)))
  expect_true("A" %in% blocked_cells(r1$state$graph))
  r2 <- drive(r1$state, ev_run("A", at(21)))
  expect_equal(r2$replies[[1]]$skipped, "A")
  expect_null(r2$state$results$A)
  expect_equal(r2$replies[[1]]$queued, "B")
  expect_equal(last_sent(r2)$cell, "B")   # after A's drop_globals
  r3 <- drive(r2$state, wk_done(1, last_token(r2),
                                report(status = "error", error = list(message = "object 'x' not found")), at(22)))
  # A no longer parses, so it defines nothing and B has no edge to it: B
  # fails with its own error, not an upstream one.
  expect_equal(r3$state$results$B$status, "error")
  expect_false(isTRUE(r3$state$results$B$stale))
})

test_that("running a cell into a multiple definition queues the name's readers in autorun (#272)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("y <- 2"), C = cell("x + 1")))
  r <- boot(s, c("A", "B", "C"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(11)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(12)))
  expect_equal(r$state$results$C$status, "ok")

  r1 <- drive(r$state, ev_apply(list(op_set_code("B", "x <- 2")), at(20)))
  r2 <- drive(r1$state, ev_run("B", at(21)))
  expect_equal(r2$replies[[1]]$skipped, "B")
  expect_equal(last_sent(r2)$cell, "C")
  expect_false("C" %in% r2$state$pending)
})

test_that("running a cell into a cycle queues its readers, and drops the blocked cycle peer unsent (#272)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("y <- 2"), C = cell("x + 1")))
  r <- boot(s, c("A", "B", "C"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(11)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(12)))

  r1 <- drive(r$state, ev_apply(list(op_set_code("B", "y <- x"), op_set_code("A", "x <- y")), at(20)))
  expect_true(all(c("A", "B") %in% blocked_cells(r1$state$graph)))
  r2 <- drive(r1$state, ev_run("A", at(21)))
  expect_setequal(r2$replies[[1]]$skipped, c("A", "B"))   # B is an ancestor of A now
  expect_equal(sent_cells(r2), "C")   # B is queued as A's dependent but blocked: dropped, not sent
  expect_false("B" %in% r2$state$pending)
  expect_null(r2$state$results$A)
  expect_null(r2$state$results$B)
})

test_that("running a cell into a graph error leaves its dependents stale, not queued, when lazy (#272)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell("x + 1")), on_cell_change = "lazy")
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))

  r1 <- drive(r$state, ev_apply(list(op_set_code("A", "x <- (")), at(20)))
  r2 <- drive(r1$state, ev_run("A", at(21)))
  expect_true(isTRUE(r2$state$results$B$stale))
  expect_equal(r2$state$pending, character())
  expect_null(last_sent(r2)$token)
})

# #315: the way out of a cycle. A and B lose their results while the cycle
# stands; C (reads B) and D (reads A) fail with upstream errors.
cycle_then_fixed <- function(on_cell_change = "autorun") {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a * 2"),
                       C = cell("b + 1"), D = cell("a")), on_cell_change = on_cell_change)
  r <- boot(s, c("A", "B", "C", "D"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "b"), at(11)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(12)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(13)))
  r <- drive(r$state, ev_apply(list(op_set_code("A", "a <- b")), at(20)), ev_run("A", at(21)))
  t <- 22
  while (!is.null(r$state$worker$running)) {
    r <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "not found")), at(t)))
    t <- t + 1
  }
  r
}

test_that("fixing a cycle runs the peer it dropped before the cells that read it (#315)", {
  r <- cycle_then_fixed()
  expect_null(r$state$results$B)
  expect_equal(r$state$results$C$error$kind, "upstream")
  expect_equal(r$state$results$D$error$kind, "upstream")

  r1 <- drive(r$state, ev_apply(list(op_set_code("A", "a <- 10")), at(30)))
  # The edit runs nothing, but C's and D's messages blamed the cycle.
  expect_true(isTRUE(r1$state$results$C$stale))
  expect_true(isTRUE(r1$state$results$D$stale))
  r2 <- drive(r1$state, ev_run("A", at(31)))
  sent <- sent_cells(r2)
  t <- 32
  while (!is.null(r2$state$worker$running)) {
    cell <- r2$state$worker$running$cell
    created <- switch(cell, A = "a", B = "b", character())
    r2 <- drive(r2$state, wk_done(1, last_token(r2), report(created = created), at(t)))
    sent <- c(sent, sent_cells(r2))
    t <- t + 1
  }
  expect_equal(sent[sent %in% c("A", "B", "C")], c("A", "B", "C"))
  expect_true("D" %in% sent)
  for (id in c("A", "B", "C", "D")) {
    expect_equal(r2$state$results[[id]]$status, "ok")
    expect_false(isTRUE(r2$state$results[[id]]$stale))
  }
})

test_that("fixing a cycle by a rename marks the cells blaming it stale (#315)", {
  for (mode in c("autorun", "lazy")) {
    r <- cycle_then_fixed(mode)
    r1 <- drive(r$state, ev_apply(list(op_set_code("A", "aa <- 1")), at(30)))
    expect_true(isTRUE(r1$state$results$C$stale), info = mode)
    expect_true(isTRUE(r1$state$results$D$stale), info = mode)
    expect_equal(r1$state$pending, character(), info = mode)   # an edit runs nothing
  }
})

test_that("a dependent queued in autorun runs its not-run ancestor first (#315)", {
  # B has no result (dropped by a graph error that is now gone) while C,
  # which reads it, does. Rerunning A queues C; B must run before it.
  r <- cycle_then_fixed()
  r1 <- drive(r$state, ev_apply(list(op_set_code("A", "a <- 10")), at(30)))
  r2 <- drive(r1$state, ev_run("A", at(31)))
  expect_true(all(c("B", "C") %in% r2$state$pending))
  expect_equal(run_order(r2$state$graph, intersect(r2$state$pending, c("B", "C"))), c("B", "C"))
})

test_that("a draft cell never run stays not run when a dependent it would feed is queued (#315)", {
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), C = cell("y + a")))
  r <- boot(s, c("A", "C"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(status = "error", error = list(message = "object 'y' not found")), at(11)))
  r1 <- drive(r$state, ev_apply(list(op_insert("E", 3, "y <- Sys.sleep(60)")), at(20)),
              ev_apply(list(op_set_code("A", "a <- 2")), at(21)), ev_run("A", at(22)))
  expect_false("E" %in% r1$state$pending)
  sent <- sent_cells(r1)
  t <- 23
  while (!is.null(r1$state$worker$running)) {
    r1 <- drive(r1$state, wk_done(1, last_token(r1), report(), at(t)))
    sent <- c(sent, sent_cells(r1))
    t <- t + 1
  }
  expect_false("E" %in% sent)
  expect_null(r1$state$results$E)
})

test_that("a cycle peer edited after its result was dropped waits to be asked (#315)", {
  r <- cycle_then_fixed()
  r1 <- drive(r$state, ev_apply(list(op_set_code("A", "a <- 10"), op_set_code("B", "b <- a * 3")), at(30)),
              ev_run("A", at(31)))
  expect_false("B" %in% r1$state$pending)
})

test_that("submitting a cell whose graph-error result is already gone still reruns its stale dependents in autorun (#325)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), A2 = cell("z <- 9"), E = cell("x + 1"), F = cell("2")))
  r <- boot(s, c("A", "A2", "E", "F"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "z"), at(11)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(12)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(13)))

  r2 <- drive(r$state, ev_apply(list(op_set_code("A2", "x <- 2")), at(20)))
  # Running F drops A's and A2's results, marking E stale but not queueing it.
  r3 <- drive(r2$state, ev_run("F", at(21)))
  r3 <- drive(r3$state, wk_done(1, last_token(r3), report(), at(22)))
  expect_null(r3$state$results$A2)
  expect_true(isTRUE(r3$state$results$E$stale))
  expect_false("E" %in% r3$state$pending)

  r4 <- drive(r3$state, ev_run("A2", at(23)))
  expect_equal(last_sent(r4)$cell, "E")
})

test_that("a dependent queued by submitting a graph error runs after a cell the other definer leaves stale (#326, #176)", {
  # D is edited to define x, which A defines: both have a graph error. E
  # reads D's w and B's y, and B reads A's q, so B is stale once A's result
  # goes: E must run after it, not with its old y. B doesn't read x, so it
  # isn't one of D's dependents.
  s <- fake_state(list(S = cell(""), A = cell("x <- 1\nq <- 2"), B = cell("y <- q + 1"),
                       D = cell("w <- 5"), E = cell("w + y")))
  r <- boot(s, c("A", "B", "D", "E"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = c("x", "q")), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(11)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "w"), at(12)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(13)))

  r2 <- drive(r$state, ev_apply(list(op_set_code("D", "x <- 2\nw <- 5")), at(20)))
  r3 <- drive(r2$state, ev_run("D", at(21)))
  expect_null(r3$state$results$A)
  expect_null(r3$state$results$D)
  expect_equal(last_sent(r3)$cell, "B")
  expect_true("E" %in% r3$state$pending)
})

test_that("a queued cell runs after a cell that dropping a graph error's result left stale, though another ran first (#449)", {
  # E is edited to define x, which A defines: both have a graph error. D
  # reads B's y and C's z, and B reads A's w. Dispatching C, which hasn't
  # run, drops A's result, so B is stale: D must run after it, not with its
  # old y. C reads nothing from B, so checking only C's ancestors missed it.
  s <- fake_state(list(S = cell(""), A = cell("x <- 1\nw <- 2"), B = cell("y <- w + 1"),
                       C = cell("z <- 5"), E = cell(""), D = cell("y + z")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = c("x", "w")), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(11)))

  r2 <- drive(r$state, ev_apply(list(op_set_code("E", "x <- 2")), at(20)))
  r3 <- drive(r2$state, ev_run("D", at(21)))
  expect_null(r3$state$results$A)
  expect_equal(last_sent(r3)$cell, "B")
  expect_true(all(c("C", "D") %in% r3$state$pending))
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

test_that("a cell that changes another cell's object in place shows a note, and its readers don't go stale (#167)", {
  s <- fake_state(list(A = cell("cnt <- make_counter()"), B = cell("cnt$add()"), C = cell("cnt$n")))
  r <- boot(s, c("A", "B", "C"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "cnt"), at(10)))
  # The worker reports a name; only one another cell defines gets the note.
  r <- drive(r$state, wk_done(1, last_token(r), report(changed_in_place = c("cnt", "tmp")), at(11)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(12)))
  expect_equal(r$state$results$B$status, "ok")
  expect_equal(r$state$results$B$changed_in_place, "cnt")
  expect_equal(snapshot_of(r$state)$cells$B$changed_in_place, "cnt")
  js <- pluto_state(r$state)$js
  check_wire(js)
  expect_equal(js$cell_results$B$ember$changed_in_place, as_arr("cnt"))
  expect_null(js$cell_results$A$ember$changed_in_place)
  expect_false(isTRUE(r$state$results$C$stale))

  # A run that changes nothing in place clears the note.
  r2 <- drive(r$state, ev_run("B", at(13)))
  r2 <- drive(r2$state, wk_done(1, last_token(r2), report(), at(14)))
  expect_equal(r2$state$results$B$changed_in_place, character())
  expect_null(pluto_state(r2$state)$js$cell_results$B$ember$changed_in_place)
})

test_that("a cell that reads globals by a computed name shows the can't-track note, before and after it runs (#357)", {
  s <- fake_state(list(N = cell("nms <- c('a', 'b')"),
                       A = cell("for (s in nms) assign(s, 1)"),
                       B = cell("sapply(nms, function(s) get(s))"),
                       C = cell("x <- lapply(nms, get)\neval(parse(text = 'a'))"),
                       D = cell("get('a')")))
  snap <- snapshot_of(s)
  expect_equal(snap$cells$B$untracked_reads, "get")
  expect_equal(snap$cells$C$untracked_reads, c("get", "eval"))
  # A literal name is a reference, not an untracked read.
  expect_equal(snap$cells$D$untracked_reads, character())
  expect_equal(snap$cells$A$untracked_reads, character())
  js <- pluto_state(s)$js
  check_wire(js)
  expect_equal(js$cell_results$B$ember$untracked_reads, as_arr("get"))
  expect_equal(js$cell_results$C$ember$untracked_reads, as_arr(c("get", "eval")))
  expect_null(js$cell_results$D$ember$untracked_reads)

  # It comes from the code, so a run keeps it and an edit that drops the
  # get() drops it; the page's cached projection follows the edit.
  r <- boot(s, c("N", "A", "B", "C", "D"))
  expect_equal(snapshot_of(r$state)$cells$B$untracked_reads, "get")
  p1 <- pluto_state(r$state)
  r2 <- drive(r$state, ev_apply(list(op_set_code("B", "nms")), at(20)))
  expect_equal(snapshot_of(r2$state)$cells$B$untracked_reads, character())
  expect_null(pluto_state(r2$state, p1)$js$cell_results$B$ember$untracked_reads)
})

test_that("a cell that reads a file by a computed path shows the can't-track note (#276)", {
  s <- fake_state(list(F = cell("f <- 'd.csv'"),
                       X = cell("d <- read.csv(f)"),
                       Y = cell("e <- read.csv('e.csv')")))
  snap <- snapshot_of(s)
  expect_equal(snap$cells$X$untracked_files, "read.csv")
  expect_equal(snap$cells$Y$untracked_files, character())
  js <- pluto_state(s)$js
  check_wire(js)
  expect_equal(js$cell_results$X$ember$untracked_files, as_arr("read.csv"))
  expect_null(js$cell_results$Y$ember$untracked_files)

  # An edit to a literal path drops it, and the cached projection follows.
  p1 <- pluto_state(s)
  r <- drive(s, ev_apply(list(op_set_code("X", "d <- read.csv('d.csv')")), at(20)))
  expect_equal(snapshot_of(r$state)$cells$X$untracked_files, character())
  expect_null(pluto_state(r$state, p1)$js$cell_results$X$ember$untracked_files)
})

test_that("a sourced file that starts reading by a computed path shows the note on a cell that hasn't run, from a cached page state (#276)", {
  s <- fake_state(list(S = cell(""), A = cell('source("h.R")')))
  r <- drive(s, ev_files_read(list("h.R" = list(text = "z <- 1", hash = "v1")), at(2)))
  p1 <- pluto_state(r$state)
  expect_null(p1$js$cell_results$A$ember$untracked_files)
  r2 <- drive(r$state, ev_files_read(list("h.R" = list(text = "d <- read.csv(f)", hash = "v2")), at(3)))
  expect_equal(r2$state$graph$analyses$A$untracked_files, "read.csv")
  expect_equal(pluto_state(r2$state, p1)$js$cell_results$A$ember$untracked_files, as_arr("read.csv"))
})

test_that("a cell that calls a function reading through get() shows the note, not the cell defining it (#365)", {
  s <- fake_state(list(N = cell("site_names <- c('site_A', 'site_B')"),
                       A = cell("for (s in site_names) assign(s, data.frame(h = 1:3))"),
                       H = cell("load_site <- function(s) get(s)"),
                       W = cell("load_all <- function(ns) lapply(ns, load_site)"),
                       C = cell("sapply(site_names, function(s) sum(load_site(s)$h))"),
                       D = cell("length(load_all(site_names))"),
                       L = cell("f <- function(s) get(s)\nf('site_A')")))
  snap <- snapshot_of(s)
  expect_equal(snap$cells$C$untracked_reads, "load_site")
  expect_equal(snap$cells$D$untracked_reads, "load_all")
  # A cell that both defines and calls one has the note too.
  expect_equal(snap$cells$L$untracked_reads, "f")
  # Defining a function reads nothing.
  expect_equal(snap$cells$H$untracked_reads, character())
  expect_equal(snap$cells$W$untracked_reads, character())
  js <- pluto_state(s)$js
  check_wire(js)
  expect_equal(js$cell_results$C$ember$untracked_reads, as_arr("load_site"))
  expect_null(js$cell_results$H$ember$untracked_reads)

  # An edit to the helper that names the variable drops the callers' notes,
  # though their own code didn't change.
  r <- boot(s, c("N", "A", "H", "W", "C", "D", "L"))
  p1 <- pluto_state(r$state)
  r2 <- drive(r$state, ev_apply(list(op_set_code("H", "load_site <- function(s) site_A")), at(20)))
  expect_equal(snapshot_of(r2$state)$cells$C$untracked_reads, character())
  expect_equal(snapshot_of(r2$state)$cells$D$untracked_reads, character())
  expect_null(pluto_state(r2$state, p1)$js$cell_results$C$ember$untracked_reads)
})

test_that("a get() helper nothing calls by a name Ember sees keeps the note on the cell defining it (#365)", {
  s <- fake_state(list(H = cell("load_site <- function(s) get(s)"),
                       S = cell("sapply(c('a', 'b'), 'load_site')"),
                       P = cell("pick <- function(s) get(s)"),
                       Q = cell("f <- paste0('pi', 'ck')\ndo.call(f, list('a'))"),
                       L = cell("args(load_site)")))
  snap <- snapshot_of(s)
  # Called by a string: the caller has the note, the definer doesn't.
  expect_equal(snap$cells$S$untracked_reads, "load_site")
  expect_equal(snap$cells$H$untracked_reads, character())
  # Called through a computed name: no caller is found, so the definer keeps it.
  expect_equal(snap$cells$P$untracked_reads, "get")
  expect_equal(snap$cells$Q$untracked_reads, character())
  # Looking at a function isn't calling it.
  expect_equal(snap$cells$L$untracked_reads, character())
})

test_that("a package load that resets a setting a settings cell set shows a note on the loading cell (#61)", {
  # A loads mgcv inside a function, so the fake lock needs no entry for it;
  # the worker's report is what matters here.
  s <- fake_state(list(S = cell("options(mgcv.vc.logrange = 50)"), A = cell("fit_model()"),
                       B = cell("x <- 1")))
  r <- boot(s, c("S", "A"))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(10)))
  expect_equal(last_sent(r)$cell, "A")
  notes <- list(list(package = "mgcv", kind = "option", name = "mgcv.vc.logrange"))
  r2 <- drive(r$state, wk_done(1, last_token(r), report(load_notes = notes), at(11)))
  expect_equal(r2$state$results$A$status, "ok")
  expect_equal(r2$state$results$A$load_notes, list(list(package = "mgcv", setting = "mgcv.vc.logrange")))
  # The note doesn't make the loading cell a settings cell.
  expect_equal(r2$state$graph$settings, "S")
  expect_equal(snapshot_of(r2$state)$cells$A$load_notes,
               list(list(package = "mgcv", setting = "mgcv.vc.logrange")))
  js <- pluto_state(r2$state)$js
  check_wire(js)
  expect_equal(js$cell_results$A$ember$load_notes,
               as_arr(list(list(package = "mgcv", setting = "mgcv.vc.logrange"))))
  expect_null(js$cell_results$S$ember$load_notes)

  # The next run loads nothing new: the note goes.
  r3 <- drive(r2$state, ev_run("A", at(12)))
  r3 <- drive(r3$state, wk_done(1, last_token(r3), report(), at(13)))
  expect_equal(r3$state$results$A$load_notes, list())
  expect_null(pluto_state(r3$state)$js$cell_results$A$ember$load_notes)
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

test_that("a sourced file that changes while its cell runs, after source() read it, leaves the result stale (#485)", {
  # A sources h.R, then works on. h.R changes while A runs: in lazy mode
  # the result A sends, built from the old h.R, is stale; in autorun A runs
  # again and that result is current.
  start <- function(mode) {
    s <- fake_state(list(S = cell(""), A = cell('source("h.R"); Sys.sleep(3); z'), B = cell("z + 1")),
                    on_cell_change = mode)
    s$path <- "/proj/nb.R"
    r <- drive(s, ev_files_read(list("h.R" = list(text = "z <- 1\n", hash = "v1")), at(1)))
    r <- boot(r$state, c("A", "B"), at0 = 2)
    tok <- r$state$worker$running$token
    # The worker's text is readLines() joined, with no final newline.
    drive(r$state, wk_source(1, tok, "/proj/h.R", "z <- 1", at(11)))
  }
  r <- start("lazy")
  tok <- r$state$worker$running$token
  r <- drive(r$state, ev_files_read(list("h.R" = list(text = "z <- 2\n", hash = "v2")), at(12)),
             wk_done(1, tok, report(created = "z"), at(13)))
  expect_true(r$state$results$A$stale)
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(), at(14)))
  expect_true(r$state$results$B$stale)
  expect_equal(r$state$pending, character())

  r <- start("autorun")
  tok <- r$state$worker$running$token
  r <- drive(r$state, ev_files_read(list("h.R" = list(text = "z <- 2\n", hash = "v2")), at(12)),
             wk_done(1, tok, report(created = "z"), at(13)))
  expect_equal(r$state$worker$running$cell, "A")
  expect_true(r$state$results$A$stale)

  # A change seen before source() read the file: the run reads the new
  # text, so its result is current.
  s <- fake_state(list(S = cell(""), A = cell('Sys.sleep(1); source("h.R"); z')), on_cell_change = "lazy")
  s$path <- "/proj/nb.R"
  r <- drive(s, ev_files_read(list("h.R" = list(text = "z <- 1\n", hash = "v1")), at(1)))
  r <- boot(r$state, "A", at0 = 2)
  tok <- r$state$worker$running$token
  r <- drive(r$state, ev_files_read(list("h.R" = list(text = "z <- 2\n", hash = "v2")), at(11)),
             wk_source(1, tok, "/proj/h.R", "z <- 2", at(12)),
             wk_done(1, tok, report(created = "z"), at(13)))
  expect_false(isTRUE(r$state$results$A$stale))
  # A change after source() read it stays counted even if the file then
  # changes back to the text the run read: the result is marked stale,
  # which costs at most a rerun.
  r <- drive(r$state, ev_run("A", at(20)))
  tok <- r$state$worker$running$token
  r <- drive(r$state, wk_source(1, tok, "/proj/h.R", "z <- 2", at(31)),
             ev_files_read(list("h.R" = list(text = "z <- 3", hash = "v3")), at(32)),
             ev_files_read(list("h.R" = list(text = "z <- 2\r\n", hash = "v2")), at(33)),
             wk_done(1, tok, report(created = "z"), at(34)))
  expect_true(r$state$results$A$stale)
})

test_that("read_old_source() matches a sourced path by its tail and compares text without line endings (#485)", {
  src <- list(list(path = "/proj/R/h.R", text = "a\nb"))
  expect_false(read_old_source(src, "R/h.R", "a\r\nb\r\n"))
  expect_true(read_old_source(src, "R/h.R", "a\nc\n"))
  expect_true(read_old_source(src, "./R/h.R", "x"))
  expect_true(read_old_source(src, "../proj/R/h.R", "x"))
  # No file at that tail was read: one of the same name counts, since a
  # symlink can hide it, which costs at most a rerun.
  expect_true(read_old_source(src, "S/h.R", "x"))
  expect_false(read_old_source(src, "R/g.R", "x"))
  expect_false(read_old_source(list(), "R/h.R", "x"))
  expect_false(read_old_source(src, "R/h.R", NA_character_))
  expect_true(read_old_source(list(list(path = "C:\\proj\\h.R", text = "a")), "h.R", "b"))
  # A path that reads differently once normalized matches by file name.
  expect_true(read_old_source(list(list(path = "/private/tmp/x/h.R", text = "a")), "/tmp/x/h.R", "b"))
  expect_false(read_old_source(list(list(path = "/private/tmp/x/h.R", text = "a")), "/tmp/x/h.R", "a\n"))
  expect_true(read_old_source(list(list(path = "C:\\Users\\me\\h.R", text = "a")), "c:/Users/me/h.R", "b"))
  expect_true(read_old_source(list(list(path = "/home/me/real/h.R", text = "a")), "link/h.R", "b"))
  # A file of the same name the run read isn't taken for one at the tail.
  two <- list(list(path = "/proj/a/h.R", text = "a"), list(path = "/proj/b/h.R", text = "b"))
  expect_false(read_old_source(two, "b/h.R", "b"))
  expect_true(read_old_source(two, "a/h.R", "b"))
})

# ---- Data files a cell reads (#276) -----------------------------------------

# W writes d.csv, R reads it, U uses what R read: no edge between W and R.
# R's result saw d.csv at version "v1" (the shell's signature of the file).
data_file_notebook <- function(on_cell_change = "autorun") {
  s <- fake_state(list(S = cell(""),
                       W = cell('write.csv(data.frame(x = 1:3), "d.csv", row.names = FALSE)'),
                       R = cell('d <- read.csv("d.csv")'),
                       U = cell("print(sum(d$x))")),
                  on_cell_change = on_cell_change)
  r <- boot(s, c("W", "R", "U"))
  for (created in list(character(), "d", character())) {
    seen <- if (identical(created, "d")) list("d.csv" = "v1") else list()
    r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(created = created, data_seen = seen),
                                at(r$state$worker$running$started_at + 2)))
  }
  r
}

test_that("a cell that reads a data file by a literal path has it in its analysis (#276)", {
  r <- data_file_notebook()
  expect_equal(r$state$graph$analyses$R$data_files, "d.csv")
  expect_equal(r$state$graph$analyses$W$data_files, character())
  expect_equal(watched_data_files(r$state), "d.csv")
  expect_equal(r$state$results$R$data_seen, list("d.csv" = "v1"))
})

test_that("a data file that changed after its reader ran reruns the reader and its dependents in autorun (#276)", {
  r <- data_file_notebook()
  r2 <- drive(r$state, ev_data_changed(list("d.csv" = "v2"), at(21)))
  expect_equal(r2$state$worker$running$cell, "R")
  expect_true(isTRUE(r2$state$results$U$stale) || "U" %in% r2$state$pending)
  expect_false("W" %in% c(r2$state$pending, r2$state$worker$running$cell))
})

test_that("a cell edited to stop reading a data file goes stale when that file changes before it runs again (#439)", {
  # Its result, and U's, came from the old file, so they are out of date
  # the same as for a cell that still reads it.
  r <- data_file_notebook("lazy")
  r <- drive(r$state, ev_apply(list(op_set_code("R", "d <- data.frame(x = 4)")), at(20)))
  expect_equal(r$state$graph$analyses$R$data_files, character())
  expect_equal(watched_data_files(r$state), "d.csv")
  r2 <- drive(r$state, ev_data_changed(list("d.csv" = "v2"), at(21)))
  expect_true(isTRUE(r2$state$results$R$stale))
  expect_true(isTRUE(r2$state$results$U$stale))
  expect_length(r2$state$pending, 0)
  # Once it runs its new code, its result reads no file and nothing is watched.
  r3 <- drive(r2$state, ev_run("R", at(22)))
  r3 <- drive(r3$state, wk_done(1, r3$state$worker$running$token, report(created = "d"), at(23)))
  expect_equal(watched_data_files(r3$state), character())
})

test_that("a run whose upstream cell is deleted while it runs ends stale, as the delete would leave it idle (#451)", {
  s <- fake_state(list(S = cell(""), A = cell("v1 <- 1"), B = cell("v2 <- v1 + 5")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "v1"), at(5)))
  expect_equal(r$state$worker$running$cell, "B")
  r2 <- drive(r$state, ev_apply(list(op_delete("A")), at(6)))
  r3 <- drive(r2$state, wk_done(1, last_token(r), report(created = "v2"), at(7)))
  expect_equal(r3$state$results$B$status, "ok")
  expect_true(isTRUE(r3$state$results$B$stale))
  # An edit runs nothing, in autorun too.
  expect_equal(r3$state$pending, character())
  # Its first run too, with no result to mark when the delete came.
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "v1"), at(5)))
  r$state$results$B <- NULL
  r2 <- drive(r$state, ev_apply(list(op_delete("A")), at(6)))
  r3 <- drive(r2$state, wk_done(1, last_token(r), report(created = "v2"), at(7)))
  expect_true(isTRUE(r3$state$results$B$stale))
})

test_that("in lazy mode a hand run that makes a queued cell's ancestor stale reruns that ancestor first (#453)", {
  s <- fake_state(list(S = cell(""), C1 = cell("v1 <- 1"), C2 = cell("v2 <- v1 + 1"),
                       C3 = cell("v3 <- v2 + 1"), C4 = cell("v3 + 1")), on_cell_change = "lazy")
  r <- boot(s, c("C1", "C2", "C3", "C4"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "v1"), at(5)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "v2"), at(6)))
  expect_equal(r$state$worker$running$cell, "C3")
  # Run C2 again while C3 runs: C2 goes before C4, and makes C3 stale.
  r <- drive(r$state, ev_run("C2", at(7)))
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(created = "v3"), at(8)))
  expect_equal(r$state$worker$running$cell, "C2")
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(created = "v2"), at(9)))
  expect_equal(r$state$worker$running$cell, "C3")
  expect_equal(r$state$pending, "C4")
})

test_that("in autorun a reader the file change reruns runs its stale ancestors first, not with their old values (#437)", {
  # Found by the scheduling fuzz test with data files: B was left stale (its
  # upstream deleted), and R reran alone on the change, reading B's old j.
  s <- fake_state(list(S = cell(""), B = cell("j <- 2"), R = cell('d <- read.csv("d.csv")\nsum(d$x) + j')))
  r <- boot(s, c("B", "R"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "j"), at(5)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "d", data_seen = list("d.csv" = "v1")), at(6)))
  r$state$results$B$stale <- TRUE
  r2 <- drive(r$state, ev_data_changed(list("d.csv" = "v2"), at(21)))
  expect_equal(r2$state$worker$running$cell, "B")
  expect_equal(r2$state$pending, "R")
})

test_that("in lazy mode a run that reaches the writer after the reader reruns the reader before a queued cell that reads it (#437)", {
  # Run all: R reads d.csv, W writes it, U reads what R read. The change is
  # seen as W's result arrives, while U is still queued.
  s <- fake_state(list(S = cell(""), R = cell('d <- read.csv("d.csv")'),
                       W = cell('write.csv(data.frame(x = 1:3), "d.csv", row.names = FALSE)'),
                       U = cell("sum(d$x)")), on_cell_change = "lazy")
  r <- boot(s, c("R", "W", "U"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "d", data_seen = list("d.csv" = "v1")), at(5)))
  expect_equal(r$state$worker$running$cell, "W")
  r2 <- drive(r$state, ev_data_changed(list("d.csv" = "v2"), at(6)))
  expect_setequal(r2$state$pending, c("R", "U"))
  r3 <- drive(r2$state, wk_done(1, r2$state$worker$running$token, report(), at(7)))
  expect_equal(r3$state$worker$running$cell, "R")
  # A cell between the reader and the queued one, which ran before the
  # write, runs again too.
  s <- fake_state(list(S = cell(""), R = cell('d <- read.csv("d.csv")'), A = cell("e <- d"),
                       W = cell('write.csv(data.frame(x = 1:3), "d.csv", row.names = FALSE)'),
                       U = cell("sum(e$x)")), on_cell_change = "lazy")
  r <- boot(s, c("R", "A", "W", "U"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "d", data_seen = list("d.csv" = "v1")), at(5)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "e"), at(6)))
  r2 <- drive(r$state, ev_data_changed(list("d.csv" = "v2"), at(7)))
  expect_setequal(r2$state$pending, c("R", "A", "U"))
  # With nothing queued that reads it, lazy mode only marks it stale.
  r4 <- drive(data_file_notebook("lazy")$state, ev_data_changed(list("d.csv" = "v2"), at(21)))
  expect_equal(r4$state$pending, character())
})

test_that("a data file that changes while its reader is queued leaves the reader stale if a stop empties the queue (#472)", {
  # Run W and R by hand: W runs, R waits. d.csv changes, then a stop
  # empties the queue. R's result read the old file, so it and U, which
  # read R's value, are stale, and nothing more runs.
  for (mode in c("lazy", "autorun")) {
    r <- data_file_notebook(mode)
    r <- drive(r$state, ev_run(c("W", "R"), at(30)))
    expect_equal(r$state$worker$running$cell, "W")
    expect_equal(r$state$pending, "R")
    r <- drive(r$state, wk_running(1, r$state$worker$running$token, at(31)),
               ev_data_changed(list("d.csv" = "v2"), at(32)))
    expect_equal(r$state$pending, "R")
    expect_true(r$state$results$R$stale, info = mode)
    r <- drive(r$state, ev_interrupt(at(33)),
               wk_done(1, r$state$worker$running$token, report(status = "interrupted"), at(34)))
    expect_equal(r$state$pending, character(), info = mode)
    expect_true(r$state$results$R$stale, info = mode)
    expect_true(r$state$results$U$stale, info = mode)
  }
  # Not stopped, R runs and its new result is current.
  r <- data_file_notebook("lazy")
  r <- drive(r$state, ev_run(c("W", "R"), at(30)))
  r <- drive(r$state, ev_data_changed(list("d.csv" = "v2"), at(31)),
             wk_done(1, r$state$worker$running$token, report(), at(32)))
  expect_equal(r$state$worker$running$cell, "R")
  r <- drive(r$state, wk_done(1, r$state$worker$running$token, report(created = "d", data_seen = list("d.csv" = "v2")), at(33)))
  expect_false(isTRUE(r$state$results$R$stale))
})

test_that("a writer that runs right after its reader reruns the reader, however coarse the file clock (#276)", {
  # R sits above W: run all runs R, then W. W's write can carry a modified
  # time from before R's result arrived; only the version counts.
  s <- fake_state(list(S = cell(""), R = cell('d <- read.csv("d.csv")'),
                       W = cell('write.csv(data.frame(x = 1:3), "d.csv", row.names = FALSE)')))
  r <- boot(s, c("R", "W"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "d", data_seen = list("d.csv" = "v1")), at(5)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(5.004)))
  r2 <- drive(r$state, ev_data_changed(list("d.csv" = "v2"), at(6)))
  expect_equal(r2$state$worker$running$cell, "R")
})

test_that("in lazy mode a changed data file marks its reader and dependents stale, and runs nothing (#276)", {
  r <- data_file_notebook("lazy")
  r2 <- drive(r$state, ev_data_changed(list("d.csv" = "v2"), at(21)))
  expect_true(isTRUE(r2$state$results$R$stale))
  expect_true(isTRUE(r2$state$results$U$stale))
  expect_equal(r2$state$pending, character())
  expect_null(r2$state$worker$running)
})

test_that("a data file at the version its reader's result saw doesn't wake the reader (#276)", {
  # As when a cell writes the file it reads: its result saw its own write.
  r <- data_file_notebook()
  r2 <- drive(r$state, ev_data_changed(list("d.csv" = "v1"), at(10)))
  expect_false(isTRUE(r2$state$results$R$stale))
  expect_equal(r2$state$pending, character())
  expect_null(r2$state$worker$running)
})

test_that("a data file someone else changed while its reader ran makes the result stale, and autorun runs it again (#276)", {
  s <- fake_state(list(S = cell(""), R = cell('d <- read.csv("d.csv")'), U = cell("d")))
  r <- boot(s, c("R", "U"))
  # The poll's change, during the run, is left to the run's own report.
  r2 <- drive(r$state, ev_data_changed(list("d.csv" = "v2"), at(4)))
  expect_equal(r2$state$worker$running$cell, "R")
  expect_equal(r2$state$pending, "U")
  r3 <- drive(r2$state, wk_done(1, r2$state$worker$running$token,
                                report(created = "d", data_seen = list("d.csv" = "v2"), data_changed = "d.csv"), at(5)))
  expect_equal(r3$state$results$R$data_seen, list("d.csv" = "v2"))
  expect_equal(r3$state$worker$running$cell, "R")
  # A run that saw it again right after (a write Ember can't see, as
  # through a helper function) keeps its result: no loop.
  r4 <- drive(r3$state, wk_done(1, r3$state$worker$running$token,
                                report(created = "d", data_seen = list("d.csv" = "v3"), data_changed = "d.csv"), at(6)))
  expect_false(isTRUE(r4$state$results$R$stale))
  expect_equal(r4$state$worker$running$cell, "U")
  # A run that saw no one else's change is fresh, its own writes included.
  r5 <- drive(r2$state, wk_done(1, r2$state$worker$running$token,
                                report(created = "d", data_seen = list("d.csv" = "v2")), at(5)))
  expect_false(isTRUE(r5$state$results$R$stale))
  expect_equal(r5$state$worker$running$cell, "U")
})

test_that("in lazy mode a change during the run marks the result stale and runs nothing more for it (#276)", {
  s <- fake_state(list(S = cell(""), R = cell('d <- read.csv("d.csv")')), on_cell_change = "lazy")
  r <- boot(s, "R")
  r2 <- drive(r$state, wk_done(1, r$state$worker$running$token,
                               report(created = "d", data_seen = list("d.csv" = "v2"), data_changed = "d.csv"), at(5)))
  expect_true(isTRUE(r2$state$results$R$stale))
  expect_null(r2$state$worker$running)
})

test_that("a run message carries each data file with the expressions that read or write it (#276)", {
  s <- fake_state(list(S = cell(""),
                       R = cell('d <- read.csv("d.csv")\nm <- lm(y ~ x, d)\nwrite.csv(d, "d.csv")\nwriteLines("x", f)')))
  r <- boot(s, "R")
  msg <- last_sent(r)
  expect_equal(length(msg$data), 1)
  expect_equal(msg$data[[1]]$path, "d.csv")
  expect_equal(msg$data[[1]]$full, file.path(dirname(s$path), "d.csv"))
  expect_equal(msg$data[[1]]$touch, c(1L, 3L, 4L))
  expect_null(last_sent(boot(fake_state(list(S = cell(""), A = cell("1"))), "A"))$data)
})

test_that("a change to a file no cell reads does nothing (#276)", {
  r <- data_file_notebook()
  r2 <- drive(r$state, ev_data_changed(list("other.csv" = "v2"), at(21)))
  expect_identical(r2$state$results, r$state$results)
  expect_null(r2$state$worker$running)
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

  r <- drive(r$state, wk_running(1, r$state$worker$running$token, at(5)))
  r2 <- drive(r$state, ev_interrupt(at(10)))
  expect_equal(r2$state$pending, character())
  expect_true(any(vapply(r2$effects, function(e) identical(e$type, "interrupt"), logical(1))))
  expect_true(any(vapply(r2$effects, function(e) identical(e$type, "timer"), logical(1))))
})

test_that("an interrupt before the worker began the run is held until it does", {
  # The worker swallows an interrupt that lands before it began a run (it
  # can't tell it from a late one for the run before), so SIGINT waits for
  # the worker's "running".
  is_sigint <- function(effects) any(vapply(effects, function(e) identical(e$type, "interrupt"), logical(1)))
  s <- fake_state(list(S = cell(""), A = cell("Sys.sleep(3)")))
  r <- boot(s, "A")
  tok <- r$state$worker$running$token
  r2 <- drive(r$state, ev_interrupt(at(10)))
  expect_false(is_sigint(r2$effects))
  expect_true(any(vapply(r2$effects, function(e) identical(e$type, "timer"), logical(1))))
  expect_identical(r2$state$worker$interrupt$token, tok)

  expect_false(is_sigint(drive(r2$state, wk_running(1, tok + 1L, at(11)))$effects))
  expect_false(is_sigint(drive(r2$state, wk_running(2, tok, at(11)))$effects))
  r3 <- drive(r2$state, wk_running(1, tok, at(11)))
  expect_true(is_sigint(r3$effects))
  expect_true(r3$state$worker$running$begun)

  # Without an interrupt asked for, the run beginning sends nothing.
  expect_false(is_sigint(drive(r$state, wk_running(1, tok, at(11)))$effects))
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

test_that("a stop the running cell finishes before still stops its dependents in autorun (#486)", {
  # A stop that reaches the run in time gives "interrupted"; one that lands
  # just as it finishes gives "ok" or "error". Either way the dependents
  # the stop dropped stay stale, as Esc in plain R drops the lines waiting.
  s <- fake_state(list(S = cell(""), A = cell("a <- 1"), B = cell("b <- a")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "a"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))
  r <- drive(r$state, ev_run("A", at(12)))
  tok <- last_token(r)
  r <- drive(r$state, wk_running(1, tok, at(13)))
  # Without the stop, B runs again (37).
  expect_equal(drive(r$state, wk_done(1, tok, report(created = "a"), at(15)))$state$worker$running$cell, "B")
  r <- drive(r$state, ev_interrupt(at(14)))
  for (rep in list(report(created = "a"), report(status = "error", error = list(message = "boom")))) {
    r2 <- drive(r$state, wk_done(1, tok, rep, at(15)))
    expect_null(r2$state$worker$running)
    expect_equal(r2$state$pending, character())
    expect_true(isTRUE(r2$state$results$B$stale))
    expect_null(r2$state$worker$interrupt)
  }
  # A run asked for after the stop still runs.
  r5 <- drive(r$state, ev_run("B", at(15)), wk_done(1, tok, report(created = "a"), at(16)))
  expect_equal(r5$state$worker$running$cell, "B")
})

test_that("a run asked for after a stop still runs the ancestors the stopped cell made stale first (#486, #453)", {
  # A's first run created nothing, so M reads x only once A's next run
  # reports it. B, asked for after the stop, needs M rerun on the new x
  # first, as when a run is asked for (#453), whether A's run ended "ok"
  # after the stop or "interrupted".
  for (mode in c("autorun", "lazy")) {
    for (status in c("ok", "interrupted")) {
      info <- paste(mode, status)
      s <- fake_state(list(S = cell(""), A = cell('assign("x", 1, envir = globalenv())'),
                           M = cell("y <- if (exists('x')) x + 1 else 0"), B = cell("y * 2")),
                      on_cell_change = mode)
      r <- boot(s, c("A", "M", "B"))
      r <- drive(r$state, wk_done(1, last_token(r), report(), at(10)))
      r <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(11)))
      r <- drive(r$state, wk_done(1, last_token(r), report(), at(12)))
      r <- drive(r$state, ev_run("A", at(13)))
      tok <- last_token(r)
      r <- drive(r$state, wk_running(1, tok, at(14)), ev_interrupt(at(15)), ev_run("B", at(16)),
                 wk_done(1, tok, report(status = status, created = "x"), at(17)))
      expect_equal(r$state$worker$running$cell, "M", info = info)
      r <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(18)))
      expect_equal(r$state$worker$running$cell, "B", info = info)
      r <- drive(r$state, wk_done(1, last_token(r), report(), at(19)))
      expect_false(isTRUE(r$state$results$B$stale), info = info)
      expect_false(isTRUE(r$state$results$M$stale), info = info)
      expect_null(r$state$worker$running, info = info)
    }
  }
})

test_that("a stop the running cell finishes before doesn't rerun it for a data file changed during the run (#486)", {
  s <- fake_state(list(S = cell(""), R = cell('d <- read.csv("d.csv")')))
  r <- boot(s, "R")
  tok <- r$state$worker$running$token
  r <- drive(r$state, wk_running(1, tok, at(4)), ev_interrupt(at(5)))
  r2 <- drive(r$state, wk_done(1, tok, report(created = "d", data_seen = list("d.csv" = "v2"),
                                             data_changed = "d.csv"), at(6)))
  expect_true(isTRUE(r2$state$results$R$stale))
  expect_null(r2$state$worker$running)
  expect_equal(r2$state$pending, character())
})

test_that("a stale restart-offer timer does nothing (59)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1")))
  r <- boot(s, "A")
  tok <- r$state$worker$running$token
  r2 <- drive(r$state, wk_done(1, tok, report(), at(10)))  # finished before the timer fires
  r3 <- drive(r2$state, tm_offer_restart(1, tok, at(11)))
  expect_identical(r3$state, at_clock(r2$state, 11))
})

test_that("an interrupt that couldn't be delivered offers the restart at once and says so (#48)", {
  s <- fake_state(list(S = cell(""), A = cell("Sys.sleep(30)")))
  r <- boot(s, "A")
  tok <- r$state$worker$running$token
  r2 <- drive(r$state, ev_interrupt(at(10)))
  r3 <- drive(r2$state, wk_interrupt_failed(1, at(10.1)))
  expect_true(r3$state$worker$restart_offered)
  expect_true(r3$state$worker$interrupt$failed)
  expect_true(snapshot_of(r3$state)$interrupt_failed)

  # From an older worker, or once the run is over, it does nothing.
  expect_identical(drive(r2$state, wk_interrupt_failed(2, at(10.1)))$state, at_clock(r2$state, 10.1))
  r4 <- drive(r2$state, wk_done(1, tok, report(status = "interrupted"), at(10.1)))
  expect_identical(drive(r4$state, wk_interrupt_failed(1, at(10.2)))$state, at_clock(r4$state, 10.2))

  # The run ending clears it with the offer.
  r5 <- drive(r3$state, wk_done(1, tok, report(status = "interrupted"), at(12)))
  expect_false(r5$state$worker$restart_offered)
  expect_false(snapshot_of(r5$state)$interrupt_failed)
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

test_that("rerunning a chain marks each cell's dependents stale in linear time, not square (#316)", {
  # Every cell that starts marks all later cells stale again. The walk
  # looked names up in growing vectors and `union()`ed one cell at a time,
  # so one step grew with the square of the chain: about 20x from 250 to
  # 2000 cells (1 s a step at 2000), against about 7x now. Timed against
  # the smaller chain rather than a fixed budget (helper-perf.R).
  done <- function(r) function() step(r$state, perf_done(r))
  r <- time_ratio(done(perf_chain_rerun(2000)), done(perf_chain_rerun(250)), samples = 5L, inner_b = 4L)
  cat(sprintf("\n[timing] a step during a chain rerun: 2000 cells %.1f ms, 250 cells %.1f ms (%.1fx)\n",
              1000 * r$a, 1000 * r$b, r$ratio))
  expect_lt(r$ratio, 12)
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

test_that("reduce_render() sends render {cell, res} with no width or height (ui-3 66)", {
  s <- fake_state(list(S = cell(""), A = cell("plot(1)")))
  out <- new_display("image/png", "bytes", "[plot]", size = list(width = 1440, height = 960, res = 192))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(output = out), at(10)))

  r2 <- drive(r$state, ev_render("A", at(11), res = 288))
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

test_that("an edit drops learned definitions that would hold the cell in a cycle", {
  s <- fake_state(list(S = cell(""), A = cell("load('x.rda')"), B = cell("y <- x + 1")),
                  on_cell_change = "lazy")
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  expect_equal(r$state$graph$learned$definitions$A, "x")
  expect_true("A" %in% r$state$graph$upstream$B)

  # A no longer defines x and now reads B's y. Kept, the learned x would
  # make A <-> B a cycle neither cell can run its way out of.
  r <- drive(r$state, ev_apply(list(op_set_code("A", "load('z.rda'); w <- y")), at(20)))
  expect_null(r$state$graph$learned$definitions$A)
  expect_false("A" %in% r$state$graph$upstream$B)
  expect_true("B" %in% r$state$graph$upstream$A)
  expect_length(blocked_cells(r$state$graph), 0)

  # Nor does the reopened file bring it back.
  s2 <- reopen(r$state)
  expect_null(s2$graph$learned$definitions$A)
  expect_false("A" %in% s2$graph$upstream$B)
})

test_that("an edit drops a learned definition another cell now defines", {
  s <- fake_state(list(S = cell(""), A = cell("load('x.rda')"), B = cell("y <- x + 1")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  n1 <- "44444444-4444-4444-8444-444444444444"
  r <- drive(r$state, ev_apply(list(op_set_code("A", "load('z.rda')"),
                                    op_insert(n1, 2, "x <- 1")), at(20)))
  expect_null(r$state$graph$learned$definitions$A)
  expect_length(blocked_cells(r$state$graph), 0)
  expect_true(n1 %in% r$state$graph$upstream$B)
})

test_that("an edit keeps learned definitions that block nothing, so readers still wait for the cell", {
  s <- fake_state(list(S = cell(""), A = cell("load('f.rda')"), B = cell("summary(fits)")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "fits"), at(10)))
  r <- drive(r$state, wk_done(1, last_token(r), report(), at(11)))
  r <- drive(r$state, ev_apply(list(op_set_code("A", "load('g.rda')")), at(20)))
  expect_equal(r$state$graph$learned$definitions$A, "fits")
  # Running B runs the edited A first, as running any stale cell does.
  expect_equal(sent_cells(drive(r$state, ev_run("B", at(21)))), "A")
})

test_that("an edit keeps learned definitions, so the file is still written in run order", {
  s <- fake_state(list(S = cell(""), B = cell("summary(fits)"), A = cell("load('f.rda')")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "fits"), at(10)))
  expect_equal(r$state$graph$order, c("A", "S", "B"))
  r <- drive(r$state, ev_apply(list(op_set_code("A", "load('g.rda')")), at(20)))
  expect_equal(r$state$graph$order, c("A", "S", "B"))
  expect_equal(reopen(r$state)$graph$order, c("A", "S", "B"))
})

test_that("an edit that leaves the code as it was keeps the learned definitions", {
  s <- fake_state(list(S = cell(""), A = cell("load('f.rda')"), B = cell("summary(fits)")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "fits"), at(10)))
  r <- drive(r$state, ev_apply(list(op_set_code("A", "load('f.rda')"), op_fold("A", TRUE)), at(20)))
  expect_equal(r$state$graph$learned$definitions$A, "fits")
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
  expect_equal(err$message, "there is no package called 'cli': install failed")
})

# ---- A package the error names but the code doesn't (#184) -----------------

# A state whose CRAN index has glmnet, textdata, dplyr and MASS, with dplyr
# installed in the notebook's library and MASS in R's own.
named_state <- function(cells = list(A = cell("x <- 1"))) {
  s <- fake_state(cells)
  idx <- new_repo_index("cran/2026-09-01", "CRAN", c("glmnet", "textdata", "dplyr", "MASS", "lexicon2"),
                        rep("1.0", 5), rep(list(character()), 5), rep(FALSE, 5))
  s$packages$indexes[["cran/2026-09-01"]] <- new_index_slot("ready", index = idx)
  s$packages$active$installed <- c(dplyr = "1.1.4")
  s
}

test_that("a message saying a package is needed offers to add it, and only then (#184)", {
  s <- named_state()
  # parsnip's set_engine("glmnet"), and tidytext's get_sentiments("afinn").
  # As parsnip's message reads in the worker, which turns cli's colours on (trial 5).
  expect_equal(packages_named_in(s, "Package install is required for \033[34mglmnet\033[39m."), "glmnet")
  # Without the colours nothing marks it as a package.
  expect_equal(packages_named_in(s, "Package install is required for glmnet."), character())
  expect_equal(packages_named_in(s, "The textdata package is required to download the AFINN lexicon."), "textdata")
  # Installed: in the notebook's library, or R's own (MASS is recommended).
  expect_equal(packages_named_in(s, "The dplyr package is required."), character())
  expect_equal(packages_named_in(s, "The MASS package is required."), character())
  # "package" next to a word that is no package, or a name in the index without "package".
  expect_equal(packages_named_in(s, "could not find the package lexicon"), character())
  expect_equal(packages_named_in(s, "object 'glmnet' not found"), character())
  # Part of a longer word or name.
  expect_equal(packages_named_in(s, "the packages 'glmnet2' and 'glmnet_cv' and 'my.glmnet' are required"), character())
  # Ordinary words that are CRAN packages ("not", "here") count only where the
  # message marks them as one.
  n <- named_state()
  idx <- n$packages$indexes[["cran/2026-09-01"]]$index
  n$packages$indexes[["cran/2026-09-01"]]$index <- new_repo_index("cran/2026-09-01", "CRAN",
    c(idx$name, "not", "here", "and"), c(idx$version, "1", "1", "1"), c(idx$deps, list(character(), character(), character())),
    c(idx$needs_compilation, FALSE, FALSE, FALSE))
  expect_equal(packages_named_in(n, "Package 'glmnet' is not installed."), "glmnet")
  expect_equal(packages_named_in(n, "Package \u2018glmnet\u2019 and its friends are not installed here."), "glmnet")
  expect_equal(packages_named_in(n, "No package here and not now."), character())
  # A word before "package" counts only when nothing is quoted ("optional" is on CRAN).
  n$packages$indexes[["cran/2026-09-01"]]$index <- new_repo_index("cran/2026-09-01", "CRAN",
    c(idx$name, "not", "here", "and", "optional", "ranger"), c(idx$version, rep("1", 5)),
    c(idx$deps, rep(list(character()), 5)), c(idx$needs_compilation, rep(FALSE, 5)))
  expect_equal(packages_named_in(n, "The optional package \"ranger\" is required."), "ranger")
  expect_equal(packages_named_in(n, "The ranger package is required."), "ranger")
  # rlang's message for check_installed(c("glmnet", "rlang"), version = c(NA, "99.0")):
  # the worker names neither, and the quoted glmnet still gets its fix.
  expect_equal(packages_named_in(n, "The packages \"glmnet\" and \"rlang\" (>= 99.0) are required."), "glmnet")
  # Translated: no match, no fix.
  expect_equal(packages_named_in(s, "Le paquet glmnet est requis."), character())
  # Already named in the code: adding it again would do nothing.
  w <- named_state(list(A = cell("library(glmnet)")))
  expect_equal(packages_named_in(w, "Package install is required for glmnet."), character())

  # Through a run: the error keeps its kind and text, with the fix added.
  r <- drive(s, ev_run("A", at(1)), wk_started(1, 99, at(2)), wk_hello(1, list(), at(3)))
  r <- drive(r$state, wk_done(r$state$worker$gen, r$state$worker$running$token, report(
    error = list(message = "Package install is required for \033[34mglmnet\033[39m.")), at(4)))
  err <- r$state$results$A$error
  expect_equal(err$kind, "error")
  expect_equal(err$message, "Package install is required for \033[34mglmnet\033[39m.")
  expect_equal(err$fixes, "Add glmnet to [extra_packages]")
})

test_that("rlang's check_installed() error is a missing package, with each one's fix (#184)", {
  s <- named_state()
  r <- drive(s, ev_run("A", at(1)), wk_started(1, 99, at(2)), wk_hello(1, list(), at(3)))
  r <- drive(r$state, wk_done(r$state$worker$gen, r$state$worker$running$token, report(
    error = list(message = "The packages \"glmnet\" and \"textdata\" are required.", package = c("glmnet", "textdata"))), at(4)))
  err <- r$state$results$A$error
  expect_equal(err$kind, "missing_package")
  expect_equal(err$names, c("glmnet", "textdata"))
  expect_equal(err$fixes, c("Add glmnet to [extra_packages]", "Add textdata to [extra_packages]"))
})

test_that("while a package installs, a cell calling its functions waits for it instead of failing first (#67)", {
  # Before dplyr is installed its exports are unknown, so B has no edge to
  # A. B's `summarise` resolves to nothing, so B waits for dplyr with A;
  # C reads only base R and a dataset, so it still runs.
  lock <- new_lock(name = "dplyr", version = "1.1.4", source = "CRAN")
  s <- fake_state(list(A = cell("library(dplyr)"), B = cell("x <- summarise(mtcars, m = mean(mpg))"),
                       C = cell("n <- nrow(mtcars)")), lock = lock)
  expect_false("A" %in% s$graph$upstream$B)
  w <- waiting_cells(s)
  expect_equal(w$A, "dplyr")
  expect_equal(w$B, "dplyr")
  expect_null(w$C)

  r <- drive(s, ev_run(NULL, at(1)), wk_started(1, 99, at(2)), wk_hello(1, list(), at(3)))
  expect_equal(r$state$worker$running$cell, "C")

  # Once dplyr's exports are known, B's wait comes from its edge to A.
  s2 <- s
  s2$exports <- list(dplyr = "summarise")
  s2 <- rebuild_graph(s2)
  expect_true("A" %in% s2$graph$upstream$B)
  expect_equal(waiting_cells(s2)$B, "dplyr")

  # A failed install releases B too: it runs after A and shows R's own error,
  # while A carries the install failure.
  key <- s$packages$target$key
  r <- drive(s, ev_run(NULL, at(1)), wk_started(1, 99, at(2)), wk_hello(1, list(), at(3)))
  expect_true("B" %in% r$state$pending)
  r <- drive(r$state, ev_library_checked(key, NULL, at(4)))
  expect_true("B" %in% r$state$pending)
  tok <- r$state$packages$install$token
  r <- drive(r$state, ev_install_done(tok, key, NULL, "install failed", character(), at(5),
                                      failures = data.frame(package = "dplyr", kind = "build_error",
                                                            detail = "boom", stringsAsFactors = FALSE)))
  expect_equal(r$state$packages$target$status, "failed")
  ran <- character()
  for (i in 1:4) {
    cell <- r$state$worker$running$cell
    if (is.null(cell)) break
    ran <- c(ran, cell)
    err <- if (cell == "A") list(message = "there is no package called 'dplyr'", package = "dplyr")
           else if (cell == "B") list(message = 'could not find function "summarise"') else NULL
    r <- drive(r$state, wk_done(r$state$worker$gen, r$state$worker$running$token,
                                report(error = err), at(6 + i)))
  }
  expect_true(all(c("A", "B") %in% ran))
  expect_lt(match("A", ran), match("B", ran))
  expect_equal(r$state$results$A$error$kind, "missing_package")
  expect_match(r$state$results$B$error$message, "could not find function")

  # Nothing installing, nothing held: a typo alone doesn't wait.
  s3 <- fake_state(list(A = cell("x <- summarse(mtcars)")))
  expect_null(waiting_cells(s3)$A)
})

test_that("missing_package_error() for a locked, uninstalled package points at the install failure", {
  lock <- new_lock(name = "cli", version = "3.6.0", source = "CRAN")
  s <- fake_state(list(S = cell(""), A = cell("library(cli)")), lock = lock)
  s$packages$target$status <- "failed"

  out <- missing_package_error(s, "cli")
  expect_equal(out$error$kind, "missing_package")
  expect_match(out$error$message, "there is no package called 'cli'; its install may have failed")
})

test_that("a failed install's cell error says why it failed, as package_status() does (#182)", {
  # Before, the cell said only "its install may have failed", though the
  # Packages status named the missing system libraries and the command.
  lock <- new_lock(name = c("s2", "sf", "units"), version = c("1.1.9", "1.0-21", "0.8-7"), source = rep("CRAN", 3))
  s <- fake_state(list(A = cell("library(sf)")), lock = lock)
  key <- s$packages$target$key
  why <- paste("install failed:\nError: sf, units need system libraries that aren't installed (libgdal.so.34, libudunits2.so.0).",
               "Install them with `apt-get install -y libgdal-dev libudunits2-dev`, then try again.")
  r <- drive(s, ev_run("A", at(1)), wk_started(1, 99, at(2)), wk_hello(1, list(), at(3)))
  r <- drive(r$state, ev_library_checked(key, NULL, at(4)))
  tok <- r$state$packages$install$token
  r <- drive(r$state, ev_install_done(tok, key, NULL, why, character(), at(5),
                                      failures = data.frame(package = c("units", "sf"), kind = "system_library",
                                                            detail = "", stringsAsFactors = FALSE)))
  r <- drive(r$state, wk_done(r$state$worker$gen, r$state$worker$running$token, report(
    error = list(message = "there is no package called 'sf'", package = "sf")), at(6)))
  err <- r$state$results$A$error
  expect_equal(err$kind, "missing_package")
  expect_equal(err$message, paste0("there is no package called 'sf': ", why))
  expect_equal(packages_view(r$state)$problems$message[[1]], why)

  # A package the install didn't get to, though it didn't fail itself, says why too.
  out <- missing_package_error(r$state, "s2")
  expect_equal(out$error$message, paste0("there is no package called 's2': ", why))
})

# ---- Prompts (#186) --------------------------------------------------------------

test_that("a prompt waits on the running cell until answered, and the answer goes to the worker (#186)", {
  s <- fake_state(list(S = cell(""), A = cell('x <- readline("Name? ")')))
  r <- boot(s, "A")
  tok <- last_token(r)
  r <- drive(r$state, wk_running(1, tok, at(9)), wk_input(1, tok, 1L, "Name? ", NULL, at(10)))
  expect_equal(r$state$worker$running$prompt, list(id = 1L, text = "Name? ", choices = NULL))
  view <- Find(function(v) identical(v$id, "A"), snapshot_of(r$state)$cells)
  expect_equal(view$prompt$text, "Name? ")
  expect_true(view$running)

  r2 <- drive(r$state, ev_answer_input("Ada", at(11), cell = "A"))
  expect_true(r2$reply)
  expect_equal(last_sent(r2), list(type = "input_reply", id = 1L, text = "Ada"))
  expect_null(r2$state$worker$running$prompt)
  # Answered once: a second answer has no prompt to go to.
  r3 <- drive(r2$state, ev_answer_input("again", at(12)))
  expect_s3_class(r3$reply, "ember_refused")
  expect_length(r3$effects, 0)
})

test_that("an answer is refused for another cell, or when it isn't one string (#186)", {
  s <- fake_state(list(S = cell(""), A = cell('x <- readline("Name? ")'), B = cell("1")))
  r <- boot(s, "A")
  tok <- last_token(r)
  r <- drive(r$state, wk_input(1, tok, 1L, "Name? ", NULL, at(10)))
  expect_s3_class(drive(r$state, ev_answer_input("Ada", at(11), cell = "B"))$reply, "ember_refused")
  expect_s3_class(drive(r$state, ev_answer_input(c("a", "b"), at(11)))$reply, "ember_refused")
  expect_s3_class(drive(r$state, ev_answer_input(NA_character_, at(11)))$reply, "ember_refused")
  expect_false(is.null(r$state$worker$running$prompt))
})

test_that("an answer that names its prompt is refused once that prompt has gone (#186)", {
  s <- fake_state(list(S = cell(""), A = cell('x <- menu(c("a", "b"))')))
  r <- boot(s, "A")
  tok <- last_token(r)
  # menu() asked again after a bad answer: an answer typed for the first question isn't given to the second.
  r <- drive(r$state, wk_input(1, tok, 2L, "Selection: ", c("a", "b"), at(10)))
  stale <- drive(r$state, ev_answer_input("1", at(11), id = 1L))
  expect_s3_class(stale$reply, "ember_refused")
  expect_match(conditionMessage(stale$reply), "already answered", fixed = TRUE)
  expect_length(stale$effects, 0)
  ok <- drive(r$state, ev_answer_input("1", at(11), id = 2L))
  expect_true(isTRUE(ok$reply))
  expect_equal(last_sent(ok), list(type = "input_reply", id = 2L, text = "1"))
})

test_that("a prompt from an older run or worker is ignored, and one that closes or ends with the run goes (#186)", {
  s <- fake_state(list(S = cell(""), A = cell('x <- readline("Name? ")')))
  r <- boot(s, "A")
  tok <- last_token(r)
  expect_null(drive(r$state, wk_input(2, tok, 1L, "Name? ", NULL, at(10)))$state$worker$running$prompt)
  expect_null(drive(r$state, wk_input(1, tok + 1L, 1L, "Name? ", NULL, at(10)))$state$worker$running$prompt)

  r <- drive(r$state, wk_input(1, tok, 1L, "Name? ", NULL, at(10)))
  # A close for another prompt leaves this one.
  expect_false(is.null(drive(r$state, wk_input_closed(1, tok, 2L, at(11)))$state$worker$running$prompt))
  expect_null(drive(r$state, wk_input_closed(1, tok, 1L, at(11)))$state$worker$running$prompt)
  # The run ends (interrupted): nothing waits.
  r2 <- drive(r$state, wk_done(1, tok, report(status = "interrupted"), at(12)))
  expect_null(r2$state$worker$running)
  expect_s3_class(drive(r2$state, ev_answer_input("late", at(13)))$reply, "ember_refused")
})

test_that("deleting the cell that waits on a prompt interrupts it, so the worker is free again (#452)", {
  s <- fake_state(list(S = cell(""), A = cell("x <- 1"), B = cell('y <- readline("Name? ")')))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(5)))
  tok <- last_token(r)
  r <- drive(r$state, wk_running(1, tok, at(6)), wk_input(1, tok, 1L, "Name? ", NULL, at(7)))
  r2 <- drive(r$state, ev_apply(list(op_delete("B")), at(8)))
  expect_null(r2$state$worker$running$prompt)
  expect_true(any(vapply(r2$effects, function(e) identical(e$type, "interrupt"), logical(1))))
  r3 <- drive(r2$state, wk_done(1, tok, report(status = "interrupted"), at(9)))
  expect_equal(r3$state$worker$status, "ready")
  expect_null(r3$state$results$B)
  # A cell deleted while it runs without asking isn't interrupted: its run is discarded as before.
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(5)))
  r2 <- drive(r$state, ev_apply(list(op_delete("B")), at(8)))
  expect_false(any(vapply(r2$effects, function(e) identical(e$type, "interrupt"), logical(1))))
})

test_that("the page's projection carries the prompt and updates when only the prompt changes (#186)", {
  s <- fake_state(list(S = cell(""), A = cell('pick <- menu(c("red", "blue"))')))
  r <- boot(s, "A")
  tok <- last_token(r)
  r <- drive(r$state, wk_running(1, tok, at(9)))
  before <- pluto_state(r$state)
  r2 <- drive(r$state, wk_input(1, tok, 3L, "Selection: ", c("red", "blue"), at(10)))
  after <- pluto_state(r2$state, previous = before)
  expect_equal(after$js$cell_results$A$ember$prompt,
               list(id = 3L, text = "Selection: ", choices = list("red", "blue")))
  expect_null(before$js$cell_results$A$ember$prompt)
  # Built from scratch, the same.
  expect_equal(after$js$cell_results$A, pluto_state(r2$state)$js$cell_results$A)
})
