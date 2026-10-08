# Tests for export_html() (docs/ui-2.md, "Offline bundle", "Exports").
# Covers docs/ui-2-tests.md item 15.

#' `html` with every `<script ...>...</script>` and `<style>...</style>`
#' element's text content blanked out (tags kept). What's left is the
#' editor.html skeleton: real `src=`/`href=`/`url()` attributes can only
#' ever appear there, never inside the embedded `#ember-modules` JSON or
#' the loader script, where an original frontend file's own source text
#' (a comment, an error page's `<a href="./">`, ...) can otherwise read
#' like a match without being one (ui-2-tests.md 13's "a plain <a href> is
#' not a load" note, applied the same way to the export's own markup).
strip_script_and_style_content <- function(html) {
  html <- gsub("(?s)(<script\\b[^>]*>).*?(</script>)", "\\1\\2", html, perl = TRUE)
  gsub("(?s)(<style\\b[^>]*>).*?(</style>)", "\\1\\2", html, perl = TRUE)
}

minimal_export_state <- function() {
  dir <- tempfile("ember-export-nb-")
  dir.create(dir, recursive = TRUE)
  path <- write_session_notebook(list(A = cell("1 + 1"), B = cell("A")), dir = dir)
  nb <- open_notebook(path)
  notebook_state(nb)
}

test_that("export_html() leaves no relative src=/href=/url(./ and no external URL but MathJax (15)", {
  state <- minimal_export_state()
  html <- export_html(state)
  skeleton <- strip_script_and_style_content(html)

  expect_false(grepl('src="\\./', skeleton, perl = TRUE))
  expect_false(grepl('href="\\./', skeleton, perl = TRUE))
  expect_false(grepl("url\\(\\./", skeleton, perl = TRUE))

  url_re <- "https?://[^\"'()\\s>]+"
  urls <- regmatches(skeleton, gregexpr(url_re, skeleton, perl = TRUE))[[1]]
  non_mathjax <- urls[!grepl("mathjax@", urls, fixed = TRUE)]
  expect_equal(non_mathjax, character(0))
})

test_that("export_html()'s #ember-modules holds every .js/.json file with no relative specifier left (15)", {
  state <- minimal_export_state()
  html <- export_html(state)

  m <- regmatches(html, regexec(
    '<script type="application/json" id="ember-modules">(.*?)</script>', html, perl = TRUE))[[1]]
  expect_equal(length(m), 2)
  modules <- jsonlite::fromJSON(m[2], simplifyVector = FALSE)

  frontend_dir <- system.file("frontend", package = "ember")
  on_disk <- list.files(frontend_dir, pattern = "\\.(js|json)$", recursive = TRUE)
  on_disk <- gsub("\\\\", "/", on_disk)
  expect_equal(sort(names(modules)), sort(on_disk))

  spec_re <- '(?:from|import)\\s*\\(?\\s*"(\\.[^"]*)"'
  offenders <- character(0)
  for (path in names(modules)) {
    if (!grepl("\\.js$", path)) next
    text <- modules[[path]]
    if (grepl(spec_re, text, perl = TRUE)) offenders <- c(offenders, path)
  }
  expect_equal(offenders, character(0))
})

test_that("export_html()'s frontend .js files use no import.meta and no computed import() but Environment.js (15)", {
  frontend_dir <- system.file("frontend", package = "ember")
  files <- list.files(frontend_dir, pattern = "\\.js$", recursive = TRUE, full.names = TRUE)

  meta_offenders <- character(0)
  dynamic_offenders <- character(0)
  for (f in files) {
    text <- readChar(f, file.info(f)$size)
    if (grepl("import\\.meta", text, fixed = TRUE)) meta_offenders <- c(meta_offenders, f)
    # A dynamic import() whose argument isn't a string literal: look for
    # `import(` not immediately followed by a quote (allowing whitespace).
    bad <- regmatches(text, gregexpr("import\\(\\s*[^\"'\\s)]", text, perl = TRUE))[[1]]
    if (length(bad) > 0 && !grepl("Environment\\.js$", f)) dynamic_offenders <- c(dynamic_offenders, f)
  }
  expect_equal(meta_offenders, character(0))
  expect_equal(dynamic_offenders, character(0))
})

#' A `/ember-deps` JSON block (if any) read back out of an export's HTML,
#' as path -> list(mime, data).
read_deps_script <- function(html) {
  m <- regmatches(html, regexec(
    '<script type="application/json" id="ember-deps">(.*?)</script>', html, perl = TRUE))[[1]]
  if (length(m) == 0) return(NULL)
  jsonlite::fromJSON(m[2], simplifyVector = FALSE)
}

