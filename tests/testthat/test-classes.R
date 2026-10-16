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

test_that("setOldClass() defines its first class and reads the rest", {
  a <- read_cell(paste(
    "setOldClass(c('lm2', 'lm'))",
    "setOldClass('tbl3')",
    "setOldClass(c(cls, 'glm'))",                       # computed first: reads glm
    sep = "\n"))
  expect_equal(def_names(a, "class"), c(".__C__lm2", ".__C__tbl3"))
  expect_true(all(c(".__C__lm", ".__C__glm") %in% refs(a)))
  expect_false(".__C__lm2" %in% refs(a))
})

test_that("setOldClass() orders a method on the old class after it", {
  g <- notebook_graph(c(
    S = "setMethod('show', 'lm2', function(object) cat('lm2'))",
    O = "setOldClass(c('lm2', 'lm'))"
  ))
  expect_true(has_edge(g, "S", "O", ".__C__lm2", "definition"))
  expect_equal(run_order(g), c("O", "S"))
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

test_that("setClass() reads its superclasses, and its slot classes softly", {
  a <- read_cell(paste(
    "setClass('A', representation('Base', r = 'numeric'))",
    "setClass('B', contains = c('Base2'), slots = c('untyped', p = 'Point'))",
    "setRefClass('C', fields = c('anything', q = 'Queue'), contains = 'RBase')",
    sep = "\n"))
  r <- a$references[grepl("^\\.__C__", a$references$name), ]
  expect_setequal(r$name[r$where == "code"], paste0(".__C__", c("Base", "Base2", "RBase")))
  expect_setequal(r$name[r$where == "slot"], paste0(".__C__", c("numeric", "Point", "Queue")))
  expect_false(".__C__Point" %in% references_of(a))
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

test_that("a slot class orders the cells, but never makes a cycle", {
  g <- notebook_graph(c(
    pt   = "setClass('Pt', representation(x = 'numeric'))",
    line = "setClass('Line', representation(a = 'Pt', b = 'Pt'))"))
  expect_true(has_edge(g, "line", "pt", ".__C__Pt", "definition"))

  g <- notebook_graph(c(
    aa = "setClass('AA', representation(b = 'BB'))",
    bb = "setClass('BB', representation(a = 'AA'))"))
  expect_length(g$errors, 0)
  expect_equal(nrow(g$edges), 1)
})

test_that("a slot class is a hard read where the cell also needs it", {
  g <- notebook_graph(c(
    aa = "setClass('AA', representation(b = 'BB'))\nx <- new('BB')",
    bb = "setClass('BB', representation(a = 'AA'))"))
  expect_true(has_edge(g, "aa", "bb", ".__C__BB", "definition"))
  expect_false(has_edge(g, "bb", "aa", ".__C__AA", "definition"))
})

test_that("a cycle through classes names them as classes, with no column-name fix", {
  g <- notebook_graph(c(a = "setClass('A', contains = 'B')", b = "setClass('B', contains = 'A')"))
  e <- Find(function(e) e$kind == "cycle", g$errors)
  expect_equal(e$message, "class A, class B form a cycle.")
  expect_length(e$fixes, 0)
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

test_that("a setOldClass() cell placed last runs first, and deleting it removes the class", {
  cells <- list(S = cell(""),
                M = cell("setMethod('show', 'lm2', function(object) cat('an lm2\\n'))"),
                U = cell("tryCatch(getClass('lm2')@className, error = function(e) 'no class')"),
                O = cell("setOldClass(c('lm2', 'lm'))"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 30)
  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  for (id in c("M", "U", "O")) expect_equal(snap_view(snap, id)$status, "ok", info = id)
  expect_match(snap_view(snap, "U")$output$text, '"lm2"', fixed = TRUE)

  edit_notebook(nb, delete_cell("O"))
  edit_notebook(nb, delete_cell("M"))
  res <- run_cells(nb, "U", wait = TRUE, timeout = 30)
  expect_false(res$timed_out)
  expect_equal(snap_view(notebook_snapshot(nb), "U")$output$text, '[1] "no class"')
})

test_that("a subclass or union in another cell doesn't count as changing the class", {
  cells <- list(S = cell(""),
                A = cell("setClass('Shape', representation('VIRTUAL'))"),
                B = cell("setClass('Circ', contains = 'Shape', representation(r = 'numeric'))"),
                N = cell("setClass('Node', representation(v = 'numeric'))"),
                V = cell("setClassUnion('NodeOrNULL', c('Node', 'NULL'))"),
                U = cell("c(is(new('Circ', r = 1), 'Shape'), is(new('Node', v = 1), 'NodeOrNULL'))"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 30)

  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  for (id in c("A", "B", "N", "V", "U")) expect_equal(snap_view(snap, id)$status, "ok", info = id)
  expect_equal(snap_view(snap, "U")$output$text, "[1] TRUE TRUE")
})

test_that("two classes whose slots name each other both run", {
  cells <- list(S = cell(""),
                A = cell("setClass('AA', representation(b = 'BB'))"),
                B = cell("setClass('BB', representation(a = 'AA'))"),
                U = cell("class(new('AA', b = new('BB'))@b)[[1]]"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 30)

  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  for (id in c("A", "B", "U")) expect_equal(snap_view(snap, id)$status, "ok", info = id)
  expect_equal(snap_view(snap, "U")$output$text, '[1] "BB"')
})

test_that("the trial's shapes notebook runs, and renaming a slot reruns the method", {
  cells <- list(S = cell(""),
                V = cell("setClass('Shape', representation('VIRTUAL'))"),
                C = cell("Circle <- setClass('Circle', contains = 'Shape', representation(radius = 'numeric'))"),
                R = cell("Rectangle <- setClass('Rectangle', contains = 'Shape',\n  representation(width = 'numeric', height = 'numeric'))"),
                G = cell("setGeneric('area', function(shape) standardGeneric('area'))"),
                MC = cell("setMethod('area', 'Circle', function(shape) shape@radius^2)"),
                MR = cell("setMethod('area', 'Rectangle', function(shape) shape@width * shape@height)"),
                P = cell("setMethod('show', 'Shape', function(object) cat('area', area(object), '\\n'))"),
                U = cell("vapply(list(Circle(radius = 2), Rectangle(width = 3, height = 4)), area, numeric(1))"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 60)
  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  for (id in names(cells)[-1]) expect_equal(snap_view(snap, id)$status, "ok", info = id)
  expect_equal(snap_view(snap, "U")$output$text, "[1]  4 12")

  edit_notebook(nb, set_code("C", "Circle <- setClass('Circle', contains = 'Shape', representation(diameter = 'numeric'))"))
  run_cells(nb, "C", wait = TRUE, timeout = 60)
  expect_false(snap_view(notebook_snapshot(nb), "MC")$stale %||% FALSE)
  # The method reran with the new class, so a Circle now fails in it, as it
  # would under Rscript: nothing still holds the old slot.
  expect_equal(snap_view(notebook_snapshot(nb), "U")$status, "error")
})
