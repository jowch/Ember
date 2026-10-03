# The shared things on disk: the index cache, the libraries, renv's cache,
# cleanup. Plain functions over the filesystem, called by the shell (to
# carry out effects), by `ember::run()` and by `ember::clean()`.
#
# Layout under `cache_dir()` = tools::R_user_dir("ember", "cache"):
#
#   indexes/<repo key with "/" -> "_">.rds   parsed `ember_repo_index`
#   libraries/R-4.6/<platform>/<key>/        one library per lock
#       <pkg>/...                            links into renv-cache
#       ember-library.rds                    the manifest; written last
#       ember-last-used                      touched when a worker starts
#   libraries/R-4.6/<platform>/<key>.staging-<pid>-<rand>/   in progress
#   renv-cache/                              RENV_PATHS_CACHE
#   renv-root/                               RENV_PATHS_ROOT (sandbox etc.)
#
# Ember's own renv cache, not the user's: `ember::clean()` deletes cache
# entries no Ember library uses, which must never touch the user's own renv
# projects.
#
# Concurrency (several sessions, several R processes, one cache): nothing
# here takes a lock. Every write goes to a private temporary name and is
# renamed into place; a rename that finds the target already there means
# another process finished the same work, so the loser deletes its copy.
# Both outcomes are the same library (per make-operations-idempotent).
# renv's own cache writes use renv's locking.

#' `path` with its nearest existing ancestor resolved by `normalizePath()`
#' and the rest (components that don't exist yet) reattached as given.
#' Plain `normalizePath(path, mustWork = FALSE)` on a path that doesn't
#' exist yet does no symlink resolution at all on most platforms/R
#' versions, even when a real symlink sits earlier in the path (macOS's
#' `/var` -> `/private/var`, under which `tempfile()`'s default root
#' lives) -- it falls back to a plain string cleanup once it can't `stat()`
#' the full path. Walking up to the first ancestor that does exist and
#' resolving only that gets the same canonical spelling `normalizePath()`
#' would give once the rest of `path` exists too.
normalize_existing_prefix <- function(path) {
  if (file.exists(path)) return(normalizePath(path, mustWork = FALSE))
  parent <- dirname(path)
  if (identical(parent, path)) return(path)   # reached the filesystem root
  file.path(normalize_existing_prefix(parent), basename(path))
}

#' @export
cache_dir <- function() {
  raw <- getOption("ember.cache_dir", tools::R_user_dir("ember", "cache"))
  # normalize_existing_prefix(), not the raw value: a path built from this
  # root (every library_for() path, every test's cache_dir override,
  # setup-cache.R) and a path normalizePath() has already resolved
  # elsewhere (dep_to_wire(), inst/worker.R, once the dependency's files
  # really exist) have to spell the exact same directory the same way, or
  # dep_path_allowed()'s plain string prefix check (R/server.R,
  # R/export.R) falsely refuses a dependency that really is inside the
  # library -- which happens on macOS specifically, since `tempfile()`'s
  # default root is under "/var" (a symlink to "/private/var"). This
  # doesn't touch dep_path_allowed()'s own, deliberate non-resolution of a
  # symlink *inside* the library (renv's shared cache): only this one root
  # is normalized, once, here.
  normalize_existing_prefix(raw)
}

#' What the session needs to know about the running R:
#' `list(version = "4.6.1", minor = "4.6", platform = R.version$platform)`.
#' Read once by `open_notebook()` and passed into the core.
r_info <- function() {
  list(version = as.character(getRversion()),
       minor = paste(R.version$major, strsplit(R.version$minor, ".", fixed = TRUE)[[1]][1],
                     sep = "."),
       platform = R.version$platform)
}

# ---- Indexes -----------------------------------------------------------------

#' The path an index for `key` is cached at: `key`'s `/` turned to `_`, so
#' `"cran/2026-09-01"` is a single filename component.
index_rds_path <- function(key, cache = cache_dir()) {
  file.path(cache, "indexes", paste0(gsub("/", "_", key, fixed = TRUE), ".rds"))
}

