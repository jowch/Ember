# The fake installer: candidate B's test seam (docs/packages.md, "Taken
# from B"). Same plan, same staging-then-rename, same manifest shape and
# the same EMBER-PROGRESS lines as inst/installer.R, but it never loads
# renv and never touches the network: it writes an *empty* library (no
# package files at all) with a manifest that claims the lock's versions
# are installed, so the core and the shell can be tested end to end
# (resolving, waiting cells, the worker's library switch, restarts,
# `clean()`) without a real install ever running.
#
# Selected by pointing `options(ember.installer_script = ...)` at this
# file instead of inst/installer.R (see `installer_script()` in
# R/library.R); it is not used unless a test does that.
#
#   Rscript --vanilla fake-installer.R <plan.rds>

main <- function(plan_path) {
  plan <- readRDS(plan_path)

  if (!is.null(ember:::read_library_manifest(plan$path))) {
    unlink(plan$staging, recursive = TRUE)
    return(invisible(NULL))
  }

  lock <- ember:::parse_lock_lines(plan$lock_lines)$lock
  installed <- ember:::lock_versions(lock)
  total <- length(installed)

  dir.create(plan$staging, recursive = TRUE, showWarnings = FALSE)

  cat(sprintf("EMBER-PROGRESS 0 %d - restore\n", total))
  flush(stdout())

  exports <- stats::setNames(lapply(names(installed), function(p) character()),
                             names(installed))
  manifest <- list(lock_lines = plan$lock_lines, r = plan$r, installed = installed,
                   exports = exports, cache_entries = character(), created = Sys.time())
  ember:::finish_library(plan$staging, plan$path, manifest)

  cat(sprintf("EMBER-PROGRESS %d %d - restore\n", total, total))
  flush(stdout())
  invisible(NULL)
}

if (!interactive()) {
  library(ember)
  main(commandArgs(trailingOnly = TRUE)[[1]])
}
