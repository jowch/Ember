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
#' `"cran/2026-09-01"` is a single filename component. Two GitHub branches
#' of one repository, `feature/x` and `feature_x`, share a file; harmless,
#' since an index for a moving ref is always fetched again before it is
#' read (`fresh_index()`), and a commit's key has no `/` in its ref.
index_rds_path <- function(key, cache = cache_dir()) {
  file.path(cache, "indexes", paste0(gsub("/", "_", key, fixed = TRUE), ".rds"))
}

#' Whether the index for a dated `key` may still change at `now`: its date
#' is yesterday or later, in UTC (#39). Package Manager may publish a
#' date's snapshot after the first fetch of it, so an index fetched that
#' early could miss packages released later that day; a date preview
#' fetches such an index again (its slot is `provisional`). Yesterday too,
#' since when a day's snapshot is complete isn't known here, and a date
#' ahead of UTC's (a clock east of Greenwich) is later still. Any other
#' dated index never changes. Not GitHub keys: those move by ref
#' (`github_key()`).
index_may_change <- function(key, now = Sys.time()) {
  if (is_github_key(key)) return(FALSE)
  date <- tryCatch(as.Date(strsplit(key, "/", fixed = TRUE)[[1]][[2]]), error = function(e) NA)
  !is.na(date) && date >= as.Date(format(now, tz = "UTC", usetz = FALSE)) - 1
}

#' The label a dated repo key resolves to (`read_repo_index()`'s `label`,
#' and the lock's `source` field): the kind before the first `/`, mapped to
#' its lock spelling. Unknown kinds (a future `[sources]` key) pass through
#' unchanged, so a one-row GitHub index can use its own source string as
#' its own label with no special case here.
index_label_of_key <- function(key) {
  kind <- strsplit(key, "/", fixed = TRUE)[[1]][1]
  if (kind %in% names(bioc_kinds)) "Bioc" else switch(kind, cran = "CRAN", kind)
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

#' `cached_index()` after a fetch that may have replaced the saved copy (a
#' provisional key fetched again, `index_may_change()`): read from disk,
#' and the memo answers with this copy from now on, so a session opened
#' later gets it too. `NULL` when there is none.
reload_index <- function(key, cache = cache_dir(), url = NULL) {
  memo_key <- paste(key, url %||% "", cache, sep = "\u0001")
  if (exists(memo_key, envir = index_memo, inherits = FALSE)) rm(list = memo_key, envir = index_memo)
  cached_index(key, cache, url)
}

#' Run in the index-fetch subprocess (`index_fetch_command()`'s `-e`,
#' with `library(ember)` already loaded, as the installer is): download
#' `<url>/src/contrib/PACKAGES.gz`, falling back to the uncompressed
#' `PACKAGES` (the toy fixtures ship only the latter), parse it with
#' `read_repo_index()` and save the RDS at a temporary name, then rename
#' into place. A rename that loses the race to another process fetching
#' the same key is harmless: the two parses are `identical()` in content,
#' except for a key as recent as today (`index_may_change()`), where a later
#' fetch may hold more, and either is a valid snapshot of that day.
#' `cached_index()`'s memo only cares that a file exists at `path`.
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
  main <- if (is_github_key(key)) "fetch_github_main" else "fetch_index_main"
  code <- paste0(
    "local({library(ember); ember:::", main, "(",
    deparse(key), ", ", deparse(url), ", ", deparse(path), ")})")
  # The server's own library path, as for the installer, so the child finds
  # the same Ember the server runs.
  env <- c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep),
           R_LIBS_USER = "", R_LIBS_SITE = "")
  list(command = rscript, args = c("--vanilla", "-e", code), env = env)
}

# ---- GitHub sources ----------------------------------------------------------

