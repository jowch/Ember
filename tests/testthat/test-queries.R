# Tests for the read-only query functions over a built ember_graph
# (R/queries.R): upstream/downstream, run_order, affected, cell_summary,
# blocked_cells and changed_cells. Uses the same fake_cell()/
# build_test_graph() helpers as test-graph.R (tests/testthat/helper-graph.R).

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
