# Tests for the installed frontend and package metadata after pieces 1 and
# 2 ("Ember's look" and "Offline bundle", docs/ui-2.md). Covers
# docs/ui-2-tests.md items 5, 6, 7, 13, 14.

frontend_dir <- function() {
  dir <- system.file("frontend", package = "ember")
  if (!nzchar(dir)) skip("installed frontend not found (system.file empty)")
  dir
}

frontend_files <- function(dir) {
  list.files(dir, recursive = TRUE, full.names = TRUE)
}

#' Every `https?://` URL in `dir`'s `.js`/`.css`/`.html` files that sits in
#' an import/load position -- a static or dynamic JS import, an HTML
#' `<link>`/`<script>`'s `src=`/`href=`, or a CSS `url()` -- except one
#' naming something in `allow` (a substring match). A plain `<a href>` is
#' not a load (ui-2-tests.md 13's note) and is deliberately not checked:
#' only `<link>`/`<script>` tags are.
external_url_hits <- function(dir, allow = "mathjax@") {
  url_re <- "https?://[^\"'()\\s>]+"
  is_allowed <- function(url) any(vapply(allow, function(a) grepl(a, url, fixed = TRUE), logical(1)))

  # Strip comments before scanning: a URL mentioned in a `//`/`/* */`/
  # `<!-- -->` comment (a stale CDN note, a vendored file's own doc header)
  # is text, not a load, the same way ui-2-tests.md 13 exempts a plain
  # `<a href>`.
  strip_comments <- function(text, ext) {
    text <- gsub("(?s)/\\*.*?\\*/", "", text, perl = TRUE)
    if (identical(ext, "html")) text <- gsub("(?s)<!--.*?-->", "", text, perl = TRUE)
    # `(?<!:)` so a `//` straight after a colon -- "https://", "http://" --
    # is never mistaken for a line comment's start.
    if (identical(ext, "js")) text <- gsub("(?m)(?<!:)//[^\n]*$", "", text, perl = TRUE)
    text
  }

  read_text <- function(f, ext) {
    text <- tryCatch(readChar(f, file.info(f)$size, useBytes = TRUE), error = function(e) NA_character_)
    if (is.na(text)) return(text)
    strip_comments(text, ext)
  }

  scan_pattern <- function(files, pattern, ext) {
    hits <- character(0)
    for (f in files) {
      text <- read_text(f, ext)
      if (is.na(text)) next
      found <- regmatches(text, gregexpr(pattern, text, perl = TRUE))[[1]]
      for (m in found) {
        url <- regmatches(m, regexpr(url_re, m, perl = TRUE))
        if (length(url) == 0 || !nzchar(url) || is_allowed(url)) next
        hits <- c(hits, paste0(f, ": ", m))
      }
    }
    hits
  }

  files <- frontend_files(dir)
  js <- files[grepl("\\.js$", files)]
  css <- files[grepl("\\.css$", files)]
  html <- files[grepl("\\.html$", files)]

  hits <- c(
    scan_pattern(js, paste0('\\bfrom\\s*\\(?\\s*["\']', url_re), "js"),
    scan_pattern(js, paste0('\\bimport\\(\\s*["\']', url_re), "js"),
    scan_pattern(css, paste0("url\\(\\s*[\"']?", url_re), "css"))

  for (f in html) {
    text <- read_text(f, "html")
    if (is.na(text)) next
    tags <- regmatches(text, gregexpr("<(link|script)\\b[^>]*>", text, perl = TRUE, ignore.case = TRUE))[[1]]
    for (tag in tags) {
      attrs <- regmatches(tag, gregexpr(paste0("(src|href)\\s*=\\s*[\"']", url_re, "[\"']"),
                                        tag, perl = TRUE, ignore.case = TRUE))[[1]]
      for (a in attrs) {
        url <- regmatches(a, regexpr(url_re, a, perl = TRUE))
        if (length(url) == 0 || !nzchar(url) || is_allowed(url)) next
        hits <- c(hits, paste0(f, ": ", a))
      }
    }
  }
  hits
}

# ---- 5. No EMBER flag, no calling-home strings, deleted files stay gone ----

