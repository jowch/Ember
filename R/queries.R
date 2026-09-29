# Read-only queries over a built ember_graph: neighbours, run order,
# per-cell summaries, what changed between two builds, and the
# print/format methods.

# ---- Queries -----------------------------------------------------------------

#' Cells `id` depends on (direct), or all its ancestors (`transitive`).
#'
#' Ancestors come back in run order, which is the order they must run in.
upstream <- function(graph, id, transitive = FALSE) {
  if (!isTRUE(transitive)) return(graph$upstream[[id]])
  seen <- character()
  visit <- function(i) {
    for (u in graph$upstream[[i]]) {
      if (!(u %in% seen)) {
        seen <<- c(seen, u)
        visit(u)
      }
    }
  }
  visit(id)
  run_order(graph, seen)
}

#' Cells that depend on `id` (direct), or all its descendants.
#'
#' Descendants come back in run order.
downstream <- function(graph, id, transitive = FALSE) {
  if (!isTRUE(transitive)) return(graph$downstream[[id]])
  seen <- character()
  visit <- function(i) {
    for (d in graph$downstream[[i]]) {
      if (!(d %in% seen)) {
        seen <<- c(seen, d)
        visit(d)
      }
    }
  }
  visit(id)
  run_order(graph, seen)
}

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
#' downstream, errors, notes, formulas)`: the static definitions and the
#' learned ones separately (the design's snapshot shows both), references,
#' packages, direct neighbours, the cell's errors, and the analysis's notes
#' (what the engine couldn't track) so the UI can show them.
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
      notes = a$notes, formulas = a$formulas)
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
  ids <- union(old$ids, new$ids)
  changed <- character()
  for (id in ids) {
    oc <- old$cells[[id]]; nc <- new$cells[[id]]
    if (is.null(oc) || is.null(nc)) {
      changed <- c(changed, id)
      next
    }
    if (!identical(oc$definitions, nc$definitions) ||
        !identical(oc$references, nc$references) ||
        !identical(oc$packages, nc$packages) ||
        !identical(old$upstream[[id]], new$upstream[[id]]) ||
        !identical(cell_errors(old, id), cell_errors(new, id))) {
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
