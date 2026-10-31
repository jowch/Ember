# Tests for step 3's core: the `state$packages` fields, `schedule_packages()`
# and the new `step()` reducers (R/packages-core.R, plus the step-3 changes
# in R/state.R and R/step.R). No process, no network: `drive()` (from
# helper-core.R) folds `step()` over synthetic events, including fake
# `index_fetched`/`library_checked`/`install_done` events standing in for
# the shell's subprocess jobs, and checks `check_state()` after each one.
#
# Covers docs/packages-tests.md items 28-58 ("Core: packages in step()")
# and 67-69 ("Worker (test-worker.R additions)", in test-worker.R instead).
#
# Index fixtures: tests/testthat/fixtures/repos/cran/<date>/src/contrib/PACKAGES
# (docs/packages-tests.md's fixture list): dplyr -> cli, glue; viz -> cli;
# spatial -> Matrix (recommended); cli and dplyr both move version between
# 2026-09-01 and 2026-09-30.

# ---- Local helpers (packages-specific; not in helper-core.R) -----------------

#' A notebook file with package-related header fields `fake_file()` doesn't
#' expose (`snapshot`, `extra_packages`, `lock`).
pkg_file <- function(cells, snapshot = "2026-09-01",
                     extra_packages = character(), lock = empty_lock(),
                     on_cell_change = "autorun", bioc_version = NA_character_) {
  new_notebook_file(
    header = new_header(ember_version = "0.1.0", r_version = "4.3.0", snapshot = snapshot,
                        bioc_version = bioc_version, on_cell_change = on_cell_change,
                        extra_packages = extra_packages),
    cells = cells, run_order = names(cells), learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = lock, extra_blocks = list(), format = 1L, read_only = FALSE, problems = NULL)
}

#' Bioconductor's release list as bioconductor.org served it on 2026-10-08.
fixture_releases <- function(name = "config.yaml") {
  parse_bioc_config(readLines(testthat::test_path("fixtures", "bioc-config", name), warn = FALSE))
}

#' A fresh session state with package-related fields, otherwise like
#' `fake_state()`. It starts with the fixture release list unless a test
#' passes its own `repos`; the tests below "Bioconductor's release list"
#' cover fetching it.
pkg_state <- function(cells, ..., options = list(), at = 0) {
  if (is.null(options$repos)) options$bioc_releases <- options$bioc_releases %||% fixture_releases()
  file <- pkg_file(cells, ...)
  new_state(file, path = "nb.R", id = "n1", options = options, at = at)
}

#' The CRAN fixture index at `date`, read from disk once per call (no
#' network, no mock: the same `read_repo_index()` PPM would go through).
cran_index <- function(date = "2026-09-01") {
  read_repo_index(testthat::test_path("fixtures", "repos", "cran", date, "src", "contrib", "PACKAGES"),
                  key = repo_key("cran", date), label = "CRAN")
}

#' A fake library manifest for `ev_library_checked()`/`ev_install_done()`.
manifest <- function(installed = character(), exports = list()) {
  list(installed = installed, exports = exports)
}

#' Op constructors for the two edit ops in R/api-packages.R (its own file;
#' duplicated here in the shape `reduce_apply()` expects, matching
#' `add_extra_package()`/`remove_extra_package()` there).
op_add_extra_package <- function(name) list(op = "add_extra_package", name = name)
op_remove_extra_package <- function(name) list(op = "remove_extra_package", name = name)

#' The type of every effect in a `drive()` result (or a plain effects list).
effect_types <- function(result) {
  effects <- if (!is.null(result$effects)) result$effects else result
  vapply(effects, function(e) e$type, character(1))
}

#' The first effect of `type` in a `drive()` result.
find_effect <- function(result, type) {
  effects <- if (!is.null(result$effects)) result$effects else result
  Find(function(e) identical(e$type, type), effects)
}

#' A running R that has a Bioconductor release (3.23) in `bioc_releases`.
r46 <- list(version = "4.6.1", minor = "4.6", platform = "x86_64-pc-linux-gnu")

#' The Bioconductor 3.23 fixture index of `kind`
#' (fixtures/bioc/2026-09-01/packages/3.23/...), keyed as `release`
#' at `date`.
bioc_index <- function(kind, release = "3.23", date = "2026-09-01") {
  idx <- read_repo_index(testthat::test_path("fixtures", "bioc", "2026-09-01", "packages",
                                             "3.23", bioc_kinds[[kind]], "src", "contrib", "PACKAGES"),
                         key = repo_key(kind, date, release), label = "Bioc")
  idx
}

#' Drive `s` through open and CRAN's index at 2026-09-01.
open_with_cran <- function(s) {
  r <- drive(s, ev_open(at(1)))
  drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index("2026-09-01"), at(2)))
}

#' Deliver each of Bioconductor's three indexes the state is fetching.
deliver_bioc <- function(state, release = "3.23", date = "2026-09-01", t = 3) {
  r <- list(state = state, effects = list())
  for (kind in names(bioc_kinds)) {
    r <- drive(r$state, ev_index_fetched(repo_key(kind, date, release),
                                         bioc_index(kind, release, date), at(t)))
  }
  r
}

# ---- Resolving --------------------------------------------------------------

test_that("opening a notebook whose lock already answers its code emits no effect (28)", {
  s <- pkg_state(list(S = cell("")))
  r <- drive(s, ev_open(at(1)))
  expect_equal(r$effects, list())
  expect_equal(r$state$packages$resolved_for, character())
  expect_equal(r$state$packages$active$status, "ready")
})

test_that("a notebook whose code names a package the lock lacks emits fetch_index (29)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  expect_equal(effect_types(r), "fetch_index")
  expect_equal(find_effect(r, "fetch_index")$key, repo_key("cran", "2026-09-01"))
})

test_that("a notebook with no snapshot date gets the event's date when its first package appears (30)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")), snapshot = NA_character_)
  r <- drive(s, ev_open(as.Date("2026-09-15")))
  expect_equal(r$state$file$header$snapshot, "2026-09-15")
  expect_equal(find_effect(r, "fetch_index")$key, repo_key("cran", "2026-09-15"))
})

test_that("the new snapshot date uses the local date, not UTC's", {
  # A time that is still "2026-09-15" locally in a far-west zone, but
  # already "2026-09-16" in UTC: `as.Date()` on a POSIXct defaults to UTC,
  # which would pick the wrong day for that session.
  old_tz <- Sys.getenv("TZ", unset = NA)
  Sys.setenv(TZ = "Etc/GMT+10")  # UTC-10: always behind UTC
  on.exit(if (is.na(old_tz)) Sys.unsetenv("TZ") else Sys.setenv(TZ = old_tz), add = TRUE)
  at_local_evening <- as.POSIXct("2026-09-15 23:00:00", tz = "Etc/GMT+10")
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")), snapshot = NA_character_)
  r <- drive(s, ev_open(at_local_evening))
  expect_equal(r$state$file$header$snapshot, "2026-09-15")
})

test_that("index_fetched resolves, writes the lock, and the derived file text changes (31)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  idx <- cran_index("2026-09-01")
  r2 <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), idx, at(2)))
  expect_setequal(r2$state$file$lock$entries$name, c("cli", "dplyr", "glue"))
  expect_equal(r2$state$packages$resolved_for, "dplyr")
  text <- format_notebook(notebook_file_of(r2$state))
  expect_match(text, "dplyr 1.1.4 CRAN", fixed = TRUE)
})

test_that("a duplicate index_fetched is a no-op (32)", {
  key <- repo_key("cran", "2026-09-01")
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  idx <- cran_index("2026-09-01")
  r2 <- drive(r$state, ev_index_fetched(key, idx, at(2)))
  r3 <- drive(r2$state, ev_index_fetched(key, idx, at(3)))
  expect_equal(r3$effects, list())
  expect_equal(r3$state$seq, r2$state$seq)
})

test_that("index_failed keeps the lock and adds index_unavailable; same wanted set doesn't refetch (33)", {
  key <- repo_key("cran", "2026-09-01")
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r2 <- drive(r$state, ev_index_failed(key, "network down", at(2)))
  expect_equal(nrow(r2$state$file$lock$entries), 0)
  expect_true("index_unavailable" %in% r2$state$packages$problems$kind)

  # An unrelated edit still leaves the wanted set at just "dplyr"; the failed
  # slot's `wanted` matches, so it isn't refetched.
  r3 <- drive(r2$state, ev_apply(list(op_set_code("S", "1 + 1")), at(3)))
  expect_equal(effect_types(r3), character())
  expect_true("index_unavailable" %in% r3$state$packages$problems$kind)
})

test_that("a date not published yet moves back a day while nothing is locked, and resolves there (#162)", {
  s <- pkg_state(list(A = cell("library(dplyr)")), snapshot = "2026-10-01")
  r <- drive(s, ev_open(at(1)))
  expect_equal(find_effect(r, "fetch_index")$key, repo_key("cran", "2026-10-01"))
  r <- drive(r$state, ev_index_failed(repo_key("cran", "2026-10-01"), "cran/2026-10-01 isn't published",
                                      at(2), unpublished = TRUE))
  expect_equal(r$state$file$header$snapshot, "2026-09-30")
  expect_null(r$state$packages$indexes[[repo_key("cran", "2026-10-01")]])
  expect_equal(find_effect(r, "fetch_index")$key, repo_key("cran", "2026-09-30"))
  expect_equal(nrow(r$state$packages$problems), 0)
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(3)))
  expect_setequal(r$state$file$lock$entries$name, c("dplyr", "cli", "glue"))
})

test_that("an unpublished date stays, with the failure shown, when the lock has packages or the fetch just failed (#162)", {
  key <- repo_key("cran", "2026-10-01")
  locked <- new_lock("cli", "3.6.3", "CRAN")
  s <- pkg_state(list(A = cell("library(dplyr)")), snapshot = "2026-10-01", lock = locked)
  r <- drive(s, ev_open(at(1)), ev_index_failed(key, "cran/2026-10-01 isn't published", at(2), unpublished = TRUE))
  expect_equal(r$state$file$header$snapshot, "2026-10-01")
  expect_true("index_unavailable" %in% r$state$packages$problems$kind)

  # Offline, or anything but a 404 for a recent date: nothing says the date
  # is the problem, so it stays.
  s <- pkg_state(list(A = cell("library(dplyr)")), snapshot = "2026-10-01")
  r <- drive(s, ev_open(at(1)), ev_index_failed(key, "could not resolve host", at(2)))
  expect_equal(r$state$file$header$snapshot, "2026-10-01")
  expect_true("index_unavailable" %in% r$state$packages$problems$kind)
})

test_that("a preview of a date not published yet moves back a day and offers that one; any other failure fails it (#162)", {
  s <- pkg_state(list(A = cell("library(dplyr)")), snapshot = "2026-09-01")
  r <- drive(s, ev_open(at(1)), ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index("2026-09-01"), at(2)))
  expect_setequal(r$state$file$lock$entries$name, c("dplyr", "cli", "glue"))

  key <- repo_key("cran", "2026-10-01")
  p <- drive(r$state, ev_preview_date("2026-10-01", at(3)))
  expect_equal(find_effect(p, "fetch_index")$key, key)
  p <- drive(p$state, ev_index_failed(key, "cran/2026-10-01 isn't published", at(4), unpublished = TRUE))
  expect_equal(p$state$packages$proposal$date, "2026-09-30")
  expect_equal(p$state$packages$proposal$asked, "2026-10-01")
  expect_null(p$state$packages$indexes[[key]])
  expect_equal(find_effect(p, "fetch_index")$key, repo_key("cran", "2026-09-30"))
  p <- drive(p$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(5)))
  expect_equal(p$state$packages$proposal$status, "ready")
  expect_equal(packages_view(p$state)$proposal$asked, "2026-10-01")
  expect_equal(p$state$file$header$snapshot, "2026-09-01")

  # Offline, or anything but a 404 for a recent date: the preview fails for
  # the date it was asked for, as before.
  p <- drive(r$state, ev_preview_date("2026-10-01", at(3)),
             ev_index_failed(key, "could not resolve host", at(4)))
  expect_equal(p$state$packages$proposal$date, "2026-10-01")
  expect_equal(p$state$packages$proposal$status, "failed")
})

# ---- Looking at and installing the library ------------------------------------

test_that("in safe preview a missing library is checked but never installed (34)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(2)))
  expect_true("check_library" %in% effect_types(r))

  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(3)))
  expect_equal(r$state$packages$target$status, "missing")
  expect_false("install" %in% effect_types(r))
  expect_false(isTRUE(r$state$allowed))
})

test_that("after allow, a missing target emits exactly one install; a second event emits none (35)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(2)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(3)))

  r <- drive(r$state, ev_allow(at(4)))
  expect_equal(sum(effect_types(r) == "install"), 1)
  expect_equal(r$state$packages$target$status, "installing")

  r2 <- drive(r$state, ev_render("nonexistent", at(5)))
  expect_equal(sum(effect_types(r2) == "install"), 0)
})

test_that("a queued cell waiting for an install says what it waits for, and the page gets when the install started (#590)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)"), B = cell("1 + 1")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(2)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(3)))
  js <- pluto_state(r$state)$js
  expect_null(js$ember$install_started_at)

  r <- drive(r$state, ev_allow(at(4)), ev_run("A", at(5)))
  js <- pluto_state(r$state)$js
  expect_true(check_wire(js))
  expect_equal(js$ember$install_started_at, 4)
  expect_equal(unlist(js$cell_results$A$ember$waiting_for), "dplyr")
  expect_null(js$cell_results$B$ember$waiting_for)

  token <- r$state$packages$install$token
  r <- drive(r$state, ev_install_done(token, r$state$packages$target$key, NULL, "renv failed", character(), at(6)))
  js <- pluto_state(r$state)$js
  expect_null(js$ember$install_started_at)
  # A failed install lets the cell run (and fail), so it no longer waits.
  expect_null(js$cell_results$A$ember$waiting_for)
})

test_that("a lock change during an install waits for the running job, then installs the new target (36)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(2)))
  old_key <- r$state$packages$target$key
  r <- drive(r$state, ev_library_checked(old_key, NULL, at(3)))
  r <- drive(r$state, ev_allow(at(4)))
  expect_equal(r$state$packages$install$key, old_key)
  old_token <- r$state$packages$install$token

  # Add a package directly (viz, also resolved from the already-loaded
  # index): the lock, and so the target library, changes while the old
  # install is still running.
  r <- drive(r$state, ev_apply(list(op_add_extra_package("viz")), at(5)))
  new_key <- r$state$packages$target$key
  expect_false(identical(new_key, old_key))
  expect_equal(r$state$packages$install$key, old_key)
  expect_equal(sum(effect_types(r) == "install"), 0)

  r <- drive(r$state, ev_library_checked(new_key, NULL, at(6)))
  r <- drive(r$state, ev_install_done(old_token, old_key, NULL, NULL, character(), at(7)))
  expect_null_or_new <- r$state$packages$install
  expect_equal(r$state$packages$install$key, new_key)
  expect_equal(sum(effect_types(r) == "install"), 1)
  expect_equal(find_effect(r, "install")$key, new_key)
})

test_that("install_done for an old token or key leaves the target alone (37)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(2)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(3)))
  r <- drive(r$state, ev_allow(at(4)))
  key <- r$state$packages$target$key
  token <- r$state$packages$install$token

  r2 <- drive(r$state, ev_install_done(token + 1000L, key, manifest(c(dplyr = "1.1.4")), NULL, character(), at(5)))
  expect_equal(r2$state$packages$install, r$state$packages$install)
  expect_equal(r2$state$packages$target$status, "installing")
})

test_that("install_done with no manifest marks the target failed and adds install_failed (38)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(2)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(3)))
  r <- drive(r$state, ev_allow(at(4)))
  key <- r$state$packages$target$key
  token <- r$state$packages$install$token

  r2 <- drive(r$state, ev_install_done(token, key, NULL, "renv failed", c("compiler missing"), at(5)))
  expect_equal(r2$state$packages$target$status, "failed")
  expect_true("install_failed" %in% r2$state$packages$problems$kind)
  expect_null(r2$state$packages$install)
})

test_that("a failed target is not retried until ev_run, which retries it once (39)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(2)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(3)))
  r <- drive(r$state, ev_allow(at(4)))
  key <- r$state$packages$target$key
  token <- r$state$packages$install$token
  r <- drive(r$state, ev_install_done(token, key, NULL, "renv failed", character(), at(5)))
  expect_equal(r$state$packages$target$status, "failed")

  r2 <- drive(r$state, ev_apply(list(op_fold("A", TRUE)), at(6)))
  expect_equal(sum(effect_types(r2) == "install"), 0)
  expect_equal(r2$state$packages$target$status, "failed")

  r3 <- drive(r2$state, ev_run(NULL, at(7)))
  expect_equal(r3$state$packages$target$status, "installing")
  expect_equal(sum(effect_types(r3) == "install"), 1)
})

# ---- Waiting cells ------------------------------------------------------------

test_that("a cell attaching a package not yet installed stays pending and is not sent (40)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)\n1 + 1")))
  r <- boot(s, "A")
  expect_true("A" %in% r$state$pending)
  expect_false(identical(last_sent(r)$cell, "A"))
})

test_that("a cell downstream of a waiting cell is not sent; an unrelated cell is (41)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)\nx <- 1"),
                      B = cell("y <- x + 1"), C = cell("z <- 2")))
  r <- boot(s, c("A", "B", "C"))
  expect_true(all(c("A", "B") %in% r$state$pending))
  expect_equal(last_sent(r)$cell, "C")
})

test_that("a cell using a not_found package is sent and doesn't wait (43)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(nosuchpkg)")), options = list(r = r46))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(2)))
  # Not on CRAN, so Bioconductor's indexes are looked at too.
  r <- deliver_bioc(r$state)
  expect_true("not_found" %in% r$state$packages$problems$kind)

  r <- boot(r$state, "A", at0 = 10)
  expect_equal(last_sent(r)$cell, "A")
})

