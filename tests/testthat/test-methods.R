# Method definitions (the Pluto model): a cell that defines a method of a
# generic, by name (`print.foo <- function`), by `registerS3method()` or by
# `setMethod()`, feeds every cell that reads the generic. Reading is
# read_cell(); edges and errors are notebook_graph(); the last tests run a
# real worker.

method_edges <- function(g) g$edges[g$edges$via == "method", c("from", "to", "name")]

has_edge <- function(g, from, to, name, via) {
  any(g$edges$from == from & g$edges$to == to & g$edges$name == name & g$edges$via == via)
}

# ---- Reading -----------------------------------------------------------------

test_that("a top-level dotted function gives one method row per split", {
  a <- read_cell("print.foo <- function(x, ...) cat('foo')\nas.data.frame.bar <- function(x, ...) x")
  expect_equal(a$methods$generic, c("print", "as", "as.data", "as.data.frame"))
  expect_equal(a$methods$signature, c("foo", "data.frame.bar", "frame.bar", "bar"))
  expect_true(all(a$methods$form == "name"))
  expect_equal(a$methods$line, c(1L, 2L, 2L, 2L))
})

test_that("only public function literals at the top level are read as methods", {
  a <- read_cell(paste(
    "summary.stats <- summarise(df)",            # a value, not a function
    ".print.foo <- function(x) 1",               # private
    "f <- function() { print.bar <- function(x) 1 }",  # local to f
    "local({ print.baz <- function(x) 1 })",     # local to the block
    "print. <- function(x) 1",                   # nothing after the dot
    sep = "\n"))
  expect_equal(nrow(a$methods), 0)
})

test_that("registerS3method() and .S3method() record the generic and class", {
  a <- read_cell(paste(
    "registerS3method('format', 'foo', function(x, ...) 'f')",
    ".S3method(class = 'foo', 'summary', function(object, ...) 1)",
    "registerS3method(gen, 'foo', identity)",     # computed generic: nothing
    "registerS3method('print', cls, identity)",   # computed class
    sep = "\n"))
  expect_equal(a$methods$generic, c("format", "summary", "print"))
  expect_equal(a$methods$signature, c("foo", "foo", NA))
  expect_true(all(a$methods$form == "register"))
})

test_that("setMethod() records the generic and a literal signature", {
  a <- read_cell(paste(
    "setMethod('show', 'Foo', function(object) cat('Foo'))",
    "setMethod('area', signature('Sq', y = 'Num'), function(s, y) 1)",
    "setMethod(f = 'length', c('Bag'), function(x) 1L)",
    "setMethod('area', sig, function(s) 1)",
    sep = "\n"))
  expect_equal(a$methods$generic, c("show", "area", "length", "area"))
  expect_equal(a$methods$signature, c("Foo", "Sq,Num", "Bag", NA))
  expect_true(all(a$methods$form == "s4"))
})

test_that("method registrations inside a function body are not the cell's", {
  a <- read_cell("f <- function() registerS3method('print', 'foo', identity)")
  expect_equal(nrow(a$methods), 0)
})

test_that("the method body is read like any other code", {
  a <- read_cell("setMethod('show', 'Foo', function(object) cat(prefix, object@x))")
  expect_true("prefix" %in% a$references$name)
  expect_false("object" %in% a$references$name)
})

test_that("setGeneric() defines its generic", {
  a <- read_cell("setGeneric('area', function(shape) standardGeneric('area'))")
  expect_equal(a$definitions$name, "area")
  expect_equal(a$definitions$kind, "generic")
})

test_that("a sourced file's methods are the cell's", {
  files <- list("m.R" = "print.foo <- function(x, ...) 1\nsetMethod('show', 'Foo', function(object) 1)")
  a <- read_cell("source('m.R')", read_file = function(p) files[[p]])
  expect_equal(a$methods$generic, c("print", "show"))
  expect_equal(a$methods$file, c("m.R", "m.R"))
})

# ---- Edges -------------------------------------------------------------------

test_that("a cell reading a generic depends on every cell defining a method of it", {
  g <- notebook_graph(c(
    m1 = "print.foo <- function(x, ...) cat('foo')",
    m2 = "registerS3method('print', 'bar', function(x, ...) cat('bar'))",
    o  = "obj <- structure(1, class = 'foo')",
    u  = "print(obj)"
  ))
  expect_true(has_edge(g, "u", "m1", "print", "method"))
  expect_true(has_edge(g, "u", "m2", "print", "method"))
  expect_true(has_edge(g, "u", "o", "obj", "definition"))
  expect_setequal(downstream(g, "m1"), "u")
  expect_length(g$errors, 0)
})

