# Fixture trees whose real layout doesn't fit in a package tarball, which
# stores no path over 100 bytes (#244).

#' The `file://` GitHub fixture's folder: a copy of fixtures/github, made
#' once per test process, with each `contents/<short sha>` folder renamed to
#' the full sha `github_description_url()` asks for. The full sha is the one
#' in that repository's `tarball/` that starts with the short one.
github_fixture_dir <- local({
  dir <- NULL
  function() {
    if (!is.null(dir) && dir.exists(dir)) return(dir)
    out <- tempfile("ember-gh-fixture-")
    dir.create(out)
    file.copy(normalizePath(testthat::test_path("fixtures", "github"), mustWork = TRUE), out, recursive = TRUE)
    out <- file.path(out, "github")
    for (contents in Sys.glob(file.path(out, "repos", "*", "*", "contents"))) {
      shas <- list.files(file.path(dirname(contents), "tarball"))
      for (short in list.files(contents)) {
        full <- shas[startsWith(shas, short)]
        stopifnot(length(full) == 1L)
        file.rename(file.path(contents, short), file.path(contents, full))
      }
    }
    dir <<- normalizePath(out)
    dir
  }
})
