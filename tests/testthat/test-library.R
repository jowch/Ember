# Disk and jobs (R/library.R): library manifests, the index memo, the
# process-wide job table and `clean()`. No notebook and no worker: these
# are plain functions over the filesystem and over `processx` handles, so
# they're driven directly rather than through `drive()` or a session.
#
# Covers packages-tests.md items 59-66 ("Disk and jobs").

test_that("cache_dir() normalizes ember.cache_dir, even before the folder exists (review: dep_path_allowed() false refusal)", {
  # dep_path_allowed() (R/server.R, R/export.R) compares a dependency's
  # resolved dir (normalizePath()d in inst/worker.R's dep_to_wire(), once
  # the dependency's files really exist) against this root with a plain
  # string prefix check. On macOS, tempfile()'s default root is under
  # "/var" (a symlink to "/private/var"), so an un-normalized cache_dir()
  # and an already-normalized dependency dir can name the same directory
  # with two different spellings and fail that prefix check even though
  # the dependency really is inside the library -- and plain
  # normalizePath(path, mustWork = FALSE) does no symlink resolution at all
  # when "path" itself doesn't exist yet (the common case: cache_dir() is
  # called before any library under it has been created).
  not_yet_created <- tempfile("ember-cache-dir-test-")
  expect_false(file.exists(not_yet_created))
  old <- options(ember.cache_dir = not_yet_created)
  on.exit(options(old), add = TRUE)

  resolved_parent <- normalizePath(dirname(not_yet_created), mustWork = TRUE)
  expect_identical(cache_dir(), file.path(resolved_parent, basename(not_yet_created)))
})

