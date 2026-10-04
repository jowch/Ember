### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-01-01"
# ///

# %% id=S [setup]

# %% id=A
x <- 1

# %% id=B
x + 1

# %% id=F
f <- function(d) lm(mpg ~ wt, data = d)

# %% id=ERR
bad <- list(mpg = 1, wt = list(1)); g <- function(d) f(d); g(bad)

# %% id=TOP
y <- 2
stop("boom")

# %% id=LOOP
Sys.sleep(3)

# %% id=NEVER
3 + 3

# /// cell order
# S
# A
# B
# F
# ERR
# TOP
# LOOP
# NEVER
# ///
