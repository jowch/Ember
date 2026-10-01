# Packages inside the session core.
#
# The lock, the resolution and the install status are fields of the
# notebook's `ember_state`. `step()` (step.R) calls `schedule_packages()`
# after `reduce()` and before `schedule()`, the same way `schedule()` moves
# the worker forward: no event handler resolves, fetches or installs
# itself. Whichever event changes what the notebook wants (an edit, a
# sourced file, a learned definition, a date move, an index arriving, an
# install finishing), the same function decides what happens next.
#
# Index fetches, library checks and installs are effects the shell carries
# out in subprocesses; their progress and results come back as events.
# Everything here is pure.

# ---- The record --------------------------------------------------------------

#' `state$packages`: what the session knows about the notebook's packages
#' beyond the lock and header (which stay in `state$file`, so the derived
#' save writes them with no extra code).
#'
#' * `resolved_for`: sorted character, the `wanted_packages()` the current
#'   lock answers. History, like a result's `stale`: it cannot be derived,
#'   because the lock alone doesn't say which of its entries were roots.
#'   Set at open to `wanted` when every wanted name is in the lock (an
#'   Ember-written file: nothing to do, no network, no write), else to
#'   `character()` so the first `schedule_packages()` resolves.
#' * `indexes`: named list, repo key -> `ember_index_slot`.
#' * `problems`: data frame (`empty_package_problems()`), from the last
#'   resolution plus install failures. Replaced, never appended, by each
#'   resolution, so a fixed typo clears its row.
#' * `target`: `ember_library_slot` for the current lock's library.
#' * `active`: `ember_library_slot`, the last library seen ready: the one
#'   the worker runs with. Equal to `target` once `target` is ready and the
#'   switch is made (see `switch_library()`). Starts as the empty library
#'   (status `"ready"`, nothing installed): before a worker has ever run,
#'   that is exactly what it has loaded, and it keeps the "`active$status`
#'   is always `"ready"`" invariant true from the moment the state exists.
#' * `install`: `NULL` or `list(token, key)`: the one install job this
#'   session has running. At most one at a time, so two renv processes never
#'   build libraries for the same notebook at once.
#' * `proposal`: `NULL` or `ember_proposal` (a date move being previewed).
#' * `next_token`: integer, install job tokens.
#'
#' Invariants (added to `check_state()`):
#' * `target$key == library_for(state$file$lock, r, cache)$key`: `target`
#'   is reset by every change to the lock (`set_lock()` is the only writer
#'   of `state$file$lock` after open).
#' * `active$status == "ready"`.
#' * `install` is not `NULL` iff some slot with `install$key` has status
#'   `"installing"`, or the target changed while it ran (then the job
#'   finishes, its result is ignored, and the next install starts).
#' * `!allowed` implies `install` is `NULL`: nothing installs in safe
#'   preview (design.md, Decisions).
new_packages_state <- function(lock, wanted, r, cache) {
  empty <- empty_library(r, cache)
  info <- library_for(lock, r, cache)
  target <- if (identical(info$key, empty$key)) {
    new_library_slot(info$key, info$path, status = "ready",
                     installed = character(), exports = list())
  } else {
    new_library_slot(info$key, info$path)
  }
  active <- new_library_slot(empty$key, empty$path, status = "ready",
                             installed = character(), exports = list())
  locked_names <- if (is.null(lock$entries) || nrow(lock$entries) == 0) character() else lock$entries$name
  resolved_for <- if (all(wanted %in% locked_names)) wanted else character()
  structure(list(
    resolved_for = resolved_for,
    indexes = list(),
    problems = empty_package_problems(),
    target = target,
    active = active,
    install = NULL,
    proposal = NULL,
    next_token = 1L,
    # Seeded with `wanted` itself (not `NULL`), computed by `new_state()`
    # from the same graph and header passed in here: an uninitialised `NULL`
    # would make the first `schedule_packages()` call after open look like a
    # state change even for an event `reduce()` refuses outright (the
    # NULL -> character() transition bumps `seq` and breaks the
    # `identical(new, old)` no-op checks step-2's tests rely on).
    wanted_cache = wanted
  ), class = "ember_packages_state")
}

