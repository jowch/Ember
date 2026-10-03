# Edits from the frontend: an update_notebook request carries immer patches
# against the client's copy of the projection. They become edit_notebook()
# ops by comparing that copy before and after the patches, so the engine
# stays the only writer and the projection the only reader.
#
# Pure. The server calls pluto_edits(), then edit_notebook() with the ops,
# then flushes; whatever the engine accepted or refused, the next diff for
# this client is fb_diff(after, projection): nothing when accepted, the
# reversal when refused. No undo code exists anywhere.

#' Translate one update_notebook request.
#'
#' @param before The client's copy (`client$sent`): the projection last sent
#'   to it, plus its own earlier patches.
#' @param patches The request's `updates`, decoded.
#' @return `ember_pluto_edit`:
#'   * `after`: `before` with the patches applied. The server stores it as the
#'     client's copy whatever happens next (Pluto does the same with
#'     current_state_for_clients), because the browser already shows it.
#'   * `ops`: list of `ember_op` for one atomic edit_notebook() call.
#'   * `move_to`: a new path, or NULL (move_notebook(), not an op).
#'   * `refusal`: NULL, or one sentence. When set, `ops` is empty and the
#'     server answers 👎 without calling the engine.
#' An `ember_pluto_edit`: see `pluto_edits()`'s return value.
new_pluto_edit <- function(after, ops, move_to = NULL, refusal = NULL) {
  structure(list(after = after, ops = ops, move_to = move_to, refusal = refusal),
            class = "ember_pluto_edit")
}

pluto_edits <- function(before, patches) {
  for (p in patches) {
    verdict <- allowed_patch(p, before)
    if (!isTRUE(verdict)) {
      # The client's copy still gets every patch applied: the browser
      # already shows `after`, and the next flush's diff from it to the
      # real projection is the reversal (design.md, "Refusal costs no
      # code").
      return(new_pluto_edit(fb_apply_all(before, patches), list(), refusal = verdict))
    }
  }
  after <- fb_apply_all(before, patches)

  before_ids <- names(before$cell_inputs)
  after_ids  <- names(after$cell_inputs)
  deleted_ids <- setdiff(before_ids, after_ids)

  ops <- lapply(deleted_ids, delete_cell)

  common <- intersect(before_ids, after_ids)
  for (id in common) {
    bc <- before$cell_inputs[[id]]$code
    ac <- after$cell_inputs[[id]]$code
    if (!identical(bc, ac)) ops <- c(ops, list(set_code(id, ac, expected = bc)))

    bf <- before$cell_inputs[[id]]$code_folded
    af <- after$cell_inputs[[id]]$code_folded
    if (!identical(bf, af)) ops <- c(ops, list(fold_cell(id, af)))

    bd <- before$cell_inputs[[id]]$metadata$disabled
    ad <- after$cell_inputs[[id]]$metadata$disabled
    if (!identical(bd, ad)) ops <- c(ops, list(disable_cell(id, isTRUE(ad))))
  }

  current <- setdiff(before_ids, deleted_ids)
  target <- target_order(before, after)
  ops <- c(ops, order_ops(current, target, after))

  move_to <- if (!identical(before$path, after$path)) after$path else NULL

  new_pluto_edit(after, ops, move_to = move_to)
}

#' Is this patch one the frontend sends for something Ember supports, and
#' does it point at something that exists? Checked on the raw patches before
#' applying, because fb_apply() creates missing maps: a code edit to a cell
#' another writer just deleted would otherwise come out of step 3 as a new
#' cell holding only `code`. Such a patch is refused ("that cell was
#' deleted") and the reversal removes it from the client.
#'
#' @return `TRUE`, or a one-sentence refusal.
allowed_patch <- function(patch, before) {
  path <- patch$path
  if (length(path) == 0) {
    return("Ember doesn't support replacing the whole notebook yet")
  }
  head <- path[[1]]

  if (identical(head, "cell_inputs")) {
    if (length(path) < 3) return(TRUE)   # add/remove a whole cell
    field <- path[[3]]
    if (identical(field, "metadata")) {
      key <- if (length(path) >= 4) path[[4]] else NULL
      if (length(path) == 4 && identical(key, "disabled")) {
        id <- path[[2]]
        if (is.null(before$cell_inputs[[id]])) return("that cell was deleted")
        return(TRUE)
      }
      if (is.null(key)) {
        return("Ember doesn't support replacing cell metadata yet")
      }
      if (identical(key, "disabled")) {
        # length(path) > 4 here: a patch reaching past metadata.disabled
        # itself (into a value that is just a boolean), not a patch to
        # metadata.disabled, which is supported.
        return("Ember doesn't support changing part of cell metadata.disabled yet")
      }
      return(sprintf("Ember doesn't support cell metadata.%s yet", key))
    }
    if (!identical(field, "code") && !identical(field, "code_folded")) {
      return(sprintf("Ember doesn't support cell %s yet", field))
    }
    id <- path[[2]]
    if (is.null(before$cell_inputs[[id]])) return("that cell was deleted")
    return(TRUE)
  }
  if (head %in% c("cell_order", "path", "in_temp_dir", "process_status")) return(TRUE)
  sprintf("Ember doesn't support %s yet", head)
}

