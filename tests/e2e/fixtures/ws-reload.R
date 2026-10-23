### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-01-01"
# ///

# %% id=STREAM
for (i in 1:150) {
  cat("line", i, strrep("x", 2000), "\n")
  Sys.sleep(0.02)
}

# /// cell order
# STREAM
# ///
