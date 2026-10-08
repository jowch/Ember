### An Ember notebook ###
# /// environment
# ember_version = "0.1.0"
# r_version = "4.5.1"
# snapshot = "2026-09-01"
# on_cell_change = "lazy"
# [sources]
# mypkg = "github:lab/mypkg@3f2a1c9"
# other = "gitlab:x/y@abc123"
# [extra_packages]
# svglite
# ragg
# ///

# %% id=setup
library(dplyr)

# %% id=calc
x <- 1

y <- x + 1

z <- y * 2

# %% id=note [markdown]
#' ## Résumé
#'
#' Café data, emoji test 😀, 中文测试

# /// cell order
# setup
# note folded
# calc
# ///
# /// sourced files
# helpers.R md5:9c1e1234
# "a path.R" sha256:deadbeef
# ///
# /// learned definitions
# calc z extra
# ///
# /// lock
# dplyr 1.1.4 CRAN
# ///
