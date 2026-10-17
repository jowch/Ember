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
  if (nzchar(s)) eval(parse(text = s), baseenv()) else 1:6
}
fuzz_steps <- function() {
  s <- Sys.getenv("EMBER_FUZZ_STEPS")
  if (nzchar(s)) as.integer(s) else 12L
}

# Known failures, by mode and seed (at the default 12 steps): each must
# still fail at its step for its recorded reason, so a fix shows up here as
# a failure until its entry is removed, and any other failure is new.
fuzz_known <- list(
  "lazy 3" = list(issue = 174, step = 4L, kind = "after running every cell, _ isn't fresh"),
  "autorun 6" = list(issue = 176, step = 10L, kind = "_ isn't stale but reads from _, which is")
)

expect_known_failure <- function(trace, known) {
  fail <- fuzz_replay(trace)
  ok <- !is.null(fail) && identical(fail$step, known$step) && known$kind %in% fuzz_kind(fail$problems)
  if (ok) return(succeed())
  got <- if (is.null(fail)) "it passed" else
    paste0("it failed at step ", fail$step, ": ", paste(fail$problems, collapse = "; "))
  fail(paste0("seed ", trace$seed, ", ", trace$mode, " mode was expected to fail at step ",
              known$step, " for #", known$issue, " (", known$kind, "), but ", got,
              ". If #", known$issue, " is fixed, remove its entry from fuzz_known."))
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
      trace <- fuzz_trace(seed, mode, steps = fuzz_steps())
      known <- fuzz_known[[paste(mode, seed)]]
      if (!is.null(known) && fuzz_steps() >= known$step) expect_known_failure(trace, known)
      else expect_trace_passes(trace)
    }
  })
}