#' The label a dated repo key resolves to (`read_repo_index()`'s `label`,
#' and the lock's `source` field): the kind before the first `/`, mapped to
#' its lock spelling. Unknown kinds (a future `[sources]` key) pass through
#' unchanged, so a one-row GitHub index can use its own source string as
#' its own label with no special case here.
index_label_of_key <- function(key) {
  kind <- strsplit(key, "/", fixed = TRUE)[[1]][1]
  switch(kind, cran = "CRAN", bioc = "Bioc", kind)
}

#' The parsed index for `key`, or `NULL` when it isn't on disk yet.
#' Memoised per process in `index_memo` (an environment), so every session
#' gets the same R object for one key. Called by the shell on
#' `fx_fetch_index` before it starts a download: a cached index arrives in
#' the same drain, with no subprocess.
#'
#' The memo is keyed by `url` and `cache` as well as `key`: `key` alone
#' (a date string like `"cran/2026-09-01"`) is shared by any repository that
#' happens to resolve that date, and by any cache directory a test or
#' another Ember process points at. Keying the memo by `key` alone meant
#' one session's fetch from one repository, into one cache, could hand its
#' parsed index to another session reading a *different* cache (or a
#' different repository) for the same key, before that other cache ever had
#' a file on disk -- the memo answered for a read that should have missed.
cached_index <- function(key, cache = cache_dir(), url = NULL) {
  memo_key <- paste(key, url %||% "", cache, sep = "\u0001")
  hit <- index_memo[[memo_key]]
  if (!is.null(hit)) return(hit)
  path <- index_rds_path(key, cache)
  if (!file.exists(path)) return(NULL)
  idx <- tryCatch(readRDS(path), error = function(e) NULL)
  if (!is.null(idx)) index_memo[[memo_key]] <- idx
  idx
}
index_memo <- new.env(parent = emptyenv())

#' Run in the index-fetch subprocess (`index_fetch_command()`'s `-e`,
#' with `library(ember)` already loaded, as the installer is): download
#' `<url>/src/contrib/PACKAGES.gz`, falling back to the uncompressed
#' `PACKAGES` (the toy fixtures ship only the latter), parse it with
#' `read_repo_index()` and save the RDS at a temporary name, then rename
#' into place. A rename that loses the race to another process fetching
#' the same key is a no-op: the two parses are `identical()` in content,
#' and `cached_index()`'s memo only cares that a file exists at `path`.
fetch_index_main <- function(key, url, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  base <- paste0(sub("/+$", "", url), "/src/contrib/")
  tmp_pkgs <- tempfile("ember-packages-")
  ok <- FALSE
  for (name in c("PACKAGES.gz", "PACKAGES")) {
    ok <- isTRUE(tryCatch({
      utils::download.file(paste0(base, name), tmp_pkgs, quiet = TRUE, mode = "wb")
      TRUE
    }, error = function(e) FALSE, warning = function(w) FALSE))
    if (ok) break
  }
  if (!ok) stop("ember: could not fetch the index for ", key, " from ", url, call. = FALSE)

  idx <- read_repo_index(tmp_pkgs, key, index_label_of_key(key))
  tmp_rds <- paste0(path, ".tmp-", Sys.getpid())
  saveRDS(idx, tmp_rds)
  if (!file.rename(tmp_rds, path)) unlink(tmp_rds)
  invisible(NULL)
}

#' The command that downloads and parses the index for `key`, as a job
#' (see Jobs). `url` may be `file://`: the test seam. Runs the same way
#' the worker is booted (shell.R's `start_worker_process()`): an inline
#' `Rscript -e` that loads the installed `ember` and calls one internal
#' function, so there is no separate top-level script to keep in sync with
#' the function it calls.
index_fetch_command <- function(key, url, cache = cache_dir()) {
  path <- index_rds_path(key, cache)
  rscript <- file.path(R.home("bin"), "Rscript")
  code <- paste0(
    "local({library(ember); ember:::fetch_index_main(",
    deparse(key), ", ", deparse(url), ", ", deparse(path), ")})")
  # The server's own library path, as for the installer, so the child finds
  # the same Ember the server runs.
  env <- c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep),
           R_LIBS_USER = "", R_LIBS_SITE = "")
  list(command = rscript, args = c("--vanilla", "-e", code), env = env)
}

