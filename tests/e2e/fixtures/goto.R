### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-01-01"
# ///

# %% id=S

# %% id=A
total.n <- 10
tiny <- 1

# %% id=B
y <- total.n + tiny + mean(1)

# %% id=R
`r<-` <- function(x, value) value

# %% id=W
w <- 1
r(w) <- 3

# /// cell order
# S
# A
# B
# R
# W
# ///
