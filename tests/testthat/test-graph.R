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
  ))
  expect_true("A" %in% upstream(g, "B"))
  expect_true(any(g$edges$from == "B" & g$edges$to == "A" &
                    g$edges$name == "x" & g$edges$via == "definition"))
})

test_that("a reference to a package export gets a package edge", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", attaches = "dplyr"),
    B = fake_cell(code = "B", refs = "mutate")
  ), exports = list(dplyr = c("mutate", "filter")))
  expect_true(any(g$edges$from == "B" & g$edges$to == "A" &
                    g$edges$name == "mutate" & g$edges$via == "package"))
})

test_that("a global definition shadows a package export", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "filter"),
    B = fake_cell(code = "B", attaches = "dplyr"),
    C = fake_cell(code = "C", refs = "filter")
  ), exports = list(dplyr = "filter"))
  expect_equal(upstream(g, "C"), "A")
  expect_false(any(g$edges$from == "C" & g$edges$to == "B"))
})

test_that("no cell is special: an ordinary first cell gets no edges", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", defs = "x"),
    C = fake_cell(code = "C", refs = "x")
  ))
  expect_false("A" %in% upstream(g, "B"))
  expect_false("A" %in% upstream(g, "C"))
  expect_equal(g$settings, character())
  expect_false(any(g$edges$to == "A"))
})

test_that("a cell reading its own name gets no self edge", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "s", refs = "s")
  ))
  expect_equal(nrow(g$edges), 0)
  expect_length(g$errors, 0)
})

# ---- Multiple definitions ---------------------------------------------------

test_that("two plain definitions of the same name are an error on both cells", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "x"),
    B = fake_cell(code = "B", defs = "x")
  ))
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
  ))
  err <- Filter(function(e) e$kind == "multiple_definitions", g$errors)[[1]]
  expect_equal(err$fixes,
              "Move the line into the cell that defines df, or name the result (df2 <- ...)")
})

test_that("two 'for' definitions give the private-name fix", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "i", kinds = "for"),
    B = fake_cell(code = "B", defs = "i", kinds = "for")
  ))
  err <- Filter(function(e) e$kind == "multiple_definitions", g$errors)[[1]]
  expect_equal(err$fixes, "Use a private name: .i")
})

test_that("private names in a 'for' loop in two cells don't collide", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = ".i", kinds = "for"),
    B = fake_cell(code = "B", defs = ".i", kinds = "for")
  ))
  expect_length(Filter(function(e) e$kind == "multiple_definitions", g$errors), 0)
  expect_length(g$errors, 0)
})

# ---- Private names -----------------------------------------------------------

test_that("using another cell's private name is an error with no edge", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = ".tmp"),
    B = fake_cell(code = "B", refs = ".tmp")
  ))
  err <- Filter(function(e) e$kind == "private_name", g$errors)
  expect_length(err, 1)
  expect_equal(err[[1]]$cells, "B")
  expect_equal(err[[1]]$names, ".tmp")
  expect_equal(err[[1]]$fixes, "Drop the dot: tmp")
  expect_false(any(g$edges$from == "B" & g$edges$to == "A" & g$edges$via == "definition"))
})

test_that("a private-name error's message has no cell id, only the private name", {
  owner_id <- "ca1b0a64-d117-466f-898a-8603bbc24e75"
  reader_id <- "e2f5c0a1-8a8e-4e8e-9a0e-1a2b3c4d5e6f"
  g <- build_test_graph(setNames(
    list(fake_cell(code = "owner", defs = ".tmp"),
        fake_cell(code = "reader", refs = ".tmp")),
    c(owner_id, reader_id)
  ))
  err <- Filter(function(e) e$kind == "private_name", g$errors)
  expect_length(err, 1)
  expect_no_match(err[[1]]$message, owner_id, fixed = TRUE)
  expect_match(err[[1]]$message, ".tmp", fixed = TRUE)
})

# ---- Settings cells (settings-cells.md) ---------------------------------------

test_that("a setting in any cell makes it a settings cell, not an error", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", settings = c(options = "option:digits"))
  ))
  expect_equal(g$settings, "B")
  expect_length(g$errors, 0)
  expect_equal(g$cells$B$setting_keys$key, "option:digits")
  expect_equal(g$cells$B$setting_keys$found, "code")
})

