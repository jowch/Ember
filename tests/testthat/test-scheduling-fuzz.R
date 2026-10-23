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

# Known failures, by mode and seed ("conflicts" first for the tests with
# edits that break the code), one or more per open issue: each must still
# fail at its step for its recorded reason, so a fix shows up here as a
# failure until its entry is removed, and any other failure is new. Their
# seeds run along with fuzz_seeds(), and a run with fewer steps than an
# entry's checks that its trace passes up to there. A known trace stops at
# its failure, so its later steps aren't checked. Entries look like
#   "lazy 30" = list(issue = 174, step = 5L, kind = "after running every cell, _ isn't fresh")
fuzz_known <- list(
  "conflicts lazy 285" = list(issue = 390, step = 18L, kind = "after running _, it isn't fresh"),
  "conflicts lazy 289" = list(issue = 390, step = 25L, kind = "after running _, it isn't fresh"))

known_seeds <- function(mode) {
  keys <- as.character(names(fuzz_known))
  prefix <- paste0(mode, " ")
  keys <- keys[startsWith(keys, prefix) & !grepl(" ", substring(keys, nchar(prefix) + 1))]
  as.integer(substring(keys, nchar(prefix) + 1))
}

expect_known_failure <- function(trace, known) {
  res <- fuzz_replay(trace)
  ok <- !is.null(res) && identical(res$step, known$step) && known$kind %in% fuzz_kind(res$problems)
  if (ok) return(succeed())
  got <- if (is.null(res)) "it passed" else
    paste0("it failed at step ", res$step, ": ", paste(res$problems, collapse = "; "))
  fail(paste0("seed ", trace$seed %||% "(fixed trace)", ", ", trace$mode, " mode was expected to fail at step ",
              known$step, " for #", known$issue, " (", known$kind, "), but ", got,
              ". If #", known$issue, " is fixed, remove its entry from fuzz_known."))
}

expect_trace_passes <- function(trace) {
  res <- fuzz_replay(trace)
  if (is.null(res)) return(succeed())
  label <- "Trace"
  if (!identical(Sys.getenv("EMBER_FUZZ_NO_SHRINK"), "1")) {
    trace <- fuzz_shrink(trace)
    res <- fuzz_replay(trace) %||% res
    label <- "Shrunk trace"
  }
  fail(paste0(
    "seed ", trace$seed %||% "(fixed trace)", ", ", trace$mode, " mode, step ", res$step, ":\n",
    paste0("  ", res$problems, collapse = "\n"),
    "\n", label, ":\n", fuzz_format(trace)))
}

for (mode in c("autorun", "lazy")) {
  test_that(paste("random edits and runs match a run from scratch,", mode, "mode"), {
    for (seed in union(fuzz_seeds(), known_seeds(mode))) {
      trace <- fuzz_trace(seed, mode, steps = fuzz_steps())
      known <- fuzz_known[[paste(mode, seed)]]
      if (!is.null(known) && fuzz_steps() >= known$step) expect_known_failure(trace, known)
      else expect_trace_passes(trace)
    }
  })
}

# The same, with edits that break the code too: a name defined in two cells,
# a cycle, a parse error, a cell reading its own variable, and undoing them.
# Each step is one edit, run as submitted. A cell that can't run must show
# a graph error, and everything else is checked as above. Known failures
# here are keyed "conflicts <mode> <seed>".
for (mode in c("autorun", "lazy")) {
  test_that(paste("random edits that break the code match a run from scratch,", mode, "mode"), {
    for (seed in union(fuzz_seeds(), known_seeds(paste("conflicts", mode)))) {
      trace <- fuzz_trace(seed, mode, steps = fuzz_steps(), conflicts = TRUE)
      known <- fuzz_known[[paste("conflicts", mode, seed)]]
      if (!is.null(known) && fuzz_steps() >= known$step) expect_known_failure(trace, known)
      else expect_trace_passes(trace)
    }
  })
}

# Regression tests: shrunk traces of what the random runs found.

test_that("autorun runs a queued dependent's stale ancestors first (#176)", {
  expect_trace_passes(list(mode = "autorun",
    cells = list(C1 = "v1 <- 1", C2 = "v2 <- v1 + 1", C3 = "v3 <- 10", C4 = "v2 + v3"),
    steps = list(list(ops = list(), run = "all"),
                 list(ops = list(list(op = "delete", cell = "C1"),
                                 list(op = "set_code", cell = "C3", code = "v3 <- 20")), run = "C3"))))
})

test_that("a staged edit that drops a reference or a definition doesn't hide staleness (#175)", {
  staged <- function(mode, code) list(mode = mode,
    cells = list(C1 = "v1 <- 1", C2 = "v2 <- v1 + 1", C3 = "v2 * 10"),
    steps = list(list(ops = list(), run = "all"),
                 list(ops = list(list(op = "set_code", cell = "C2", code = code),
                                 list(op = "set_code", cell = "C1", code = "v1 <- 2")), run = "C1")))
  for (mode in c("autorun", "lazy")) {
    expect_trace_passes(staged(mode, "v2 <- 5"))        # drops the reference to v1
    expect_trace_passes(staged(mode, "v3 <- v1 + 1"))   # drops the definition of v2
  }
})

