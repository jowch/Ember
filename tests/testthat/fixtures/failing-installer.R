# A stand-in for inst/installer.R (`options(ember.installer_script = ...)`,
# R/library.R's `installer_script()`): prints a captured renv failure for a
# package called "brokenpkg", over about a second, with a `Sys.sleep()`
# between each line so `poll_jobs()` (R/library.R) reads several chunks
# while the process is still alive, then exits 1. Never writes a manifest
# and never renames anything into place: the target library stays missing
# on disk, matching what a real failed renv restore leaves behind.
#
#   Rscript --vanilla failing-installer.R <plan.rds>

LINES <- c(
  "- Installing brokenpkg ...",
  "Downloading packages -------------------------------------------------",
  "Downloading brokenpkg from Repository ...",
  "Downloaded brokenpkg (0.1.0)",
  "Installing brokenpkg ...",
  "* installing *source* package 'brokenpkg' ...",
  "** using staged installation",
  "** libs",
  "clang -c brokenpkg.c -o brokenpkg.o",
  "brokenpkg.c:3:10: fatal error: 'nonexistent.h' file not found",
  "#include <nonexistent.h>",
  "         ^~~~~~~~~~~~~~~~",
  "1 error generated.",
  "make: *** [brokenpkg.o] Error 1",
  "ERROR: compilation failed for package \u2018brokenpkg\u2019",
  "* removing '/tmp/does-not-exist/brokenpkg'",
  "Error: failed to install \"brokenpkg\"",
  "Execution halted"
)

main <- function(plan_path) {
  for (line in LINES) {
    cat(line, "\n", sep = "")
    flush(stdout())
    Sys.sleep(0.06)
  }
  quit(save = "no", status = 1L)
}

if (!interactive()) {
  main(commandArgs(trailingOnly = TRUE)[[1]])
}
