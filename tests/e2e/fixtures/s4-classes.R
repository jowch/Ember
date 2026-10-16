### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-01-01"
# ///

# %% id=S

# %% id=U1
new("Ok", r = 2)@r

# %% id=C1
setClass("Ok", representation(r = "numeric"))

# %% id=U2
new("Bad")

# %% id=C2
setClass("Bad", representation(r = "numeric"))
stop("boom")

# /// cell order
# S
# U1
# C1
# U2
# C2
# ///