# ---- Libraries ---------------------------------------------------------------

#' The manifest of a ready library, or `NULL` when there is no complete
#' library at `path` (no folder, or a folder without a manifest).
#'
#' Manifest: `list(lock_lines, r, installed = name -> version,
#' exports = name -> character, cache_entries = character (renv cache
#' paths the library links to), created)`.
#' One `readRDS()`: fast enough for the server thread.
read_library_manifest <- function(path) {
  manifest_path <- file.path(path, "ember-library.rds")
  if (!file.exists(manifest_path)) return(NULL)
  tryCatch(readRDS(manifest_path), error = function(e) NULL)
}

#' Record that a library was used now. The shell calls it when it starts a
#' worker on `path` and when it reads the manifest. Cleanup reads it.
touch_library <- function(path) {
  if (!dir.exists(path)) return(invisible(NULL))
  marker <- file.path(path, "ember-last-used")
  tryCatch(suppressWarnings({
    if (!file.exists(marker)) file.create(marker)
    Sys.setFileTime(marker, Sys.time())
  }), error = function(e) NULL)
  invisible(NULL)
}

#' The script `installer_command()` runs. An option, not an environment
#' variable, because the choice is made here, in the parent process, while
#' building the command, not re-read inside the child (unlike `EMBER_WORKER`,
#' which the worker's own boot line reads). Tests point it at
#' `inst/fake-installer.R` (a fake installer: an empty library with a
#' valid manifest, no renv) so core and shell tests never run renv.
installer_script <- function() {
  getOption("ember.installer_script", system.file("installer.R", package = "ember"))
}

#' The command for the installer subprocess (inst/installer.R):
#' `list(command = <Rscript>, args, env)`.
#'
#' * Runs with the server's own library (`R_LIBS` = the server's
#'   `.libPaths()`), which is where renv is: renv is an Imports of ember, so
#'   it is installed with ember and never enters a notebook's library.
#' * `env`: `RENV_PATHS_CACHE`, `RENV_PATHS_ROOT` under `cache`,
#'   `RENV_CONFIG_PPM_ENABLED = TRUE` (renv rewrites a PPM URL to its Linux
#'   binary form), `MAKEFLAGS = -j2` (increment 2 chooses a real core
#'   count; increment 1's fixtures need no compiler at all).
#' * Input: a plan file (RDS) with the lock lines, the repo URLs, R info,
#'   the staging and final paths.
#' The installer restores into the staging folder, writes the manifest
#' (computing exports: see the script), then renames staging to `path`.
#'
#' `r` isn't a parameter: it is always this process's own `r_info()`,
#' since whoever calls `installer_command()` is running on the R the
#' library must match.
installer_command <- function(lock, repos, path, cache = cache_dir()) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  # `tempfile()`'s own unique suffix, not `sample()`: this runs in the
  # server process, and `sample()` would perturb its `.Random.seed` on
  # every install, which could silently change the next random draw a
  # running cell makes (randomness must depend only on the user's own
  # `set.seed()`, never on unrelated server bookkeeping). `tempfile()`
  # generates its uniqueness from the process id and a session-specific
  # counter, not from R's own RNG (confirmed: it leaves `.Random.seed`
  # untouched).
  staging <- paste0(path, ".staging-", Sys.getpid(), "-", basename(tempfile()))
  plan <- list(lock_lines = format_lock_lines(lock), repos = repos, r = r_info(),
              staging = staging, path = path, cache = cache)
  plan_path <- tempfile("ember-install-plan-", fileext = ".rds")
  saveRDS(plan, plan_path)

  rscript <- file.path(R.home("bin"), "Rscript")
  env <- c("current",
          R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep),
          R_LIBS_USER = "", R_LIBS_SITE = "",
          RENV_PATHS_CACHE = file.path(cache, "renv-cache"),
          RENV_PATHS_ROOT = file.path(cache, "renv-root"),
          RENV_CONFIG_PPM_ENABLED = "TRUE",
          MAKEFLAGS = "-j2")
  list(command = rscript, args = c("--vanilla", installer_script(), plan_path), env = env)
}