#' An index the session has asked for.
#' `status`: `"fetching"`, `"ready"` (`index` set) or `"failed"`
#' (`message`; `wanted` records the wanted set at failure, and the fetch is
#' retried only once `wanted` differs or `ev_run` asks: no retry loop when
#' offline).
new_index_slot <- function(status, index = NULL, message = NULL, wanted = NULL) {
  structure(list(status = status, index = index, message = message, wanted = wanted),
            class = "ember_index_slot")
}

#' A library as the session sees it. The folder is the shell's; the core
#' knows only this.
#'
#' * `key`, `path`: from `library_for()`.
#' * `status`: `"unknown"` (not looked at), `"checking"`, `"missing"`
#'   (looked at: no complete library there), `"installing"`, `"ready"`,
#'   `"failed"`.
#' * `installed`: named character, package -> version, from the library's
#'   manifest; empty unless `"ready"`.
#' * `exports`: named list, package -> exported names, from the manifest:
#'   computed once, by the installer, from each package's NAMESPACE and
#'   lazy-load index (no package is loaded in the server).
#' * `progress`: `NULL` or `list(done, total, current)` while installing.
#' * `message`, `log`: why it failed, and the installer's last lines.
#'
#' Readiness is one fact on disk: the manifest exists. The installer writes
#' it last, into a staging folder that is then renamed into place (library.R).
new_library_slot <- function(key, path, status = "unknown", installed = character(),
                             exports = list(), progress = NULL, message = NULL,
                             log = character()) {
  structure(list(key = key, path = path, status = status, installed = installed,
                 exports = exports, progress = progress, message = message, log = log),
            class = "ember_library_slot")
}

#' A date move being previewed: `date`, `status` (`"fetching"`, `"ready"`,
#' `"failed"`), and once ready `lock` (the fresh resolution at `date`),
#' `changes` (`lock_diff(current, lock)`), `problems`, `for_wanted` (the
#' wanted set it was computed for; recomputed when that changes, so a
#' preview never goes stale under an edit).
new_proposal <- function(date, status = "fetching", lock = NULL, changes = NULL,
                         problems = NULL, for_wanted = NULL) {
  structure(list(date = date, status = status, lock = lock, changes = changes,
                 problems = problems, for_wanted = for_wanted),
            class = "ember_proposal")
}

# ---- Events and effects ------------------------------------------------------

# From the API
ev_preview_date <- function(date, at) event("preview_date", at, date = date)
ev_set_date     <- function(date, at) event("set_date", at, date = date)
# `edit_notebook()` ops, applied by reduce_apply() with the others:
#   add_extra_package(name), remove_extra_package(name)

# From the shell's jobs
ev_index_fetched <- function(key, index, at) event("index_fetched", at, key = key, index = index)
ev_index_failed  <- function(key, message, at) event("index_failed", at, key = key, message = message)
ev_library_checked <- function(key, manifest, at)            # manifest: NULL when absent
  event("library_checked", at, key = key, manifest = manifest)
ev_install_progress <- function(token, item, at)             # item: list(package, step, done, total)
  event("install_progress", at, token = token, item = item)
ev_install_done <- function(token, key, manifest, message, log, at)
  event("install_done", at, token = token, key = key, manifest = manifest,
        message = message, log = log)

fx_fetch_index    <- function(key, url) effect("fetch_index", key = key, url = url)
fx_check_library  <- function(key, path) effect("check_library", key = key, path = path)
#' `lock` and `repos` are everything the installer needs; it writes the
#' renv lockfile itself (lock.R, `renv_lockfile_of()`).
fx_install        <- function(token, key, path, lock, repos)
  effect("install", token = token, key = key, path = path, lock = lock, repos = repos)