#' A fake state with `n` cells, each a `text/html` output using the same
#' widget dependency (`dep_dir`/`key`), the shape `display_html()`
#' (inst/worker.R) and `project_dep_tags()` (pluto-state.R) produce -- not a
#' real htmltools install, which needs a package install this sandbox's
#' renv setup can't always complete (see the [net] test below for that
#' end-to-end path).
fake_state_with_shared_dep <- function(n, dep_dir, key = "widgettest-1.0.0") {
  cells <- c(list(S = cell("")), setNames(lapply(seq_len(n), function(i) cell("1")), paste0("W", seq_len(n))))
  s <- fake_state(cells)
  s$allowed <- TRUE
  s$packages$active$path <- dirname(dep_dir)
  s$results <- setNames(lapply(seq_len(n), function(i) {
    report(status = "ok", output = list(
      mime = "text/html",
      data = sprintf("<div>%d</div>", i),
      deps = list(list(name = "widgettest", version = "1.0.0", dir = dep_dir,
                       script = "a.js", stylesheet = NULL, head = NULL, href = NULL))))
  }), paste0("W", seq_len(n)))
  s
}

test_that("export_html() embeds a dependency file once, however many outputs share it (review: export size)", {
  dep_dir <- tempfile("widgetlib-widgettest-1.0.0-")
  dir.create(dep_dir, recursive = TRUE)
  payload <- paste(rep("x", 5000), collapse = "")   # big enough that 1x vs 3x is unmistakable
  writeLines(sprintf("document.title = '%s'", payload), file.path(dep_dir, "a.js"))

  s1 <- fake_state_with_shared_dep(1, dep_dir)
  s3 <- fake_state_with_shared_dep(3, dep_dir)

  html1 <- export_html(s1)
  html3 <- export_html(s3)

  deps1 <- read_deps_script(html1)
  deps3 <- read_deps_script(html3)
  expect_equal(length(deps1), 1)
  expect_equal(length(deps3), 1)   # one entry, not one per output
  expect_identical(deps1[[1]]$data, deps3[[1]]$data)

  # The 3-output export is only marginally bigger than the 1-output one
  # (three "deps/widgettest-1.0.0/a.js" references and two more cell
  # bodies), nowhere near 3x the dependency's own embedded size -- the
  # bug this fixes multiplied a shared dependency's cost by every output
  # using it.
  grew_by <- nchar(html3) - nchar(html1)
  expect_lt(grew_by, nchar(deps1[[1]]$data))

  # Each output's body still carries the untouched "deps/<key>/<file>"
  # reference -- the live page's own HTML, unchanged -- for
  # export-loader.js/CellOutput.js to rewrite to a Blob URL at render time.
  start <- regexpr('window.pluto_statefile = "data:;base64,', html3, fixed = TRUE)
  rest <- substring(html3, start + attr(start, "match.length"))
  statefile_b64 <- substr(rest, 1, regexpr('"', rest, fixed = TRUE) - 1)
  js <- mp_decode(jsonlite::base64_dec(statefile_b64))
  for (id in c("W1", "W2", "W3")) {
    expect_match(js$cell_results[[id]]$output$body, "deps/widgettest-1.0.0/a.js", fixed = TRUE)
  }
})

test_that("export_html() refuses a dependency dir outside the library (path traversal)", {
  outside <- tempfile("outside-lib-")
  dir.create(outside, recursive = TRUE)
  marker <- "SECRETMARKERXYZ123"
  writeLines(marker, file.path(outside, "a.js"))

  s <- fake_state(list(S = cell(""), W = cell("1")))
  s$allowed <- TRUE
  s$packages$active$path <- tempfile("widgetlib-")
  dir.create(s$packages$active$path, recursive = TRUE)
  s$results <- list(W = report(status = "ok", output = list(
    mime = "text/html",
    data = "<div>x</div>",
    deps = list(list(name = "widgettest", version = "1.0.0", dir = outside,
                     script = "a.js", stylesheet = NULL, head = NULL, href = NULL))
  )))

  html <- export_html(s)
  # The dependency is dropped, not embedded: no #ember-deps entry, the
  # file's actual content never reaches the export at all, and the
  # untouched "deps/" link stays in the body (the live server would also
  # refuse to serve it).
  expect_null(read_deps_script(html))
  expect_false(grepl(marker, html, fixed = TRUE))

  start <- regexpr('window.pluto_statefile = "data:;base64,', html, fixed = TRUE)
  rest <- substring(html, start + attr(start, "match.length"))
  statefile_b64 <- substr(rest, 1, regexpr('"', rest, fixed = TRUE) - 1)
  js <- mp_decode(jsonlite::base64_dec(statefile_b64))
  expect_match(js$cell_results$W$output$body, "deps/widgettest-1.0.0/a.js", fixed = TRUE)
})

