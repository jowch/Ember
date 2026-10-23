### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-09-01"
# ///

# %% id=L
library(emberui)

# %% id=I
n <- input_slider(1L, 10L, 5L)
method <- input_select(c(Pearson = "pearson", Spearman = "spearman"))
show <- input_checkbox(TRUE, label = "Show points")
title <- input_text("Results")
round(input_number(2))

# %% id=B
paste(n, method, show, title)

# /// cell order
# L
# I
# B
# ///