#' Deviation from the sketch: `fx_cancel_install()` also carries `key`, not
#' just `token`. The shell's job table (library.R) is keyed by the library
#' key, not the token (two notebooks installing the *same* library share
#' one job); `reduce_shutdown()` still has `state$packages$install$key` at
#' hand when it builds this effect, so passing it along costs nothing and
#' saves the shell from having to reverse-map a token to a job key.
fx_cancel_install <- function(token, key) effect("cancel_install", token = token, key = key)

# ---- The stage step() runs ---------------------------------------------------

#' `%||%` is defined in state.R, loaded before this file.

#' Move packages forward. Called by `step()` after `reduce()`, before
#' `schedule()`; returns `list(state, effects)`.
#'
#' In order, each part reading the state the previous part left: resolve,
#' then the date-move proposal, then look at the target library, then
#' install it, then switch the worker onto it. See the stage comments below
#' for what each one does; the module doc at the top of this file and
#' design.md ("One more stage in step()") give the rationale.
schedule_packages <- function(state, old) {
  effects <- list()
  p <- state$packages

  # ---- 1. Resolve --------------------------------------------------------
  # Deviation from the sketch's "cheap check first: skip when graph and
  # header are identical() to old's": skipping the whole stage on that check
  # would also skip it on every `index_fetched`/`index_failed` event, since
  # those change `packages$indexes`, not `graph` or `header` -- and resolving
  # in response to an index arriving is the whole point of the stage (test
  # "index_fetched resolves ..."). The real gate is `!setequal(wanted,
  # resolved_for)`, checked every call. What the cheap check *can* still
  # skip is recomputing `wanted` itself: it is a pure function of `graph` and
  # `header`, so when neither changed since `old`, the previous call's result
  # (cached in `wanted_cache`, not part of the documented invariants) is
  # still correct. Measured: without this, a 2000-cell notebook with no
  # packages regressed step()'s per-event cost past the engine's 50ms budget
  # (test-projections.R), since `wanted_packages()` walks every cell.
  {
    wanted <- if (identical(state$graph, old$graph) && identical(state$file$header, old$file$header) &&
                 !is.null(p$wanted_cache)) {
      p$wanted_cache
    } else {
      wanted_packages(state$graph, state$file$header)
    }
    p$wanted_cache <- wanted
    if (!setequal(wanted, p$resolved_for)) {
      if (length(wanted) > 0 && (is.null(state$file$header$snapshot) || is.na(state$file$header$snapshot))) {
        state$file$header$snapshot <- format(as.Date(state$clock), "%Y-%m-%d")
      }
      needed <- needed_repos(state$file$header)
      to_fetch <- Filter(function(k) {
        slot <- p$indexes[[k]]
        is.null(slot) || (identical(slot$status, "failed") && !setequal(slot$wanted %||% character(), wanted))
      }, needed)
      for (k in to_fetch) {
        p$indexes[[k]] <- new_index_slot("fetching")
        effects <- c(effects, list(fx_fetch_index(k, repo_url(state$options$repos, k))))
      }
      if (length(to_fetch) == 0 && length(needed) > 0) {
        first <- p$indexes[[needed[[1]]]]
        if (!is.null(first) && identical(first$status, "ready")) {
          loaded_idx <- Filter(Negate(is.null), lapply(p$indexes, function(s) s$index))
          res <- resolve_lock(wanted, state$file$lock, loaded_idx, needed = needed, mode = "keep")
          if (isTRUE(res$complete)) {
            state$packages <- p
            state <- set_lock(state, res$lock)
            p <- state$packages
            p$resolved_for <- wanted
            p$problems <- res$problems
          } else {
            for (k in res$fetch) {
              if (is.null(p$indexes[[k]]) || !identical(p$indexes[[k]]$status, "fetching")) {
                p$indexes[[k]] <- new_index_slot("fetching")
                effects <- c(effects, list(fx_fetch_index(k, repo_url(state$options$repos, k))))
              }
            }
          }
        } else if (!is.null(first) && identical(first$status, "failed")) {
          p$problems <- data.frame(kind = "index_unavailable", package = NA_character_,
                                   message = first$message %||% "no package index available",
                                   fixes = NA_character_, stringsAsFactors = FALSE)
        }
      }
    }
  }
  state$packages <- p

  # ---- 2. Proposal --------------------------------------------------------
  if (!is.null(state$packages$proposal)) {
    prop <- state$packages$proposal
    wanted <- wanted_packages(state$graph, state$file$header)
    key <- repo_key("cran", prop$date)
    slot <- state$packages$indexes[[key]]
    if (is.null(slot)) {
      state$packages$indexes[[key]] <- new_index_slot("fetching")
      effects <- c(effects, list(fx_fetch_index(key, repo_url(state$options$repos, key))))
    } else if (identical(slot$status, "ready") &&
              (identical(prop$status, "fetching") || !setequal(prop$for_wanted %||% character(), wanted))) {
      indexes_loaded <- stats::setNames(list(slot$index), key)
      res <- resolve_lock(wanted, state$file$lock, indexes_loaded, needed = key, mode = "fresh")
      if (isTRUE(res$complete)) {
        state$packages$proposal <- new_proposal(prop$date, status = "ready", lock = res$lock,
                                                changes = lock_diff(state$file$lock, res$lock),
                                                problems = res$problems, for_wanted = wanted)
      } else {
        for (k in res$fetch) {
          if (is.null(state$packages$indexes[[k]])) {
            state$packages$indexes[[k]] <- new_index_slot("fetching")
            effects <- c(effects, list(fx_fetch_index(k, repo_url(state$options$repos, k))))
          }
        }
      }
    } else if (identical(slot$status, "failed")) {
      state$packages$proposal <- new_proposal(prop$date, status = "failed")
    }
  }

  # ---- 3. Look -------------------------------------------------------------
  tgt <- state$packages$target
  if (identical(tgt$status, "unknown")) {
    lock_entries <- state$file$lock$entries
    if (is.null(lock_entries) || nrow(lock_entries) == 0) {
      tgt$status <- "ready"
      tgt$installed <- character()
      tgt$exports <- list()
      state$packages$target <- tgt
    } else {
      tgt$status <- "checking"
      state$packages$target <- tgt
      effects <- c(effects, list(fx_check_library(tgt$key, tgt$path)))
    }
  }

  # ---- 4. Install ------------------------------------------------------------
  tgt <- state$packages$target
  if (isTRUE(state$allowed) && !isTRUE(state$read_only) &&
      identical(tgt$status, "missing") && is.null(state$packages$install)) {
    token <- state$packages$next_token
    state$packages$next_token <- token + 1L
    state$packages$install <- list(token = token, key = tgt$key)
    tgt$status <- "installing"
    tgt$progress <- NULL
    state$packages$target <- tgt
    effects <- c(effects, list(fx_install(token, tgt$key, tgt$path, state$file$lock, state$options$repos)))
  }

  # ---- 5. Switch -------------------------------------------------------------
  sw <- switch_library(state)
  state <- sw$state
  effects <- c(effects, sw$effects)

  list(state = state, effects = effects)
}

