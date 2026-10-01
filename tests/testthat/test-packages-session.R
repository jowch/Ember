# Session end to end, with real installs: the R API, a real worker and the
# real installer (inst/installer.R, real renv), against the `file://` toy
# repo fixture (tests/testthat/fixtures/repos/toy): two tiny pure-R source
# packages, `toyA` (imports `toyB`) at version 0.1 on 2026-09-01 and 0.2 on
# 2026-09-30, so renv restores offline with no compiler and no network.
#
# The toy repo stands in for CRAN itself: `ember_repos(cran = "file://...")`
# points the ordinary CRAN resolution and install path at the fixture, so
# no mock is needed anywhere (docs/packages.md, "The test seam is the
# repository URL").
#
# Covers docs/packages-tests.md items 70-75 ("Session end to end, offline"
# and the opt-in network test). Waits use `wait_for()`/`run_cells(wait =
# TRUE)`/`preview_date(wait = TRUE)`, never `Sys.sleep` loops. Every
# notebook and temp cache made here is removed on exit.

# ---- Helpers ---------------------------------------------------------------

use_installed_ember()

#' `ember_repos()` pointed at the toy fixture repo instead of CRAN: the
#' fixture's own layout (`<root>/<date>/src/contrib/PACKAGES`) is exactly
#' what `repo_url()` expects for a `"cran/<date>"` key, so no other code
#' needs to know the packages aren't really from CRAN.
toy_repos <- function() {
  root <- normalizePath(testthat::test_path("fixtures", "repos", "toy"), mustWork = TRUE)
  ember_repos(cran = paste0("file://", root))
}

#' A fresh, private cache directory for one test: libraries, indexes and
#' renv's own cache all live under it, so tests never share installs or
#' touch the real user cache.
toy_cache <- function() {
  path <- tempfile("ember-pkg-cache-")
  dir.create(path, recursive = TRUE)
  path
}

#' A notebook file naming `toyA`, at `snapshot`, written to a fresh temp
#' folder. The lock starts empty: resolution and the install are exactly
#' what `open_notebook()` + `run_cells()` are being tested to do.
write_toy_notebook <- function(snapshot = "2026-09-01", dir = NULL) {
  if (is.null(dir)) {
    dir <- tempfile("ember-nb-")
    dir.create(dir, recursive = TRUE)
  }
  setup_id <- "S"
  cell_id <- "A"
  cells <- list(S = list(code = "", kind = "code", folded = FALSE),
               A = list(code = "library(toyA)\ntoyA_hello()", kind = "code", folded = FALSE))
  header <- new_header(ember_version = as.character(utils::packageVersion("ember")),
                       r_version = paste(R.version$major, R.version$minor, sep = "."),
                       snapshot = snapshot)
  file <- new_notebook_file(
    header = header, cells = cells, setup = setup_id, run_order = names(cells),
    learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = empty_lock(), extra_blocks = list(), format = ember_format)
  path <- file.path(dir, "nb.R")
  ok <- write_atomic(path, format_notebook(file))
  stopifnot(ok)
  path
}

#' Package statuses `package_status(nb)$library$status` passes through
#' while `pred` (a predicate on the full status list) isn't satisfied,
#' collected via `on_notebook_event()` so a transient "installing" isn't
#' missed between two `wait_for()` polls.
watch_library_statuses <- function(nb) {
  seen <- character()
  unsub <- on_notebook_event(nb, function(note) {
    if (identical(note$kind, "packages_changed")) {
      seen <<- c(seen, package_status(nb)$library$status)
    }
  })
  list(seen = function() seen, stop = unsub)
}

# ---- 70: first run installs toyA and toyB -----------------------------------

test_that("a notebook with library(toyA) on the file:// toy repo installs toyA and toyB on first run (70)", {
  repos <- toy_repos()
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  path <- write_toy_notebook("2026-09-01")

  nb <- open_notebook(path, repos = repos, cache = cache)
  on.exit(close_notebook(nb), add = TRUE)

  res <- run_cells(nb, wait = TRUE, timeout = 120)
  expect_false(res$timed_out)

  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, "A")$status, "ok")
  expect_equal(snap_view(snap, "A")$output$text, "[1] \"toyA 0.1 says: hello from toyB\"")

  status <- package_status(nb)
  expect_equal(status$library$status, "ready")
  pkgs <- status$packages
  expect_setequal(pkgs$name, c("toyA", "toyB"))
  expect_equal(pkgs$version[pkgs$name == "toyA"], "0.1")
  expect_equal(pkgs$version[pkgs$name == "toyB"], "1.0")
  expect_true(all(pkgs$status == "installed"))
})

# ---- 71: a second notebook with the same lock reuses the library -----------

test_that("adding a second notebook with the same lock reuses the library folder (71)", {
  repos <- toy_repos()
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)

  path1 <- write_toy_notebook("2026-09-01")
  nb1 <- open_notebook(path1, repos = repos, cache = cache)
  on.exit(close_notebook(nb1), add = TRUE)
  res1 <- run_cells(nb1, wait = TRUE, timeout = 120)
  expect_false(res1$timed_out)
  lib1 <- package_status(nb1)$library$path

  path2 <- write_toy_notebook("2026-09-01")
  nb2 <- open_notebook(path2, repos = repos, cache = cache)
  on.exit(close_notebook(nb2), add = TRUE)
  watch <- watch_library_statuses(nb2)

  res2 <- run_cells(nb2, wait = TRUE, timeout = 120)
  watch$stop()
  expect_false(res2$timed_out)

  lib2 <- package_status(nb2)$library$path
  expect_equal(lib2, lib1)
  # The manifest was already on disk: the target goes straight from
  # "unknown" (via the Look stage's one file read) to "ready", never
  # through "installing" -- no installer subprocess ran for nb2.
  expect_false("installing" %in% watch$seen())
  expect_equal(package_status(nb2)$library$status, "ready")
})

