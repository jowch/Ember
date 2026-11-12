### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-09-01"
# ///

# %% id=S

# %% id=DEP
dep_of <- function(version) {
  dir <- file.path(.libPaths()[1], paste0("emberdupe-", version))
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  writeLines(sprintf("window.__dupe_runs = (window.__dupe_runs || []).concat('%s')", version), file.path(dir, "dupe.js"))
  htmltools::htmlDependency("emberdupe", version, src = c(file = dir), script = "dupe.js")
}
old <- dep_of("1.0.0")
new <- dep_of("2.0.0")

# %% id=OLD
htmltools::browsable(htmltools::tagList(htmltools::tags$div(id = "dupe-1", class = "dupe-marker", "pending"), htmltools::tags$script("document.getElementById('dupe-1').textContent = window.__dupe_runs.join()"), old))

# %% id=NEW
htmltools::browsable(htmltools::tagList(htmltools::tags$div(id = "dupe-2", class = "dupe-marker", "pending"), htmltools::tags$script("document.getElementById('dupe-2').textContent = window.__dupe_runs.join()"), new))

# %% id=BOX
htmltools::browsable(htmltools::tags$div(id = "box-widget", class = "html-widget", style = "width: 100%; height: 40px"))

# /// cell order
# S
# DEP
# OLD
# NEW
# BOX
# ///
