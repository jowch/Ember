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
#' written (a read-only home folder). A path containing "\n" or "\r" is
#' dropped first: the file is one path per line, and either character
#' would otherwise split or truncate the entry on the next `read_recent()`
#' (not a path `normalize_recent_path()` would ever itself produce, but
#' this is the file's only format guarantee, so it is enforced here too).
write_recent <- function(paths) {
  paths <- paths[!grepl("[\n\r]", paths, fixed = FALSE)]
  path <- recent_file()
  dir <- dirname(path)
  if (!dir.exists(dir)) {
    created <- tryCatch(suppressWarnings(dir.create(dir, recursive = TRUE)), error = function(e) FALSE)
    if (!isTRUE(created) || !dir.exists(dir)) return(FALSE)
  }
  write_atomic(path, paste0(paste(paths, collapse = "\n"), if (length(paths) > 0) "\n" else ""))
}

#' `path`, resolved the way every recent-list entry is compared and
#' stored: `normalizePath(path, mustWork = FALSE)`, so a notebook reached
#' by two different (but equal) spellings -- a trailing slash, a `.`
#' segment, a symlink component -- is one entry, not two, and a move's
#' `replaces` reliably matches what an earlier `remember_notebook()`
#' stored for the same file. `mustWork = FALSE`: a forgotten or
#' since-deleted path must still normalize, not error.
normalize_recent_path <- function(path) {
  tryCatch(normalizePath(path, mustWork = FALSE), error = function(e) path)
}

#' Record `path` as the most recently opened notebook. When `replaces` is
#' given (a move or rename), that old path is dropped instead of kept
#' further down the list. No duplicates; at most 50 entries, newest
#' first.
remember_notebook <- function(path, replaces = NULL) {
  path <- normalize_recent_path(path)
  existing <- read_recent()
  drop <- c(path, if (!is.null(replaces)) normalize_recent_path(replaces))
  without <- existing[!(existing %in% drop)]
  updated <- c(path, without)
  write_recent(utils::head(updated, 50))
  invisible(NULL)
}

#' Remove `path` from the recent list (the start page's "Forget"). The
#' file itself is untouched.
forget_notebook <- function(path) {
  path <- normalize_recent_path(path)
  existing <- read_recent()
  write_recent(existing[!(existing %in% path)])
  invisible(NULL)
}
