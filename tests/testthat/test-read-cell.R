# Tests for read_cell()'s entry point (R/analysis.R): parse errors, the
# shape of an empty result, definitions_of()/references_of(), performance,
# and the property that it never errors on parseable code.

test_that("a parse error is reported with its line, and leaves every field empty", {
  a <- read_cell("1 + * 2")
  expect_false(is.null(a$parse_error))
  expect_equal(a$parse_error$line, 1)
  expect_equal(nrow(a$definitions), 0)
  expect_equal(nrow(a$references), 0)
  expect_equal(nrow(a$packages), 0)
})

test_that("empty code reads as an analysis with nothing in it", {
  a <- read_cell("")
  expect_equal(nrow(a$definitions), 0)
  expect_equal(nrow(a$references), 0)
  expect_null(a$parse_error)
})

test_that("definitions_of and references_of return unique names in source order", {
  a <- read_cell("x <- 1; x <- 2; y <- x")
  expect_equal(definitions_of(a), c("x", "y"))
  expect_equal(references_of(a), character())
})

# Compares 6000 lines with 1000, so a slow machine doesn't matter: linear
# time gives a ratio near 6, quadratic near 36.
test_that("read_cell() reads 6000 generated lines in linear time", {
  gen <- function(n) paste(sprintf("x%d <- f(x%d, y)", 1:n, 0:(n - 1)), collapse = "\n")
  short <- system.time(read_cell(gen(1000)))[["elapsed"]]
  long <- system.time(a <- read_cell(gen(6000)))[["elapsed"]]
  expect_equal(nrow(a$definitions), 6000)
  expect_lt(long / max(short, 0.01), 15)
})

test_that("read_cell() never errors on ~20 odd but parseable one-liners", {
  snippets <- c(
    "lm(y ~ x, , d)", "source('a.R', local = )", "source(file = )",
    "box::use(dplyr[])", "box::use()", "`for`(i)", "`if`()", "`function`()",
    "`\\\\`(x)", "`while`()", "`repeat`()", "assign(, 1)",
    "data(list = c(,))", "options(,)", "library(character.only = TRUE)",
    "require(pkg = x)", "lm(~ x, data = d, data = e)", "f(x) <- g(y) <- 1",
    "pkg::`fn<-`(x, 1)", "glue::glue()", "substitute()"
  )
  for (s in snippets) {
    a <- read_cell(s)
    expect_s3_class(a, "ember_cell_analysis")
    expect_null(a$parse_error)
  }
})

