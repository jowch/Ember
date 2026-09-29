# The notebook graph: a pure function of the cells, the setup cell, the
# package exports, and what the worker has learned. Rebuilt whole on every
# change; only cells whose code changed are re-read.

# ---- Result type -----------------------------------------------------------

#' The notebook graph.
#'
#' Built by `notebook_graph()`. Fields:
#'
#' * `ids`: cell ids in display order. Every named list below is keyed by
#'   these ids, in this order.
#' * `setup`: the setup cell's id.
#' * `analyses`: `ember_cell_analysis` per cell (the cache for the next
#'   build).
#' * `learned`: `list(definitions = <id -> character>, references = <id ->
#'   character>)`: what the worker reported, exactly as given. The caller
#'   owns this; the graph carries it so `notebook_graph(previous = g)` can
#'   keep it.
#' * `exports`: the package exports the graph was built with.
#' * `cells`: per cell, `list(definitions, learned, references, packages,
#'   attaches, settings, private)`: the resolved view the adapter reports.
#'   `definitions` are the public names the cell defines (static plus
#'   learned); `private` its dot-names; `attaches` the packages it puts on
#'   the search path.
#' * `edges`: data frame `from`, `to`, `name`, `via`: `from` depends on
#'   `to`. `via` is `"definition"` (`to` defines `name`), `"package"` (`to`
#'   attaches a package exporting `name`), `"setup"` (`to` is the setup
#'   cell; `name` is `NA`). One row per (from, to, name).
#' * `upstream`, `downstream`: `id -> character` of direct neighbours, in
#'   display order, derived from `edges` at build time.
#' * `order`: every cell id, in run order (see `run_order()`).
#' * `errors`: list of `ember_graph_error`.
#' * `reread`: ids whose analysis was computed in this build rather than
#'   taken from `previous`. The scheduler uses it to know which cells' code
#'   actually changed.
#' * `read_file`: the reader `notebook_graph()` was built with. Not part of
#'   the sketch's field list; kept so `graph_learn()` can rebuild with
#'   `previous = graph` and still re-check sourced files, per the "every
#'   rebuild re-reads sourced files" tradeoff, without the caller passing
#'   `read_file` again.
#'
#' Invariants: no edge from a cell to itself; `upstream[[a]]` contains `b` iff `downstream[[b]]` contains
#' `a`; `order` is a permutation of `ids`; a cell with a `parse` error has
#' no definitions and no references but keeps its setup edge.
new_graph <- function(ids, setup, analyses, learned, exports, cells, edges,
                      upstream, downstream, order, errors, reread,
                      read_file = NULL) {
  structure(list(ids = ids, setup = setup, analyses = analyses,
                 learned = learned, exports = exports, cells = cells,
                 edges = edges, upstream = upstream, downstream = downstream,
                 order = order, errors = errors, reread = reread,
                 read_file = read_file),
            class = "ember_graph")
}

#' A graph-level error.
#'
#' `kind` is one of `"parse"`, `"multiple_definitions"`, `"cycle"`,
#' `"private_name"`, `"global_setting"`. `cells` are the ids the error is
#' reported on (all of them can't run). `names` are the globals involved
#' (empty for `parse` and `global_setting`). `lines` is a data frame `cell`,
#' `line` pointing at the responsible lines where known. `message` is one
#' sentence for the UI; `fixes` a character vector of suggested fixes, in
#' the wording the design gives:
#'
#' * multiple definitions of `df` where one is a replacement: "Move the line
#'   into the cell that defines df, or name the result (df2 <- ...)".
#' * `for (i ...)` in two cells: "Use a private name: .i".
#' * private name used elsewhere: "Drop the dot: x".
#' * cycle through a name only read inside call arguments: "If x is a
#'   column name, rename the global".
#' * global setting: "Move it to the setup cell, or use withr::with_options()
#'   for one piece of code".
new_graph_error <- function(kind, cells, names = character(),
                            lines = NULL, message, fixes = character()) {
  structure(list(kind = kind, cells = cells, names = names,
                 lines = lines, message = message, fixes = fixes),
            class = "ember_graph_error")
}

# ---- Building ---------------------------------------------------------------

