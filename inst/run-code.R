# Runs the R code in EMBER_RUN_CODE: how Ember starts an Rscript of its own
# (shell.R's rscript_command(), #512), instead of `Rscript -e`, which on
# Windows leaves an Rscript<hex> file in the temp folder when killed.
local({
  code <- Sys.getenv("EMBER_RUN_CODE")
  Sys.unsetenv("EMBER_RUN_CODE")
  eval(parse(text = code), envir = globalenv())
})
