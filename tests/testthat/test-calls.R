# Tests for package calls (library/box/qualified calls), source()
# following, data()/assign(), glue interpolation, and quoting calls
# (R/walk-calls.R).

test_that("library, require and pacman::p_load attach; pacman is only used", {
  a <- read_cell('library(dplyr); require("ggplot2"); pacman::p_load(sf, terra)')
  expect_setequal(a$packages$name, c("dplyr", "ggplot2", "pacman", "sf", "terra"))
  attached <- setNames(a$packages$attached, a$packages$name)
  expect_true(attached[["dplyr"]])
  expect_true(attached[["ggplot2"]])
  expect_true(attached[["sf"]])
  expect_true(attached[["terra"]])
  expect_false(attached[["pacman"]])
})

test_that("pkg::fn is a package use, not a reference to fn", {
  a <- read_cell('n <- dplyr::n_distinct(v); requireNamespace("jsonlite")')
  expect_setequal(a$packages$name, c("dplyr", "jsonlite"))
  expect_true(!any(a$packages$attached))
  expect_setequal(refs(a), c("v", "requireNamespace"))
  expect_false("n_distinct" %in% refs(a))
})

test_that("library(x, character.only = TRUE) attaches nothing and notes it", {
  a <- read_cell("library(pkg, character.only = TRUE)")
  expect_equal(nrow(a$packages), 0)
  expect_equal(a$notes$kind, "computed_package")
})

test_that("quote()'s argument is never walked, but quote itself is a reference", {
  a <- read_cell("q <- quote(alpha + beta); helper(3)")
  expect_setequal(refs(a), c("quote", "helper"))
  expect_false("alpha" %in% refs(a))
  expect_false("beta" %in% refs(a))
})

test_that("bquote(.(a)) is walked: the .() part reads a global", {
  a <- read_cell("bquote(.(a))")
  expect_setequal(refs(a), c("bquote", "a"))
})

test_that("source() merges a file's definitions, references and packages", {
  reader <- function(path) {
    if (path == "helpers.R") {
      "library(minpack.lm)\nfit_growth <- function(d) nlsLM(y ~ a, d)"
    } else {
      NULL
    }
  }
  a <- read_cell('source("helpers.R")', reader)
  expect_equal(a$definitions$name, "fit_growth")
  expect_equal(a$definitions$file, "helpers.R")
  expect_equal(a$definitions$line, 2)
  expect_setequal(a$packages$name, "minpack.lm")
  expect_true(a$packages$attached)
  expect_setequal(refs(a), c("source", "library", "nlsLM", "y", "a"))
  expect_equal(a$sourced$path, "helpers.R")
  expect_true(a$sourced$found)
})

test_that("nested source() files merge, and a self-sourcing file does not loop", {
  files <- list("a.R" = 'source("b.R")',
                "b.R" = 'source("a.R")\nq <- 1')
  reader <- function(path) files[[path]]
  a <- read_cell('source("a.R")', reader)
  expect_equal(a$definitions$name, "q")
  expect_equal(a$definitions$file, "b.R")
  expect_setequal(a$sourced$path, c("a.R", "b.R"))
  expect_equal(nrow(a$sourced), 2)
})

test_that("a missing source() file is noted, not an error", {
  a <- read_cell('source("gone.R")', function(path) NULL)
  expect_equal(nrow(a$definitions), 0)
  expect_equal(a$sourced$path, "gone.R")
  expect_false(a$sourced$found)
  expect_equal(a$notes$kind, "missing_file")
})

test_that("a computed source() path is noted and read for its own references", {
  a <- read_cell('source(file.path(dir, "h.R"))')
  expect_equal(nrow(a$sourced), 0)
  expect_equal(a$notes$kind, "computed_source")
  expect_setequal(refs(a), c("source", "file.path", "dir"))
})

test_that("assign() and data() at top level are call-kind definitions", {
  a <- read_cell('assign("made", 1); data(iris); assign(nm, 2)')
  expect_setequal(defs(a), c("made", "iris"))
  expect_equal(a$definitions$kind, c("call", "call"))
  expect_setequal(refs(a), c("assign", "data", "nm"))
})

test_that("base::library(dplyr) attaches dplyr, and dplyr is not a reference", {
  a <- read_cell("base::library(dplyr)")
  attached <- setNames(a$packages$attached, a$packages$name)
  expect_true(attached[["dplyr"]])
  expect_false(attached[["base"]])
  expect_false("dplyr" %in% refs(a))
})