test_that("the worked example orders 2, 4, 3, 1, 5 and later cells depend on the settings cell", {
  g <- build_test_graph(list(
    c1 = fake_cell(code = "c1", defs = "fit"),
    c2 = fake_cell(code = "c2", attaches = "ggplot2"),
    c3 = fake_cell(code = "c3", refs = c("theme_set", "theme_minimal", "n"),
                   settings = c(theme_set = "theme")),
    c4 = fake_cell(code = "c4", defs = "n"),
    c5 = fake_cell(code = "c5", refs = c("ggplot", "aes"))
  ), exports = list(ggplot2 = c("theme_set", "theme_minimal", "ggplot", "aes")))
  expect_equal(g$order, c("c2", "c4", "c3", "c1", "c5"))
  setting <- g$edges[g$edges$via == "setting", , drop = FALSE]
  expect_setequal(setting$from, c("c1", "c5"))
  expect_true(all(setting$to == "c3"))
  expect_true(all(setting$name == "theme"))
  expect_true("c3" %in% upstream(g, "c1"))
  expect_false("c3" %in% upstream(g, "c2"))
  expect_false("c3" %in% upstream(g, "c4"))
})

test_that("two settings cells run in display order, the second depending on the first", {
  g <- build_test_graph(list(
    X = fake_cell(code = "X", defs = "x"),
    A = fake_cell(code = "A", settings = c(options = "option:digits")),
    B = fake_cell(code = "B", settings = c(Sys.setenv = "env:TZ"))
  ))
  expect_equal(g$order, c("A", "B", "X"))
  expect_true("A" %in% upstream(g, "B"))
  expect_false("B" %in% upstream(g, "A"))
  expect_setequal(upstream(g, "X"), c("A", "B"))
  expect_length(Filter(function(e) e$kind == "cycle", g$errors), 0)
})

test_that("the four cases that cycled under 'every cell depends on every settings cell' don't", {
  # A settings cell using another cell's package.
  g1 <- build_test_graph(list(
    A = fake_cell(code = "A", attaches = "ggplot2"),
    B = fake_cell(code = "B", refs = c("theme_set", "theme_minimal"), settings = c(theme_set = "theme"))
  ), exports = list(ggplot2 = c("theme_set", "theme_minimal")))
  expect_length(g1$errors, 0)
  expect_equal(g1$order, c("A", "B"))
  # A setting inside a helper, found at run time.
  g2 <- build_test_graph(list(
    F = fake_cell(code = "F", defs = "prep"),
    G = fake_cell(code = "G", refs = "prep"),
    H = fake_cell(code = "H", defs = "y")
  ), learned = list(settings = list(G = "option:digits")))
  expect_length(g2$errors, 0)
  expect_equal(g2$order, c("F", "G", "H"))
  expect_equal(g2$cells$G$setting_keys$found, "run")
  expect_false("G" %in% upstream(g2, "F"))
  # A setting computed from another cell.
  g3 <- build_test_graph(list(
    S = fake_cell(code = "S", refs = "n", settings = c(options = "option:digits")),
    N = fake_cell(code = "N", defs = "n")
  ))
  expect_length(g3$errors, 0)
  expect_equal(g3$order, c("N", "S"))
})

test_that("a setting in two cells is setting_conflict; two different settings aren't", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", settings = c(options = "option:digits")),
    B = fake_cell(code = "B", settings = c(options = "option:digits", options = "option:scipen")),
    C = fake_cell(code = "C", settings = c(options = "option:width"))
  ))
  err <- Filter(function(e) e$kind == "setting_conflict", g$errors)
  expect_length(err, 1)
  expect_equal(err[[1]]$cells, c("A", "B"))
  expect_equal(err[[1]]$names, "digits")
  expect_equal(err[[1]]$message, "digits is set in two cells.")
  expect_equal(err[[1]]$fixes,
               "Set it in one cell, or use withr::with_options() to change it for one piece of code")
  expect_setequal(blocked_cells(g), c("A", "B"))
})

test_that("a static setting and a learned one for the same key conflict", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", settings = c(Sys.setenv = "env:TZ")),
    B = fake_cell(code = "B")
  ), learned = list(settings = list(B = "env:TZ")))
  err <- Filter(function(e) e$kind == "setting_conflict", g$errors)
  expect_length(err, 1)
  expect_equal(err[[1]]$names, "TZ")
  expect_match(err[[1]]$fixes, "with_envvar", fixed = TRUE)
})

