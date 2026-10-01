# Test-only helpers for test-session.R: real notebooks opened through the
# API, with a real worker but no package installs (`library = NULL`, so
# only R's own packages are visible -- every notebook cell here must stick
# to base R).

#' Write `text` to `path` with exactly those bytes: no trailing newline
#' added, unlike `writeLines()`.
write_file_exact <- function(path, text) {
  con <- file(path, open = "wb")
  on.exit(close(con))
  writeBin(charToRaw(enc2utf8(text)), con)
}

#' Build a canonical notebook file from `cell()`s (helper-core.R) and write
#' it to disk. Returns the path.
write_session_notebook <- function(cells, setup = names(cells)[1],
                                   on_cell_change = "autorun",
                                   dir = NULL) {
  if (is.null(dir)) {
    dir <- tempfile("ember-nb-")
    dir.create(dir, recursive = TRUE)
  }
  header <- new_header(ember_version = as.character(utils::packageVersion("ember")),
                       r_version = paste(R.version$major, R.version$minor, sep = "."),
                       snapshot = "2026-01-01", on_cell_change = on_cell_change)
  file <- new_notebook_file(
    header = header, cells = cells, setup = setup, run_order = names(cells),
    learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = character(), extra_blocks = list(), format = ember_format)
  path <- file.path(dir, "nb.R")
  write_file_exact(path, format_notebook(file))
  path
}

#' Compile the spike's `stuck.c` (a loop that never calls
#' `R_CheckUserInterrupt()`) into a shared library in a fresh temp dir.
#' Returns the library path, or `NULL` if `R CMD SHLIB` failed (the caller
#' should `skip()`).
compile_stuck_lib <- function() {
  src_dir <- tempfile("ember-stuck-")
  dir.create(src_dir)
  src <- file.path(ember_package_root(), "tests", "testthat", "fixtures", "stuck.c")
  if (!file.exists(src)) return(NULL)
  file.copy(src, file.path(src_dir, "stuck.c"))

  r_bin <- file.path(R.home("bin"), "R")
  res <- tryCatch(
    processx::run(r_bin, c("CMD", "SHLIB", "stuck.c"), wd = src_dir,
                  error_on_status = FALSE, timeout = 60),
    error = function(e) NULL)
  if (is.null(res) || res$status != 0) return(NULL)

  so <- list.files(src_dir, pattern = "\\.(so|dll|dylib)$", full.names = TRUE)
  if (length(so) == 0) return(NULL)
  normalizePath(so[[1]])
}

#' The id -> `ember_cell_view` lookup from a snapshot's cells.
snap_view <- function(snap, id) Find(function(v) identical(v$id, id), snap$cells)