#' Run in a subprocess (`index_fetch_command()`, for a `github/` key), as
#' `fetch_index_main()` is for a dated one: find the commit the key's ref
#' names (`<url>/commits/<ref>`, asking GitHub for the bare SHA), read that
#' commit's DESCRIPTION (`github_description_url()`) and save a one-row
#' `ember_repo_index` whose label is the lock source
#' `"github:<user>/<repo>@<sha>"`. Two small requests: the package itself
#' is downloaded only when it is installed (by renv), so a safe preview
#' fetches metadata only, as for CRAN.
#'
#' The index is saved under the key asked for, and also under the key of
#' the commit it found (`github_key(..., sha)`), which never changes: a
#' notebook whose lock holds that commit then finds it in the cache.
#' A token (`github_token()`) is sent when there is one, for private
#' repositories and GitHub's rate limit; a refusal says which it likely was
#' (`github_failure()`).
fetch_github_main <- function(key, url, path) {
  src <- parse_github_key(key)
  if (is.null(src)) stop("ember: not a GitHub key: ", key, call. = FALSE)
  base <- sub("/+$", "", url)
  token <- github_token(base)
  headers <- if (nzchar(token)) c(Authorization = paste("token", token)) else character()
  where <- sprintf("github:%s/%s@%s", src$user, src$repo, src$ref)

  sha_file <- tempfile("ember-github-sha-")
  got <- github_get(paste0(base, "/commits/", utils::URLencode(src$ref, reserved = TRUE)), sha_file,
                    c(headers, Accept = "application/vnd.github.sha"))
  if (!got$ok) stop(github_failure(where, got, nzchar(token)), call. = FALSE)
  sha <- tolower(trimws(readLines(sha_file, n = 1L, warn = FALSE)))
  if (!is_commit(sha)) stop("ember: GitHub didn't name a commit for ", where, call. = FALSE)

  desc <- tempfile("ember-github-desc-")
  got <- github_get(github_description_url(base, sha), desc,
                    c(headers, Accept = "application/vnd.github.raw"))
  if (identical(got$status, 404L)) {
    stop("ember: ", where, " has no DESCRIPTION at its top level, so it isn't an R package",
         call. = FALSE)
  }
  if (!got$ok) stop(github_failure(where, got, nzchar(token), sha), call. = FALSE)
  idx <- read_description_index(desc, key, github_source(src$user, src$repo, sha))

  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  pinned <- github_key(src$user, src$repo, sha)
  targets <- stats::setNames(c(path, index_rds_path(pinned, dirname(dirname(path)))), c(key, pinned))
  targets <- targets[!duplicated(names(targets))]
  for (k in names(targets)) {
    idx$key <- k
    tmp_rds <- paste0(targets[[k]], ".tmp-", Sys.getpid())
    saveRDS(idx, tmp_rds)
    if (!file.rename(tmp_rds, targets[[k]])) unlink(tmp_rds)
  }
  invisible(NULL)
}

#' The URL of a commit's top-level DESCRIPTION: GitHub's contents endpoint
#' (`<base>/contents/DESCRIPTION?ref=<sha>`, the call renv makes too), or,
#' for a `file://` base (the tests' fixture, which can't take a query),
#' `<base>/contents/<sha>/DESCRIPTION`.
github_description_url <- function(base, sha) {
  if (startsWith(base, "file://")) paste0(base, "/contents/", sha, "/DESCRIPTION")
  else paste0(base, "/contents/DESCRIPTION?ref=", sha)
}

#' The token to send to GitHub's API at `base`, or `""`: `GITHUB_PAT` (as
#' renv reads it), else `GITHUB_TOKEN`, else, for github.com when the
#' gitcreds package is installed, the git credential store's
#' (`gitcreds::gitcreds_get()`, which usethis sets up and renv also reads).
#' The fetch runs under `--vanilla`, so `~/.Renviron` counts only when the
#' server read it; the credential store doesn't depend on that.
github_token <- function(base) {
  token <- Sys.getenv("GITHUB_PAT", Sys.getenv("GITHUB_TOKEN", ""))
  if (nzchar(token) || !startsWith(base, "https://api.github.com")) return(token)
  if (!requireNamespace("gitcreds", quietly = TRUE)) return("")
  cred <- tryCatch(gitcreds::gitcreds_get("https://github.com", use_cache = FALSE),
                   error = function(e) NULL)
  if (is.null(cred) || is.null(cred$password)) "" else as.character(cred$password)
}