test_that("a package attached in two cells is package_conflict; overlapping packages aren't", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", attaches = "tidyverse"),
    B = fake_cell(code = "B", attaches = c("tidyverse", "broom")),
    C = fake_cell(code = "C", attaches = "ggplot2"),
    D = fake_cell(code = "D", used = "tidyverse")
  ))
  err <- Filter(function(e) e$kind == "package_conflict", g$errors)
  expect_length(err, 1)
  expect_equal(err[[1]]$cells, c("A", "B"))
  expect_equal(err[[1]]$message, "tidyverse is attached in two cells.")
  expect_equal(err[[1]]$fixes, "Keep one library(tidyverse) and remove the other")
})

test_that("a disabled settings cell sets nothing and adds no edges", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", settings = c(options = "option:digits")),
    B = fake_cell(code = "B", settings = c(options = "option:digits")),
    C = fake_cell(code = "C")
  ), disabled = "A")
  expect_equal(g$settings, "B")
  expect_length(Filter(function(e) e$kind == "setting_conflict", g$errors), 0)
  expect_false(any(g$edges$to == "A" & g$edges$via == "setting"))
  expect_equal(names(g$off), "A")
})

test_that("a settings cell that is off turns off only its own readers, not every later cell", {
  g <- build_test_graph(list(
    D = fake_cell(code = "D", defs = "n"),
    S = fake_cell(code = "S", refs = "n", settings = c(options = "option:digits")),
    C = fake_cell(code = "C", defs = "y")
  ), disabled = "D")
  expect_setequal(names(g$off), c("D", "S"))
  expect_true("S" %in% upstream(g, "C"))
})

test_that("a computed setting name makes a settings cell that conflicts with nothing", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", settings = "options"),
    B = fake_cell(code = "B", settings = "options"),
    C = fake_cell(code = "C")
  ))
  expect_equal(g$settings, c("A", "B"))
  expect_length(g$errors, 0)
})

test_that("an empty cell gets no setting edge; a text cell's inline code does", {
  g <- build_test_graph(list(
    S = fake_cell(code = "S", settings = c(options = "option:digits")),
    E = fake_cell(code = ""),
    T = fake_cell(code = "x")
  ))
  expect_false(any(g$edges$from == "E"))
  expect_true(any(g$edges$from == "T" & g$edges$to == "S" & g$edges$via == "setting"))
})

test_that("graph_learn adds and drops learned settings", {
  g0 <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B")
  ))
  g1 <- graph_learn(g0, "B", settings = "option:digits")
  expect_equal(g1$settings, "B")
  expect_equal(g1$order, c("B", "A"))
  expect_equal(g1$learned$settings, list(B = "option:digits"))
  g2 <- graph_learn(g1, "B", settings = character())
  expect_equal(g2$settings, character())
  expect_length(g2$learned$settings, 0)
})

# ---- Mixed text and code (ui-3 42) --------------------------------------------

test_that("a cell mixing #' lines and code gets mixed_text; a pure text or code cell doesn't", {
  g <- build_test_graph(list(
    A = fake_cell(code = "#' a\nx <- 1"),
    B = fake_cell(code = "#' only text"),
    C = fake_cell(code = "y <- 2")
  ))
  err <- Filter(function(e) e$kind == "mixed_text", g$errors)
  expect_length(err, 1)
  expect_equal(err[[1]]$cells, "A")
  expect_equal(err[[1]]$fixes, character())
})

test_that("the first cell is mixed_text like any other: no cell is special", {
  g <- build_test_graph(list(
    A = fake_cell(code = "#' doc\nlibrary(stats)"),
    B = fake_cell(code = "1")
  ))
  expect_length(Filter(function(e) e$kind == "mixed_text", g$errors), 1)
})

# ---- Cycles -------------------------------------------------------------------

test_that("a two-cell cycle is one error naming both names", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "a", refs = "b"),
    B = fake_cell(code = "B", defs = "b", refs = "a")
  ))
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
  ))
  errs <- Filter(function(e) e$kind == "cycle", g$errors)
  expect_length(errs, 1)
  expect_equal(errs[[1]]$cells, c("A", "B", "C"))
  expect_equal(errs[[1]]$names, c("a", "b", "c"))
})

