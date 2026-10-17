# One pass over the benchmark cases against the ember installed in a given
# library: `Rscript bench/cases.R <lib> <checkout> <out.csv>`. compare.R
# runs this alternately against a pull request's base and head; see
# bench/README.md.
#
# The fixtures are the performance tests' own (tests/testthat/helper-perf.R
# and helper-core.R), evaluated inside the installed ember's namespace. They
# come from `<checkout>`, the source that ember was installed from, so a
# change to a constructor's arguments doesn't break the other side; a
# checkout older than helper-perf.R borrows this checkout's copy. A case
# that still fails on one side is reported as not compared.

args <- commandArgs(trailingOnly = TRUE)
lib <- args[[1]]; checkout <- args[[2]]; out <- args[[3]]
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE))))
helper <- function(f) {
  own <- file.path(checkout, "tests", "testthat", f)
  if (file.exists(own)) own else file.path(here, "..", "tests", "testthat", f)
}

ns <- loadNamespace("ember", lib.loc = lib)
env <- new.env(parent = ns)
for (f in c("helper-core.R", "helper-perf.R")) sys.source(helper(f), envir = env)

# Each case: `setup()` builds the input once, untimed; `run(x)` is timed,
# `inner` calls to a sample at least (more if a sample would last under
# MIN_SAMPLE_SECS), and the case's time is its fastest of SAMPLES samples.
cases <- local(envir = env, list(
  pluto_state_one_change_2000 = list(
    setup = function() perf_projection(2000),
    run = function(x) pluto_state(x$state, x$previous), inner = 3L),
  pluto_state_one_change_2000_with_results = list(
    setup = function() perf_projection(2000, results = TRUE),
    run = function(x) pluto_state(x$state, x$previous), inner = 3L),
  step_no_rebuild_2000 = list(
    setup = function() perf_running(2000),
    run = function(st) step(st, wk_done(1, st$worker$running$token, report(), at(10))), inner = 3L),
  fb_diff_one_change_2000 = list(
    setup = function() perf_diff_pair(2000),
    run = function(x) fb_diff(x$old, x$new), inner = 10L),
  packages_view_150 = list(
    setup = function() perf_packages(150),
    run = function(st) packages_view(st), inner = 10L),
  graph_edit_2000 = list(
    setup = function() perf_graph_edit(2000),
    run = function(x) notebook_graph(x$code, previous = x$previous), inner = 1L),
  run_all_chain_2000 = list(
    setup = function() fake_state(make_chain_cells(2000)),
    run = function(s) step(s, ev_run(NULL, at(1))), inner = 1L),
  # One worker message during Run all: the step, then what the shell
  # derives from it (#44).
  worker_message_2000 = list(
    setup = function() {
      st <- perf_running(2000)
      list(st = st, done = wk_done(1, st$worker$running$token, report(), at(10)))
    },
    run = function(x) { r <- step(x$st, x$done); notifications(x$st, r$state) }, inner = 1L)
))

# The fastest sample, not the median: noise on a shared runner (another
# job, a GC, the first calls before R has compiled the code) only ever
# adds time, so the minimum moves least between two runs of the same code,
# while a change that makes every call slower still moves it (#163). A
# sample lasts at least MIN_SAMPLE_SECS so the clock's 1 ms ticks stay a
# small part of it.
SAMPLES <- 15L
MIN_SAMPLE_SECS <- 0.05

time_calls <- function(f, inner) {
  t0 <- proc.time()[["elapsed"]]
  for (i in seq_len(inner)) f()
  proc.time()[["elapsed"]] - t0
}

time_min <- function(f, inner) {
  f()
  while (inner < 1e6 && time_calls(f, inner) < MIN_SAMPLE_SECS) inner <- inner * 2L
  min(vapply(seq_len(SAMPLES), function(i) time_calls(f, inner), numeric(1))) / inner
}

rows <- lapply(names(cases), function(name) {
  case <- cases[[name]]
  secs <- tryCatch({
    x <- case$setup()
    time_min(function() case$run(x), case$inner)
  }, error = function(e) {
    message(name, ": ", conditionMessage(e))
    NA_real_
  })
  data.frame(case = name, seconds = secs)
})
utils::write.csv(do.call(rbind, rows), out, row.names = FALSE)