test_that("when the library becomes ready the waiting cell is sent with the new library path (42)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)\n1 + 1")))
  r <- boot(s, "A")
  expect_false(identical(last_sent(r)$cell, "A"))

  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(20)))
  target_key <- r$state$packages$target$key
  r <- drive(r$state, ev_library_checked(target_key, NULL, at(21)))
  r <- drive(r$state, ev_install_done(r$state$packages$install$token, target_key,
                                      manifest(c(dplyr = "1.1.4", cli = "3.6.5", glue = "1.8.0")),
                                      NULL, character(), at(22)))
  expect_equal(last_sent(r)$cell, "A")
  expect_equal(last_sent(r)$library, r$state$packages$active$path)
  expect_equal(r$state$packages$active$key, target_key)
})

test_that("a cell rerun to wait for an install marks its dependents stale meanwhile, and they rerun after it (#248)", {
  s <- pkg_state(list(S = cell(""), A = cell("x <- 1"), B = cell("y <- x + 1")))
  r <- boot(s, c("A", "B"))
  expect_equal(last_sent(r)$cell, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(4)))
  expect_equal(last_sent(r)$cell, "B")
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(5)))
  expect_false(r$state$results$B$stale)

  r <- drive(r$state, ev_apply(list(op_set_code("A", "library(dplyr)\nx <- 2")), at(6)),
             ev_run("A", at(7)))
  expect_true("A" %in% r$state$pending)
  expect_null(last_sent(r))
  expect_true(r$state$results$B$stale)
  # Queued when A is sent, not before: it can't run ahead of A.
  expect_false("B" %in% r$state$pending)

  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(20)))
  target_key <- r$state$packages$target$key
  r <- drive(r$state, ev_library_checked(target_key, NULL, at(21)))
  r <- drive(r$state, ev_install_done(r$state$packages$install$token, target_key,
                                      manifest(c(dplyr = "1.1.4", cli = "3.6.5", glue = "1.8.0")),
                                      NULL, character(), at(22)))
  expect_equal(last_sent(r)$cell, "A")
  r <- drive(r$state, wk_done(r$state$worker$gen, last_token(r), report(created = "x"), at(23)))
  expect_equal(last_sent(r)$cell, "B")
})

test_that("a cell run by hand waits for an edited ancestor that waits for an install (#604)", {
  s <- pkg_state(list(S = cell(""), A = cell("x <- 1"), B = cell("y <- x + 1")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(4)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "y"), at(5)))

  # A no longer defines x, and needs a package the library doesn't have.
  # Running B runs the edited A first (#174), so B mustn't run while A
  # waits: it would read A's old x. `dplyr::` attaches nothing, so B has no
  # edge to A and isn't waiting itself.
  r <- drive(r$state, ev_apply(list(op_set_code("A", "z <- dplyr::n_distinct(1)")), at(6)),
             ev_run("B", at(7)))
  expect_setequal(r$state$pending, c("A", "B"))
  expect_null(last_sent(r))

  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(20)))
  target_key <- r$state$packages$target$key
  r <- drive(r$state, ev_library_checked(target_key, NULL, at(21)))
  r <- drive(r$state, ev_install_done(r$state$packages$install$token, target_key,
                                      manifest(c(dplyr = "1.1.4", cli = "3.6.5", glue = "1.8.0")),
                                      NULL, character(), at(22)))
  expect_equal(last_sent(r)$cell, "A")
  r <- drive(r$state, wk_done(r$state$worker$gen, last_token(r), report(created = "z"), at(23)))
  expect_equal(last_sent(r)$cell, "B")
})

test_that("a waiting settings cell marks later cells stale without letting them run first (#248)", {
  s <- pkg_state(list(S = cell(""), A = cell("options(digits = 3)"), B = cell("z <- 2")))
  r <- boot(s, c("A", "B"))
  r <- drive(r$state, wk_done(1, last_token(r), report(settings = list(list(kind = "option", name = "digits", before = 7, after = 3))), at(4)))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "z"), at(5)))
  expect_false(r$state$results$B$stale)

  r <- drive(r$state, ev_apply(list(op_set_code("A", "library(dplyr)\noptions(digits = 4)")), at(6)),
             ev_run("A", at(7)))
  expect_true(r$state$results$B$stale)
  expect_null(last_sent(r))
})

test_that("while another cell runs, a cell waiting for an install costs an event nothing (#248)", {
  # A chain of n cells below A, which waits on dplyr, while C runs.
  busy_state <- function(n, a_code) {
    chain <- setNames(lapply(seq_len(n), function(i) cell(sprintf("b%d <- %s + 1", i, if (i == 1) "x" else paste0("b", i - 1)))),
                      paste0("B", seq_len(n)))
    s <- pkg_state(c(list(S = cell(""), C = cell("z <- 1"), A = cell(a_code)), chain))
    r <- boot(s, c("C", "A"))
    expect_equal(last_sent(r)$cell, "C")
    r$state
  }
  waiting <- busy_state(300, "library(dplyr)\nx <- 1")
  plain <- busy_state(300, "x <- 1")
  expect_false(is.null(waiting_cells(waiting)$A))
  r <- time_ratio(function() schedule(waiting), function() schedule(plain), samples = 11L)
  cat(sprintf("\n[timing] schedule() with a busy worker, 300-cell chain: A waiting %.3f ms, not waiting %.3f ms (%.1fx)\n",
              r$a * 1000, r$b * 1000, r$ratio))
  expect_lt(r$ratio, 3)
})

test_that("waiting_cells() stays linear in the number of cells while one waits for an install (#258)", {
  skip_on_cran()  # too slow for CRAN's check time; CI runs it (#536)
  # A waits on dplyr, whose exports aren't known yet; every cell below it
  # also has a reference that resolves to nothing, so each one goes through
  # the unknown-exports check and is a waiting cell with its own downstream.
  waiting <- function(n) {
    chain <- setNames(lapply(seq_len(n), function(i) {
      cell(sprintf("b%d <- %s + nrow(mtcars) + typo%d", i, if (i == 1) "1" else paste0("b", i - 1), i))
    }), paste0("B", seq_len(n)))
    fake_state(c(list(S = cell(""), A = cell("library(dplyr)")), chain),
               lock = new_lock(name = "dplyr", version = "1.1.4", source = "CRAN"))
  }
  big <- waiting(300)
  small <- waiting(100)
  w <- waiting_cells(big)
  expect_equal(length(w), 301)
  expect_equal(w$B300, "dplyr")
  r <- time_ratio(function() waiting_cells(big), function() waiting_cells(small), samples = 11L)
  cat(sprintf("\n[timing] waiting_cells(): 300-cell chain %.2f ms, 100-cell chain %.2f ms (%.1fx)\n",
              r$a * 1000, r$b * 1000, r$ratio))
  expect_lt(r$ratio, 6)   # linear is 3x; the per-cell walk this replaced was ~10x
  expect_lt(r$a, 0.3)
})

# ---- Library readiness and restarts -------------------------------------------

#' Get a notebook using dplyr through install, the worker started and the
#' cell run once, so `worker$loaded` has dplyr at the first date's version.
#' Returns the `drive()` result positioned right after that.
dplyr_running <- function() {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)\n1 + 1")))
  r <- boot(s, "A")
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index("2026-09-01"), at(20)))
  key <- r$state$packages$target$key
  r <- drive(r$state, ev_library_checked(key, NULL, at(21)))
  r <- drive(r$state, ev_install_done(r$state$packages$install$token, key,
                                      manifest(c(dplyr = "1.1.4", cli = "3.6.5", glue = "1.8.0")),
                                      NULL, character(), at(22)))
  expect_equal(last_sent(r)$cell, "A")
  r <- drive(r$state, wk_done(r$state$worker$gen, last_token(r),
                             report(created = "x", loaded = c(dplyr = "1.1.4", cli = "3.6.5", glue = "1.8.0")),
                             at(23)))
  r
}

test_that("a ready target with no version conflict becomes active without a restart (44)", {
  r <- dplyr_running()
  gen_before <- r$state$worker$gen
  # Adding glue's dependency closure again (viz, which only needs cli, not a
  # new dplyr version) exercises a lock change with no conflict.
  r2 <- drive(r$state, ev_apply(list(op_add_extra_package("viz")), at(30)))
  key2 <- r2$state$packages$target$key
  r2 <- drive(r2$state, ev_library_checked(key2, NULL, at(31)))
  r2 <- drive(r2$state, ev_install_done(r2$state$packages$install$token, key2,
                                        manifest(c(dplyr = "1.1.4", cli = "3.6.5", glue = "1.8.0", viz = "2.0.0")),
                                        NULL, character(), at(32)))
  expect_equal(r2$state$packages$active$key, key2)
  expect_equal(r2$state$worker$gen, gen_before)
  expect_identical(r2$state$worker$status, "ready")
})

test_that("a ready target that changes a loaded package's version restarts the worker (45)", {
  r <- dplyr_running()
  gen_before <- r$state$worker$gen

  r2 <- drive(r$state, ev_preview_date(as.Date("2026-09-30"), at(30)))
  r2 <- drive(r2$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(31)))
  r2 <- drive(r2$state, ev_set_date(as.Date("2026-09-30"), at(32)))
  key2 <- r2$state$packages$target$key

  r2 <- drive(r2$state, ev_library_checked(key2, NULL, at(33)))
  r2 <- drive(r2$state, ev_install_done(r2$state$packages$install$token, key2,
                                        manifest(c(dplyr = "1.1.5", cli = "3.6.6", glue = "1.8.0")),
                                        NULL, character(), at(34)))

  expect_true(r2$state$worker$gen > gen_before)
  expect_equal(r2$state$results, list())
  expect_match(r2$state$worker$exit$message, "dplyr")
  expect_equal(r2$state$packages$active$key, key2)
})

test_that("a conflicting switch while a cell runs waits for done, sends nothing new, then restarts (46)", {
  r <- dplyr_running()
  gen_before <- r$state$worker$gen

  # Start a new run of A so the worker is busy when the newer library
  # becomes ready.
  r <- drive(r$state, ev_run("A", at(30)))
  expect_identical(r$state$worker$status, "busy")
  running_token <- r$state$worker$running$token

  r2 <- drive(r$state, ev_preview_date(as.Date("2026-09-30"), at(31)))
  r2 <- drive(r2$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(32)))
  r2 <- drive(r2$state, ev_set_date(as.Date("2026-09-30"), at(33)))
  key2 <- r2$state$packages$target$key
  r2 <- drive(r2$state, ev_library_checked(key2, NULL, at(34)))
  r2 <- drive(r2$state, ev_install_done(r2$state$packages$install$token, key2,
                                        manifest(c(dplyr = "1.1.5", cli = "3.6.6", glue = "1.8.0")),
                                        NULL, character(), at(35)))
  # The switch is pending: the worker is still busy on the old library, so
  # nothing new was sent and the active library hasn't moved yet.
  expect_identical(r2$state$worker$gen, gen_before)
  expect_false(identical(r2$state$packages$active$key, key2))
  expect_identical(r2$state$worker$status, "busy")

  r3 <- drive(r2$state, wk_done(r2$state$worker$gen, running_token, report(created = "x"), at(36)))
  expect_true(r3$state$worker$gen > gen_before)
  expect_equal(r3$state$packages$active$key, key2)
})

# ---- Missing-package errors ----------------------------------------------------

test_that("a worker packageNotFoundError outside the lock gives a missing_package error (48)", {
  s <- pkg_state(list(S = cell(""), A = cell("1 + 1")))
  r <- boot(s, "A")
  r <- drive(r$state, wk_done(1, last_token(r), report(error = list(message = "there is no package called 'nope'",
                                                                    package = "nope")), at(10)))
  v <- snapshot_of(r$state)$cells$A
  expect_equal(v$errors[[1]]$kind, "missing_package")
  expect_match(v$errors[[1]]$fixes, "nope")
  expect_match(v$errors[[1]]$fixes, "extra_packages")
})

test_that("the same error for a package the active library claims makes the library be checked again (49)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)\n1 + 1")))
  r <- boot(s, "A")
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(20)))
  key <- r$state$packages$target$key
  r <- drive(r$state, ev_library_checked(key, NULL, at(21)))
  r <- drive(r$state, ev_install_done(r$state$packages$install$token, key,
                                      manifest(c(dplyr = "1.1.4", cli = "3.6.5", glue = "1.8.0")),
                                      NULL, character(), at(22)))
  expect_equal(last_sent(r)$cell, "A")
  r <- drive(r$state, wk_done(r$state$worker$gen, last_token(r),
                             report(error = list(message = "there is no package called 'dplyr'", package = "dplyr")),
                             at(23)))
  # `active` stays "ready" (check_state()'s invariant: it's always what the
  # worker last had, even while stale); `target` is put back to "unknown",
  # and schedule_packages() immediately re-checks it in the same dispatch.
  expect_equal(r$state$packages$active$status, "ready")
  expect_true("check_library" %in% effect_types(r))
})

test_that("a packageNotFoundError for a package already wanted doesn't offer to add it again (05)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)), ev_index_failed(repo_key("cran", "2026-09-01"),
                                                "could not resolve host", at(2)))
  expect_true("index_unavailable" %in% r$state$packages$problems$kind)
  r <- boot(r$state, "A", at0 = 3)
  # boot()'s ev_run() retries the failed index once (reduce_run()'s "I want
  # this to work now" rule), clearing the slot; it fails again before the
  # cell's wk_done arrives, same as the reproduction.
  r <- drive(r$state, ev_index_failed(repo_key("cran", "2026-09-01"), "could not resolve host", at(9)))
  expect_true("index_unavailable" %in% r$state$packages$problems$kind)
  r <- drive(r$state, wk_done(1, last_token(r), report(status = "error",
    error = list(message = "there is no package called 'dplyr'", package = "dplyr")), at(10)))
  e <- r$state$results$A$error
  expect_equal(e$kind, "missing_package")
  expect_match(e$message, "could not resolve host", fixed = TRUE)
  expect_equal(e$fixes, character())
  expect_false(grepl("extra_packages", e$message))
})

test_that("shutdown leaves a still-fetching index job, not just a running install", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  expect_equal(r$state$packages$indexes[[repo_key("cran", "2026-09-01")]]$status, "fetching")

  r <- drive(r$state, ev_shutdown(at(2)))
  ce <- find_effect(r, "cancel_fetch_index")
  expect_false(is.null(ce))
  expect_equal(ce$key, repo_key("cran", "2026-09-01"))
})

# ---- extra_packages ops --------------------------------------------------------

test_that("library_checked exports give a cell attaching the package edges before it runs (47)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)\nfilter(1)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(2)))
  key <- r$state$packages$target$key
  r <- drive(r$state, ev_library_checked(key, manifest(c(dplyr = "1.1.4", cli = "3.6.5", glue = "1.8.0"),
                                                       exports = list(dplyr = "filter")), at(3)))
  expect_true("filter" %in% unlist(r$state$graph$cells$A$references %||% character()) ||
             "dplyr" %in% r$state$graph$cells$A$attaches)
})

test_that("add_extra_package changes the header and resolves (50)", {
  s <- pkg_state(list(S = cell("")))
  r <- drive(s, ev_apply(list(op_add_extra_package("svglite")), at(1)))
  expect_equal(r$state$file$header$extra_packages, "svglite")
  expect_true("fetch_index" %in% effect_types(r))
})

test_that("remove_extra_package is refused for a name already from code (50)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_apply(list(op_remove_extra_package("dplyr")), at(1)))
  expect_s3_class(r$reply, "ember_refused")
})

test_that("remove_extra_package removes a name not referenced in code (50)", {
  s <- pkg_state(list(S = cell("")), extra_packages = "svglite")
  r <- drive(s, ev_apply(list(op_remove_extra_package("svglite")), at(1)))
  expect_equal(r$state$file$header$extra_packages, character())
})

# ---- Moving the date ------------------------------------------------------------

test_that("preview_date fetches the date's index and fills the proposal's changes (51)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index("2026-09-01"), at(2)))

  r <- drive(r$state, ev_preview_date(as.Date("2026-09-30"), at(3)))
  expect_true(r$reply)
  expect_true("fetch_index" %in% effect_types(r))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(4)))
  prop <- r$state$packages$proposal
  expect_equal(prop$status, "ready")
  expect_true("dplyr" %in% prop$changes$name)
  expect_equal(prop$changes$change[prop$changes$name == "dplyr"], "upgraded")
})

test_that("preview_date retries a failed index fetch for that date (04)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index("2026-09-01"), at(2)))

  r <- drive(r$state, ev_preview_date(as.Date("2026-09-30"), at(3)))
  r <- drive(r$state, ev_index_failed(repo_key("cran", "2026-09-30"), "timeout (network blip)", at(4)))
  expect_equal(r$state$packages$proposal$status, "failed")

  # Network is back; the user asks again. Without the fix the failed slot
  # is never refetched, so no effect appears and the proposal stays failed.
  r2 <- drive(r$state, ev_preview_date(as.Date("2026-09-30"), at(5)))
  expect_true("fetch_index" %in% effect_types(r2))
  expect_equal(r2$state$packages$proposal$status, "fetching")
})

