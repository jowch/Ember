### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-01-01"
# ///

# %% id=S [setup]

# %% id=T
#' Let's fit a model with lm and take the mean.
#' A second line of prose.

# %% id=C
# Let's take the mean
x <- mean(c(1, 2, 3))
y <- lm(mpg ~ wt, mtcars)

# %% id=FN
# Drop rows with a **missing** value.
clean <- function(df, cols = names(df)) df[complete.cases(df[cols]), ]

# %% id=G
smooth <- s(wt)

# /// cell order
# S
# T
# C
# FN
# G
# ///
