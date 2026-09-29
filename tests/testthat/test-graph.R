# Tests for R/graph.R. read_cell() isn't implemented yet, so these build
# ember_cell_analysis values with fake_cell() (tests/testthat/helper-graph.R)
# instead of reading real code, and feed them through build_test_graph(),
# which passes them to notebook_graph() as a `previous` so they're reused
# without calling read_cell(). Tests that must exercise a real read_cell()
# call (the reuse/reread machinery) stub it with local_mocked_bindings().

# ---- Edges: definitions and packages ---------------------------------------

test_that("a reference to another cell's definition gets a definition edge", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "x"),
    B = fake_cell(code = "B", refs = "x")
  ), setup = "A")
  expect_true("A" %in% upstream(g, "B"))
  expect_true(any(g$edges$from == "B" & g$edges$to == "A" &
                    g$edges$name == "x" & g$edges$via == "definition"))
})

test_that("a reference to a package export gets a package edge", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", attaches = "dplyr"),
    B = fake_cell(code = "B", refs = "mutate")
  ), setup = "A", exports = list(dplyr = c("mutate", "filter")))
  expect_true(any(g$edges$from == "B" & g$edges$to == "A" &
                    g$edges$name == "mutate" & g$edges$via == "package"))
})

test_that("a global definition shadows a package export", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "filter"),
    B = fake_cell(code = "B", attaches = "dplyr"),
    C = fake_cell(code = "C", refs = "filter")
  ), setup = "A", exports = list(dplyr = "filter"))
  expect_equal(upstream(g, "C"), "A")
  expect_false(any(g$edges$from == "C" & g$edges$to == "B"))
})

test_that("every non-setup cell gets a setup edge", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", defs = "x"),
    C = fake_cell(code = "C", refs = "x")
  ), setup = "A")
  expect_true("A" %in% upstream(g, "B"))
  expect_true("A" %in% upstream(g, "C"))
  expect_true(any(g$edges$from == "B" & g$edges$to == "A" & g$edges$via == "setup"))
  expect_false(any(g$edges$from == "A" & g$edges$to == "A"))
})

test_that("a cell reading its own name gets no self edge", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "s", refs = "s")
  ), setup = "A")
  expect_equal(nrow(g$edges), 0)
  expect_length(g$errors, 0)
})

# ---- Multiple definitions ---------------------------------------------------

test_that("two plain definitions of the same name are an error on both cells", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "x"),
    B = fake_cell(code = "B", defs = "x")
  ), setup = "A")
  errs <- Filter(function(e) e$kind == "multiple_definitions", g$errors)
  expect_length(errs, 1)
  expect_setequal(errs[[1]]$cells, c("A", "B"))
  expect_equal(errs[[1]]$names, "x")
  expect_true("A" %in% cell_errors(g, "A")[[1]]$cells)
  expect_true("B" %in% cell_errors(g, "B")[[1]]$cells)
})

test_that("a replacement definition gives the 'name the result' fix", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "df"),
    B = fake_cell(code = "B", defs = "df", kinds = "replacement")
  ), setup = "A")
  err <- Filter(function(e) e$kind == "multiple_definitions", g$errors)[[1]]
  expect_equal(err$fixes,
              "Move the line into the cell that defines df, or name the result (df2 <- ...)")
})

test_that("two 'for' definitions give the private-name fix", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "i", kinds = "for"),
    B = fake_cell(code = "B", defs = "i", kinds = "for")
  ), setup = "A")
  err <- Filter(function(e) e$kind == "multiple_definitions", g$errors)[[1]]
  expect_equal(err$fixes, "Use a private name: .i")
})

test_that("private names in a 'for' loop in two cells don't collide", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = ".i", kinds = "for"),
    B = fake_cell(code = "B", defs = ".i", kinds = "for")
  ), setup = "A")
  expect_length(Filter(function(e) e$kind == "multiple_definitions", g$errors), 0)
  expect_length(g$errors, 0)
})

# ---- Private names -----------------------------------------------------------

test_that("using another cell's private name is an error with no edge", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = ".tmp"),
    B = fake_cell(code = "B", refs = ".tmp")
  ), setup = "A")
  err <- Filter(function(e) e$kind == "private_name", g$errors)
  expect_length(err, 1)
  expect_equal(err[[1]]$cells, "B")
  expect_equal(err[[1]]$names, ".tmp")
  expect_equal(err[[1]]$fixes, "Drop the dot: tmp")
  expect_false(any(g$edges$from == "B" & g$edges$to == "A" & g$edges$via == "definition"))
})

# ---- Global settings ---------------------------------------------------------