#' Reuse a cached analysis when its code and any sourced files are unchanged.
#'
#' Consults `read_file` on every rebuild, even with `previous`, per the
#' accepted tradeoff of re-reading small helper files rather than needing a
#' cache-invalidation call from a file watcher.
reuse_analysis <- function(prev, code, read_file) {
  if (is.null(prev)) return(FALSE)
  if (!identical(prev$code, code)) return(FALSE)
  sourced <- prev$sourced
  if (is.null(sourced) || nrow(sourced) == 0) return(TRUE)
  for (i in seq_len(nrow(sourced))) {
    text <- if (is.null(read_file)) NULL else read_file(sourced$path[i])
    found <- !is.null(text)
    if (!identical(found, sourced$found[i])) return(FALSE)
    if (found && !identical(text, sourced$text[i])) return(FALSE)
  }
  TRUE
}

#' Build the notebook graph.
#'
#' @param cells Named character vector, cell id -> code, in display order.
#'   Markdown cells are passed as empty strings (or left out); they take
#'   part in the order and nothing else.
#' @param setup The setup cell's id. Default: the first cell. Every other
#'   cell depends on it.
#' @param exports Named list, package name -> character vector of exported
#'   names (`getNamespaceExports()`), for the packages that are installed.
#'   A package not in the list contributes no edges.
#' @param learned `list(definitions = <id -> character>, references = <id ->
#'   character>)` from the footer and from formula checks; `NULL` means
#'   none. Ids not in `cells` are dropped.
#' @param previous An earlier `ember_graph` for the same notebook, or
#'   `NULL`. Analyses are reused for cells whose code is identical and whose
#'   sourced files still read the same; everything else is recomputed.
#'   Passing `previous` never changes the result, only the work done.
#' @param read_file Reader for `source()` paths; see `read_cell()`.
#' @return An `ember_graph`.
#'
#' The build is deterministic and idempotent: the same inputs give an
#' identical graph, with or without `previous`.
notebook_graph <- function(cells, setup = names(cells)[1], exports = list(),
                           learned = NULL, previous = NULL, read_file = NULL) {
  ids <- names(cells)
  if (is.null(ids) || any(is.na(ids)) || any(ids == "") ||
      any(duplicated(ids))) {
    stop("cells must be a named character vector with unique, non-empty names")
  }
  if (!isTRUE(setup %in% ids)) stop("setup must be one of the cell ids")

  if (is.null(learned)) learned <- list()
  if (is.null(learned$definitions)) learned$definitions <- list()
  if (is.null(learned$references)) learned$references <- list()
  learned$definitions <- learned$definitions[names(learned$definitions) %in% ids]
  learned$references <- learned$references[names(learned$references) %in% ids]

  # 1. analyses: reuse previous$analyses[[id]] when code and sourced files
  #    are unchanged; else read_cell(code, read_file). reread <- the rest.
  analyses <- list()
  reread <- character()
  for (id in ids) {
    code <- cells[[id]]
    if (is.na(code)) code <- ""
    prev_a <- if (!is.null(previous)) previous$analyses[[id]] else NULL
    if (reuse_analysis(prev_a, code, read_file)) {
      analyses[[id]] <- prev_a
    } else {
      analyses[[id]] <- read_cell(code, read_file)
      reread <- c(reread, id)
    }
  }

  # 2. cells: the resolved, per-cell view.
  cells_resolved <- resolve_cells(analyses, learned, ids)

  # 3. edges: resolve_edges(cells, setup, exports).
  edges <- resolve_edges(cells_resolved, setup, exports, ids)

  # upstream/downstream from edges, in display order. Grouped with split()
  # (one pass over the edge rows) rather than a per-row union(), which
  # rescans the growing neighbour vector on every edge; and ordered by a
  # precomputed rank rather than `ids[ids %in% x]`, which would rescan all
  # of `ids` for every one of the ids instead of just each id's neighbours.
  upstream_list <- setNames(vector("list", length(ids)), ids)
  downstream_list <- setNames(vector("list", length(ids)), ids)
  for (id in ids) {
    upstream_list[[id]] <- character()
    downstream_list[[id]] <- character()
  }
  if (nrow(edges) > 0) {
    up_groups <- split(edges$to, edges$from)
    down_groups <- split(edges$from, edges$to)
    for (f in names(up_groups)) upstream_list[[f]] <- unique(up_groups[[f]])
    for (t in names(down_groups)) downstream_list[[t]] <- unique(down_groups[[t]])
  }
  rank <- setNames(seq_along(ids), ids)
  for (id in ids) {
    u <- upstream_list[[id]]
    if (length(u) > 0) upstream_list[[id]] <- u[order(rank[u])]
    d <- downstream_list[[id]]
    if (length(d) > 0) downstream_list[[id]] <- d[order(rank[d])]
  }

  # Strongly connected components of the dependency graph, computed once and
  # shared by find_errors (the cycle error) and compute_order (which cells
  # can't force an order onto one another).
  components <- scc_components(ids, upstream_list)

  # 4. errors: find_errors(cells, analyses, edges, setup, ids).
  errors <- find_errors(cells_resolved, analyses, edges, setup, ids, components)

  # 5. order <- compute_order(...).
  comp_of <- setNames(rep(NA_integer_, length(ids)), ids)
  for (i in seq_along(components)) comp_of[components[[i]]] <- i
  attaches_list <- setNames(lapply(ids, function(id) cells_resolved[[id]]$attaches), ids)
  is_markdown <- setNames(vapply(ids, function(id) grepl("^\\s*$", analyses[[id]]$code), logical(1)), ids)
  order <- compute_order(ids, setup, upstream_list, attaches_list, comp_of, is_markdown)

  new_graph(ids = ids, setup = setup, analyses = analyses, learned = learned,
            exports = exports, cells = cells_resolved, edges = edges,
            upstream = upstream_list, downstream = downstream_list,
            order = order, errors = errors, reread = reread,
            read_file = read_file)
}

