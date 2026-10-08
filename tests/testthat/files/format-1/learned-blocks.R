### An Ember notebook ###
# /// environment
# ember_version = "0.1.0"
# r_version = "4.5.1"
# snapshot = "2026-09-01"
# ///

# %% id=setup
d <- "helpers"
x <- 1

# %% id=a
source(file.path(d, "dyn.R"))

# %% id=b
fit <- lm(y ~ x + `dose mg`, data = df)

# /// cell order
# setup
# a
# b
# ///
# /// sourced files
# helpers/dyn.R md5:deadbeef
# "helpers/my dyn.R" md5:cafef00d
# ///
# /// learned sources
# a helpers/dyn.R "helpers/my dyn.R"
# ///
# /// learned definitions
# a dyn_fit
# ///
# /// learned references
# b x "dose mg"
# ///