test_that("normalize_existing_prefix() resolves an existing path outright and leaves a nonexistent tail as given", {
  expect_identical(normalize_existing_prefix(tempdir()), normalizePath(tempdir(), mustWork = FALSE))

  nested <- file.path(tempdir(), "a-review-test-dir", "b", "c")
  expect_false(file.exists(nested))
  resolved <- normalize_existing_prefix(nested)
  expect_identical(basename(resolved), "c")
  expect_identical(basename(dirname(resolved)), "b")
})

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
  # load_all() sets DEVTOOLS_LOAD while it loads ember's imports, and renv's
  # .onLoad then deletes and rebuilds renv.so inside the installed renv
  # package. Two children doing that at once can find it missing, and the
  # load fails with "The package renv is required". RENV_EXT_ENABLED=FALSE
  # skips the rebuild; renv falls back to its R implementations.
  procs <- lapply(stagings, function(st) {
    processx::process$new(rscript, c("--vanilla", "-e", race_code(st)),
                          env = c("current", RENV_EXT_ENABLED = "FALSE"),
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

test_that("an index dated yesterday or later in UTC may still change, and an older one or a GitHub key doesn't (#39)", {
  now <- as.POSIXct("2026-10-16 01:30:00", tz = "UTC")
  expect_true(index_may_change("cran/2026-10-16", now))
  expect_true(index_may_change("cran/2026-10-15", now))
  expect_true(index_may_change("cran/2026-10-17", now))   # a clock east of UTC
  expect_true(index_may_change("bioc-ann/2026-10-16/3.23", now))
  expect_false(index_may_change("cran/2026-10-14", now))
  expect_false(index_may_change("bioc/2026-09-01/3.23", now))
  expect_false(index_may_change("github/lab/toyC@main", now))
  # The day is UTC's, whatever the local zone says: 20:00 on the 16th in
  # Los Angeles is the 17th in UTC, so the 15th is two days back.
  expect_false(index_may_change("cran/2026-10-15", as.POSIXct("2026-10-16 20:00:00", tz = "America/Los_Angeles")))
})

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

#' A job command that starts a grandchild (`sleep`, in the job's process
#' group, as `R CMD INSTALL` is for an install), prints its pid, and waits.
grandchild_cmd <- function() {
  list(command = file.path(R.home("bin"), "Rscript"),
       args = c("--vanilla", "-e", "system('sleep 300 & echo $!'); Sys.sleep(300)"),
       env = "current")
}

test_that("job_leave by the last subscriber kills the job's children too (#141)", {
  skip_on_os("windows")
  key <- paste0("job-kill-tree-", uuid())
  nb <- fake_sub()
  job_start(key, grandchild_cmd(), nb, make_progress = function(line) NULL,
           make_done = function(status, output) NULL)
  proc <- jobs[[key]]$proc
  proc$poll_io(30000)
  pid <- as.integer(proc$read_output_lines()[1])
  expect_true(pid_running(pid))

  job_leave(key, nb)

  expect_true(wait_pid_gone(pid))
})

test_that("a job and its children end when the server that started it is killed (#141)", {
  skip_on_os("windows")
  use_installed_ember()
  cmd <- grandchild_cmd()
  code <- paste0(
    "library(ember); cmd <- ", paste(deparse(cmd), collapse = " "), "; ",
    "ember:::job_start('k', cmd, new.env(), function(line) NULL, function(status, output) NULL); ",
    "p <- ember:::jobs[['k']]$proc; invisible(p$poll_io(30000)); ",
    "cat(p$get_pid(), p$read_output_lines()[1], '\\n'); flush(stdout()); Sys.sleep(300)")
  server <- processx::process$new(file.path(R.home("bin"), "Rscript"), c("--vanilla", "-e", code),
                                  env = c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)),
                                  stdout = "|", stderr = "2>&1")
  on.exit(if (server$is_alive()) server$kill(), add = TRUE)
  line <- character()
  while (length(line) == 0 && server$is_alive()) {
    server$poll_io(30000)
    line <- server$read_output_lines()
  }
  pids <- as.integer(strsplit(trimws(line[1]), " +")[[1]])
  expect_length(pids, 2)
  expect_true(all(vapply(pids, pid_running, logical(1))))

  # SIGKILL: no handler, no finalizer, nothing in the server runs.
  server$kill()

  expect_true(wait_pid_gone(pids[1]))  # the job
  expect_true(wait_pid_gone(pids[2]))  # its child
})

# ---- poll_jobs(): no inserted newline, failure lines survive the cap -------

#' A minimal stand-in for a `processx::process` handle, giving `poll_jobs()`
#' exactly the four calls it makes (`is_alive`, `read_output`,
#' `get_exit_status`, `read_all_output`) with results fixed ahead of time,
#' rather than depending on a real subprocess's timing to split output
#' across polls just right.
fake_job_proc <- function(chunks, exit_status = 1L, final_chunk = "") {
  i <- 0L
  self <- new.env(parent = emptyenv())
  self$is_alive <- function() i < length(chunks)
  self$read_output <- function() {
    i <<- i + 1L
    chunks[[i]]
  }
  self$get_exit_status <- function() exit_status
  self$read_all_output <- function() final_chunk
  self
}

#' Register `proc` directly in the job table under `key`, as `job_start()`
#' would once its subprocess exists, without actually spawning one.
fake_job <- function(key, proc, nb) {
  job <- new.env(parent = emptyenv())
  job$proc <- proc
  job$buf <- ""
  job$lines <- character()
  job$subs <- list(list(nb = nb, make_progress = function(line) NULL,
                        make_done = function(status, output) list(kind = "done", status = status, output = output)))
  assign(key, job, envir = jobs)
}

test_that("poll_jobs() doesn't insert a newline between buf and the final read: a line split across them stays one line", {
  key <- paste0("job-split-", uuid())
  # Never ends in "\n": by the time `!alive`, the whole line is still
  # unterminated, split across one `read_output()` (into `job$buf`) and
  # the final `read_all_output()` (`rest`) -- exactly the case a `paste()`
  # with `collapse = "\n"` over `c(job$lines, job$buf, rest)` used to
  # break, turning one line into two and hiding it from any pattern
  # anchored on a whole line (`install_failures()`'s `^ERROR: ...`).
  proc <- fake_job_proc(list("ERROR: compilation fail"), final_chunk = "ed for package 'x'")
  nb <- fake_sub()
  fake_job(key, proc, nb)

  poll_jobs(NULL)
  done <- Filter(function(e) identical(e$kind, "done"), nb$inbox)
  expect_length(done, 1)
  expect_equal(done[[1]]$output, "ERROR: compilation failed for package 'x'")
  expect_null(jobs[[key]])
})

test_that("poll_jobs(): a line matching the failure patterns survives the 400-line cap", {
  key <- paste0("job-cap-", uuid())
  failure_line <- "ERROR: compilation failed for package 'x'"
  noise <- paste0("noise line ", seq_len(500))
  chunk <- paste0(c(failure_line, noise), "\n", collapse = "")
  proc <- fake_job_proc(list(chunk, ""), final_chunk = "")
  nb <- fake_sub()
  fake_job(key, proc, nb)

  poll_jobs(NULL)  # reads the chunk: 501 complete lines, over the 400 cap
  job <- jobs[[key]]
  expect_true(failure_line %in% job$lines, info = "kept past the cap, not just the most recent 400")
  expect_true(length(job$lines) < 501, info = "still bounded, not literally unlimited")

  poll_jobs(NULL)  # process no longer alive: done fires
  done <- Filter(function(e) identical(e$kind, "done"), nb$inbox)
  expect_length(done, 1)
  expect_true(grepl(failure_line, done[[1]]$output, fixed = TRUE))
})

# ---- disk_use() (#38) -------------------------------------------------------

#' A cache dir with a 200 KB cache entry hard-linked into a library, a
#' 100 KB file of the library's own and a 50 KB index.
make_disk_use_cache <- function() {
  root <- tempfile("ember-cache-")
  dir.create(root)
  lib <- make_fake_library(root, "dukey")
  entry <- file.path(root, "renv-cache", "v5", "R-4.6", "testplat", "pkg", "1.0", "abc", "pkg")
  dir.create(entry, recursive = TRUE)
  writeBin(as.raw(rep(1L, 200000)), file.path(entry, "big"))
  linked <- file.link(file.path(entry, "big"), file.path(lib, "big"))
  writeBin(as.raw(rep(2L, 100000)), file.path(lib, "own"))
  dir.create(file.path(root, "indexes"))
  writeBin(as.raw(rep(3L, 50000)), file.path(root, "indexes", "cran-2026-09-01.rds"))
  list(root = root, linked = linked)
}

test_that("disk_use() counts a file hard-linked from the cache into a library once, in the cache (#38)", {
  skip_if(!nzchar(Sys.which("du")), "no du on this system")
  d <- make_disk_use_cache()
  on.exit(unlink(d$root, recursive = TRUE))
  skip_if_not(d$linked, "this file system has no hard links")
  use <- disk_use(d$root)
  expect_named(use, c("libraries", "cache", "indexes", "exact"))
  expect_true(use$exact)
  expect_gte(use$cache, 200000)
  expect_gte(use$libraries, 100000)
  expect_lt(use$libraries, 200000)  # its own file only; the linked one is the cache's
  expect_gte(use$indexes, 50000)
  expect_lt(use$indexes, 100000)
})

test_that("disk_use() without du sums file sizes, which counts a linked file twice, and says so (#38)", {
  d <- make_disk_use_cache()
  on.exit(unlink(d$root, recursive = TRUE))
  use <- disk_use(d$root, du = "")
  expect_false(use$exact)
  expect_gte(use$cache, 200000)
  expect_gte(use$libraries, if (d$linked) 300000 else 100000)
  expect_gte(use$indexes, 50000)
})

test_that("disk_use() of a cache dir with nothing in it is all zero (#38)", {
  root <- tempfile("ember-cache-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  use <- disk_use(root)
  expect_equal(c(use$libraries, use$cache, use$indexes), c(0, 0, 0))
  use2 <- disk_use(file.path(root, "missing"))
  expect_equal(c(use2$libraries, use2$cache, use2$indexes), c(0, 0, 0))
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
  Sys.setFileTime(c(used_entry, unused_entry), Sys.time() - 7 * 86400)

  make_fake_library(root, "key1", last_used_days_ago = 1, cache_entries = used_entry)

  out <- clean(max_age = 60, cache = TRUE, dry_run = FALSE, dir = root, now = Sys.time())

  expect_true(unused_entry %in% out$path)
  expect_false(used_entry %in% out$path)
  expect_false(dir.exists(unused_entry))
  expect_true(dir.exists(used_entry))
})

# ---- clean_up(): the Packages tab's clean-up button (#128) --------------------

# A cache dir with two cache entries, each 100 KB: `kept` is listed by an
# open notebook's library, `stale` by a library last used 40 days ago.
# A third library, used 10 days ago, lists nothing.
make_clean_up_cache <- function() {
  root <- tempfile("ember-cache-")
  dir.create(root)
  entry <- function(pkg) {
    e <- file.path(root, "renv-cache", "v5", "os", "R-4.6", "triplet", pkg, "1.0", paste0("hash", pkg))
    dir.create(file.path(e, pkg), recursive = TRUE)
    writeBin(raw(100000), file.path(e, pkg, "R.rdb"))
    # Older than the day clean() gives a new entry (an install in flight).
    Sys.setFileTime(e, Sys.time() - 7 * 86400)
    e
  }
  kept <- entry("pkgKept"); stale <- entry("pkgStale")
  list(root = root, kept_entry = kept, stale_entry = stale,
       open_lib = make_fake_library(root, "openkey", last_used_days_ago = 90, cache_entries = kept),
       stale_lib = make_fake_library(root, "stalekey", last_used_days_ago = 40, cache_entries = stale),
       recent_lib = make_fake_library(root, "recentkey", last_used_days_ago = 10))
}

test_that("clean_up(dry_run = TRUE) counts what it would delete and deletes nothing (#128)", {
  d <- make_clean_up_cache()
  on.exit(unlink(d$root, recursive = TRUE))
  plan <- clean_up(d$root, keep = d$open_lib, dry_run = TRUE)
  expect_equal(plan$libraries, 1)
  expect_equal(plan$cache, 1)
  expect_gte(plan$bytes, 100000)
  expect_lt(plan$bytes, 200000)
  expect_true(all(dir.exists(c(d$open_lib, d$stale_lib, d$recent_lib, d$kept_entry, d$stale_entry))))
})

test_that("clean_up() deletes libraries no open notebook holds and unused for 30 days, then the cache entries only they listed (#128)", {
  d <- make_clean_up_cache()
  on.exit(unlink(d$root, recursive = TRUE))
  done <- clean_up(d$root, keep = d$open_lib, dry_run = FALSE)
  expect_equal(c(done$libraries, done$cache), c(1, 1))
  expect_false(dir.exists(d$stale_lib))
  expect_false(dir.exists(d$stale_entry))
  # The open notebook's library is kept however old, and so is its cache entry.
  expect_true(dir.exists(d$open_lib))
  expect_true(dir.exists(d$kept_entry))
  # A library used in the last 30 days may belong to a notebook open in
  # another Ember process, which this one can't see.
  expect_true(dir.exists(d$recent_lib))
})

test_that("clean_up() leaves the indexes to the startup sweep (#128)", {
  d <- make_clean_up_cache()
  on.exit(unlink(d$root, recursive = TRUE))
  dir.create(file.path(d$root, "indexes"))
  idx <- file.path(d$root, "indexes", "old.rds")
  saveRDS(1, idx)
  Sys.setFileTime(idx, Sys.time() - 90 * 86400)
  clean_up(d$root, keep = d$open_lib, dry_run = FALSE)
  expect_true(file.exists(idx))
})

test_that("clean_up() without du estimates bytes from file sizes (#128)", {
  d <- make_clean_up_cache()
  on.exit(unlink(d$root, recursive = TRUE))
  plan <- clean_up(d$root, keep = d$open_lib, dry_run = TRUE, du = "")
  expect_gte(plan$bytes, 100000)
})

test_that("clean_up_command() runs clean_up() in a subprocess and prints JSON (#128)", {
  use_installed_ember()
  d <- make_clean_up_cache()
  on.exit(unlink(d$root, recursive = TRUE))
  cmd <- clean_up_command(d$root, keep = d$open_lib, dry_run = TRUE)
  res <- processx::run(cmd$command, cmd$args, env = cmd$env, error_on_status = FALSE)
  expect_identical(res$status, 0L)
  out <- jsonlite::fromJSON(res$stdout)
  expect_equal(c(out$libraries, out$cache), c(1, 1))
  expect_true(dir.exists(d$stale_lib))
  # `now` reaches the subprocess: judged 15 days ago, nothing is old enough.
  cmd <- clean_up_command(d$root, keep = d$open_lib, dry_run = TRUE,
                          now = as.numeric(Sys.time()) - 15 * 86400)
  res <- processx::run(cmd$command, cmd$args, env = cmd$env, error_on_status = FALSE)
  expect_identical(res$status, 0L)
  expect_equal(jsonlite::fromJSON(res$stdout)$libraries, 0)
})

test_that("the library heartbeat keeps open sessions' markers fresh, and stops with no session open (#128)", {
  root <- tempfile("ember-cache-")
  on.exit(unlink(root, recursive = TRUE))
  lib <- make_fake_library(root, "openkey", last_used_days_ago = 40)
  old <- active_libraries$paths
  on.exit(set_active_libraries(old), add = TRUE)
  set_active_libraries(lib)
  touch_active_libraries()
  marker <- file.path(lib, "ember-last-used")
  expect_lt(as.numeric(difftime(Sys.time(), file.info(marker)$mtime, units = "mins")), 5)
  # A clean-up in another process now sees it as used.
  expect_equal(clean_up(root, dry_run = TRUE)$libraries, 0)

  # Sessions earlier test files left open would keep it going; set them
  # aside for this check.
  ids <- ls(open_sessions, all.names = TRUE)
  saved <- mget(ids, envir = open_sessions)
  rm(list = ids, envir = open_sessions)
  on.exit(list2env(saved, envir = open_sessions), add = TRUE)
  was <- library_heartbeat$scheduled
  on.exit(library_heartbeat$scheduled <- was, add = TRUE)
  library_heartbeat$scheduled <- TRUE
  heartbeat_tick()
  expect_false(library_heartbeat$scheduled)
})

test_that("a lock entry renv skipped because R already has that version is copied into the library", {
  fake_pkg <- function(lib, pkg, version) {
    dir.create(file.path(lib, pkg), recursive = TRUE)
    writeLines(c(paste("Package:", pkg), paste("Version:", version)),
               file.path(lib, pkg, "DESCRIPTION"))
  }
  staging <- tempfile("ember-staging-")
  system_lib <- tempfile("ember-system-lib-")
  on.exit(unlink(c(staging, system_lib), recursive = TRUE), add = TRUE)
  fake_pkg(staging, "toyA", "0.1")
  fake_pkg(system_lib, "codetools", "0.2-20")
  fake_pkg(system_lib, "lattice", "0.22-6")

  wanted <- c(toyA = "0.1", codetools = "0.2-20", lattice = "0.22-7")
  copied <- copy_from_r_library(staging, wanted, lib_paths = c(staging, system_lib))

  expect_equal(copied, "codetools")
  expect_true(file.exists(file.path(staging, "codetools", "DESCRIPTION")))
  # A different version is renv's to install, not ours to copy.
  expect_false(dir.exists(file.path(staging, "lattice")))
})

# ---- Bioconductor's release list ---------------------------------------------

bioc_config_url <- function(name = "config.yaml") {
  paste0("file://", normalizePath(testthat::test_path("fixtures", "bioc-config", name)))
}

test_that("the release-list job fetches, parses and caches bioconductor.org's config.yaml", {
  use_installed_ember()
  cache <- tempfile("ember-bioc-config-test-"); dir.create(cache)
  url <- bioc_config_url("config-3.24.yaml")
  expect_null(cached_bioc_config(url, cache))
  cmd <- bioc_config_fetch_command(url, cache)
  out <- processx::run(cmd$command, cmd$args, env = cmd$env, error_on_status = FALSE)
  expect_identical(out$status, 0L)
  hit <- cached_bioc_config(url, cache)
  expect_equal(tail(hit$table$version, 1), "3.24")
  expect_equal(fetched_day(hit), Sys.Date())
  # Another URL is another cache entry.
  expect_null(cached_bioc_config(bioc_config_url(), cache))
})

test_that("a cached release list is used for a day; an older one only as a fallback", {
  cache <- tempfile("ember-bioc-config-test-"); dir.create(cache)
  url <- bioc_config_url()
  fetch_bioc_config_main(url, bioc_config_rds_path(url, cache))
  expect_false(is.null(cached_bioc_config(url, cache)))
  path <- bioc_config_rds_path(url, cache)
  old <- readRDS(path)
  old$fetched_at <- Sys.time() - 2 * bioc_config_max_age
  saveRDS(old, path)
  expect_null(cached_bioc_config(url, cache))
  expect_equal(cached_bioc_config(url, cache, max_age = Inf)$table, old$table)
})

test_that("a release-list fetch fails on a missing file and on a file with no releases in it", {
  cache <- tempfile("ember-bioc-config-test-"); dir.create(cache)
  missing <- paste0("file://", file.path(cache, "nope.yaml"))
  expect_error(fetch_bioc_config_main(missing, bioc_config_rds_path(missing, cache)),
               "could not fetch Bioconductor's release list")
  other <- paste0("file://", normalizePath(testthat::test_path("fixtures", "repos", "cran", "2026-09-01",
                                                               "src", "contrib", "PACKAGES")))
  expect_error(fetch_bioc_config_main(other, bioc_config_rds_path(other, cache)),
               "no Bioconductor releases found")
  expect_false(file.exists(bioc_config_rds_path(other, cache)))
})

test_that("clean_up() keeps the cache entries an install in progress links to (#128)", {
  skip_on_os("windows")  # symlinks
  d <- make_clean_up_cache()
  on.exit(unlink(d$root, recursive = TRUE))
  # A staging folder younger than a day has no manifest yet; its package
  # is a symlink into an old cache entry no library lists.
  linked <- file.path(d$root, "renv-cache", "v5", "os", "R-4.6", "triplet", "pkgLinked", "1.0", "hashLinked")
  dir.create(file.path(linked, "pkgLinked"), recursive = TRUE)
  Sys.setFileTime(linked, Sys.time() - 7 * 86400)
  staging <- make_fake_staging(d$root, "newkey", age_days = 0)
  file.symlink(file.path(linked, "pkgLinked"), file.path(staging, "pkgLinked"))
  # And a cache entry made just now, which renv fills before it links.
  fresh <- file.path(d$root, "renv-cache", "v5", "os", "R-4.6", "triplet", "pkgFresh", "1.0", "hashFresh")
  dir.create(file.path(fresh, "pkgFresh"), recursive = TRUE)

  done <- clean_up(d$root, keep = d$open_lib, dry_run = FALSE)
  expect_equal(c(done$libraries, done$cache), c(1, 1))
  expect_true(dir.exists(linked))
  expect_true(file.exists(file.path(staging, "pkgLinked")))
  expect_true(dir.exists(fresh))
  expect_true(dir.exists(staging))
  expect_false(dir.exists(d$stale_entry))
})

test_that("clean_up() judged at an earlier time keeps a library that aged since (#128)", {
  d <- make_clean_up_cache()
  on.exit(unlink(d$root, recursive = TRUE))
  # stale_lib was last used 40 days ago; judged as of 15 days ago it was
  # used 25 days before, so it stays, and so does its entry.
  done <- clean_up(d$root, keep = d$open_lib, dry_run = FALSE, now = Sys.time() - 15 * 86400)
  expect_equal(done$libraries, 0)
  expect_true(dir.exists(d$stale_lib))
  expect_true(dir.exists(d$stale_entry))
})

test_that("clean_up() through a symlinked cache dir keeps an open library's own entry (#128)", {
  skip_on_os("windows")  # symlinks
  d <- make_clean_up_cache()
  on.exit(unlink(d$root, recursive = TRUE))
  # The open library lists its entry by the resolved path, as
  # library_cache_entries() records a symlink's target; the cache dir is
  # reached through a symlink (macOS's /var -> /private/var).
  m <- readRDS(file.path(d$open_lib, "ember-library.rds"))
  m$cache_entries <- normalizePath(d$kept_entry)
  saveRDS(m, file.path(d$open_lib, "ember-library.rds"))
  link <- tempfile("ember-cache-link-")
  file.symlink(d$root, link)
  on.exit(unlink(link), add = TRUE)

  done <- clean_up(link, keep = d$open_lib, dry_run = FALSE)
  expect_equal(c(done$libraries, done$cache), c(1, 1))
  expect_true(dir.exists(d$open_lib))
  expect_true(dir.exists(d$kept_entry))
  expect_false(dir.exists(d$stale_entry))
  # keep spelled through the link matches too.
  d2 <- make_clean_up_cache()
  on.exit(unlink(d2$root, recursive = TRUE), add = TRUE)
  link2 <- tempfile("ember-cache-link-")
  file.symlink(d2$root, link2)
  on.exit(unlink(link2), add = TRUE)
  open_via_link <- file.path(link2, substring(d2$open_lib, nchar(d2$root) + 2))
  clean_up(d2$root, keep = open_via_link, dry_run = FALSE)
  expect_true(dir.exists(d2$open_lib))
})