#' The only writer of `state$file$lock` after open. Resets `target` to the
#' new lock's library (status `"unknown"`, or `"ready"` with no look when it
#' equals `active`'s key) and leaves `active` alone, so the worker keeps
#' running on the old library until the new one is ready.
set_lock <- function(state, lock) {
  state$file$lock <- lock
  info <- library_for(lock, state$options$r, state$options$cache)
  active <- state$packages$active
  if (identical(info$key, active$key)) {
    state$packages$target <- active
  } else {
    state$packages$target <- new_library_slot(info$key, info$path)
  }
  state
}

#' Point the worker at the target library once it is ready.
#'
#' * Same key as `active`: nothing.
#' * No conflict (`library_conflicts()` empty): `active <- target`. The
#'   worker picks up the new path from the next `run` message (it carries
#'   `library`, as it carries `order`), so a new package is just loaded:
#'   no restart. Namespaces already loaded keep their files, which are
#'   links to the same cache entries.
#' * A conflict and the worker busy: wait. `schedule()` sends nothing new
#'   meanwhile (`switch_pending()`), so no further cell loads an old
#'   version.
#' * A conflict and the worker not busy: `active <- target` and
#'   `restart_worker(state, reason)` (step.R, factored out of
#'   `reduce_restart()`): every cell is left not run, and
#'   `worker$exit$message` says why ("dplyr changed 1.1.4 -> 1.2.1; R
#'   restarted").
#' @return `list(state, effects)` (not just `state`, since a restart emits
#'   `fx_kill_worker`/`fx_start_worker`).
switch_library <- function(state) {
  p <- state$packages
  if (!identical(p$target$status, "ready") || identical(p$target$key, p$active$key)) {
    return(list(state = state, effects = list()))
  }
  loaded <- state$worker$loaded %||% character()
  conflicts <- library_conflicts(loaded, p$target$installed)
  if (nrow(conflicts) > 0 && identical(state$worker$status, "busy")) {
    return(list(state = state, effects = list()))
  }
  state$packages$active <- p$target
  # The active library's exports feed the graph (`exports_of()`, state.R);
  # rebuilding here, not just from `reduce_library_checked()`/
  # `reduce_install_done()`, is what makes a package's edges appear the
  # moment it becomes active even when no install was needed (a library
  # already complete on disk goes ready -> active in the same step()).
  state <- rebuild_graph(state)
  if (nrow(conflicts) > 0) {
    changes_txt <- paste(sprintf("%s changed %s -> %s", conflicts$name, conflicts$loaded, conflicts$new),
                         collapse = "; ")
    return(restart_worker(state, reason = paste0(changes_txt, "; R restarted")))
  }
  list(state = state, effects = list())
}

