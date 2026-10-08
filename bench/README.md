# Benchmarks

The performance tests in `tests/testthat` never hold a call to a fixed
number of milliseconds: shared CI runners vary too much for that, and those
limits failed with no code change behind them. Each test compares two
timings from the same run instead (the same call at two sizes, or the cheap
path against the expensive one it avoids), which catches a change in shape,
such as a linear pass turning quadratic, on any machine.

A change of the same shape that is only slower, like the one PR #3 put into
`pluto_state()` at 2000 cells (33 ms to 41 ms on the machine that found it,
12-17% on a cloud container), is invisible to those tests. That one came
from a call made once per cell, which `test-pluto-state.R` now catches by
counting calls. This directory is for slowdowns no count points at: it
times the same fixtures (`tests/testthat/helper-perf.R`) on a pull request
and on its base branch, on one machine, in alternating fresh R processes:

```sh
R CMD INSTALL --library=/tmp/lib-base path/to/base/checkout
R CMD INSTALL --library=/tmp/lib-head .
Rscript bench/compare.R /tmp/lib-base path/to/base/checkout /tmp/lib-head .
```

It prints a table of each case's median time on both sides and exits 1
when a case is more than 25% slower on head. Two identical builds read
within about 8% of each other on a 4-core cloud container, so 25% is about
the smallest change it can flag without flagging noise; anything smaller
shows in the table but doesn't fail. The `bench` workflow runs it on
every pull request that changes package code (R/, inst/, src/) or the
fixtures. It is a separate workflow so that it can stay out of the
required checks: a red `bench` means "look at this table", and a change that
is slower on purpose can merge with it red.

To add a case, add its fixture to `helper-perf.R` (so the test and the
benchmark time the same notebook) and an entry to `cases.R`.
