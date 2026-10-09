# The installer subprocess. Started by the shell for `fx_install` and by
# `ensure_library()` for `ember::run()`, with the server's library (so renv
# is found) and Ember's renv cache. Never started in safe preview.
#
#   Rscript --vanilla installer.R <plan.rds>
#
# Plan: list(lock_lines, repos (name -> dated URL), r, staging, path, cache).
#
# Output on stdout, one per line, for the shell to turn into
# `ev_install_progress` (best effort: renv's own per-package reporting
# uses `cli` progress bars with no stable text to parse across versions,
# so this emits only a start and a finish line, not one per package; the
# manifest, not the progress, says what got installed):
#   EMBER-PROGRESS <done> <total> <package> <step>
# Exit status 0 iff the manifest was written and the rename made (which
# includes losing a race to another process: see `finish_library()`).

main <- function(plan_path) {
  plan <- readRDS(plan_path)
  # The lock's dated repositories decide what installs. A user's (or CI's)
  # renv settings would otherwise replace them: RENV_CONFIG_REPOS_OVERRIDE
  # points renv at another repository, and a profile or project changes
  # which library and lockfile it uses.
  Sys.unsetenv(c("RENV_CONFIG_REPOS_OVERRIDE", "RENV_PROFILE", "RENV_PROJECT",
                 "RENV_PATHS_LIBRARY", "RENV_PATHS_LOCKFILE"))

  if (!is.null(ember:::read_library_manifest(plan$path))) {
    unlink(plan$staging, recursive = TRUE)
    return(invisible(NULL))
  }

  lock <- ember:::parse_lock_lines(plan$lock_lines)$lock
  wanted <- ember:::lock_versions(lock)
  total <- length(wanted)

  # renv's own Linux binary rewrite gets Bioconductor's URLs wrong
  # (`ppm_binary_repos()`), so they go in already rewritten. The platform
  # is renv's own lookup (NULL off Linux), so both rewrites agree on it.
  platform <- if (identical(Sys.info()[["sysname"]], "Linux")) {
    tryCatch(utils::getFromNamespace("renv_ppm_platform", "renv")(),
             error = function(e) NULL)
  }
  repos <- ember:::ppm_binary_repos(plan$repos, platform)

  lf <- ember:::renv_lockfile_of(lock, plan$r, repos)
  lockfile_tmp <- tempfile("ember-lockfile-", fileext = ".json")
  renv::lockfile_write(lf, file = lockfile_tmp)

  dir.create(plan$staging, recursive = TRUE, showWarnings = FALSE)
  project_dir <- tempfile("ember-install-project-")
  dir.create(project_dir, recursive = TRUE, showWarnings = FALSE)

  cat(sprintf("EMBER-PROGRESS 0 %d - restore\n", total))
  flush(stdout())

  options(repos = repos)
  withCallingHandlers(
    renv::restore(lockfile = lockfile_tmp, library = plan$staging,
                  project = project_dir, prompt = FALSE, clean = FALSE),
    message = function(m) invokeRestart("muffleMessage"))

  ember:::copy_from_r_library(plan$staging, wanted)

  installed <- character()
  for (pkg in names(wanted)) {
    desc_path <- file.path(plan$staging, pkg, "DESCRIPTION")
    if (!file.exists(desc_path)) {
      cat(sprintf("EMBER-PROBLEM missing_package %s\n", pkg))
      quit(status = 1L, save = "no")
    }
    got <- unname(read.dcf(desc_path, fields = "Version")[1, 1])
    if (!identical(got, unname(wanted[[pkg]]))) {
      cat(sprintf("EMBER-PROBLEM version_mismatch %s wanted=%s got=%s\n",
                  pkg, wanted[[pkg]], got))
      quit(status = 1L, save = "no")
    }
    installed[[pkg]] <- got
  }

  exports <- list()
  for (pkg in names(installed)) {
    ns <- parseNamespaceFile(pkg, plan$staging)
    names <- ns$exports
    if (length(ns$exportPatterns) > 0) {
      rdx <- file.path(plan$staging, pkg, "R", paste0(pkg, ".rdx"))
      if (file.exists(rdx)) {
        objs <- names(readRDS(rdx)$variables)
        pattern <- paste(ns$exportPatterns, collapse = "|")
        names <- union(names, grep(pattern, objs, value = TRUE))
      }
    }
    exports[[pkg]] <- names
  }

  cache_root <- file.path(plan$cache, "renv-cache")
  cache_entries <- ember:::library_cache_entries(plan$staging, installed, cache_root)

  manifest <- list(lock_lines = plan$lock_lines, r = plan$r, installed = installed,
                   exports = exports, cache_entries = cache_entries,
                   created = Sys.time())
  ember:::finish_library(plan$staging, plan$path, manifest)

  cat(sprintf("EMBER-PROGRESS %d %d - restore\n", total, total))
  flush(stdout())
  invisible(NULL)
}

if (!interactive()) {
  library(ember)
  main(commandArgs(trailingOnly = TRUE)[[1]])
}
