# Disk and jobs (R/library.R): library manifests, the index memo, the
# process-wide job table and `clean()`. No notebook and no worker: these
# are plain functions over the filesystem and over `processx` handles, so
# they're driven directly rather than through `drive()` or a session.
#
# Covers packages-tests.md items 59-66 ("Disk and jobs").

# ---- Helpers -------------------------------------------------------------

#' A bare environment that can receive events the way `enqueue()` (shell.R)
#' expects. Jobs only ever call `enqueue(sub$nb, event)`; they need nothing
#' else from a subscriber.
fake_sub <- function() {
  nb <- new.env(parent = emptyenv())
  nb$inbox <- list()
  nb
}

#' Run `poll_jobs()` until `predicate()` is true or `timeout` seconds pass.
#' Each iteration waits on the named jobs' own processes for a short slice
#' with `processx`'s `poll_io()` before checking again: a deadline, not a
#' bare `Sys.sleep()` loop, and not `socketSelect()`, which a `later` tick
#' already run in this process can make return early with nothing to read
#' (docs/engine.md).
poll_jobs_until <- function(predicate, keys, timeout = 15) {
  deadline <- Sys.time() + timeout
  repeat {
    poll_jobs(NULL)
    if (isTRUE(predicate())) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    for (key in keys) {
      job <- jobs[[key]]
      if (!is.null(job)) tryCatch(job$proc$poll_io(50), error = function(e) NULL)
    }
  }
}

#' A fake, ready library under `root`: a manifest and a last-used marker
#' backdated by `last_used_days_ago`, so `clean()` can be tested without an
#' installer ever running.
make_fake_library <- function(root, key, last_used_days_ago = 0,
                              cache_entries = character()) {
  path <- file.path(root, "libraries", "R-4.6", "testplat", key)
  dir.create(path, recursive = TRUE)
  manifest <- list(lock_lines = character(),
                   r = list(version = "4.6.0", minor = "4.6", platform = "testplat"),
                   installed = character(), exports = list(),
                   cache_entries = cache_entries, created = Sys.time())
  saveRDS(manifest, file.path(path, "ember-library.rds"))
  marker <- file.path(path, "ember-last-used")
  file.create(marker)
  Sys.setFileTime(marker, Sys.time() - last_used_days_ago * 86400)
  path
}

#' A fake staging folder under `root`, backdated by `age_days`.
make_fake_staging <- function(root, key, age_days = 0) {
  path <- file.path(root, "libraries", "R-4.6", "testplat",
                    paste0(key, ".staging-123-abcdef"))
  dir.create(path, recursive = TRUE)
  Sys.setFileTime(path, Sys.time() - age_days * 86400)
  path
}

# ---- Library manifests (59) -----------------------------------------------

test_that("read_library_manifest returns NULL for a missing folder and for a folder without a manifest (59)", {
  expect_null(read_library_manifest(file.path(tempdir(), paste0("ember-missing-", uuid()))))

  empty <- tempfile("ember-lib-empty-")
  dir.create(empty)
  expect_null(read_library_manifest(empty))

  ready <- tempfile("ember-lib-ready-")
  dir.create(ready)
  manifest <- list(lock_lines = "a 1.0 CRAN", r = r_info(), installed = c(a = "1.0"),
                   exports = list(a = "f"), cache_entries = character(), created = Sys.time())
  saveRDS(manifest, file.path(ready, "ember-library.rds"))
  expect_equal(read_library_manifest(ready), manifest)
})

# ---- The installer's rename race (60) --------------------------------------

test_that("two installs of one key racing in two processes leave one library and no staging folder (60)", {
  # The installed package under R CMD check (installed packages have Meta/);
  # the source tree under load_all(). Recompiling the source in each
  # subprocess fails on Windows while the parent holds the DLL.
  pkg_path <- find.package("ember")
  load_ember <- if (dir.exists(file.path(pkg_path, "Meta"))) {
    paste0("loadNamespace('ember', lib.loc = ", deparse(dirname(pkg_path)), ")")
  } else {
    paste0("suppressMessages(pkgload::load_all(", deparse(pkg_path), ", quiet = TRUE))")
  }
  path <- tempfile("ember-lib-race-")
  stagings <- c(paste0(path, ".staging-1"), paste0(path, ".staging-2"))

  rscript <- file.path(R.home("bin"), "Rscript")
  race_code <- function(staging) {
    paste0(
      load_ember, "; ",
      "dir.create(", deparse(staging), ", recursive = TRUE); ",
      "manifest <- list(lock_lines = character(), r = ember:::r_info(), ",
      "installed = character(), exports = list(), cache_entries = character(), ",
      "created = Sys.time()); ",
      "ember:::finish_library(", deparse(staging), ", ", deparse(path), ", manifest)")
  }
  procs <- lapply(stagings, function(st) {
    processx::process$new(rscript, c("--vanilla", "-e", race_code(st)),
                          stdout = "|", stderr = "2>&1")
  })

  deadline <- Sys.time() + 60
  for (p in procs) {
    remaining <- max(0, as.numeric(deadline - Sys.time(), units = "secs")) * 1000
    p$wait(remaining)
  }
  for (p in procs) {
    status <- tryCatch(p$get_exit_status(), error = function(e) NA_integer_)
    expect_identical(status, 0L, info = tryCatch(p$read_all_output(), error = function(e) ""))
  }

  expect_false(dir.exists(stagings[1]))
  expect_false(dir.exists(stagings[2]))
  expect_true(dir.exists(path))
  expect_false(is.null(read_library_manifest(path)))
})

