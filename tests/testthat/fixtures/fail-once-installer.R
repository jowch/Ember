# A stand-in for inst/installer.R (`options(ember.installer_script = ...)`)
# that fails once, then installs for real (#106). The first run stops the
# way the system-library check does (R/install-checks.R): an EMBER-MISSING
# line and an Error line for toyB, the toy repository's dependency of
# toyA, then exit 1. It leaves a marker under R_USER_DATA_DIR, which
# tests/e2e/server.mjs gives each server a folder of its own, so every
# later run hands the plan to the real installer, as if the user had
# installed the missing library in between.
#
#   Rscript --vanilla fail-once-installer.R <plan.rds>

main <- function(plan_path) {
  marker <- file.path(Sys.getenv("R_USER_DATA_DIR"), "fail-once-installer-ran")
  if (!file.exists(marker)) {
    file.create(marker)
    cat("- Installing toyB ...\n")
    flush(stdout())
    writeLines(c(
      "EMBER-MISSING system toyB libtoy.so.1 sudo apt-get install -y libtoy-dev",
      paste("Error: toyB needs system libraries that aren't installed (libtoy.so.1).",
            "Install them with `sudo apt-get install -y libtoy-dev`, then try again.")
    ), con = stderr())
    quit(save = "no", status = 1L)
  }
  rscript <- file.path(R.home("bin"), "Rscript")
  status <- system2(rscript, c("--vanilla", shQuote(system.file("installer.R", package = "ember")), shQuote(plan_path)))
  quit(save = "no", status = status)
}

if (!interactive()) {
  main(commandArgs(trailingOnly = TRUE)[[1]])
}
