# Tests for parse-data position matching (R/positions.R): every row the
# walker records carries the exact token it came from.

#' The row of `df` (a `definitions`/`references`/`settings`/`notes` frame)
#' for `name`, or the `i`-th such row when `name` appears more than once.
row_for <- function(df, name, i = 1) {
  df[df$name == name, , drop = FALSE][i, , drop = FALSE]
}

test_that("a multi-line cell with a nested function: exact line/col/end_col", {
  a <- read_cell(paste(
    "f <- function(x, y = 2) {",
    "  z <- x + y",
    "  helper <- function(n) n * z",
    "  helper(3)",
    "}",
    sep = "\n"
  ))
  f_row <- row_for(a$definitions, "f")
  expect_equal(c(f_row$line, f_row$col, f_row$end_col), c(1L, 1L, 1L))
  plus <- row_for(a$references, "+")
  expect_equal(c(plus$line, plus$col, plus$end_col), c(2L, 10L, 10L))
  star <- row_for(a$references, "*")
  expect_equal(c(star$line, star$col, star$end_col), c(3L, 27L, 27L))
})

test_that("a pipe x |> f(y): f, x and y each keep their own source position", {
  a <- read_cell("x |> f(y)")
  f_row <- row_for(a$references, "f")
  x_row <- row_for(a$references, "x")
  y_row <- row_for(a$references, "y")
  expect_equal(c(f_row$col, f_row$end_col), c(6L, 6L))
  expect_equal(c(x_row$col, x_row$end_col), c(1L, 1L))
  expect_equal(c(y_row$col, y_row$end_col), c(8L, 8L))
})

test_that("-> positions its target and value at their own tokens, not swapped", {
  a <- read_cell("v -> x")
  def_row <- a$definitions[a$definitions$name == "x", ]
  ref_row <- a$references[a$references$name == "v", ]
  expect_equal(c(def_row$col, def_row$end_col), c(6L, 6L))
  expect_equal(c(ref_row$col, ref_row$end_col), c(1L, 1L))
})

test_that("a formula site is positioned at its own ~, distinct from a column reference", {
  a <- read_cell("fit <- lm(y ~ x, data = df)")
  site <- a$formulas[[1]]
  expect_equal(site$line, 1L)
  expect_equal(site$col, 13L)
  expect_equal(site$end_col, 13L)
  # y and x are columns (not references, so not positioned in `references`);
  # `lm` and `df` are references, each at their own token.
  lm_row <- a$references[a$references$name == "lm", ]
  df_row <- a$references[a$references$name == "df", ]
  expect_equal(c(lm_row$col, lm_row$end_col), c(8L, 9L))
  expect_equal(c(df_row$col, df_row$end_col), c(25L, 26L))
})

test_that("a bare (non-column) formula reference is positioned at its own symbol", {
  a <- read_cell("f <- y ~ x")
  y_row <- a$references[a$references$name == "y", ]
  x_row <- a$references[a$references$name == "x", ]
  expect_equal(c(y_row$col, y_row$end_col), c(6L, 6L))
  expect_equal(c(x_row$col, x_row$end_col), c(10L, 10L))
})

test_that("df$z <- v: the replacement definition sits at df, not at df$z or z", {
  a <- read_cell("df$z <- v")
  def_row <- a$definitions[a$definitions$name == "df", ]
  expect_equal(c(def_row$col, def_row$end_col), c(1L, 2L))
  df_ref <- a$references[a$references$name == "df", ]
  v_ref <- a$references[a$references$name == "v", ]
  expect_equal(c(df_ref$col, df_ref$end_col), c(1L, 2L))
  expect_equal(c(v_ref$col, v_ref$end_col), c(9L, 9L))
})

test_that("a name read twice gets one row per distinct position", {
  a <- read_cell("f(x); g(x)")
  x_rows <- a$references[a$references$name == "x", ]
  expect_equal(nrow(x_rows), 2)
  expect_equal(sort(x_rows$col), c(3L, 9L))
  # references_of() still collapses to the unique name.
  expect_equal(references_of(a), c("f", "x", "g"))
})

test_that("a sourced file's positions are local to that file, not the source() line", {
  reader <- function(path) {
    if (path == "helpers.R") "fit_growth <- function(d) nlsLM(y ~ a, d)\n" else NULL
  }
  a <- read_cell('x <- 1\nsource("helpers.R")', reader)
  def_row <- a$definitions[a$definitions$name == "fit_growth", ]
  expect_equal(def_row$line, 1L)
  expect_equal(c(def_row$col, def_row$end_col), c(1L, 10L))
  nlslm_row <- a$references[a$references$name == "nlsLM", ]
  expect_equal(nlslm_row$line, 1L)
  expect_equal(c(nlslm_row$col, nlslm_row$end_col), c(27L, 31L))
})

test_that("a name inside a glue string is positioned at the string literal itself", {
  a <- read_cell("glue::glue('{total} of {n}')")
  str_col <- 12L
  str_end_col <- nchar("'{total} of {n}'") + str_col - 1L
  total_row <- a$references[a$references$name == "total", ]
  n_row <- a$references[a$references$name == "n", ]
  expect_equal(c(total_row$col, total_row$end_col), c(str_col, str_end_col))
  expect_equal(c(n_row$col, n_row$end_col), c(str_col, str_end_col))
})

test_that("a shape the position matcher doesn't recognise falls back to NA columns", {
  # {f(x)}'s segment is itself a call, not a bare name: the reparsed
  # segment has no parse-data node of its own in the outer file to align
  # against (only the whole string literal does), so it falls back to the
  # enclosing expression's line with col/end_col NA, same as any other
  # unmatched shape, rather than misattributing a position.
  a <- read_cell('glue::glue("{f(x)}")')
  f_row <- a$references[a$references$name == "f", ]
  x_row <- a$references[a$references$name == "x", ]
  expect_equal(f_row$line, 1L)
  expect_true(is.na(f_row$col))
  expect_true(is.na(f_row$end_col))
  expect_true(is.na(x_row$col))
  expect_true(is.na(x_row$end_col))
})