#' Loaded namespaces whose version the new library changes: data frame
#' `name`, `loaded`, `new`. A loaded package the new library doesn't have
#' is not a conflict: it stays loaded, as Pluto keeps a removed package.
#' @param loaded `state$worker$loaded`, package -> version (non-base).
library_conflicts <- function(loaded, installed) {
  common <- intersect(names(loaded), names(installed))
  changed <- Filter(function(n) !identical(unname(loaded[[n]]), unname(installed[[n]])), common)
  data.frame(name = changed, loaded = unname(loaded[changed]), new = unname(installed[changed]),
            stringsAsFactors = FALSE)
}

#' `TRUE` while a conflicting switch waits for the running cell.
switch_pending <- function(state) {
  p <- state$packages
  if (!identical(p$target$status, "ready") || identical(p$target$key, p$active$key)) return(FALSE)
  loaded <- state$worker$loaded %||% character()
  conflicts <- library_conflicts(loaded, p$target$installed)
  nrow(conflicts) > 0 && identical(state$worker$status, "busy")
}

# ---- Which cells wait --------------------------------------------------------

#' Map cell id -> character packages it waits for, for every code cell
#' that can't run yet, plus their transitive downstream (mapped to the
#' upstream cell's packages), the way `failed_blockers()` maps failures.
#'
#' Cell `c` waits for `p` when `p` is in `cell_packages(graph, c)`, `p` is
#' not in `active$installed`, and either `p` is in the lock (an install
#' will bring it) or resolution is still pending (`wanted != resolved_for`
#' and an index is fetching). A package that resolved to `not_found` does
#' not hold its cell: it runs, R says "there is no package called", and
#' the problem row explains why.
#'
#' `schedule()` skips waiting cells but keeps them in `pending`, so they run
#' the moment the library is ready. When the target library fails, they are
#' dropped from `pending` instead, and their view shows the failure.
waiting_cells <- function(state) {
  p <- state$packages
  # Cheap check first: no cell in the notebook names any package at all
  # (the common case, and the one `schedule()` pays this cost on for every
  # notebook on every event) means nothing can be waiting. `wanted_cache`
  # (packages-core.R's `schedule_packages()`) is exactly `wanted_packages()`
  # for the current graph and header, kept current by the stage that always
  # runs just before `schedule()` calls this.
  if (length(p$wanted_cache %||% character()) == 0) return(list())
  installed <- p$active$installed
  lock_entries <- state$file$lock$entries
  lock_names <- if (is.null(lock_entries) || nrow(lock_entries) == 0) character() else lock_entries$name
  not_found <- if (is.null(p$problems) || nrow(p$problems) == 0) character() else {
    p$problems$package[p$problems$kind == "not_found" & !is.na(p$problems$package)]
  }
  wanted <- wanted_packages(state$graph, state$file$header)
  resolving <- !setequal(wanted, p$resolved_for)
  any_fetching <- any(vapply(p$indexes, function(s) identical(s$status, "fetching"), logical(1)))

  code_ids <- names(state$cells)[vapply(state$cells, function(c) identical(c$kind, "code"), logical(1))]
  direct <- list()
  for (id in code_ids) {
    pkgs <- setdiff(cell_packages(state$graph, id), not_found)
    needed <- Filter(function(pk) {
      !(pk %in% names(installed)) && (pk %in% lock_names || (resolving && any_fetching))
    }, pkgs)
    if (length(needed) > 0) direct[[id]] <- needed
  }

  out <- direct
  for (id in names(direct)) {
    for (d in downstream(state$graph, id, transitive = TRUE)) {
      if (is.null(out[[d]])) out[[d]] <- direct[[id]]
    }
  }
  out
}