test_that("passing the generic by name counts as reading it", {
  g <- notebook_graph(c(m = "format.foo <- function(x, ...) 'f'",
                        u = "vapply(xs, format, character(1))"))
  expect_true(has_edge(g, "u", "m", "format", "method"))
})

test_that("S4: setMethod feeds callers of the generic and runs after setGeneric", {
  g <- notebook_graph(c(
    gen  = "setGeneric('area', function(shape) standardGeneric('area'))",
    sq   = "setMethod('area', 'Sq', function(shape) shape@w^2)",
    call = "area(s)"
  ))
  expect_true(has_edge(g, "call", "gen", "area", "definition"))
  expect_true(has_edge(g, "call", "sq", "area", "method"))
  expect_true(has_edge(g, "sq", "gen", "area", "definition"))
  expect_equal(g$order, c("gen", "sq", "call"))
})

test_that("a dotted helper whose prefix is no generic is just a function", {
  g <- notebook_graph(c(
    h = "fit.plot <- function() plot(fit2)",
    a = "fit <- lm(y ~ x, data = d)",
    b = "fit2 <- update(fit, . ~ . + z)"
  ))
  expect_equal(nrow(method_edges(g)), 0)
  expect_length(g$errors, 0)
  expect_equal(nrow(g$cells$h$methods), 0)
})

test_that("a generic the notebook defines, or a package exports, makes a dotted function a method", {
  g <- notebook_graph(c(
    gen = "area <- function(shape) UseMethod('area')",
    m   = "area.circle <- function(shape) pi * shape$r^2",
    t   = "tidy.myfit <- function(x, ...) data.frame()",
    u   = "area(c1); tidy(f1)"
  ), exports = list(broom = "tidy"))
  expect_true(has_edge(g, "u", "m", "area", "method"))
  expect_true(has_edge(g, "u", "t", "tidy", "method"))
})

test_that("a variable named like the prefix doesn't make a dotted function a method", {
  g <- notebook_graph(c(d = "df <- read.csv('a.csv')",
                        h = "df.clean <- function(x) na.omit(x)",
                        u = "nrow(df)"))
  expect_equal(nrow(method_edges(g)), 0)
})

test_that("as.data.frame.foo is a method of as.data.frame, not of as or as.data", {
  g <- notebook_graph(c(m = "as.data.frame.foo <- function(x, ...) data.frame()",
                        u = "as.data.frame(obj)"))
  expect_equal(g$cells$m$methods$generic, "as.data.frame")
  expect_equal(g$cells$m$methods$key, "as.data.frame.foo")
  expect_true(has_edge(g, "u", "m", "as.data.frame", "method"))
})

test_that("an operator method feeds every cell using the operator", {
  g <- notebook_graph(c(m = "`+.money` <- function(e1, e2) e1",
                        u = "total <- a + b"))
  expect_true(has_edge(g, "u", "m", "+", "method"))
})

test_that("two cells that each define a print method and call print() form no cycle", {
  g <- notebook_graph(c(
    a = "print.foo <- function(x, ...) cat('foo'); print(structure(1, class = 'foo'))",
    b = "print.bar <- function(x, ...) cat('bar'); print(structure(1, class = 'bar'))",
    u = "print(x)"
  ))
  m <- method_edges(g)
  expect_equal(nrow(m[m$from %in% c("a", "b"), ]), 0)
  expect_length(g$errors, 0)
  expect_setequal(upstream(g, "u"), c("a", "b"))
})

test_that("many cells may add methods to one generic", {
  g <- notebook_graph(c(
    a = "print.foo <- function(x, ...) 1",
    b = "print.bar <- function(x, ...) 1",
    c = "setMethod('show', 'Foo', function(object) 1)",
    d = "setMethod('show', 'Bar', function(object) 1)"
  ))
  expect_length(g$errors, 0)
})

test_that("a method doesn't replace a definition edge for the same name", {
  g <- notebook_graph(c(def = "summary <- function(x) 'mine'",
                        m = "summary.foo <- function(object, ...) 1",
                        u = "summary(x)"))
  expect_true(has_edge(g, "u", "def", "summary", "definition"))
  expect_true(has_edge(g, "u", "m", "summary", "method"))
  expect_false(anyDuplicated(g$edges[c("from", "to", "name")]) > 0)
})

