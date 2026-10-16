# Replacement functions (#94, and #41's setReplaceMethod()): R runs
# `r(x) <- v` as `` x <- `r<-`(x, value = v) ``, so the cell reads
# `` `r<-` `` and depends on the cell that defines it, or on the cells that
# define methods of it. Reading is read_cell(); edges are notebook_graph();
# the last tests run a real worker.

has_edge <- function(g, from, to, name, via) {
  any(g$edges$from == from & g$edges$to == to & g$edges$name == name & g$edges$via == via)
}

# ---- Reading -----------------------------------------------------------------

test_that("a replacement call reads its replacement function", {
  a <- read_cell("r(x) <- 2")
  expect_setequal(defs(a), "x")
  expect_setequal(refs(a), c("x", "r<-"))
})

test_that("a nested replacement call reads each setter and the inner getters", {
  # R runs names(x)[i] <- nm as x <- `names<-`(x, `[<-`(names(x), i, nm)).
  a <- read_cell("names(x)[i] <- nm")
  expect_setequal(refs(a), c("x", "i", "nm", "names<-", "names", "[<-"))
})

test_that("$ and @ targets read no replacement function", {
  a <- read_cell("df$col <- v; s@slot <- w")
  expect_setequal(refs(a), c("df", "v", "s", "w"))
  a <- read_cell("r(df$col) <- v")
  expect_setequal(refs(a), c("df", "v", "r<-"))
})

test_that("a pkg:: replacement head is a use of the package, not a read", {
  a <- read_cell("Biobase::exprs(es) <- m")
  expect_setequal(refs(a), c("es", "m"))
  expect_equal(a$packages$name, "Biobase")
  expect_false(a$packages$attached)
})

test_that("a replacement call inside a function body reads the function", {
  a <- read_cell("f <- function(x) { r(x) <- 2; x }")
  expect_setequal(refs(a), "r<-")
  # <<- calls the replacement function too, and reads its index.
  a <- read_cell("f <- function() x[i] <<- 1")
  expect_setequal(refs(a), c("x", "[<-", "i"))
})

test_that("%<>% on a replacement target reads the getter and the setter", {
  a <- read_cell("x[i] %<>% sort")
  expect_setequal(defs(a), "x")
  expect_setequal(refs(a), c("x", "i", "[", "[<-", "sort"))
})

test_that("the reference sits on the replacement call's head", {
  a <- read_cell("x <- list()\nr(x) <- 2")
  row <- a$references[a$references$name == "r<-", ]
  expect_equal(c(row$line, row$col, row$end_col), c(2, 1, 1))
})

test_that("setReplaceMethod() records a method of the replacement generic", {
  a <- read_cell(paste(
    "setReplaceMethod('r', 'C', function(x, value) x)",
    "setReplaceMethod(f = 'w', signature('C', 'numeric'), function(x, value) x)",
    sep = "\n"))
  expect_equal(a$methods$generic, c("r<-", "w<-"))
  expect_equal(a$methods$signature, c("C", "C,numeric"))
  expect_equal(a$methods$form, c("s4", "s4"))
  expect_true(".__C__C" %in% refs(a))
})

# ---- Edges -------------------------------------------------------------------

test_that("a cell calling a replacement function runs after the cell defining it", {
  g <- notebook_graph(c(
    U = "x <- list(); r(x) <- 2; x",
    M = "`r<-` <- function(x, value) { x$r <- value; x }"
  ))
  expect_true(has_edge(g, "U", "M", "r<-", "definition"))
  expect_equal(run_order(g), c("M", "U"))
  expect_equal(downstream(g, "M"), "U")
})

test_that("an S3 method of a replacement generic feeds the cells that call it", {
  g <- notebook_graph(c(
    M = "`names<-.foo` <- function(x, value) x",
    U = "y <- structure(list(), class = 'foo'); names(y) <- 'a'"
  ))
  expect_true(has_edge(g, "U", "M", "names<-", "method"))
})

test_that("setReplaceMethod() feeds r(x) <- v and runs after setGeneric() and the class", {
  g <- notebook_graph(c(
    U = "x <- new('C', r = 1); r(x) <- 2; x",
    M = "setReplaceMethod('r', 'C', function(x, value) { x@r <- value; x })",
    G = "setGeneric('r<-', function(x, value) standardGeneric('r<-'))",
    K = "setClass('C', representation(r = 'numeric'))"
  ))
  expect_true(has_edge(g, "U", "M", "r<-", "method"))
  expect_true(has_edge(g, "M", "G", "r<-", "definition"))
  expect_true(has_edge(g, "M", "K", ".__C__C", "definition"))
  expect_equal(run_order(g)[4], "U")
  expect_lt(match("G", run_order(g)), match("M", run_order(g)))
})

test_that("setReplaceMethod() and setMethod('r<-') for one class are one method", {
  g <- notebook_graph(c(
    A = "setReplaceMethod('r', 'C', function(x, value) x)",
    B = "setMethod('r<-', 'C', function(x, value) x)"
  ))
  expect_length(g$errors, 1)
  expect_equal(g$errors[[1]]$kind, "multiple_definitions")
})

# ---- Running -------------------------------------------------------------------

test_that("the issue's notebook runs, and editing the function reruns its caller", {
  cells <- list(S = cell(""),
                U = cell("x <- list(); r(x) <- 2; x$r"),
                M = cell("`r<-` <- function(x, value) { x$r <- value; x }"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 30)
  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  for (id in c("U", "M")) expect_equal(snap_view(snap, id)$status, "ok", info = id)
  expect_equal(snap_view(snap, "U")$output$text, "[1] 2")

  edit_notebook(nb, set_code("M", "`r<-` <- function(x, value) { x$r <- 10 * value; x }"))
  res <- run_cells(nb, "M", wait = TRUE, timeout = 30)
  expect_false(res$timed_out)
  expect_equal(snap_view(notebook_snapshot(nb), "U")$output$text, "[1] 20")
})

test_that("setReplaceMethod() cells placed after their caller still run first", {
  cells <- list(S = cell(""),
                U = cell("x <- new('C', r = 1); r(x) <- 2; x@r"),
                M = cell("setReplaceMethod('r', 'C', function(x, value) { x@r <- value; x })"),
                G = cell("setGeneric('r<-', function(x, value) standardGeneric('r<-'))"),
                K = cell("setClass('C', representation(r = 'numeric'))"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_cells(nb, wait = TRUE, timeout = 30)
  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  for (id in c("U", "M", "G", "K")) expect_equal(snap_view(snap, id)$status, "ok", info = id)
  expect_equal(snap_view(snap, "U")$output$text, "[1] 2")

  edit_notebook(nb, set_code("M", "setReplaceMethod('r', 'C', function(x, value) { x@r <- -value; x })"))
  res <- run_cells(nb, "M", wait = TRUE, timeout = 30)
  expect_false(res$timed_out)
  expect_equal(snap_view(notebook_snapshot(nb), "U")$output$text, "[1] -2")
})
