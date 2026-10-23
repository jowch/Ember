### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-01-01"
# ///

# %% id=LONG
cat(strrep("a long line of printed output ", 12), "\n")

# %% id=MD [markdown]
#' # UI sweep
#'
#' One of each kind of output, for the layout checks in
#' `tests/ui-sweep.test.mjs` and the screenshots in `shots.mjs`.
#' The first cell is a code cell with no upstream, so it stays unrun
#' when only `B` runs (#284).

# %% id=A
x <- 1:10

# %% id=B
sum(x)

# %% id=WIDE
data.frame(
  id = seq_len(40),
  name = sprintf("row %d", seq_len(40)),
  group = rep(c("alpha", "beta", "gamma", "delta"), 10),
  value = round(sin(seq_len(40)), 3),
  flag = rep(c(TRUE, FALSE), 20),
  note = strrep("a long note that makes the table wider than the cell ", 3)
)

# %% id=PLT
plot(x, x^2, type = "b")

# %% id=ERR
stop("boom: a deliberate error")

# %% id=DOWN
x * 2

# /// cell order
# LONG
# MD
# A
# B
# WIDE
# PLT
# ERR
# DOWN
# ///
