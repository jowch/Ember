# Tests for R/pluto-edits.R: translating a client's immer-style patches into
# edit_notebook() ops, by comparing the client's copy before and after.
# Pure: no server, no process, no engine. Table-driven per docs/ui-tests.md
# items 15-25: each case is the patches a frontend action produces (the
# shapes immer's own patches take for that action in Editor.js) and the ops
# expected.

#' A minimal but wire-shaped `before` (a client's copy of a projection):
#' `n` plain cells "A".."?" with empty code, `cell_order` and `cell_inputs`
#' filled in, `path` set.
base_before <- function(n = 3, ids = NULL) {
  if (is.null(ids)) ids <- LETTERS[seq_len(n)]
  inputs <- stats::setNames(lapply(ids, function(id) {
    list(cell_id = id, code = sprintf("# %s", id), code_folded = FALSE,
        metadata = list(disabled = FALSE, show_logs = TRUE, skip_as_script = FALSE))
  }), ids)
  list(cell_inputs = inputs, cell_order = as_arr(ids), path = "nb.R",
      metadata = emptymap(), bonds = emptymap())
}

patch_replace <- function(path, value) list(op = "replace", path = path, value = value)
patch_add     <- function(path, value) list(op = "add", path = path, value = value)
patch_remove  <- function(path) list(op = "remove", path = path)

new_cell_patch <- function(id, code = "", folded = FALSE) {
  list(cell_id = id, code = code, code_folded = folded,
      metadata = list(disabled = FALSE, show_logs = TRUE, skip_as_script = FALSE))
}

# ---- 15. Set code and run ----------------------------------------------------

test_that("set code: one set_code with expected = the code in before (15)", {
  before <- base_before(3)
  patches <- list(patch_replace(list("cell_inputs", "A", "code"), "# A edited"))
  ed <- pluto_edits(before, patches)
  expect_null(ed$refusal)
  expect_equal(length(ed$ops), 1)
  op <- ed$ops[[1]]
  expect_equal(op$op, "set_code")
  expect_equal(op$cell, "A")
  expect_equal(op$code, "# A edited")
  expect_equal(op$expected, "# A")
  expect_equal(ed$after$cell_inputs$A$code, "# A edited")
})

# ---- 16. Add a cell at index 3 ------------------------------------------------

test_that("add a cell at index 3: one insert_cell(3, id = client id) (16)", {
  before <- base_before(3)  # A B C
  patches <- list(
    patch_add(list("cell_inputs", "new1"), new_cell_patch("new1")),
    patch_replace(list("cell_order"), as_arr(c("A", "B", "new1", "C"))))
  ed <- pluto_edits(before, patches)
  expect_null(ed$refusal)
  expect_equal(length(ed$ops), 1)
  op <- ed$ops[[1]]
  expect_equal(op$op, "insert")
  expect_equal(op$id, "new1")
  expect_equal(op$index, 3L)
  expect_equal(op$code, "")
})

# ---- 17. Paste, split, undo a delete ------------------------------------------

test_that("paste three cells at once: three inserts at the right indexes, client ids kept (17)", {
  before <- base_before(2)  # A B
  patches <- list(
    patch_add(list("cell_inputs", "p1"), new_cell_patch("p1", "1")),
    patch_add(list("cell_inputs", "p2"), new_cell_patch("p2", "2")),
    patch_add(list("cell_inputs", "p3"), new_cell_patch("p3", "3")),
    patch_replace(list("cell_order"), as_arr(c("A", "p1", "p2", "p3", "B"))))
  ed <- pluto_edits(before, patches)
  expect_null(ed$refusal)
  inserts <- Filter(function(o) identical(o$op, "insert"), ed$ops)
  expect_equal(length(inserts), 3)
  expect_setequal(vapply(inserts, `[[`, character(1), "id"), c("p1", "p2", "p3"))
  expect_equal(ed$after$cell_order, as_arr(c("A", "p1", "p2", "p3", "B")))
})