# ---- Reducers ----------------------------------------------------------------

#' Record the index (or the failure) under its key. A slot that is not
#' `"fetching"` ignores the event, so a duplicate is a no-op.
reduce_index_fetched <- function(state, event) {
  slot <- state$packages$indexes[[event$key]]
  if (is.null(slot) || !identical(slot$status, "fetching")) {
    return(list(state = state, effects = list(), reply = NULL))
  }
  state$packages$indexes[[event$key]] <- new_index_slot("ready", index = event$index)
  list(state = state, effects = list(), reply = NULL)
}

reduce_index_failed <- function(state, event) {
  slot <- state$packages$indexes[[event$key]]
  if (is.null(slot) || !identical(slot$status, "fetching")) {
    return(list(state = state, effects = list(), reply = NULL))
  }
  wanted <- wanted_packages(state$graph, state$file$header)
  state$packages$indexes[[event$key]] <- new_index_slot("failed", message = event$message, wanted = wanted)
  list(state = state, effects = list(), reply = NULL)
}

#' For `target` only (an old key's answer is ignored): manifest present ->
#' `"ready"` with `installed` and `exports`; absent -> `"missing"`.
#' Exports join the graph through `exports_of()` (state.R), and the graph
#' is rebuilt.
reduce_library_checked <- function(state, event) {
  tgt <- state$packages$target
  if (!identical(event$key, tgt$key)) return(list(state = state, effects = list(), reply = NULL))
  if (is.null(event$manifest)) {
    tgt$status <- "missing"
  } else {
    tgt$status <- "ready"
    tgt$installed <- event$manifest$installed
    tgt$exports <- event$manifest$exports
  }
  state$packages$target <- tgt
  state <- rebuild_graph(state)
  list(state = state, effects = list(), reply = NULL)
}

#' Token check; `target$progress` updated.
reduce_install_progress <- function(state, event) {
  inst <- state$packages$install
  if (is.null(inst) || !eq(inst$token, event$token)) return(list(state = state, effects = list(), reply = NULL))
  state$packages$target$progress <- event$item
  list(state = state, effects = list(), reply = NULL)
}