#' Download `u` to `dest` -> `list(ok, status, detail)`: `status` the HTTP
#' status GitHub answered (an integer, `NA` when there was none; a missing
#' `file://` path counts as 404), `detail` the last condition's message.
github_get <- function(u, dest, headers) {
  msgs <- character()
  ok <- tryCatch(withCallingHandlers({
    utils::download.file(u, dest, quiet = TRUE, mode = "wb", headers = headers)
    TRUE
  }, warning = function(w) {
    msgs <<- c(msgs, conditionMessage(w))
    invokeRestart("muffleWarning")
  }), error = function(e) {
    msgs <<- c(msgs, conditionMessage(e))
    FALSE
  })
  ok <- isTRUE(ok) && length(msgs) == 0
  hit <- regmatches(msgs, regexpr("HTTP status was '[0-9]{3}", msgs))
  status <- if (length(hit) > 0) {
    as.integer(sub(".*'", "", hit[[1]]))
  } else if (!ok && startsWith(u, "file://") && any(grepl("No such file", msgs, fixed = TRUE))) {
    404L   # the fixture's "not there"
  } else {
    NA_integer_
  }
  list(ok = ok, status = status, detail = if (length(msgs) > 0) msgs[[length(msgs)]] else "")
}

#' The message for a failed GitHub request for `where`
#' (`"github:user/repo@ref"`), from `got` (`github_get()`) and whether a
#' token was sent. GitHub answers 404 for a private repository it wasn't
#' shown a token for, and 403 or 429 when the rate limit (60 requests an
#' hour without a token) runs out, so each says that rather than only
#' "not found". `sha`: the commit, when the failure was reading its
#' DESCRIPTION.
github_failure <- function(where, got, token, sha = NULL) {
  status <- got$status
  what <- if (is.null(sha)) where else sprintf("%s (commit %s)", where, sha)
  if (identical(status, 422L)) {
    # The commits endpoint's answer for a ref the repository doesn't have.
    paste0("ember: could not find ", what, " on GitHub: the repository has no branch, tag or commit by that name")
  } else if (identical(status, 404L)) {
    paste0("ember: could not find ", what, " on GitHub",
           if (token) " (or the token can't see that repository)"
           else "; if the repository is private, set GITHUB_PAT to a token that can read it")
  } else if (identical(status, 401L)) {
    paste0("ember: GitHub refused the token for ", what, " (GITHUB_PAT): it may have expired")
  } else if (identical(status, 403L) || identical(status, 429L)) {
    paste0("ember: GitHub refused to look up ", what,
           if (token) ", most likely its rate limit or the token's access"
           else ", most likely its rate limit of 60 requests an hour without a token; set GITHUB_PAT to raise it")
  } else {
    paste0("ember: could not reach GitHub for ", what,
           if (nzchar(got$detail)) paste0(" (", got$detail, ")") else "")
  }
}

#' A package's DESCRIPTION -> a one-row `ember_repo_index` under `key`,
#' labelled `label`: the same fields `read_repo_index()` reads from an index.
#' A source tree's DESCRIPTION rarely says NeedsCompilation (`R CMD build`
#' adds it), so without it `needs_compilation` is `NA`: unknown until the
#' package is downloaded.
read_description_index <- function(path, key, label) {
  dcf <- read.dcf(path, fields = c("Package", "Version", "Depends", "Imports", "LinkingTo",
                                   "NeedsCompilation"))
  if (nrow(dcf) != 1 || is.na(dcf[1, "Package"]) || is.na(dcf[1, "Version"])) {
    stop("ember: ", label, "'s DESCRIPTION has no Package or Version", call. = FALSE)
  }
  deps <- list(dep_field_union(dcf[1, "Depends"], dcf[1, "Imports"], dcf[1, "LinkingTo"]))
  nc <- toupper(trimws(unname(dcf[1, "NeedsCompilation"])))
  new_repo_index(key, label, unname(dcf[1, "Package"]), unname(dcf[1, "Version"]), deps,
                 if (is.na(nc)) NA else nc == "YES")
}