test_that("split a cell: the original keeps the first half, a new cell holds the rest (17)", {
  before <- base_before(2, ids = c("A", "B"))
  patches <- list(
    patch_replace(list("cell_inputs", "A", "code"), "first"),
    patch_add(list("cell_inputs", "new1"), new_cell_patch("new1", "second")),
    patch_replace(list("cell_order"), as_arr(c("A", "new1", "B"))))
  ed <- pluto_edits(before, patches)
  expect_null(ed$refusal)
  set_codes <- Filter(function(o) identical(o$op, "set_code"), ed$ops)
  inserts <- Filter(function(o) identical(o$op, "insert"), ed$ops)
  expect_equal(length(set_codes), 1)
  expect_equal(set_codes[[1]]$code, "first")
  expect_equal(length(inserts), 1)
  expect_equal(inserts[[1]]$code, "second")
})

test_that("undo a delete re-adds the cell with the client's (original) id (17)", {
  before <- base_before(2, ids = c("A", "B"))
  patches <- list(
    patch_add(list("cell_inputs", "A2"), new_cell_patch("A2", "# A2")),
    patch_replace(list("cell_order"), as_arr(c("A", "A2", "B"))))
  ed <- pluto_edits(before, patches)
  expect_null(ed$refusal)
  expect_equal(length(ed$ops), 1)
  expect_equal(ed$ops[[1]]$op, "insert")
  expect_equal(ed$ops[[1]]$id, "A2")
})

# ---- 18. Delete two cells ------------------------------------------------------

test_that("delete two cells: two delete_cell, no moves (18)", {
  before <- base_before(4)  # A B C D
  patches <- list(patch_remove(list("cell_inputs", "B")),
                  patch_remove(list("cell_inputs", "D")),
                  patch_replace(list("cell_order"), as_arr(c("A", "C"))))
  ed <- pluto_edits(before, patches)
  expect_null(ed$refusal)
  kinds <- vapply(ed$ops, `[[`, character(1), "op")
  expect_setequal(kinds, "delete")
  deleted <- vapply(ed$ops, `[[`, character(1), "cell")
  expect_setequal(deleted, c("B", "D"))
})

# ---- 19/20. Drags ---------------------------------------------------------------

test_that("drag one cell from first to last: exactly one move_cell (19)", {
  before <- base_before(4)  # A B C D
  patches <- list(patch_replace(list("cell_order"), as_arr(c("B", "C", "D", "A"))))
  ed <- pluto_edits(before, patches)
  expect_null(ed$refusal)
  expect_equal(length(ed$ops), 1)
  expect_equal(ed$ops[[1]]$op, "move")
  expect_equal(ed$ops[[1]]$cell, "A")
})

test_that("drag three selected cells: at most 3 moves, never more than the cells whose order changed (20)", {
  before <- base_before(6)  # A B C D E F
  # Move A, C, E to the front, keeping their relative order (B D F unmoved relative to each other)
  patches <- list(patch_replace(list("cell_order"), as_arr(c("A", "C", "E", "B", "D", "F"))))
  ed <- pluto_edits(before, patches)
  expect_null(ed$refusal)
  moves <- Filter(function(o) identical(o$op, "move"), ed$ops)
  expect_true(length(moves) <= 3)
  expect_true(length(moves) > 0)
})

# ---- 21. Fold -------------------------------------------------------------------

test_that("fold: one fold_cell (21)", {
  before <- base_before(2)
  patches <- list(patch_replace(list("cell_inputs", "A", "code_folded"), TRUE))
  ed <- pluto_edits(before, patches)
  expect_null(ed$refusal)
  expect_equal(length(ed$ops), 1)
  expect_equal(ed$ops[[1]]$op, "fold")
  expect_equal(ed$ops[[1]]$cell, "A")
  expect_true(ed$ops[[1]]$folded)
})

# ---- 22. Move the file -----------------------------------------------------------

test_that("move the file: move_to set, no ops (22)", {
  before <- base_before(2)
  patches <- list(patch_replace(list("path"), "other.R"))
  ed <- pluto_edits(before, patches)
  expect_null(ed$refusal)
  expect_equal(length(ed$ops), 0)
  expect_equal(ed$move_to, "other.R")
})

# ---- 23. Refusals ------------------------------------------------------------------

