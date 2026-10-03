# R API additions for packages. Thin wrappers, as in api.R: one event per
# call, the reply returned.

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
#' `apply = TRUE` is what the Packages tab's Update button does
#' (`ember_update_packages`, server.R): once the preview is ready,
#' `schedule_packages()` applies it itself (`apply_proposal()`,
#' packages-core.R), the same change `set_date()` would make, unless doing
#' so would restart a package the worker has already loaded -- then the
#' proposal stays `"ready"` with `restart` naming it and waits for
#' `set_date()` (or, from the page, an explicit answer) instead of
#' applying on its own. With `wait = TRUE`, this call also returns once
#' the date has visibly moved, since an applied proposal is cleared the
#' moment it applies and so may already be gone by the time this checks.
#'
#' @return `list(date, status, changes = data.frame(name, from, to, change),
#'   problems, restart)`. `restart` is `character()` unless `apply = TRUE`
#'   left the proposal waiting on a loaded package.
#' @export
preview_date <- function(nb, date = Sys.Date(), wait = TRUE, apply = FALSE, timeout = 60) {
  date <- format(as.Date(date), "%Y-%m-%d")
  dispatch(nb, ev_preview_date(date, at = Sys.time(), apply = apply))

  if (isTRUE(wait)) {
    wait_for(nb, function(snap) {
      prop <- snap$packages$proposal
      if (!is.null(prop) && identical(prop$date, date)) return(prop$status %in% c("ready", "failed"))
      isTRUE(apply) && identical(snap$packages$snapshot, date)
    }, timeout = timeout)
  }

  prop <- package_status(nb)$proposal
  if (!is.null(prop) && identical(prop$date, date)) {
    return(list(date = prop$date, status = prop$status, changes = prop$changes,
               problems = prop$problems, restart = prop$restart %||% character()))
  }
  if (isTRUE(apply) && identical(package_status(nb)$snapshot, date)) {
    return(list(date = date, status = "ready", changes = NULL, problems = NULL, restart = character()))
  }
  list(date = date, status = "fetching", changes = NULL, problems = NULL, restart = character())
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
  date <- format(as.Date(date), "%Y-%m-%d")
  reply <- dispatch(nb, ev_set_date(date, at = Sys.time()))
  if (inherits(reply, "ember_refused")) stop(reply)
  invisible(reply)
}

#' Increment 3. Move the date so that `name` is at `version` (the latest
#' when `NULL`): the earliest date on which that version was current, from
#' CRAN's release dates (crandb.r-pkg.org, cached), so the other packages
#' move only as far as they must. Returns the preview; `set_date()` with
#' its date applies it. Pinning an older version is the same call.
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
run <- function(path, repos = ember_repos(), cache = cache_dir(), echo = TRUE) {
  text <- read_file_utf8(path)
  file <- parse_notebook(text, new_id = uuid)

  graph <- notebook_graph(code_of(file$cells), setup = file$setup,
                          disabled = disabled_ids(file$cells))
  wanted <- wanted_packages(graph, file$header)
  locked_names <- if (is.null(file$lock$entries) || nrow(file$lock$entries) == 0) {
    character()
  } else {
    file$lock$entries$name
  }
  gap <- setdiff(wanted, locked_names)
  if (length(gap) > 0) {
    message("ember: ", path, " uses package(s) not in its lock: ", paste(gap, collapse = ", "))
  }

  lib <- if (is.null(file$lock$entries) || nrow(file$lock$entries) == 0) {
    empty_library(r_info(), cache)$path
  } else {
    ensure_library(file$lock, repo_urls(repos, file$header), cache = cache, echo = echo)
  }
  touch_library(lib)

  rscript <- file.path(R.home("bin"), "Rscript")
  res <- processx::run(rscript, c("--vanilla", path), wd = dirname(path),
                       env = c("current", R_LIBS_USER = lib, R_LIBS = "", R_LIBS_SITE = ""),
                       echo = echo, error_on_status = FALSE)
  invisible(res$status)
}

# `clean()` is exported from library.R. Endeavor calls it through the
# adapter as any R function.