#' Install a library and wait: for `ember::run()`, which runs outside any
#' session and may block. The same installer, the same staging and rename,
#' so a library built here and one built by a session are the same.
#' Returns `path`, or stops with the installer's message and last lines.
ensure_library <- function(lock, repos, r = r_info(), cache = cache_dir(),
                           echo = TRUE) {
  info <- library_for(lock, r, cache)
  if (!is.null(read_library_manifest(info$path))) {
    touch_library(info$path)
    return(info$path)
  }
  cmd <- installer_command(lock, repos, info$path, cache)
  res <- processx::run(cmd$command, cmd$args, env = cmd$env, echo = echo,
                       error_on_status = FALSE)
  if (is.null(read_library_manifest(info$path))) {
    tail <- paste(utils::tail(strsplit(res$stderr, "\n", fixed = TRUE)[[1]], 20),
                  collapse = "\n")
    stop("ember: installing ", info$path, " failed (status ", res$status, ")\n", tail,
        call. = FALSE)
  }
  touch_library(info$path)
  info$path
}

# ---- renv's cache layout -------------------------------------------------------

#' The renv cache directories the installed packages in `staging` link to,
#' for the manifest's `cache_entries` (what `clean(cache = TRUE)` may
#' delete once no library's manifest lists it). `cache_root` is
#' `RENV_PATHS_CACHE` (`<cache>/renv-cache`).
#'
#' renv links a package into a library either as a symlink to the cache
#' (`Sys.readlink()` finds the target directly) or, measured on macOS
#' (spikes/packages), as a hard link with no symlink to follow. For a hard
#' link, the cache entry is found by renv's own layout,
#' `v5/<os>/R-<minor>/<platform triplet>/<pkg>/<version>/<hash>`; when more
#' than one hash exists for that package and version (an upgrade that
#' reinstalled it), the one sharing the installed copy's inode is picked,
#' falling back to the newest when inodes aren't comparable (Windows).
library_cache_entries <- function(staging, installed, cache_root) {
  if (!dir.exists(cache_root) || length(installed) == 0) return(character())
  out <- character()
  for (pkg in names(installed)) {
    pkg_dir <- file.path(staging, pkg)
    if (!dir.exists(pkg_dir)) next
    link <- tryCatch(Sys.readlink(pkg_dir), error = function(e) "")
    if (!is.na(link) && nzchar(link)) {
      out <- c(out, dirname(normalizePath(link, mustWork = FALSE)))
      next
    }
    version <- installed[[pkg]]
    candidates <- Sys.glob(file.path(cache_root, "v5", "*", "*", "*", pkg, version, "*"))
    if (length(candidates) <= 1) {
      out <- c(out, candidates)
      next
    }
    target_ino <- tryCatch(file.info(pkg_dir)$ino, error = function(e) NA)
    matched <- if (!is.na(target_ino)) {
      Filter(function(c) isTRUE(file.info(file.path(c, pkg))$ino == target_ino), candidates)
    } else character()
    out <- c(out, if (length(matched) > 0) matched else candidates[length(candidates)])
  }
  unique(out)
}

#' Write the manifest into `staging` and rename it to `path`: the one
#' rename every installer (real or fake) ends with. If `path` already has
#' a valid manifest, another process's installer won the race while this
#' one ran; this one's copy is discarded, not an error
#' (make-operations-idempotent). Used by inst/installer.R and
#' inst/fake-installer.R, and exercised directly by test-library.R's race
#' test so it doesn't need two real renv runs.
finish_library <- function(staging, path, manifest) {
  saveRDS(manifest, file.path(staging, "ember-library.rds"))
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  if (!is.null(read_library_manifest(path))) {
    unlink(staging, recursive = TRUE)
    return(invisible(FALSE))
  }
  if (suppressWarnings(file.rename(staging, path))) return(invisible(TRUE))
  # Lost a race that started after the check above.
  if (!is.null(read_library_manifest(path))) {
    unlink(staging, recursive = TRUE)
    return(invisible(FALSE))
  }
  stop("ember: could not install the library at ", path, call. = FALSE)
}

# ---- Jobs (shell side) -------------------------------------------------------

