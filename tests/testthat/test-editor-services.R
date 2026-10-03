# Pure unit tests for R/editor-services.R (ui-2.md, "4. Editor services";
# ui-2-tests.md 50-56 except 53, which lives in test-pluto-state.R next to
# project_dependencies()'s other tests).

test_that("completion_context() (50)", {
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

test_that("completion_context() start is a byte offset into the whole query, not just the last line", {
  # "x <- 1\nme": the token is on line 2, after a first line of 7 bytes
  # ("x <- 1") plus the newline.
  ctx <- completion_context("x <- 1\nme")
  expect_identical(ctx$token, "me")
  expect_identical(ctx$start, nchar("x <- 1\n", type = "bytes"))

  # A trailing newline must not drop the (empty) last line: the token
  # being completed is on a fresh, empty line right after it, not back on
  # the previous line.
  ctx2 <- completion_context("x <- 1\n")
  expect_identical(ctx2$line, "")
  expect_identical(ctx2$token, "")
  expect_identical(ctx2$start, nchar("x <- 1\n", type = "bytes"))

  # Non-ASCII on an earlier line: its UTF-8 byte length (not character
  # count) must be what's added to the offset.
  ctx3 <- completion_context("y <- 'é'\nme")
  expect_identical(ctx3$token, "me")
  expect_identical(nchar("é", type = "bytes"), 2L)
  expect_identical(ctx3$start, nchar("y <- 'é'\n", type = "bytes"))
})

test_that("the fallback offers nothing after $ or @, where only the worker knows the fields", {
  for (q in c("df$", "df$m", "obj@", "x <- df $ ")) {
    ctx <- completion_context(q)
    expect_true(ctx$field, info = q)
    expect_length(fallback_completions(list(), ctx, base = c("mean", "max"))$items, 0)
  }
  expect_false(completion_context("me")$field)
  expect_false(completion_context("stats::me")$field)
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

test_that("fallback_completions() (51)", {
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

test_that("worker_completion_items() strips the worker's $/@/path prefix so names match ctx$start", {
  ctx <- completion_context("df$m")
  expect_identical(ctx$token, "m")
  reply <- list(token = "df$m", items = list(list(name = "df$mpg", kind = "other", notebook = FALSE)),
               too_long = FALSE)
  out <- worker_completion_items(ctx, reply)
  expect_identical(out$items[[1]]$name, "mpg")
  expect_identical(out$token, "m")

  ctx2 <- completion_context("p@slot")
  reply2 <- list(token = "p@slot", items = list(list(name = "p@slotx", kind = "other", notebook = FALSE)),
                too_long = FALSE)
  out2 <- worker_completion_items(ctx2, reply2)
  expect_identical(out2$items[[1]]$name, "slotx")

  ctx3 <- completion_context("x <- \"sub/fi")
  reply3 <- list(token = "sub/fi", items = list(list(name = "sub/file.R", kind = "path", notebook = FALSE)),
                too_long = FALSE)
  out3 <- worker_completion_items(ctx3, reply3)
  expect_identical(out3$items[[1]]$name, "file.R")

  # A plain completion (no $/@/path receiver): the worker's token equals
  # ctx$token, so nothing is stripped.
  ctx4 <- list(token = "fil")
  reply4 <- list(token = "fil", items = list(list(name = "file", kind = "function", notebook = FALSE)),
                too_long = FALSE)
  out4 <- worker_completion_items(ctx4, reply4)
  expect_identical(out4$items[[1]]$name, "file")
})

test_that("completion_reply() (52)", {
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

test_that("rewrite_help_links() (54)", {
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

test_that("signature_fallback() (56)", {
  expect_match(signature_fallback("lm"), "^lm\\(formula, data")
  expect_null(signature_fallback("my_fun"))
})

#' Whether `pkg` is installed, without loading it: unlike
#' `requireNamespace()` (and `testthat::skip_if_not_installed()`, which
#' calls it), `system.file(package = ...)` only looks the package up on
#' disk. These tests are about code that must not load a package as a
#' side effect, so checking "is it installed" must not load it either.
pkg_installed_unloaded <- function(pkg) {
  nzchar(system.file(package = pkg)) && !isNamespaceLoaded(pkg)
}

test_that("fallback_completions() for pkg:: never loads an installed-but-unloaded package", {
  skip_if_not(pkg_installed_unloaded("boot"), "boot not installed, or already loaded")

  st <- fallback_state()
  r <- fallback_completions(st, list(token = "", namespace = "boot"))
  expect_false(isNamespaceLoaded("boot"))
  expect_length(r$items, 0)
})

test_that("signature_fallback() for an explicit, unloaded package never loads it", {
  skip_if_not(pkg_installed_unloaded("codetools"), "codetools not installed, or already loaded")

  expect_null(signature_fallback("findGlobals", package = "codetools"))
  expect_false(isNamespaceLoaded("codetools"))
})
