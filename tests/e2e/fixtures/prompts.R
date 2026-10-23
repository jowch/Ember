### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-01-01"
# ///

# %% id=S

# %% id=ASK
name <- readline("Name? ")
cat("Hello", name, "\n")

# %% id=MENU
pick <- menu(c("red", "blue"), title = "Colour")
pick

# /// cell order
# S
# ASK
# MENU
# ///
