# Read-only queries over a built ember_graph: neighbours, run order,
# per-cell summaries, what changed between two builds, and the
# print/format methods.

# ---- Queries -----------------------------------------------------------------

#' Cells `id` depends on (direct), or all its ancestors (`transitive`).
#'
#' Ancestors come back in run order, which is the order they must run in.
upstream <- function(graph, id, transitive = FALSE) {
  if (!isTRUE(transitive)) return(graph$upstream[[id]])
  run_order(graph, reach(graph$upstream, id))
}

#' Cells that depend on `id` (direct), or all its descendants.
#'
#' Descendants come back in run order.
downstream <- function(graph, id, transitive = FALSE) {
  if (!isTRUE(transitive)) return(graph$downstream[[id]])
  run_order(graph, reach(graph$downstream, id))
}

#' The cells reached from any of `from` along `edges` (`graph$upstream` or
#' `graph$downstream`), in no particular order. A cell of `from` counts
#' only if an edge leads back to it. One walk over positions, so a long
#' chain stays linear (#316).
reach <- function(edges, from) {
  if (length(from) == 0) return(character())
  # Positions, not names: looking a name up in `edges` scans its names, so
  # a walk down a chain would be quadratic again. The index costs a pass
  # over every edge, so it is kept for the last few edge lists: a step
  # asks about the same graph several times, and a cell with no
  # dependents must not pay for the whole notebook.
  ix <- reach_index(edges)
  seen <- logical(length(ix$ids))
  todo <- match(from, ix$ids)
  while (length(todo)) {
    nxt <- unique(unlist(ix$to[todo], use.names = FALSE))
    todo <- nxt[!seen[nxt]]
    seen[todo] <- TRUE
  }
  ix$ids[seen]
}

#' `reach()`'s position index of `edges`: `ids` (the names of `edges`,
#' then any target that isn't one) and `to`, each id's targets as positions
#' in `ids`.
reach_index <- function(edges) {
  for (ix in reach_memo$kept) if (identical(ix$edges, edges)) return(ix)
  targets <- unlist(edges, use.names = FALSE)
  ids <- unique(c(names(edges), targets))
  to <- split(match(targets, ids), factor(rep.int(seq_along(edges), lengths(edges)), levels = seq_along(ids)))
  ix <- list(edges = edges, ids = ids, to = to)
  # Upstream and downstream, of the graph and of run_graph()'s copy.
  reach_memo$kept <- c(list(ix), reach_memo$kept)[seq_len(min(4L, length(reach_memo$kept) + 1L))]
  ix
}
reach_memo <- new.env(parent = emptyenv())

#' Run order of a set of cells, or of the whole notebook.
#'
#' `ids = NULL` gives `graph$order`. Otherwise the given ids sorted by
#' their position in `graph$order`; nothing is added, so the caller
#' composes "run these and their unrun ancestors" as
#' `run_order(g, union(ids, unlist(lapply(ids, upstream, graph = g,
#' transitive = TRUE))))`.
run_order <- function(graph, ids = NULL) {
  if (is.null(ids)) return(graph$order)
  graph$order[graph$order %in% ids]
}

#' Errors reported on one cell, in the order they were found.
cell_errors <- function(graph, id) {
  Filter(function(e) id %in% e$cells, graph$errors)
}

#' Ids of cells that can't run: any cell named in an error.
blocked_cells <- function(graph) {
  named <- unique(unlist(lapply(graph$errors, function(e) e$cells)))
  graph$ids[graph$ids %in% named]
}

#' Everything the adapter reports for one cell in one list.
#'
#' `list(definitions, learned, references, packages, attaches, upstream,
#' downstream, errors, notes, formulas, methods)`: the static definitions and the
#' learned ones separately (the design's snapshot shows both), references,
#' packages, direct neighbours, the cell's errors, the analysis's notes
#' (what the engine couldn't track) so the UI can show them, and the
#' methods the cell defines (`resolve_methods()`).
#'
#' `cells[[id]]$definitions` (used for edges and the multiple-definitions
#' rule) is static plus learned, as documented on `ember_graph`; here,
#' where the two are shown apart, `definitions` is static only (`learned`
#' subtracted out) so the two fields don't overlap.
cell_summary <- function(graph, id) {
  c <- graph$cells[[id]]
  a <- graph$analyses[[id]]
  list(definitions = setdiff(c$definitions, c$learned), learned = c$learned,
      references = c$references, packages = a$packages,
      attaches = c$attaches, upstream = graph$upstream[[id]],
      downstream = graph$downstream[[id]], errors = cell_errors(graph, id),
      notes = a$notes, formulas = a$formulas, methods = c$methods)
}