#' Run in the installer: for each GitHub package in `lock`, the package
#' names its DESCRIPTION needs, from the index cached when it was resolved
#' (under its commit's key), or fetched again (`fetch_github_main()`) when
#' this machine never resolved it. A package whose DESCRIPTION can't be had
#' is left out, and renv looks it up itself. -> named list.
github_install_deps <- function(lock, cache, github) {
  e <- lock$entries
  out <- list()
  for (i in which(startsWith(e$source, "github:"))) {
    src <- parse_github_source(e$source[[i]])
    if (is.null(src) || is.na(src$ref)) next
    key <- github_key(src$user, src$repo, if (is_commit(src$ref)) tolower(src$ref) else src$ref)
    idx <- cached_index(key, cache)
    if (is.null(idx)) {
      url <- repo_url(list(github = github), key)
      idx <- tryCatch({
        fetch_github_main(key, url, index_rds_path(key, cache))
        fresh_index(key, cache)
      }, error = function(e) NULL)
    }
    pos <- if (is.null(idx)) NA else match(e$name[[i]], idx$name)
    if (!is.na(pos)) out[[e$name[[i]]]] <- idx$deps[[pos]]
  }
  out
}

#' The index saved for a GitHub `key` with a moving ref (a branch, a tag,
#' `HEAD`), read straight from disk after this session's own fetch: not
#' memoised, and not read before fetching, since the ref may have moved
#' since an earlier fetch (`github_key()`). `NULL` when there is none.
fresh_index <- function(key, cache = cache_dir()) {
  path <- index_rds_path(key, cache)
  if (!file.exists(path)) return(NULL)
  tryCatch(readRDS(path), error = function(e) NULL)
}

# ---- Bioconductor's release list ---------------------------------------------

#' Where the parsed release list from `url` is cached: one file per URL
#' (hashed into its name), since a test or an institution may point
#' `ember_repos(bioc_config)` somewhere else.
bioc_config_rds_path <- function(url, cache = cache_dir()) {
  file.path(cache, "bioc-releases", paste0(hash_text(url), ".rds"))
}

#' How long a fetched release list is used before it is fetched again.
#' Bioconductor releases twice a year, so a day is plenty fresh. An older
#' copy is still used when a fetch fails (shell.R).
bioc_config_max_age <- 24 * 60 * 60

#' The cached release list for `url`: `list(table, fetched_at)`, or `NULL`
#' when there is none, or it is older than `max_age` seconds.
cached_bioc_config <- function(url, cache = cache_dir(), max_age = bioc_config_max_age) {
  path <- bioc_config_rds_path(url, cache)
  if (!file.exists(path)) return(NULL)
  hit <- tryCatch(readRDS(path), error = function(e) NULL)
  if (is.null(hit) || !is.data.frame(hit$table)) return(NULL)
  age <- as.numeric(difftime(Sys.time(), hit$fetched_at, units = "secs"))
  if (is.na(age) || age > max_age) return(NULL)
  hit
}

#' The local day a cached release list was fetched: it speaks for snapshot
#' dates up to that day (`releases_at()`, packages-core.R). Snapshot dates
#' are local days too (`schedule_packages()`).
fetched_day <- function(hit) as.Date(format(hit$fetched_at, "%Y-%m-%d"))

#' Run in a subprocess (`bioc_config_fetch_command()`), as
#' `fetch_index_main()` is: download `url`, parse it with
#' `parse_bioc_config()`, and save `list(table, fetched_at)` at a temporary
#' name, then rename into place. A file that parses to no release at all is
#' an error, not an empty list: it is not the file Ember expects.
fetch_bioc_config_main <- function(url, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- tempfile("ember-bioc-config-")
  ok <- isTRUE(tryCatch({
    utils::download.file(url, tmp, quiet = TRUE, mode = "wb")
    TRUE
  }, error = function(e) FALSE, warning = function(w) FALSE))
  if (!ok) stop("ember: could not fetch Bioconductor's release list from ", url, call. = FALSE)
  table <- parse_bioc_config(readLines(tmp, warn = FALSE))
  if (nrow(table) == 0) stop("ember: no Bioconductor releases found in ", url, call. = FALSE)
  tmp_rds <- paste0(path, ".tmp-", Sys.getpid())
  saveRDS(list(table = table, fetched_at = Sys.time()), tmp_rds)
  if (!file.rename(tmp_rds, path)) unlink(tmp_rds)
  invisible(NULL)
}