test_that("a setting call outside the setup cell is an error", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", settings = "options")
  ), setup = "A")
  err <- Filter(function(e) e$kind == "global_setting", g$errors)
  expect_length(err, 1)
  expect_equal(err[[1]]$cells, "B")
  expect_equal(err[[1]]$fixes,
              "Move it to the setup cell, or use withr::with_options() for one piece of code")
})

test_that("a setting call in the setup cell is fine", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", settings = "options"),
    B = fake_cell(code = "B")
  ), setup = "A")
  expect_length(Filter(function(e) e$kind == "global_setting", g$errors), 0)
})

# ---- Cycles -------------------------------------------------------------------

test_that("a two-cell cycle is one error naming both names", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "a", refs = "b"),
    B = fake_cell(code = "B", defs = "b", refs = "a")
  ), setup = "A")
  errs <- Filter(function(e) e$kind == "cycle", g$errors)
  expect_length(errs, 1)
  expect_equal(errs[[1]]$cells, c("A", "B"))
  expect_setequal(errs[[1]]$names, c("a", "b"))
})

test_that("a three-cell cycle is one error naming all three cells", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "a", refs = "c"),
    B = fake_cell(code = "B", defs = "b", refs = "a"),
    C = fake_cell(code = "C", defs = "c", refs = "b")
  ), setup = "A")
  errs <- Filter(function(e) e$kind == "cycle", g$errors)
  expect_length(errs, 1)
  expect_equal(errs[[1]]$cells, c("A", "B", "C"))
})

test_that("the setup cell can be part of a cycle", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "z", refs = "w"),
    B = fake_cell(code = "B", defs = "w")
  ), setup = "A")
  errs <- Filter(function(e) e$kind == "cycle", g$errors)
  expect_length(errs, 1)
  expect_setequal(errs[[1]]$cells, c("A", "B"))
})

test_that("cycle members can't run", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "a", refs = "b"),
    B = fake_cell(code = "B", defs = "b", refs = "a")
  ), setup = "A")
  expect_setequal(blocked_cells(g), c("A", "B"))
})

test_that("graph_learn can add and clear a cycle", {
  g0 <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "fit"),
    B = fake_cell(code = "B", defs = "x")
  ), setup = "A")
  expect_length(Filter(function(e) e$kind == "cycle", g0$errors), 0)

  g1 <- graph_learn(g0, "A", references = "x")
  expect_length(Filter(function(e) e$kind == "cycle", g1$errors), 1)

  g2 <- graph_learn(g1, "A", references = character())
  expect_length(Filter(function(e) e$kind == "cycle", g2$errors), 0)
})

# ---- Run order ----------------------------------------------------------------

test_that("the setup cell always runs first", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B"),
    C = fake_cell(code = "C")
  ), setup = "A")
  expect_equal(g$order[1], "A")
})

test_that("package-attaching cells run before the rest, in display order", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", refs = "x"),
    B = fake_cell(code = "B", attaches = "ggplot2"),
    C = fake_cell(code = "C", defs = "x"),
    D = fake_cell(code = "D")
  ), setup = "A")
  expect_equal(g$order, c("A", "B", "C", "D"))
})

test_that("with no forcing edges, run order is display order", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B"),
    C = fake_cell(code = "C")
  ), setup = "A")
  expect_equal(g$order, c("A", "B", "C"))
})

test_that("a cell moves only when an edge forces it", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", refs = c("x", "y")),
    C = fake_cell(code = "C", defs = "x"),
    D = fake_cell(code = "D", defs = "y")
  ), setup = "A")
  expect_equal(g$order, c("A", "C", "D", "B"))
})

test_that("a markdown (empty-code) cell keeps its place beside its neighbours", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "x"),
    M = fake_cell(code = ""),
    B = fake_cell(code = "B", refs = "x")
  ), setup = "A")
  expect_equal(g$order, c("A", "M", "B"))
})

test_that("markdown cells stay anchored to their next neighbour when a package-attaching cell pulls it forward", {
  # Display order s, md1, a, md2, b; b attaches dplyr and uses a's name, so
  # the package-first pass would otherwise pull a and b ahead of md1/md2,
  # stranding both markdown cells at the end (run order s a b md1 md2).
  # The rule: each markdown cell is placed immediately before the next
  # non-markdown cell in display order, whenever that cell is emitted.
  g <- build_test_graph(list(
    s = fake_cell(code = "s"),
    md1 = fake_cell(code = "   "),
    a = fake_cell(code = "a", defs = "x"),
    md2 = fake_cell(code = ""),
    b = fake_cell(code = "b", refs = "x", attaches = "dplyr")
  ), setup = "s", exports = list(dplyr = "mutate"))
  expect_equal(g$order, c("s", "md1", "a", "md2", "b"))
})

