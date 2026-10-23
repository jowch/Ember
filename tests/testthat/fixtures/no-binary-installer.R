# A stand-in for inst/installer.R (`options(ember.installer_script = ...)`)
# whose renv build of "brokenpkg" failed, and the package had no binary
# for this R (R/install-checks.R, #19): prints the notice the installer
# gives before renv starts (EMBER-NO-BINARY), the build's ERROR line on
# stdout, then renv's error, the EMBER-MISSING line and the Error line on
# stderr, as the real installer does, then exits 1. Never writes a
# manifest.
#
#   Rscript --vanilla no-binary-installer.R <plan.rds>

main <- function(plan_path) {
  cat("EMBER-NO-BINARY brokenpkg=0.1.0\n")
  cat("* installing *source* package 'brokenpkg' ...\n")
  cat("ERROR: compilation failed for package 'brokenpkg'\n")
  flush(stdout())
  Sys.sleep(0.2)
  writeLines(c(
    "Error: failed to install \"brokenpkg\"",
    "EMBER-MISSING binary brokenpkg 0.1.0",
    paste("Error: brokenpkg 0.1.0 has no binary for R 4.6.1, so it was built from source,",
          "and it doesn't build on R 4.6.1.")
  ), con = stderr())
  quit(save = "no", status = 1L)
}

if (!interactive()) {
  main(commandArgs(trailingOnly = TRUE)[[1]])
}
