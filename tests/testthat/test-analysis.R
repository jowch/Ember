# Tests for read_cell() (R/analysis.R). Translated from the corpus at
# scratchpad/sketch/tests-spec.md into this package's API: read_cell()
# returns an ember_cell_analysis whose fields are data frames
# (definitions, references, packages, settings, sourced, notes) plus a
# list of formula_site and an optional parse_error. Graph-level cases from
# that corpus are out of scope here (R/graph.R).

defs <- function(a) a$definitions$name
refs <- function(a) a$references$name

test_that("ordered top-level reads: a self-reference before definition is a reference", {
  a <- read_cell("s <- s + 1")
  expect_setequal(defs(a), "s")
  expect_setequal(refs(a), c("s", "+"))
})

test_that("ordered top-level reads: a name read before it is (re)defined later", {
  a <- read_cell("y <- x; x <- 1")
  expect_setequal(defs(a), c("y", "x"))
  expect_setequal(refs(a), "x")
})

test_that("a name defined before it is read is not a reference", {
  a <- read_cell("x <- 1; y <- x + 1")
  expect_setequal(defs(a), c("x", "y"))
  expect_setequal(refs(a), "+")
})

test_that("assignment operators: <-, =, ->, <<-, ->>, and a string target", {
  a <- read_cell('1 -> a; b = 2; c <<- 3; d ->> e; "q" <- 4')
  expect_setequal(defs(a), c("a", "b", "c", "e", "q"))
  expect_equal(a$definitions$kind, rep("assign", 5))
  expect_setequal(refs(a), "d")
})

test_that("function bodies: arguments and body locals are never references", {
  a <- read_cell("f <- function(a, b = k) { z <- a + w; z }")
  expect_setequal(defs(a), "f")
  expect_equal(a$definitions$kind, "function")
  expect_setequal(refs(a), c("k", "w", "+"))
})

test_that("free names read only inside a function body are unordered", {
  a <- read_cell("f <- function() g(); g <- function() 1")
  expect_setequal(defs(a), c("f", "g"))
  expect_equal(nrow(a$references), 0)
})

test_that("a nested <<- reads but does not define its target", {
  a <- read_cell("f <- function() { counter <<- counter + 1 }")
  expect_setequal(defs(a), "f")
  expect_setequal(refs(a), c("counter", "+"))
})

test_that("for defines its variable and reads the sequence and prior accumulator", {
  a <- read_cell("for (i in seq_len(n)) total <- total + i")
  expect_setequal(defs(a), c("i", "total"))
  expect_equal(a$definitions$kind[a$definitions$name == "i"], "for")
  expect_setequal(refs(a), c("seq_len", "n", "total", "+"))
})

test_that("if defines what either branch defines", {
  a <- read_cell("if (flag) a <- 1 else b <- 2")
  expect_setequal(defs(a), c("a", "b"))
  expect_setequal(refs(a), "flag")
})

test_that("if: one branch does not see the other branch's definition", {
  a <- read_cell("if (p) a <- 1 else print(a)")
  expect_setequal(defs(a), "a")
  expect_setequal(refs(a), c("p", "print", "a"))
})

test_that("local() hides its own definitions but reads escape it", {
  a <- read_cell("res <- local({ tmp <- read(); tmp * k })")
  expect_setequal(defs(a), "res")
  expect_setequal(refs(a), c("read", "k", "*"))
  expect_false("tmp" %in% refs(a))
})

test_that("<<- inside local() at top level defines globally", {
  a <- read_cell("local({ counter <<- 0 })")
  expect_setequal(defs(a), "counter")
  expect_equal(a$definitions$kind, "assign")
})

test_that("df$col <- v defines df (replacement) and reads df and v", {
  a <- read_cell("df$col <- v")
  expect_setequal(defs(a), "df")
  expect_equal(a$definitions$kind, "replacement")
  expect_setequal(refs(a), c("df", "v"))
  expect_false("col" %in% refs(a))
})

test_that("names(x)[i] <- nm resolves through nested replacement calls", {
  a <- read_cell("names(x)[i] <- nm")
  expect_setequal(defs(a), "x")
  expect_equal(a$definitions$kind, "replacement")
  expect_setequal(refs(a), c("x", "i", "nm"))
})

test_that("x[[i]] <- v defines x and reads i, v and x", {
  a <- read_cell("x[[i]] <- v")
  expect_setequal(defs(a), "x")
  expect_setequal(refs(a), c("i", "v", "x"))
})

test_that("-> defines its right-hand target", {
  a <- read_cell("v -> x")
  expect_setequal(defs(a), "x")
  expect_setequal(refs(a), "v")
})