# ---- 72: moving the date upgrades toyA and restarts the worker -------------

test_that("moving the toy date upgrades toyA, restarts the loaded worker, and the cell reruns with 0.2 (72)", {
  repos <- toy_repos()
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  path <- write_toy_notebook("2026-09-01")

  nb <- open_notebook(path, repos = repos, cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 120)
  expect_false(res$timed_out)
  expect_equal(snap_view(notebook_snapshot(nb), "A")$output$text,
              "[1] \"toyA 0.1 says: hello from toyB\"")

  preview <- preview_date(nb, as.Date("2026-09-30"), wait = TRUE, timeout = 120)
  expect_equal(preview$status, "ready")
  up <- preview$changes[preview$changes$name == "toyA", ]
  expect_equal(up$change, "upgraded")
  expect_equal(up$from, "0.1")
  expect_equal(up$to, "0.2")

  set_date(nb, as.Date("2026-09-30"))

  # The new library installs, then the worker restarts (toyA's version
  # changed under it) once that library is ready: every cell goes back to
  # not run, with the restart's reason in worker_message.
  ok <- wait_for(nb, function(snap) {
    v <- snap_view(snap, "A")
    identical(v$status, "not_run") && !is.null(snap$worker_message) &&
      grepl("toyA", snap$worker_message, fixed = TRUE)
  }, timeout = 120)
  expect_true(ok)

  res2 <- run_cells(nb, wait = TRUE, timeout = 120)
  expect_false(res2$timed_out)
  expect_equal(snap_view(notebook_snapshot(nb), "A")$output$text,
              "[1] \"toyA 0.2 says: hello from toyB\"")
  expect_equal(notebook_state(nb)$file$header$snapshot, "2026-09-30")
})

# ---- 73: the saved lock round-trips -----------------------------------------

test_that("the saved file's lock block lists toyA and toyB and round-trips unchanged on reopen (73)", {
  repos <- toy_repos()
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  path <- write_toy_notebook("2026-09-01")

  nb <- open_notebook(path, repos = repos, cache = cache)
  res <- run_cells(nb, wait = TRUE, timeout = 120)
  expect_false(res$timed_out)
  close_notebook(nb)

  text1 <- read_file_utf8(path)
  expect_match(text1, "toyA 0.1 CRAN", fixed = TRUE)
  expect_match(text1, "toyB 1.0 CRAN", fixed = TRUE)

  nb2 <- open_notebook(path, repos = repos, cache = cache)
  on.exit(close_notebook(nb2), add = TRUE)
  wait_for(nb2, is_idle, timeout = 10)
  close_notebook(nb2)

  text2 <- read_file_utf8(path)
  expect_identical(text2, text1)
})

# ---- 74: ember::run() --------------------------------------------------------

test_that("ember::run() on the saved file installs if needed and prints the cell's output with the locked version (74)", {
  repos <- toy_repos()
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  path <- write_toy_notebook("2026-09-01")

  # Saved with a resolved lock first, the way a session leaves the file:
  # run() itself never resolves (docs/packages.md: "the lock is the
  # authority here").
  nb <- open_notebook(path, repos = repos, cache = cache)
  res <- run_cells(nb, wait = TRUE, timeout = 120)
  expect_false(res$timed_out)
  close_notebook(nb)

  out <- testthat::capture_output(status <- run(path, repos = repos, cache = cache, echo = TRUE))
  expect_equal(status, 0L)
  expect_match(out, "toyA 0.1 says: hello from toyB", fixed = TRUE)
})

# ---- 75: network, opt-in -----------------------------------------------------

test_that("[net] a notebook with library(dplyr) at a fixed past date resolves, installs and loads from PPM (75)", {
  skip_if_not(identical(Sys.getenv("EMBER_TEST_NETWORK"), "1"),
             "set EMBER_TEST_NETWORK=1 to run the opt-in network test")

  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  dir <- tempfile("ember-nb-")
  dir.create(dir, recursive = TRUE)
  cells <- list(S = list(code = "", kind = "code", folded = FALSE),
               A = list(code = "library(dplyr)\npackageVersion(\"dplyr\")",
                        kind = "code", folded = FALSE))
  header <- new_header(ember_version = as.character(utils::packageVersion("ember")),
                       r_version = paste(R.version$major, R.version$minor, sep = "."),
                       snapshot = "2026-06-01")  # after R 4.6.0: binaries exist
  file <- new_notebook_file(
    header = header, cells = cells, setup = "S", run_order = names(cells), learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = empty_lock(), extra_blocks = list(), format = ember_format)
  path <- file.path(dir, "nb.R")
  write_atomic(path, format_notebook(file))

  nb <- open_notebook(path, repos = ember_repos(), cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 300)
  expect_false(res$timed_out)

  status <- package_status(nb)
  expect_true("dplyr" %in% status$packages$name)
  expect_equal(status$packages$status[status$packages$name == "dplyr"], "installed")

  locked_version <- status$packages$version[status$packages$name == "dplyr"]
  snap <- notebook_snapshot(nb)
  expect_match(snap_view(snap, "A")$output$text, locked_version, fixed = TRUE)
  expect_equal(notebook_state(nb)$worker$loaded[["dplyr"]], locked_version)
})