test_that("base::source(...) is followed, and base is used", {
  a <- read_cell('base::source("a.R")', function(path) "made_by_source <- 1")
  expect_equal(defs(a), "made_by_source")
  expect_setequal(a$packages$name, "base")
})

test_that("utils::data(iris) defines iris, and utils is used", {
  a <- read_cell("utils::data(iris)")
  expect_equal(defs(a), "iris")
  expect_setequal(a$packages$name, "utils")
})

test_that("data(iris, envir = e) defines iris only, and reads e", {
  a <- read_cell("data(iris, envir = e)")
  expect_equal(defs(a), "iris")
  expect_setequal(refs(a), c("data", "e"))
})

test_that("data(list = c('iris', 'mtcars')) defines every name in the vector", {
  a <- read_cell('data(list = c("iris", "mtcars"))')
  expect_setequal(defs(a), c("iris", "mtcars"))
})

test_that("local(source(...)) follows the file and keeps its definitions", {
  a <- read_cell('local(source("a.R"))', function(path) "made_in_source <- 1")
  expect_equal(defs(a), "made_in_source")
})

test_that("local(source(..., local = TRUE)) does not add definitions", {
  a <- read_cell('local(source("a.R", local = TRUE))',
                 function(path) "made_in_source <- 1")
  expect_equal(nrow(a$definitions), 0)
  expect_equal(a$notes$kind, "computed_source")
})

test_that("source() inside a function body is untracked, not followed", {
  a <- read_cell('f <- function() { source("a.R") }',
                 function(path) "made_in_source <- 1")
  expect_equal(defs(a), "f")
  expect_false("made_in_source" %in% defs(a))
})

test_that("a sourced file that fails to parse gets a source_parse_error note", {
  a <- read_cell('source("bad.R")', function(path) "1 + ")
  expect_equal(nrow(a$definitions), 0)
  expect_equal(a$notes$kind, "source_parse_error")
  expect_true(nzchar(a$notes$detail))
})

test_that("source('a.R', local = ): an empty local= is treated as absent", {
  a <- read_cell("source('a.R', local = )", function(path) "made <- 1")
  expect_equal(defs(a), "made")
})

test_that("source(file = ): an empty file= path is skipped, not followed", {
  a <- read_cell("source(file = )")
  expect_equal(nrow(a$sourced), 0)
  expect_equal(nrow(a$notes), 0)
})

test_that("box::use(dplyr[]): an empty selector list attaches the package only", {
  a <- read_cell("box::use(dplyr[])")
  attached <- setNames(a$packages$attached, a$packages$name)
  expect_true(attached[["dplyr"]])
  expect_equal(nrow(a$definitions), 0)
})

test_that("library(dplyr) and require(dplyr): the head is a reference", {
  a <- read_cell("library(dplyr)")
  expect_setequal(refs(a), "library")
  b <- read_cell("require(dplyr)")
  expect_setequal(refs(b), "require")
})

test_that("source('a.R'): source itself is a reference alongside following the file", {
  a <- read_cell("source('a.R')", function(path) "y <- 1")
  expect_true("source" %in% refs(a))
  expect_equal(defs(a), "y")
})

test_that("data(iris) and assign('x', 1): the head is a reference", {
  a <- read_cell("data(iris)")
  expect_setequal(refs(a), "data")
  expect_equal(defs(a), "iris")

  b <- read_cell("assign('x', 1)")
  expect_setequal(refs(b), "assign")
  expect_equal(defs(b), "x")
})

test_that("substitute(f(), list(f = my_fn)): only the env argument is code", {
  a <- read_cell("substitute(f(), list(f = my_fn))")
  expect_setequal(refs(a), c("substitute", "list", "my_fn"))
  expect_false("f" %in% refs(a))
})

test_that("quote/expression/alist: every argument stays quoted", {
  a <- read_cell("quote(f(x))")
  expect_setequal(refs(a), "quote")

  b <- read_cell("expression(a + b)")
  expect_setequal(refs(b), "expression")

  cc <- read_cell("alist(a = , b = 2)")
  expect_setequal(refs(cc), "alist")
})

test_that("glue::glue interpolates {name} segments as references", {
  a <- read_cell("glue::glue('{total} of {n}')")
  expect_setequal(refs(a), c("total", "n"))
  expect_setequal(a$packages$name, "glue")
})