test_that("%<>% reads and redefines its target as replacement", {
  a <- read_cell("x %<>% mutate(z = 1)")
  expect_setequal(defs(a), "x")
  expect_equal(a$definitions$kind, "replacement")
  expect_setequal(refs(a), c("x", "mutate"))
})

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
  expect_setequal(refs(a), "v")
  expect_false("n_distinct" %in% refs(a))
})

test_that("library(x, character.only = TRUE) attaches nothing and notes it", {
  a <- read_cell("library(pkg, character.only = TRUE)")
  expect_equal(nrow(a$packages), 0)
  expect_equal(a$notes$kind, "computed_package")
})

test_that("lm(y ~ x) with no data: every formula symbol is a reference", {
  a <- read_cell("lm(y ~ x)")
  expect_setequal(refs(a), c("lm", "y", "x"))
  expect_equal(length(a$formulas), 0)
})

test_that("a standalone formula (no enclosing call) is all references", {
  a <- read_cell("f <- y ~ x + z")
  expect_setequal(defs(a), "f")
  expect_setequal(refs(a), c("y", "x", "z"))
})

test_that("lm(y ~ poly(x, deg), data = df) reads by the column rule", {
  a <- read_cell("fit <- lm(y ~ poly(x, deg), data = df)")
  expect_setequal(defs(a), "fit")
  expect_setequal(refs(a), c("lm", "poly", "deg", "df"))
  expect_equal(length(a$formulas), 1)
  site <- a$formulas[[1]]
  expect_equal(site$fn, "lm")
  expect_equal(site$data, "df")
  expect_setequal(site$columns, c("y", "x"))
})

test_that("lm(y ~ x, df): a positional second argument is the data", {
  a <- read_cell("lm(y ~ x, df)")
  expect_setequal(refs(a), c("lm", "df"))
  expect_equal(a$formulas[[1]]$data, "df")
  expect_setequal(a$formulas[[1]]$columns, c("y", "x"))
})

test_that("y ~ . takes every other column, and . is never a name", {
  a <- read_cell("lm(y ~ ., data = df); f <- y ~ x")
  expect_setequal(defs(a), "f")
  expect_setequal(refs(a), c("lm", "df", "y", "x"))
  expect_setequal(a$formulas[[1]]$columns, "y")
})

test_that("s(x, k = k) in gam: the settings argument is a reference, not a column", {
  a <- read_cell("gam(y ~ s(x, k = k), data = df)")
  expect_setequal(a$formulas[[1]]$columns, c("y", "x"))
  expect_setequal(refs(a), c("gam", "s", "k", "df"))
})

test_that("offset(log(n)) takes its nested call's first argument as a column", {
  a <- read_cell("glm(n ~ s(x, k = k) + offset(log(n0)), data = d)")
  expect_setequal(a$formulas[[1]]$columns, c("n", "x", "n0"))
  expect_setequal(refs(a), c("glm", "s", "k", "offset", "log", "d"))
})

test_that("a formula outside any call is entirely references", {
  a <- read_cell("model_formula <- y ~ x")
  expect_setequal(refs(a), c("y", "x"))
  expect_equal(length(a$formulas), 0)
})

test_that("NSE: a piped mutate() reads the piped object and its argument", {
  a <- read_cell("df |> mutate(z = x * 2)")
  expect_setequal(refs(a), c("df", "mutate", "x", "*"))
  expect_false("z" %in% defs(a))
})

test_that("$ and @ read only the object, never the field or slot name", {
  a <- read_cell("x <- df$a + df@b")
  expect_setequal(refs(a), c("df", "+"))
  expect_false("a" %in% refs(a))
  expect_false("b" %in% refs(a))
})

test_that("quote() is never walked", {
  a <- read_cell("q <- quote(alpha + beta); helper(3)")
  expect_setequal(refs(a), "helper")
  expect_false("alpha" %in% refs(a))
  expect_false("beta" %in% refs(a))
})

test_that("bquote(.(a)) is walked: the .() part reads a global", {
  a <- read_cell("bquote(.(a))")
  expect_setequal(refs(a), c("bquote", "a"))
})

test_that("get() is untracked and does not create a reference to its argument", {
  a <- read_cell('v <- get("thing"); eval(parse(text = s))')
  expect_setequal(defs(a), "v")
  expect_setequal(refs(a), c("parse", "s"))
  expect_setequal(a$notes$kind, "untracked_read")
  expect_setequal(a$notes$detail, c("get", "eval"))
})

test_that("options(digits = 3) is a setting; options() and options(\"digits\") are reads", {
  a <- read_cell('d <- getOption("digits"); o <- options(); options("digits")')
  expect_equal(nrow(a$settings), 0)
})

