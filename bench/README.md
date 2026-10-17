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
rounds) and exits 1 when a case is more than 20% slower on head.
On GitHub's runners, seven runs of main against main (56 case readings) read from 0.91x
to 1.17x, and 95% of them at or under 1.06x (#179). So 20% leaves room
above identical code, and a case at 1.15x or more is still worth a
look. Against a slowdown of about 30% on every call, 20% misses a case
about 1 time in 30 on a quiet machine and 1 in 10 under load, where 25%
missed it about 1 time in 4 (#179). The `bench` workflow runs it on
every pull request that changes package code (R/, inst/, src/) or the
fixtures. It is a separate workflow so that it can stay out of the
required checks: a red `bench` means "look at this table", and a change that
is slower on purpose can merge with it red.

It can also be run by hand on any two refs (Actions, bench, Run workflow).
With both left at `main` it is an A/A run: both sides are the commit
`main` was at when the run was started, which shows how far apart one
runner reads the same build (#179).

To add a case, add its fixture to `helper-perf.R` (so the test and the
benchmark time the same notebook) and an entry to `cases.R`.
