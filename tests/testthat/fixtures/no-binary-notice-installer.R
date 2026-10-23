# A stand-in for inst/installer.R (`options(ember.installer_script = ...)`,
# R/library.R's `installer_script()`) that says, as the real installer
# does before renv starts, that two packages have no binary for this R
# and build from source (#19, `source_only_packages()`), then stays busy
# as if building them, so tests can look at the session mid-install. The
# session kills it when the notebook closes (`job_leave()`); left alone it
# fails after ten minutes, so a lost one doesn't stay forever. Never writes
# a manifest.
#
#   Rscript --vanilla no-binary-notice-installer.R <plan.rds>

main <- function(plan_path) {
  cat("EMBER-PROGRESS 0 2 - restore\n")
  cat("EMBER-NO-BINARY brokenpkg=0.1.0 rlang=1.1.3\n")
  flush(stdout())
  for (i in seq_len(6000)) Sys.sleep(0.1)
  quit(save = "no", status = 1L)
}

if (!interactive()) {
  main(commandArgs(trailingOnly = TRUE)[[1]])
}