# ---- The index memo (61) ---------------------------------------------------

test_that("cached_index returns the identical object to two callers in one process (61)", {
  cache <- tempfile("ember-cache-")
  dir.create(file.path(cache, "indexes"), recursive = TRUE)
  key <- paste0("cran/test-", uuid())
  idx <- structure(list(key = key, name = c("a", "b")), class = "ember_repo_index")
  saveRDS(idx, index_rds_path(key, cache))

  a <- cached_index(key, cache)
  b <- cached_index(key, cache)

  expect_true(identical(a, b))
})

test_that("cached_index doesn't answer for a cache that has no file, even if another cache does (07)", {
  key <- paste0("cran/test-", uuid())
  cacheA <- tempfile("cacheA-"); cacheB <- tempfile("cacheB-")
  dir.create(file.path(cacheA, "indexes"), recursive = TRUE)
  idxA <- structure(list(key = key, name = c("from-A")), class = "ember_repo_index")
  saveRDS(idxA, index_rds_path(key, cacheA))

  a <- cached_index(key, cacheA, url = "file:///repoA")
  expect_identical(a$name, "from-A")

  # Same key, a different cache with no file for it yet: the memo must not
  # hand back cache A's parsed index just because the key string matches.
  b <- cached_index(key, cacheB, url = "file:///repoB")
  expect_null(b)
  expect_false(file.exists(index_rds_path(key, cacheB)))
})

test_that("installer_command() doesn't perturb the server's own RNG state", {
  lock <- new_lock("dplyr", "1.1.4", "CRAN")
  cache <- tempfile("ember-cache-")
  set.seed(1)
  before <- .Random.seed
  installer_command(lock, c(CRAN = "https://example.invalid"),
                    file.path(cache, "libraries", "x"), cache = cache)
  expect_identical(.Random.seed, before)
})

# ---- Jobs (62, 63) ----------------------------------------------------------

test_that("two sessions asking for one index share one job and both get the event (62)", {
  key <- paste0("job-idx-", uuid())
  rscript <- file.path(R.home("bin"), "Rscript")
  cmd <- list(command = rscript,
             args = c("--vanilla", "-e", "cat('line\n'); flush(stdout())"),
             env = "current")
  nb1 <- fake_sub()
  nb2 <- fake_sub()
  done_of <- function(nb) Filter(function(e) identical(e$kind, "done"), nb$inbox)

  job_start(key, cmd, nb1, make_progress = function(line) NULL,
           make_done = function(status, output) list(kind = "done", status = status))
  expect_identical(length(ls(jobs, all.names = TRUE)), 1L)
  # Joining an already-running job: `cmd` is ignored for the second
  # subscriber, since only one subprocess may exist per key.
  job_start(key, cmd, nb2, make_progress = function(line) NULL,
           make_done = function(status, output) list(kind = "done", status = status))
  expect_identical(length(ls(jobs, all.names = TRUE)), 1L)

  ok <- poll_jobs_until(function() length(done_of(nb1)) > 0 && length(done_of(nb2)) > 0,
                        keys = key)

  expect_true(ok)
  expect_identical(done_of(nb1)[[1]]$status, 0L)
  expect_identical(done_of(nb2)[[1]]$status, 0L)
})