#' The command that fetches the release list from `url`, as a job; built
#' the same way as `index_fetch_command()`.
bioc_config_fetch_command <- function(url, cache = cache_dir()) {
  path <- bioc_config_rds_path(url, cache)
  rscript <- file.path(R.home("bin"), "Rscript")
  code <- paste0(
    "local({library(ember); ember:::fetch_bioc_config_main(",
    deparse(url), ", ", deparse(path), ")})")
  env <- c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep),
           R_LIBS_USER = "", R_LIBS_SITE = "")
  list(command = rscript, args = c("--vanilla", "-e", code), env = env)
}

#' The process-wide job key for fetching the release list from `url` into
#' `cache`: unlike an index key, it names no date, so it is prefixed to
#' keep it apart from `index_job_key()`'s.
bioc_config_job_key <- function(url, cache) paste("bioc-config", url, cache, sep = "\u0001")

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
installer_command <- function(lock, repos, path, cache = cache_dir(), github = "https://api.github.com") {
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
              staging = staging, path = path, cache = cache, github = github)
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
                           echo = TRUE, github = "https://api.github.com") {
  info <- library_for(lock, r, cache)
  if (!is.null(read_library_manifest(info$path))) {
    touch_library(info$path)
    return(info$path)
  }
  cmd <- installer_command(lock, repos, info$path, cache, github = github)
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

#' Copy into `staging` each lock entry renv left out because R's own
#' library (`.Library`, or the system site library a distribution uses for
#' them, `.Library.site`) already has that exact version: a recommended
#' package such as codetools at the version R ships. renv counts it as
#' installed and puts no copy in the target library, but a notebook's
#' library must hold every lock entry (packages.md: recommended packages
#' are locked), or the installer's check stops with `missing_package`. The
#' user's own libraries aren't looked in. Returns the names copied.
copy_from_r_library <- function(staging, wanted, lib_paths = c(.Library, .Library.site)) {
  lib_paths <- setdiff(normalizePath(lib_paths, mustWork = FALSE),
                       normalizePath(staging, mustWork = FALSE))
  copied <- character()
  for (pkg in names(wanted)) {
    if (file.exists(file.path(staging, pkg, "DESCRIPTION"))) next
    for (lib in lib_paths) {
      desc <- file.path(lib, pkg, "DESCRIPTION")
      if (!file.exists(desc)) next
      if (!identical(unname(read.dcf(desc, fields = "Version")[1, 1]), unname(wanted[[pkg]]))) next
      # A failed copy leaves the entry missing, which the installer's check reports.
      if (isTRUE(file.copy(file.path(lib, pkg), staging, recursive = TRUE))) copied <- c(copied, pkg)
      break
    }
  }
  copied
}

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

#' The cache entries a staging folder's package symlinks point at, for
#' `clean()` to keep while that install runs. Hard links have nothing to
#' follow, and need nothing: the library's copy outlives the entry.
staging_link_targets <- function(staging) {
  out <- character()
  for (pkg_dir in list.files(staging, full.names = TRUE)) {
    link <- tryCatch(Sys.readlink(pkg_dir), error = function(e) "")
    if (!is.na(link) && nzchar(link))
      out <- c(out, dirname(normalizePath(link, mustWork = FALSE)))
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
#' anything gets a chance to parse it. Not a contract:
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
#' poll interval used to report an empty log on failure. Bounded at 400
#' lines, but a line matching `JOB_FAILURE_LINE_RE` is kept regardless:
#' capping by a plain `tail(..., 400)` would drop an early failure line
#' from a log that keeps printing for thousands of lines afterward (a
#' slow, chatty configure script, say), leaving `install_failures()`
#' nothing to find.
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
#'   those in `keep`. They
#'   hold only links, so a returning notebook gets its library back from
#'   the cache in seconds, or from the lock.
#' * Staging folders older than one day (an installer that crashed).
#' * With `cache = TRUE`: renv cache entries listed in no remaining
#'   library's manifest (`cache_entries`), so deleting one never breaks a
#'   library whether renv linked with hard links or symlinks. An entry
#'   made in the last day, or one a staging folder younger than a day
#'   links to, is kept too: an install still running has no manifest yet.
#' * With `indexes = TRUE`: index RDS files not read for `max_age` days.
#'
#' `keep` is the library paths never to delete: by default every library
#' an open session in this process holds. The Packages tab's clean-up
#' (`clean_up()`, #128) runs this in a subprocess, so it passes the
#' server's set.
#'
#' The first `open_notebook()` in a process runs it once, in a job, with
#' `cache = FALSE` (design.md: "when the server starts").
#' @export
clean <- function(max_age = 60, cache = TRUE, dry_run = FALSE,
                  dir = cache_dir(), now = Sys.time(), keep = active_libraries$paths,
                  indexes = TRUE) {
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

  # Resolved like the paths it is compared with, so a `dir` spelled
  # through a symlink still matches an open session's library path.
  keep_resolved <- normalizePath(as.character(keep), mustWork = FALSE)
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
        } else {
          # An install in progress: it has no manifest yet, so the cache
          # entries it links to are listed nowhere. Keep the ones its
          # symlinks point at (a hard link survives its entry's deletion).
          kept_cache_entries <- c(kept_cache_entries, staging_link_targets(entry))
        }
        next
      }

      manifest <- read_library_manifest(entry)
      if (is.null(manifest)) next

      if (normalizePath(entry, mustWork = FALSE) %in% keep_resolved) {
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
  if (isTRUE(indexes) && dir.exists(idx_root)) {
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
      # Compared resolved: a manifest can name an entry through a symlink
      # target (`library_cache_entries()` follows renv's links) while the
      # glob spells it through `dir` (/var vs /private/var on macOS).
      kept <- unique(normalizePath(kept_cache_entries, mustWork = FALSE))
      for (h in hash_dirs) {
        # A cache entry made in the last day may belong to an install
        # still running, which renv fills before it links the library.
        age <- age_days(file.info(h)$mtime)
        if (!(normalizePath(h, mustWork = FALSE) %in% kept) && !is.na(age) && age >= 1) {
          record(h, "cache", dir_size(h), file.info(h)$mtime)
          if (!dry_run) unlink(h, recursive = TRUE)
        }
      }
    }
  }

  invisible(out)
}

#' Disk use for the package view (#38): `list(libraries, cache, indexes,
#' exact)`, the first three in bytes. R's `file.info()` has no inode or
#' link count, so this runs one `du -sk` over the cache, the indexes and
#' the libraries, in that order: `du` counts a hard-linked file once per
#' run, at its first sighting, so a library's links into renv's cache
#' count as the cache's and the libraries' number is what they hold of
#' their own. `exact` is `TRUE` then. Without `du` (`du = ""`; Windows
#' has none) it sums file sizes, which counts a linked file in both, and
#' `exact` is `FALSE`. A folder that doesn't exist is 0. Run in a
#' subprocess when asked (`disk_use_command()`): walking a large cache
#' can take seconds.
disk_use <- function(dir = cache_dir(), du = Sys.which("du")) {
  roots <- c(cache = file.path(dir, "renv-cache"), indexes = file.path(dir, "indexes"),
             libraries = file.path(dir, "libraries"))
  use <- list(libraries = 0, cache = 0, indexes = 0, exact = nzchar(du))
  present <- roots[dir.exists(roots)]
  if (length(present) == 0L) return(use)
  if (nzchar(du)) {
    res <- processx::run(du, c("-sk", unname(present)), error_on_status = FALSE)
    lines <- strsplit(res$stdout, "\n")[[1]]
    lines <- lines[nzchar(lines)]
    if (identical(res$status, 0L) && length(lines) == length(present)) {
      kb <- as.numeric(sub("\t.*$", "", lines))
      for (i in seq_along(present)) use[[names(present)[i]]] <- kb[i] * 1024
      return(use)
    }
    use$exact <- FALSE
  }
  for (kind in names(present)) use[[kind]] <- dir_size(present[[kind]])
  use
}

#' Run in a subprocess (`disk_use_command()`): print `disk_use(dir)` as JSON.
disk_use_main <- function(dir) {
  cat(jsonlite::toJSON(disk_use(dir), auto_unbox = TRUE, digits = NA))
  invisible(NULL)
}

#' The command that measures disk use for `dir`, as `index_fetch_command()`
#' builds its own: an inline `Rscript -e` that loads the installed `ember`.
disk_use_command <- function(dir = cache_dir()) {
  rscript <- file.path(R.home("bin"), "Rscript")
  code <- paste0("local({library(ember); ember:::disk_use_main(", deparse(dir), ")})")
  env <- c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep),
           R_LIBS_USER = "", R_LIBS_SITE = "")
  list(command = rscript, args = c("--vanilla", "-e", code), env = env)
}

