# Tests for the walker's core language constructs (R/walk.R): dispatch,
# assignment and replacement targets, function/local/if/for, and the
# generic call-argument path (including settings and untracked reads,
# which dispatch_call_by_name handles directly).

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
  expect_setequal(refs(a), c("local", "read", "k", "*"))
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

test_that("get('thing') resolves to a reference; eval() stays untracked", {
  a <- read_cell('v <- get("thing"); eval(parse(text = s))')
  expect_setequal(defs(a), "v")
  expect_setequal(refs(a), c("get", "thing", "eval", "parse", "s"))
  expect_setequal(a$notes$kind, "untracked_read")
  expect_setequal(a$notes$detail, "eval")
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

test_that("a settings call inside local() doesn't count statically", {
  a <- read_cell("local(options(warn = 2))")
  expect_equal(nrow(a$settings), 0)
  b <- read_cell("local({ op <- options(digits = 3); on.exit(options(op)); print(x) })")
  expect_equal(nrow(b$settings), 0)
})

test_that("each setting a call names is its own key", {
  a <- read_cell('options(digits = 3, scipen = 2); Sys.setenv(TZ = "UTC"); Sys.unsetenv("LANG")')
  expect_setequal(a$settings$setting, c("option:digits", "option:scipen", "env:TZ", "env:LANG"))
  expect_setequal(read_cell('options(list(warn = 1))')$settings$setting, "option:warn")
  expect_equal(read_cell("setwd('data')")$settings$setting, "wd")
  expect_equal(read_cell('Sys.setlocale("LC_ALL", "C")')$settings$setting, "locale")
  expect_equal(read_cell("ggplot2::theme_set(theme_bw())")$settings$setting, "theme")
  expect_equal(read_cell("attach(mtcars)")$settings$setting, "attach:mtcars")
  expect_equal(read_cell('attach(df, name = "d")')$settings$setting, "attach:d")
})

test_that("a setting whose name is computed is a setting with an unknown key", {
  a <- read_cell("options(opts)")
  expect_equal(a$settings$fn, "options")
  expect_true(is.na(a$settings$setting))
  b <- read_cell("do.call(Sys.setenv, vars)")
  expect_equal(nrow(b$settings), 0)
})

test_that("library() inside a function body uses the package but doesn't attach it", {
  a <- read_cell("f <- function() { library(dplyr); filter(x) }")
  expect_setequal(a$packages$name, "dplyr")
  expect_false(any(a$packages$attached))
  b <- read_cell("library(dplyr)")
  expect_true(b$packages$attached)
  c <- read_cell("local(library(dplyr))")
  expect_true(c$packages$attached)
})

test_that("withr::with_options is a scoped setting, not a global one", {
  a <- read_cell("withr::with_options(list(digits = 3), print(fit))")
  expect_equal(nrow(a$settings), 0)
  expect_setequal(a$packages$name, "withr")
  expect_false(a$packages$attached)
  expect_setequal(refs(a), c("list", "print", "fit"))
})

test_that("ignored_names are never definitions or references", {
  a <- read_cell("T <- 1; x <- TRUE + NA")
  expect_false("T" %in% defs(a))
  expect_false(any(c("TRUE", "NA") %in% refs(a)))
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

test_that("dt[, ..cols] reads the global cols, not the symbol ..cols", {
  a <- read_cell("dt[, ..cols]")
  expect_setequal(refs(a), c("[", "dt", "cols"))
  expect_false("..cols" %in% refs(a))
})

test_that("dt[, ..cols, with = FALSE] still reads cols", {
  a <- read_cell("dt[, ..cols, with = FALSE]")
  expect_setequal(refs(a), c("[", "dt", "cols"))
})

test_that("a ..x in the by position also reads the stripped name", {
  a <- read_cell("dt[, .N, by = ..grp]")
  expect_true("grp" %in% refs(a))
  expect_false("..grp" %in% refs(a))
})

test_that("...and ..1 inside a [ call are not stripped: they're not ..name", {
  a <- read_cell("f <- function(...) dt[, ...]")
  expect_false("" %in% refs(a))

  b <- read_cell("f <- function(...) dt[, ..1]")
  expect_false("1" %in% refs(b))
})

test_that("switch(x, a = , b = 1): an empty alternative value is skipped", {
  a <- read_cell("f <- function() switch(x, a = , b = 1)")
  expect_setequal(defs(a), "f")
  expect_setequal(refs(a), c("switch", "x"))
})

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

test_that("base::get(\"x\") resolves x as a reference, and base is used", {
  a <- read_cell('base::get("x")')
  expect_equal(nrow(a$notes), 0)
  expect_setequal(refs(a), "x")
  expect_setequal(a$packages$name, "base")
  expect_false(a$packages$attached)
})

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

test_that("break and next inside a loop are not references", {
  a <- read_cell("f <- function() { for (i in 1:3) { if (i > 1) break; next } }")
  expect_setequal(defs(a), "f")
  expect_setequal(refs(a), c(":", ">"))
})

test_that("options(op) with an unnamed non-string argument is a setting", {
  a <- read_cell("op <- options(digits = 5); options(op)")
  # Two distinct calls, both settings; before positions existed they
  # deduplicated onto one row by sharing a line (`;`-separated on line 1),
  # which was really standing in for two occurrences at different columns.
  expect_equal(a$settings$fn, c("options", "options"))
})

test_that("options() and options(\"digits\") are still reads, not settings", {
  a <- read_cell('options(); options("digits")')
  expect_equal(nrow(a$settings), 0)
})

test_that("backtick-called `for`(i): treated as an ordinary call", {
  a <- read_cell("`for`(i)")
  expect_setequal(refs(a), "i")
})

test_that("backtick-called `if`(): treated as an ordinary (argument-less) call", {
  a <- read_cell("`if`()")
  expect_equal(nrow(a$references), 0)
  expect_equal(nrow(a$definitions), 0)
})

test_that("backtick-called `function`(): treated as an ordinary (argument-less) call", {
  a <- read_cell("`function`()")
  expect_equal(nrow(a$references), 0)
  expect_equal(nrow(a$definitions), 0)
})

test_that("backtick-called `\\\\`(x): treated as an ordinary call", {
  a <- read_cell("`\\\\`(x)")
  expect_setequal(refs(a), "x")
})

test_that("theme_set(my_theme): the head and its argument are both references", {
  a <- read_cell("theme_set(my_theme)")
  expect_setequal(refs(a), c("theme_set", "my_theme"))
  expect_equal(a$settings$fn, "theme_set")
})

test_that("options(digits = 2): options itself is a reference too", {
  a <- read_cell("options(digits = 2)")
  expect_setequal(refs(a), "options")
})

test_that("Sys.setenv(A = '1'): the head is a reference", {
  a <- read_cell("Sys.setenv(A = '1')")
  expect_setequal(refs(a), "Sys.setenv")
})

test_that("local_options(list(digits = 3)): the head and its argument are references", {
  a <- read_cell("local_options(list(digits = 3))")
  expect_setequal(refs(a), c("local_options", "list"))
})

test_that("get('x') and exists('x'): the head and the resolved name are both references", {
  a <- read_cell("get('x')")
  expect_setequal(refs(a), c("get", "x"))
  expect_equal(nrow(a$notes), 0)

  b <- read_cell("exists('x')")
  expect_setequal(refs(b), c("exists", "x"))
  expect_equal(nrow(b$notes), 0)
})

test_that("local({ x <- 1; x }): local itself is a reference, x stays private", {
  a <- read_cell("local({ x <- 1; x })")
  expect_setequal(refs(a), "local")
  expect_equal(nrow(a$definitions), 0)
})

test_that("a recursive function local to a body does not reference itself", {
  a <- read_cell("g <- function() { h <- function(n) if (n > 0) h(n - 1); h(3) }")
  expect_setequal(defs(a), "g")
  expect_setequal(refs(a), c(">", "-"))
  expect_false("h" %in% refs(a))
})

test_that("..4 (and any ..N) is never a reference", {
  a <- read_cell("f <- function(...) ..4")
  expect_setequal(defs(a), "f")
  expect_equal(nrow(a$references), 0)
})