test_that("a cycle's message names the variables, not the cell ids", {
  id_a <- "ca1b0a64-d117-466f-898a-8603bbc24e75"
  id_b <- "e2f5c0a1-8a8e-4e8e-9a0e-1a2b3c4d5e6f"
  g <- build_test_graph(setNames(
    list(fake_cell(code = "a", defs = "a", refs = "b"),
        fake_cell(code = "b", defs = "b", refs = "a")),
    c(id_a, id_b)
  ))
  errs <- Filter(function(e) e$kind == "cycle", g$errors)
  expect_length(errs, 1)
  expect_no_match(errs[[1]]$message, id_a, fixed = TRUE)
  expect_no_match(errs[[1]]$message, id_b, fixed = TRUE)
  expect_match(errs[[1]]$message, "a, b", fixed = TRUE)
})

test_that("a first cell reading a later cell's name is no cycle (it was, with a setup cell)", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "z", refs = "w"),
    B = fake_cell(code = "B", defs = "w")
  ))
  expect_length(Filter(function(e) e$kind == "cycle", g$errors), 0)
  expect_equal(g$order, c("B", "A"))
})

test_that("cycle members can't run", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "a", refs = "b"),
    B = fake_cell(code = "B", defs = "b", refs = "a")
  ))
  expect_setequal(blocked_cells(g), c("A", "B"))
})

test_that("graph_learn can add and clear a cycle", {
  g0 <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "fit"),
    B = fake_cell(code = "B", defs = "x", refs = "fit")
  ))
  expect_length(Filter(function(e) e$kind == "cycle", g0$errors), 0)

  g1 <- graph_learn(g0, "A", references = "x")
  expect_length(Filter(function(e) e$kind == "cycle", g1$errors), 1)

  g2 <- graph_learn(g1, "A", references = character())
  expect_length(Filter(function(e) e$kind == "cycle", g2$errors), 0)
})

# ---- Run order ----------------------------------------------------------------

test_that("settings cells run first, then attaching cells, then the rest", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", attaches = "stats"),
    C = fake_cell(code = "C", settings = c(options = "option:digits"))
  ))
  expect_equal(g$order, c("C", "B", "A"))
})

test_that("package-attaching cells run before the rest, in display order", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", refs = "x"),
    B = fake_cell(code = "B", attaches = "ggplot2"),
    C = fake_cell(code = "C", defs = "x"),
    D = fake_cell(code = "D")
  ))
  # B goes first; A then waits for C, which defines the x it reads.
  expect_equal(g$order, c("B", "C", "A", "D"))
})

test_that("with no forcing edges, run order is display order", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B"),
    C = fake_cell(code = "C")
  ))
  expect_equal(g$order, c("A", "B", "C"))
})

test_that("a cell moves only when an edge forces it", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", refs = c("x", "y")),
    C = fake_cell(code = "C", defs = "x"),
    D = fake_cell(code = "D", defs = "y")
  ))
  expect_equal(g$order, c("A", "C", "D", "B"))
})

test_that("a markdown (empty-code) cell keeps its place beside its neighbours", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "x"),
    M = fake_cell(code = ""),
    B = fake_cell(code = "B", refs = "x")
  ))
  expect_equal(g$order, c("A", "M", "B"))
})

test_that("markdown cells stay anchored to their next neighbour when a package-attaching cell pulls it forward", {
  # Display order s, md1, a, md2, b; b attaches dplyr and uses a's name, so
  # the package-first pass would otherwise pull a and b ahead of md1/md2,
  # stranding both markdown cells at the end (run order s a b md1 md2).
  # The rule: each markdown cell is placed immediately before the next
  # non-markdown cell in display order, whenever that cell is emitted.
  g <- build_test_graph(list(
    s = fake_cell(code = "s", settings = c(options = "option:digits")),
    md1 = fake_cell(code = "   "),
    a = fake_cell(code = "a", defs = "x"),
    md2 = fake_cell(code = ""),
    b = fake_cell(code = "b", refs = "x", attaches = "dplyr")
  ), exports = list(dplyr = "mutate"))
  expect_equal(g$order, c("s", "md1", "a", "md2", "b"))
})

test_that("trailing markdown cells after the last code cell go at the end in display order", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "x"),
    B = fake_cell(code = "B", refs = "x"),
    md1 = fake_cell(code = ""),
    md2 = fake_cell(code = "  ")
  ))
  expect_equal(g$order, c("A", "B", "md1", "md2"))
})