test_that("a cell edited since it ran goes before what read its old code (#174)", {
  for (mode in c("autorun", "lazy")) {
    # Run all after a rename: the old reader comes first in the file.
    expect_trace_passes(list(mode = mode,
      cells = list(C2 = "v2 <- v1 + 1", C1 = "v1 <- 1", C3 = "v2 * 10"),
      steps = list(list(ops = list(), run = "all"),
                   list(ops = list(list(op = "set_code", cell = "C1", code = "v4 <- 1")), run = "all"))))
    # A hand run that pulls in an edited ancestor the file puts after it.
    expect_trace_passes(list(mode = mode,
      cells = list(C1 = "v4 <- 1", C5 = "v7 <- (5 + 1 * v6) %% 997", C4 = "v6 <- (36 + 1 * v4) %% 997"),
      steps = list(list(ops = list(), run = "all"),
                   list(ops = list(list(op = "set_code", cell = "C4", code = "v11 <- (36 + 1 * v4) %% 997")), run = "C5"))))
  }
})

test_that("a cell newly marked stale by a changed upstream error marks what read from it", {
  # C2 gets a parse error, so C4 and C5 blame it; deleting C2 marks C4
  # stale, and C5 read from C4.
  expect_trace_passes(list(mode = "autorun",
    cells = list(C4 = "v4 <- (10 + 1 * v2 + 2 * v3) %% 997", C2 = "v2 <- (43 + 1 * v1) %% 997",
                 C5 = "v5 <- (16 + 1 * v4) %% 997"),
    steps = list(list(ops = list(), run = "C5"),
                 list(ops = list(list(op = "set_code", cell = "C2", code = "v2 <- (43 + 1 * v1) %% 997\n(")), run = "C2"),
                 list(ops = list(list(op = "delete", cell = "C2")), run = NULL))))
  # C4 defines v4 as C3 does, so C7 blames C4; renaming C3's v4 clears
  # that and marks C7 stale, and C6 read from C7.
  expect_trace_passes(list(mode = "autorun",
    cells = list(C3 = "v4 <- (2 + 1 * v2) %% 997", C4 = "v5 <- (87 + 1 * v1) %% 997", C6 = "stop(\"fail 73\")"),
    steps = list(list(ops = list(list(op = "insert", index = 4L, id = "C7", code = "v8 <- (34 + 1 * v2 + 2 * v5) %% 997")), run = NULL),
                 list(ops = list(list(op = "set_code", cell = "C4", code = "v4[1] <- 63\nv5 <- (87 + 1 * v1) %% 997")), run = NULL),
                 list(ops = list(list(op = "set_code", cell = "C6", code = "(53 + 1 * v8) %% 997")), run = "C6"),
                 list(ops = list(list(op = "set_code", cell = "C3", code = "v9 <- (2 + 1 * v2) %% 997")), run = NULL))))
})

test_that("a hand run can leave a cell stale through a cell that can't run (#390)", {
  # C4 defines v7 as C7 does; running C13 runs C2 and C3 after it, and
  # their stale walk reaches C13 through C4.
  expect_known_failure(list(mode = "lazy",
    cells = list(C2 = "v2 <- (68 + 1 * v1) %% 997", C3 = "v3 <- (36 + 1 * v1) %% 997",
                 C4 = "v4 <- (65 + 1 * v2 + 2 * v3) %% 997", C5 = "v5 <- (30 + 1 * v4) %% 997",
                 C7 = "v7 <- (43 + 1 * v5 + 2 * v6) %% 997"),
    steps = list(list(ops = list(list(op = "set_code", cell = "C5", code = "v11 <- (30 + 1 * v4) %% 997"),
                                 list(op = "set_code", cell = "C7", code = "v7 <- (43 + 1 * v11 + 2 * v6) %% 997")), run = NULL),
                 list(ops = list(list(op = "set_code", cell = "C4", code = "v7[1] <- 64\nv4 <- (65 + 1 * v2 + 2 * v3) %% 997")), run = NULL),
                 list(ops = list(list(op = "insert", index = 3L, id = "C13", code = "v19 <- (6 + 1 * v12 + 2 * v11) %% 997")), run = "C13"))),
    list(issue = 390, step = 3L, kind = "after running _, it isn't fresh"))
  # The same through a cycle (C6 and C10).
  expect_known_failure(list(mode = "lazy",
    cells = list(C2 = "v2 <- (15 + 1 * v1) %% 997", C5 = "v5 <- (28 + 1 * v4) %% 997", C6 = "v6 <- (21 + 1 * v4) %% 997"),
    steps = list(list(ops = list(list(op = "insert", index = 7L, id = "C10",
                                      code = "v10 <- (30 + 1 * v9 + 2 * v1 + 3 * v5) %% 997\nv11 <- (v10 * 3 + 30) %% 997")), run = NULL),
                 list(ops = list(list(op = "set_code", cell = "C6", code = "v1 <- 41\nv6 <- (36 + 1 * v11 + 2 * v1 + 3 * v10) %% 997")), run = NULL),
                 list(ops = list(list(op = "insert", index = 5L, id = "C11", code = "v12 <- (59 + 1 * v3 + 2 * v8 + 3 * v2) %% 997")), run = "C11"))),
    list(issue = 390, step = 3L, kind = "after running _, its ancestor _ isn't fresh"))
})
