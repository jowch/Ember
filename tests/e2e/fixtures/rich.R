### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-01-01"
# ///

# %% id=S [setup]
print.ansi_demo <- function(x, ...) {
  cat("\033[32mgreen\033[39m\n")
  invisible(x)
}

# %% id=DF
df <- mtcars

# %% id=TBL
df

# %% id=FIT
lm(mpg ~ wt, df)

# %% id=LST
list(a = 1, b = list(c = "x"), long = as.list(1:100))

# %% id=PLT
plot(1:10)

# %% id=ANSI
cat("\033[31mred\033[39m\n")
structure("x", class = "ansi_demo")

# %% id=PARSE
x <- (

# %% id=MD [markdown]
#' # Rich outputs
#'
#' A fenced R block:
#'
#' ```r
#' 1 + 1
#' ```

# /// cell order
# S
# DF
# TBL
# FIT
# LST
# PLT
# ANSI
# PARSE
# MD folded
# ///
