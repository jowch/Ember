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

# ---- Mixed text and code (ui-3 42) --------------------------------------------

test_that("a cell mixing #' lines and code gets mixed_text; a pure text or code cell doesn't", {
  g <- build_test_graph(list(
    A = fake_cell(code = "#' a\nx <- 1"),
    B = fake_cell(code = "#' only text"),
    C = fake_cell(code = "y <- 2")
  ), setup = "C")
  err <- Filter(function(e) e$kind == "mixed_text", g$errors)
  expect_length(err, 1)
  expect_equal(err[[1]]$cells, "A")
  expect_equal(err[[1]]$fixes, character())
})

test_that("the setup cell is never mixed_text even with #' lines above its code", {
  g <- build_test_graph(list(
    A = fake_cell(code = "#' setup doc\nlibrary(stats)"),
    B = fake_cell(code = "1")
  ), setup = "A")
  expect_length(Filter(function(e) e$kind == "mixed_text", g$errors), 0)
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
  expect_equal(errs[[1]]$names, c("a", "b"))
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
  expect_equal(errs[[1]]$names, c("a", "b", "c"))
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




# ---- affected() -----------------------------------------------------------------



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





# ---- cell_summary() and blocked_cells() ----------------------------------------



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

# ---- Disable cell (ui-3 20-23) -----------------------------------------------

test_that("a disabled definer drops out of multiple_definitions; its reader resolves to the other (ui-3 20)", {
  g <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x"),
    A2 = fake_cell(code = "A2", defs = "x"),
    C = fake_cell(code = "C", refs = "x")
  ), setup = "S", disabled = "A")
  expect_length(Filter(function(e) e$kind == "multiple_definitions", g$errors), 0)
  rows <- g$edges[g$edges$from == "C" & g$edges$name %in% "x", , drop = FALSE]
  expect_equal(rows$to, "A2")
  expect_equal(rows$via, "definition")
  expect_equal(g$off, c(A = "A"))

  g2 <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x"),
    A2 = fake_cell(code = "A2", defs = "x"),
    C = fake_cell(code = "C", refs = "x")
  ), setup = "S")
  expect_length(Filter(function(e) e$kind == "multiple_definitions", g2$errors), 1)
  rows2 <- g2$edges[g2$edges$from == "C" & g2$edges$name %in% "x", , drop = FALSE]
  expect_setequal(rows2$to, c("A", "A2"))
})

test_that("a dependent of a disabled cell gets a disabled edge and is off (ui-3 21)", {
  g <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x"),
    C = fake_cell(code = "C", defs = "y", refs = "x"),
    E = fake_cell(code = "E", refs = "y"),
    F = fake_cell(code = "F")
  ), setup = "S", disabled = "A")
  row <- g$edges[g$edges$from == "C" & g$edges$name %in% "x", , drop = FALSE]
  expect_equal(nrow(row), 1)
  expect_equal(row$to, "A")
  expect_equal(row$via, "disabled")
  expect_equal(g$off, c(A = "A", C = "A", E = "A"))
  expect_false("F" %in% names(g$off))
  expect_equal(downstream(g, "A", transitive = TRUE), c("C", "E"))

  g_enabled <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x"),
    C = fake_cell(code = "C", defs = "y", refs = "x"),
    E = fake_cell(code = "E", refs = "y"),
    F = fake_cell(code = "F")
  ), setup = "S")
  expect_equal(which(g$order == "A") < which(g$order == "C"), TRUE)
  expect_equal(which(g_enabled$order == "A") < which(g_enabled$order == "C"), TRUE)

  g_both <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x"),
    C = fake_cell(code = "C", defs = "y", refs = "x"),
    E = fake_cell(code = "E", refs = "y"),
    F = fake_cell(code = "F")
  ), setup = "S", disabled = c("A", "C"))
  expect_equal(unname(g_both$off["C"]), "C")
})

test_that("a disabled package attacher gives a disabled edge; the setup cell's attach wins (ui-3 22)", {
  # "mypkg"/"myfun", not a real package: wanted_packages() drops base
  # packages (tools among them) regardless of attachment, which would make
  # the assertion below pass for the wrong reason.
  g <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", attaches = "mypkg"),
    B = fake_cell(code = "B", refs = "myfun")
  ), setup = "S", exports = list(mypkg = "myfun"), disabled = "A")
  row <- g$edges[g$edges$from == "B" & g$edges$name %in% "myfun", , drop = FALSE]
  expect_equal(row$to, "A")
  expect_equal(row$via, "disabled")
  expect_true("B" %in% names(g$off))
  # A package used only in a disabled cell stays installed and locked: it's
  # still in wanted_packages(), not just visible in the per-cell analysis.
  expect_true("mypkg" %in% wanted_packages(g, list()))

  g2 <- build_test_graph(list(
    S = fake_cell(code = "S", attaches = "mypkg"),
    A = fake_cell(code = "A", attaches = "mypkg"),
    B = fake_cell(code = "B", refs = "myfun")
  ), setup = "S", exports = list(mypkg = "myfun"), disabled = "A")
  row2 <- g2$edges[g2$edges$from == "B" & g2$edges$name %in% "myfun", , drop = FALSE]
  expect_equal(row2$to, "S")
  expect_equal(row2$via, "package")
  expect_false("B" %in% names(g2$off))
  expect_true("mypkg" %in% wanted_packages(g2, list()))
})

