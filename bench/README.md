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

Each process times a case 15 times and keeps its fastest sample, each
sample at least 50 ms long (enough calls of a fast case to cover the 1 ms
clock). The fastest, not the median: noise on a shared runner only adds
time, and the first samples in a fresh process run slower than later
ones, so the median of a few samples moved by up to 26% between
identical builds while the fastest moved by under 10% (#163). A change
that makes every call slower still moves the fastest sample. A change
that only makes some calls slower, such as more garbage collection,
may not, and the tests in `tests/testthat` don't time that either.

It prints a table of each case's time on both sides (the median over
rounds) and exits 1 when a case is more than 25% slower on head.
Identical builds read within 5% of each other on a 4-core cloud
container under a bursty background load. A build with about 30% added
to each timed call fails, with six of the seven slowed cases flagged at
1.26x to 1.50x (#163). A slowdown near 30% can still read under 25% on a
single case, so treat a case in the 1.15x to 1.25x range as worth a
look; anything under 25% shows in the table but doesn't fail. The `bench` workflow runs it on
every pull request that changes package code (R/, inst/, src/) or the
fixtures. It is a separate workflow so that it can stay out of the
required checks: a red `bench` means "look at this table", and a change that
is slower on purpose can merge with it red.

To add a case, add its fixture to `helper-perf.R` (so the test and the
benchmark time the same notebook) and an entry to `cases.R`.
