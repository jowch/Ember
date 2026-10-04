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

# %% id=W
message("Reading")
h <- function() warning("careful")
h()
cat("\033[32mok\033[39m \033[38;5;246mgrey\033[39m\n")
1

# %% id=NA
data.frame(a = c(1, NA), b = c("x", NA))

# %% id=VEC
list(a = 1, long = 1:100, sub = list(c = "x"))

# /// cell order
# S
# A
# B
# F
# ERR
# TOP
# LOOP
# NEVER
# W
# NA
# VEC
# ///
