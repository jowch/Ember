### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-09-01"
# ///

# %% id=S [setup]

# %% id=WIDGET
dep_dir <- file.path(.libPaths()[1], "embertestdep")
dir.create(dep_dir, showWarnings = FALSE, recursive = TRUE)
writeLines(
  "document.getElementById('widget-marker').textContent = 'widget-ran'",
  file.path(dep_dir, "widget.js")
)
htmltools::browsable(htmltools::tagList(
  htmltools::tags$div(id = "widget-marker", "pending"),
  htmltools::htmlDependency("embertestdep", "1.0.0", src = c(file = dep_dir), script = "widget.js")
))

# /// cell order
# S
# WIDGET
# ///
