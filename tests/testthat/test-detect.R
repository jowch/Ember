# Tests for wanted_packages()/cell_packages() (R/resolve.R): what the
# notebook's code and header say it needs. See docs/packages-tests.md,
# "Detection" (tests 11-15). Uses fake_cell()/build_test_graph() from
# helper-graph.R: read_cell()'s own package detection is tested in
# test-calls.R and friends, not here.

plain_header <- function(extra_packages = character()) {
  new_header(ember_version = "0.1.0", r_version = "4.6.1", snapshot = NA_character_,
            extra_packages = extra_packages)
}

test_that("wanted_packages collects library, require, requireNamespace, ::, box and pacman names across cells", {
  a <- fake_cell(attaches = c("dplyr", "ggplot2"))
  b <- fake_cell(used = c("stringr", "purrr"))
  g <- build_test_graph(list(setup = a, b = b))
  expect_setequal(wanted_packages(g, plain_header()), c("dplyr", "ggplot2", "stringr", "purrr"))
})

test_that("wanted_packages includes packages named in a sourced file", {
  # read_cell() merges a sourced file's package rows into the cell's own
  # packages data frame (analysis.R); wanted_packages() reads that merged
  # result and has no separate notion of "from a sourced file".
  a <- fake_cell(used = "jsonlite")
  g <- build_test_graph(list(setup = a))
  expect_true("jsonlite" %in% wanted_packages(g, plain_header()))
})

test_that("wanted_packages adds [extra_packages] and drops base packages", {
  a <- fake_cell(attaches = c("dplyr", "methods"))
  g <- build_test_graph(list(setup = a))
  w <- wanted_packages(g, plain_header(extra_packages = "svglite"))
  expect_setequal(w, c("dplyr", "svglite"))
  expect_false("methods" %in% w)
})

test_that("wanted_packages keeps recommended packages (MASS) as ordinary names", {
  a <- fake_cell(attaches = "MASS")
  g <- build_test_graph(list(setup = a))
  expect_true("MASS" %in% wanted_packages(g, plain_header()))
})

test_that("a computed library(pkg) contributes nothing", {
  # analysis.R gives a computed library() call a "computed_package" note
  # and no packages row at all; wanted_packages() just sees an empty
  # packages data frame for that cell, as for any cell naming no package.
  a <- fake_cell(defs = "pkg")
  g <- build_test_graph(list(setup = a))
  expect_equal(wanted_packages(g, plain_header()), character())
})

test_that("cell_packages gives one cell's own wanted packages, minus base packages", {
  a <- fake_cell(attaches = c("dplyr", "stats"))
  b <- fake_cell(used = "glue")
  g <- build_test_graph(list(setup = a, b = b))
  expect_equal(cell_packages(g, "setup"), "dplyr")
  expect_equal(cell_packages(g, "b"), "glue")
})
