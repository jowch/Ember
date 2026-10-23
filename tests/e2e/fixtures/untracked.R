### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-01-01"
# ///

# %% id=N
site_names <- c("site_A", "site_B")

# %% id=A
for (s in site_names) assign(s, data.frame(h = 1:3))

# %% id=B
sapply(site_names, function(s) sum(get(s)$h))

# %% id=L
sum(get("site_A")$h)

# /// cell order
# N
# A
# B
# L
# ///