test_that("trailing markdown cells after the last code cell go at the end in display order", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "x"),
    B = fake_cell(code = "B", refs = "x"),
    md1 = fake_cell(code = ""),
    md2 = fake_cell(code = "  ")
  ), setup = "A")
  expect_equal(g$order, c("A", "B", "md1", "md2"))
})

test_that("cycle members appear in display order within the run order", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", defs = "b", refs = "c"),
    C = fake_cell(code = "C", defs = "c", refs = "b")
  ), setup = "A")
  expect_equal(which(g$order == "B") + 1, which(g$order == "C"))
})

test_that("run order is always a permutation of the cell ids", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", defs = "b", refs = "c"),
    C = fake_cell(code = "C", defs = "c", refs = "b"),
    D = fake_cell(code = "D", attaches = "dplyr"),
    E = fake_cell(code = "")
  ), setup = "A")
  expect_setequal(g$order, g$ids)
  expect_length(g$order, length(g$ids))
})

# ---- Upstream / downstream -----------------------------------------------------

test_that("upstream and downstream give direct and transitive neighbours", {
  g <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x"),
    B = fake_cell(code = "B", defs = "y", refs = "x"),
    C = fake_cell(code = "C", refs = "y")
  ), setup = "S")
  expect_setequal(upstream(g, "B"), c("S", "A"))
  expect_setequal(upstream(g, "C", transitive = TRUE), c("S", "A", "B"))
  expect_equal(downstream(g, "A"), "B")
  expect_setequal(downstream(g, "A", transitive = TRUE), c("B", "C"))
})

test_that("transitive upstream and downstream come back in run order", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", defs = "c", refs = "a"),
    C = fake_cell(code = "C", defs = "a"),
    D = fake_cell(code = "D", refs = "c")
  ), setup = "A")
  expect_equal(upstream(g, "D", transitive = TRUE), run_order(g, c("A", "B", "C")))
  expect_equal(downstream(g, "C", transitive = TRUE), run_order(g, c("B", "D")))
})

test_that("run_order(ids) sorts a subset by the notebook's run order", {
  g <- build_test_graph(list(
    A = fake_cell(code = ""),
    B = fake_cell(code = "B", refs = c("a", "b")),
    C = fake_cell(code = "C", defs = "a"),
    D = fake_cell(code = "D", defs = "b")
  ), setup = "A")
  expect_equal(run_order(g, c("D", "B", "A")), c("A", "D", "B"))
})

# ---- affected() -----------------------------------------------------------------

test_that("affected() includes downstream cells in the new graph", {
  mk <- function(a_code) list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = a_code, defs = "x"),
    B = fake_cell(code = "B", defs = "y", refs = "x"),
    C = fake_cell(code = "C", refs = "y"),
    D = fake_cell(code = "D")
  )
  old <- build_test_graph(mk("A"), setup = "S")
  new <- build_test_graph(mk("A2"), setup = "S")
  expect_setequal(affected(old, new, "A"), c("A", "B", "C"))
  expect_false("D" %in% affected(old, new, "A"))
})

test_that("affected() includes a cell whose old edge the edit removed", {
  old <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x"),
    B = fake_cell(code = "B", refs = "x")
  ), setup = "S")
  # A no longer defines x: B's edge to A disappears in `new`, but B still
  # holds a result computed from the old x, so it must still rerun.
  new <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A2"),
    B = fake_cell(code = "B", refs = "x")
  ), setup = "S")
  expect_false("A" %in% upstream(new, "B"))
  expect_setequal(affected(old, new, "A"), c("A", "B"))
})

# ---- graph_learn() ----------------------------------------------------------

test_that("a learned definition joins the multiple-definitions rule", {
  g0 <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", defs = "fits")
  ), setup = "A")
  expect_length(g0$errors, 0)

  g1 <- graph_learn(g0, "A", definitions = "fits")
  err <- Filter(function(e) e$kind == "multiple_definitions", g1$errors)
  expect_length(err, 1)
  expect_setequal(err[[1]]$cells, c("A", "B"))
})

test_that("dropping a learned name removes the edge it created", {
  g0 <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", refs = "fits")
  ), setup = "S")
  g1 <- graph_learn(g0, "A", definitions = "fits")
  expect_true("A" %in% upstream(g1, "B"))

  g2 <- graph_learn(g1, "A", definitions = character())
  expect_false("A" %in% upstream(g2, "B"))
})

test_that("a learned reference adds an edge", {
  g0 <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "fit"),
    B = fake_cell(code = "B", defs = "z")
  ), setup = "A")
  expect_false("B" %in% upstream(g0, "A"))

  g1 <- graph_learn(g0, "A", references = "z")
  expect_true("B" %in% upstream(g1, "A"))
})

