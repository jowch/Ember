# Changes to the engine this candidate needs. Small, and each one is the
# engine's own business rather than the UI's.

# ---- state.R: split snapshot_of() so the projection shares its rules --------

#' Everything snapshot_of() computes once for the whole notebook, as one
#' value: the queued ids (`run_order(graph, pending)` minus the running
#' cell), blocked ids (graph errors plus downstream), `failed_blockers()`,
#' `waiting_cells()`, the running cell id, and graph errors grouped by cell.
#' `flags[[id]]` holds the per-cell scalars derived from these.
#'
#' Today these lines open snapshot_of(). Moving them here lets pluto_state()
#' compute them once per projection and then build views only for the cells
#' whose key changed, with no second copy of "what queued/blocked/stale
#' means" in the UI code (single source of truth).
view_context <- function(state) stop("not implemented")

#' One cell's `ember_cell_view`, exactly the element snapshot_of() builds
#' today. snapshot_of(state) becomes
#'   ctx <- view_context(state); lapply(ids, cell_view, state = state, ctx = ctx)
#' plus its notebook-level fields, so the snapshot and the projection can't
#' drift.
cell_view <- function(state, ctx, id) stop("not implemented")

# ---- api.R: inserts keep a caller's id ---------------------------------------

#' `insert_cell(index, code = "", kind = c("code", "markdown"), id = NULL)`.
#' edit_notebook() keeps `op$id` when given (it must be a 36-character UUID;
#' reduce_apply() already refuses an id in use) and calls uuid() only when
#' it is NULL. The frontend names a new cell before the server sees it, shows
#' it under that id, and asks to run that id next; a server-chosen id would
#' make the cell flicker away and the run miss.
insert_cell <- function(index, code = "", kind = c("code", "markdown"), id = NULL) {
  structure(list(op = "insert", index = index, code = code,
                 kind = match.arg(kind), id = id), class = "ember_op")
}

# ---- step.R: markdown cells can be edited ------------------------------------

#' reduce_apply() refuses set_code on a markdown cell ("is not a code cell").
#' The page edits a markdown cell's text like any other cell's, so
#' set_code must accept markdown cells (the text changes, nothing reruns;
#' the graph already reads markdown as ""). Without it every markdown edit in
#' the browser is answered 👎 and reverted. Question for the owner: was the
#' refusal deliberate?
NULL