test_that("a preview fetches a provisional index again, and keeps one that isn't (#39)", {
  # The shell marks today's index provisional; the core has no clock.
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index("2026-09-01"), at(2),
                                       provisional = TRUE))
  expect_true(r$state$packages$indexes[["cran/2026-09-01"]]$provisional)
  expect_equal(r$state$file$lock$entries$version[r$state$file$lock$entries$name == "dplyr"], "1.1.4")

  # Later that day Package Manager has more: the preview of the same date
  # asks for the index again and resolves against what arrives.
  r2 <- drive(r$state, ev_preview_date(as.Date("2026-09-01"), at(3)))
  expect_equal(vapply(r2$effects, function(e) e$key, character(1)), "cran/2026-09-01")
  expect_true(r2$effects[[1]]$fresh)
  r2 <- drive(r2$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index("2026-09-30"), at(4)))
  prop <- r2$state$packages$proposal
  expect_equal(prop$status, "ready")
  expect_equal(prop$changes$change[prop$changes$name == "dplyr"], "upgraded")
  expect_false(r2$state$packages$indexes[["cran/2026-09-01"]]$provisional)

  # An index that isn't provisional is the date's for good.
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index("2026-09-01"), at(2)))
  r3 <- drive(r$state, ev_preview_date(as.Date("2026-09-01"), at(3)))
  expect_false("fetch_index" %in% effect_types(r3))
  expect_equal(r3$state$packages$proposal$status, "ready")

  # A date the session has no index for is asked for fresh too: the shell
  # skips a saved copy only when its date is recent enough to change.
  r4 <- drive(r$state, ev_preview_date(as.Date("2026-09-30"), at(3)))
  expect_equal(vapply(r4$effects, function(e) e$key, character(1)), "cran/2026-09-30")
  expect_true(r4$effects[[1]]$fresh)
})

test_that("set_date replaces problems with the proposal's, not the old date's (06)", {
  # dplyr hand-edited to a version the 2026-09-01 index doesn't have:
  # an off_date problem at the old date.
  lock <- new_lock(c("cli", "dplyr", "glue"), c("3.6.5", "1.1.3", "1.8.0"), rep("CRAN", 3))
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)\nlibrary(viz)")), lock = lock)
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index("2026-09-01"), at(2)))
  expect_true("off_date" %in% r$state$packages$problems$kind)

  r <- drive(r$state, ev_preview_date(as.Date("2026-09-30"), at(3)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(4)))
  prop_problems <- r$state$packages$proposal$problems

  r <- drive(r$state, ev_set_date(as.Date("2026-09-30"), at(5)))
  expect_false("off_date" %in% r$state$packages$problems$kind)
  expect_equal(r$state$packages$problems, prop_problems)
})

test_that("set_date is refused without a ready, current preview for that date (52)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_set_date(as.Date("2026-09-30"), at(1)))
  expect_s3_class(r$reply, "ember_refused")
})

test_that("set_date moves the header date and the lock in one step (53)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index("2026-09-01"), at(2)))
  r <- drive(r$state, ev_preview_date(as.Date("2026-09-30"), at(3)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(4)))

  r <- drive(r$state, ev_set_date(as.Date("2026-09-30"), at(5)))
  expect_equal(r$state$file$header$snapshot, as.Date("2026-09-30"))
  expect_true(all(r$state$file$lock$entries$version[r$state$file$lock$entries$name == "dplyr"] == "1.1.5"))
  expect_null(r$state$packages$proposal)
})

test_that("an edit that changes the wanted set recomputes a ready proposal (54)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index("2026-09-01"), at(2)))
  r <- drive(r$state, ev_preview_date(as.Date("2026-09-30"), at(3)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(4)))
  expect_equal(r$state$packages$proposal$status, "ready")

  r2 <- drive(r$state, ev_apply(list(op_add_extra_package("viz")), at(5)))
  # viz's index is already loaded (same CRAN repos), so the proposal
  # recomputes to "ready" again (`for_wanted` catches up), rather than
  # staying stale for the old wanted set. viz's version is the same on both
  # fixture dates, so it's in the proposal's lock without being in its
  # `changes` (nothing to report for an unchanged package).
  expect_equal(r2$state$packages$proposal$status, "ready")
  expect_setequal(r2$state$packages$proposal$for_wanted, c("dplyr", "viz"))
  expect_true("viz" %in% r2$state$packages$proposal$lock$entries$name)
})

# ---- Updating one package (docs/packages-tests.md, 77) -----------------------

#' CRAN's release dates as `cran_release_table()` gives them, for the
#' fixture's dplyr: 1.1.4 current from 2026-08-01, 1.1.5 from `new_on`.
release_table <- function(new_on = "2026-09-30") {
  data.frame(package = c("dplyr", "dplyr", "dplyr"), version = c("1.1.3", "1.1.4", "1.1.5"),
             date = as.Date(c("2026-06-01", "2026-08-01", new_on)), stringsAsFactors = FALSE)
}

#' The fixture's index at `date` (the files of 2026-09-01 or 2026-09-30),
#' keyed as `as`: a snapshot of a day in between.
cran_index_as <- function(date, as) {
  read_repo_index(testthat::test_path("fixtures", "repos", "cran", date, "src", "contrib", "PACKAGES"),
                  key = repo_key("cran", as), label = "CRAN")
}

today <- as.Date("2026-10-10")

test_that("update_date takes a newer version's first day and an older one's last", {
  t <- release_table()
  up <- update_date(t, "dplyr", NULL, "1.1.4")
  expect_equal(up$version, "1.1.5")
  expect_equal(up$date, as.Date("2026-09-30"))
  expect_equal(up$step, 1L)
  expect_true(is.na(up$last))
  pin <- update_date(t, "dplyr", "1.1.3", "1.1.4")
  expect_equal(pin$date, as.Date("2026-07-31"))
  expect_equal(pin$step, -1L)
  expect_equal(pin$last, as.Date("2026-06-01"))
  mid <- update_date(t, "dplyr", "1.1.4", "1.1.3")
  expect_equal(mid$date, as.Date("2026-08-01"))
  expect_equal(mid$last, as.Date("2026-09-29"))

  expect_match(update_date(t, "dplyr", "9.9.9", "1.1.4")$message, "never released dplyr 9.9.9")
  expect_match(update_date(t, "nope", NULL, "1.0")$message, "no record of a package called 'nope'")
  expect_match(update_date(t, "dplyr", "1.1.4", "1.1.4")$message, "already at 1.1.4")
  same_day <- rbind(t, data.frame(package = "dplyr", version = "1.1.6", date = as.Date("2026-09-30")))
  expect_match(update_date(same_day, "dplyr", "1.1.5", "1.1.4")$message, "replaced by 1.1.6 the day it came out")
})

test_that("cran_release_table reads archive.rds and current.rds as CRAN writes them", {
  info <- function(files, times) {
    data.frame(size = rep(1, length(files)),
               mtime = as.POSIXct(times, tz = "UTC"), row.names = files)
  }
  archive <- list(dplyr = info(c("dplyr/dplyr_1.1.3.tar.gz", "dplyr/dplyr_1.1.4.tar.gz"),
                               c("2026-06-01 10:00:00", "2026-08-01 23:30:00")),
                  old.pkg = info("old.pkg/old.pkg_0.1-2.tar.gz", "2020-01-02 03:04:05"))
  current <- info(c("dplyr_1.1.5.tar.gz", "zoo_1.8-12.tar.gz"), c("2026-09-30 08:00:00", "2026-01-01 00:00:00"))
  t <- cran_release_table(archive, current)
  expect_equal(t$package, c("dplyr", "dplyr", "dplyr", "old.pkg", "zoo"))
  expect_equal(t$version, c("1.1.3", "1.1.4", "1.1.5", "0.1-2", "1.8-12"))
  expect_equal(t$date, as.Date(c("2026-06-01", "2026-08-01", "2026-09-30", "2020-01-02", "2026-01-01")))
})

test_that("cran_release_table orders versions released the same day by the time they came out (77)", {
  # BFS 0.5 at 12:32 and 0.5.1 at 22:23 on 2023-06-08: by file name, 0.5.1
  # sorts first, and the day alone can't tell them apart.
  archive <- list(BFS = data.frame(size = c(1, 1),
                                   mtime = as.POSIXct(c("2023-06-08 22:23:00", "2023-06-08 12:32:00"), tz = "UTC"),
                                   row.names = c("BFS/BFS_0.5.1.tar.gz", "BFS/BFS_0.5.tar.gz")))
  current <- data.frame(size = 1, mtime = as.POSIXct("2023-08-11 09:00:00", tz = "UTC"),
                        row.names = "BFS_0.5.2.tar.gz")
  t <- cran_release_table(archive, current)
  expect_equal(t$version, c("0.5", "0.5.1", "0.5.2"))
  got <- update_date(t, "BFS", "0.5.1", "0.5.2")
  expect_equal(got$date, as.Date("2023-08-10"))
  expect_match(update_date(t, "BFS", "0.5", "0.5.2")$message, "replaced by 0.5.1 the day it came out")
})

test_that("an update whose day isn't published yet isn't moved back a day, as update all is (77)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- open_with_cran(s)
  r <- drive(r$state, ev_preview_update("dplyr", NULL, today, at(3)))
  r <- drive(r$state, ev_cran_releases_fetched(release_table(), at(4)))
  key <- repo_key("cran", "2026-09-30")
  r <- drive(r$state, ev_index_failed(key, "cran/2026-09-30 isn't published", at(5), unpublished = TRUE))
  prop <- r$state$packages$proposal
  expect_equal(prop$date, "2026-09-30")
  expect_equal(prop$update$version, "1.1.5")
  expect_equal(prop$status, "failed")
})

test_that("preview_update fetches CRAN's release dates, then previews the newest version's date (77)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- open_with_cran(s)
  expect_equal(unname(lock_versions(r$state$file$lock)["dplyr"]), "1.1.4")

  r <- drive(r$state, ev_preview_update("dplyr", NULL, today, at(3)))
  expect_true(r$reply)
  expect_equal(effect_types(r), "fetch_cran_releases")
  expect_equal(r$state$packages$proposal$status, "dates")
  expect_equal(packages_view(r$state)$proposal$update$name, "dplyr")

  r <- drive(r$state, ev_cran_releases_fetched(release_table(), at(4)))
  expect_equal(r$state$packages$proposal$date, "2026-09-30")
  expect_true("fetch_index" %in% effect_types(r))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(5)))
  prop <- r$state$packages$proposal
  expect_equal(prop$status, "ready")
  expect_equal(prop$changes$to[prop$changes$name == "dplyr"], "1.1.5")
  expect_equal(prop$update$version, "1.1.5")

  # Applied as any preview is.
  r <- drive(r$state, ev_set_date("2026-09-30", at(6)))
  expect_equal(r$state$file$header$snapshot, "2026-09-30")
  expect_equal(unname(lock_versions(r$state$file$lock)["dplyr"]), "1.1.5")

  # A second update uses the dates already fetched.
  r <- drive(r$state, ev_preview_update("dplyr", "1.1.4", today, at(7)))
  expect_false("fetch_cran_releases" %in% effect_types(r))
  expect_equal(r$state$packages$proposal$date, "2026-09-29")
})

test_that("a snapshot taken before the release reached it is passed over for the next day's", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- open_with_cran(s)
  r <- drive(r$state, ev_preview_update("dplyr", "1.1.5", today, at(3)))
  r <- drive(r$state, ev_cran_releases_fetched(release_table(new_on = "2026-09-29"), at(4)))
  expect_equal(r$state$packages$proposal$date, "2026-09-29")
  # Package Manager's snapshot of 2026-09-29 still has 1.1.4.
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-29"), cran_index_as("2026-09-01", "2026-09-29"), at(5)))
  prop <- r$state$packages$proposal
  expect_equal(prop$date, "2026-09-30")
  expect_equal(prop$status, "fetching")
  expect_true("fetch_index" %in% effect_types(r))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(6)))
  expect_equal(r$state$packages$proposal$status, "ready")
  expect_equal(r$state$packages$proposal$date, "2026-09-30")
})

test_that("a pin moves the date back to the last day the old version was current, and passes over a later snapshot", {
  lock <- new_lock(c("cli", "dplyr", "glue"), c("3.6.6", "1.1.5", "1.8.0"), rep("CRAN", 3))
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")), snapshot = "2026-09-30", lock = lock)
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_preview_update("dplyr", "1.1.4", today, at(2)))
  # 1.1.5 came out on 2026-09-02, but the snapshot of 09-01 already had it.
  r <- drive(r$state, ev_cran_releases_fetched(release_table(new_on = "2026-09-02"), at(3)))
  expect_equal(r$state$packages$proposal$date, "2026-09-01")
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index_as("2026-09-30", "2026-09-01"), at(4)))
  expect_equal(r$state$packages$proposal$date, "2026-08-31")
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-08-31"), cran_index_as("2026-09-01", "2026-08-31"), at(5)))
  prop <- r$state$packages$proposal
  expect_equal(prop$status, "ready")
  expect_equal(prop$changes$change[prop$changes$name == "dplyr"], "downgraded")
  expect_equal(prop$changes$to[prop$changes$name == "dplyr"], "1.1.4")
})

test_that("an update that no snapshot near its date has fails, saying so", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- open_with_cran(s)
  r <- drive(r$state, ev_preview_update("dplyr", "1.1.5", today, at(3)))
  r <- drive(r$state, ev_cran_releases_fetched(release_table(new_on = "2026-09-20"), at(4)))
  for (i in 0:3) {
    d <- format(as.Date("2026-09-20") + i)
    expect_equal(r$state$packages$proposal$date, d)
    r <- drive(r$state, ev_index_fetched(repo_key("cran", d), cran_index_as("2026-09-01", d), at(5 + i)))
  }
  prop <- r$state$packages$proposal
  expect_equal(prop$status, "failed")
  expect_match(prop$message, "snapshot of 2026-09-23 has dplyr 1.1.4, and no snapshot near it has dplyr 1.1.5")
  expect_equal(packages_view(r$state)$proposal$status, "failed")
})

test_that("an update never goes past today's snapshot", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- open_with_cran(s)
  r <- drive(r$state, ev_preview_update("dplyr", NULL, as.Date("2026-09-30"), at(3)))
  r <- drive(r$state, ev_cran_releases_fetched(release_table(), at(4)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index_as("2026-09-01", "2026-09-30"), at(5)))
  expect_equal(r$state$packages$proposal$status, "failed")
  expect_false("fetch_index" %in% effect_types(r))
})

test_that("preview_update refuses a package that isn't in the lock or isn't from CRAN", {
  lock <- new_lock(c("dplyr", "mypkg"), c("1.1.4", "0.1.0"), c("CRAN", "github:me/mypkg@abc123"))
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")), lock = lock)
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_preview_update("ggplot2", NULL, today, at(2)))
  expect_s3_class(r$reply, "ember_refused")
  expect_match(conditionMessage(r$reply), "ggplot2 is not in this notebook's packages")
  r <- drive(r$state, ev_preview_update("mypkg", NULL, today, at(3)))
  expect_s3_class(r$reply, "ember_refused")
  expect_match(conditionMessage(r$reply), "not CRAN")
  expect_length(r$effects, 0)
})

test_that("an update asked for before the first resolve waits for the lock, then goes on (#419)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  expect_equal(nrow(r$state$file$lock$entries), 0)
  r <- drive(r$state, ev_preview_update("dplyr", NULL, today, at(2), page = TRUE))
  expect_true(r$reply)
  expect_equal(r$state$packages$proposal$status, "lock")
  expect_equal(pluto_state(r$state)$js$ember$packages$package_update$status, "checking")
  # A name the code doesn't load is still refused at once.
  r2 <- drive(r$state, ev_preview_update("ggplot2", NULL, today, at(2)))
  expect_s3_class(r2$reply, "ember_refused")
  expect_match(conditionMessage(r2$reply), "ggplot2 is not in this notebook's packages")

  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index("2026-09-01"), at(3)))
  expect_equal(unname(lock_versions(r$state$file$lock)["dplyr"]), "1.1.4")
  expect_equal(r$state$packages$proposal$status, "dates")
  expect_equal(r$state$packages$proposal$update$from, "1.1.4")
  expect_true(r$state$packages$proposal$update$page)
  expect_true("fetch_cran_releases" %in% effect_types(r))
  r <- drive(r$state, ev_cran_releases_fetched(release_table(), at(4)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(5)))
  prop <- r$state$packages$proposal
  expect_equal(prop$status, "ready")
  expect_equal(prop$changes$to[prop$changes$name == "dplyr"], "1.1.5")
})

test_that("an update waiting for the lock fails, saying why, when resolution can't give it the package (#419)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_preview_update("dplyr", NULL, today, at(2)))
  expect_equal(r$state$packages$proposal$status, "lock")
  r <- drive(r$state, ev_index_failed(repo_key("cran", "2026-09-01"), "couldn't reach Package Manager", at(3)))
  prop <- r$state$packages$proposal
  expect_equal(prop$status, "failed")
  expect_equal(prop$message, "dplyr isn't in this notebook's lock: its packages couldn't be resolved (couldn't reach Package Manager)")
  expect_false("fetch_cran_releases" %in% effect_types(r))
  # Asked again now, it is refused at once, saying the same.
  r <- drive(r$state, ev_preview_update("dplyr", NULL, today, at(4)))
  expect_s3_class(r$reply, "ember_refused")
  expect_match(conditionMessage(r$reply), "its packages couldn't be resolved", fixed = TRUE)
})

test_that("a held update for a package resolution didn't find fails with its problem when replayed (#419)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(nosuchpkg)")), options = list(r = r46))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_preview_update("nosuchpkg", NULL, today, at(2), page = TRUE))
  expect_equal(r$state$packages$proposal$status, "lock")
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(3)))
  r <- deliver_bioc(r$state)
  prop <- r$state$packages$proposal
  expect_equal(prop$status, "failed")
  own <- r$state$packages$problems$message[r$state$packages$problems$package %in% "nosuchpkg"]
  expect_equal(prop$message, paste0("nosuchpkg isn't in this notebook's lock: ", own[[1]]))
  expect_equal(pluto_state(r$state)$js$ember$packages$package_update$status, "failed")

  # The same request held for a Bioconductor move fails the same way when
  # replayed, rather than being dropped.
  st <- r$state
  st$packages$proposal <- NULL
  st$packages$held <- ev_preview_update("nosuchpkg", NULL, today, at(4), page = TRUE)
  rp <- replay_held(st)
  expect_null(rp$state$packages$held)
  expect_equal(rp$state$packages$proposal$status, "failed")
  expect_equal(rp$state$packages$proposal$message, prop$message)
})

