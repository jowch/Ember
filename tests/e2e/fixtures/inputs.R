### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-09-01"
# ///

# %% id=L
library(emberui)

# %% id=N
n <- input_slider(1L, 10L, 5L)

# %% id=M
method <- input_select(c(Pearson = "pearson", Spearman = "spearman"))

# %% id=CB
show <- input_checkbox(TRUE, label = "Show points")

# %% id=TX
title <- input_text("Results")

# %% id=K
k <- input_number(5L, min = 0L, max = 10L)

# %% id=J
pick <- input_radio(c("x", "y"), selected = "y")

# %% id=R
other <- input_radio(c("p", "q"))

# %% id=X
q <- input_slider(1, 3, 2)
round(input_number(2))

# %% id=B
paste(n, method, show, title, k, pick)

# /// cell order
# L
# N
# M
# CB
# TX
# K
# J
# R
# X
# B
# ///
