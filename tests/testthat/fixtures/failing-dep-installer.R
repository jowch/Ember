# A stand-in for inst/installer.R (`options(ember.installer_script = ...)`,
# R/library.R's `installer_script()`): failing-installer.R's captured renv
# failure, for toyB, the toy repository's dependency of toyA (#17), over
# about a second, with a `Sys.sleep()` between each line so `poll_jobs()` (R/library.R) reads several chunks
# while the process is still alive, then exits 1. Never writes a manifest
# and never renames anything into place: the target library stays missing
# on disk, matching what a real failed renv restore leaves behind.
#
#   Rscript --vanilla failing-dep-installer.R <plan.rds>

LINES <- c(
  "- Installing toyB ...",
  "Downloading packages -------------------------------------------------",
  "Downloading toyB from Repository ...",
  "Downloaded toyB (0.1.0)",
  "Installing toyB ...",
  "* installing *source* package 'toyB' ...",
  "** using staged installation",
  "** libs",
  "clang -c toyB.c -o toyB.o",
  "toyB.c:3:10: fatal error: 'nonexistent.h' file not found",
  "#include <nonexistent.h>",
  "         ^~~~~~~~~~~~~~~~",
  "1 error generated.",
  "make: *** [toyB.o] Error 1",
  "ERROR: compilation failed for package \u2018toyB\u2019",
  "* removing '/tmp/does-not-exist/toyB'",
  "Error: failed to install \"toyB\"",
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
