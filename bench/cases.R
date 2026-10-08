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
# `inner` calls to a sample, as its median over `samples` samples.
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
  run_all_chain_2000 = list(
    setup = function() fake_state(make_chain_cells(2000)),
    run = function(s) step(s, ev_run(NULL, at(1))), inner = 1L)
))

rows <- lapply(names(cases), function(name) {
  case <- cases[[name]]
  secs <- tryCatch({
    x <- case$setup()
    env$time_median(function() case$run(x), samples = 7L, inner = case$inner)
  }, error = function(e) {
    message(name, ": ", conditionMessage(e))
    NA_real_
  })
  data.frame(case = name, seconds = secs)
})
utils::write.csv(do.call(rbind, rows), out, row.names = FALSE)