#' Subprocess jobs the shell runs for effects: index fetches and installs.
#'
#' A process-wide table, keyed by a job key that identifies the actual
#' subprocess two sessions could share: the full `(repo key, url, cache)`
#' for an index fetch (`index_job_key()`), and the library's filesystem
#' `path` for an install (not its `key`: that's a hash of the lock text
#' alone, the same for two sessions whose libraries live under different
#' caches). Two sessions asking for the same index or the same library
#' share one subprocess and both get the result: the only shared,
#' mutable thing step 3 adds, and it holds no decisions, only processes and
#' the list of `(nb, token)` to tell. Polled from each session's existing
#' `later` poll (shell.R): a finished job enqueues one event per
#' subscriber.
#'
#' `poll_jobs()` services every job in the table, not only ones `nb`
#' subscribes to: the table is process-wide, so whichever session's `later`
#' tick happens to run next does the work for everyone, and each
#' subscriber still only ever hears about the keys it joined. `nb` is kept
#' as a parameter for symmetry with `job_start()`/`job_leave()` and in case
#' a future caller wants to poll on behalf of one session only; it isn't
#' read here.
jobs <- new.env(parent = emptyenv())

#' The job-table key for an index fetch: `key` alone would let two sessions
#' fetching the same date from different repositories, or into different
#' cache directories, join the same download and each get an index that
#' doesn't match their own `url`/`cache` (the same ambiguity `cached_index()`
#' guards against in its own memo).
index_job_key <- function(key, url, cache) paste(key, url, cache, sep = "\u0001")

#' Start, or join a running job with the same key. `make_progress(line)`
#' -> event or `NULL`; `make_done(status, output)` -> event. Each
#' subscriber keeps its own closures, since the same index fetch can be
#' told to two sessions with no per-session data, while an install job's
#' events carry a token private to the session that started it.
job_start <- function(key, cmd, nb, make_progress, make_done) {
  job <- jobs[[key]]
  if (is.null(job)) {
    proc <- processx::process$new(cmd$command, cmd$args, env = cmd$env,
                                  stdout = "|", stderr = "2>&1", cleanup_tree = TRUE)
    job <- new.env(parent = emptyenv())
    job$proc <- proc
    job$buf <- ""
    job$lines <- character()
    job$subs <- list()
    jobs[[key]] <- job
  }
  job$subs[[length(job$subs) + 1L]] <- list(nb = nb, make_progress = make_progress,
                                            make_done = make_done)
  invisible(NULL)
}

#' The session no longer cares (closed, or `fx_cancel_install`); the
#' process is killed when no subscriber remains, and the staging folder it
#' leaves is cleaned later (`clean()`'s staging rule).
job_leave <- function(key, nb) {
  job <- jobs[[key]]
  if (is.null(job)) return(invisible(NULL))
  job$subs <- Filter(function(s) !identical(s$nb, nb), job$subs)
  if (length(job$subs) == 0L) {
    tryCatch(if (job$proc$is_alive()) job$proc$kill(), error = function(e) NULL)
    rm(list = key, envir = jobs)
  }
  invisible(NULL)
}

#' Lines `poll_jobs()` keeps past its 400-line cap even once they'd
#' otherwise be the oldest and first evicted: the same shapes
#' `install_failures()` (packages-core.R) looks for, so a failure near
#' the start of a long, slow build's output is never dropped before
#' anything gets a chance to parse it. Not a contract (design-gaps.md):
#' widening this list costs nothing and can only keep more, never less.
JOB_FAILURE_LINE_RE <- "^(ERROR|Error)|install failed|failed to retrieve"