test_that("an update asked for while a Bioconductor move is pending and the lock resolving keeps the move (#419)", {
  lock <- new_lock(c("DESeq2", "S4Vectors", "cli"), c("1.48.0", "0.46.0", "3.6.4"), c("Bioc", "Bioc", "CRAN"))
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)"), D = cell("library(dplyr)")), options = list(r = r46),
                 snapshot = "2026-09-01", lock = lock, bioc_version = "3.22")
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(2)))
  r <- drive(r$state, ev_allow(at(3)))
  expect_equal(r$state$packages$proposal$kind, "bioc")
  expect_true(resolving(r$state))
  r <- drive(r$state, ev_preview_update("dplyr", NULL, today, at(4)))
  expect_true(r$reply)
  expect_equal(r$state$packages$proposal$kind, "bioc")
  expect_equal(r$state$packages$held$name, "dplyr")
  # Deliver every index being fetched until none is: the move goes
  # through, then the update goes on.
  for (i in 1:4) {
    keys <- names(Filter(function(slot) identical(slot$status, "fetching"), r$state$packages$indexes))
    if (length(keys) == 0) break
    for (k in keys) {
      parts <- strsplit(k, "/")[[1]]
      idx <- if (startsWith(k, "cran")) cran_index(parts[[2]]) else bioc_index(parts[[1]], parts[[3]], parts[[2]])
      r <- drive(r$state, ev_index_fetched(k, idx, at(4 + i)))
    }
  }
  expect_equal(r$state$file$header$bioc_version, "3.23")
  expect_null(r$state$packages$held)
  expect_equal(r$state$packages$proposal$update$name, "dplyr")
  expect_equal(r$state$packages$proposal$status, "dates")
})

test_that("release dates that can't be fetched fail the update, and the next one fetches again", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- open_with_cran(s)
  r <- drive(r$state, ev_preview_update("dplyr", NULL, today, at(3)))
  r <- drive(r$state, ev_cran_releases_failed("couldn't fetch CRAN's release dates from x", at(4)))
  expect_equal(r$state$packages$proposal$status, "failed")
  expect_match(r$state$packages$proposal$message, "couldn't fetch CRAN's release dates")
  r <- drive(r$state, ev_preview_update("dplyr", NULL, today, at(5)))
  expect_equal(effect_types(r), "fetch_cran_releases")
  r <- drive(r$state, ev_cran_releases_fetched(release_table(), at(6)))
  r <- drive(r$state, ev_preview_update("dplyr", "7.0", today, at(7)))
  expect_equal(r$state$packages$proposal$status, "failed")
  expect_match(r$state$packages$proposal$message, "never released dplyr 7.0")
})

test_that("the Packages tab's check fetches CRAN's release dates once, and each row says what CRAN has newer (#23)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- open_with_cran(s)
  expect_true(all(is.na(packages_view(r$state)$packages$available)))

  r <- drive(r$state, ev_check_releases(at(3)))
  expect_equal(effect_types(r), "fetch_cran_releases")
  expect_equal(r$state$packages$cran_releases$status, "fetching")
  r <- drive(r$state, ev_check_releases(at(4)))
  expect_length(r$effects, 0)

  # A failed fetch is tried again the next time the tab opens.
  r <- drive(r$state, ev_cran_releases_failed("couldn't fetch CRAN's release dates from x", at(5)))
  expect_true(all(is.na(packages_view(r$state)$packages$available)))
  r <- drive(r$state, ev_check_releases(at(6)))
  expect_equal(effect_types(r), "fetch_cran_releases")

  r <- drive(r$state, ev_cran_releases_fetched(release_table(), at(7)))
  rows <- packages_view(r$state)$packages
  expect_equal(rows$available[rows$name == "dplyr"], "1.1.5")
  # cli and glue aren't in the table: nothing to say.
  expect_true(all(is.na(rows$available[rows$name != "dplyr"])))
  js <- pluto_state(r$state)$js
  expect_true(check_wire(js))
  dplyr <- Filter(function(row) identical(row$name, "dplyr"), js$ember$packages$rows)[[1]]
  expect_equal(dplyr$available, "1.1.5")
  expect_null(js$ember$packages$package_update)

  r <- drive(r$state, ev_check_releases(at(8)))
  expect_length(r$effects, 0)
})

test_that("the tab's check fetches release dates again once they are a day old, keeping the old ones meanwhile (#23)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- open_with_cran(s)
  t0 <- 100
  r <- drive(r$state, ev_check_releases(at(3)))
  r <- drive(r$state, ev_cran_releases_fetched(release_table(), at(t0)))
  available <- function(state) {
    rows <- packages_view(state)$packages
    rows$available[rows$name == "dplyr"]
  }

  # A session stays open for days: under a day, nothing is fetched.
  r <- drive(r$state, ev_check_releases(at(t0 + cran_releases_max_age - 1)))
  expect_length(r$effects, 0)
  r <- drive(r$state, ev_check_releases(at(t0 + cran_releases_max_age)))
  expect_equal(effect_types(r), "fetch_cran_releases")
  expect_equal(available(r$state), "1.1.5")

  # A failed fetch keeps the old dates, and the next check tries again.
  r <- drive(r$state, ev_cran_releases_failed("couldn't fetch CRAN's release dates from x", at(t0 + cran_releases_max_age + 1)))
  expect_equal(r$state$packages$cran_releases$status, "ready")
  expect_equal(available(r$state), "1.1.5")
  r <- drive(r$state, ev_check_releases(at(t0 + cran_releases_max_age + 2)))
  expect_equal(effect_types(r), "fetch_cran_releases")

  # An update asked for meanwhile waits for the new dates.
  r <- drive(r$state, ev_preview_update("dplyr", NULL, today, at(t0 + cran_releases_max_age + 3), page = TRUE))
  expect_equal(r$state$packages$proposal$status, "dates")
  newer <- rbind(release_table(), data.frame(package = "dplyr", version = "1.1.6", date = as.Date("2026-10-05")))
  r <- drive(r$state, ev_cran_releases_fetched(newer, at(t0 + cran_releases_max_age + 4)))
  expect_equal(available(r$state), "1.1.6")
  expect_equal(r$state$packages$proposal$update$version, "1.1.6")
  expect_equal(r$state$packages$proposal$date, "2026-10-05")
})

test_that("available_versions names only a newer CRAN version of a package the lock has from CRAN (#23)", {
  rows <- data.frame(name = c("dplyr", "dplyr2", "mypkg", "gone", "cli"),
                     version = c("1.1.4", "1.1.5", "0.1.0", NA, "3.6.6"),
                     source = c("CRAN", "CRAN", "github:me/mypkg@abc123", NA, "CRAN"),
                     stringsAsFactors = FALSE)
  table <- rbind(release_table(),
                 data.frame(package = c("dplyr2", "mypkg", "gone", "cli"), version = c("1.1.5", "9.0", "1.0", "3.6.5"),
                            date = as.Date("2026-01-01"), stringsAsFactors = FALSE))
  ready <- new_cran_releases_slot("ready", table)
  # dplyr2 is at CRAN's newest, mypkg comes from GitHub, gone has no
  # version, and cli is newer than CRAN's (a lock written by hand).
  expect_equal(available_versions(rows, ready), c("1.1.5", NA, NA, NA, NA))
  expect_equal(available_versions(rows, new_cran_releases_slot("fetching")), rep(NA_character_, 5))
})

test_that("a row's Update is that row's question, with the other packages that move, until applied (#23)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- open_with_cran(s)
  r <- drive(r$state, ev_check_releases(at(3)))
  r <- drive(r$state, ev_cran_releases_fetched(release_table(), at(4)))

  # From R, an update leaves the page alone.
  r0 <- drive(r$state, ev_preview_update("dplyr", "1.1.5", today, at(5)))
  expect_null(pluto_state(r0$state)$js$ember$packages$package_update)

  r <- drive(r$state, ev_preview_update("dplyr", "1.1.5", today, at(5), page = TRUE))
  expect_true(r$reply)
  pu <- pluto_state(r$state)$js$ember$packages$package_update
  expect_equal(pu$name, "dplyr")
  expect_equal(pu$version, "1.1.5")
  expect_equal(pu$status, "checking")
  expect_equal(pu$date, "2026-09-30")
  # The header's Update question is a different one.
  expect_null(pluto_state(r$state)$js$ember$packages$update)

  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(6)))
  js <- pluto_state(r$state)$js
  expect_true(check_wire(js))
  pu <- js$ember$packages$package_update
  expect_equal(pu$status, "ready")
  expect_null(pu$message)
  # Every other package the date moves, not dplyr itself.
  ch <- r$state$packages$proposal$changes
  others <- ch$name[ch$name != "dplyr"]
  expect_equal(vapply(pu$changes, function(c) c$name, ""), others)
  expect_false("dplyr" %in% vapply(pu$changes, function(c) c$name, ""))
  expect_length(pu$restart, 0)

  # Nothing applies until the page says so; then the row is up to date.
  expect_equal(r$state$file$header$snapshot, "2026-09-01")
  r <- drive(r$state, ev_set_date(pu$date, at(7)))
  expect_equal(unname(lock_versions(r$state$file$lock)["dplyr"]), "1.1.5")
  js <- pluto_state(r$state)$js
  expect_null(js$ember$packages$package_update)
  dplyr <- Filter(function(row) identical(row$name, "dplyr"), js$ember$packages$rows)[[1]]
  expect_null(dplyr$available)
})

test_that("a row's Update names the loaded packages it restarts, and a failed one says why until closed (#23)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- open_with_cran(s)
  r$state$worker$loaded <- c(dplyr = "1.1.4", glue = "1.8.0")
  r <- drive(r$state, ev_check_releases(at(3)))
  r <- drive(r$state, ev_cran_releases_fetched(release_table(), at(4)))
  r <- drive(r$state, ev_preview_update("dplyr", "1.1.5", today, at(5), page = TRUE))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(6)))
  pu <- pluto_state(r$state)$js$ember$packages$package_update
  ch <- r$state$packages$proposal$changes
  expect_equal(sort(unlist(pu$restart)), sort(intersect(ch$name, c("dplyr", "glue"))))
  expect_true("dplyr" %in% unlist(pu$restart))

  r <- drive(r$state, ev_preview_update("dplyr", "7.0", today, at(7), page = TRUE))
  pu <- pluto_state(r$state)$js$ember$packages$package_update
  expect_equal(pu$status, "failed")
  expect_match(pu$message, "never released dplyr 7.0")
  expect_null(pu$date)
  r <- drive(r$state, ev_cancel_preview(at(8)))
  expect_null(pluto_state(r$state)$js$ember$packages$package_update)
})

# ---- apply = TRUE previews (ui-3-plan.md, "Update to today's snapshot") -----

test_that("an apply = TRUE preview applies itself once ready with nothing loaded to restart (83)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index("2026-09-01"), at(2)))

  r <- drive(r$state, ev_preview_date(as.Date("2026-09-30"), at(3), apply = TRUE))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(4)))

  expect_equal(r$state$file$header$snapshot, as.Date("2026-09-30"))
  expect_true(all(r$state$file$lock$entries$version[r$state$file$lock$entries$name == "dplyr"] == "1.1.5"))
  expect_null(r$state$packages$proposal)
  expect_true(r$state$packages$target$status %in% c("unknown", "checking"))
})

test_that("an apply = TRUE preview that would restart a loaded package waits for set_date or ev_cancel_preview (84)", {
  r <- dplyr_running()

  r2 <- drive(r$state, ev_preview_date(as.Date("2026-09-30"), at(30), apply = TRUE))
  r2 <- drive(r2$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(31)))

  prop <- r2$state$packages$proposal
  expect_equal(prop$status, "ready")
  expect_true("dplyr" %in% prop$restart)
  # Left for the page/console to decide: nothing applied on its own.
  expect_equal(r2$state$file$header$snapshot, "2026-09-01")

  r3 <- drive(r2$state, ev_set_date(as.Date("2026-09-30"), at(32)))
  expect_equal(r3$state$file$header$snapshot, as.Date("2026-09-30"))
  expect_null(r3$state$packages$proposal)

  r4 <- drive(r2$state, ev_cancel_preview(at(33)))
  expect_null(r4$state$packages$proposal)
  expect_equal(r4$state$file$header$snapshot, "2026-09-01")
})

test_that("allow records the running R version in the header when it differs (55)", {
  s <- pkg_state(list(S = cell("")), options = list(r = list(version = "9.9.9", minor = "9.9", platform = "test")))
  r <- drive(s, ev_allow(at(1)))
  expect_equal(r$state$file$header$r_version, "9.9.9")
})

test_that("ev_run also records the running R version in the header when it differs", {
  s <- pkg_state(list(S = cell(""), A = cell("1 + 1")),
                options = list(r = list(version = "9.9.9", minor = "9.9", platform = "test")))
  r <- drive(s, ev_run(NULL, at(1)))
  expect_equal(r$state$file$header$r_version, "9.9.9")
})

# ---- Snapshot projection --------------------------------------------------------

test_that("packages_view per-package statuses: installed, installing, not_installed, not_found (56)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)\nlibrary(nosuchpkg)")),
                 options = list(r = r46))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(2)))
  r <- deliver_bioc(r$state)
  v <- packages_view(r$state)
  expect_setequal(v$packages$status[v$packages$name %in% c("cli", "dplyr", "glue")], "missing")
  expect_true("not_found" %in% v$packages$status)

  key <- r$state$packages$target$key
  r <- drive(r$state, ev_library_checked(key, NULL, at(3)))
  r <- drive(r$state, ev_allow(at(4)))
  v2 <- packages_view(r$state)
  expect_true("installing" %in% v2$packages$status)

  r <- drive(r$state, ev_install_done(r$state$packages$install$token, key, NULL, "boom", character(), at(5)))
  v3 <- packages_view(r$state)
  # install_failures() parsed nothing from "boom" (no captured installer
  # output): no row names a specific failed package, so none is "failed" --
  # the whole batch reverts to "not_installed" (its staging folder was
  # never renamed into place).
  expect_true("not_installed" %in% v3$packages$status)
  expect_false("failed" %in% v3$packages$status)

  r <- drive(r$state, ev_run(NULL, at(6)))
  r <- drive(r$state, ev_install_done(r$state$packages$install$token, key,
                                      manifest(c(dplyr = "1.1.4", cli = "3.6.5", glue = "1.8.0")),
                                      NULL, character(), at(7)))
  v4 <- packages_view(r$state)
  expect_setequal(v4$packages$status[v4$packages$name %in% c("cli", "dplyr", "glue")], "installed")
})

test_that("packages_changed is notified once per dispatch when the view changes, and not otherwise (57)", {
  # The bare `ev_open` only starts a fetch (an effect); nothing visible in
  # `packages_view()` changes yet (the lock is still empty either way), so
  # the observable change is at `index_fetched`, once the lock fills in.
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")))
  r <- drive(s, ev_open(at(1)))
  r2 <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(2)))
  notes <- notifications(r$state, r2$state)
  expect_equal(sum(vapply(notes, function(n) n$kind, character(1)) == "packages_changed"), 1)

  r3 <- drive(r2$state, ev_render("nonexistent", at(3)))
  notes2 <- notifications(r2$state, r3$state)
  expect_false("packages_changed" %in% vapply(notes2, function(n) n$kind, character(1)))
})

# ---- check_state() holds throughout --------------------------------------------

test_that("check_state() holds after every step across a full packages lifecycle (58)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)\n1 + 1")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(2)))
  key <- r$state$packages$target$key
  r <- drive(r$state, ev_library_checked(key, NULL, at(3)))
  r <- drive(r$state, ev_allow(at(4)))
  r <- drive(r$state, ev_install_done(r$state$packages$install$token, key,
                                      manifest(c(dplyr = "1.1.4", cli = "3.6.5", glue = "1.8.0")),
                                      NULL, character(), at(5)))
  r <- drive(r$state, wk_started(r$state$worker$gen, 1L, at(6)), wk_hello(r$state$worker$gen, list(), at(7)))
  r <- drive(r$state, wk_done(r$state$worker$gen, last_token(r), report(created = "x"), at(8)))
  # drive() already calls check_state() after every step() above; reaching
  # here without an error is the assertion.
  expect_true(TRUE)
})

# ---- Performance (09) -------------------------------------------------------

# Times packages_view() itself, which is what regressed: one data frame per
# lock row took 19.5 ms at 150 packages, the column-wise version 1.5 ms.
# Timed against the same call at ten times the packages rather than a
# fixed budget (helper-perf.R): built column-wise, the per-row work is
# vectorised and fixed costs dominate, so 1500 packages cost a few times
# 150; one data frame per row costs ten times as much.
test_that("packages_view() is built column-wise: 1500 packages cost a few times 150", {
  skip_on_cran()  # too slow for CRAN's check time; CI runs it (#536)
  small <- perf_packages(150)
  big <- perf_packages(1500)
  r <- time_ratio(function() packages_view(big), function() packages_view(small),
                  samples = 11L, inner_a = 5L, inner_b = 10L)
  cat(sprintf("\n[timing] packages_view(): 1500 packages %.1f ms, 150 packages %.1f ms (%.1fx)\n",
              r$a * 1000, r$b * 1000, r$ratio))
  expect_lt(r$ratio, 6)
  # Backstop: about 1.5 ms on a cloud container.
  expect_lt(r$b, 0.03)
})

# ---- Install failures (piece 4, step 1) -------------------------------------

#' Captured installer output, as `poll_jobs()` (library.R) now retains it.
install_output <- function(name) {
  readLines(testthat::test_path("fixtures", "install-output", paste0(name, ".txt")), warn = FALSE)
}

