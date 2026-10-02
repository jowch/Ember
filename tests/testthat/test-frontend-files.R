# Tests for the installed frontend and package metadata after piece 1
# ("Ember's look", docs/ui-2.md). Covers docs/ui-2-tests.md items 5, 6, 7.

frontend_dir <- function() {
  dir <- system.file("frontend", package = "ember")
  if (!nzchar(dir)) skip("installed frontend not found (system.file empty)")
  dir
}

frontend_files <- function(dir) {
  list.files(dir, recursive = TRUE, full.names = TRUE)
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