test_that("refusals: show_logs, disabled, skip_as_script, notebook metadata, a bond (23)", {
  cases <- list(
    show_logs = patch_replace(list("cell_inputs", "A", "metadata", "show_logs"), FALSE),
    disabled = patch_replace(list("cell_inputs", "A", "metadata", "disabled"), TRUE),
    skip_as_script = patch_replace(list("cell_inputs", "A", "metadata", "skip_as_script"), TRUE),
    notebook_metadata = patch_add(list("metadata", "some_setting"), TRUE),
    bond = patch_add(list("bonds", "x"), list(value = 1))
  )
  for (name in names(cases)) {
    before <- base_before(2)
    ed <- pluto_edits(before, list(cases[[name]]))
    expect_false(is.null(ed$refusal), info = name)
    expect_equal(length(ed$ops), 0, info = name)
    # The client's own change still lands in `after`: no undo code exists.
    expect_false(identical(ed$after, before), info = name)
  }
})

# ---- 24. Races --------------------------------------------------------------------

test_that("race (a): cell_order missing a cell another writer inserted keeps its place (24)", {
  before <- base_before(3, ids = c("A", "B", "C"))
  # Another writer's insert already landed in `before$cell_inputs` (the
  # client's last-synced copy), between B and C, but the client's drag
  # patch replaces the whole order from a view that predates it.
  before$cell_inputs$Z <- new_cell_patch("Z", "# Z")
  before$cell_order <- as_arr(c("A", "B", "Z", "C"))

  patches <- list(patch_replace(list("cell_order"), as_arr(c("C", "A", "B"))))
  ed <- pluto_edits(before, patches)
  expect_null(ed$refusal)
  moves <- Filter(function(o) identical(o$op, "move"), ed$ops)
  expect_true(any(vapply(moves, function(o) identical(o$cell, "C"), logical(1))))
  expect_false(any(vapply(ed$ops, function(o) identical(o$op, "delete") && identical(o$cell, "Z"), logical(1))))
})

test_that("race (b): a code edit to a cell another writer deleted is refused (24)", {
  before <- base_before(3, ids = c("A", "B", "C"))
  before$cell_inputs$B <- NULL  # another writer's delete already landed
  before$cell_order <- as_arr(c("A", "C"))

  patches <- list(patch_replace(list("cell_inputs", "B", "code"), "edited"))
  ed <- pluto_edits(before, patches)
  expect_false(is.null(ed$refusal))
  expect_match(ed$refusal, "deleted")
  expect_equal(length(ed$ops), 0)
})

test_that("race (c): cell_order naming a deleted cell drops the id (24)", {
  before <- base_before(3, ids = c("A", "B", "C"))
  patches <- list(patch_remove(list("cell_inputs", "B")),
                  patch_replace(list("cell_order"), as_arr(c("A", "B", "C"))))
  ed <- pluto_edits(before, patches)
  expect_null(ed$refusal)
  target <- target_order(before, ed$after)
  expect_false("B" %in% target)
  expect_equal(target, c("A", "C"))
})

# ---- 25. lis() against brute force --------------------------------------------

test_that("lis() matches a brute-force longest increasing subsequence (25)", {
  brute_len <- function(x) {
    n <- length(x)
    if (n == 0) return(0L)
    best <- 1L
    for (mask in seq_len(2^n - 1)) {
      idx <- which(as.logical(intToBits(mask))[seq_len(n)])
      if (length(idx) <= 1) next
      sub <- x[idx]
      if (all(diff(sub) > 0)) best <- max(best, length(sub))
    }
    best
  }
  set.seed(2026)
  for (i in 1:300) {
    n <- sample(0:8, 1)
    x <- if (n == 0) integer(0) else sample(1:10, n, replace = TRUE)
    idx <- lis(x)
    if (length(idx) > 1) expect_true(all(diff(x[idx]) > 0), info = paste(x, collapse = ","))
    expect_true(all(idx == sort(idx)), info = paste(x, collapse = ","))
    expect_equal(length(idx), brute_len(x), info = paste(x, collapse = ","))
  }
})