test_that("an install failure names what failed to build", {
  lines <- c("Installing cli ...", "cleancall.c:39:28: error: ...",
             "ERROR: compilation failed for package 'cli'",
             "Error: failed to install \"cli\", \"dplyr\"", "Execution halted")
  msg <- install_failure_message(lines, 1L)
  expect_match(msg, "compilation failed for package 'cli'", fixed = TRUE)
  expect_match(msg, "failed to install \"cli\", \"dplyr\"", fixed = TRUE)
  expect_identical(install_failure_message("no reason given", 2L), "install failed, status 2")
})

test_that("an install failure message ignores terminal colour codes", {
  msg <- install_failure_message(c("\033[?25h\033[31mError: failed to install \"toyA\"\033[39m"), 1L)
  expect_match(msg, "Error: failed to install \"toyA\"", fixed = TRUE)
})

test_that("install_failures() on each captured output gives the expected rows; no failure gives 0 rows (80)", {
  expect_equal(nrow(install_failures(install_output("success"))), 0)

  cmp <- install_failures(install_output("compile-ascii"))
  expect_equal(cmp$package, "brokenpkg")
  expect_equal(cmp$kind, "compile")
  expect_true(is.na(cmp$detail))

  # R's quotes are ASCII or curly ("\u2018"/"\u2019") depending on locale;
  # both parse to the same row.
  cmp_curly <- install_failures(install_output("compile-curly"))
  expect_equal(cmp_curly, cmp)

  # configure's own "pkg-config not found" is a missing system tool, so
  # it is "system", not "configure" (whose card says to update).
  cfg <- install_failures(install_output("configure"))
  expect_equal(cfg$package, "brokenpkg")
  expect_equal(cfg$kind, "system")
  expect_equal(cfg$detail, "configure: error: pkg-config not found")

  # (Not "C compiler cannot create executables", which is a broken or
  # missing compiler: missing_compiler, test-install-checks.R.)
  cfg_plain <- install_failures(c("* installing *source* package 'brokenpkg' ...",
                                 "configure: error: this platform is not supported",
                                 "ERROR: configuration failed for package 'brokenpkg'"))
  expect_equal(cfg_plain$kind, "configure")

  dep <- install_failures(install_output("dependency"))
  expect_equal(dep$package, "broom")
  expect_equal(dep$kind, "dependency")
  expect_equal(dep$detail, "rlang")

  dl <- install_failures(install_output("download"))
  expect_equal(dl$package, "brokenpkg")
  expect_equal(dl$kind, "download")

  # "configure: error: libxml2 not found" with no ERROR line of its own:
  # still the system library it names.
  sys_lib <- install_failures(install_output("other"))
  expect_equal(sys_lib$package, "brokenpkg")
  expect_equal(sys_lib$kind, "system")
  expect_equal(sys_lib$detail, "configure: error: libxml2 not found")

  # The anticonf block xml2, curl and openssl print, then the generic
  # "configuration failed": "system", from the anticonf line.
  anticonf <- install_failures(install_output("system-anticonf"))
  expect_equal(anticonf$package, "xml2")
  expect_equal(anticonf$kind, "system")
  expect_match(anticonf$detail, "^Configuration failed because libxml-2.0 was not found")

  oth <- install_failures(c("- brokenpkg: install failed", "Error: failed to install \"brokenpkg\""))
  expect_equal(oth$package, "brokenpkg")
  expect_equal(oth$kind, "other")
  expect_match(oth$detail, "^Error: failed to install")

  two <- install_failures(install_output("two-failures"))
  expect_equal(nrow(two), 2)
  expect_setequal(two$package, c("rlang", "broom"))
  expect_equal(two$kind[two$package == "rlang"], "compile")
  expect_equal(two$kind[two$package == "broom"], "dependency")
  expect_equal(two$detail[two$package == "broom"], "rlang")
})

test_that("install_failures() on a real renv 1.3.0 / R 4.6.1 restore() log (ui-3 80)", {
  # Captured verbatim (fixture-build/renv-build.R, not committed) from a
  # real `renv::restore()` against a tiny source package whose C file
  # #includes a header that doesn't exist, run the same way
  # installer_command()/inst/installer.R run it: real ANSI codes, real
  # curly quotes, and renv's real bracketed summary line
  # ("- [brokenpkg]: install failed"), none of which the hand-written
  # fixtures above exercise.
  real <- install_failures(install_output("real-renv-compile"))
  expect_equal(nrow(real), 1)
  expect_equal(real$package, "brokenpkg")
  expect_equal(real$kind, "compile")
})

test_that("install_failures(): renv's bracketed summary line, and '@version' stripped from the name", {
  lines <- c("The following package(s) were not installed successfully:",
            "- [brokenpkg]: install failed",
            "You may need to manually download and install these packages.")
  r <- install_failures(lines)
  expect_equal(r$package, "brokenpkg")
  expect_equal(r$kind, "other")

  dl <- install_failures(c("- [brokenpkg]: failed to retrieve package 'brokenpkg@0.1.0'"))
  expect_equal(dl$package, "brokenpkg")
  expect_equal(dl$kind, "download")
})

test_that("install_failures(): renv's other real summary wordings (no 'package' before the quote, or no quote at all)", {
  # Real renv 1.3.0 text for two retrieval failures distinct from "install
  # failed": a raw path with no "package" keyword (so the download-
  # specific regexes above never match it), and binary lookup failing
  # with no quoted package name at all.
  by_path <- install_failures(c(
    "- [brokenpkg]: error downloading 'file:///tmp/repo/src/contrib/brokenpkg_0.1.0.tar.gz' [error code 37]"))
  expect_equal(by_path$package, "brokenpkg")
  expect_equal(by_path$kind, "download")

  no_binary <- install_failures(c(
    "- [brokenpkg]: failed to find binary for 'brokenpkg 0.1.0' in package repositories"))
  expect_equal(no_binary$package, "brokenpkg")
  expect_equal(no_binary$kind, "unavailable")
})

test_that("install_failures() on a real Bioconductor restore whose repository index 404'd", {
  # Captured verbatim (the installer's last 200 lines, as the session
  # keeps them) from DESeq2 + ggplot2 at 2026-10-08 on Linux, before
  # ppm_binary_repos(): renv rewrote the Bioconductor URLs into a form
  # Package Manager doesn't serve, couldn't read their index, and then
  # reported each Bioconductor package as "failed to find source". None of
  # that is a missing system library.
  real <- install_failures(install_output("real-renv-bioc-404"))
  expect_equal(nrow(real), 14)
  expect_true("DESeq2" %in% real$package)
  expect_equal(unique(real$kind), "unavailable")
  expect_equal(real$detail[real$package == "DESeq2"],
              "failed to find source for 'DESeq2 1.52.0' in package repositories")
})

test_that("install_failures(): a system-library line counts only while its package builds", {
  lines <- c("* installing *source* package 'a' ...",
            "/usr/bin/ld: libgdal.so.30: cannot open shared object file: No such file or directory",
            "ERROR: compilation failed for package 'a'",
            "configure: error: libfoo not found",
            "- [b]: install failed")
  r <- install_failures(lines)
  expect_equal(r$kind[r$package == "a"], "system")
  # The stray line after a's ERROR line isn't b's: b never started building.
  expect_equal(r$kind[r$package == "b"], "other")
})

test_that("install_failures(): one row per package, keeping the most specific kind", {
  # A package can match both its own ERROR line earlier in the log and
  # renv's generic summary line at the end; the summary line alone must
  # never downgrade an already-identified compile/configure/dependency
  # failure to "other".
  lines <- c("ERROR: compilation failed for package 'brokenpkg'",
            "The following package(s) were not installed successfully:",
            "- [brokenpkg]: install failed")
  r <- install_failures(lines)
  expect_equal(nrow(r), 1)
  expect_equal(r$kind, "compile")
})

test_that("reduce_install_done() writes one install_failed row per failed package; needed_by walks the loaded index (81)", {
  lock <- new_lock(c("broom", "rlang"), c("1.0.0", "1.1.0"), c("CRAN", "CRAN"))
  s <- pkg_state(list(S = cell(""), A = cell("library(broom)")), lock = lock)
  r0 <- drive(s, ev_open(at(1)))
  r0 <- drive(r0$state, ev_library_checked(r0$state$packages$target$key, NULL, at(2)))
  r0 <- drive(r0$state, ev_allow(at(3)))
  key <- r0$state$packages$target$key
  token <- r0$state$packages$install$token
  failures <- data.frame(package = "rlang", kind = "compile", detail = NA_character_,
                         stringsAsFactors = FALSE)

  idx_key <- repo_key("cran", r0$state$file$header$snapshot)
  idx <- new_repo_index(idx_key, "CRAN", name = c("broom", "rlang"),
                        version = c("1.0.0", "1.1.0"),
                        deps = list("rlang", character()), needs_compilation = c(FALSE, FALSE))
  state_with_idx <- r0$state
  state_with_idx$packages$indexes[[idx_key]] <- new_index_slot("ready", index = idx)

  rf <- drive(state_with_idx, ev_install_done(token, key, NULL, "install failed",
                                           c("ERROR: compilation failed for package 'rlang'"),
                                           at(5), failures = failures))
  v <- packages_view(rf$state)
  expect_equal(v$packages$status[v$packages$name == "broom"], "failed")
  expect_equal(v$packages$status[v$packages$name == "rlang"], "failed")
  expect_equal(v$library$failures$needed_by[[1]], "broom")
  problems <- rf$state$packages$problems
  install_rows <- problems[problems$kind == "install_failed", ]
  expect_equal(nrow(install_rows), 1)
  expect_equal(install_rows$package, "rlang")

  # A notebook opened with its lock never resolves, so no index is loaded
  # when the install fails (#17). The failure fetches CRAN's index; until it
  # arrives, needed_by is empty and broom reads "not_installed"; once it
  # does, broom points at the failure again.
  rf_noidx <- drive(r0$state, ev_install_done(token, key, NULL, "install failed",
                                               c("ERROR: compilation failed for package 'rlang'"),
                                               at(5), failures = failures))
  fetches <- Filter(function(e) identical(e$type, "fetch_index"), rf_noidx$effects)
  expect_equal(vapply(fetches, function(e) e$key, character(1)), idx_key)
  v2 <- packages_view(rf_noidx$state)
  expect_equal(v2$packages$status[v2$packages$name == "rlang"], "failed")
  expect_equal(v2$packages$status[v2$packages$name == "broom"], "not_installed")
  expect_equal(length(v2$library$failures$needed_by[[1]]), 0)

  rf_idx <- drive(rf_noidx$state, ev_index_fetched(idx_key, idx, at(6)))
  v3 <- packages_view(rf_idx$state)
  expect_equal(v3$library$failures$needed_by[[1]], "broom")
  expect_equal(v3$packages$status[v3$packages$name == "broom"], "failed")
  # The lock still answers the wanted set: the index doesn't start a resolve.
  expect_false("fetch_index" %in% effect_types(rf_idx))
  expect_identical(rf_idx$state$file$lock, r0$state$file$lock)
})

test_that("a failed install on a locked Bioconductor notebook fetches CRAN's and Bioconductor's indexes to say what needs the failure (#17)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46))
  locked <- deliver_bioc(open_with_cran(s)$state)$state$file$lock
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46),
                 lock = locked, bioc_version = "3.23")
  r0 <- drive(s, ev_open(at(1)))
  r0 <- drive(r0$state, ev_library_checked(r0$state$packages$target$key, NULL, at(2)))
  r0 <- drive(r0$state, ev_allow(at(3)))
  expect_false("fetch_index" %in% effect_types(r0))
  key <- r0$state$packages$target$key
  token <- r0$state$packages$install$token
  failures <- data.frame(package = "S4Vectors", kind = "missing_system", detail = NA_character_,
                         stringsAsFactors = FALSE)
  rf <- drive(r0$state, ev_install_done(token, key, NULL, "install failed", character(), at(4),
                                        failures = failures))
  fetched <- vapply(Filter(function(e) identical(e$type, "fetch_index"), rf$effects),
                    function(e) e$key, character(1))
  expect_setequal(fetched, c("cran/2026-09-01", "bioc/2026-09-01/3.23",
                             "bioc-ann/2026-09-01/3.23", "bioc-exp/2026-09-01/3.23"))
  expect_equal(length(packages_view(rf$state)$library$failures$needed_by[[1]]), 0)

  r1 <- deliver_bioc(rf$state, t = 5)
  v <- packages_view(r1$state)
  expect_equal(v$library$failures$needed_by[[1]], "DESeq2")
  expect_equal(v$packages$status[v$packages$name == "DESeq2"], "failed")
  # CRAN's index that never arrives leaves the walk as it was, and nothing
  # resolves: the lock still answers the notebook.
  r2 <- drive(r1$state, ev_index_failed("cran/2026-09-01", "offline", at(6)))
  expect_equal(packages_view(r2$state)$library$failures$needed_by[[1]], "DESeq2")
  expect_identical(r2$state$file$lock, locked)
  expect_false("fetch_index" %in% effect_types(r2))

  # Trying again drops the failed slot, so the next failure asks for it again.
  r3 <- drive(r2$state, ev_run(NULL, at(7)))
  token2 <- r3$state$packages$install$token
  expect_false(is.null(token2))
  r4 <- drive(r3$state, ev_install_done(token2, key, NULL, "install failed", character(), at(8),
                                        failures = failures))
  expect_equal(vapply(Filter(function(e) identical(e$type, "fetch_index"), r4$effects),
                      function(e) e$key, character(1)), "cran/2026-09-01")
  expect_equal(packages_view(r4$state)$library$failures$needed_by[[1]], "DESeq2")
})

# ---- Bioconductor (docs/packages-tests.md, 82-87) ----------------------------

test_that("a CRAN-only notebook never fetches a Bioconductor index and carries no pin (82)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")), options = list(r = r46))
  r <- open_with_cran(s)
  expect_false("fetch_index" %in% effect_types(r))
  expect_equal(r$state$packages$resolved_for, "dplyr")
  expect_true(is.na(r$state$file$header$bioc_version))
  expect_false(any(startsWith(names(r$state$packages$indexes), "bioc")))
})

test_that("library(DESeq2) fetches Bioconductor's indexes after CRAN's, locks it as Bioc and pins the release (83)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46))
  r <- open_with_cran(s)
  expect_setequal(vapply(r$effects, function(e) e$key, character(1)),
                  c("bioc/2026-09-01/3.23", "bioc-ann/2026-09-01/3.23", "bioc-exp/2026-09-01/3.23"))
  expect_equal(find_effect(r, "fetch_index")$url,
               "https://packagemanager.posit.co/bioconductor/2026-09-01/packages/3.23/bioc")
  r <- deliver_bioc(r$state)
  expect_equal(format_lock_lines(r$state$file$lock),
               c("DESeq2 1.50.0 Bioc", "S4Vectors 0.48.0 Bioc", "cli 3.6.5 CRAN"))
  expect_equal(r$state$file$header$bioc_version, "3.23")
  expect_equal(nrow(r$state$packages$problems), 0)
  text <- format_notebook(notebook_file_of(r$state))
  expect_match(text, 'bioc_version = "3.23"', fixed = TRUE)
  expect_match(text, "# DESeq2 1.50.0 Bioc", fixed = TRUE)
})

test_that("the install gets CRAN and the three Bioconductor repositories once the lock holds a Bioc package (83)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(wgcna)")), options = list(r = r46))
  r <- deliver_bioc(open_with_cran(s)$state)
  expect_true("GO.db" %in% r$state$file$lock$entries$name)
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(4)))
  r <- drive(r$state, ev_allow(at(5)))
  inst <- find_effect(r, "install")
  expect_named(inst$repos, c("CRAN", "BioCsoft", "BioCann", "BioCexp"))
})

test_that("removing the last Bioconductor package drops the pin (84)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46))
  r <- deliver_bioc(open_with_cran(s)$state)
  r <- drive(r$state, ev_apply(list(op_set_code("A", "library(dplyr)")), at(6)))
  expect_false(any(r$state$file$lock$entries$source == "Bioc"))
  expect_true(is.na(r$state$file$header$bioc_version))
})

test_that("a failed Bioconductor index leaves the name not found, says why, and is retried only when the wanted set changes (85)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46))
  r <- open_with_cran(s)
  for (kind in names(bioc_kinds)) {
    r <- drive(r$state, ev_index_failed(repo_key(kind, "2026-09-01", "3.23"), "network down", at(3)))
  }
  probs <- r$state$packages$problems
  expect_true("DESeq2" %in% probs$package[probs$kind == "not_found"])
  expect_true(any(probs$kind == "index_unavailable" & grepl("network down", probs$message)))
  expect_equal(effect_types(r), character())
  # The page doesn't call it "not found in any repository": it may be in
  # the index that failed (#264).
  row <- packages_view(r$state)$packages
  row <- row[row$name == "DESeq2", ]
  expect_equal(row$status, "lookup_failed")
  expect_match(row$message, "couldn't look in Bioconductor (the package index bioc/2026-09-01/3.23 could not be fetched: network down)",
               fixed = TRUE)

  r2 <- drive(r$state, ev_apply(list(op_set_code("S", "1 + 1")), at(4)))
  expect_equal(effect_types(r2), character())

  r3 <- drive(r2$state, ev_apply(list(op_set_code("S", "library(viz)")), at(5)))
  expect_setequal(vapply(r3$effects, function(e) e$key, character(1)),
                  c("bioc/2026-09-01/3.23", "bioc-ann/2026-09-01/3.23", "bioc-exp/2026-09-01/3.23"))

  # Once the name is fixed to a CRAN one, the failed indexes aren't fetched again.
  r4 <- drive(r2$state, ev_apply(list(op_set_code("A", "library(dplyr)")), at(5)))
  expect_false("fetch_index" %in% effect_types(r4))
  expect_equal(r4$state$packages$resolved_for, "dplyr")
})