#' The Packages tab's clean-up button (#128): `clean()` with the rule
#' "unused now", libraries no open notebook holds (`keep`) and not used
#' in the last `max_age` days, then the renv cache entries no remaining
#' library lists. The one-day default is a guard for notebooks open in
#' another Ember process or run by `ember::run()`, which this process can't
#' see: a worker touches its library's `ember-last-used` when it starts.
#' Indexes are left to the startup sweep. Returns `list(libraries, cache,
#' bytes)`: how many libraries (staging folders included) and cache
#' entries were, or with `dry_run` would be, deleted, and about how many
#' bytes that frees. `bytes` is measured before deleting, by one `du` over
#' the cache entries then the libraries, so a file a library links from a
#' deleted cache entry counts once; without `du` it is `clean()`'s plain
#' sum, which counts such a file twice.
clean_up <- function(dir = cache_dir(), keep = character(), dry_run = TRUE, max_age = 1,
                     du = Sys.which("du"), now = Sys.time()) {
  plan <- clean(max_age = max_age, cache = TRUE, dry_run = TRUE, dir = dir, now = now,
                keep = keep, indexes = FALSE)
  libs <- plan$path[plan$kind %in% c("library", "staging")]
  entries <- plan$path[plan$kind == "cache"]
  bytes <- sum(plan$bytes)
  paths <- c(entries, libs)
  if (length(paths) > 0L && nzchar(du)) {
    res <- processx::run(du, c("-sck", paths), error_on_status = FALSE)
    lines <- strsplit(res$stdout, "\n")[[1]]
    total <- grep("\ttotal$", lines, value = TRUE)
    if (identical(res$status, 0L) && length(total) == 1L)
      bytes <- as.numeric(sub("\t.*$", "", total)) * 1024
  }
  if (!isTRUE(dry_run) && length(paths) > 0L)
    clean(max_age = max_age, cache = TRUE, dry_run = FALSE, dir = dir, now = now,
          keep = keep, indexes = FALSE)
  list(libraries = length(libs), cache = length(entries), bytes = bytes)
}

