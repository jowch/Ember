### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-01-01"
# ///

# %% id=S [setup]

# %% id=A
x <- 1:10

# %% id=B
sum(x)

# %% id=ERR
stop("boom")

# %% id=LOOP
t0 <- Sys.time()
while (Sys.time() - t0 < 8) NULL

# %% id=MD [markdown]
#' # Hello
#'
#' Some *markdown*.

# /// cell order
# S
# A
# B
# ERR
# LOOP
# MD
# ///