test_that("a cell's missing-package error says Bioconductor couldn't be looked in, as the page does (#282)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46))
  r <- open_with_cran(s)
  for (kind in names(bioc_kinds)) {
    r <- drive(r$state, ev_index_failed(repo_key(kind, "2026-09-01", "3.23"), "network down", at(3)))
  }
  err <- missing_package_error(r$state, "DESeq2")$error
  expect_equal(err$kind, "missing_package")
  expect_match(err$message, "there is no package called 'DESeq2': DESeq2 isn't on CRAN at this date, and Ember couldn't look in Bioconductor (the package index bioc/2026-09-01/3.23 could not be fetched: network down)",
               fixed = TRUE)
  expect_false(grepl("not found in any repository", err$message, fixed = TRUE))
})

test_that("a Bioconductor index not published yet at the notebook's date moves the date back while nothing is locked (#282)", {
  # CRAN's index is there at 2026-10-01 (the 2026-09-30 fixture stands in);
  # Bioconductor's isn't yet.
  cran_at <- function(date) {
    read_repo_index(testthat::test_path("fixtures", "repos", "cran", "2026-09-30", "src", "contrib", "PACKAGES"),
                    key = repo_key("cran", date), label = "CRAN")
  }
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46), snapshot = "2026-10-01")
  r <- drive(s, ev_open(at(1)), ev_index_fetched(repo_key("cran", "2026-10-01"), cran_at("2026-10-01"), at(2)))
  expect_setequal(vapply(r$effects, function(e) e$key %||% NA_character_, character(1)) |> stats::na.omit() |> as.character(),
                  c("cran/2026-10-01", "bioc/2026-10-01/3.23", "bioc-ann/2026-10-01/3.23", "bioc-exp/2026-10-01/3.23"))

  r <- drive(r$state, ev_index_failed("bioc/2026-10-01/3.23", "bioc/2026-10-01/3.23 isn't published: no index for that date (404)",
                                      at(3), unpublished = TRUE))
  expect_equal(r$state$file$header$snapshot, "2026-09-30")
  expect_false(any(grepl("2026-10-01", names(r$state$packages$indexes)) &
                     is_bioc_key(names(r$state$packages$indexes))))
  expect_equal(find_effect(r, "fetch_index")$key, repo_key("cran", "2026-09-30"))
  # The old date's other Bioconductor answers are ignored.
  r <- drive(r$state, ev_index_failed("bioc-ann/2026-10-01/3.23", "404", at(4), unpublished = TRUE),
             ev_index_failed("bioc-exp/2026-10-01/3.23", "404", at(4), unpublished = TRUE))
  expect_equal(r$state$file$header$snapshot, "2026-09-30")
  expect_equal(nrow(r$state$packages$problems), 0)

  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_at("2026-09-30"), at(5)))
  r <- deliver_bioc(r$state, release = "3.23", date = "2026-09-30", t = 6)
  expect_true("DESeq2" %in% r$state$file$lock$entries$name)
  expect_equal(r$state$file$header$snapshot, "2026-09-30")
  expect_false(any(r$state$packages$problems$kind %in% c("not_found", "index_unavailable")))
})

test_that("a Bioconductor index not published yet leaves the date alone when the lock has packages (#282)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46),
                 lock = new_lock("cli", "3.6.3", "CRAN"))
  r <- open_with_cran(s)
  for (kind in names(bioc_kinds)) {
    r <- drive(r$state, ev_index_failed(repo_key(kind, "2026-09-01", "3.23"),
                                        sprintf("%s isn't published: no index for that date (404)", repo_key(kind, "2026-09-01", "3.23")),
                                        at(3), unpublished = TRUE))
  }
  expect_equal(r$state$file$header$snapshot, "2026-09-01")
  expect_true(any(r$state$packages$problems$kind == "index_unavailable" &
                    grepl("bioc/2026-09-01/3.23 isn't published", r$state$packages$problems$message, fixed = TRUE)))
})

# ---- Stepping back for Bioconductor while packages are locked (#311) ----------

#' The CRAN fixture `fixture` (2026-09-30's or 2026-09-01's) keyed at `date`.
cran_as <- function(date, fixture = "2026-09-30") {
  read_repo_index(testthat::test_path("fixtures", "repos", "cran", fixture, "src", "contrib", "PACKAGES"),
                  key = repo_key("cran", date), label = "CRAN")
}

#' A notebook dated 2026-10-01 using cli, locked at 3.6.6 (2026-09-30's
#' version), and a cell asking for DESeq2, opened with CRAN's index there.
#' Bioconductor's indexes at 2026-10-01 are being fetched.
locked_bioc_open <- function() {
  s <- pkg_state(list(S = cell("library(cli)"), A = cell("library(DESeq2)")), options = list(r = r46),
                 snapshot = "2026-10-01", lock = new_lock("cli", "3.6.6", "CRAN"))
  drive(s, ev_open(at(1)), ev_index_fetched(repo_key("cran", "2026-10-01"), cran_as("2026-10-01"), at(2)))
}

unpublished_404 <- function(state, key, t) {
  drive(state, ev_index_failed(key, sprintf("%s isn't published: no index for that date (404)", key),
                               at(t), unpublished = TRUE))
}

#' Every Bioconductor index at `date` answers an unpublished 404.
bioc_unpublished <- function(state, date = "2026-10-01", t = 3) {
  r <- list(state = state, effects = list())
  for (kind in names(bioc_kinds)) r <- unpublished_404(r$state, repo_key(kind, date, "3.23"), t)
  r
}

test_that("a Bioconductor index not published at a locked notebook's date steps back silently when nothing locked changes (#311)", {
  r <- locked_bioc_open()
  r <- unpublished_404(r$state, "bioc/2026-10-01/3.23", 3)
  # Not before resolution at the notebook's date has settled.
  expect_null(r$state$packages$proposal)
  r <- unpublished_404(r$state, "bioc-ann/2026-10-01/3.23", 3)
  r <- unpublished_404(r$state, "bioc-exp/2026-10-01/3.23", 3)
  prop <- r$state$packages$proposal
  expect_equal(prop$kind, "back")
  expect_equal(prop$date, "2026-09-30")
  expect_equal(prop$asked, "2026-10-01")
  # Nothing has moved yet, the page asks nothing, and the cell that needs
  # DESeq2 waits for the step back rather than failing first.
  expect_equal(r$state$file$header$snapshot, "2026-10-01")
  expect_null(pluto_state(r$state)$js$ember$packages$update)
  expect_true("A" %in% names(waiting_cells(r$state)))
  expect_equal(find_effect(r, "fetch_index")$key, "cran/2026-09-30")
  expect_true(find_effect(r, "fetch_index")$fresh)

  r <- drive(r$state, ev_index_fetched("cran/2026-09-30", cran_as("2026-09-30"), at(5)))
  r <- deliver_bioc(r$state, date = "2026-09-30", t = 6)
  expect_null(r$state$packages$proposal)
  expect_equal(r$state$file$header$snapshot, "2026-09-30")
  lock <- r$state$file$lock$entries
  expect_true("DESeq2" %in% lock$name)
  expect_equal(lock$version[lock$name == "cli"], "3.6.6")
  expect_false(any(r$state$packages$problems$kind %in% c("not_found", "index_unavailable", "off_date")))
  expect_null(pluto_state(r$state)$js$ember$packages$update)
  # Still waiting, now for the install.
  expect_equal(waiting_cells(r$state)[["A"]], "DESeq2")
  text <- format_notebook(notebook_file_of(r$state))
  expect_match(text, "2026-09-30", fixed = TRUE)
  expect_match(text, "# DESeq2 1.50.0 Bioc", fixed = TRUE)
})

test_that("a step back keeps going while the earlier day isn't published either, for Bioconductor or CRAN (#311)", {
  r <- bioc_unpublished(locked_bioc_open()$state)
  r <- drive(r$state, ev_index_fetched("cran/2026-09-30", cran_as("2026-09-30"), at(4)))
  r <- unpublished_404(r$state, "bioc/2026-09-30/3.23", 5)
  expect_equal(r$state$packages$proposal$kind, "back")
  expect_equal(r$state$packages$proposal$date, "2026-09-29")
  expect_equal(r$state$packages$proposal$asked, "2026-10-01")
  expect_false(any(is_bioc_key(names(r$state$packages$indexes)) &
                     key_date(names(r$state$packages$indexes)) == "2026-09-30"))
  # CRAN's index at 2026-09-29 isn't there either.
  r <- unpublished_404(r$state, "cran/2026-09-29", 6)
  expect_equal(r$state$packages$proposal$date, "2026-09-28")
  expect_null(r$state$packages$indexes[["cran/2026-09-29"]])
  expect_equal(find_effect(r, "fetch_index")$key, "cran/2026-09-28")
  r <- drive(r$state, ev_index_fetched("cran/2026-09-28", cran_as("2026-09-28"), at(7)))
  r <- deliver_bioc(r$state, date = "2026-09-28", t = 8)
  expect_null(r$state$packages$proposal)
  expect_equal(r$state$file$header$snapshot, "2026-09-28")
  expect_true("DESeq2" %in% r$state$file$lock$entries$name)
})

#' `locked_bioc_open()` stepped back to 2026-09-30, whose CRAN index has
#' cli 3.6.5 rather than the locked 3.6.6, so the move waits for an answer.
back_question <- function(loaded = NULL) {
  r <- bioc_unpublished(locked_bioc_open()$state)
  if (!is.null(loaded)) r$state$worker$loaded <- loaded
  r <- drive(r$state, ev_index_fetched("cran/2026-09-30", cran_as("2026-09-30", fixture = "2026-09-01"), at(4)))
  deliver_bioc(r$state, date = "2026-09-30", t = 5)
}

test_that("a step back that would change a locked version waits as the page's question, and set_date() applies it (#311)", {
  r <- back_question()
  prop <- r$state$packages$proposal
  expect_equal(prop$kind, "back")
  expect_equal(prop$status, "ready")
  expect_false(isTRUE(prop$apply))
  expect_equal(prop$restart, character())
  expect_equal(r$state$file$header$snapshot, "2026-10-01")
  ch <- prop$changes
  expect_equal(ch$from[ch$name == "cli"], "3.6.6")
  expect_equal(ch$to[ch$name == "cli"], "3.6.5")
  expect_true("DESeq2" %in% ch$name[ch$change == "added"])
  # Only the package that has to move moves.
  expect_false(any(prop$problems$kind == "off_date"))
  # The question is open: the cell isn't held for it.
  expect_false("A" %in% names(waiting_cells(r$state)))

  js <- pluto_state(r$state)$js
  expect_true(check_wire(js))
  up <- js$ember$packages$update
  expect_equal(up$date, "2026-09-30")
  expect_equal(up$status, "ready")
  expect_equal(up$back$from, "2026-10-01")
  cli_row <- Filter(function(c) identical(c$name, "cli"), up$back$changes)[[1]]
  expect_equal(cli_row$from, "3.6.6")
  expect_equal(cli_row$to, "3.6.5")
  added <- Filter(function(c) identical(c$name, "DESeq2"), up$back$changes)[[1]]
  expect_null(added$from)

  r <- drive(r$state, ev_set_date("2026-09-30", at(6)))
  expect_false(inherits(r$replies[[1]], "ember_refused"))
  expect_equal(r$state$file$header$snapshot, "2026-09-30")
  lock <- r$state$file$lock$entries
  expect_equal(lock$version[lock$name == "cli"], "3.6.5")
  expect_true("DESeq2" %in% lock$name)
  expect_null(r$state$packages$proposal)
})

test_that("a step back's question names a loaded package it changes as restarting R (#311)", {
  r <- back_question(loaded = c(cli = "3.6.6"))
  expect_equal(r$state$packages$proposal$restart, "cli")
  expect_equal(unlist(pluto_state(r$state)$js$ember$packages$update$restart), "cli")
})

test_that("a step back's question follows the wanted set, and goes once the missing name does (#311)", {
  r <- back_question()
  r <- drive(r$state, ev_apply(list(op_set_code("S", "library(cli); library(glue)")), at(6)))
  # Bioconductor is asked again at the notebook's date for the new set.
  r <- bioc_unpublished(r$state, t = 6)
  prop <- r$state$packages$proposal
  expect_equal(prop$status, "ready")
  expect_setequal(prop$for_wanted, c("cli", "glue", "DESeq2"))
  expect_true("glue" %in% prop$lock$entries$name)

  r <- drive(r$state, ev_apply(list(op_set_code("A", "1 + 1")), at(7)))
  expect_null(r$state$packages$proposal)
  expect_equal(r$state$file$header$snapshot, "2026-10-01")
  expect_equal(r$state$file$lock$entries$version[r$state$file$lock$entries$name == "cli"], "3.6.6")
})

test_that("a step back that finds no missing name is dropped, and not tried again until the notebook runs (#311)", {
  s <- pkg_state(list(S = cell("library(cli)"), A = cell("library(dplyrr)")), options = list(r = r46),
                 snapshot = "2026-10-01", lock = new_lock("cli", "3.6.6", "CRAN"))
  r <- drive(s, ev_open(at(1)), ev_index_fetched(repo_key("cran", "2026-10-01"), cran_as("2026-10-01"), at(2)))
  r <- bioc_unpublished(r$state)
  expect_equal(r$state$packages$proposal$kind, "back")
  # Even with cli older there, a typo isn't worth a question.
  r <- drive(r$state, ev_index_fetched("cran/2026-09-30", cran_as("2026-09-30", fixture = "2026-09-01"), at(4)))
  r <- deliver_bioc(r$state, date = "2026-09-30", t = 5)
  expect_null(r$state$packages$proposal)
  expect_equal(r$state$file$header$snapshot, "2026-10-01")
  expect_null(pluto_state(r$state)$js$ember$packages$update)
  r <- drive(r$state, ev_apply(list(op_set_code("S", "library(cli) # again")), at(6)))
  expect_null(r$state$packages$proposal)
  expect_false("A" %in% names(waiting_cells(r$state)))

  # Running again fetches the failed indexes, and tries once more once
  # they have answered (at once here: the earlier day's indexes are held).
  r <- drive(r$state, ev_run(NULL, at(7)))
  expect_null(r$state$packages$back_tried)
  r <- unpublished_404(r$state, "bioc/2026-10-01/3.23", 8)
  expect_null(r$state$packages$back_tried)
  r <- bioc_unpublished(r$state, t = 8)
  expect_equal(r$state$packages$back_tried$names, "dplyrr")
  expect_null(r$state$packages$proposal)
})

test_that("no step back once the Bioconductor package resolved at the notebook's date, whatever else 404s (#311)", {
  r <- locked_bioc_open()
  r <- drive(r$state, ev_index_fetched("bioc/2026-10-01/3.23", bioc_index("bioc", date = "2026-10-01"), at(3)),
             ev_index_fetched("bioc-exp/2026-10-01/3.23", bioc_index("bioc-exp", date = "2026-10-01"), at(3)))
  r <- unpublished_404(r$state, "bioc-ann/2026-10-01/3.23", 4)
  expect_true("DESeq2" %in% r$state$file$lock$entries$name)
  expect_null(r$state$packages$proposal)
  expect_equal(r$state$file$header$snapshot, "2026-10-01")
})

test_that("a step back that would lose a locked package is dropped (#311)", {
  s <- pkg_state(list(S = cell("library(cli); library(viz)"), A = cell("library(DESeq2)")),
                 options = list(r = r46), snapshot = "2026-10-01",
                 lock = new_lock(c("cli", "viz"), c("3.6.6", "2.0.0"), c("CRAN", "CRAN")))
  r <- drive(s, ev_open(at(1)), ev_index_fetched(repo_key("cran", "2026-10-01"), cran_as("2026-10-01"), at(2)))
  r <- bioc_unpublished(r$state)
  # viz isn't out yet at 2026-09-30.
  idx <- cran_as("2026-09-30")
  keep <- idx$name != "viz"
  without_viz <- new_repo_index(idx$key, idx$label, idx$name[keep], idx$version[keep], idx$deps[keep],
                                idx$needs_compilation[keep])
  r <- drive(r$state, ev_index_fetched("cran/2026-09-30", without_viz, at(4)))
  r <- deliver_bioc(r$state, date = "2026-09-30", t = 5)
  expect_null(r$state$packages$proposal)
  expect_equal(r$state$file$header$snapshot, "2026-10-01")
  expect_true("viz" %in% r$state$file$lock$entries$name)
})

test_that("a cancelled step back leaves the date and the unpublished index's row (#311)", {
  r <- back_question()
  r <- drive(r$state, ev_cancel_preview(at(6)))
  expect_null(r$state$packages$proposal)
  expect_equal(r$state$file$header$snapshot, "2026-10-01")
  expect_true(any(r$state$packages$problems$kind == "index_unavailable"))
  expect_null(pluto_state(r$state)$js$ember$packages$update)
  # Not asked again on the next edit.
  r <- drive(r$state, ev_apply(list(op_set_code("S", "library(cli) # again")), at(7)))
  expect_null(r$state$packages$proposal)
})

test_that("a step back whose earlier day fails to fetch is dropped, and the failure shows as before (#311)", {
  r <- bioc_unpublished(locked_bioc_open()$state)
  r <- drive(r$state, ev_index_fetched("cran/2026-09-30", cran_as("2026-09-30"), at(4)))
  for (kind in names(bioc_kinds)) {
    r <- drive(r$state, ev_index_failed(repo_key(kind, "2026-09-30", "3.23"), "network down", at(5)))
  }
  expect_null(r$state$packages$proposal)
  expect_equal(r$state$file$header$snapshot, "2026-10-01")
  expect_equal(r$state$file$lock$entries$name, "cli")
  probs <- r$state$packages$problems
  expect_true(any(probs$kind == "index_unavailable" &
                    grepl("bioc/2026-10-01/3.23 isn't published", probs$message, fixed = TRUE)))
  expect_false("A" %in% names(waiting_cells(r$state)))
})

