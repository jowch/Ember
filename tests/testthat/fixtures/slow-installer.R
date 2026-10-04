# A stand-in for inst/installer.R (`options(ember.installer_script = ...)`,
# R/library.R's `installer_script()`) that stays busy for 30 seconds and
# then fails, so the e2e suite can look at the Packages tab mid-install.
#
#   Rscript --vanilla slow-installer.R <plan.rds>

main <- function(plan_path) {
  cat("- Installing brokenpkg ...\n")
  flush(stdout())
  for (i in seq_len(300)) Sys.sleep(0.1)
  quit(save = "no", status = 1L)
}

if (!interactive()) {
  main(commandArgs(trailingOnly = TRUE)[[1]])
}