#' Add what the worker learned about one cell, and rebuild.
#'
#' `definitions` replaces the learned definitions of `cell` (the worker
#' reports the full set after each run, so a name that stopped appearing
#' drops out); `references` replaces its learned references (the formula
#' check's missing columns). `NULL` leaves that part as it was. Returns a
#' new graph built with `previous = graph`, so nothing is re-read.
#'
#' The caller persists `graph$learned$definitions` in the footer.
graph_learn <- function(graph, cell, definitions = NULL, references = NULL) {
  learned <- graph$learned
  if (!is.null(definitions)) learned$definitions[[cell]] <- definitions
  if (!is.null(references)) learned$references[[cell]] <- references
  cells <- setNames(vapply(graph$ids, function(id) graph$analyses[[id]]$code,
                            character(1)), graph$ids)
  notebook_graph(cells, setup = graph$setup, exports = graph$exports,
                 learned = learned, previous = graph, read_file = graph$read_file)
}

#' Public definitions, references, packages per cell.
resolve_cells <- function(analyses, learned, ids) {
  cells <- list()
  for (id in ids) {
    a <- analyses[[id]]
    learned_defs <- learned$definitions[[id]]
    if (is.null(learned_defs)) learned_defs <- character()
    learned_refs <- learned$references[[id]]
    if (is.null(learned_refs)) learned_refs <- character()

    defs_all <- unique(c(definitions_of(a), learned_defs))
    private <- defs_all[is_private_name(defs_all)]
    definitions <- defs_all[!is_private_name(defs_all)]
    references <- unique(c(references_of(a), learned_refs))
    attaches <- unique(a$packages$name[a$packages$attached])

    cells[[id]] <- list(definitions = definitions, learned = learned_defs,
                        references = references,
                        packages = unique(a$packages$name),
                        attaches = attaches, settings = a$settings,
                        private = private)
  }
  cells
}