#' The display order the client wants, made total.
#'
#' Start from `after$cell_order`, keep only ids present in
#' `after$cell_inputs` (the frontend's "cells stuck in limbo" rule), then add
#' each id present in `after$cell_inputs` but missing from the order right
#' after its predecessor in `before$cell_order` (or first). That second case
#' is the race this candidate has to absorb: the client replaced the whole
#' `cell_order` array from a view that didn't yet have a cell another writer
#' inserted. Pluto would drop that cell from the order; here it keeps its
#' place, and the client's move still happens.
target_order <- function(before, after) {
  after_ids <- names(after$cell_inputs)
  want <- unlist(after$cell_order, use.names = FALSE)
  if (is.null(want)) want <- character()
  want <- want[want %in% after_ids]

  missing <- setdiff(after_ids, want)
  if (length(missing) == 0) return(want)

  before_order <- unlist(before$cell_order, use.names = FALSE)
  if (is.null(before_order)) before_order <- character()
  for (id in missing) {
    pos <- match(id, before_order)
    pred <- if (is.na(pos) || pos <= 1) NA_character_ else before_order[pos - 1]
    insert_at <- if (!is.na(pred) && pred %in% want) match(pred, want) + 1L else 1L
    want <- append(want, id, after = insert_at - 1L)
  }
  want
}

#' Inserts and moves that turn `current` (engine order after the deletes)
#' into `target`.
#'
#' Cells on a longest increasing subsequence of `match(current, target)` stay
#' where they are. Every other cell, and every inserted id, is placed in
#' ascending target position right after its target predecessor, which is
#' already in place by then: a drag of one cell is one move_cell(), not a
#' cascade of them.
#'
#' Inserted ids keep the client's id (insert_cell(..., id = <client id>);
#' engine change, see RATIONALE.md): the browser already shows the cell under
#' that id and its next request is run_multiple_cells for it. Their code is
#' `after$cell_inputs[[id]]$code` and kind `after$cell_inputs[[id]]$kind %||%
#' "code"` (undo delete and paste of a markdown cell keep it markdown).
#'
#' Indexes are computed as edit_notebook() reads them: positions after the
#' previous ops, 1-based.
order_ops <- function(current, target, after) {
  if (length(current) == 0 && length(target) == 0) return(list())
  pos  <- match(current, target)
  keep <- current[lis(pos)]
  todo <- target[!(target %in% keep)]          # in target order
  cur  <- current; ops <- list()
  for (id in todo) {
    ti   <- match(id, target)
    pred <- if (ti == 1L) NULL else target[ti - 1L]
    cur  <- setdiff(cur, id)
    idx  <- if (is.null(pred)) 1L else match(pred, cur) + 1L
    ops  <- c(ops, list(if (id %in% current) move_cell(id, idx)
                        else insert_cell(idx, code = after$cell_inputs[[id]]$code,
                                         kind = after$cell_inputs[[id]]$kind %||% "code", id = id)))
    cur  <- append(cur, id, after = idx - 1L)
  }
  stopifnot(identical(cur, target))
  ops
}

#' Indexes into `x` (integer, no NAs) of one longest strictly increasing
#' subsequence. Patience sorting, O(n log n).
lis <- function(x) {
  n <- length(x)
  if (n == 0) return(integer())
  pile_top <- integer(0)   # pile_top[k]: index into x ending the best length-k run found so far
  prev <- integer(n)
  for (i in seq_len(n)) {
    lo <- 1L; hi <- length(pile_top) + 1L
    while (lo < hi) {
      mid <- (lo + hi) %/% 2L
      if (x[pile_top[mid]] < x[i]) lo <- mid + 1L else hi <- mid
    }
    prev[i] <- if (lo > 1L) pile_top[lo - 1L] else NA_integer_
    if (lo > length(pile_top)) pile_top <- c(pile_top, i) else pile_top[lo] <- i
  }
  out <- integer(length(pile_top))
  k <- pile_top[length(pile_top)]
  for (j in rev(seq_along(pile_top))) {
    out[j] <- k
    k <- prev[k]
  }
  out
}