test_that("the installed frontend has no EMBER checks or calling-home strings (5)", {
  dir <- frontend_dir()
  files <- frontend_files(dir)

  forbidden <- c("EMBER", "plutojl.org", "fonsp.com", "stats.plutojl", "openai.com", "firebasejs")
  hits <- character()
  for (f in files) {
    text <- tryCatch(readChar(f, file.info(f)$size, useBytes = TRUE), error = function(e) NA_character_)
    if (is.na(text)) next
    for (pat in forbidden) {
      if (grepl(pat, text, fixed = TRUE)) hits <- c(hits, paste(f, pat, sep = ": "))
    }
  }
  expect_equal(hits, character(0))

  expect_false(file.exists(file.path(dir, "common", "EmberFlags.js")))
  expect_false(file.exists(file.path(dir, "common", "Feedback.js")))
  expect_false(file.exists(file.path(dir, "components", "FixWithAIButton.js")))
  expect_false(dir.exists(file.path(dir, "components", "welcome")))
})

# ---- 6. Every Pluto CSS variable name survives in both themes -------------

test_that("every name in pluto-css-variables.txt is defined in both themes (6)", {
  dir <- frontend_dir()
  names <- readLines(testthat::test_path("fixtures", "pluto-css-variables.txt"))
  names <- names[nzchar(names)]

  for (theme in c("light.css", "dark.css")) {
    text <- readChar(file.path(dir, "themes", theme), file.info(file.path(dir, "themes", theme))$size)
    missing <- names[!vapply(names, function(n) grepl(paste0(n, "\\s*:"), text), logical(1))]
    expect_equal(missing, character(0), info = theme)
  }
})

# ---- 7. Credits ------------------------------------------------------------

test_that("inst/COPYRIGHTS and DESCRIPTION credit Pluto.jl (7)", {
  copyrights_path <- system.file("COPYRIGHTS", package = "ember")
  if (!nzchar(copyrights_path)) skip("installed COPYRIGHTS not found")
  copyrights <- readChar(copyrights_path, file.info(copyrights_path)$size)
  expect_true(grepl("Pluto.jl", copyrights, fixed = TRUE))

  desc_path <- system.file("DESCRIPTION", package = "ember")
  if (!nzchar(desc_path)) skip("installed DESCRIPTION not found")
  d <- read.dcf(desc_path)
  people <- eval(parse(text = d[, "Authors@R"]))
  cph <- Filter(function(p) "cph" %in% p$role, people)
  expect_true(length(cph) >= 1)
  expect_true(any(grepl("Pluto.jl", vapply(cph, function(p) paste(p$given, p$family), character(1)))))
})

# ---- 13. No external URL except the MathJax allowlist ---------------------

test_that("the installed frontend has no external URL in a load position, except MathJax (13)", {
  dir <- frontend_dir()
  expect_equal(external_url_hits(dir), character(0))
})

test_that("external_url_hits() catches a planted CDN import (13)", {
  dir <- frontend_dir()
  tmp <- tempfile("ember-frontend-copy-")
  dir.create(tmp)
  file.copy(dir, dirname(tmp), recursive = TRUE)
  copy_dir <- file.path(dirname(tmp), basename(dir))
  on.exit(unlink(copy_dir, recursive = TRUE), add = TRUE)

  target <- file.path(copy_dir, "imports", "AnsiUp.js")
  text <- readChar(target, file.info(target)$size)
  writeLines(c('import { foo } from "https://cdn.jsdelivr.net/npm/foo@1.0.0/+esm"', text), target)

  hits <- external_url_hits(copy_dir)
  expect_true(length(hits) >= 1)
  expect_true(any(grepl("AnsiUp.js", hits, fixed = TRUE)))
})

# ---- 14. Frontend size, THIRD-PARTY.txt, COPYRIGHTS cross-check -----------

test_that("the installed frontend is under 3 MB and THIRD-PARTY.txt matches COPYRIGHTS (14)", {
  dir <- frontend_dir()
  files <- frontend_files(dir)
  total_bytes <- sum(vapply(files, function(f) file.info(f)$size, numeric(1)))
  expect_lt(total_bytes, 3 * 1024 * 1024)

  third_party_path <- file.path(dir, "imports", "vendor", "THIRD-PARTY.txt")
  expect_true(file.exists(third_party_path))
  third_party <- readChar(third_party_path, file.info(third_party_path)$size)
  names <- regmatches(third_party, gregexpr("(?m)^Name: (.+)$", third_party, perl = TRUE))[[1]]
  names <- sub("^Name: ", "", names)
  expect_true(length(names) > 0)

  copyrights_path <- system.file("COPYRIGHTS", package = "ember")
  if (!nzchar(copyrights_path)) skip("installed COPYRIGHTS not found")
  copyrights <- readChar(copyrights_path, file.info(copyrights_path)$size)
  missing <- names[!vapply(names, function(n) grepl(n, copyrights, fixed = TRUE), logical(1))]
  expect_equal(missing, character(0))
})
