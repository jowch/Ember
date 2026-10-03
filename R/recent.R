# The recent-notebooks list: one file per user, shared by every Ember
# server of that user, whatever the port (it lives under
# tools::R_user_dir(), not anything port- or process-specific). Plain
# functions over that one file; callers (host_notebook(), on_note(),
# the start-page requests) wrap every call in tryCatch so a read-only
# home folder never breaks hosting a notebook.

#' The recent-notebooks file's path: one absolute path per line, newest
#' first, at most 50 entries.
recent_file <- function() {
  file.path(tools::R_user_dir("ember", "data"), "recent-notebooks.txt")
}

#' The recent list, newest first. A missing file reads as `character()`,
#' never an error.
read_recent <- function() {
  path <- recent_file()
  if (!file.exists(path)) return(character())
  lines <- tryCatch(readLines(path, warn = FALSE), error = function(e) character())
  lines[nzchar(lines)]
}

#' Write `paths` to the recent file, creating its folder if needed.
#' Returns `FALSE`, doing nothing, if the folder can't be created or
#' written (a read-only home folder).
write_recent <- function(paths) {
  path <- recent_file()
  dir <- dirname(path)
  if (!dir.exists(dir)) {
    created <- tryCatch(suppressWarnings(dir.create(dir, recursive = TRUE)), error = function(e) FALSE)
    if (!isTRUE(created) || !dir.exists(dir)) return(FALSE)
  }
  write_atomic(path, paste0(paste(paths, collapse = "\n"), if (length(paths) > 0) "\n" else ""))
}

#' Record `path` as the most recently opened notebook. When `replaces` is
#' given (a move or rename), that old path is dropped instead of kept
#' further down the list. No duplicates; at most 50 entries, newest
#' first.
remember_notebook <- function(path, replaces = NULL) {
  existing <- read_recent()
  drop <- c(path, replaces)
  without <- existing[!(existing %in% drop)]
  updated <- c(path, without)
  write_recent(utils::head(updated, 50))
  invisible(NULL)
}

#' Remove `path` from the recent list (the start page's "Forget"). The
#' file itself is untouched.
forget_notebook <- function(path) {
  existing <- read_recent()
  write_recent(existing[!(existing %in% path)])
  invisible(NULL)
}
