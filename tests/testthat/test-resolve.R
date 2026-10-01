# Tests for R/resolve.R: the repository index and the closure walk. See
# docs/packages-tests.md, "Resolution with fixture indexes" (tests 16-25).
# No network: fixture indexes under fixtures/repos/cran/<date>/src/contrib.

idx1 <- read_repo_index(
  testthat::test_path("fixtures/repos/cran/2026-09-01/src/contrib/PACKAGES"),
  key = "cran/2026-09-01", label = "CRAN")
idx2 <- read_repo_index(
  testthat::test_path("fixtures/repos/cran/2026-09-30/src/contrib/PACKAGES"),
  key = "cran/2026-09-30", label = "CRAN")

dep_of <- function(idx, name) idx$deps[[which(idx$name == name)]]

test_that("read_repo_index drops version constraints and R, keeps Depends, Imports and LinkingTo but not Suggests", {
  expect_equal(dep_of(idx1, "withmethods"), "methods")
  expect_setequal(dep_of(idx1, "fastcalc"), c("cli", "Rcpp"))
  expect_setequal(dep_of(idx1, "dplyr"), c("cli", "glue"))
})

test_that("read_repo_index keeps the highest version of a duplicated entry", {
  expect_equal(sum(idx1$name == "oldie"), 1)
  expect_equal(idx1$version[idx1$name == "oldie"], "2.0.0")
})

test_that("resolving dplyr into an empty lock gives the full closure at the date's versions", {
  r <- resolve_lock("dplyr", empty_lock(), list("cran/2026-09-01" = idx1),
                    needed = "cran/2026-09-01")
  expect_true(r$complete)
  expect_equal(format_lock_lines(r$lock),
              c("cli 3.6.5 CRAN", "dplyr 1.1.4 CRAN", "glue 1.8.0 CRAN"))
})

test_that("adding glue keeps every existing entry at its locked version (mode keep)", {
  base <- resolve_lock("dplyr", empty_lock(), list("cran/2026-09-01" = idx1),
                       needed = "cran/2026-09-01")$lock
  r <- resolve_lock(c("dplyr", "glue"), base, list("cran/2026-09-01" = idx1),
                    needed = "cran/2026-09-01")
  expect_true(r$complete)
  expect_equal(format_lock_lines(r$lock), format_lock_lines(base))
})

test_that("removing dplyr from the roots drops the dependencies nothing else needs and keeps shared ones", {
  both <- resolve_lock(c("dplyr", "viz"), empty_lock(), list("cran/2026-09-01" = idx1),
                       needed = "cran/2026-09-01")$lock
  only_viz <- resolve_lock("viz", both, list("cran/2026-09-01" = idx1),
                           needed = "cran/2026-09-01")
  expect_true(only_viz$complete)
  expect_setequal(only_viz$lock$entries$name, c("cli", "viz"))
})

test_that("a name in no index gives a not_found problem and leaves the rest resolved", {
  r <- resolve_lock(c("dplyr", "nosuchpkg"), empty_lock(), list("cran/2026-09-01" = idx1),
                    needed = "cran/2026-09-01")
  expect_true(r$complete)
  expect_setequal(r$lock$entries$name, c("cli", "dplyr", "glue"))
  expect_equal(r$problems$kind[r$problems$package == "nosuchpkg"], "not_found")
})

test_that("a locked version that differs from the index gives off_date and is kept", {
  locked <- new_lock(name = "cli", version = "9.9.9", source = "CRAN", extra = "")
  r <- resolve_lock("cli", locked, list("cran/2026-09-01" = idx1), needed = "cran/2026-09-01")
  expect_true(r$complete)
  expect_equal(r$lock$entries$version[r$lock$entries$name == "cli"], "9.9.9")
  expect_equal(r$problems$kind[r$problems$package == "cli"], "off_date")
})

test_that("a recommended package reached as a dependency (Matrix) is locked", {
  r <- resolve_lock("spatial", empty_lock(), list("cran/2026-09-01" = idx1),
                    needed = "cran/2026-09-01")
  expect_true(r$complete)
  expect_true("Matrix" %in% r$lock$entries$name)
})

test_that("a missing index makes the result incomplete, names the key in fetch and returns the lock unchanged", {
  base <- empty_lock()
  r <- resolve_lock("dplyr", base, list(), needed = "cran/2026-09-01")
  expect_false(r$complete)
  expect_equal(r$fetch, "cran/2026-09-01")
  expect_identical(r$lock, base)
})

test_that("mode fresh at a later date moves every version and lock_diff lists them", {
  old <- resolve_lock("dplyr", empty_lock(), list("cran/2026-09-01" = idx1),
                      needed = "cran/2026-09-01")$lock
  new <- resolve_lock("dplyr", old, list("cran/2026-09-30" = idx2),
                      needed = "cran/2026-09-30", mode = "fresh")
  expect_true(new$complete)
  d <- lock_diff(old, new$lock)
  expect_setequal(d$name, c("cli", "dplyr"))
  expect_true(all(d$change == "upgraded"))
})
