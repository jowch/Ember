# S4 class names written as strings (#41): `setClass("Circle")` defines
# `.__C__Circle`, the binding R keeps the class in, and a string in a class
# position (`new("Circle")`, a `setMethod()` signature, `contains =`) reads
# it. Reading is read_cell(); edges and errors are notebook_graph(); the
# last tests run a real worker.

has_edge <- function(g, from, to, name, via) {
  any(g$edges$from == from & g$edges$to == to & g$edges$name == name & g$edges$via == via)
}

def_names <- function(a, kind) a$definitions$name[a$definitions$kind == kind]

# ---- Reading -----------------------------------------------------------------

test_that("setClass(), setClassUnion() and setRefClass() define their class", {
  a <- read_cell(paste(
    "setClass('Shape', representation('VIRTUAL'))",
    "Circle <- setClass(Class = 'Circle', contains = 'Shape')",
    "setClassUnion('NumOrChar', c('numeric', 'character'))",
    "Account <- setRefClass('Account', fields = list(balance = 'numeric'))",
    "setClass(cls)",                                    # computed: nothing
    sep = "\n"))
  expect_equal(def_names(a, "class"),
               c(".__C__Shape", ".__C__Circle", ".__C__NumOrChar", ".__C__Account"))
  expect_true(all(c("Circle", "Account") %in% def_names(a, "assign")))
})

test_that("a class created inside a function body is not the cell's", {
  a <- read_cell("make <- function() setClass('Later')")
  expect_length(def_names(a, "class"), 0)
})

test_that("string class names in class positions read the class", {
  a <- read_cell(paste(
    "x <- new('Circle', r = 1)",
    "setMethod('area', signature(s = 'Tri', y = 'Num'), function(s, y) 1)",
    "setValidity('Sq', function(object) TRUE)",
    "is(x, 'Hex')",
    "as(x, Class = 'Oct')",
    "setAs('Pent', 'numeric', function(from) 1)",
    "getClass('Rect')",
    sep = "\n"))
  expect_setequal(grep("^\\.__C__", a$references$name, value = TRUE),
                  paste0(".__C__", c("Circle", "Tri", "Num", "Sq", "Hex", "Oct", "Pent",
                                     "numeric", "Rect")))
})

test_that("setClass() reads its superclasses and slot classes", {
  a <- read_cell(paste(
    "setClass('A', representation('Base', r = 'numeric'))",
    "setClass('B', contains = c('Base2'), slots = c('untyped', p = 'Point'))",
    "setRefClass('C', fields = c('anything', q = 'Queue'), contains = 'RBase')",
    sep = "\n"))
  reads <- grep("^\\.__C__", a$references$name, value = TRUE)
  expect_setequal(reads, paste0(".__C__", c("Base", "numeric", "Base2", "Point", "Queue", "RBase")))
})

test_that("a class the cell defines itself is no read, and nor is a computed name", {
  a <- read_cell("setClass('Circle', representation(r = 'numeric'))\nnew('Circle', r = 1)\nnew(cls)")
  expect_false(".__C__Circle" %in% a$references$name)
})

test_that("a class name read inside a function body is the cell's read", {
  a <- read_cell("make <- function(r) new('Circle', r = r)")
  expect_true(".__C__Circle" %in% a$references$name)
})

# ---- Graph -------------------------------------------------------------------

test_that("the issue's notebook runs the class cell first", {
  g <- notebook_graph(c(
    gen = "setGeneric('area', function(s) standardGeneric('area'))",
    m   = "setMethod('area', 'Circle', function(s) pi * s@r^2)",
    use = "area(new('Circle', r = 1))",
    cls = "setClass('Circle', representation(r = 'numeric'))"))
  expect_true(has_edge(g, "m", "cls", ".__C__Circle", "definition"))
  expect_true(has_edge(g, "use", "cls", ".__C__Circle", "definition"))
  expect_equal(g$order, c("gen", "cls", "m", "use"))
  expect_length(g$errors, 0)
})