test_that("two installs with the same lock key but different library paths are separate jobs (07)", {
  # Two caches give the same lock the same `key` (library_for()'s key is a
  # hash of the lock text alone) but a different `path`. The shell keys the
  # install job table on `path`, not `key` (run_effect()'s "install" case,
  # shell.R), so these must not share one subprocess.
  lock <- new_lock("dplyr", "1.1.4", "CRAN")
  r <- list(minor = "4.6", platform = "testplat")
  infoA <- library_for(lock, r, tempfile("cacheA-"))
  infoB <- library_for(lock, r, tempfile("cacheB-"))
  expect_identical(infoA$key, infoB$key)
  expect_false(identical(infoA$path, infoB$path))

  rscript <- file.path(R.home("bin"), "Rscript")
  cmd <- list(command = rscript, args = c("--vanilla", "-e", "cat('line\n'); flush(stdout())"),
             env = "current")
  nbA <- fake_sub(); nbB <- fake_sub()
  job_start(infoA$path, cmd, nbA, make_progress = function(line) NULL,
           make_done = function(status, output) list(kind = "done"))
  job_start(infoB$path, cmd, nbB, make_progress = function(line) NULL,
           make_done = function(status, output) list(kind = "done"))
  expect_identical(length(ls(jobs, all.names = TRUE)), 2L)

  job_leave(infoA$path, nbA)
  job_leave(infoB$path, nbB)
})

test_that("job_leave by the last subscriber kills the process (63)", {
  key <- paste0("job-kill-", uuid())
  rscript <- file.path(R.home("bin"), "Rscript")
  cmd <- list(command = rscript, args = c("--vanilla", "-e", "Sys.sleep(30)"), env = "current")
  nb <- fake_sub()

  job_start(key, cmd, nb, make_progress = function(line) NULL,
           make_done = function(status, output) NULL)
  proc <- jobs[[key]]$proc
  expect_true(proc$is_alive())

  job_leave(key, nb)

  deadline <- Sys.time() + 5
  repeat {
    if (!isTRUE(tryCatch(proc$is_alive(), error = function(e) FALSE))) break
    if (Sys.time() >= deadline) break
    tryCatch(proc$poll_io(50), error = function(e) NULL)
  }
  expect_false(isTRUE(tryCatch(proc$is_alive(), error = function(e) FALSE)))
  expect_null(jobs[[key]])
})

# ---- clean() (64, 65, 66) ---------------------------------------------------

test_that("clean(dry_run = TRUE) lists libraries older than max_age and staging folders older than a day, and deletes nothing (64)", {
  root <- tempfile("ember-cache-")
  dir.create(root)
  old_lib <- make_fake_library(root, "oldkey", last_used_days_ago = 90)
  new_lib <- make_fake_library(root, "newkey", last_used_days_ago = 1)
  old_staging <- make_fake_staging(root, "stagingold", age_days = 2)
  new_staging <- make_fake_staging(root, "stagingnew", age_days = 0.1)

  out <- clean(max_age = 60, cache = FALSE, dry_run = TRUE, dir = root, now = Sys.time())

  expect_true(old_lib %in% out$path)
  expect_false(new_lib %in% out$path)
  expect_true(old_staging %in% out$path)
  expect_false(new_staging %in% out$path)
  expect_equal(out$kind[out$path == old_lib], "library")
  expect_equal(out$kind[out$path == old_staging], "staging")

  expect_true(dir.exists(old_lib))
  expect_true(dir.exists(new_lib))
  expect_true(dir.exists(old_staging))
  expect_true(dir.exists(new_staging))
})

test_that("clean() keeps libraries active in an open session even when old (65)", {
  root <- tempfile("ember-cache-")
  dir.create(root)
  old_lib <- make_fake_library(root, "activekey", last_used_days_ago = 90)
  set_active_libraries(old_lib)
  on.exit(set_active_libraries(character()), add = TRUE)

  out <- clean(max_age = 60, cache = FALSE, dry_run = FALSE, dir = root, now = Sys.time())

  expect_false(old_lib %in% out$path)
  expect_true(dir.exists(old_lib))
})

test_that("clean(cache = TRUE) deletes only cache entries no manifest lists (66)", {
  root <- tempfile("ember-cache-")
  dir.create(root)
  cache_root <- file.path(root, "renv-cache")
  used_entry <- file.path(cache_root, "v5", "os", "R-4.6", "triplet", "pkgA", "1.0", "hashA")
  unused_entry <- file.path(cache_root, "v5", "os", "R-4.6", "triplet", "pkgB", "2.0", "hashB")
  dir.create(file.path(used_entry, "pkgA"), recursive = TRUE)
  dir.create(file.path(unused_entry, "pkgB"), recursive = TRUE)
  writeLines("x", file.path(used_entry, "pkgA", "DESCRIPTION"))
  writeLines("x", file.path(unused_entry, "pkgB", "DESCRIPTION"))

  make_fake_library(root, "key1", last_used_days_ago = 1, cache_entries = used_entry)

  out <- clean(max_age = 60, cache = TRUE, dry_run = FALSE, dir = root, now = Sys.time())

  expect_true(unused_entry %in% out$path)
  expect_false(used_entry %in% out$path)
  expect_false(dir.exists(unused_entry))
  expect_true(dir.exists(used_entry))
})
