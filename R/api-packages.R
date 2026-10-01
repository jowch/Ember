# R API additions for packages. Thin wrappers, as in api.R: one event per
# call, the reply returned. Merges into api.R when built.

# ---- Opening -----------------------------------------------------------------

#' `open_notebook()` and `new_notebook()` lose `library =` and gain:
#'
#' @param repos `ember_repos()`: where indexes and packages come from.
#' @param cache `cache_dir()`: where libraries, indexes and renv's cache live.
#'
#' Both go into `state$options` with `r = r_info()`; the core never reads
#' them from the environment. The step-2 tests that passed `library = NULL`
#' use notebooks with no packages, whose library is the empty one.
#' The first open in a process starts `clean(cache = FALSE)` as a job.
open_notebook <- function(path, repos = ember_repos(), cache = cache_dir()) {
  stop("not implemented")
}

# ---- Reading -----------------------------------------------------------------

#' The notebook's packages: `packages_view()` of the current state (see
#' packages-core.R). Also in `notebook_snapshot(nb)$packages`; this is the
#' same value, for callers that want only it.
#' @export
package_status <- function(nb) packages_view(nb$state)

# ---- Changing the package set ------------------------------------------------

#' Edit ops for `edit_notebook()`: add or remove a name in the header's
#' `[extra_packages]`, for packages the code can't reveal (`ggsave("x.svg")`
#' needs svglite). Batched and atomic with the other ops.
#'
#' `remove_extra_package("dplyr")` when dplyr comes from a cell's code (not
#' the header) is refused, naming the cell: removing it means editing the
#' code.
#' @export
add_extra_package <- function(name) list(op = "add_extra_package", name = name)
#' @export
remove_extra_package <- function(name) list(op = "remove_extra_package", name = name)

# ---- Moving the date ---------------------------------------------------------

#' What moving the notebook's snapshot date would change.
#'
#' Starts the preview (fetching the index for `date` if needed). With
#' `wait = TRUE` (console and tests only, as `run_cells()`), services the
#' `later` loop until it is ready or `timeout` passes; with `wait = FALSE`
#' returns at once, and `package_status(nb)$proposal` fills in, announced
#' by a `packages_changed` event.
#'
#' "Update all" is `preview_date(nb, Sys.Date())`.
#'
#' @return `list(date, status, changes = data.frame(name, from, to, change),
#'   problems)`.
#' @export
preview_date <- function(nb, date = Sys.Date(), wait = TRUE, timeout = 60) {
  stop("not implemented")
}

#' Apply a previewed date move. Refused (an `ember_refused` condition)
#' unless `preview_date()` for this `date` is ready and current: the caller
#' has seen what changes. Returns the changes, invisibly.
#'
#' The header's `snapshot` and the lock change at once and the file is
#' saved; the library installs (once execution is allowed); if a package
#' the worker has loaded changed version, the worker restarts when the
#' library is ready and every cell is left not run.
#' @export
set_date <- function(nb, date) {
  stop("not implemented")
}

#' Increment 3. Move the date so that `name` is at `version` (the latest
#' when `NULL`): the earliest date on which that version was current, from
#' CRAN's release dates (crandb.r-pkg.org, cached), so the other packages
#' move only as far as they must. Returns the preview; `set_date()` with
#' its date applies it. Pinning an older version is the same call.
#' @export
preview_update <- function(nb, name, version = NULL, wait = TRUE, timeout = 60) {
  stop("not implemented")
}

# ---- Running a notebook file -------------------------------------------------

#' Run a notebook file top to bottom with its own packages.
#'
#' Reads the lock from the file, builds its library if needed (blocking;
#' the same installer and layout as a session), then runs the file with
#' `Rscript --vanilla` and `R_LIBS_USER` set to that library, as the worker
#' is started. Does not resolve: the lock is the authority here. If the
#' code names packages the lock lacks, it says so and runs anyway (R will
#' report the missing package), since resolving would change the file.
#'
#' @return The exit status, invisibly.
#' @export
run <- function(path, repos = ember_repos(), cache = cache_dir(),
                echo = TRUE) {
  # file <- parse_notebook(read_file_utf8(path), new_id = uuid)
  # wanted <- wanted_packages(notebook_graph(code_of(file$cells), file$setup), file$header)
  # gap <- setdiff(wanted, file$lock$entries$name); if (length(gap)) message(...)
  # lib <- if (nrow(file$lock$entries) == 0) empty_library(r_info(), cache)$path
  #        else ensure_library(file$lock, repo_urls(repos, file$header), cache = cache)
  # touch_library(lib)
  # processx::run(Rscript, c("--vanilla", path), wd = dirname(path),
  #   env = c("current", R_LIBS_USER = lib, R_LIBS = "", R_LIBS_SITE = ""),
  #   echo = echo, error_on_status = FALSE)$status
  stop("not implemented")
}

# `clean()` is exported from library.R. Endeavor calls it through the
# adapter as any R function.
