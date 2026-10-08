### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-01-01"
# ///

# %% id=S

# %% id=FN
# Drop rows with a missing value.
clean <- function(df) df[complete.cases(df), ]

# /// cell order
# S
# FN
# ///
