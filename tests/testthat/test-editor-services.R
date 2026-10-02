# Pure unit tests for R/editor-services.R (ui-2.md, "4. Editor services";
# ui-2-tests.md 49-55 except 52, which lives in test-pluto-state.R next to
# project_dependencies()'s other tests).

test_that("completion_context() (49)", {
  ctx <- completion_context("x <- dplyr::fil")
  expect_identical(ctx$namespace, "dplyr")
  expect_identical(ctx$token, "fil")
  expect_identical(ctx$start, 12L)

  ctx2 <- completion_context("\u00e9 <- me")
  expect_identical(ctx2$token, "me")
  expect_identical(nchar("\u00e9", type = "bytes"), 2L)
  expect_identical(ctx2$start, nchar("\u00e9 <- ", type = "bytes"))

  ctx3 <- completion_context("x <- 1\ny <- dpl")
  expect_identical(ctx3$line, "y <- dpl")
  expect_identical(ctx3$token, "dpl")
  expect_null(ctx3$namespace)
})

#' A minimal `state` for `fallback_completions()`: `fil_x` defined in cell
#' `A`, `dplyr` attached with `filter`/`select` exported.
fallback_state <- function() {
  list(
    graph = list(cells = list(
      A = list(definitions = c("fil_x")),
      B = list(definitions = character())
    )),
    packages = list(active = list(exports = list())),
    exports = list(dplyr = c("filter", "select"))
  )
}

test_that("fallback_completions() (50)", {
  st <- fallback_state()
  r <- fallback_completions(st, list(token = "fil", namespace = NULL))
  names <- vapply(r$items, `[[`, character(1), "name")
  expect_identical(names[1:2], c("fil_x", "filter"))
  expect_true("file.path" %in% names)
  expect_true(which(names == "file.path") > which(names == "filter"))
  expect_false(r$too_long)

  r2 <- fallback_completions(st, list(token = "", namespace = "dplyr"))
  expect_identical(sort(vapply(r2$items, `[[`, character(1), "name")), c("filter", "select"))

  many <- as.character(seq_len(600))
  st2 <- fallback_state()
  st2$exports <- list(bigpkg = many)
  r3 <- fallback_completions(st2, list(token = "", namespace = "bigpkg"))
  expect_true(r3$too_long)
  expect_length(r3$items, 500)
})

test_that("completion_reply() (51)", {
  ctx <- list(token = "fo", start = 5L)
  items <- list(too_long = FALSE, items = list(
    list(name = "formula=", kind = "argument", notebook = FALSE),
    list(name = "foo/", kind = "path", notebook = FALSE),
    list(name = "foo", kind = "function", notebook = TRUE)
  ))
  reply <- completion_reply(ctx, items)
  expect_identical(reply$start, 5L)
  expect_identical(reply$stop, 5L + nchar("fo", type = "bytes"))
  expect_length(reply$results, 3)
  for (r in reply$results) expect_length(r, 6)
  expect_identical(reply$results[[1]][[5]], "keyword_argument")
  expect_identical(reply$results[[2]][[5]], "path")
  expect_identical(reply$results[[3]][[2]], "Function")
  expect_identical(reply$results[[3]][[4]], TRUE)
  expect_false(reply$too_long)
})

test_that("rewrite_help_links() (53)", {
  expect_identical(
    rewrite_help_links('<a href="../../stats/help/sd">sd</a>'),
    '<a href="@ref stats::sd">sd</a>'
  )
  expect_identical(
    rewrite_help_links('<a href="https://cran.r-project.org">CRAN</a>'),
    '<a href="https://cran.r-project.org">CRAN</a>'
  )
})

test_that("sanitize_help_html() drops scripts, styles, iframes, event handlers and javascript: links", {
  dirty <- paste0(
    '<p onclick="evil()">hi</p>',
    '<script src="/doc/html/prism.js"></script>',
    "<script>alert(1)</script>",
    '<style>body{color:red}</style>',
    '<iframe src="https://evil.example"></iframe>',
    '<a href="javascript:alert(1)">bad</a>')
  clean <- sanitize_help_html(dirty)
  expect_no_match(clean, "<script", fixed = TRUE)
  expect_no_match(clean, "<style", fixed = TRUE)
  expect_no_match(clean, "<iframe", fixed = TRUE)
  expect_no_match(clean, "onclick", fixed = TRUE)
  expect_no_match(clean, "javascript:", fixed = TRUE)
  expect_match(clean, "<p>hi</p>", fixed = TRUE)
})

test_that("signature_fallback() (55)", {
  expect_match(signature_fallback("lm"), "^lm\\(formula, data")
  expect_null(signature_fallback("my_fun"))
})
