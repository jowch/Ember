# Randomized scheduling test: random notebooks (chains, diamonds, fans,
# cells defining several names), random edits (edit, rename, delete, insert,
# move, several edits before a run), in autorun and lazy mode. After each
# step every cell's output and stale mark is checked against a run of the
# notebook from scratch (helper-fuzz.R). Seeds are fixed, so a failure
# replays; its message prints the shrunk trace, which goes below as an
# ordinary regression test once the bug is fixed.
#
# More seeds and steps for a long local run (EMBER_FUZZ_NO_SHRINK=1 reports
# the whole trace without shrinking it, which is much faster):
#   EMBER_FUZZ_SEEDS=1:200 EMBER_FUZZ_STEPS=30 Rscript -e 'testthat::test_local(filter = "scheduling-fuzz")'

fuzz_seeds <- function() {
  s <- Sys.getenv("EMBER_FUZZ_SEEDS")
  # Seeds 3 (lazy) and 6 (autorun) find #174 and #176; they join these
  # with the fixes.
  if (nzchar(s)) eval(parse(text = s), baseenv()) else c(1, 2, 4)
}
fuzz_steps <- function() {
  s <- Sys.getenv("EMBER_FUZZ_STEPS")
  if (nzchar(s)) as.integer(s) else 12L
}

expect_trace_passes <- function(trace) {
  fail <- fuzz_replay(trace)
  if (is.null(fail)) return(succeed())
  label <- "Trace"
  if (!identical(Sys.getenv("EMBER_FUZZ_NO_SHRINK"), "1")) {
    trace <- fuzz_shrink(trace)
    fail <- fuzz_replay(trace) %||% fail
    label <- "Shrunk trace"
  }
  fail(paste0(
    "seed ", trace$seed %||% "(fixed trace)", ", ", trace$mode, " mode, step ", fail$step, ":\n",
    paste0("  ", fail$problems, collapse = "\n"),
    "\n", label, ":\n", fuzz_format(trace)))
}

for (mode in c("autorun", "lazy")) {
  test_that(paste("random edits and runs match a run from scratch,", mode, "mode"), {
    for (seed in fuzz_seeds()) {
      expect_trace_passes(fuzz_trace(seed, mode, steps = fuzz_steps()))
    }
  })
}