#' Cells to rerun (or mark stale) after an edit, in run order.
#'
#' `changed` are the edited cells. The result is `changed` plus every cell
#' downstream of them in `new`, plus every cell downstream of them in `old`
#' that still exists: a cell that read a name the edit removed has lost its
#' edge in `new` but still holds a result computed from that name, and the
#' worker removes the name before the edited cell reruns. Cells with errors
#' in `new` are included; the scheduler skips them.
affected <- function(old, new, changed) {
  down_new <- unlist(lapply(changed, function(id) {
    if (id %in% new$ids) downstream(new, id, transitive = TRUE) else character()
  }))
  down_old <- unlist(lapply(changed, function(id) {
    if (id %in% old$ids) downstream(old, id, transitive = TRUE) else character()
  }))
  down_old <- down_old[down_old %in% new$ids]
  all_ids <- unique(c(changed[changed %in% new$ids], down_new, down_old))
  run_order(new, all_ids)
}

#' Ids whose resolved view changed between two graphs, including deletions.
#'
#' A cell counts as changed when its definitions, references, packages,
#' upstream set, or errors differ; an id present in only one of the two
#' graphs (added or deleted) also counts. This is what a "graph changed"
#' event carries, so a deletion is reported even though the id is gone from
#' `new`. Comparing resolved views rather than analyses means a cell whose
#' neighbour was edited (so its edges moved) is included even though it was
#' not re-read.
#'
#' The result orders ids present in `new` by `new`'s run order, followed by
#' deleted ids (present in `old` only) in `old`'s run order.
changed_cells <- function(old, new) {
  # Most dispatches (a worker message during Run all) keep the same graph
  # object: nothing changed, and the per-cell walk below is skipped (#44).
  if (identical(old, new)) return(character())
  ids <- union(old$ids, new$ids)
  # By position, not by name: a lookup by name scans the names (#43).
  oi <- match(ids, old$ids)
  ni <- match(ids, new$ids)
  old_cells <- old$cells[oi]; new_cells <- new$cells[ni]
  old_up <- old$upstream[match(ids, names(old$upstream))]
  new_up <- new$upstream[match(ids, names(new$upstream))]
  errors_of <- function(graph) {
    by <- new.env(parent = emptyenv())
    for (e in graph$errors) for (cid in unique(e$cells)) by[[cid]] <- c(by[[cid]], list(e))
    by
  }
  old_errors <- errors_of(old); new_errors <- errors_of(new)
  changed <- character()
  for (k in seq_along(ids)) {
    id <- ids[[k]]
    oc <- old_cells[[k]]; nc <- new_cells[[k]]
    if (is.null(oc) || is.null(nc)) {
      changed <- c(changed, id)
      next
    }
    if (!identical(oc$definitions, nc$definitions) ||
        !identical(oc$references, nc$references) ||
        !identical(oc$packages, nc$packages) ||
        !identical(old_up[[k]], new_up[[k]]) ||
        !identical(old_errors[[id]], new_errors[[id]])) {
      changed <- c(changed, id)
    }
  }
  present <- run_order(new, changed[changed %in% new$ids])
  deleted <- old$order[old$order %in% changed[!(changed %in% new$ids)]]
  c(present, deleted)
}

#' @export
print.ember_graph <- function(x, ...) {
  # one line per cell in run order: id, definitions, "<- upstream ids",
  # then errors.
  for (id in x$order) {
    c <- x$cells[[id]]
    line <- sprintf("%s: %s", id, paste(c$definitions, collapse = ", "))
    ups <- x$upstream[[id]]
    if (length(ups) > 0) line <- paste0(line, " <- ", paste(ups, collapse = ", "))
    cat(line, "\n", sep = "")
    for (e in cell_errors(x, id)) cat("  ", format(e), "\n", sep = "")
  }
  invisible(x)
}

#' @export
format.ember_graph_error <- function(x, ...) {
  sprintf("[%s] %s", x$kind, x$message)
}
