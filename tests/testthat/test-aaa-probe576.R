# Probe for #576, not for merging: why fst won't load in Ember's worker on macOS.
test_that("probe #576", {
  skip_on_os(c("windows", "linux"))
  sh <- function(cmd, args) paste(c(paste("$", cmd, paste(args, collapse = " ")),
                                    tryCatch(system2(cmd, args, stdout = TRUE, stderr = TRUE), error = conditionMessage)), collapse = "\n")
  so <- system.file("libs", "fstcore.so", package = "fstcore")
  rs <- file.path(R.home("bin"), "Rscript")
  r <- file.path(R.home("bin"), "R")
  out <- c(
    paste("env:", paste(grep("^(DYLD|OMP|R_LIBS|KMP|R_HOME)", names(Sys.getenv()), value = TRUE), Sys.getenv(grep("^(DYLD|OMP|R_LIBS|KMP|R_HOME)", names(Sys.getenv()), value = TRUE)), sep = "=", collapse = "; ")),
    paste("dlls before:", paste(names(getLoadedDLLs()), collapse = ",")),
    sh("otool", c("-L", shQuote(so))),
    sh("sh", c("-c", shQuote(paste("nm -u", shQuote(so), "| grep -i kmpc | head -3")))),
    sh("sh", c("-c", shQuote(paste("ls", shQuote(R.home("lib")))))),
    sh(rs, c("-e", shQuote("library(fst); cat('rscript fresh: ok\\n')"))),
    sh(rs, c("-e", shQuote("loadNamespace('data.table'); library(fst); cat('rscript after data.table: ok\\n')"))),
    sh(r, c("--vanilla", "--no-echo", "-e", shQuote("library(fst); cat('R --vanilla fresh: ok\\n')"))),
    paste("in-process requireNamespace(fst):", tryCatch(requireNamespace("fst"), error = conditionMessage)),
    paste("dlls after:", paste(names(getLoadedDLLs()), collapse = ",")))
  expect_true(FALSE, info = paste(out, collapse = "\n\n"))
})