test_that("options(digits = 4) at top level is a setting", {
  a <- read_cell("options(digits = 4)")
  expect_equal(a$settings$fn, "options")
})

test_that("Sys.setenv is always a setting, with no named argument required", {
  a <- read_cell('Sys.setenv(TZ = "UTC")')
  expect_equal(a$settings$fn, "Sys.setenv")
})

test_that("a setting call inside a function body is not caught statically", {
  a <- read_cell("f <- function() options(warn = 2)")
  expect_equal(nrow(a$settings), 0)
})

test_that("local({ options(...) }) still counts as a top-level setting", {
  a <- read_cell("local(options(warn = 2))")
  expect_equal(a$settings$fn, "options")
})

test_that("withr::with_options is a scoped setting, not a global one", {
  a <- read_cell("withr::with_options(list(digits = 3), print(fit))")
  expect_equal(nrow(a$settings), 0)
  expect_setequal(a$packages$name, "withr")
  expect_false(a$packages$attached)
  expect_setequal(refs(a), c("list", "print", "fit"))
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
  expect_setequal(refs(a), c("nlsLM", "y", "a"))
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
  expect_setequal(refs(a), c("file.path", "dir"))
})

test_that("ignored_names are never definitions or references", {
  a <- read_cell("T <- 1; x <- TRUE + NA")
  expect_false("T" %in% defs(a))
  expect_false(any(c("TRUE", "NA") %in% refs(a)))
})

test_that("a parse error is reported with its line, and leaves every field empty", {
  a <- read_cell("1 + * 2")
  expect_false(is.null(a$parse_error))
  expect_equal(a$parse_error$line, 1)
  expect_equal(nrow(a$definitions), 0)
  expect_equal(nrow(a$references), 0)
  expect_equal(nrow(a$packages), 0)
})

test_that("empty code reads as an analysis with nothing in it", {
  a <- read_cell("")
  expect_equal(nrow(a$definitions), 0)
  expect_equal(nrow(a$references), 0)
  expect_null(a$parse_error)
})

test_that("the native pipe's _ placeholder is desugared before we ever see it", {
  a <- read_cell("df |> lm(y ~ x, data = _)")
  expect_setequal(refs(a), c("lm", "df"))
  expect_equal(a$formulas[[1]]$data, "df")
  expect_setequal(a$formulas[[1]]$columns, c("y", "x"))
})

test_that("a backslash lambda reads like an ordinary function", {
  a <- read_cell("\\(x) x + k")
  expect_equal(nrow(a$definitions), 0)
  expect_setequal(refs(a), c("k", "+"))
})

test_that("definitions_of and references_of return unique names in source order", {
  a <- read_cell("x <- 1; x <- 2; y <- x")
  expect_equal(definitions_of(a), c("x", "y"))
  expect_equal(references_of(a), character())
})

test_that("assign() and data() at top level are call-kind definitions", {
  a <- read_cell('assign("made", 1); data(iris); assign(nm, 2)')
  expect_setequal(defs(a), c("made", "iris"))
  expect_equal(a$definitions$kind, c("call", "call"))
  expect_setequal(refs(a), "nm")
})

# ---- Item 1: empty arguments must never crash the walker -------------------

test_that("m[, 2] <- 0: an empty replacement-target argument is skipped", {
  a <- read_cell("m[, 2] <- 0")
  expect_setequal(defs(a), "m")
  expect_setequal(refs(a), "m")
})

test_that("df[df$a > 1, ] <- 0: an empty argument after a filter is skipped", {
  a <- read_cell("df[df$a > 1, ] <- 0")
  expect_setequal(defs(a), "df")
  expect_setequal(refs(a), c("df", ">"))
})

test_that("f <- function() d[1, ]: an empty argument inside a body is skipped", {
  a <- read_cell("f <- function() d[1, ]")
  expect_setequal(defs(a), "f")
  expect_setequal(refs(a), c("[", "d"))
})

test_that("g <- function(m) apply(m[, 1:2], 1, sum): empty arg under a call is skipped", {
  a <- read_cell("g <- function(m) apply(m[, 1:2], 1, sum)")
  expect_setequal(defs(a), "g")
  expect_setequal(refs(a), c("apply", "[", ":", "sum"))
})

test_that("switch(x, a = , b = 1): an empty alternative value is skipped", {
  a <- read_cell("f <- function() switch(x, a = , b = 1)")
  expect_setequal(defs(a), "f")
  expect_setequal(refs(a), c("switch", "x"))
})

test_that("lm(y ~ X[, 1]): an empty argument inside a formula term is skipped", {
  a <- read_cell("lm(y ~ X[, 1])")
  expect_setequal(refs(a), c("lm", "y", "[", "X"))
})

