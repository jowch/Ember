# Tests for R/text-cells.R: working out a cell's kind from its code, and
# the mixed-cell and inline-expression helpers it's built from.

test_that("cell_kind: text cells", {
  expect_equal(cell_kind("#' a\n#'\n#' b"), "markdown")
  expect_equal(cell_kind("##' a"), "markdown")
})

test_that("cell_kind: code cells", {
  expect_equal(cell_kind("x <- 1"), "code")
  expect_equal(cell_kind(""), "code")
  expect_equal(cell_kind("\n\n"), "code")
  expect_equal(cell_kind("#' a\nx"), "code")
  expect_equal(cell_kind("#| fig-width: 8"), "code")
})

test_that("cell_kind: the setup cell is always code", {
  expect_equal(cell_kind("#' a", setup = TRUE), "code")
})

test_that("is_mixed", {
  expect_false(is_mixed("x <- 1"))
  expect_false(is_mixed("#' a\n#' b"))
  expect_true(is_mixed("#' a\nx"))
  expect_true(is_mixed("# note\n#' a"))
})

test_that("split_mixed splits text and code, dropping edge blanks", {
  expect_equal(split_mixed("#' ## The model\n#' A line.\n\nfit <- lm(mpg ~ wt, cars)"),
              c("#' ## The model\n#' A line.", "fit <- lm(mpg ~ wt, cars)"))
  expect_equal(split_mixed("#' a\n\nx\n#' b"), c("#' a", "x", "#' b"))
  expect_equal(split_mixed("# note\n#' a"), c("# note", "#' a"))
})

test_that("inline_spans finds `r expr` on text lines only", {
  spans <- inline_spans("#' The average is `r round(mean(x), 1)` mpg, across `r nrow(d)` cars.")
  expect_equal(spans$line, c(1, 1))
  expect_equal(spans$expr, c("round(mean(x), 1)", "nrow(d)"))

  expect_equal(nrow(inline_spans("#' `rx` and `r`")), 0)
  expect_equal(nrow(inline_spans("x <- `r 1`")), 0)

  spans3 <- inline_spans("#' a\n#' b\n#' `r z`")
  expect_equal(spans3$line, 3)
})

test_that("inline_code joins one expression per line", {
  expect_equal(inline_code("#' `r a`\n#' text\n#' `r b`"), "a\nb")
  expect_equal(inline_code("#' no expr here"), "")
})

test_that("cell_runs: code cells always; text cells only with inline values", {
  expect_true(cell_runs(list(kind = "code", code = "1")))
  expect_false(cell_runs(list(kind = "markdown", code = "#' hi")))
  expect_true(cell_runs(list(kind = "markdown", code = "#' `r 1 + 1`")))
})

test_that("text_body strips the #' prefix", {
  expect_equal(text_body("#' Hi\n#'\n#' There"), c("Hi", "", "There"))
})

test_that("line_inline_matches finds spans on one line with their positions", {
  mm <- line_inline_matches("The average is `r round(mean(x), 1)` mpg.")
  expect_equal(mm$exprs, "round(mean(x), 1)")
  expect_equal(substr("The average is `r round(mean(x), 1)` mpg.", mm$starts, mm$starts + mm$lengths - 1),
              "`r round(mean(x), 1)`")

  expect_equal(line_inline_matches("no expr here")$exprs, character())
})

test_that("replace_inline_matches splices replacements in without disturbing the rest of the line", {
  expect_equal(replace_inline_matches("a `r x` b `r y` c", c("X", "Y")), "a X b Y c")
  expect_equal(replace_inline_matches("no spans", character()), "no spans")
})

test_that("line_inline_matches never matches across a line break (review)", {
  # inline_spans() already matches line by line; this is the shared
  # primitive project_text() (pluto-state.R) must use the same way, so a
  # whole-body regex can't consume a span's closing backtick from the
  # next line.
  expect_equal(line_inline_matches("see `r ")$exprs, character())
  expect_equal(line_inline_matches("x` and `r y`")$exprs, "y")
})