test_that("cycle members appear in display order within the run order", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", defs = "b", refs = "c"),
    C = fake_cell(code = "C", defs = "c", refs = "b")
  ))
  expect_equal(which(g$order == "B") + 1, which(g$order == "C"))
})

test_that("run order is always a permutation of the cell ids", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", defs = "b", refs = "c"),
    C = fake_cell(code = "C", defs = "c", refs = "b"),
    D = fake_cell(code = "D", attaches = "dplyr"),
    E = fake_cell(code = "")
  ))
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
  ))
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
  ))
  g1 <- graph_learn(g0, "A", definitions = "fits")
  expect_true("A" %in% upstream(g1, "B"))

  g2 <- graph_learn(g1, "A", definitions = character())
  expect_false("A" %in% upstream(g2, "B"))
})

test_that("a learned reference adds an edge", {
  g0 <- build_test_graph(list(
    A = fake_cell(code = "A", defs = "fit"),
    B = fake_cell(code = "B", defs = "z")
  ))
  expect_false("B" %in% upstream(g0, "A"))

  g1 <- graph_learn(g0, "A", references = "z")
  expect_true("B" %in% upstream(g1, "A"))
})


# ---- Previous reuse -----------------------------------------------------------

test_that("rereading only the changed cell leaves other analyses untouched", {
  a_analysis <- fake_cell(code = "x <- 1", defs = "x")
  b_analysis_old <- fake_cell(code = "y <- x", refs = "x")
  previous <- build_test_graph(list(A = a_analysis, B = b_analysis_old))

  testthat::local_mocked_bindings(
    read_cell = function(code, read_file = NULL) fake_cell(code = code, refs = "x")
  )
  new_cells <- c(A = "x <- 1", B = "y <- x + 1")
  g <- notebook_graph(new_cells, previous = previous, read_file = NULL)

  expect_equal(g$reread, "B")
  expect_identical(g$analyses[["A"]], a_analysis)
})

test_that("passing previous never changes the result", {
  testthat::local_mocked_bindings(
    read_cell = function(code, read_file = NULL) fake_cell(code = code, defs = "x")
  )
  cells <- c(A = "x <- 1", B = "y <- 2")
  fresh <- notebook_graph(cells, read_file = NULL)
  previous <- fresh
  again <- notebook_graph(cells, previous = previous, read_file = NULL)

  expect_identical(fresh$order, again$order)
  expect_identical(fresh$edges, again$edges)
  expect_identical(fresh$cells, again$cells)
  expect_length(again$reread, 0)
})

test_that("unknown learned ids are dropped", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B")
  ), learned = list(definitions = list(ghost = "x")))
  expect_false("ghost" %in% names(g$learned$definitions))
})

# ---- changed_cells() ----------------------------------------------------------





# ---- cell_summary() and blocked_cells() ----------------------------------------



# ---- Parse errors ---------------------------------------------------------------

test_that("a cell with a parse error keeps its setting edge and has no definitions", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A", settings = c(options = "option:digits")),
    B = fake_cell(code = "B", parse_error = list(message = "unexpected end of input",
                                                 line = 1L, column = 5L))
  ))
  expect_true("A" %in% upstream(g, "B"))
  expect_equal(g$cells[["B"]]$definitions, character())
  errs <- Filter(function(e) e$kind == "parse", g$errors)
  expect_length(errs, 1)
  expect_equal(errs[[1]]$cells, "B")
})

test_that("a parse error's graph error carries the real line, not always 1", {
  g <- build_test_graph(list(
    A = fake_cell(code = "A"),
    B = fake_cell(code = "B", parse_error = list(message = "unexpected ','",
                                                 line = 3L, column = 5L))
  ))
  errs <- Filter(function(e) e$kind == "parse", g$errors)
  expect_length(errs, 1)
  expect_equal(errs[[1]]$lines$line, 3L)
})

test_that("a parse error at the end of input stays on the cell's last line", {
  a <- read_cell("x <- (\n")
  expect_equal(a$parse_error$line, 1L)
  a <- read_cell("y <- 1\nx <- (\n\n")
  expect_equal(a$parse_error$line, 2L)
})

# ---- Disable cell (ui-3 20-23) -----------------------------------------------