test_that("export_html() refuses a dependency file name with a '..' segment", {
  lib <- tempfile("widgetlib-")
  dep_dir <- file.path(lib, "widgettest-1.0.0")
  dir.create(dep_dir, recursive = TRUE)
  writeLines("safe", file.path(dep_dir, "a.js"))
  writeLines("secret", file.path(lib, "secret.txt"))

  deps <- list("widgettest-1.0.0" = list(dir = dep_dir, name = "widgettest", version = "1.0.0"))
  js_bad <- list(cell_results = list(W = list(output = list(
    mime = "text/html", body = '<script src="deps/widgettest-1.0.0/../secret.txt"></script>'))))
  paths_bad <- collect_dep_file_paths(js_bad, deps)
  expect_equal(length(paths_bad), 0)

  js_ok <- list(cell_results = list(W = list(output = list(
    mime = "text/html", body = '<script src="deps/widgettest-1.0.0/a.js"></script>'))))
  paths_ok <- collect_dep_file_paths(js_ok, deps)
  expect_equal(unname(paths_ok), list(file.path(dep_dir, "a.js")))
})

test_that("escape_json_for_script() closes off both </SCRIPT> and <!--<script> (review)", {
  text <- 'a </SCRIPT> b <!--<script> c'
  json <- jsonlite::toJSON(list(f = text), auto_unbox = TRUE)
  escaped <- escape_json_for_script(as.character(json))
  expect_false(grepl("<", escaped, fixed = TRUE))
  decoded <- jsonlite::fromJSON(escaped, simplifyVector = FALSE)
  expect_identical(decoded$f, text)
})

test_that("export_html() embeds a module's </SCRIPT> and <!--<script> text safely (review)", {
  dir <- tempfile("ember-export-nb-")
  dir.create(dir, recursive = TRUE)
  path <- write_session_notebook(list(A = cell("1 + 1")), dir = dir)
  nb <- open_notebook(path)
  frontend_dir <- system.file("frontend", package = "ember")
  planted <- file.path(frontend_dir, "components", "__review_test_planted.js")
  writeLines('// </SCRIPT> and <!--<script> inside a comment, never executed', planted)
  on.exit(unlink(planted), add = TRUE)

  html <- export_html(notebook_state(nb))
  m <- regmatches(html, regexec(
    '<script type="application/json" id="ember-modules">(.*?)</script>', html, perl = TRUE))[[1]]
  modules_json_text <- m[2]
  expect_false(grepl("<", modules_json_text, fixed = TRUE))
  modules <- jsonlite::fromJSON(modules_json_text, simplifyVector = FALSE)
  expect_match(modules[["components/__review_test_planted.js"]], "</SCRIPT>", fixed = TRUE)
  expect_match(modules[["components/__review_test_planted.js"]], "<!--<script>", fixed = TRUE)
})

# ---- 20, end to end: a real htmltools install (opt-in network test) -------

test_that("[net] a real htmltools widget's dependency survives export (20)", {
  skip_if_not_installed("htmltools")
  skip_if_not(identical(Sys.getenv("EMBER_TEST_NETWORK"), "1"),
             "set EMBER_TEST_NETWORK=1 to run the opt-in network test")

  dir <- tempfile("ember-export-widget-")
  dir.create(dir, recursive = TRUE)
  path <- write_session_notebook(list(S = cell(""), W = cell(paste(
    # Inside .libPaths()[1] (the notebook's own library), not a bare
    # tempfile(): dep_path_allowed() (R/export.R, collect_output_deps())
    # refuses a dependency outside the library on the live server too, so a
    # dependency this test wants embedded has to live where a real widget
    # package's installed files actually would.
    'dep_dir <- file.path(.libPaths()[1], "widgettest-1.0.0"); dir.create(dep_dir)',
    'writeLines("1", file.path(dep_dir, "a.js"))',
    'htmltools::browsable(htmltools::tagList(',
    '  htmltools::tags$div("x"),',
    '  htmltools::htmlDependency("widgettest", "1.0.0", src = c(file = dep_dir), script = "a.js")',
    '))',
    sep = "\n"
  # Packages from early 2026 (rlang 1.1.6) don't compile on R 4.6.
  ))), dir = dir, snapshot = "2026-09-01")
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  allow_execution(nb)

  res <- run_cells(nb, wait = TRUE, timeout = 120)
  # Not skip(): this test only runs at all with EMBER_TEST_NETWORK=1, which
  # CI now sets precisely so a real install-and-run regression is caught
  # rather than silently skipped.
  if (!res$accepted || res$timed_out) fail("worker did not finish installing/running in time")
  state <- notebook_state(nb)
  w <- state$results[["W"]]
  expect_identical(w$status, "ok")

  html <- export_html(state)
  deps <- read_deps_script(html)
  expect_equal(length(deps), 1)
})
