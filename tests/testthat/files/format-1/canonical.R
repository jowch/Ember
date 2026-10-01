### An Ember notebook ###
# /// environment
# ember_version = "0.1.0"
# r_version = "4.5.1"
# snapshot = "2026-09-01"
# bioc_version = "3.22"
# [sources]
# mypkg = "github:lab/mypkg@3f2a1c9"
# [extra_packages]
# svglite
# ///

# %% id=setup [setup]
library(dplyr)
library(ggplot2)
options(digits = 4)

# %% id=md1 [markdown]
#' ## Growth curves
#' Measured every 30 minutes.

# %% id=a
curves <- read.csv("growth.csv")

# %% id=load1
load("fits.RData")

# /// cell order
# setup
# md1 folded
# a
# load1
# ///
# /// sourced files
# helpers.R sha256:9c1e
# ///
# /// learned definitions
# load1 fits
# ///
# /// lock
# cli 3.6.5 CRAN
# dplyr 1.1.4 CRAN
# ggplot2 3.5.2 CRAN
# ///