#' Token check; `install <- NULL`. If `key` is still the target: manifest ->
#' `"ready"` (as `reduce_library_checked`), else `"failed"` with `message`
#' and `log`, plus a `problems` row (`install_failed`, naming the package
#' when the installer could tell). An old key's result is dropped: the
#' library exists on disk and costs nothing until cleanup.
reduce_install_done <- function(state, event) {
  inst <- state$packages$install
  if (is.null(inst) || !eq(inst$token, event$token)) return(list(state = state, effects = list(), reply = NULL))
  state$packages$install <- NULL
  if (identical(event$key, state$packages$target$key)) {
    tgt <- state$packages$target
    if (!is.null(event$manifest)) {
      tgt$status <- "ready"
      tgt$installed <- event$manifest$installed
      tgt$exports <- event$manifest$exports
      tgt$progress <- NULL
      state$packages$target <- tgt
      state <- rebuild_graph(state)
    } else {
      tgt$status <- "failed"
      tgt$message <- event$message
      tgt$log <- event$log
      tgt$progress <- NULL
      state$packages$target <- tgt
      row <- data.frame(kind = "install_failed", package = NA_character_,
                        message = event$message %||% "install failed", fixes = NA_character_,
                        stringsAsFactors = FALSE)
      state$packages$problems <- if (is.null(state$packages$problems) || nrow(state$packages$problems) == 0) {
        row
      } else {
        rbind(state$packages$problems, row)
      }
    }
  }
  list(state = state, effects = list(), reply = NULL)
}

#' A preview of moving the date: `proposal <- new_proposal(date)`;
#' `schedule_packages()` fetches the index and computes it. Reply: `TRUE`.
reduce_preview_date <- function(state, event) {
  state$packages$proposal <- new_proposal(event$date)
  list(state = state, effects = list(), reply = TRUE)
}

#' Apply a previewed date move. Refused unless `proposal` is ready, is for
#' `event$date`, and was computed for the current wanted set: the caller
#' must have seen exactly what changes. Then `header$snapshot <- date`,
#' `set_lock(proposal$lock)`, `resolved_for <- wanted`, `proposal <-
#' NULL`. The restart, if a loaded package moved, follows from
#' `switch_library()` once the new library is ready.
#' Reply: the applied `changes`.
reduce_set_date <- function(state, event) {
  p <- state$packages
  wanted <- wanted_packages(state$graph, state$file$header)
  prop <- p$proposal
  if (is.null(prop) || !identical(prop$date, event$date) || !identical(prop$status, "ready") ||
      !setequal(prop$for_wanted %||% character(), wanted)) {
    return(list(state = state, effects = list(),
               reply = refused("no ready, current preview for that date")))
  }
  state$file$header$snapshot <- event$date
  state <- set_lock(state, prop$lock)
  state$packages$resolved_for <- wanted
  changes <- prop$changes
  state$packages$proposal <- NULL
  list(state = state, effects = list(), reply = changes)
}

#' `wk_done` with `report$error$package` set (the worker saw R's
#' `packageNotFoundError`, which carries the name, so this is not a message
#' match and works in every locale):
#' * not in the lock: run error kind `"missing_package"`, `names = pkg`,
#'   fix "Add pkg to [extra_packages]" (the API op `add_extra_package()`);
#' * in the lock and `active` says it is installed: the library changed
#'   under us (cleaned by another process): `active$status <- "unknown"` and
#'   target likewise, so it is looked at again;
#' * in the lock, not installed: the install failed; the error points at the
#'   package status.
#' Called from `reduce_wk_done()`. Returns `list(state, error)` (the
#' sketch's signature only names the inputs; a reducer needs to update both
#' the state, for the "check again" case, and produce the run error).
missing_package_error <- function(state, pkg) {
  lock_entries <- state$file$lock$entries
  lock_names <- if (is.null(lock_entries) || nrow(lock_entries) == 0) character() else lock_entries$name

  if (!(pkg %in% lock_names)) {
    err <- new_run_error("missing_package",
      message = sprintf("there is no package called '%s'", pkg),
      names = pkg,
      fixes = sprintf("Add %s to [extra_packages]", pkg))
    return(list(state = state, error = err))
  }

  if (pkg %in% names(state$packages$active$installed)) {
    # Only `target` goes back to "unknown" so `schedule_packages()`'s Look
    # stage checks the library again; `active` stays "ready" (check_state()'s
    # invariant) and the worker keeps running meanwhile. If the recheck finds
    # the package really is gone, `target` becomes "missing" and an install
    # follows the same way it would for a brand new package; until then the
    # worker is simply wrong about what it has, the same way any stale fact
    # on disk is (design.md, "Where the direction strains").
    if (identical(state$packages$target$key, state$packages$active$key)) {
      state$packages$target$status <- "unknown"
    }
    err <- new_run_error("missing_package",
      message = sprintf("there is no package called '%s'; the library will be checked again", pkg),
      names = pkg, fixes = character())
    return(list(state = state, error = err))
  }

  err <- new_run_error("missing_package",
    message = sprintf("there is no package called '%s'; its install may have failed", pkg),
    names = pkg, fixes = character())
  list(state = state, error = err)
}