test_that("a disabled cell's methods give no edge", {
  g <- notebook_graph(c(m = "print.foo <- function(x, ...) 1", u = "print(x)"),
                      disabled = "m")
  expect_equal(nrow(g$edges), 0)
  expect_false("u" %in% names(g$off))
})

test_that("cell_summary() reports the cell's methods", {
  g <- notebook_graph(c(m = "setMethod('show', 'Foo', function(object) 1)"))
  s <- cell_summary(g, "m")
  expect_equal(s$methods$key, "show(Foo)")
})

# ---- Errors ------------------------------------------------------------------

test_that("one (generic, class) pair in two cells is a multiple-definitions error", {
  g <- notebook_graph(c(
    a = "print.foo <- function(x, ...) 1",
    b = "registerS3method('print', 'foo', function(x, ...) 2)",
    c = "setMethod('show', 'Foo', function(object) 1)",
    d = "setMethod('show', signature('Foo'), function(object) 2)",
    e = "setMethod('show', 'Bar', function(object) 1)"
  ))
  kinds <- vapply(g$errors, `[[`, character(1), "kind")
  expect_true(all(kinds == "multiple_definitions"))
  by_name <- setNames(g$errors, vapply(g$errors, function(e) e$names, character(1)))
  expect_setequal(names(by_name), c("print.foo", "show(Foo)"))
  expect_setequal(by_name[["print.foo"]]$cells, c("a", "b"))
  expect_equal(by_name[["print.foo"]]$message,
               "The print method for foo is defined in more than one cell.")
  expect_setequal(by_name[["show(Foo)"]]$cells, c("c", "d"))
  expect_setequal(blocked_cells(g), c("a", "b", "c", "d"))
})

test_that("two print.foo definitions give one error, not two", {
  g <- notebook_graph(c(a = "print.foo <- function(x, ...) 1",
                        b = "print.foo <- function(x, ...) 2"))
  expect_length(g$errors, 1)
  expect_equal(g$errors[[1]]$names, "print.foo")
})

test_that("a computed class never conflicts", {
  g <- notebook_graph(c(a = "registerS3method('print', cls, identity)",
                        b = "registerS3method('print', cls, identity)"))
  expect_length(g$errors, 0)
})

test_that("a cycle through a method edge suggests passing the value instead", {
  g <- notebook_graph(c(
    m = "print.res <- function(x, ...) cat(x$v / total)",
    t = "total <- sum(vals); print(r)"
  ))
  expect_length(g$errors, 1)
  e <- g$errors[[1]]
  expect_equal(e$kind, "cycle")
  expect_false(any(grepl("print is a column", e$fixes)))
  expect_true(any(grepl("print method", e$fixes)))
})

# ---- Running -------------------------------------------------------------------

test_that("editing a method reruns the cell that called its generic", {
  cells <- list(S = cell(""),
                M = cell("format.foo <- function(x, ...) 'old'"),
                O = cell("obj <- structure(list(), class = 'foo')"),
                P = cell("format(obj)"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_cells(nb, wait = TRUE, timeout = 20)
  expect_match(snap_view(notebook_snapshot(nb), "P")$output$text, "old")

  edit_notebook(nb, set_code("M", "format.foo <- function(x, ...) 'new'"))
  res <- run_cells(nb, "M", wait = TRUE, timeout = 20)

  expect_false(res$timed_out)
  expect_match(snap_view(notebook_snapshot(nb), "P")$output$text, "new")
})

test_that("S4 methods in separate cells all run", {
  cells <- list(S = cell(""),
                C = cell("setClass('Sq', representation(w = 'numeric'))\nsetClass('Ci', representation(r = 'numeric'))"),
                G = cell("setGeneric('area', function(shape) standardGeneric('area'))"),
                A = cell("setMethod('area', 'Sq', function(shape) shape@w^2)"),
                B = cell("setMethod('area', 'Ci', function(shape) 3 * shape@r^2)"),
                U = cell("area(new('Sq', w = 2)) + area(new('Ci', r = 1))"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 30)

  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  for (id in c("C", "G", "A", "B", "U")) expect_equal(snap_view(snap, id)$status, "ok", info = id)
  expect_equal(snap_view(snap, "U")$output$text, "[1] 7")
})
