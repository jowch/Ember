# Plain functions for the browser's file-naming surfaces: turning what a
# person typed into a notebook path (notebook_target_path(), used by the
# start page's New notebook and the header's rename/move), and listing a
# folder's entries for a typed path (complete_path(), behind Pluto's
# completepath request).

#' A notebook file path from what a person typed.
#'
#' `name` is trimmed; ".R" is appended unless it already ends in ".R" or
#' ".r"; a `name` that is empty, "." or ".." or contains "/" or "\\" is
#' refused. `folder` has "~" expanded, must be an absolute, existing,
#' writable (`file.access(folder, 2) == 0`) folder.
#'
#' @return The target path, or stops with an `ember_refused` condition
#'   whose message is the reason, worded as the page shows it.
notebook_target_path <- function(name, folder) {
  name <- trimws(name %||% "")
  folder <- path.expand(folder %||% "")
  if (!nzchar(name) || identical(name, ".") || identical(name, "..") || grepl("[/\\\\]", name)) {
    stop(refused(sprintf("\"%s\" is not a valid name", name)))
  }
  if (!grepl("\\.[Rr]$", name)) name <- paste0(name, ".R")
  if (!is_absolute_path(folder)) {
    stop(refused(sprintf("%s is not an absolute path", folder)))
  }
  if (!dir.exists(folder)) {
    stop(refused(sprintf("the folder %s does not exist", folder)))
  }
  if (!identical(unname(file.access(folder, 2)), 0L)) {
    stop(refused(sprintf("the folder %s is not writable", folder)))
  }
  file.path(folder, name)
}

#' Folder-completion candidates for a typed path (Pluto's `completepath`
#' request). Everything in `query` up to its last "/" names the folder
#' (the folder is `"."`, the working directory, when there is no "/");
#' what follows is matched by prefix, case-sensitively, against that
#' folder's entries, folders getting a trailing "/". A typed part that
#' doesn't start with "." leaves out hidden entries. `dirs_only` keeps
#' only folders. At most 200 results, alphabetical.
#'
#' @return `list(start, stop, results)`, the shape Pluto's own protocol
#'   uses: `start` is the 0-based byte offset in `query` right after its
#'   last "/" (0 when there is none) and `stop` is `query`'s byte length,
#'   together the span a chosen result replaces; `results` is a character
#'   vector.
complete_path <- function(query, dirs_only = FALSE) {
  query <- query %||% ""
  slashes <- gregexpr("/", query, fixed = TRUE)[[1]]
  last_slash <- if (identical(slashes[1], -1L)) 0L else max(slashes)
  dir <- if (last_slash > 0L) substr(query, 1L, last_slash) else "."
  partial <- substr(query, last_slash + 1L, nchar(query))

  expanded <- path.expand(dir)
  entries <- tryCatch(list.files(expanded, all.files = TRUE, no.. = TRUE, include.dirs = TRUE),
                      error = function(e) character())
  is_dir <- if (length(entries) == 0) logical() else {
    info <- file.info(file.path(expanded, entries))$isdir
    !is.na(info) & info
  }

  show_hidden <- startsWith(partial, ".")
  keep <- startsWith(entries, partial) & (show_hidden | !startsWith(entries, "."))
  if (isTRUE(dirs_only)) keep <- keep & is_dir

  labeled <- ifelse(is_dir, paste0(entries, "/"), entries)
  results <- sort(labeled[keep])
  if (length(results) > 200) results <- results[seq_len(200)]

  list(start = last_slash, stop = nchar(query, type = "bytes"), results = as.list(results))
}
