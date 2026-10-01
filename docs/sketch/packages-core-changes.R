# Changes to step 2's files, as sketches of the changed functions. Each
# block names its file. Nothing here is a new module.

# ==== state.R ==================================================================

# new_state(): `file$lock` is now an `ember_lock` (notebook.R parses it);
# `options` gains `repos`, `cache`, `r`; the state gains `packages`:
#
#   wanted <- wanted_packages(graph, file$header)
#   packages = new_packages_state(file$lock, wanted, options$r, options$cache)
#
# and `worker` (new_worker_state()) gains `loaded`: named character,
# namespace -> version, for non-base namespaces loaded in this worker,
# from the hello and every `done` report. Reset with the worker.

#' The exports the graph is built with: the installed packages' (from the
#' active library's manifest), overridden by what the worker reported for
#' packages it attached. Replaces the bare `state$exports` in
#' `rebuild_graph()`, `new_state()` and `check_state()`'s graph invariant,
#' so a cell that attaches dplyr gets dplyr's edges before it ever runs.
exports_of <- function(state) {
  utils::modifyList(state$packages$active$exports, state$exports)
}

# snapshot_of(): adds `packages = packages_view(state)`, and per cell view
# `waiting_for` (character: `waiting_cells(state)[[id]]`, else empty).
# `queued` stays as it is: a waiting cell is still queued.

# notifications(): adds `packages_changed` when `packages_view()` differs,
# after an `identical()` short cut on `state$packages`, `state$file$lock`
# and `state$file$header`.

# check_state(): adds the `packages` invariants (packages-core.R) and
# compares the graph against `exports_of(state)`.

# ==== step.R ===================================================================

# step():
#   r <- reduce(state, event)
#   p <- schedule_packages(r$state, old = state)     # new
#   s <- schedule(p$state)
#   reads <- missing_file_reads(s$state)
#   effects = c(r$effects, p$effects, s$effects, reads)
#
# reduce(): new cases preview_date, set_date, index_fetched, index_failed,
# library_checked, install_progress, install_done (packages-core.R).

# schedule():
#   * returns early while `switch_pending(state)`;
#   * the candidate loop skips ids in `waiting_cells(state)` without
#     dropping them from `pending` (`repeat` walks the queue past them
#     instead of stopping), and drops them when the target library failed;
#   * fx_start_worker(gen, state$packages$active$path, wd).
#
# run_message(): adds `library = state$packages$active$path`. The worker
# sets `.libPaths(library)` before the run when it differs from its own,
# converging on the active library the way it converges on `order`.

#' reduce_restart() keeps its checks and calls this; switch_library() calls
#' it for a version change. `reason` goes into `worker$exit$message` so the
#' snapshot says why every cell is not run.
restart_worker <- function(state, reason = NULL) {
  stop("not implemented")
}

# reduce_run(): also resets a "failed" target library to "missing" (and
# failed index slots to retry), so asking to run again retries the
# install, once.

# reduce_allow(): records `options$r$version` into `header$r_version` when
# it differs (design.md: "records the new version once the user runs the
# notebook on it"). Increment 2 adds the Bioconductor release change and
# its warning.

# reduce_apply(): ops add_extra_package / remove_extra_package edit
# `state$file$header$extra_packages` (sorted, unique; remove refused when
# the name comes from code). schedule_packages() sees the new wanted set.

# reduce_wk_hello(): `worker$loaded <- event$info$loaded`.
# reduce_wk_done(): `worker$loaded <- c(worker$loaded, report$loaded)`;
# when `report$error$package` is set, the run error comes from
# `missing_package_error()`.

# reduce_shutdown(): adds fx_cancel_install(token) when an install runs
# (the shell leaves the job; another session may still want it).

# ==== shell.R ==================================================================

# run_effect(): new cases
#   fetch_index    -> idx <- cached_index(key); if (!is.null(idx)) enqueue
#                     ev_index_fetched at once, else job_start(key,
#                     index_fetch_command(...)) whose done event reads the
#                     RDS (ev_index_fetched) or carries the error
#                     (ev_index_failed).
#   check_library  -> touch_library(path); enqueue ev_library_checked(key,
#                     read_library_manifest(path)).
#   install        -> write the plan file; job_start(key, installer_command(...)),
#                     progress lines -> ev_install_progress, exit ->
#                     ev_install_done(token, key, read_library_manifest(path),
#                     message, last lines).
#   cancel_install -> job_leave(key, nb).
# start_worker_process(): touch_library(fx$library).
# poll(): also poll_jobs(nb).

# ==== notebook.R ===============================================================

# parse_notebook(): the lock block goes through parse_lock_lines(); its
# problems join the file's `problems`. format_notebook(): through
# format_lock_lines(). An Ember-written lock round-trips byte for byte, as
# the rest of the file does.

# ==== inst/worker.R ============================================================

# hello: adds `loaded` (name -> version for loadedNamespaces() minus base).
# done report: adds `loaded` (namespaces loaded during this run, with
# getNamespaceVersion()), and `error$package` when the condition inherits
# from `packageNotFoundError` (its `package` field), so the server needs no
# message matching.
# run: `msg$library` -> `.libPaths(msg$library)` when it differs.
# The worker still needs no package beyond R's own.
