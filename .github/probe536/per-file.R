# Per-file test times against the installed package, as the check runs
# them (NOT_CRAN unset). One line per file: file, elapsed s, failed, skipped.
lib <- commandArgs(TRUE)[1]
.libPaths(c(lib, .libPaths()))
library(testthat)
files <- sort(list.files("tests/testthat", "^test.*\\.R$"))
out <- data.frame()
for (f in files) {
  t0 <- proc.time()[["elapsed"]]
  r <- tryCatch(as.data.frame(testthat::test_file(file.path("tests/testthat", f), reporter = "silent", package = "ember", load_package = "installed", stop_on_failure = FALSE)), error = function(e) NULL)
  el <- proc.time()[["elapsed"]] - t0
  row <- data.frame(file = f, s = round(el, 1), failed = if (is.null(r)) NA else sum(r$failed), skipped = if (is.null(r)) NA else sum(r$skipped))
  print(row, row.names = FALSE)
  out <- rbind(out, row)
}
out <- out[order(-out$s), ]
cat("\n== per file, slowest first; total", sum(out$s), "s\n")
print(out, row.names = FALSE)