#' Edges from references to the cells that satisfy them.
#'
#' For each reference `n` of cell `b`, in this order, stopping at the first
#' rule that yields cells:
#' 1. cells (other than `b`) whose public definitions include `n`: one edge
#'    each, via "definition". If `n` is a dot-name defined in another cell,
#'    no edge; `find_errors` reports it.
#' 2. else cells (other than `b`) attaching a package whose exports include
#'    `n`: one edge each, via "package". A global definition shadows a
#'    package export, as the global environment comes first on R's search
#'    path, which is why rule 1 stops the search.
#' Every cell other than `setup` gets an edge to `setup`, via "setup".
resolve_edges <- function(cells, setup, exports, ids) {
  # Three lookup tables, each built in one pass so the whole function is
  # linear in (total definitions + total exports + total references)
  # instead of the reference-times-cells cost of testing every id against
  # every reference:
  #  - definer_lookup: name -> ids that publicly define it, display order.
  #  - attachers: package -> ids attaching it, display order.
  #  - name_to_pkgs: name -> packages (from `exports`) that export it.
  # A reference is then resolved by two hash lookups (plus, for rule 2, one
  # lookup per exporting package) rather than a scan of every id.
  definer_lookup <- new.env(parent = emptyenv())
  for (id in ids) {
    for (n in cells[[id]]$definitions) {
      definer_lookup[[n]] <- c(definer_lookup[[n]], id)
    }
  }
  attachers <- new.env(parent = emptyenv())
  for (id in ids) {
    for (p in cells[[id]]$attaches) {
      attachers[[p]] <- c(attachers[[p]], id)
    }
  }
  name_to_pkgs <- new.env(parent = emptyenv())
  for (p in names(exports)) {
    for (n in exports[[p]]) {
      name_to_pkgs[[n]] <- c(name_to_pkgs[[n]], p)
    }
  }

  # Rule 1 only sees public definitions: private names never appear in
  # `cells[[id]]$definitions`, so a dot-name reference falls through to no
  # edge without a special case here. Each cell's own edges are built as
  # plain vectors and combined with `unlist()` once, rather than growing
  # one shared vector element by element.
  ref_edges <- lapply(ids, function(b) {
    refs <- cells[[b]]$references
    if (length(refs) == 0) return(NULL)
    parts <- lapply(refs, function(n) {
      definers <- definer_lookup[[n]]
      if (is.null(definers)) definers <- character()
      definers <- definers[definers != b]
      if (length(definers) > 0) {
        return(list(from = rep(b, length(definers)), to = definers,
                    name = rep(n, length(definers)),
                    via = rep("definition", length(definers))))
      }
      pkgs <- name_to_pkgs[[n]]
      if (is.null(pkgs)) return(NULL)
      provider_ids <- unique(unlist(lapply(pkgs, function(p) attachers[[p]]),
                                    use.names = FALSE))
      provider_ids <- provider_ids[provider_ids != b]
      if (length(provider_ids) == 0) return(NULL)
      provider_ids <- ids[ids %in% provider_ids]
      list(from = rep(b, length(provider_ids)), to = provider_ids,
          name = rep(n, length(provider_ids)), via = rep("package", length(provider_ids)))
    })
    parts <- Filter(Negate(is.null), parts)
    if (length(parts) == 0) return(NULL)
    list(from = unlist(lapply(parts, `[[`, "from"), use.names = FALSE),
        to = unlist(lapply(parts, `[[`, "to"), use.names = FALSE),
        name = unlist(lapply(parts, `[[`, "name"), use.names = FALSE),
        via = unlist(lapply(parts, `[[`, "via"), use.names = FALSE))
  })
  ref_edges <- Filter(Negate(is.null), ref_edges)

  from <- unlist(lapply(ref_edges, `[[`, "from"), use.names = FALSE)
  to <- unlist(lapply(ref_edges, `[[`, "to"), use.names = FALSE)
  name <- unlist(lapply(ref_edges, `[[`, "name"), use.names = FALSE)
  via <- unlist(lapply(ref_edges, `[[`, "via"), use.names = FALSE)

  non_setup <- ids[ids != setup]
  from <- c(from, non_setup)
  to <- c(to, rep(setup, length(non_setup)))
  name <- c(name, rep(NA_character_, length(non_setup)))
  via <- c(via, rep("setup", length(non_setup)))

  data.frame(from = from, to = to, name = name, via = via, stringsAsFactors = FALSE)
}

#' Strongly connected components of a graph given as an adjacency list
#' (id -> character vector of ids it points to), via Tarjan's algorithm.
#' Returns a list of character vectors; a component of length 1 is not a
#' cycle (the design gives no self edges).
scc_components <- function(ids, adjacency) {
  counter <- 0L
  index <- list()
  low <- list()
  on_stack <- list()
  stack <- character()
  components <- list()

  connect <- function(v) {
    counter <<- counter + 1L
    index[[v]] <<- counter
    low[[v]] <<- counter
    stack <<- c(stack, v)
    on_stack[[v]] <<- TRUE

    for (w in adjacency[[v]]) {
      if (is.null(index[[w]])) {
        connect(w)
        low[[v]] <<- min(low[[v]], low[[w]])
      } else if (isTRUE(on_stack[[w]])) {
        low[[v]] <<- min(low[[v]], index[[w]])
      }
    }

    if (identical(low[[v]], index[[v]])) {
      comp <- character()
      repeat {
        w <- stack[length(stack)]
        stack <<- stack[-length(stack)]
        on_stack[[w]] <<- FALSE
        comp <- c(comp, w)
        if (identical(w, v)) break
      }
      components[[length(components) + 1]] <<- comp
    }
  }

  for (id in ids) if (is.null(index[[id]])) connect(id)
  components
}

