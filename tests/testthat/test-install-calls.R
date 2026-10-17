# Install calls as package sources (#79, packages.md "Install calls"): the
# walker reads `remotes::install_github("lab/pkg")` and its kin as where a
# package lives, the session writes that into the header's `[sources]`,
# and neither the worker nor `ember::run()` runs them: the lock answers
# them. The universe fixture (fixtures/universe/lab) serves toyD, as in
# test-universe-sources.R.

installs_of <- function(code) read_cell(code)$installs

install_state <- function(cells, sources = character()) {
  file <- new_notebook_file(
    header = new_header(ember_version = "0.1.0", r_version = "4.3.0", snapshot = "2026-09-01",
                        sources = sources),
    cells = cells, run_order = names(cells), learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = empty_lock(), extra_blocks = list(), format = 1L, read_only = FALSE, problems = NULL)
  options <- list(r = list(version = "4.6.1", minor = "4.6", platform = "x86_64-pc-linux-gnu"),
                  bioc_releases = parse_bioc_config(readLines(testthat::test_path("fixtures", "bioc-config", "config.yaml"),
                                                              warn = FALSE)))
  new_state(file, path = "nb.R", id = "n1", options = options, at = 0)
}

fetch_keys <- function(r) {
  vapply(Filter(function(e) identical(e$type, "fetch_index"), r$effects), function(e) e$key, character(1))
}

# ---- Reading -----------------------------------------------------------------

test_that("install_github names the repository and its ref, and its own package isn't one the notebook needs", {
  a <- read_cell('remotes::install_github("lab/toyD@v1")\ndevtools::install_github(c("a1/one", "b2/two"), ref = "dev")')
  expect_equal(a$installs$package, c("toyD", "one", "two"))
  expect_equal(a$installs$source, c("github:lab/toyD@v1", "github:a1/one@dev", "github:b2/two@dev"))
  expect_equal(a$installs$top, c(TRUE, TRUE, TRUE))
  expect_equal(nrow(a$packages), 0)
})

test_that("pak's forms, install.packages with an r-universe, and BiocManager are read", {
  i <- installs_of('pak::pak(c("toyD=lab/toy-d", "github::lab/viz", "cran::cli", "dplyr"))')
  expect_equal(i$package, c("toyD", "viz", "cli", "dplyr"))
  expect_equal(i$source, c("github:lab/toy-d", "github:lab/viz", NA, NA))

  i <- installs_of('install.packages(c("toyD", "viz"), repos = c("https://lab.r-universe.dev", "https://cloud.r-project.org"))')
  expect_equal(i$source, c("universe:lab", "universe:lab"))
  # CRAN's own universe isn't a source; two others can't be told apart.
  expect_equal(installs_of('install.packages("toyD", repos = c("https://lab.r-universe.dev", "https://cran.r-universe.dev"))')$source,
               "universe:lab")
  expect_equal(installs_of('install.packages("toyD", repos = c("https://a.r-universe.dev", "https://b.r-universe.dev"))')$source,
               NA_character_)
  expect_equal(installs_of('install.packages("dplyr")')$source, NA_character_)
  expect_equal(installs_of('BiocManager::install("DESeq2")')$package, "DESeq2")
})

test_that("a bare install_github after library(remotes) is read, and the call reads its arguments as code", {
  a <- read_cell('library(remotes)\ninstall_github(repo)')
  expect_equal(a$installs$package, NA_character_)
  expect_true(a$installs$top)
  expect_true("repo" %in% a$references$name)
  expect_equal(a$packages$name, "remotes")
})

test_that("an install call inside a condition is read but isn't the top-level expression; one in a function is an ordinary call", {
  a <- read_cell('if (!requireNamespace("toyD")) remotes::install_github("lab/toyD")')
  expect_equal(a$installs$source, "github:lab/toyD")
  expect_false(a$installs$top)
  expect_equal(a$packages$name, "toyD")

  a <- read_cell('setup <- function() remotes::install_github("lab/toyD")')
  expect_equal(nrow(a$installs), 0)
  expect_equal(a$packages$name, "remotes")
})

test_that("a call that names no readable package, or a subdirectory, is still one the worker skips", {
  i <- installs_of('remotes::install_github("lab/repo/pkgdir")\ninstall.packages(pkgs)')
  expect_equal(i$package, c(NA_character_, NA_character_))
  expect_equal(i$top, c(TRUE, TRUE))
})

# ---- The graph ---------------------------------------------------------------

test_that("two install calls giving one package different sources are a source_conflict", {
  g <- notebook_graph(list(A = 'remotes::install_github("lab/toyD")', B = 'install.packages("toyD", repos = "https://lab.r-universe.dev")',
                           C = "library(toyD)"))
  e <- Find(function(e) identical(e$kind, "source_conflict"), g$errors)
  expect_false(is.null(e))
  expect_setequal(e$cells, c("A", "B"))
  expect_equal(e$message, "toyD is installed from two places: github:lab/toyD, universe:lab.")
  expect_equal(e$fixes, "Keep one install call for toyD")
  expect_equal(declared_sources(g, "toyD"), character())

  # The same source twice is no conflict; a disabled cell's call doesn't count.
  g <- notebook_graph(list(A = 'remotes::install_github("lab/toyD")', B = 'remotes::install_github("lab/toyD")'))
  expect_false(any(vapply(g$errors, function(e) identical(e$kind, "source_conflict"), logical(1))))
  g <- notebook_graph(list(A = 'remotes::install_github("lab/toyD")', B = 'install.packages("toyD", repos = "https://lab.r-universe.dev")'),
                      disabled = "B")
  expect_length(g$errors, 0)
  expect_equal(declared_sources(g, "toyD"), c(toyD = "github:lab/toyD"))
})

