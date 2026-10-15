# A stand-in for inst/installer.R (`options(ember.installer_script = ...)`)
# whose system-library check stopped the install (R/install-checks.R):
# prints the EMBER-MISSING line and the Error line for a package called
# "brokenpkg" on stderr, as the real installer does, then exits 1. Never
# writes a manifest.
#
#   Rscript --vanilla missing-system-installer.R <plan.rds>

main <- function(plan_path) {
  cat("- Installing brokenpkg ...\n")
  flush(stdout())
  Sys.sleep(0.2)
  writeLines(c(
    "EMBER-MISSING system brokenpkg sudo apt-get install -y libbroken-dev",
    paste("Error: brokenpkg needs system libraries that aren't installed (libbroken.so.1).",
          "Install them with `sudo apt-get install -y libbroken-dev`, then try again.")
  ), con = stderr())
  quit(save = "no", status = 1L)
}

if (!interactive()) {
  main(commandArgs(trailingOnly = TRUE)[[1]])
}
