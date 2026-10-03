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

test_that("render_markdown falls back to escaped <pre> without commonmark", {
  testthat::local_mocked_bindings(commonmark_available = function() FALSE)
  expect_equal(render_markdown("<b>hi</b>"), "<pre>&lt;b&gt;hi&lt;/b&gt;</pre>")
})
