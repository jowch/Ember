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

test_that("a locked package missing from the index (archived) keeps its own deps reachable (03)", {
  lock <- resolve_lock("another", empty_lock(), list("cran/2026-09-01" = idx1),
                       needed = "cran/2026-09-01")$lock
  expect_setequal(lock$entries$name, c("another", "standalone"))

  # The same date's index with "another" removed (archived, or a
  # hand-written line increment 1 has no index for).
  keep <- idx1$name != "another"
  idx_no_another <- new_repo_index(idx1$key, idx1$label, idx1$name[keep], idx1$version[keep],
                                   idx1$deps[keep], idx1$needs_compilation[keep])

  r <- resolve_lock(c("another", "glue"), lock, list("cran/2026-09-01" = idx_no_another),
                    needed = "cran/2026-09-01")
  expect_true(r$complete)
  expect_setequal(r$lock$entries$name, c("another", "standalone", "glue"))
  expect_equal(r$lock$entries$version[r$lock$entries$name == "another"], "0.5.0")
  expect_equal(r$problems$kind[r$problems$package == "another"], "not_in_index")
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

test_that("mode fresh keeps a lock row's extra field when its version didn't change", {
  # glue is 1.8.0 on both fixture dates; dplyr moves 1.1.4 -> 1.1.5.
  old <- resolve_lock("dplyr", empty_lock(), list("cran/2026-09-01" = idx1),
                      needed = "cran/2026-09-01")$lock
  old$entries$extra[old$entries$name == "glue"] <- "sha256:abcd"
  new <- resolve_lock("dplyr", old, list("cran/2026-09-30" = idx2),
                      needed = "cran/2026-09-30", mode = "fresh")
  expect_true(new$complete)
  expect_equal(new$lock$entries$extra[new$lock$entries$name == "glue"], "sha256:abcd")
  expect_equal(new$lock$entries$extra[new$lock$entries$name == "dplyr"], "")
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

# ---- Bioconductor (docs/packages-tests.md, 26 and 78-82) ---------------------

bioc_fixture <- function(kind, release = "3.23", date = "2026-09-01") {
  read_repo_index(
    testthat::test_path("fixtures/repos/bioc", date, "packages", release, bioc_kinds[[kind]],
                        "src/contrib/PACKAGES"),
    key = repo_key(kind, date, release), label = "Bioc")
}
r46 <- list(version = "4.6.1", minor = "4.6", platform = "x86_64-pc-linux-gnu")
header_at <- function(snapshot, bioc_version = NA_character_) {
  new_header(ember_version = "0.1.0", r_version = "4.6.1", snapshot = snapshot,
             bioc_version = bioc_version)
}

test_that("each Bioconductor kind has its own key and dated URL (78)", {
  repos <- ember_repos(bioc = "https://ppm.example/bioconductor")
  expect_equal(repo_url(repos, repo_key("bioc", "2026-09-01", "3.23")),
              "https://ppm.example/bioconductor/2026-09-01/packages/3.23/bioc")
  expect_equal(repo_url(repos, repo_key("bioc-ann", "2026-09-01", "3.23")),
              "https://ppm.example/bioconductor/2026-09-01/packages/3.23/data/annotation")
  expect_equal(repo_url(repos, repo_key("bioc-exp", "2026-09-01", "3.23")),
              "https://ppm.example/bioconductor/2026-09-01/packages/3.23/data/experiment")
  expect_equal(index_label_of_key("bioc-ann/2026-09-01/3.23"), "Bioc")
})

test_that("repo_urls lists the three Bioconductor repositories only with a pin (78)", {
  repos <- ember_repos()
  expect_named(repo_urls(repos, header_at("2026-09-01")), "CRAN")
  expect_named(repo_urls(repos, header_at("2026-09-01", "3.23")),
              c("CRAN", "BioCsoft", "BioCann", "BioCexp"))
})

test_that("the release is the latest one for the running R out by the snapshot date (79)", {
  expect_equal(bioc_release_for("4.5", "2025-09-01"), "3.21")
  expect_equal(bioc_release_for("4.5", "2025-10-30"), "3.22")
  expect_equal(bioc_release_for("4.5", "2026-09-01"), "3.22")
  # Before R 4.6's first release no dated repository exists yet.
  expect_true(is.na(bioc_release_for("4.6", "2026-03-01")))
  expect_true(is.na(bioc_release_for("9.9", "2026-09-01")))
  expect_true(is.na(bioc_release_for("4.6", NA_character_)))
})

test_that("needed_repos is CRAN, then Bioconductor's three at the pin or the derived release (79)", {
  expect_equal(needed_repos(header_at("2026-09-01"), r46),
              c("cran/2026-09-01", "bioc/2026-09-01/3.23", "bioc-ann/2026-09-01/3.23",
                "bioc-exp/2026-09-01/3.23"))
  expect_equal(needed_repos(header_at("2026-09-01", "3.22"), r46)[[2]], "bioc/2026-09-01/3.22")
  expect_equal(needed_repos(header_at("2026-09-01"), list(minor = "9.9")), "cran/2026-09-01")
})

test_that("a name missing from CRAN asks for the Bioconductor indexes, then resolves there with source Bioc (26)", {
  needed <- needed_repos(header_at("2026-09-01"), r46)
  r <- resolve_lock("DESeq2", empty_lock(), list("cran/2026-09-01" = idx1), needed = needed)
  expect_false(r$complete)
  expect_equal(r$fetch, needed[-1])

  idx <- list(idx1, bioc_fixture("bioc"), bioc_fixture("bioc-ann"), bioc_fixture("bioc-exp"))
  names(idx) <- needed
  r <- resolve_lock("DESeq2", empty_lock(), idx, needed = needed)
  expect_true(r$complete)
  expect_equal(format_lock_lines(r$lock),
              c("DESeq2 1.50.0 Bioc", "S4Vectors 0.48.0 Bioc", "cli 3.6.5 CRAN"))
})

test_that("a CRAN package needing an annotation package resolves it from the annotation repository (80)", {
  needed <- needed_repos(header_at("2026-09-01"), r46)
  idx <- list(idx1, bioc_fixture("bioc"), bioc_fixture("bioc-ann"), bioc_fixture("bioc-exp"))
  names(idx) <- needed
  r <- resolve_lock("wgcna", empty_lock(), idx, needed = needed)
  expect_true(r$complete)
  expect_equal(format_lock_lines(r$lock),
              c("AnnotationDbi 1.72.0 Bioc", "GO.db 3.22.0 Bioc", "S4Vectors 0.48.0 Bioc",
                "cli 3.6.5 CRAN", "impute 1.84.0 Bioc", "wgcna 1.73 CRAN"))
})

test_that("bioc_problems flags a release built for another R and a date outside its window (81)", {
  expect_equal(nrow(bioc_problems(header_at("2026-09-01"), r46)), 0)
  expect_equal(nrow(bioc_problems(header_at("2026-09-01", "3.23"), r46)), 0)
  p <- bioc_problems(header_at("2026-09-01", "3.22"), r46)
  expect_setequal(p$kind, c("bioc_r_version", "bioc_off_date"))
  expect_match(p$message[p$kind == "bioc_r_version"], "built for R 4.5; this is R 4.6", fixed = TRUE)
  expect_equal(bioc_problems(header_at("2026-03-01", "3.23"), r46)$kind, "bioc_off_date")
})