test_that("a subclass depends on its superclass, and setValidity() on the class", {
  g <- notebook_graph(c(
    shape  = "setClass('Shape', representation('VIRTUAL'))",
    circle = "Circle <- setClass('Circle', contains = 'Shape', representation(d = 'numeric'))",
    valid  = "setValidity('Circle', function(object) object@d > 0)"))
  expect_true(has_edge(g, "circle", "shape", ".__C__Shape", "definition"))
  expect_true(has_edge(g, "valid", "circle", ".__C__Circle", "definition"))
  expect_setequal(downstream(g, "shape", transitive = TRUE), c("circle", "valid"))
})

test_that("a class learned from a run counts like one read from the code", {
  g <- notebook_graph(c(cls = "do.call(setClass, list('Circle'))", use = "new('Circle')"),
                      learned = list(definitions = list(cls = ".__C__Circle")))
  expect_true(has_edge(g, "use", "cls", ".__C__Circle", "definition"))
  expect_length(g$errors, 0)
})

test_that("a class exported by an attached package resolves to the attaching cell", {
  g <- notebook_graph(c(lib = "library(shapes)", use = "x <- new('Blob')"),
                      exports = list(shapes = c(".__C__Blob", "blob_area")))
  expect_true(has_edge(g, "use", "lib", ".__C__Blob", "package"))
})

test_that("one class in two cells is a multiple-definitions error", {
  g <- notebook_graph(c(a = "setClass('A')", b = "setClass('A', representation(x = 'numeric'))"))
  expect_length(g$errors, 1)
  e <- g$errors[[1]]
  expect_equal(e$kind, "multiple_definitions")
  expect_setequal(e$cells, c("a", "b"))
  expect_equal(e$message, "Class A is defined in more than one cell.")
  expect_match(project_error(e)$msg, "^Multiple definitions for class A\n")
})

test_that("a dot-name that is no class binding stays private", {
  g <- notebook_graph(c(a = ".helper <- 1", b = ".helper + 1"))
  expect_equal(g$errors[[1]]$kind, "private_name")
})

# ---- Running -------------------------------------------------------------------

test_that("a class cell placed last still runs before the cells that use it", {
  cells <- list(S = cell(""),
                G = cell("setGeneric('area', function(s) standardGeneric('area'))"),
                M = cell("setMethod('area', 'Ci', function(s) 3 * s@r^2)"),
                U = cell("area(new('Ci', r = 1))"),
                C = cell("setClass('Ci', representation(r = 'numeric'))"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 30)

  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  for (id in c("G", "M", "U", "C")) expect_equal(snap_view(snap, id)$status, "ok", info = id)
  expect_equal(snap_view(snap, "U")$output$text, "[1] 3")
})

test_that("editing the class cell reruns the cells that use the class", {
  cells <- list(S = cell(""),
                C = cell("setClass('Ci', representation(r = 'numeric'), prototype(r = 1))"),
                G = cell("setGeneric('area', function(s) standardGeneric('area'))"),
                M = cell("setMethod('area', 'Ci', function(s) 3 * s@r^2)"),
                U = cell("area(new('Ci'))"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_cells(nb, wait = TRUE, timeout = 30)
  expect_equal(snap_view(notebook_snapshot(nb), "U")$output$text, "[1] 3")

  edit_notebook(nb, set_code("C", "setClass('Ci', representation(r = 'numeric'), prototype(r = 2))"))
  res <- run_cells(nb, "C", wait = TRUE, timeout = 30)

  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, "M")$status, "ok")
  expect_equal(snap_view(snap, "U")$output$text, "[1] 12")
})

test_that("deleting the class cell removes the class, not only its binding", {
  cells <- list(S = cell(""),
                C = cell("setClass('Ci', representation(r = 'numeric'))"),
                U = cell("tryCatch(new('Ci', r = 1)@r, error = function(e) 'no class')"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_cells(nb, wait = TRUE, timeout = 30)
  expect_equal(snap_view(notebook_snapshot(nb), "U")$output$text, "[1] 1")

  edit_notebook(nb, delete_cell("C"))
  res <- run_cells(nb, "U", wait = TRUE, timeout = 30)

  expect_false(res$timed_out)
  expect_equal(snap_view(notebook_snapshot(nb), "U")$output$text, '[1] "no class"')
})