test_that("an enabled package export wins over a disabled global definer (review)", {
  g <- build_test_graph(list(
    S = fake_cell(code = "S", attaches = "mypkg"),
    A = fake_cell(code = "A", defs = "myfun"),
    B = fake_cell(code = "B", refs = "myfun")
  ), setup = "S", exports = list(mypkg = "myfun"), disabled = "A")
  row <- g$edges[g$edges$from == "B" & g$edges$name %in% "myfun", , drop = FALSE]
  expect_equal(row$to, "S")
  expect_equal(row$via, "package")
  expect_false("B" %in% names(g$off))
})

test_that("the setup cell never resolves a reference through a disabled cell (review)", {
  g <- build_test_graph(list(
    S = fake_cell(code = "S", attaches = "tools", refs = "x"),
    A = fake_cell(code = "A", defs = "x")
  ), setup = "S", exports = list(tools = character()), disabled = "A")
  expect_equal(nrow(g$edges[g$edges$from == "S" & g$edges$name %in% "x", , drop = FALSE]), 0)
  expect_equal(g$off, c(A = "A"))
  expect_false("S" %in% names(g$off))

  # Without disabling A, S resolves normally (a sanity check on the fixture).
  g2 <- build_test_graph(list(
    S = fake_cell(code = "S", attaches = "tools", refs = "x"),
    A = fake_cell(code = "A", defs = "x")
  ), setup = "S", exports = list(tools = character()))
  row2 <- g2$edges[g2$edges$from == "S" & g2$edges$name %in% "x", , drop = FALSE]
  expect_equal(row2$to, "A")
  expect_equal(row2$via, "definition")
})

test_that("a disabled cell is excluded from cycle, private_name and global_setting errors (ui-3 23)", {
  g <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x", refs = "y"),
    C = fake_cell(code = "C", defs = "y", refs = "x")
  ), setup = "S", disabled = "A")
  expect_length(Filter(function(e) e$kind == "cycle", g$errors), 0)

  g_enabled <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x", refs = "y"),
    C = fake_cell(code = "C", defs = "y", refs = "x")
  ), setup = "S")
  expect_length(Filter(function(e) e$kind == "cycle", g_enabled$errors), 1)

  g_parse <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", parse_error = list(message = "oops", line = 1L, column = 1L))
  ), setup = "S", disabled = "A")
  expect_length(Filter(function(e) e$kind == "parse", g_parse$errors), 1)

  g_setting <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", settings = "options")
  ), setup = "S", disabled = "A")
  expect_length(Filter(function(e) e$kind == "global_setting", g_setting$errors), 0)

  g_mixed <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "#' a\nx <- 1")
  ), setup = "S", disabled = "A")
  expect_length(Filter(function(e) e$kind == "mixed_text", g_mixed$errors), 0)

  analyses <- list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x", refs = "y"),
    C = fake_cell(code = "C", defs = "y", refs = "x")
  )
  g1 <- build_test_graph(analyses, setup = "S", disabled = "A")
  g2 <- graph_learn(g1, "A", definitions = "x")
  expect_equal(g2$disabled, "A")
  expect_equal(g2$off, g1$off)
  g3 <- notebook_graph(setNames(vapply(names(analyses), function(id) analyses[[id]]$code, character(1)),
                                names(analyses)),
                       setup = "S", disabled = "A", previous = g1, read_file = NULL)
  cmp1 <- g1; cmp1$reread <- NULL
  cmp3 <- g3; cmp3$reread <- NULL
  expect_identical(cmp1, cmp3)
})

# ---- code_of(): a text cell's inline expressions join the graph (42) --------

test_that("code_of(): a text cell's inline expression gives it a real edge and run-order position (42)", {
  cells <- list(
    S = list(code = "", kind = "code", folded = FALSE, disabled = FALSE),
    A = list(code = "x <- 1", kind = "code", folded = FALSE, disabled = FALSE),
    T = list(code = "#' `r x`", kind = "markdown", folded = TRUE, disabled = FALSE),
    B = list(code = "x + 1", kind = "code", folded = FALSE, disabled = FALSE)
  )
  g <- notebook_graph(code_of(cells), setup = "S")
  expect_true("A" %in% g$upstream[["T"]])
  expect_lt(match("A", g$order), match("T", g$order))
})

test_that("code_of(): a text cell without inline values keeps its place beside its neighbours (42)", {
  cells <- list(
    S = list(code = "", kind = "code", folded = FALSE, disabled = FALSE),
    MD = list(code = "#' just text", kind = "markdown", folded = TRUE, disabled = FALSE),
    A = list(code = "x <- 1", kind = "code", folded = FALSE, disabled = FALSE)
  )
  g <- notebook_graph(code_of(cells), setup = "S")
  expect_equal(g$order, c("S", "MD", "A"))
})