test_that("cell_summary reports learned definitions separately from static ones", {
  g0 <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", refs = "fits")
  ), setup = "A")
  g1 <- graph_learn(g0, "A", definitions = "fits")
  s <- cell_summary(g1, "A")
  expect_equal(s$learned, "fits")
  expect_equal(s$definitions, character())
})

# ---- Previous reuse -----------------------------------------------------------

test_that("rereading only the changed cell leaves other analyses untouched", {
  a_analysis <- fake_cell(code = "x <- 1", defs = "x")
  b_analysis_old <- fake_cell(code = "y <- x", refs = "x")
  previous <- build_test_graph(list(A = a_analysis, B = b_analysis_old), setup = "A")

  testthat::local_mocked_bindings(
    read_cell = function(code, read_file = NULL) fake_cell(code = code, refs = "x")
  )
  new_cells <- c(A = "x <- 1", B = "y <- x + 1")
  g <- notebook_graph(new_cells, setup = "A", previous = previous, read_file = NULL)

  expect_equal(g$reread, "B")
  expect_identical(g$analyses[["A"]], a_analysis)
})

test_that("passing previous never changes the result", {
  testthat::local_mocked_bindings(
    read_cell = function(code, read_file = NULL) fake_cell(code = code, defs = "x")
  )
  cells <- c(A = "x <- 1", B = "y <- 2")
  fresh <- notebook_graph(cells, setup = "A", read_file = NULL)
  previous <- fresh
  again <- notebook_graph(cells, setup = "A", previous = previous, read_file = NULL)

  expect_identical(fresh$order, again$order)
  expect_identical(fresh$edges, again$edges)
  expect_identical(fresh$cells, again$cells)
  expect_length(again$reread, 0)
})

test_that("unknown learned ids are dropped", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B")
  ), setup = "A", learned = list(definitions = list(ghost = "x")))
  expect_false("ghost" %in% names(g$learned$definitions))
})

# ---- changed_cells() ----------------------------------------------------------

test_that("changed_cells reports a cell whose definitions changed and its neighbour", {
  old <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "x"),
    B = fake_cell(code = "B", refs = "x")
  ), setup = "A")
  new <- build_test_graph(list(
    A = fake_cell(code = "A2", defs = "x", attaches = "dplyr"),
    B = fake_cell(code = "B", refs = "x")
  ), setup = "A")
  changed <- changed_cells(old, new)
  expect_true("A" %in% changed)
})

test_that("changed_cells is empty for an unchanged rebuild", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "x"),
    B = fake_cell(code = "B", refs = "x")
  ), setup = "A")
  expect_length(changed_cells(g, g), 0)
})

test_that("changed_cells includes a cell deleted from the new graph", {
  old <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", defs = "x"),
    C = fake_cell(code = "C", refs = "x")
  ), setup = "A")
  new <- build_test_graph(list(
    A = fake_cell(code = "A"),
    C = fake_cell(code = "C", refs = "x")
  ), setup = "A")
  changed <- changed_cells(old, new)
  expect_true("B" %in% changed)
})

test_that("changed_cells includes a cell added in the new graph", {
  old <- build_test_graph(list(
    A = fake_cell(code = "A")
  ), setup = "A")
  new <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", defs = "x")
  ), setup = "A")
  changed <- changed_cells(old, new)
  expect_true("B" %in% changed)
})

# ---- cell_summary() and blocked_cells() ----------------------------------------

test_that("cell_summary lists definitions, references, packages and neighbours", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", attaches = "dplyr"),
    B = fake_cell(code = "B", defs = "y", refs = "mutate")
  ), setup = "A", exports = list(dplyr = "mutate"))
  s <- cell_summary(g, "B")
  expect_equal(s$definitions, "y")
  expect_equal(s$upstream, "A")
  expect_equal(s$downstream, character())
})

test_that("blocked_cells collects ids across different error kinds", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", defs = "x"),
    C = fake_cell(code = "C", defs = "x"),
    D = fake_cell(code = "D", settings = "options")
  ), setup = "A")
  expect_setequal(blocked_cells(g), c("B", "C", "D"))
})

# ---- Parse errors ---------------------------------------------------------------

test_that("a cell with a parse error keeps its setup edge and has no definitions", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", parse_error = list(message = "unexpected end of input",
                                                 line = 1L, column = 5L))
  ), setup = "A")
  expect_true("A" %in% upstream(g, "B"))
  expect_equal(g$cells[["B"]]$definitions, character())
  errs <- Filter(function(e) e$kind == "parse", g$errors)
  expect_length(errs, 1)
  expect_equal(errs[[1]]$cells, "B")
})
