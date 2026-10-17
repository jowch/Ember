# A package tarball stores no path over 100 bytes, counting the leading
# "ember/", so every fixture must fit (#244).

test_that("every fixture path fits in a package tarball (#244)", {
  root <- testthat::test_path("fixtures")
  paths <- c(list.files(root, recursive = TRUE, all.files = TRUE),
             list.dirs(root, full.names = FALSE, recursive = TRUE))
  long <- paths[nchar(file.path("ember/tests/testthat/fixtures", paths), type = "bytes") > 100]
  expect_equal(long, character(0))
})