test_that("bare glue()/str_glue() record the head too", {
  a <- read_cell("glue('Hi {name}')")
  expect_setequal(refs(a), c("glue", "name"))

  b <- read_cell("str_glue('Hi {name}')")
  expect_setequal(refs(b), c("str_glue", "name"))
})

test_that("cli's glue-syntax functions interpolate too", {
  a <- read_cell("cli::cli_alert_success('Done, {n} items')")
  expect_setequal(refs(a), "n")
  expect_setequal(a$packages$name, "cli")
})

test_that("{{ escapes a literal brace, not an interpolation", {
  a <- read_cell("glue::glue('{{literal}}')")
  expect_equal(nrow(a$references), 0)
})

test_that("a literal .open/.close changes the interpolation delimiters", {
  a <- read_cell("glue::glue('<<x>>', .open = '<<', .close = '>>')")
  expect_setequal(refs(a), "x")
})

test_that("glue_data()'s first argument is data, not a template", {
  a <- read_cell("glue_data(df, '{col}')")
  expect_setequal(refs(a), c("glue_data", "df", "col"))
})

test_that("str_interp()'s ${...} segments are references, bare and qualified", {
  a <- read_cell("str_interp('Hello, ${hello}!')")
  expect_setequal(refs(a), c("str_interp", "hello"))

  b <- read_cell("stringr::str_interp('Hello, ${hello}!')")
  expect_setequal(refs(b), "hello")
  expect_setequal(b$packages$name, "stringr")
})

test_that("str_interp()'s $[fmt]{...} keeps only the expression, not the format", {
  a <- read_cell("str_interp('Val: $[.2f]{y}')")
  expect_setequal(refs(a), c("str_interp", "y"))
})

test_that("str_interp()'s env argument is ordinary code, not a template", {
  a <- read_cell("str_interp('${hello}', env = e)")
  expect_setequal(refs(a), c("str_interp", "hello", "e"))
})

test_that("a malformed str_interp template doesn't error", {
  a <- read_cell("str_interp('${unclosed')")
  expect_setequal(refs(a), "str_interp")

  b <- read_cell("str_interp('$[bad')")
  expect_setequal(refs(b), "str_interp")
})

test_that("get('x') resolves to a reference and drops the untracked_read note", {
  a <- read_cell('get("x")')
  expect_setequal(refs(a), c("get", "x"))
  expect_equal(nrow(a$notes), 0)
})

test_that("get(computed name) keeps the untracked_read note", {
  a <- read_cell('get(paste0("fit_", i))')
  expect_setequal(refs(a), c("get", "paste0", "i"))
  expect_equal(a$notes$kind, "untracked_read")
})

test_that("get('x', envir = e): an envir argument blocks resolution", {
  a <- read_cell('get("x", envir = e)')
  expect_setequal(refs(a), c("get", "e"))
  expect_false("x" %in% refs(a))
  expect_equal(a$notes$kind, "untracked_read")
})

test_that("exists('y', inherits = FALSE) keeps the note", {
  a <- read_cell('exists("y", inherits = FALSE)')
  expect_setequal(refs(a), "exists")
  expect_equal(a$notes$kind, "untracked_read")
})

test_that("exists('y') resolves like get(), even though it only tests presence", {
  a <- read_cell('exists("y")')
  expect_setequal(refs(a), c("exists", "y"))
  expect_equal(nrow(a$notes), 0)
})

test_that("mget(c('a', 'b')) resolves every literal name", {
  a <- read_cell('mget(c("a", "b"))')
  expect_setequal(refs(a), c("mget", "a", "b"))
  expect_equal(nrow(a$notes), 0)
})

test_that("mget(c('a', paste0('b'))) is not fully literal, keeps the note", {
  a <- read_cell('mget(c("a", paste0("b")))')
  expect_false("a" %in% refs(a))
  expect_equal(a$notes$kind, "untracked_read")
})

test_that("eval() is untouched by the get-family literal-name rule", {
  a <- read_cell('eval(parse(text = "1 + 1"))')
  expect_equal(a$notes$kind, "untracked_read")
})

test_that("a cell using str_interp() gets a definition edge on the cell defining the name", {
  A <- read_cell('hello <- "world"')
  B <- read_cell('stringr::str_interp("Hello, ${hello}!")')
  g <- build_test_graph(list(A = A, B = B), setup = "A")
  expect_true("A" %in% upstream(g, "B"))
  expect_true(any(g$edges$from == "B" & g$edges$to == "A" &
                    g$edges$name == "hello" & g$edges$via == "definition"))
})

