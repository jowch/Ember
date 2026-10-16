# A stand-in for inst/installer.R (`options(ember.installer_script = ...)`)
# whose system-library check found binaries that don't fit this system
# (#76, R/install-checks.R): toyA, the package failing-dep.R loads, was
# built for a newer system, and toyB, its dependency, against another
# version of a library. Prints the lines `missing_report_lines()` makes
# on stderr, as the real installer does, then exits 1. Never writes a
# manifest.
#
#   Rscript --vanilla mismatch-installer.R <plan.rds>

main <- function(plan_path) {
  cat("- Installing toyA ...\n")
  flush(stdout())
  Sys.sleep(0.2)
  writeLines(c(
    "EMBER-MISSING newer toyA GLIBC_2.38 /lib/x86_64-linux-gnu/libc.so.6",
    "EMBER-MISSING soname toyB libtoy.so.1=libtoy.so.2",
    paste("Error: toyA was built for a newer system than this one, and needs GLIBC_2.38 from libraries",
          "here that are older (/lib/x86_64-linux-gnu/libc.so.6). toyB was built against libtoy.so.1,",
          "and this system has libtoy.so.2 instead. The install command would install the version",
          "already here: if your Linux has a package that provides libtoy.so.1, install that, then try again.")
  ), con = stderr())
  quit(save = "no", status = 1L)
}

if (!interactive()) {
  main(commandArgs(trailingOnly = TRUE)[[1]])
}