#' All graph errors.
find_errors <- function(cells, analyses, edges, setup, ids, components) {
  errors <- list()

  # parse: analyses[[id]]$parse_error non-NULL.
  for (id in ids) {
    pe <- analyses[[id]]$parse_error
    if (!is.null(pe)) {
      errors[[length(errors) + 1]] <- new_graph_error(
        kind = "parse", cells = id, names = character(), lines = NULL,
        message = sprintf("%s has a syntax error: %s", id, pe$message),
        fixes = character())
    }
  }

  # multiple_definitions: public name with >1 definer (learned included);
  # cells = the definers; lines from each analysis's definitions rows;
  # fix wording depends on whether any row has kind "replacement", or all
  # are kind "for".
  definer_map <- list()
  for (id in ids) {
    for (n in cells[[id]]$definitions) definer_map[[n]] <- union(definer_map[[n]], id)
  }
  for (n in names(definer_map)) {
    defs <- definer_map[[n]]
    if (length(defs) <= 1) next
    kinds <- character()
    lines_rows <- list()
    for (id in defs) {
      rows <- analyses[[id]]$definitions[analyses[[id]]$definitions$name == n, , drop = FALSE]
      if (nrow(rows) > 0) {
        kinds <- c(kinds, rows$kind)
        lines_rows[[length(lines_rows) + 1]] <-
          data.frame(cell = id, line = rows$line, stringsAsFactors = FALSE)
      } else {
        lines_rows[[length(lines_rows) + 1]] <-
          data.frame(cell = id, line = NA_integer_, stringsAsFactors = FALSE)
      }
    }
    lines_df <- do.call(rbind, lines_rows)
    fix <- if ("replacement" %in% kinds) {
      sprintf("Move the line into the cell that defines %s, or name the result (%s2 <- ...)", n, n)
    } else if (length(kinds) > 0 && all(kinds == "for")) {
      sprintf("Use a private name: .%s", n)
    } else {
      sprintf("Move the line into the cell that defines %s, or name the result (%s2 <- ...)", n, n)
    }
    errors[[length(errors) + 1]] <- new_graph_error(
      kind = "multiple_definitions", cells = defs, names = n, lines = lines_df,
      message = sprintf("%s is defined in more than one cell.", n), fixes = fix)
  }

  # private_name: reference n of b with is_private_name(n) and some other
  # cell defining n; cells = b; message names the defining cell. Built from
  # a name -> owning ids lookup (one pass over private names) instead of
  # testing every id against every private reference.
  private_owner_map <- list()
  for (id in ids) {
    for (n in cells[[id]]$private) private_owner_map[[n]] <- union(private_owner_map[[n]], id)
  }
  for (b in ids) {
    for (n in cells[[b]]$references) {
      if (!is_private_name(n)) next
      owners <- private_owner_map[[n]]
      if (is.null(owners)) next
      owners <- owners[owners != b]
      if (length(owners) == 0) next
      errors[[length(errors) + 1]] <- new_graph_error(
        kind = "private_name", cells = b, names = n, lines = NULL,
        message = sprintf("%s is private to %s.", n, paste(owners, collapse = ", ")),
        fixes = sprintf("Drop the dot: %s", sub("^\\.", "", n)))
    }
  }

  # global_setting: cells[[id]]$settings non-empty and id != setup.
  for (id in ids) {
    if (identical(id, setup)) next
    settings <- cells[[id]]$settings
    if (is.null(settings) || nrow(settings) == 0) next
    fns <- unique(settings$fn)
    errors[[length(errors) + 1]] <- new_graph_error(
      kind = "global_setting", cells = id, names = character(), lines = NULL,
      message = sprintf("%s changes a global setting outside the setup cell.",
                        paste(fns, collapse = ", ")),
      fixes = "Move it to the setup cell, or use withr::with_options() for one piece of code")
  }

  # cycle: strongly connected components of `edges` (Tarjan over the
  # upstream lists) with more than one cell; one error per component,
  # names = the edge names inside the component.
  for (comp in components) {
    if (length(comp) <= 1) next
    comp_ord <- ids[ids %in% comp]
    names_in_comp <- unique(edges$name[edges$from %in% comp & edges$to %in% comp &
                                          edges$via != "setup"])
    names_in_comp <- names_in_comp[!is.na(names_in_comp)]
    fix <- if (length(names_in_comp) == 1) {
      sprintf("If %s is a column name, rename the global", names_in_comp)
    } else if (length(names_in_comp) > 1) {
      sprintf("If one of %s is a column name, rename the global",
              paste(names_in_comp, collapse = ", "))
    } else {
      character()
    }
    errors[[length(errors) + 1]] <- new_graph_error(
      kind = "cycle", cells = comp_ord, names = names_in_comp, lines = NULL,
      message = sprintf("%s form a cycle.", paste(comp_ord, collapse = ", ")),
      fixes = fix)
  }

  errors
}

