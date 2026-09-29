# Tests for formula reading by the column rule and the one-sided lambda
# path (R/walk-formula.R).

test_that("lm(y ~ x) with no data: every formula symbol is a reference", {
  a <- read_cell("lm(y ~ x)")
  expect_setequal(refs(a), c("lm", "y", "x"))
  expect_equal(length(a$formulas), 0)
})

test_that("a standalone formula (no enclosing call) is all references", {
  a <- read_cell("f <- y ~ x + z")
  expect_setequal(defs(a), "f")
  expect_setequal(refs(a), c("y", "x", "z"))
})

test_that("lm(y ~ poly(x, deg), data = df) reads by the column rule", {
  a <- read_cell("fit <- lm(y ~ poly(x, deg), data = df)")
  expect_setequal(defs(a), "fit")
  expect_setequal(refs(a), c("lm", "poly", "deg", "df"))
  expect_equal(length(a$formulas), 1)
  site <- a$formulas[[1]]
  expect_equal(site$fn, "lm")
  expect_equal(site$data, "df")
  expect_setequal(site$columns, c("y", "x"))
})

test_that("lm(y ~ x, df): a positional second argument is the data", {
  a <- read_cell("lm(y ~ x, df)")
  expect_setequal(refs(a), c("lm", "df"))
  expect_equal(a$formulas[[1]]$data, "df")
  expect_setequal(a$formulas[[1]]$columns, c("y", "x"))
})

test_that("y ~ . takes every other column, and . is never a name", {
  a <- read_cell("lm(y ~ ., data = df); f <- y ~ x")
  expect_setequal(defs(a), "f")
  expect_setequal(refs(a), c("lm", "df", "y", "x"))
  expect_setequal(a$formulas[[1]]$columns, "y")
})

test_that("s(x, k = k) in gam: the settings argument is a reference, not a column", {
  a <- read_cell("gam(y ~ s(x, k = k), data = df)")
  expect_setequal(a$formulas[[1]]$columns, c("y", "x"))
  expect_setequal(refs(a), c("gam", "s", "k", "df"))
})

test_that("offset(log(n)) takes its nested call's first argument as a column", {
  a <- read_cell("glm(n ~ s(x, k = k) + offset(log(n0)), data = d)")
  expect_setequal(a$formulas[[1]]$columns, c("n", "x", "n0"))
  expect_setequal(refs(a), c("glm", "s", "k", "offset", "log", "d"))
})

test_that("a formula outside any call is entirely references", {
  a <- read_cell("model_formula <- y ~ x")
  expect_setequal(refs(a), c("y", "x"))
  expect_equal(length(a$formulas), 0)
})

test_that("lm(y ~ X[, 1]): an empty argument inside a formula term is skipped", {
  a <- read_cell("lm(y ~ X[, 1])")
  expect_setequal(refs(a), c("lm", "y", "[", "X"))
})

test_that("lm(d$y ~ d$x) references d only", {
  a <- read_cell("lm(d$y ~ d$x)")
  expect_setequal(refs(a), c("lm", "d"))
  expect_false("y" %in% refs(a))
  expect_false("x" %in% refs(a))
})

test_that(".x, .y, .data and .env are never references", {
  # A one-sided formula passed to a non-model function is walked as a
  # lambda's function body (item 13), so `+` is an ordinary call head, the
  # same as in any other function body; only the pronouns themselves are
  # never references.
  a <- read_cell("map(xs, ~ .x + .data$col + .env$k)")
  expect_setequal(refs(a), c("map", "xs", "+"))
})

test_that("lm(y ~ x, , d): an empty data argument is skipped, not read", {
  a <- read_cell("lm(y ~ x, , d)")
  expect_equal(nrow(a$definitions), 0)
  expect_setequal(refs(a), c("lm", "y", "x", "d"))
  expect_equal(length(a$formulas), 0)
})

test_that("a purrr-style lambda with a braced body: v stays local, xs is a reference", {
  # As in any other function body (see the "function bodies" tests above),
  # an operator call head such as `*`/`+` is itself a reference; the bug
  # this fixes is `v` and `{`/`<-` leaking in as references, not those.
  a <- read_cell("purrr::map(xs, ~ { v <- .x * 2; v + 1 })")
  expect_setequal(refs(a), c("xs", "*", "+"))
  expect_false("v" %in% refs(a))
  expect_setequal(a$packages$name, "purrr")
})

test_that("a one-sided formula lambda without braces is unaffected", {
  a <- read_cell("map(xs, ~ .x + total)")
  expect_setequal(refs(a), c("map", "xs", "total", "+"))
})