test_that("Update all steps back a day when Bioconductor hasn't published the day it previews (#377)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46))
  r <- deliver_bioc(open_with_cran(s)$state)
  r <- drive(r$state, ev_preview_date("2026-10-01", at(4), apply = TRUE))
  r <- drive(r$state, ev_index_fetched("cran/2026-10-01", cran_as("2026-10-01"), at(5)))
  r <- unpublished_404(r$state, "bioc/2026-10-01/3.23", 6)
  prop <- r$state$packages$proposal
  expect_equal(prop$kind, "date")
  expect_equal(prop$date, "2026-09-30")
  expect_equal(prop$asked, "2026-10-01")
  expect_true(prop$apply)
  # The other Bioconductor indexes at the unpublished day are dropped, so
  # their answers are ignored, and the failure isn't kept as a problem.
  keys <- names(r$state$packages$indexes)
  expect_false(any(is_bioc_key(keys) & key_date(keys) == "2026-10-01"))
  r <- unpublished_404(r$state, "bioc-ann/2026-10-01/3.23", 6)
  expect_equal(r$state$packages$proposal$date, "2026-09-30")

  r <- drive(r$state, ev_index_fetched("cran/2026-09-30", cran_as("2026-09-30"), at(7)))
  r <- deliver_bioc(r$state, date = "2026-09-30", t = 8)
  expect_null(r$state$packages$proposal)
  expect_equal(as.character(r$state$file$header$snapshot), "2026-09-30")
  expect_true("DESeq2" %in% r$state$file$lock$entries$name)
  expect_false(any(r$state$packages$problems$kind %in% c("not_found", "index_unavailable")))
})

#' Hold provisional copies of CRAN's and Bioconductor's indexes at
#' 2026-09-30, from a preview of that day that was then cancelled.
hold_provisional_0930 <- function(state, t) {
  r <- drive(state, ev_preview_date("2026-09-30", at(t)),
             ev_index_fetched("cran/2026-09-30", cran_as("2026-09-30"), at(t), provisional = TRUE))
  for (kind in names(bioc_kinds)) {
    r <- drive(r$state, ev_index_fetched(repo_key(kind, "2026-09-30", "3.23"),
                                         bioc_index(kind, "3.23", "2026-09-30"), at(t), provisional = TRUE))
  }
  r <- drive(r$state, ev_cancel_preview(at(t)))
  held <- r$state$packages$indexes[grepl("2026-09-30", names(r$state$packages$indexes), fixed = TRUE)]
  stopifnot(length(held) == 4, all(vapply(held, function(s) isTRUE(s$provisional), logical(1))))
  r
}

held_0930 <- function(state) {
  keys <- names(state$packages$indexes)
  keys[key_date(keys) == "2026-09-30" & !vapply(state$packages$indexes[keys], function(s) identical(s$status, "fetching"),
                                                 logical(1))]
}

test_that("a step back fetches the provisional CRAN and Bioconductor indexes it holds at the earlier day again (#382)", {
  # Update all's step back.
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46))
  r <- hold_provisional_0930(deliver_bioc(open_with_cran(s)$state)$state, 4)
  r <- drive(r$state, ev_preview_date("2026-10-01", at(5), apply = TRUE))
  r <- drive(r$state, ev_index_fetched("cran/2026-10-01", cran_as("2026-10-01"), at(6)))
  r <- unpublished_404(r$state, "bioc/2026-10-01/3.23", 7)
  expect_equal(r$state$packages$proposal$date, "2026-09-30")
  expect_length(held_0930(r$state), 0)

  # The #311 step back of a locked notebook.
  r <- hold_provisional_0930(locked_bioc_open()$state, 3)
  r <- bioc_unpublished(r$state, t = 4)
  expect_equal(r$state$packages$proposal$kind, "back")
  expect_equal(r$state$packages$proposal$date, "2026-09-30")
  expect_length(held_0930(r$state), 0)
})

test_that("a step back isn't proposed over a date preview the user asked for (#311)", {
  r <- locked_bioc_open()
  r <- drive(r$state, ev_preview_date("2026-10-01", at(3)))
  r <- bioc_unpublished(r$state, t = 4)
  expect_equal(r$state$packages$proposal$kind, "date")
})


test_that("running again fetches a failed Bioconductor index and resolves the name it held (#264)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46))
  r <- open_with_cran(s)
  for (kind in names(bioc_kinds)) {
    r <- drive(r$state, ev_index_failed(repo_key(kind, "2026-09-01", "3.23"), "network down", at(3)))
  }
  r <- drive(r$state, ev_run(NULL, at(4)))
  fetched <- Filter(function(e) identical(e$type, "fetch_index"), r$effects)
  expect_setequal(vapply(fetched, function(e) e$key, character(1)),
                  c("bioc/2026-09-01/3.23", "bioc-ann/2026-09-01/3.23", "bioc-exp/2026-09-01/3.23"))
  r <- deliver_bioc(r$state, t = 5)
  expect_true("DESeq2" %in% r$state$file$lock$entries$name)
  expect_false(any(r$state$packages$problems$kind %in% c("not_found", "index_unavailable")))
  expect_equal(packages_view(r$state)$packages$status[packages_view(r$state)$packages$name == "DESeq2"],
               "missing")
})

test_that("a reopened notebook with a Bioc lock fetches Bioconductor's indexes when the wanted set changes, not not_in_index (88)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46))
  locked <- deliver_bioc(open_with_cran(s)$state)$state$file$lock
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46),
                 lock = locked, bioc_version = "3.23")
  r <- drive(s, ev_open(at(1)))
  expect_false("fetch_index" %in% effect_types(r))
  r <- drive(r$state, ev_apply(list(op_set_code("S", "library(dplyr)")), at(2)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(3)))
  expect_setequal(vapply(r$effects, function(e) e$key, character(1)),
                  c("bioc/2026-09-01/3.23", "bioc-ann/2026-09-01/3.23", "bioc-exp/2026-09-01/3.23"))
  r <- deliver_bioc(r$state, t = 4)
  expect_false("not_in_index" %in% r$state$packages$problems$kind)
  expect_true(all(c("DESeq2", "S4Vectors", "dplyr") %in% r$state$file$lock$entries$name))
  expect_equal(r$state$file$header$bioc_version, "3.23")
})

test_that("a date move on an R with no known Bioconductor release fails instead of dropping Bioc packages (89)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46))
  locked <- deliver_bioc(open_with_cran(s)$state)$state$file$lock
  r47 <- list(version = "4.7.0", minor = "4.7", platform = "x86_64-pc-linux-gnu")
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r47),
                 lock = locked, bioc_version = "3.23")
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_preview_date("2026-09-30", at(2)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(3)))
  expect_equal(r$state$packages$proposal$status, "failed")
  expect_match(r$state$packages$proposal$message, "Bioconductor has no release for R 4.7", fixed = TRUE)
  expect_equal(r$state$file$header$bioc_version, "3.23")
})

test_that("a failed Bioconductor index doesn't fail a date move for a notebook with no Bioc package (89)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)\nlibrary(nosuchpkg)")),
                 options = list(r = r46))
  r <- deliver_bioc(open_with_cran(s)$state)
  r <- drive(r$state, ev_preview_date("2026-09-30", at(5)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(6)))
  for (kind in names(bioc_kinds)) {
    r <- drive(r$state, ev_index_failed(repo_key(kind, "2026-09-30", "3.23"), "network down", at(7)))
  }
  expect_equal(r$state$packages$proposal$status, "ready")
  expect_true("dplyr" %in% r$state$packages$proposal$lock$entries$name)
})

test_that("a pinned release is kept on another R and flagged; an R with no known release finds no Bioc package (86)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")), options = list(r = r46),
                 bioc_version = "3.22")
  r <- open_with_cran(s)
  expect_equal(r$state$file$header$bioc_version, NA_character_)  # CRAN-only: the pin goes

  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46),
                 bioc_version = "3.22")
  r <- open_with_cran(s)
  expect_true(all(grepl("/3.22$", vapply(r$effects, function(e) e$key, character(1)))))
  r <- deliver_bioc(r$state, release = "3.22")
  expect_equal(r$state$file$header$bioc_version, "3.22")
  expect_true("bioc_r_version" %in% r$state$packages$problems$kind)

  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")),
                 options = list(r = list(version = "9.9.0", minor = "9.9", platform = "x")))
  r <- open_with_cran(s)
  expect_false("fetch_index" %in% effect_types(r))
  expect_true("DESeq2" %in% r$state$packages$problems$package)
  expect_true("bioc_unavailable" %in% r$state$packages$problems$kind)
})

test_that("with no Bioconductor release for this R at the date, a cell's error and the page say so, not \"not found in any repository\"", {
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")),
                 options = list(r = list(version = "9.9.0", minor = "9.9", platform = "x")))
  r <- open_with_cran(s)
  why <- paste("DESeq2 isn't on CRAN at this date, and Bioconductor has no release for R 9.9 at 2026-09-01",
               "(the release then, 3.23, requires R 4.6), so Bioconductor packages can't be found.",
               "To use them, run the notebook on R 4.6")
  err <- missing_package_error(r$state, "DESeq2")$error
  expect_equal(err$message, paste0("there is no package called 'DESeq2': ", why))
  view <- packages_view(r$state)
  row <- view$packages[view$packages$name == "DESeq2", ]
  expect_equal(row$status, "not_found")  # running again won't find it
  expect_equal(row$message, why)
})

test_that("the no-release row says what to do: the R the date's release needs, or this R's first release on (#431)", {
  releases <- fixture_releases()
  nf <- package_problem("not_found", "limma", "limma was not found in any repository at this date")
  row <- bioc_unavailable_problem(character(), nf, list(snapshot = "2025-01-15"), list(minor = "4.6"), releases)
  expect_equal(row$message, paste(
    "Bioconductor has no release for R 4.6 at 2025-01-15 (the release then, 3.20, requires R 4.4;",
    "R 4.6's first, 3.23, came out on 2026-04-29), so Bioconductor packages can't be found.",
    "To use them, run the notebook on R 4.4, or move its date to 2026-04-29 or later with Update in the Packages tab"))
  # Without the release list there is only the reason.
  row <- bioc_unavailable_problem(character(), nf, list(snapshot = "2025-01-15"), list(minor = "4.6"))
  expect_equal(row$message, "Bioconductor has no release for R 4.6 at 2025-01-15, so Bioconductor packages can't be found")
})

test_that("a date move keeps Bioconductor packages, and fails rather than dropping them when its index can't be fetched (87)", {
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46))
  r <- deliver_bioc(open_with_cran(s)$state)
  r <- drive(r$state, ev_preview_date("2026-09-30", at(7)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_index("2026-09-30"), at(8)))
  keys <- vapply(r$effects, function(e) e$key, character(1))
  expect_true("bioc/2026-09-30/3.23" %in% keys)

  ok <- deliver_bioc(r$state, date = "2026-09-30", t = 9)
  prop <- ok$state$packages$proposal
  expect_equal(prop$status, "ready")
  expect_true(all(c("DESeq2", "S4Vectors") %in% prop$lock$entries$name))
  expect_equal(prop$bioc_version, "3.23")

  bad <- drive(r$state, ev_index_failed("bioc/2026-09-30/3.23", "network down", at(9)))
  expect_equal(bad$state$packages$proposal$status, "failed")
  expect_match(bad$state$packages$proposal$message, "network down", fixed = TRUE)
})

# ---- Bioconductor's release list -----------------------------------------------

#' Repos with the release-list lookup on and no list yet. The URL only
#' names the effect: the shell's job is stood in for by
#' `ev_bioc_releases_fetched/failed`.
lookup_repos <- ember_repos(bioc_config = "file:///fixtures/config.yaml")
#' Open with no release list and deliver CRAN's index at `date` (the
#' 2026-09-30 fixture standing in for any date).
open_without_list <- function(code, date = "2026-11-02", lock = empty_lock(),
                              bioc_version = NA_character_) {
  s <- pkg_state(list(S = cell(""), A = cell(code)), options = list(r = r46, repos = lookup_repos),
                 snapshot = date, lock = lock, bioc_version = bioc_version)
  r <- drive(s, ev_open(at(1)))
  cran <- read_repo_index(testthat::test_path("fixtures", "repos", "cran", "2026-09-30", "src", "contrib",
                                              "PACKAGES"), key = repo_key("cran", date), label = "CRAN")
  drive(r$state, ev_index_fetched(repo_key("cran", date), cran, at(2)))
}

test_that("the first Bioconductor name fetches the release list before any index, and a new release needs no code change", {
  r <- open_without_list("library(DESeq2)")
  expect_equal(effect_types(r), "fetch_bioc_config")
  expect_equal(find_effect(r, "fetch_bioc_config")$url, "file:///fixtures/config.yaml")
  expect_equal(r$state$packages$bioc_releases$status, "fetching")
  # Cells naming it wait for the list as they would for an index.
  expect_equal(waiting_cells(r$state)$A, "DESeq2")

  expect_equal(find_effect(r, "fetch_bioc_config")$date, "2026-11-02")
  r <- drive(r$state, ev_bioc_releases_fetched(fixture_releases("config-3.24.yaml"), as.Date("2026-11-02"), at(3)))
  expect_setequal(vapply(r$effects, function(e) e$key, character(1)),
                  c("bioc/2026-11-02/3.24", "bioc-ann/2026-11-02/3.24", "bioc-exp/2026-11-02/3.24"))
  r <- deliver_bioc(r$state, release = "3.24", date = "2026-11-02", t = 4)
  expect_equal(r$state$file$header$bioc_version, "3.24")
  expect_false("fetch_bioc_config" %in% effect_types(r))  # once a session
})

test_that("with no release list at all, Bioconductor names are not found and the page says why; run asks again", {
  r <- open_without_list("library(DESeq2)")
  msg <- "couldn't fetch Bioconductor's release list from x, and there is no copy from an earlier fetch"
  r <- drive(r$state, ev_bioc_releases_failed(msg, at(3)))
  expect_false("fetch_index" %in% effect_types(r))
  expect_true("DESeq2" %in% r$state$packages$problems$package)
  view <- packages_view(r$state)
  expect_equal(view$problems$message[view$problems$kind == "bioc_releases_unavailable"],
               paste("Bioconductor packages can't be resolved:", msg))
  expect_false("bioc_unavailable" %in% view$problems$kind)
  expect_equal(view$packages$status[view$packages$name == "DESeq2"], "lookup_failed")
  expect_match(view$packages$message[view$packages$name == "DESeq2"], msg, fixed = TRUE)

  r <- drive(r$state, ev_run(NULL, at(4)))
  expect_true("fetch_bioc_config" %in% effect_types(r))
})

test_that("a CRAN-only notebook never fetches the release list", {
  r <- open_without_list("library(dplyr)")
  expect_false("fetch_bioc_config" %in% effect_types(r))
  expect_equal(r$state$packages$bioc_releases$status, "unknown")
})

test_that("bioc_config = NA turns Bioconductor off, and says so only where a release was needed", {
  off <- list(r = r46, repos = ember_repos(bioc_config = NA))
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = off)
  r <- open_with_cran(s)
  expect_false("fetch_bioc_config" %in% effect_types(r))
  expect_match(packages_view(r$state)$problems$message, "release lookup is off", fixed = TRUE, all = FALSE)

  r <- open_with_cran(pkg_state(list(S = cell(""), A = cell("library(dplyr)")), options = off))
  expect_equal(nrow(packages_view(r$state)$problems), 0)

  # A pinned notebook needs no list to resolve.
  lock <- new_lock(c("DESeq2", "S4Vectors", "cli"), c("1.50.0", "0.48.0", "3.6.5"), c("Bioc", "Bioc", "CRAN"))
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)\nlibrary(dplyr)")), options = off,
                 lock = lock, bioc_version = "3.23")
  r <- deliver_bioc(open_with_cran(s)$state)
  expect_true("dplyr" %in% r$state$file$lock$entries$name)
  expect_false(any(grepl("^bioc_", packages_view(r$state)$problems$kind)))
})

test_that("a list fetched before the notebook's date isn't used for it: no silent pin, and the row says why", {
  r <- open_without_list("library(DESeq2)")
  # The shell couldn't fetch, and fell back to a copy from 2026-10-08.
  r <- drive(r$state, ev_bioc_releases_fetched(fixture_releases(), as.Date("2026-10-08"), at(3)))
  expect_false("fetch_index" %in% effect_types(r))
  expect_true(is.na(r$state$file$header$bioc_version))
  view <- packages_view(r$state)
  expect_equal(view$problems$message[view$problems$kind == "bioc_releases_unavailable"],
               paste("Bioconductor packages can't be resolved: Bioconductor's release list was last fetched",
                     "on 2026-10-08, before this notebook's date 2026-11-02, and couldn't be fetched again"))
  # The same copy still speaks for its own day and earlier.
  expect_equal(bioc_release_for("4.6", "2026-10-08", releases_at(r$state$packages, "2026-10-08")), "3.23")

  # Running asks again, and a list that covers the date resolves it.
  r <- drive(r$state, ev_run(NULL, at(4)))
  expect_equal(find_effect(r, "fetch_bioc_config")$date, "2026-11-02")
  r <- drive(r$state, ev_bioc_releases_fetched(fixture_releases("config-3.24.yaml"), as.Date("2026-11-02"), at(5)))
  expect_true("bioc/2026-11-02/3.24" %in% vapply(r$effects, function(e) e$key %||% "", character(1)))
})