# ---- Item 2: pkg::fn(...) goes through the same rules as fn(...) -----------

test_that("ggplot2::theme_set(...) is a setting, and ggplot2 is used", {
  a <- read_cell("ggplot2::theme_set(theme_bw())")
  expect_equal(a$settings$fn, "theme_set")
  expect_setequal(a$packages$name, "ggplot2")
  expect_false(a$packages$attached)
})

test_that("base::options(digits = 2) is a setting, and base is used", {
  a <- read_cell("base::options(digits = 2)")
  expect_equal(a$settings$fn, "options")
  expect_setequal(a$packages$name, "base")
  expect_false(a$packages$attached)
})

test_that("top-level withr::local_options(...) is a setting", {
  a <- read_cell("withr::local_options(list(digits = 3))")
  expect_equal(a$settings$fn, "local_options")
  expect_setequal(a$packages$name, "withr")
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

test_that("base::get(\"x\") gets the untracked_read note, and base is used", {
  a <- read_cell('base::get("x")')
  expect_equal(a$notes$kind, "untracked_read")
  expect_equal(a$notes$detail, "get")
  expect_setequal(a$packages$name, "base")
  expect_false(a$packages$attached)
})

# ---- Item 3: order-aware locals inside function bodies ----------------------

test_that("a function body reads a global before reassigning the same name", {
  a <- read_cell("clean <- function() { data <- na.omit(data) }")
  expect_setequal(defs(a), "clean")
  expect_setequal(refs(a), c("na.omit", "data"))
})

test_that("a replacement assignment inside a body reads its target before rebinding it", {
  a <- read_cell("f <- function() { df$z <- df$x * 2; df }")
  expect_setequal(defs(a), "f")
  expect_setequal(refs(a), c("df", "*"))
})

test_that("a name assigned earlier in a body is not a reference later on", {
  a <- read_cell("f <- function() { total <- 0; total <- total + 1; total }")
  expect_setequal(defs(a), "f")
  expect_setequal(refs(a), "+")
})

# ---- Item 4: data() only defines from unnamed args and list = -------------

test_that("data(iris, envir = e) defines iris only, and reads e", {
  a <- read_cell("data(iris, envir = e)")
  expect_equal(defs(a), "iris")
  expect_setequal(refs(a), "e")
})

test_that("data(list = c('iris', 'mtcars')) defines every name in the vector", {
  a <- read_cell('data(list = c("iris", "mtcars"))')
  expect_setequal(defs(a), c("iris", "mtcars"))
})

# ---- Item 5: $/@ inside a formula reads the object only --------------------

test_that("lm(d$y ~ d$x) references d only", {
  a <- read_cell("lm(d$y ~ d$x)")
  expect_setequal(refs(a), c("lm", "d"))
  expect_false("y" %in% refs(a))
  expect_false("x" %in% refs(a))
})

# ---- Item 6: source()/data() inside local() at the top level ---------------

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

# ---- Item 7: pronouns, break/next, source parse errors, options(op) --------

test_that(".x, .y, .data and .env are never references", {
  a <- read_cell("map(xs, ~ .x + .data$col + .env$k)")
  expect_setequal(refs(a), c("map", "xs"))
})

test_that("break and next inside a loop are not references", {
  a <- read_cell("f <- function() { for (i in 1:3) { if (i > 1) break; next } }")
  expect_setequal(defs(a), "f")
  expect_setequal(refs(a), c(":", ">"))
})

test_that("a sourced file that fails to parse gets a source_parse_error note", {
  a <- read_cell('source("bad.R")', function(path) "1 + ")
  expect_equal(nrow(a$definitions), 0)
  expect_equal(a$notes$kind, "source_parse_error")
  expect_true(nzchar(a$notes$detail))
})

test_that("options(op) with an unnamed non-string argument is a setting", {
  a <- read_cell("op <- options(digits = 5); options(op)")
  expect_equal(a$settings$fn, "options")
})

test_that("options() and options(\"digits\") are still reads, not settings", {
  a <- read_cell('options(); options("digits")')
  expect_equal(nrow(a$settings), 0)
})

# ---- Item 8: read_cell() must not be quadratic in cell length --------------

test_that("read_cell() reads 6000 generated lines in well under 2 seconds", {
  code <- paste(sprintf("x%d <- f(x%d, y)", 1:6000, 0:5999), collapse = "\n")
  elapsed <- system.time(a <- read_cell(code))[["elapsed"]]
  expect_equal(nrow(a$definitions), 6000)
  expect_lt(elapsed, 2)
})