#' Run order over all cells.
#'
#' A topological order that keeps display order wherever the edges allow
#' it, with package-attaching cells before the rest:
#'
#' 1. emit(setup)
#' 2. for each cell attaching a package, in display order: emit(cell)
#' 3. for each cell in display order: emit(cell)
#'
#' where `emit(c)` emits `c`'s unemitted upstream cells first (in display
#' order, recursively), then `c`. Cells in a cycle are emitted in display
#' order when the first of them is reached, so the order is total and the
#' file writer never has to special-case them. Cells with other errors
#' keep their place; the scheduler excludes them by `errors`.
#'
#' Going cell by cell in display order, instead of Kahn's algorithm with a
#' priority queue, means a cell moves in the file only when an edge forces
#' it, which keeps markdown cells next to their neighbours and makes small
#' edits small diffs.
#'
#' `comp_of` is `id -> component index` from `scc_components()`, one
#' integer per id (all distinct for cells not in a cycle). When walking
#' `id`'s upstream cells, an upstream cell sharing `id`'s component is
#' skipped rather than recursed into: forcing that order is exactly what a
#' cycle makes impossible, and skipping it (instead of the sketch's plain
#' `cycle_cells` flag) is what keeps two independent cycles from spuriously
#' blocking each other's order.
#'
#' Markdown cells (`is_markdown`, keyed by id: empty or whitespace-only
#' code) take no part in the walk above: they have no edges worth forcing a
#' position over, and package-attaching cells pulling their neighbours
#' forward in passes 2 and 3 would otherwise strand them at the end. So
#' every markdown cell is assigned an anchor, the next non-markdown cell in
#' *display* order (or none, for markdown cells after the last code cell),
#' and is placed immediately before that anchor at the moment the anchor
#' itself is placed -- wherever in the walk that happens. Markdown cells
#' with no anchor are appended at the end, in display order, after the walk
#' finishes. `[s, md1, a, md2, b]` with `b` attaching a package and using
#' `a`'s name gives run order `s a b` for the code cells (pass 2 pulls `a`
#' and `b` ahead of `md1`/`md2`); anchoring reinserts `md1` before `a` and
#' `md2` before `b`, for `s md1 a md2 b`.
compute_order <- function(ids, setup, upstream, attaches, comp_of, is_markdown) {
  # anchor[[id]]: for a markdown id, the next non-markdown id in display
  # order (NA if none). Computed with one backward pass over `ids`.
  anchor <- setNames(rep(NA_character_, length(ids)), ids)
  next_code <- NA_character_
  for (id in rev(ids)) {
    if (isTRUE(is_markdown[[id]])) {
      anchor[[id]] <- next_code
    } else {
      next_code <- id
    }
  }
  # pending[[anchor_id]]: markdown ids to place right before anchor_id,
  # display order.
  pending <- new.env(parent = emptyenv())
  for (id in ids) {
    a <- anchor[[id]]
    if (!is.na(a)) pending[[a]] <- c(pending[[a]], id)
  }

  emitted <- character()
  emitted_flag <- new.env(parent = emptyenv())
  visiting_flag <- new.env(parent = emptyenv())

  place <- function(id) {
    emitted[length(emitted) + 1] <<- id
    assign(id, TRUE, envir = emitted_flag)
  }

  emit <- function(id) {
    if (isTRUE(emitted_flag[[id]]) || isTRUE(visiting_flag[[id]])) return(invisible())
    assign(id, TRUE, envir = visiting_flag)
    for (u in upstream[[id]]) {
      if (identical(comp_of[[id]], comp_of[[u]])) next
      emit(u)
    }
    rm(list = id, envir = visiting_flag)
    if (!isTRUE(emitted_flag[[id]])) {
      for (m in pending[[id]]) if (!isTRUE(emitted_flag[[m]])) place(m)
      place(id)
    }
  }

  emit(setup)
  for (id in ids) if (!isTRUE(is_markdown[[id]]) && length(attaches[[id]]) > 0) emit(id)
  for (id in ids) if (!isTRUE(is_markdown[[id]])) emit(id)
  for (id in ids) if (isTRUE(is_markdown[[id]]) && !isTRUE(emitted_flag[[id]])) place(id)
  emitted
}
