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
write_toy_notebook <- function(snapshot = "2026-09-01", dir = NULL, code = "library(toyA)\ntoyA_hello()") {
  if (is.null(dir)) {
    dir <- tempfile("ember-nb-")
    dir.create(dir, recursive = TRUE)
  }
  cell_id <- "A"
  cells <- list(S = list(code = "", kind = "code", folded = FALSE),
               A = list(code = code, kind = "code", folded = FALSE))
  header <- new_header(ember_version = as.character(utils::packageVersion("ember")),
                       r_version = paste(R.version$major, R.version$minor, sep = "."),
                       snapshot = snapshot)
  file <- new_notebook_file(
    header = header, cells = cells, run_order = names(cells),
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
  expect_equal(status$library$status, "ready",
               info = paste(c(status$library$message,
                              notebook_state(nb)$packages$target$log), collapse = "\n"))
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

# ---- 77: updating one package ------------------------------------------------

test_that("preview_update finds toyA's dates in CRAN's index of its files and previews them, offline (77)", {
  # toy-meta holds archive.rds and current.rds as CRAN writes them: toyA
  # 0.1 out on 2026-09-01, 0.2 on 2026-09-30. The toy repo has a snapshot
  # of 2026-09-29 too (the 09-01 packages), the last day 0.1 was current.
  meta <- normalizePath(testthat::test_path("fixtures", "repos", "toy-meta"), mustWork = TRUE)
  repos <- toy_repos()
  repos$cran_meta <- paste0("file://", meta)
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  path <- write_toy_notebook("2026-09-01")

  nb <- open_notebook(path, repos = repos, cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 120)
  expect_false(res$timed_out)

  up <- preview_update(nb, "toyA", timeout = 120)
  expect_equal(up$status, "ready")
  expect_equal(up$date, "2026-09-30")
  row <- up$changes[up$changes$name == "toyA", ]
  expect_equal(c(row$from, row$to, row$change), c("0.1", "0.2", "upgraded"))
  expect_true(file.exists(cran_releases_rds_path(repos$cran_meta, cache)))

  set_date(nb, up$date)
  expect_equal(notebook_state(nb)$file$header$snapshot, "2026-09-30")

  pin <- preview_update(nb, "toyA", "0.1", timeout = 120)
  expect_equal(pin$status, "ready")
  expect_equal(pin$date, "2026-09-29")
  row <- pin$changes[pin$changes$name == "toyA", ]
  expect_equal(c(row$from, row$to, row$change), c("0.2", "0.1", "downgraded"))

  expect_error(preview_update(nb, "ggplot2"), "not in this notebook's packages", class = "ember_refused")
  never <- preview_update(nb, "toyA", "0.3", timeout = 120)
  expect_equal(never$status, "failed")
  expect_match(never$message, "never released toyA 0.3")
})

test_that("a row's Update through the server: CRAN's newer toyA shows, its question lists the change, and Update applies it, offline (#23)", {
  meta <- normalizePath(testthat::test_path("fixtures", "repos", "toy-meta"), mustWork = TRUE)
  repos <- toy_repos()
  repos$cran_meta <- paste0("file://", meta)
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  nb <- open_notebook(write_toy_notebook("2026-09-01"), repos = repos, cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 120)
  expect_false(res$timed_out)

  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  ws <- fake_socket()
  handle_message(server, ws, wire("connect", notebook_id = id))
  row_of <- function(name) Filter(function(r) identical(r$name, name), pluto_state(notebook_state(nb))$js$ember$packages$rows)[[1]]
  expect_null(row_of("toyA")$available)

  # The tab opening asks for CRAN's release dates.
  handle_message(server, ws, wire("ember_check_versions", notebook_id = id))
  expect_true(wait_for(nb, function(snap) {
    pk <- snap$packages$packages
    identical(pk$available[pk$name == "toyA"], "0.2")
  }, timeout = 120))
  expect_equal(row_of("toyA")$available, "0.2")

  handle_message(server, ws, wire("ember_update_package", notebook_id = id, name = "toyA", version = "0.2"))
  expect_true(wait_for(nb, function(snap) {
    identical(snap$packages$proposal$status, "ready")
  }, timeout = 120))
  pu <- pluto_state(notebook_state(nb))$js$ember$packages$package_update
  expect_equal(pu$name, "toyA")
  expect_equal(pu$status, "ready")
  expect_equal(pu$date, "2026-09-30")
  # toyA is the only package, so nothing else moves.
  expect_length(pu$changes, 0)
  expect_equal(notebook_state(nb)$file$header$snapshot, "2026-09-01")

  handle_message(server, ws, wire("ember_apply_update", notebook_id = id, date = pu$date))
  expect_equal(notebook_state(nb)$file$header$snapshot, "2026-09-30")
  expect_equal(unname(lock_versions(notebook_state(nb)$file$lock)["toyA"]), "0.2")
  expect_null(pluto_state(notebook_state(nb))$js$ember$packages$package_update)
  expect_null(row_of("toyA")$available)
})

test_that("release dates that can't be fetched fail the preview and say where from (77)", {
  repos <- toy_repos()
  repos$cran_meta <- paste0("file://", tempfile("ember-no-meta-"))
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  nb <- open_notebook(write_toy_notebook("2026-09-01"), repos = repos, cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  run_cells(nb, wait = TRUE, timeout = 120)
  res <- preview_update(nb, "toyA", timeout = 120)
  expect_equal(res$status, "failed")
  expect_match(res$message, "couldn't fetch CRAN's release dates from file://", fixed = TRUE)
})

# ---- #450: a download cut short is fetched again --------------------------------

test_that("a package download cut short is deleted and fetched again, and the install finishes (#450)", {
  # The toy repo over HTTP, cutting renv's first download of each archive
  # in half: renv installs what it downloaded without opening it, so
  # without the installer's second try the install fails.
  root <- normalizePath(testthat::test_path("fixtures", "repos", "toy"), mustWork = TRUE)
  server <- processx::process$new(file.path(R.home("bin"), "Rscript"),
                                  c("--vanilla", testthat::test_path("fixtures", "cut-download-server.R"), root),
                                  stdout = "|", stderr = "|")
  on.exit(server$kill(), add = TRUE)
  server$poll_io(-1)
  first <- server$read_output_lines()
  port <- sub("^PORT ([0-9]+).*", "\\1", first[[1]])
  expect_match(first[[1]], "^PORT [0-9]+")

  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  nb <- open_notebook(write_toy_notebook("2026-09-01"),
                      repos = ember_repos(cran = sprintf("http://127.0.0.1:%s", port)), cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 120)
  expect_false(res$timed_out)

  status <- package_status(nb)
  expect_equal(status$library$status, "ready",
               info = paste(c(status$library$message, notebook_state(nb)$packages$target$log), collapse = "\n"))
  expect_equal(snap_view(notebook_snapshot(nb), "A")$output$text, "[1] \"toyA 0.1 says: hello from toyB\"")
  # Each archive was cut once and fetched whole the second time.
  got <- c(first[-1], server$read_output_lines())
  expect_true(all(c("GET toyA_0.1.tar.gz 2", "GET toyB_1.0.tar.gz 2") %in% trimws(got)), info = paste(got, collapse = "\n"))
})

# ---- #39: today's index is fetched again --------------------------------------

test_that("an index dated today is fetched again by a preview of today, a later session reads that copy, and the saved copy stands in offline (#39)", {
  # A file:// repository dated today (UTC), first with the toy repo's
  # 2026-09-01 packages (toyA 0.1), then, "later that day", with its
  # 2026-09-30 ones (toyA 0.2); and 2026-09-01 itself, for an older notebook.
  today <- format(as.Date(format(Sys.time(), tz = "UTC")))
  toy <- normalizePath(testthat::test_path("fixtures", "repos", "toy"), mustWork = TRUE)
  root <- tempfile("ember-today-repo-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  publish <- function(from) {
    staging <- tempfile("ember-today-staging-")
    dir.create(staging)
    on.exit(unlink(staging, recursive = TRUE))
    unlink(file.path(root, today), recursive = TRUE)
    stopifnot(file.copy(file.path(toy, from), staging, recursive = TRUE),
              file.rename(file.path(staging, from), file.path(root, today)))
  }
  stopifnot(file.copy(file.path(toy, "2026-09-01"), root, recursive = TRUE))
  repos <- ember_repos(cran = paste0("file://", root))
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  toyA <- function(nb) {
    e <- notebook_state(nb)$file$lock$entries
    e$version[e$name == "toyA"]
  }
  open_locked <- function(snapshot = today) {
    nb <- open_notebook(write_toy_notebook(snapshot), repos = repos, cache = cache)
    ok <- wait_for(nb, function(snap) length(toyA(nb)) == 1, timeout = 120)
    list(nb = nb, ok = ok)
  }

  publish("2026-09-01")
  o1 <- open_locked()
  on.exit(close_notebook(o1$nb), add = TRUE)
  expect_true(o1$ok)
  expect_equal(toyA(o1$nb), "0.1")

  # toyA 0.2 is added to today's snapshot. Opening reads the saved copy, as
  # for any date: fetching on every open would cost seconds.
  publish("2026-09-30")
  o2 <- open_locked()
  on.exit(close_notebook(o2$nb), add = TRUE)
  expect_true(o2$ok)
  expect_equal(toyA(o2$nb), "0.1")

  # An older notebook updating to today fetches today's index rather than
  # reading the copy the first session saved this morning.
  old <- open_locked("2026-09-01")
  on.exit(close_notebook(old$nb), add = TRUE)
  expect_true(old$ok)
  preview0 <- preview_date(old$nb, today, wait = TRUE, timeout = 120)
  expect_equal(preview0$status, "ready")
  expect_equal(preview0$changes$to[preview0$changes$name == "toyA"], "0.2")

  # So does updating to today in a session that already has an index for
  # today.
  preview <- preview_date(o1$nb, today, wait = TRUE, timeout = 120)
  expect_equal(preview$status, "ready")
  expect_equal(preview$changes$to[preview$changes$name == "toyA"], "0.2")

  # A session opened after that reads the copy that fetch saved.
  o3 <- open_locked()
  on.exit(close_notebook(o3$nb), add = TRUE)
  expect_true(o3$ok)
  expect_equal(toyA(o3$nb), "0.2")

  # Offline, updating to today in the session still on the morning's copy:
  # the fetch fails, and the copy saved by the last fetch stands in.
  unlink(root, recursive = TRUE)
  preview2 <- preview_date(o2$nb, today, wait = TRUE, timeout = 120)
  expect_equal(preview2$status, "ready")
  expect_equal(preview2$changes$to[preview2$changes$name == "toyA"], "0.2")
})

test_that("a new notebook dated a day the repository hasn't published yet installs from the day before, and saves that date (#162)", {
  # A file:// repository with yesterday (UTC) and no folder for today: what
  # Package Manager looks like early in a new day.
  today <- as.Date(format(Sys.time(), tz = "UTC"))
  yesterday <- format(today - 1)
  toy <- normalizePath(testthat::test_path("fixtures", "repos", "toy"), mustWork = TRUE)
  root <- tempfile("ember-unpublished-repo-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  stopifnot(file.copy(file.path(toy, "2026-09-01"), root, recursive = TRUE),
            file.rename(file.path(root, "2026-09-01"), file.path(root, yesterday)))
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)

  path <- write_toy_notebook(format(today))
  nb <- open_notebook(path, repos = ember_repos(cran = paste0("file://", root)), cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  run_cells(nb, "A", wait = TRUE, timeout = 120)

  expect_equal(package_status(nb)$snapshot, yesterday)
  expect_equal(notebook_snapshot(nb)$cells[[2]]$status, "ok")
  e <- notebook_state(nb)$file$lock$entries
  expect_equal(e$version[e$name == "toyA"], "0.1")
  expect_equal(nrow(package_status(nb)$problems), 0)
  expect_true(wait_for(nb, function(snap) any(grepl(yesterday, readLines(path), fixed = TRUE)), timeout = 30))
})

test_that("updating to a day the repository hasn't published yet offers the day before, and set_date() applies it (#162)", {
  # The repository has 2026-09-01 and yesterday (UTC, toyA 0.2), and no
  # folder for today: "Update all" early in a new day.
  today <- as.Date(format(Sys.time(), tz = "UTC"))
  yesterday <- format(today - 1)
  toy <- normalizePath(testthat::test_path("fixtures", "repos", "toy"), mustWork = TRUE)
  root <- tempfile("ember-unpublished-repo-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  stopifnot(file.copy(file.path(toy, c("2026-09-01", "2026-09-30")), root, recursive = TRUE),
            file.rename(file.path(root, "2026-09-30"), file.path(root, yesterday)))
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)

  path <- write_toy_notebook("2026-09-01")
  nb <- open_notebook(path, repos = ember_repos(cran = paste0("file://", root)), cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  run_cells(nb, "A", wait = TRUE, timeout = 120)

  preview <- preview_date(nb, format(today), wait = TRUE, timeout = 120)
  expect_equal(preview$status, "ready")
  expect_equal(preview$date, yesterday)
  expect_equal(preview$changes$to[preview$changes$name == "toyA"], "0.2")
  set_date(nb, preview$date)
  expect_equal(package_status(nb)$snapshot, yesterday)
})

test_that("Update with nothing loaded applies the newest published date and preview_date() returns at once with it (#221)", {
  today <- as.Date(format(Sys.time(), tz = "UTC"))
  yesterday <- format(today - 1)
  toy <- normalizePath(testthat::test_path("fixtures", "repos", "toy"), mustWork = TRUE)
  root <- tempfile("ember-unpublished-repo-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  stopifnot(file.copy(file.path(toy, c("2026-09-01", "2026-09-30")), root, recursive = TRUE),
            file.rename(file.path(root, "2026-09-30"), file.path(root, yesterday)))
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)

  path <- write_toy_notebook("2026-09-01")
  nb <- open_notebook(path, repos = ember_repos(cran = paste0("file://", root)), cache = cache)
  on.exit(close_notebook(nb), add = TRUE)

  res <- preview_date(nb, format(today), apply = TRUE, wait = TRUE, timeout = 60)
  expect_equal(res$status, "ready")
  expect_equal(res$date, yesterday)
  expect_equal(package_status(nb)$snapshot, yesterday)

  # A date further ahead than tomorrow in UTC is no clock's today: it fails
  # at once instead of stepping back day by day.
  far <- preview_date(nb, format(today + 30), wait = TRUE, timeout = 60)
  expect_equal(far$status, "failed")
  expect_equal(far$date, format(today + 30))
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

test_that("an install call runs neither in the session nor in ember::run(): the lock answers it (#79)", {
  repos <- toy_repos()
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  # Run, install.packages() would fail: no repository is set under
  # `Rscript --vanilla`, and the session's library isn't one to install
  # into.
  path <- write_toy_notebook("2026-09-01", code = 'install.packages("toyA")\nlibrary(toyA)\ntoyA_hello()')
  nb <- open_notebook(path, repos = repos, cache = cache)
  res <- run_cells(nb, wait = TRUE, timeout = 120)
  expect_false(res$timed_out)
  view <- snap_view(notebook_snapshot(nb), "A")
  expect_equal(view$status, "ok")
  expect_equal(view$from_lock, "toyA")
  expect_match(view$output$text, "toyA 0.1 says: hello from toyB", fixed = TRUE)
  close_notebook(nb)

  msgs <- character()
  out <- testthat::capture_output(withCallingHandlers(
    status <- run(path, repos = repos, cache = cache, echo = TRUE),
    message = function(m) { msgs <<- c(msgs, conditionMessage(m)); invokeRestart("muffleMessage") }))
  expect_equal(status, 0L)
  expect_match(out, "toyA 0.1 says: hello from toyB", fixed = TRUE)
  expect_true(any(grepl("ember: install calls don't run; the lock gives toyA", msgs, fixed = TRUE)))
})

# ---- GitHub sources ([sources], #20) -----------------------------------------

#' `toy_repos()` plus the `file://` GitHub fixture (fixtures/github): toyC,
#' which imports toyB from the toy repo, at 0.3.0 (tag v0.3.0) and 0.4.0
#' (main).
toy_github_repos <- function() {
  toy <- normalizePath(testthat::test_path("fixtures", "repos", "toy"), mustWork = TRUE)
  gh <- github_fixture_dir()
  ember_repos(cran = paste0("file://", toy), github = paste0("file://", gh))
}

#' A notebook using toyC from `spec` in its `[sources]`, with an empty lock.
write_toyc_notebook <- function(spec) {
  dir <- tempfile("ember-nb-")
  dir.create(dir, recursive = TRUE)
  cells <- list(S = list(code = "", kind = "code", folded = FALSE),
               A = list(code = "library(toyC)\ntoyC_hello()", kind = "code", folded = FALSE))
  header <- new_header(ember_version = as.character(utils::packageVersion("ember")),
                       r_version = paste(R.version$major, R.version$minor, sep = "."),
                       snapshot = "2026-09-01", sources = c(toyC = spec))
  file <- new_notebook_file(
    header = header, cells = cells, run_order = names(cells), learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = empty_lock(), extra_blocks = list(), format = ember_format)
  path <- file.path(dir, "nb.R")
  stopifnot(write_atomic(path, format_notebook(file)))
  path
}

test_that("a package from a [sources] GitHub entry installs at the ref's commit with its CRAN dependency, and runs", {
  repos <- toy_github_repos()
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  path <- write_toyc_notebook("github:lab/toyC@v0.3.0")

  nb <- open_notebook(path, repos = repos, cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 120)
  expect_false(res$timed_out)

  status <- package_status(nb)
  expect_equal(status$library$status, "ready",
               info = paste(c(status$library$message, notebook_state(nb)$packages$target$log), collapse = "\n"))
  expect_equal(snap_view(notebook_snapshot(nb), "A")$output$text, "[1] \"toyC 0.3.0 says: hello from toyB\"")
  pkgs <- status$packages
  expect_equal(pkgs$source[pkgs$name == "toyC"], "github:lab/toyC@3f2a1c90a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0")
  expect_equal(pkgs$source[pkgs$name == "toyB"], "CRAN")
  expect_true(all(pkgs$status == "installed"))
})

test_that("ember::run() installs a saved GitHub lock on a machine that never resolved it", {
  repos <- toy_github_repos()
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  path <- write_toyc_notebook("github:lab/toyC")

  nb <- open_notebook(path, repos = repos, cache = cache)
  res <- run_cells(nb, wait = TRUE, timeout = 120)
  expect_false(res$timed_out)
  close_notebook(nb)
  expect_match(read_file_utf8(path), "# toyC 0.4.0 github:lab/toyC@8e4b7d2c1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c",
               fixed = TRUE)

  # A fresh cache: no index for toyC's commit, so the installer looks its
  # DESCRIPTION up itself to install toyB first.
  cache2 <- toy_cache()
  on.exit(unlink(cache2, recursive = TRUE), add = TRUE)
  out <- testthat::capture_output(status <- run(path, repos = repos, cache = cache2, echo = TRUE))
  expect_equal(status, 0L)
  expect_match(out, "toyC 0.4.0 says: hello from toyB", fixed = TRUE)
})

# ---- r-universe sources ([sources], #203) ------------------------------------

#' `toy_repos()` plus the `file://` universe and GitHub fixtures: lab's
#' universe serves toyD 0.2.0 built from commit D2 of github.com/lab/toyD;
#' the GitHub fixture also has D1, the same version with other code.
toy_universe_repos <- function() {
  toy <- normalizePath(testthat::test_path("fixtures", "repos", "toy"), mustWork = TRUE)
  gh <- github_fixture_dir()
  u <- normalizePath(testthat::test_path("fixtures", "universe"), mustWork = TRUE)
  ember_repos(cran = paste0("file://", toy), github = paste0("file://", gh),
              universe = paste0("file://", u, "/%s"))
}

#' A notebook using toyD from `universe` (fixtures/universe), with `lock`
#' (none: empty).
write_toyd_notebook <- function(lock = empty_lock(), universe = "lab") {
  dir <- tempfile("ember-nb-")
  dir.create(dir, recursive = TRUE)
  cells <- list(S = list(code = "", kind = "code", folded = FALSE),
               A = list(code = "library(toyD)\ntoyD_hello()", kind = "code", folded = FALSE))
  header <- new_header(ember_version = as.character(utils::packageVersion("ember")),
                       r_version = paste(R.version$major, R.version$minor, sep = "."),
                       snapshot = "2026-09-01", sources = c(toyD = paste0("universe:", universe)))
  file <- new_notebook_file(
    header = header, cells = cells, run_order = names(cells), learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = lock, extra_blocks = list(), format = ember_format)
  path <- file.path(dir, "nb.R")
  stopifnot(write_atomic(path, format_notebook(file)))
  path
}

test_that("a package from a [sources] universe entry installs from the universe at the commit it built, and runs", {
  repos <- toy_universe_repos()
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  path <- write_toyd_notebook()

  nb <- open_notebook(path, repos = repos, cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 120)
  expect_false(res$timed_out)

  status <- package_status(nb)
  expect_equal(status$library$status, "ready",
               info = paste(c(status$library$message, notebook_state(nb)$packages$target$log), collapse = "\n"))
  expect_equal(snap_view(notebook_snapshot(nb), "A")$output$text, "[1] \"toyD at 2e1f5a9 says: hello from toyB\"")
  pkgs <- status$packages
  expect_equal(pkgs$source[pkgs$name == "toyD"],
               "universe:lab/github.com/lab/toyD@2e1f5a9c3b8a7f6e5d4c3b2a1908f7e6d5c4b3a2")
  # The universe's own build (its DESCRIPTION says so), not GitHub's.
  desc <- read.dcf(file.path(notebook_state(nb)$packages$target$path, "toyD", "DESCRIPTION"))
  expect_equal(unname(desc[, "Repository"]), "https://lab.r-universe.dev")
  expect_equal(unname(desc[, "RemoteSha"]), "2e1f5a9c3b8a7f6e5d4c3b2a1908f7e6d5c4b3a2")
  expect_false(identical(unname(desc[1, "RemoteType"]), "github"))
})

test_that("a universe build that isn't the commit its universe names is installed again from that commit", {
  # The stale universe says it built D2, but its tarball is D1's build, as a
  # binary that lags the source build would be.
  repos <- toy_universe_repos()
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  path <- write_toyd_notebook(universe = "stale")

  nb <- open_notebook(path, repos = repos, cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 120)
  expect_false(res$timed_out)
  status <- package_status(nb)
  expect_equal(status$library$status, "ready",
               info = paste(c(status$library$message, notebook_state(nb)$packages$target$log), collapse = "\n"))
  expect_equal(snap_view(notebook_snapshot(nb), "A")$output$text, "[1] \"toyD at 2e1f5a9 says: hello from toyB\"")
  desc <- read.dcf(file.path(notebook_state(nb)$packages$target$path, "toyD", "DESCRIPTION"))
  expect_equal(unname(desc[, "RemoteType"]), "github")
})

test_that("a locked commit the universe no longer serves installs from GitHub, even under the same version", {
  repos <- toy_universe_repos()
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  d1 <- "1d0c4e8b2a7f6e5d4c3b2a1908f7e6d5c4b3a291"
  lock <- new_lock(c("toyB", "toyD"), c("1.0", "0.2.0"),
                   c("CRAN", universe_source("lab", "https://github.com/lab/toyD", d1)))
  path <- write_toyd_notebook(lock)

  out <- testthat::capture_output(status <- run(path, repos = repos, cache = cache, echo = TRUE))
  expect_equal(status, 0L)
  expect_match(out, "toyD at 1d0c4e8 says: hello from toyB", fixed = TRUE)
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
    header = header, cells = cells, run_order = names(cells), learned = list(),
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

test_that("[net] preview_update(nb, \"dplyr\", \"1.1.4\") finds the date from CRAN's index and lists the changes (77)", {
  skip_if_not(identical(Sys.getenv("EMBER_TEST_NETWORK"), "1"),
             "set EMBER_TEST_NETWORK=1 to run the opt-in network test")

  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  dir <- tempfile("ember-nb-")
  dir.create(dir, recursive = TRUE)
  cells <- list(S = list(code = "", kind = "code", folded = FALSE),
               A = list(code = "library(dplyr)", kind = "code", folded = FALSE))
  header <- new_header(ember_version = as.character(utils::packageVersion("ember")),
                       r_version = paste(R.version$major, R.version$minor, sep = "."),
                       snapshot = "2026-06-01")
  file <- new_notebook_file(
    header = header, cells = cells, run_order = names(cells), learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = empty_lock(), extra_blocks = list(), format = ember_format)
  path <- file.path(dir, "nb.R")
  write_atomic(path, format_notebook(file))

  # Safe preview resolves the lock without installing anything.
  nb <- open_notebook(path, repos = ember_repos(), cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  expect_true(wait_for(nb, function(snap) "dplyr" %in% snap$packages$packages$name, timeout = 120))
  expect_equal(package_status(nb)$packages$version[package_status(nb)$packages$name == "dplyr"], "1.2.1")

  # 1.2.0 came out on 2026-02-03, so 1.1.4 was last current on 02-02.
  res <- preview_update(nb, "dplyr", "1.1.4", timeout = 300)
  expect_equal(res$status, "ready")
  expect_equal(res$date, "2026-02-02")
  row <- res$changes[res$changes$name == "dplyr", ]
  expect_equal(c(row$from, row$to, row$change), c("1.2.1", "1.1.4", "downgraded"))
})

test_that("[net] an r-universe package installs from its universe, and a commit it no longer serves from GitHub (#203)", {
  skip_if_not(identical(Sys.getenv("EMBER_TEST_NETWORK"), "1"),
             "set EMBER_TEST_NETWORK=1 to run the opt-in network test")

  # highr, from yihui's universe: small, pure R, one CRAN dependency
  # (xfun). The universe serves only its latest build, so the date is
  # recent enough for that build's xfun.
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  dir <- tempfile("ember-nb-")
  dir.create(dir, recursive = TRUE)
  cells <- list(A = list(code = "library(highr)\ncat(\"highr\", format(packageVersion(\"highr\")), \"\\n\")",
                        kind = "code", folded = FALSE))
  header <- new_header(ember_version = as.character(utils::packageVersion("ember")),
                       r_version = paste(R.version$major, R.version$minor, sep = "."),
                       snapshot = format(Sys.Date() - 3), sources = c(highr = "https://yihui.r-universe.dev/highr"))
  file <- new_notebook_file(
    header = header, cells = cells, run_order = names(cells), learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = empty_lock(), extra_blocks = list(), format = ember_format)
  path <- file.path(dir, "nb.R")
  write_atomic(path, format_notebook(file))

  nb <- open_notebook(path, cache = cache)
  res <- run_cells(nb, wait = TRUE, timeout = 300)
  expect_false(res$timed_out)
  status <- package_status(nb)
  # A failed universe lookup is reported (highr's row is "source_failed"),
  # not passed off as success, and running again retries it. r-universe
  # sometimes fails a request, so give it one more try before asserting
  # (#312).
  failed <- function(status) {
    any(status$packages$status[status$packages$name == "highr"] == "source_failed")
  }
  if (failed(status)) {
    res <- run_cells(nb, wait = TRUE, timeout = 300)
    expect_false(res$timed_out)
    status <- package_status(nb)
  }
  why <- function(status) {
    paste(c(status$library$message,
            utils::capture.output(print(status$problems)),
            utils::capture.output(print(status$packages[, intersect(c("name", "status", "source", "message"),
                                                                   names(status$packages))])),
            notebook_state(nb)$packages$target$log), collapse = "\n")
  }
  expect_false(failed(status), info = why(status))
  expect_equal(status$library$status, "ready", info = why(status))
  src <- parse_universe_source(status$packages$source[status$packages$name == "highr"])
  expect_equal(src$universe, "yihui", info = why(status))
  expect_equal(src$git, "https://github.com/yihui/highr")
  desc <- read.dcf(file.path(notebook_state(nb)$packages$target$path, "highr", "DESCRIPTION"))
  expect_equal(unname(desc[, "RemoteSha"]), src$sha)
  close_notebook(nb)
  expect_match(read_file_utf8(path), '# highr = "universe:yihui"', fixed = TRUE)

  # Pinned to v0.11's commit (c77ef6d), which the universe no longer serves:
  # a machine that never resolved it installs that commit from GitHub.
  text <- sub("# highr [^\n]+ universe:[^\n]+",
              "# highr 0.11 universe:yihui/github.com/yihui/highr@c77ef6daa04895918f3577cb291880ae8154e3e4",
              read_file_utf8(path))
  writeLines(text, path, sep = "")
  cache2 <- toy_cache()
  on.exit(unlink(cache2, recursive = TRUE), add = TRUE)
  out <- testthat::capture_output(code <- run(path, cache = cache2, echo = TRUE))
  expect_equal(code, 0L)
  expect_match(out, "highr 0.11", fixed = TRUE)
})

test_that("[net] a notebook with library(S4Vectors) installs from Bioconductor on PPM and loads", {
  # On Linux, renv's own binary rewrite turned Bioconductor's URL into one
  # Package Manager answers with a 404, so every Bioconductor package
  # failed as "failed to find source" (ppm_binary_repos()).
  skip_if_not(identical(Sys.getenv("EMBER_TEST_NETWORK"), "1"),
             "set EMBER_TEST_NETWORK=1 to run the opt-in network test")

  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  dir <- tempfile("ember-nb-")
  dir.create(dir, recursive = TRUE)
  cells <- list(A = list(code = "library(S4Vectors)\npackageVersion(\"S4Vectors\")",
                        kind = "code", folded = FALSE))
  header <- new_header(ember_version = as.character(utils::packageVersion("ember")),
                       r_version = paste(R.version$major, R.version$minor, sep = "."),
                       snapshot = "2026-10-08")
  file <- new_notebook_file(
    header = header, cells = cells, run_order = names(cells), learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = empty_lock(), extra_blocks = list(), format = ember_format)
  path <- file.path(dir, "nb.R")
  write_atomic(path, format_notebook(file))

  nb <- open_notebook(path, repos = ember_repos(), cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 600)
  expect_false(res$timed_out)

  status <- package_status(nb)
  expect_equal(status$library$status, "ready")
  row <- status$packages$name == "S4Vectors"
  expect_equal(status$packages$source[row], "Bioc")
  expect_equal(status$packages$status[row], "installed")
  expect_match(snap_view(notebook_snapshot(nb), "A")$output$text,
               status$packages$version[row], fixed = TRUE)
})

test_that("[net] on macOS and Windows, a Bioconductor package Package Manager has no binary of installs Bioconductor's (#22)", {
  # Package Manager's Bioconductor 3.23 has no macOS arm64 or Windows
  # binary of SNPRelate 1.46.0, so it built from source: on a Mac without
  # the Fortran runtime a package like that failed to link (`ld: library
  # 'emutls_w' not found`). CI's runners have the compilers, so the source
  # build would pass there too: the test checks where the package came from.
  # Bioconductor's repository isn't dated: once a 3.23 point release moves
  # SNPRelate past 1.46.0, its binary no longer matches the lock made at
  # 2026-10-08 and this fails. Then pick another package and date.
  skip_if_not(identical(Sys.getenv("EMBER_TEST_NETWORK"), "1") || identical(Sys.getenv("EMBER_TEST_BIOC_BINARIES"), "1"),
             "set EMBER_TEST_NETWORK=1 or EMBER_TEST_BIOC_BINARIES=1 to run the opt-in network test")
  skip_if(identical(os_kind(), "linux"), "Bioconductor's own binaries are for macOS and Windows")

  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  dir <- tempfile("ember-nb-")
  dir.create(dir, recursive = TRUE)
  cells <- list(A = list(code = "library(SNPRelate)\npackageVersion(\"SNPRelate\")",
                        kind = "code", folded = FALSE))
  header <- new_header(ember_version = as.character(utils::packageVersion("ember")),
                       r_version = paste(R.version$major, R.version$minor, sep = "."),
                       snapshot = "2026-10-08")
  file <- new_notebook_file(
    header = header, cells = cells, run_order = names(cells), learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = empty_lock(), extra_blocks = list(), format = ember_format)
  path <- file.path(dir, "nb.R")
  write_atomic(path, format_notebook(file))

  started <- Sys.time()
  nb <- open_notebook(path, repos = ember_repos(), cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 600)
  expect_false(res$timed_out)

  status <- package_status(nb)
  # What a failure needs to explain itself: the problems say why a name
  # wasn't found, the log why an install went wrong.
  why <- paste(c(status$library$message, status$problems$message,
                 notebook_state(nb)$packages$target$log), collapse = "\n")
  expect_equal(status$library$status, "ready", info = why)
  row <- status$packages$name == "SNPRelate"
  expect_equal(status$packages$version[row], "1.46.0", info = why)
  expect_equal(status$packages$status[row], "installed", info = why)
  expect_match(snap_view(notebook_snapshot(nb), "A")$output$text %||% "", "1.46.0", fixed = TRUE, info = why)
  # It came as a binary, and not Package Manager's, so Bioconductor's: a
  # build on this machine would have been built today, after `started`.
  # (renv's RemoteRepos can't say which repository: Bioconductor's Windows
  # binaries carry RemoteUrl, RemoteRef and RemoteSha of their own, and
  # renv then adds none.)
  ppm <- read_available(repo_url(ember_repos(), repo_key("bioc", "2026-10-08", "3.23")), .Platform$pkgType)
  expect_false(is.null(ppm))
  expect_false("SNPRelate" %in% ppm[, "Package"])
  built <- read.dcf(file.path(status$library$path, "SNPRelate", "DESCRIPTION"), fields = "Built")[1, 1]
  built_at <- as.POSIXct(trimws(strsplit(built, ";", fixed = TRUE)[[1]][[3]]), tz = "UTC")
  expect_lt(as.numeric(built_at), as.numeric(started))
})

# ---- 90: the empty-log regression, with the failing-installer fixture ------

#' A notebook naming `brokenpkg`, already locked (no index needed: the
#' lock alone answers `wanted_packages()`), written to a fresh temp folder.
write_broken_notebook <- function(dir = NULL) {
  if (is.null(dir)) {
    dir <- tempfile("ember-nb-")
    dir.create(dir, recursive = TRUE)
  }
  cells <- list(S = list(code = "library(brokenpkg)", kind = "code", folded = FALSE))
  header <- new_header(ember_version = as.character(utils::packageVersion("ember")),
                       r_version = paste(R.version$major, R.version$minor, sep = "."),
                       snapshot = "2026-09-01")
  lock <- parse_lock_lines("brokenpkg 0.1.0 CRAN")$lock
  file <- new_notebook_file(
    header = header, cells = cells, run_order = "S", learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = lock, extra_blocks = list(), format = ember_format)
  path <- file.path(dir, "nb.R")
  write_atomic(path, format_notebook(file))
  path
}

test_that("a notebook with the failing-installer option reports the real compiler error and a non-empty log (90)", {
  old <- getOption("ember.installer_script")
  options(ember.installer_script = testthat::test_path("fixtures", "failing-installer.R"))
  on.exit(options(ember.installer_script = old), add = TRUE)

  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  path <- write_broken_notebook()

  nb <- open_notebook(path, cache = cache)
  on.exit(close_notebook(nb), add = TRUE)

  res <- run_cells(nb, wait = TRUE, timeout = 60)
  expect_false(res$timed_out)

  status <- package_status(nb)
  expect_equal(status$library$status, "failed")
  expect_match(status$library$message, "compilation failed for package", fixed = TRUE)
  expect_gt(length(status$library$log), 10)
  expect_equal(status$library$failures$package, "brokenpkg")
})

test_that("packages with no binary for this R are named while they build, and the install goes on (#19)", {
  withr::local_options(ember.installer_script = testthat::test_path("fixtures", "no-binary-notice-installer.R"))
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  path <- write_broken_notebook()

  nb <- open_notebook(path, cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  run_cells(nb, wait = FALSE)
  expect_true(wait_for(nb, function(snap) length(snap$packages$library$no_binary) > 0, timeout = 120),
              info = paste(c(package_status(nb)$library$status, package_status(nb)$library$message),
                           collapse = ": "))
  status <- package_status(nb)
  expect_equal(status$library$status, "installing")
  expect_equal(status$library$no_binary, c(brokenpkg = "0.1.0", rlang = "1.1.3"))
})

test_that("a failed install keeps its no-binary notice, beside the no_binary failure (#19)", {
  withr::local_options(ember.installer_script = testthat::test_path("fixtures", "no-binary-installer.R"))
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  path <- write_broken_notebook()

  nb <- open_notebook(path, cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 60)
  expect_false(res$timed_out)
  status <- package_status(nb)
  expect_equal(status$library$status, "failed")
  expect_equal(status$library$no_binary, c(brokenpkg = "0.1.0"))
  expect_equal(status$library$failures$kind, "no_binary")
})

# ---- 130: a large download waits for an OK -----------------------------------

test_that("an install of a large Bioconductor data package waits for approve_install() (130)", {
  withr::local_options(ember.installer_script = system.file("fake-installer.R", package = "ember"),
                       ember.ask_above = 1000)
  cache <- toy_cache()
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  # The fixture repositories, with a 2 kB GO.db tarball for the size.
  root <- withr::local_tempdir()
  file.copy(testthat::test_path("fixtures", "bioc"), root, recursive = TRUE)
  writeBin(raw(2048), file.path(root, "bioc", "2026-09-01", "packages", "3.23", "data", "annotation",
                                "src", "contrib", "GO.db_3.22.0.tar.gz"))
  # They hold Bioconductor 3.23, R 4.6's release. A copy of the fixture config
  # maps 3.23 to the running R, so the notebook looks there on any R.
  config <- readLines(testthat::test_path("fixtures", "bioc-config", "config.yaml"))
  config <- sub('^(  "3\\.23": )"4\\.6"$', sprintf('\\1"%s"', r_info()$minor), config)
  expect_equal(bioc_release_for(r_info()$minor, "2026-09-01", parse_bioc_config(config)), "3.23")
  config_path <- file.path(root, "config.yaml")
  writeLines(config, config_path)
  fixture <- function(...) paste0("file://", normalizePath(testthat::test_path("fixtures", ...), winslash = "/"))
  repos <- ember_repos(cran = fixture("repos", "cran"),
                       bioc = paste0("file://", normalizePath(file.path(root, "bioc"), winslash = "/")),
                       bioc_config = paste0("file://", normalizePath(config_path, winslash = "/")))

  dir <- withr::local_tempdir()
  cells <- list(S = list(code = "", kind = "code", folded = FALSE),
                A = list(code = "library(GO.db)", kind = "code", folded = FALSE))
  header <- new_header(ember_version = as.character(utils::packageVersion("ember")),
                       r_version = paste(R.version$major, R.version$minor, sep = "."),
                       snapshot = "2026-09-01")
  file <- new_notebook_file(
    header = header, cells = cells, run_order = names(cells), learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = empty_lock(), extra_blocks = list(), format = ember_format)
  path <- file.path(dir, "nb.R")
  write_atomic(path, format_notebook(file))

  nb <- open_notebook(path, repos = repos, cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  run_cells(nb, wait = FALSE)
  expect_true(wait_for(nb, function(snap) identical(snap$packages$library$status, "asking"), timeout = 120),
              info = paste(c(package_status(nb)$library$status, package_status(nb)$library$message),
                           collapse = ": "))
  download <- package_status(nb)$library$download
  expect_equal(download$package, "GO.db")
  expect_equal(download$bytes, 2048)

  approve_install(nb)
  expect_true(wait_for(nb, function(snap) identical(snap$packages$library$status, "ready"), timeout = 120))
  expect_error(approve_install(nb), "no install is waiting")
})