# ---- Projection --------------------------------------------------------------

#' The packages part of the snapshot (and `package_status()`): plain data.
#'
#' `list(snapshot, r_version, bioc_version,
#'      library = list(status, path, progress, message),
#'      packages = data.frame(name, version, source, direct, status, message),
#'      problems, proposal = NULL | list(date, status, changes, problems),
#'      plan = NULL | list(install = <n packages>, restart = <names>))`
#'
#' Per package `status`: `"installed"` (in `active$installed` at the locked
#' version), `"installing"`, `"missing"` (not installed; in safe preview
#' this is what the banner counts), `"failed"`, `"not_found"` (from
#' `problems`, `version` `NA`). `direct` is `TRUE` for wanted names.
#' `plan` is what running would do; the banner's "installs 3 packages".
packages_view <- function(state) {
  p <- state$packages
  wanted <- wanted_packages(state$graph, state$file$header)
  entries <- state$file$lock$entries
  installing <- !is.null(p$install) && identical(p$install$key, p$target$key)

  rows <- list(data.frame(name = character(), version = character(), source = character(),
                          direct = logical(), status = character(), message = character(),
                          stringsAsFactors = FALSE))
  if (!is.null(entries) && nrow(entries) > 0) {
    for (i in seq_len(nrow(entries))) {
      nm <- entries$name[i]; ver <- entries$version[i]
      status <- if (nm %in% names(p$active$installed) &&
                   identical(unname(p$active$installed[[nm]]), ver)) {
        "installed"
      } else if (installing) "installing"
      else if (identical(p$target$status, "failed")) "failed"
      else "missing"
      rows[[length(rows) + 1]] <- data.frame(name = nm, version = ver, source = entries$source[i],
                                             direct = nm %in% wanted, status = status,
                                             message = NA_character_, stringsAsFactors = FALSE)
    }
  }
  if (!is.null(p$problems) && nrow(p$problems) > 0) {
    nf <- p$problems[!is.na(p$problems$kind) & p$problems$kind == "not_found", , drop = FALSE]
    if (nrow(nf) > 0) {
      for (i in seq_len(nrow(nf))) {
        rows[[length(rows) + 1]] <- data.frame(name = nf$package[i], version = NA_character_,
                                               source = NA_character_, direct = nf$package[i] %in% wanted,
                                               status = "not_found", message = nf$message[i],
                                               stringsAsFactors = FALSE)
      }
    }
  }
  packages_df <- do.call(rbind, rows)

  proposal <- NULL
  if (!is.null(p$proposal)) {
    proposal <- list(date = p$proposal$date, status = p$proposal$status,
                     changes = p$proposal$changes, problems = p$proposal$problems)
  }

  missing_n <- sum(packages_df$status == "missing")
  restart_names <- character()
  if (identical(p$target$status, "ready") && !identical(p$target$key, p$active$key)) {
    conf <- library_conflicts(state$worker$loaded %||% character(), p$target$installed)
    restart_names <- conf$name
  }
  plan <- if (missing_n > 0 || length(restart_names) > 0) {
    list(install = missing_n, restart = restart_names)
  } else {
    NULL
  }

  list(snapshot = state$file$header$snapshot, r_version = state$file$header$r_version,
      bioc_version = state$file$header$bioc_version,
      library = list(status = p$target$status, path = p$target$path,
                    progress = p$target$progress, message = p$target$message),
      packages = packages_df, problems = p$problems, proposal = proposal, plan = plan)
}