#' One poll of every running job: read whatever output has arrived, turn
#' complete lines into progress events for each subscriber, and when a
#' job's process has exited, turn its status and full output into a done
#' event for each subscriber and drop the job.
#'
#' Every complete line also accumulates into `job$lines`, not just handed
#' to `make_progress` and dropped: `make_done` needs the whole run's
#' output, not only whatever didn't fit in one poll as the unfinished
#' last line (`job$buf`) -- an install that runs longer than a single
#' poll interval used to report an empty log on failure (design-gaps.md,
#' Packages). Bounded at 400 lines, but a line matching
#' `JOB_FAILURE_LINE_RE` is kept regardless: capping by a plain
#' `tail(..., 400)` would drop an early failure line from a log that
#' keeps printing for thousands of lines afterward (a slow, chatty
#' configure script, say), leaving `install_failures()` nothing to find.
poll_jobs <- function(nb) {
  for (key in ls(jobs, all.names = TRUE)) {
    job <- jobs[[key]]
    if (is.null(job)) next

    chunk <- tryCatch(if (job$proc$is_alive()) job$proc$read_output() else "",
                      error = function(e) "")
    if (nzchar(chunk)) {
      job$buf <- paste0(job$buf, chunk)
      lines <- strsplit(job$buf, "\n", fixed = TRUE)[[1]]
      ends_with_newline <- endsWith(job$buf, "\n")
      complete <- if (ends_with_newline) lines else utils::head(lines, -1L)
      job$buf <- if (ends_with_newline || length(lines) == 0L) "" else utils::tail(lines, 1L)
      if (length(complete) > 0L) {
        combined <- c(job$lines, complete)
        recent <- utils::tail(combined, 400L)
        overflow <- utils::head(combined, max(0L, length(combined) - 400L))
        job$lines <- c(overflow[grepl(JOB_FAILURE_LINE_RE, overflow)], recent)
      }
      for (line in complete) {
        for (s in job$subs) {
          ev <- tryCatch(s$make_progress(line), error = function(e) NULL)
          if (!is.null(ev)) enqueue(s$nb, ev)
        }
      }
    }

    alive <- tryCatch(job$proc$is_alive(), error = function(e) FALSE)
    if (!alive) {
      status <- tryCatch(job$proc$get_exit_status(), error = function(e) NA_integer_)
      rest <- tryCatch(job$proc$read_all_output(), error = function(e) "")
      # `job$buf` and `rest` continue the same unfinished line (whatever
      # didn't end in "\n" yet when the process exited): joining them
      # with "\n" like every other pair here would split that one line
      # in two, and a pattern anchored on the whole line (install_failures()'s
      # `^ERROR: ...`) would then match neither half.
      output <- paste0(paste(job$lines, collapse = "\n"),
                       if (length(job$lines) > 0L) "\n" else "",
                       job$buf, rest)
      for (s in job$subs) {
        ev <- tryCatch(s$make_done(status, output), error = function(e) NULL)
        if (!is.null(ev)) enqueue(s$nb, ev)
      }
      rm(list = key, envir = jobs)
    }
  }
  invisible(NULL)
}

# ---- Cleanup -----------------------------------------------------------------

#' The library paths open sessions in this process currently hold as
#' `target` or `active`, so `clean()` never deletes one out from under a
#' running session.
#'
#' The shell replaces the whole set (rather than marking and unmarking one
#' path at a time) whenever it's convenient, such as before calling
#' `clean()`, or after any dispatch that could have changed a `target` or
#' `active` path: `set_active_libraries(unique(unlist(lapply(open_sessions,
#' function(nb) c(nb$state$packages$target$path, nb$state$packages$active$path)))))`.
#' Replacing the set needs no bookkeeping when a session closes, unlike
#' marking and unmarking each path.
active_libraries <- local({
  env <- new.env(parent = emptyenv())
  env$paths <- character()
  env
})

#' @rdname active_libraries
set_active_libraries <- function(paths) {
  active_libraries$paths <- paths
  invisible(NULL)
}

#' Total size, in bytes, of every file under `path` (a plain recursive
#' sum, not `du`'s hard-link-aware count: `clean()`'s dry-run report is an
#' estimate, not a disk-use accounting, which is `disk_use()`'s job).
dir_size <- function(path) {
  files <- list.files(path, recursive = TRUE, all.files = TRUE, full.names = TRUE,
                      no.. = TRUE)
  sum(vapply(files, function(f) {
    sz <- file.info(f)$size
    if (is.na(sz)) 0 else sz
  }, numeric(1)))
}

