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

test_that("export_html() inlines an htmlwidget's dependency files as data: URLs (15)", {
  # A hand-built state with a text/html output and a resolved dependency,
  # the same shape display_html() (inst/worker.R) and project_dep_tags()
  # (pluto-state.R) produce -- not a real htmltools install, which needs
  # a package install this sandbox's renv setup can't always complete
  # (see the [net] test below for that end-to-end path).
  # dep_dir has to sit inside the notebook's (fake) library for
  # dep_path_allowed() to accept it (R/export.R, collect_output_deps()):
  # the export applies the same check the live server does before serving
  # a dependency, so a dependency outside the library is refused the same
  # way in both places.
  lib <- tempfile("widgetlib-")
  dir.create(lib, recursive = TRUE)
  dep_dir <- file.path(lib, "widgettest-1.0.0")
  dir.create(dep_dir, recursive = TRUE)
  writeLines("document.title = 'ran'", file.path(dep_dir, "a.js"))

  s <- fake_state(list(S = cell(""), W = cell("1")), setup = "S")
  s$allowed <- TRUE
  s$packages$active$path <- lib
  s$results <- list(W = report(status = "ok", output = list(
    mime = "text/html",
    data = "<div>x</div>",
    deps = list(list(name = "widgettest", version = "1.0.0", dir = dep_dir,
                     script = "a.js", stylesheet = NULL, head = NULL, href = NULL))
  )))

  html <- export_html(s)
  expect_false(grepl('src="deps/', html, fixed = TRUE))

  # The dependency's JS text survives inside the (msgpack + base64 encoded)
  # embedded statefile, as a `data:` URL -- not as a readable substring of
  # the export (it's inside a second, outer base64 layer).
  # Not regexec(): on Windows its offsets into this (non-ASCII) page are
  # shifted, so the capture picks up the closing quote.
  start <- regexpr('window.pluto_statefile = "data:;base64,', html, fixed = TRUE)
  rest <- substring(html, start + attr(start, "match.length"))
  statefile_b64 <- substr(rest, 1, regexpr('"', rest, fixed = TRUE) - 1)
  js <- mp_decode(jsonlite::base64_dec(statefile_b64))
  body <- js$cell_results$W$output$body
  expect_match(body, "^<script src=\"data:text/javascript;base64,")
  expect_false(grepl("deps/", body, fixed = TRUE))
})

test_that("export_html() refuses a dependency dir outside the library (path traversal)", {
  outside <- tempfile("outside-lib-")
  dir.create(outside, recursive = TRUE)
  writeLines("secret", file.path(outside, "a.js"))

  s <- fake_state(list(S = cell(""), W = cell("1")), setup = "S")
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
  start <- regexpr('window.pluto_statefile = "data:;base64,', html, fixed = TRUE)
  rest <- substring(html, start + attr(start, "match.length"))
  statefile_b64 <- substr(rest, 1, regexpr('"', rest, fixed = TRUE) - 1)
  js <- mp_decode(jsonlite::base64_dec(statefile_b64))
  body <- js$cell_results$W$output$body
  # The dependency is dropped, not embedded: the untouched "deps/" link
  # stays in the body (the live server would also refuse to serve it), and
  # the file's actual content never reaches the export at all.
  expect_match(body, "deps/widgettest-1.0.0/a.js", fixed = TRUE)
  expect_false(grepl("secret", body, fixed = TRUE))
})

test_that("export_html() refuses a dependency file name with a '..' segment", {
  lib <- tempfile("widgetlib-")
  dep_dir <- file.path(lib, "widgettest-1.0.0")
  dir.create(dep_dir, recursive = TRUE)
  writeLines("safe", file.path(dep_dir, "a.js"))
  outside_file <- file.path(lib, "secret.txt")
  writeLines("secret", outside_file)

  deps <- list("widgettest-1.0.0" = list(dir = dep_dir, name = "widgettest", version = "1.0.0"))
  html <- inline_output_deps('<script src="deps/widgettest-1.0.0/../secret.txt"></script>', deps)
  # Left untouched -- no data: URL -- rather than reading outside dep_dir.
  expect_equal(html, '<script src="deps/widgettest-1.0.0/../secret.txt"></script>')
  expect_false(grepl("base64", html, fixed = TRUE))

  html_ok <- inline_output_deps('<script src="deps/widgettest-1.0.0/a.js"></script>', deps)
  expect_match(html_ok, "^<script src=\"data:text/javascript;base64,")
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
  expect_false(grepl('src="deps/', html, fixed = TRUE))
})