test_that("a disabled definer drops out of multiple_definitions; its reader resolves to the other (ui-3 20)", {
  g <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x"),
    A2 = fake_cell(code = "A2", defs = "x"),
    C = fake_cell(code = "C", refs = "x")
  ), disabled = "A")
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
  ))
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
  ), disabled = "A")
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
  ))
  expect_equal(which(g$order == "A") < which(g$order == "C"), TRUE)
  expect_equal(which(g_enabled$order == "A") < which(g_enabled$order == "C"), TRUE)

  g_both <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x"),
    C = fake_cell(code = "C", defs = "y", refs = "x"),
    E = fake_cell(code = "E", refs = "y"),
    F = fake_cell(code = "F")
  ), disabled = c("A", "C"))
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
  ), exports = list(mypkg = "myfun"), disabled = "A")
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
  ), exports = list(mypkg = "myfun"), disabled = "A")
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
  ), exports = list(mypkg = "myfun"), disabled = "A")
  row <- g$edges[g$edges$from == "B" & g$edges$name %in% "myfun", , drop = FALSE]
  expect_equal(row$to, "S")
  expect_equal(row$via, "package")
  expect_false("B" %in% names(g$off))
})

test_that("the first cell is not special: a name only a disabled cell defines takes it off (settings-cells.md)", {
  g <- build_test_graph(list(
    S = fake_cell(code = "S", attaches = "tools", refs = "x"),
    A = fake_cell(code = "A", defs = "x")
  ), exports = list(tools = character()), disabled = "A")
  row <- g$edges[g$edges$from == "S" & g$edges$name %in% "x", , drop = FALSE]
  expect_equal(row$to, "A")
  expect_equal(row$via, "disabled")
  expect_setequal(names(g$off), c("A", "S"))
})

test_that("a disabled cell is excluded from cycle, private_name and global_setting errors (ui-3 23)", {
  g <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x", refs = "y"),
    C = fake_cell(code = "C", defs = "y", refs = "x")
  ), disabled = "A")
  expect_length(Filter(function(e) e$kind == "cycle", g$errors), 0)

  g_enabled <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x", refs = "y"),
    C = fake_cell(code = "C", defs = "y", refs = "x")
  ))
  expect_length(Filter(function(e) e$kind == "cycle", g_enabled$errors), 1)

  g_parse <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", parse_error = list(message = "oops", line = 1L, column = 1L))
  ), disabled = "A")
  expect_length(Filter(function(e) e$kind == "parse", g_parse$errors), 1)

  g_setting <- build_test_graph(list(
    S = fake_cell(code = "S", settings = c(options = "option:digits")),
    A = fake_cell(code = "A", settings = c(options = "option:digits"))
  ), disabled = "A")
  expect_length(Filter(function(e) e$kind == "setting_conflict", g_setting$errors), 0)
  g_setting_on <- build_test_graph(list(
    S = fake_cell(code = "S", settings = c(options = "option:digits")),
    A = fake_cell(code = "A", settings = c(options = "option:digits"))
  ))
  expect_length(Filter(function(e) e$kind == "setting_conflict", g_setting_on$errors), 1)

  g_mixed <- build_test_graph(list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "#' a\nx <- 1")
  ), disabled = "A")
  expect_length(Filter(function(e) e$kind == "mixed_text", g_mixed$errors), 0)

  analyses <- list(
    S = fake_cell(code = "S"),
    A = fake_cell(code = "A", defs = "x", refs = "y"),
    C = fake_cell(code = "C", defs = "y", refs = "x")
  )
  g1 <- build_test_graph(analyses, disabled = "A")
  g2 <- graph_learn(g1, "A", definitions = "x")
  expect_equal(g2$disabled, "A")
  expect_equal(g2$off, g1$off)
  g3 <- notebook_graph(setNames(vapply(names(analyses), function(id) analyses[[id]]$code, character(1)),
                                names(analyses)), disabled = "A", previous = g1, read_file = NULL)
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
  g <- notebook_graph(code_of(cells))
  expect_true("A" %in% g$upstream[["T"]])
  expect_lt(match("A", g$order), match("T", g$order))
})

test_that("code_of(): a text cell without inline values keeps its place beside its neighbours (42)", {
  cells <- list(
    S = list(code = "", kind = "code", folded = FALSE, disabled = FALSE),
    MD = list(code = "#' just text", kind = "markdown", folded = TRUE, disabled = FALSE),
    A = list(code = "x <- 1", kind = "code", folded = FALSE, disabled = FALSE)
  )
  g <- notebook_graph(code_of(cells))
  expect_equal(g$order, c("S", "MD", "A"))
})