#' Delete what is unused. Returns, invisibly, a data frame `path`, `kind`
#' (`"library"`, `"staging"`, `"cache"`, `"index"`), `bytes`, `last_used`
#' of what was (or with `dry_run`, would be) deleted.
#'
#' * Libraries whose `ember-last-used` is older than `max_age` days, except
#'   any an open session in this process has as `active` or `target`. They
#'   hold only links, so a returning notebook gets its library back from
#'   the cache in seconds, or from the lock.
#' * Staging folders older than one day (an installer that crashed).
#' * With `cache = TRUE`: renv cache entries listed in no remaining
#'   library's manifest (`cache_entries`), so deleting one never breaks a
#'   library whether renv linked with hard links or symlinks.
#' * Index RDS files not read for `max_age` days.
#'
#' The first `open_notebook()` in a process runs it once, in a job, with
#' `cache = FALSE` (design.md: "when the server starts").
#' @export
clean <- function(max_age = 60, cache = TRUE, dry_run = FALSE,
                  dir = cache_dir(), now = Sys.time()) {
  out <- data.frame(path = character(), kind = character(), bytes = numeric(),
                    last_used = as.POSIXct(character()), stringsAsFactors = FALSE)
  record <- function(path, kind, bytes, last_used) {
    out[nrow(out) + 1L, ] <<- list(path, kind, bytes, last_used)
  }
  age_days <- function(when) {
    if (is.null(when) || is.na(when)) return(NA_real_)
    as.numeric(difftime(now, when, units = "days"))
  }

  kept_cache_entries <- character()

  lib_root <- file.path(dir, "libraries")
  if (dir.exists(lib_root)) {
    key_dirs <- Sys.glob(file.path(lib_root, "*", "*", "*"))
    for (entry in key_dirs) {
      if (!dir.exists(entry)) next
      if (grepl("\\.staging-[^/]+$", entry)) {
        age <- age_days(file.info(entry)$mtime)
        if (is.na(age) || age >= 1) {
          record(entry, "staging", dir_size(entry), file.info(entry)$mtime)
          if (!dry_run) unlink(entry, recursive = TRUE)
        }
        next
      }

      manifest <- read_library_manifest(entry)
      if (is.null(manifest)) next

      if (entry %in% active_libraries$paths) {
        kept_cache_entries <- c(kept_cache_entries, manifest$cache_entries)
        next
      }
      marker <- file.path(entry, "ember-last-used")
      last_used <- if (file.exists(marker)) file.info(marker)$mtime else file.info(entry)$mtime
      age <- age_days(last_used)
      if (is.na(age) || age < max_age) {
        kept_cache_entries <- c(kept_cache_entries, manifest$cache_entries)
        next
      }
      record(entry, "library", dir_size(entry), last_used)
      if (!dry_run) unlink(entry, recursive = TRUE)
    }
  }

  idx_root <- file.path(dir, "indexes")
  if (dir.exists(idx_root)) {
    for (f in list.files(idx_root, full.names = TRUE, pattern = "\\.rds$")) {
      info <- file.info(f)
      last_used <- if (!is.na(info$atime)) info$atime else info$mtime
      age <- age_days(last_used)
      if (!is.na(age) && age >= max_age) {
        record(f, "index", info$size, last_used)
        if (!dry_run) unlink(f)
      }
    }
  }

  if (isTRUE(cache)) {
    cache_root <- file.path(dir, "renv-cache")
    if (dir.exists(cache_root)) {
      hash_dirs <- Sys.glob(file.path(cache_root, "v5", "*", "*", "*", "*", "*", "*"))
      kept <- unique(kept_cache_entries)
      for (h in hash_dirs) {
        if (!(h %in% kept)) {
          record(h, "cache", dir_size(h), file.info(h)$mtime)
          if (!dry_run) unlink(h, recursive = TRUE)
        }
      }
    }
  }

  invisible(out)
}

#' Disk use for the package view: `list(libraries, cache, indexes)` in
#' bytes. R's `file.info()` has no inode or link count, so this uses `du`
#' over the cache and libraries together where it exists (it counts a
#' hard-linked file once) and sums sizes elsewhere, which overcounts
#' libraries. Run as a job when asked; walking a large cache can take
#' seconds. Increment 2.
disk_use <- function(dir = cache_dir()) stop("not implemented")
