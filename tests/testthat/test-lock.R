# Tests for R/lock.R: the lock type, its file format and its library
# naming. See docs/packages-tests.md, "Lock format" (tests 1-10).

r_info_fake <- function() list(version = "4.6.1", minor = "4.6",
                               platform = "x86_64-pc-linux-gnu")

test_that("parse_lock_lines reads name version source lines into sorted entries", {
  r <- parse_lock_lines(c("dplyr 1.1.4 CRAN", "cli 3.6.5 CRAN"))
  expect_equal(r$lock$entries$name, c("cli", "dplyr"))
  expect_equal(r$lock$entries$version, c("3.6.5", "1.1.4"))
  expect_equal(r$lock$entries$source, c("CRAN", "CRAN"))
  expect_equal(nrow(r$problems), 0)
})

test_that("a line's extra fields after the source survive a parse and format byte for byte", {
  line <- "mypkg 3f2a1c9 github:lab/mypkg@3f2a1c9 sha256:abcd"
  r <- parse_lock_lines(line)
  expect_equal(r$lock$entries$extra, "sha256:abcd")
  expect_equal(format_lock_lines(r$lock), line)
})

test_that("a malformed line goes to unparsed with a lock_line problem and is written back unchanged", {
  bad <- "123bad 1.0 CRAN"
  r <- parse_lock_lines(c("dplyr 1.1.4 CRAN", bad))
  expect_equal(r$lock$unparsed, bad)
  expect_equal(r$problems$kind, "lock_line")
  expect_equal(format_lock_lines(r$lock), c("dplyr 1.1.4 CRAN", bad))
})

test_that("a duplicate name keeps the first line and reports the second", {
  r <- parse_lock_lines(c("dplyr 1.1.4 CRAN", "dplyr 1.2.0 CRAN"))
  expect_equal(r$lock$entries$name, "dplyr")
  expect_equal(r$lock$entries$version, "1.1.4")
  expect_equal(r$lock$unparsed, "dplyr 1.2.0 CRAN")
  expect_equal(r$problems$kind, "lock_line")
  expect_equal(r$problems$package, "dplyr")
})

test_that("format_lock_lines sorts by name in C order whatever the session locale", {
  r <- parse_lock_lines(c("zlib 1.0 CRAN", "Apple 1.0 CRAN", "apple 1.0 CRAN"))
  expect_equal(r$lock$entries$name, sort(c("zlib", "Apple", "apple"), method = "radix"))
})

test_that("lock_diff reports added, removed, upgraded and downgraded with package_version order", {
  old <- new_lock(name = c("a", "b", "c"), version = c("1.0", "1.10.0", "2.0"),
                  source = c("CRAN", "CRAN", "CRAN"), extra = c("", "", ""))
  new <- new_lock(name = c("a", "b", "d"), version = c("1.0", "1.9.0", "1.0"),
                  source = c("CRAN", "CRAN", "CRAN"), extra = c("", "", ""))
  d <- lock_diff(old, new)
  expect_false("a" %in% d$name)
  expect_equal(d$change[d$name == "b"], "downgraded")
  expect_equal(d$change[d$name == "c"], "removed")
  expect_equal(d$change[d$name == "d"], "added")
})

test_that("library_for gives the same key for the same lines in any order, and a different key when one version changes", {
  r <- r_info_fake()
  l1 <- new_lock(name = c("dplyr", "cli"), version = c("1.1.4", "3.6.5"),
                source = c("CRAN", "CRAN"), extra = c("", ""))
  l2 <- new_lock(name = c("cli", "dplyr"), version = c("3.6.5", "1.1.4"),
                source = c("CRAN", "CRAN"), extra = c("", ""))
  l3 <- new_lock(name = c("cli", "dplyr"), version = c("3.6.6", "1.1.4"),
                source = c("CRAN", "CRAN"), extra = c("", ""))
  expect_equal(library_for(l1, r, "/cache")$key, library_for(l2, r, "/cache")$key)
  expect_false(identical(library_for(l1, r, "/cache")$key, library_for(l3, r, "/cache")$key))
})

test_that("library_for ignores extra fields and unparsed lines when hashing", {
  r <- r_info_fake()
  l1 <- new_lock(name = "dplyr", version = "1.1.4", source = "CRAN", extra = "")
  l2 <- new_lock(name = "dplyr", version = "1.1.4", source = "CRAN", extra = "sha256:xyz",
                unparsed = "garbage line")
  expect_equal(library_for(l1, r, "/cache")$key, library_for(l2, r, "/cache")$key)
})

test_that("library_for's path contains the R minor version and platform", {
  r <- r_info_fake()
  l <- new_lock(name = "dplyr", version = "1.1.4", source = "CRAN", extra = "")
  p <- library_for(l, r, "/cache")$path
  expect_true(grepl("R-4.6", p, fixed = TRUE))
  expect_true(grepl("x86_64-pc-linux-gnu", p, fixed = TRUE))
})

test_that("renv_lockfile_of gives one minimal record per entry and the dated CRAN URL", {
  l <- new_lock(name = c("dplyr", "cli"), version = c("1.1.4", "3.6.5"),
               source = c("CRAN", "CRAN"), extra = c("", ""))
  r <- list(version = "4.6.1")
  repos <- c(CRAN = "https://packagemanager.posit.co/cran/2026-09-01")
  lf <- renv_lockfile_of(l, r, repos)
  expect_equal(lf$Packages$dplyr$Version, "1.1.4")
  expect_equal(lf$Packages$dplyr$Source, "Repository")
  expect_equal(lf$Packages$dplyr$Repository, "CRAN")
  expect_equal(lf$Packages$cli$Version, "3.6.5")
  expect_identical(lf$R$Repositories, list(CRAN = unname(repos[["CRAN"]])))
  path <- tempfile(fileext = ".lock")
  renv::lockfile_write(lf, path)
  expect_identical(renv::lockfile_read(path)$R$Repositories[["CRAN"]], unname(repos[["CRAN"]]))
})