test_that("a list fetched earlier in the session is fetched again for a later date", {
  r <- open_without_list("library(DESeq2)", date = "2026-10-08")
  r <- drive(r$state, ev_bioc_releases_fetched(fixture_releases(), as.Date("2026-10-08"), at(3)))
  r <- deliver_bioc(r$state, date = "2026-10-08", t = 4)
  expect_equal(r$state$file$header$bioc_version, "3.23")
  r <- drive(r$state, ev_preview_date("2026-11-02", at(5)))
  expect_equal(find_effect(r, "fetch_bioc_config")$date, "2026-11-02")
  r <- drive(r$state, ev_bioc_releases_fetched(fixture_releases("config-3.24.yaml"), as.Date("2026-11-02"), at(6)))
  cran <- read_repo_index(testthat::test_path("fixtures", "repos", "cran", "2026-09-30", "src", "contrib",
                                              "PACKAGES"), key = repo_key("cran", "2026-11-02"), label = "CRAN")
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-11-02"), cran, at(7)))
  expect_true("bioc/2026-11-02/3.24" %in% vapply(r$effects, function(e) e$key %||% "", character(1)))
})

test_that("a reopened Bioc notebook fetches the list at open, and its pin's rows use it", {
  lock <- new_lock(c("DESeq2", "S4Vectors", "cli"), c("1.50.0", "0.48.0", "3.6.5"),
                   c("Bioc", "Bioc", "CRAN"))
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), snapshot = "2026-11-02",
                 options = list(r = r46, repos = lookup_repos), lock = lock, bioc_version = "3.23")
  r <- drive(s, ev_open(at(1)))
  expect_equal(effect_types(r), c("fetch_bioc_config", "check_library"))
  r <- drive(r$state, ev_bioc_releases_fetched(fixture_releases("config-3.24.yaml"), as.Date("2026-11-02"), at(2)))
  expect_true("bioc_off_date" %in% r$state$packages$problems$kind)
})

test_that("shutdown cancels a release-list fetch in flight", {
  r <- open_without_list("library(DESeq2)")
  r <- drive(r$state, ev_shutdown(at(3)))
  expect_equal(find_effect(r, "cancel_fetch_bioc_config")$url, "file:///fixtures/config.yaml")
})

# ---- R minor version change with a Bioconductor pin ----------------------------

#' A notebook pinned to Bioconductor 3.22 (R 4.5), opened on R 4.6 at
#' 2026-09-01. `cli` is locked behind the date's index to show a move
#' leaves CRAN packages alone.
pinned_322 <- function(snapshot = "2026-09-01", bioc_version = "3.22") {
  lock <- new_lock(c("DESeq2", "S4Vectors", "cli"), c("1.48.0", "0.46.0", "3.6.4"),
                   c("Bioc", "Bioc", "CRAN"))
  pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46),
            snapshot = snapshot, lock = lock, bioc_version = bioc_version)
}

test_that("safe preview says a pin built for another R will move, and moves nothing", {
  r <- drive(pinned_322(), ev_open(at(1)))
  probs <- r$state$packages$problems
  expect_match(probs$message[probs$kind == "bioc_r_version"],
               "Bioconductor 3.22 is built for R 4.5; this is R 4.6; running the notebook moves it to Bioconductor 3.23",
               fixed = TRUE)
  expect_null(r$state$packages$proposal)
  expect_equal(r$state$file$header$bioc_version, "3.22")
  expect_false("fetch_index" %in% effect_types(r))
})

test_that("running on the new R moves the pin and the Bioconductor packages before installing anything", {
  r <- drive(pinned_322(), ev_open(at(1)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(2)))
  r <- drive(r$state, ev_allow(at(3)))
  expect_equal(r$state$file$header$r_version, "4.6.1")
  expect_equal(r$state$packages$proposal$kind, "bioc")
  # The old pin's library would build every Bioconductor package from source.
  expect_false("install" %in% effect_types(r))
  expect_equal(find_effect(r, "fetch_index")$key, "cran/2026-09-01")

  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(4)))
  expect_setequal(vapply(Filter(function(e) identical(e$type, "fetch_index"), r$effects),
                         function(e) e$key, character(1)),
                  c("bioc/2026-09-01/3.23", "bioc-ann/2026-09-01/3.23", "bioc-exp/2026-09-01/3.23"))
  expect_false("install" %in% effect_types(r))
  r <- deliver_bioc(r$state, t = 5)
  expect_null(r$state$packages$proposal)
  expect_equal(r$state$file$header$bioc_version, "3.23")
  expect_equal(format_lock_lines(r$state$file$lock),
               c("DESeq2 1.50.0 Bioc", "S4Vectors 0.48.0 Bioc", "cli 3.6.4 CRAN"))
  expect_false("bioc_r_version" %in% r$state$packages$problems$kind)

  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(6)))
  inst <- find_effect(r, "install")
  expect_match(inst$repos[["BioCsoft"]], "/2026-09-01/packages/3.23/bioc", fixed = TRUE)
})

#' A pinned notebook allowed to run on the new R, its move pending.
pending_move <- function() {
  r <- drive(pinned_322(), ev_open(at(1)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(2)), ev_allow(at(3)))
  expect_equal(r$state$packages$proposal$kind, "bioc")
  r
}

test_that("a date preview waits for a pending move, then is made (323)", {
  r <- drive(pending_move()$state, ev_preview_date("2026-10-01", at(4), apply = TRUE))
  expect_true(isTRUE(r$reply))
  expect_equal(r$state$packages$proposal$kind, "bioc")
  expect_false("install" %in% effect_types(r))
  # A second request replaces the first: the latest is what was asked for.
  r <- drive(r$state, ev_preview_date("2026-10-02", at(5), apply = TRUE))
  expect_equal(r$state$packages$held$date, "2026-10-02")

  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(6)))
  r <- deliver_bioc(r$state, t = 7)
  expect_equal(r$state$file$header$bioc_version, "3.23")
  prop <- r$state$packages$proposal
  expect_equal(list(prop$kind, prop$date, prop$apply), list("date", "2026-10-02", TRUE))
  expect_null(r$state$packages$held)
  expect_equal(r$state$packages$indexes[["cran/2026-10-02"]]$status, "fetching")
})

test_that("a per-package update waits for a pending move, then is made (323)", {
  r <- drive(pending_move()$state, ev_preview_update("cli", NULL, "2026-10-01", at(4)))
  expect_true(isTRUE(r$reply))
  expect_equal(r$state$packages$proposal$kind, "bioc")
  expect_false("fetch_cran_releases" %in% effect_types(r))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(5)))
  r <- deliver_bioc(r$state, t = 6)
  expect_equal(r$state$file$header$bioc_version, "3.23")
  expect_equal(r$state$packages$proposal$update$name, "cli")
  expect_equal(r$state$packages$cran_releases$status, "fetching")
  # A package the lock doesn't have is still refused at once.
  r2 <- drive(pending_move()$state, ev_preview_update("dplyr", NULL, "2026-10-01", at(4)))
  expect_s3_class(r2$reply, "ember_refused")
})

test_that("Cancel leaves a pending move alone and drops a preview held for it (323)", {
  r <- drive(pending_move()$state, ev_preview_date("2026-10-01", at(4)), ev_cancel_preview(at(5)))
  expect_equal(r$state$packages$proposal$kind, "bioc")
  expect_null(r$state$packages$held)
  expect_false("install" %in% effect_types(r))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(6)))
  r <- deliver_bioc(r$state, t = 7)
  expect_equal(r$state$file$header$bioc_version, "3.23")
  expect_null(r$state$packages$proposal)
})

test_that("a preview open from safe preview waits for the move, so the old pin doesn't install (323)", {
  r <- drive(pinned_322(), ev_open(at(1)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(2)),
             ev_preview_date("2026-10-01", at(3)), ev_allow(at(4)))
  expect_equal(r$state$packages$proposal$kind, "bioc")
  expect_equal(r$state$packages$held$date, "2026-10-01")
  expect_false("install" %in% effect_types(r))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(5)))
  r <- deliver_bioc(r$state, t = 6)
  expect_equal(r$state$file$header$bioc_version, "3.23")
  expect_equal(list(r$state$packages$proposal$kind, r$state$packages$proposal$date), list("date", "2026-10-01"))
})

test_that("a request held before the move is proposed wins over the older open preview (323)", {
  lock <- new_lock(c("DESeq2", "S4Vectors", "cli"), c("1.48.0", "0.46.0", "3.6.4"), c("Bioc", "Bioc", "CRAN"))
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), options = list(r = r46, repos = lookup_repos),
                 snapshot = "2026-09-01", lock = lock, bioc_version = "3.22")
  r <- drive(s, ev_open(at(1)), ev_bioc_releases_failed("offline", at(2)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(3)),
             ev_preview_date("2026-10-01", at(4)), ev_allow(at(5)))
  expect_equal(r$state$packages$proposal$date, "2026-10-01")
  # Run asks for the list again; the Update click meanwhile is held.
  r <- drive(r$state, ev_run(NULL, at(6)))
  expect_equal(r$state$packages$bioc_releases$status, "fetching")
  r <- drive(r$state, ev_preview_date("2026-10-02", at(7), apply = TRUE))
  expect_equal(r$state$packages$held$date, "2026-10-02")
  r <- drive(r$state, ev_bioc_releases_fetched(fixture_releases(), as.Date("2026-10-08"), at(8)))
  expect_equal(r$state$packages$proposal$kind, "bioc")
  expect_equal(list(r$state$packages$held$date, r$state$packages$held$apply), list("2026-10-02", TRUE))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(9)))
  r <- deliver_bioc(r$state, t = 10)
  expect_equal(r$state$file$header$bioc_version, "3.23")
  prop <- r$state$packages$proposal
  expect_equal(list(prop$kind, prop$date, prop$apply), list("date", "2026-10-02", TRUE))
})

test_that("a date preview replaces a move that failed", {
  r <- drive(pinned_322(), ev_open(at(1)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(2)), ev_allow(at(3)),
             ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(4)),
             ev_index_failed("bioc/2026-09-01/3.23", "network down", at(5)))
  expect_equal(r$state$packages$proposal$status, "failed")
  r <- drive(r$state, ev_preview_date("2026-10-01", at(6)))
  expect_true(isTRUE(r$reply))
  expect_equal(r$state$packages$proposal$kind, "date")
})

test_that("a move that would change a loaded package applies anyway and restarts R once installed", {
  r <- drive(pinned_322(), ev_open(at(1)), ev_allow(at(2)))
  r$state$worker$loaded <- c(DESeq2 = "1.48.0")
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(3)))
  r <- deliver_bioc(r$state, t = 4)
  expect_null(r$state$packages$proposal)
  expect_equal(r$state$file$header$bioc_version, "3.23")
})

test_that("with no release for the new R at the notebook's date, the pin stays and installs as before", {
  r <- drive(pinned_322(snapshot = "2025-06-01", bioc_version = "3.21"), ev_open(at(1)))
  probs <- r$state$packages$problems
  expect_match(probs$message[probs$kind == "bioc_r_version"], "so it stays on 3.21", fixed = TRUE)
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(2)), ev_allow(at(3)))
  expect_null(r$state$packages$proposal)
  expect_true("install" %in% effect_types(r))
  expect_equal(r$state$file$header$bioc_version, "3.21")
})

test_that("a move whose index can't be fetched keeps the pin, says why, and is retried on run", {
  r <- drive(pinned_322(), ev_open(at(1)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(2)), ev_allow(at(3)),
             ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(4)),
             ev_index_failed("bioc/2026-09-01/3.23", "network down", at(5)))
  expect_equal(r$state$packages$proposal$status, "failed")
  expect_equal(r$state$file$header$bioc_version, "3.22")
  view <- packages_view(r$state)
  expect_match(view$problems$message[view$problems$kind == "bioc_move_failed"], "network down", fixed = TRUE)
  # The page's update question is only for date moves.
  expect_equal(view$proposal$kind, "bioc")
  # With the move given up, the old pin's library installs as it did before.
  expect_true("install" %in% effect_types(r))

  r <- drive(r$state, ev_run(NULL, at(6)))
  expect_equal(r$state$packages$proposal$kind, "bioc")
  expect_equal(r$state$packages$proposal$status, "fetching")
})

test_that("a pinned notebook waits for the release list before deciding a move", {
  lock <- new_lock(c("DESeq2", "S4Vectors"), c("1.50.0", "0.48.0"), c("Bioc", "Bioc"))
  r47 <- list(version = "4.7.0", minor = "4.7", platform = "x86_64-pc-linux-gnu")
  s <- pkg_state(list(S = cell(""), A = cell("library(DESeq2)")), snapshot = "2026-11-02",
                 options = list(r = r47, repos = lookup_repos), lock = lock, bioc_version = "3.23")
  r <- drive(s, ev_open(at(1)), ev_allow(at(2)))
  expect_null(r$state$packages$proposal)
  expect_false("install" %in% effect_types(r))
  # No release for R 4.7 in the fetched list either: no move, and the install goes ahead.
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(3)),
             ev_bioc_releases_fetched(fixture_releases("config-3.24.yaml"), as.Date("2026-11-02"), at(4)))
  expect_null(r$state$packages$proposal)
  expect_true("install" %in% effect_types(r))
})

# ---- Asking before a large download (#37) -------------------------------------

#' A notebook whose install has just started: `list(state, key, token)`.
installing_state <- function(options = list()) {
  s <- pkg_state(list(S = cell(""), A = cell("library(dplyr)")), options = options)
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_index(), at(2)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(3)))
  r <- drive(r$state, ev_allow(at(4)))
  list(r = r, key = r$state$packages$target$key, token = r$state$packages$install$token)
}

big_download <- function() {
  data.frame(package = c("org.Hs.eg.db", "GO.db"), version = c("3.22.0", "3.22.0"),
             bytes = c(2.1e9, 25e6), stringsAsFactors = FALSE)
}

test_that("an install asks above ask_above, and installs without asking once approved (130)", {
  st <- installing_state(options = list(ask_above = 1e8))
  install_fx <- Filter(function(fx) identical(fx$type, "install"), st$r$effects)
  expect_equal(install_fx[[1]]$ask_above, 1e8)

  r <- drive(st$r$state, ev_install_done(st$token, st$key, NULL, NULL, character(), at(5),
                                          download = big_download()))
  tgt <- r$state$packages$target
  expect_equal(tgt$status, "asking")
  expect_equal(tgt$download$package, c("org.Hs.eg.db", "GO.db"))
  # Nothing failed: no problem row, no new install, the cell still waits.
  expect_false("install_failed" %in% r$state$packages$problems$kind)
  expect_null(r$state$packages$install)
  expect_false(any(vapply(r$effects, function(fx) identical(fx$type, "install"), logical(1))))
  expect_true("A" %in% names(waiting_cells(r$state)))
  expect_equal(packages_view(r$state)$library$download$package, c("org.Hs.eg.db", "GO.db"))

  # Running again isn't an OK.
  r <- drive(r$state, ev_run("A", at(6)))
  expect_equal(r$state$packages$target$status, "asking")

  r <- drive(r$state, ev_approve_install(at(7)))
  expect_true(r$reply)
  expect_equal(r$state$packages$target$status, "installing")
  expect_null(r$state$packages$target$download)
  install_fx <- Filter(function(fx) identical(fx$type, "install"), r$effects)
  expect_length(install_fx, 1)
  expect_equal(install_fx[[1]]$ask_above, Inf)
})

test_that("the installer's no-binary notice shows while installing and clears when the next install starts (#19)", {
  st <- installing_state()
  pkgs <- c(cli = "3.6.2", rlang = "1.1.3")
  # Another install's notice is dropped.
  r <- drive(st$r$state, ev_install_no_binary(st$token + 1L, pkgs, at(5)))
  expect_null(r$state$packages$target$no_binary)
  r <- drive(r$state, ev_install_no_binary(st$token, pkgs, at(6)))
  expect_equal(r$state$packages$target$no_binary, pkgs)
  expect_equal(r$state$packages$target$status, "installing")
  expect_equal(packages_view(r$state)$library$no_binary, pkgs)
  # It doesn't stop anything: the cell still waits on the install.
  expect_true("A" %in% names(waiting_cells(r$state)))

  # The next install starts without it.
  r <- drive(r$state, ev_install_done(st$token, st$key, NULL, NULL, character(), at(7), download = big_download()))
  r <- drive(r$state, ev_approve_install(at(8)))
  expect_equal(r$state$packages$target$status, "installing")
  expect_null(r$state$packages$target$no_binary)
  expect_null(packages_view(r$state)$library$no_binary)
})

test_that("approve_install is refused when nothing waits for an OK (130)", {
  st <- installing_state()
  r <- drive(st$r$state, ev_approve_install(at(5)))
  expect_s3_class(r$reply, "ember_refused")
  expect_equal(r$state$packages$target$status, "installing")
})

test_that("ask_above comes from options(ember.ask_above), 500 MB by default (130)", {
  expect_equal(pkg_state(list(S = cell("")))$options$ask_above, 500e6)
  withr::local_options(ember.ask_above = Inf)
  expect_equal(pkg_state(list(S = cell("")))$options$ask_above, Inf)
})

test_that("download_lines() reads the installer's EMBER-DOWNLOAD lines, largest first (130)", {
  lines <- c("EMBER-PROGRESS 0 3 - restore", "EMBER-DOWNLOAD GO.db 3.22.0 25248437",
             "EMBER-DOWNLOAD org.Hs.eg.db 3.22.0 2100000000", "EMBER-DOWNLOAD BSgenome.X 1.0 NA")
  d <- download_lines(lines)
  expect_equal(d$package, c("org.Hs.eg.db", "GO.db", "BSgenome.X"))
  expect_equal(d$bytes, c(2.1e9, 25248437, NA))
  expect_null(download_lines(c("Error: something else")))
})

test_that("a Bioconductor move drops a step back rather than holding it as a preview (#311)", {
  r <- drive(pinned_322(), ev_open(at(1)))
  st <- r$state
  st$allowed <- TRUE
  st$packages$proposal <- new_proposal("2026-08-31", kind = "back", asked = "2026-09-01")
  st$packages$back_tried <- list(date = "2026-09-01", names = "DESeq2")
  out <- propose_bioc_move(st)
  expect_equal(out$packages$proposal$kind, "bioc")
  expect_null(out$packages$held)
  expect_null(out$packages$back_tried)
})
