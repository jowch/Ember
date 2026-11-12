### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-09-01"
# ///

# %% id=S

# %% id=DEP
dep_dir <- file.path(.libPaths()[1], "emberhostdep")
dir.create(dep_dir, showWarnings = FALSE, recursive = TRUE)
writeLines(
  "window.__host_dep_runs = (window.__host_dep_runs || 0) + 1; window.hostWidget = (id) => { document.getElementById(id).textContent = 'widget-ran' }",
  file.path(dep_dir, "widget.js")
)
writeLines(".host-marker { color: rgb(1, 2, 3); }", file.path(dep_dir, "widget.css"))
dep <- htmltools::htmlDependency("emberhostdep", "1.0.0", src = c(file = dep_dir), script = "widget.js", stylesheet = "widget.css")

# %% id=WIDGET
htmltools::browsable(htmltools::tagList(htmltools::tags$div(id = "marker-1", class = "host-marker", "pending"), htmltools::tags$script("hostWidget('marker-1')"), dep))

# %% id=WIDGET2
htmltools::browsable(htmltools::tagList(htmltools::tags$div(id = "marker-2", class = "host-marker", "pending"), htmltools::tags$script("hostWidget('marker-2')"), dep))

# /// cell order
# S
# DEP
# WIDGET
# WIDGET2
# ///