#' Run in a subprocess (`clean_up_command()`): print `clean_up()` as JSON.
clean_up_main <- function(dir, keep, dry_run, now = Sys.time()) {
  cat(jsonlite::toJSON(clean_up(dir, keep = keep, dry_run = dry_run, now = as.POSIXct(now)),
                       auto_unbox = TRUE, digits = NA))
  invisible(NULL)
}

#' The command that runs `clean_up()` for `dir`, keeping `keep`, like
#' `disk_use_command()`. `now` (seconds since the epoch) is the time the
#' rule is judged at: the deletion passes the preview's, so a library that
#' turns a day old between the two isn't deleted unseen.
clean_up_command <- function(dir = cache_dir(), keep = character(), dry_run = TRUE,
                             now = as.numeric(Sys.time())) {
  rscript <- file.path(R.home("bin"), "Rscript")
  code <- paste0("local({library(ember); ember:::clean_up_main(", deparse(dir), ", ",
                 paste(deparse(as.character(keep)), collapse = ""), ", ",
                 deparse(isTRUE(dry_run)), ", ", format(as.numeric(now), digits = 17), ")})")
  env <- c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep),
           R_LIBS_USER = "", R_LIBS_SITE = "")
  list(command = rscript, args = c("--vanilla", "-e", code), env = env)
}