test_that("declared sources are for wanted packages, match the repository's name ignoring case, and fill in a built-in", {
  g <- notebook_graph(list(A = 'remotes::install_github(c("lab/MyPkg", "lab/unused"))', B = "library(mypkg); library(emberui)"))
  expect_equal(declared_sources(g, c("emberui", "mypkg"), builtin = c(emberui = "universe:jowch")),
               c(emberui = "universe:jowch", mypkg = "github:lab/MyPkg"))
})

test_that("sync_sources: the code wins, a built-in fills only a gap, and an entry whose call is gone stays", {
  h <- list(sources = c(emberui = "github:me/emberui", toyD = "universe:old"))
  out <- sync_sources(h, c(emberui = "universe:jowch", toyD = "universe:lab"), builtin = c(emberui = "universe:jowch"))
  expect_equal(out$sources, c(emberui = "github:me/emberui", toyD = "universe:lab"))
  expect_identical(sync_sources(out, character()), out)
  expect_identical(sync_sources(out, c(toyD = "universe:lab")), out)
})

# ---- The session -------------------------------------------------------------

test_that("an install call's source goes into the header and the package is looked up there", {
  s <- install_state(list(A = cell('install.packages("toyD", repos = "https://lab.r-universe.dev")'),
                          B = cell("library(toyD)")))
  r <- drive(s, ev_open(at(1)))
  expect_equal(r$state$file$header$sources, c(toyD = "universe:lab"))
  expect_setequal(fetch_keys(r), c("universe/lab/toyD", "cran/2026-09-01"))
  expect_match(format_notebook(notebook_file_of(r$state)), '# toyD = "universe:lab"', fixed = TRUE)

  # Changing the call moves the source; removing it keeps the record.
  r <- drive(r$state, ev_apply(list(op_set_code("A", 'remotes::install_github("lab/toyD")')), at(2)))
  expect_equal(r$state$file$header$sources, c(toyD = "github:lab/toyD"))
  r <- drive(r$state, ev_apply(list(op_set_code("A", "1")), at(3)))
  expect_equal(r$state$file$header$sources, c(toyD = "github:lab/toyD"))
})

test_that("the source ops are refused for a package whose source an install call names", {
  s <- install_state(list(A = cell('remotes::install_github("lab/toyD")'), B = cell("library(toyD)")))
  r <- drive(s, ev_open(at(1)))
  r2 <- drive(r$state, ev_apply(list(list(op = "set_package_source", name = "toyD", source = "universe:lab")), at(2)))
  expect_s3_class(r2$reply, "ember_refused")
  expect_match(conditionMessage(r2$reply), "install call in code; change it there instead", fixed = TRUE)
  r2 <- drive(r$state, ev_apply(list(list(op = "remove_package_source", name = "toyD")), at(2)))
  expect_s3_class(r2$reply, "ember_refused")
  expect_equal(r2$state$file$header$sources[["toyD"]], "github:lab/toyD")
})

test_that("the run message lists the top-level install calls, and the worker's report becomes the cell's note", {
  s <- fake_state(list(A = cell('remotes::install_github("lab/toyD")\nif (FALSE) install.packages("x2")\nx <- 1')))
  r <- boot(s, "A")
  expect_equal(last_sent(r)$installs, list(list(index = 1L, packages = "toyD")))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x", from_lock = "toyD"), at(10)))
  expect_equal(r$state$results$A$from_lock, "toyD")
  js <- pluto_state(r$state)$js
  check_wire(js)
  expect_equal(js$cell_results$A$ember$from_lock, as_arr("toyD"))

  s <- fake_state(list(A = cell("x <- 1")))
  r <- boot(s, "A")
  expect_null(last_sent(r)$installs)
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "x"), at(10)))
  expect_null(pluto_state(r$state)$js$cell_results$A$ember$from_lock)
})

test_that("a call whose packages couldn't be read still gets the note, without names", {
  s <- fake_state(list(A = cell("install.packages(pkgs)")))
  r <- boot(s, "A")
  expect_equal(last_sent(r)$installs, list(list(index = 1L, packages = character())))
  r <- drive(r$state, wk_done(1, last_token(r), report(from_lock = ""), at(10)))
  expect_equal(pluto_state(r$state)$js$cell_results$A$ember$from_lock, list())
})

# ---- ember::run() ------------------------------------------------------------

test_that("run() takes top-level install calls out of the file, keeping every line where it was", {
  text <- 'x <- 1\nlibrary(remotes); install_github("me/thing")\nremotes::install_github(\n  "lab/toyD"\n); y <- 2\nif (FALSE) install.packages("x2")\n'
  out <- without_install_calls(text)
  expect_equal(out$packages, c("thing", "toyD"))
  expect_equal(strsplit(out$text, "\n")[[1]],
               c("x <- 1", "library(remotes); invisible(NULL)", "invisible(NULL)", "", "; y <- 2",
                 'if (FALSE) install.packages("x2")'))
  expect_null(without_install_calls("x <- 1\n"))
  expect_null(without_install_calls("x <- (\n"))
})
