# The installer subprocess. Started by the shell for `fx_install` and by
# `ensure_library()` for `ember::run()`, with the server's library (so renv
# is found) and Ember's renv cache. Never started in safe preview.
#
#   Rscript --vanilla installer.R <plan.rds>
#
# Plan: list(lock_lines, repos (name -> dated URL), r, staging, path, cache,
# github (the GitHub API GitHub packages install from)).
#
# Output on stdout, one per line, for the shell to turn into
# `ev_install_progress` (best effort: renv's own per-package reporting
# uses `cli` progress bars with no stable text to parse across versions,
# so this emits only a start and a finish line, not one per package; the
# manifest, not the progress, says what got installed):
#   EMBER-PROGRESS <done> <total> <package> <step>
#   EMBER-MISSING <what> <package> <detail>
# when a compiler or a system library is missing (install-checks.R).
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
  # A GitHub package's `Remotes` would have renv install those packages
  # from their repositories' moving HEAD, outside the lock; the lock alone
  # decides (each GitHub package needs its own [sources] entry).
  Sys.setenv(RENV_CONFIG_INSTALL_REMOTES = "FALSE")

  if (!is.null(ember:::read_library_manifest(plan$path))) {
    unlink(plan$staging, recursive = TRUE)
    return(invisible(NULL))
  }

  lock <- ember:::parse_lock_lines(plan$lock_lines)$lock
  wanted <- ember:::lock_versions(lock)
  total <- length(wanted)

  # renv's own Linux binary rewrite gets Bioconductor's URLs wrong
  # (`ppm_binary_repos()`), so they go in already rewritten, following
  # what renv's rewrite makes of the CRAN URL. `renv_ppm_transform` is
  # renv internal: if it is renamed, this falls back to the 404, and the
  # `[net]` S4Vectors test in test-packages-session.R is what catches it.
  cran_binary <- tryCatch(
    unname(utils::getFromNamespace("renv_ppm_transform", "renv")(plan$repos[["CRAN"]])),
    error = function(e) NULL)
  repos <- ember:::ppm_binary_repos(plan$repos, cran_binary)

  # A package that builds from source needs a compiler. Checked before
  # renv downloads anything, so a missing one says what to install
  # instead of failing a build minutes in (install-checks.R).
  linux_binaries <- !is.null(cran_binary) && grepl("/__linux__/", cran_binary)
  compiler <- ember:::compiler_check(lock, plan$repos, linux_binaries)
  if (!is.null(compiler)) stop_missing(plan, compiler = compiler)

  github <- if (is.null(plan$github)) "https://api.github.com" else plan$github
  deps <- ember:::github_install_deps(lock, plan$cache, github)
  lf <- ember:::renv_lockfile_of(lock, plan$r, repos, github = github, deps = deps)
  lockfile_tmp <- tempfile("ember-lockfile-", fileext = ".json")
  renv::lockfile_write(lf, file = lockfile_tmp)

  dir.create(plan$staging, recursive = TRUE, showWarnings = FALSE)
  project_dir <- tempfile("ember-install-project-")
  dir.create(project_dir, recursive = TRUE, showWarnings = FALSE)

  cat(sprintf("EMBER-PROGRESS 0 %d - restore\n", total))
  flush(stdout())

  # On Linux renv loads each binary it installs in a fresh R, and stops at
  # the first that fails: a missing system library then surfaces one
  # package per attempt, as a bare linker error. The check after renv
  # (`system_library_check()`) looks at every package at once and names
  # the command that installs what they need, so renv's own test is off.
  # Other load errors show up when a cell loads the package, as on macOS
  # and Windows, where renv never tests.
  Sys.setenv(RENV_INSTALL_TEST_LOAD = "FALSE")
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

  # Linux: every package finds the system libraries it links to. A
  # Package Manager binary installs without them and fails only when a
  # cell loads it, so this is the last moment to say what to install.
  syslibs <- ember:::system_library_check(plan$staging, lock, plan$repos)
  if (!is.null(syslibs)) stop_missing(plan, system = syslibs)

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

# Report a check that stopped the install (EMBER-MISSING lines and an
# `Error:` line, install-checks.R) and exit without making the library.
# On stderr: a session reads both streams as one, and `ensure_library()`
# shows stderr's last lines when it stops.
stop_missing <- function(plan, compiler = NULL, system = NULL) {
  writeLines(ember:::missing_report_lines(compiler = compiler, system = system), con = stderr())
  flush(stderr())
  unlink(plan$staging, recursive = TRUE)
  quit(status = 1L, save = "no")
}

if (!interactive()) {
  library(ember)
  main(commandArgs(trailingOnly = TRUE)[[1]])
}
