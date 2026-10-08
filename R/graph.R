# The notebook graph: a pure function of the cells, the package exports,
# the disabled cells, and what the worker has learned. Rebuilt whole on every
# change; only cells whose code changed are re-read.

# ---- Result type -----------------------------------------------------------

#' The notebook graph.
#'
#' Built by `notebook_graph()`. Fields:
#'
#' * `ids`: cell ids in display order. Every named list below is keyed by
#'   these ids, in this order.
#' * `settings`: ids of the settings cells, in display order: enabled
#'   cells with a static or learned setting (settings-cells.md). They run
#'   first, and every later cell depends on them.
#' * `analyses`: `ember_cell_analysis` per cell (the cache for the next
#'   build).
#' * `learned`: `list(definitions = <id -> character>, references = <id ->
#'   character>, settings = <id -> character>)`: what the worker reported,
#'   exactly as given (settings as keys, `setting_keys()`). The caller
#'   owns this; the graph carries it so `notebook_graph(previous = g)` can
#'   keep it.
#' * `exports`: the package exports the graph was built with.
#' * `cells`: per cell, `list(definitions, learned, references, packages,
#'   attaches, settings, setting_keys, private, methods)`: the resolved view the
#'   adapter reports. `definitions` are the public names the cell defines
#'   (static plus learned); `private` its dot-names; `attaches` the
#'   packages it puts on the search path; `settings` the analysis's
#'   settings rows; `setting_keys` a data frame `key`, `found` (`"code"`
#'   or `"run"`) of the settings it sets, static first. `methods` the
#'   methods it defines (`resolve_methods()`): a data frame `generic`,
#'   `signature`, `form`, `key`, `line`.
#' * `edges`: data frame `from`, `to`, `name`, `via`: `from` depends on
#'   `to`. `via` is `"definition"` (`to` defines `name`), `"package"` (`to`
#'   attaches a package exporting `name`), `"disabled"` (`to` is a disabled
#'   cell that defines or attaches `name`, and no enabled cell does),
#'   `"setting"` (`to` is a settings cell before `from` in the run order;
#'   `name` is that cell's first setting, as `setting_label()` shows it, or
#'   `NA` when none is known yet), `"method"` (`to` defines a method of the
#'   generic `name`, which `from` reads). One row per (from, to, name).
#' * `disabled`: character ids of disabled cells, as given to
#'   `notebook_graph()`. Disabled cells are still fully analysed and keep
#'   their own edges to what they read; they just satisfy no other cell's
#'   reference (`resolve_edges()`), so they count towards nothing else's
#'   `find_errors()` rule but `parse`.
#' * `off`: named character, off cell id -> the disabled cell it comes
#'   from (itself, for a disabled cell). See `compute_off()`. Setting edges
#'   don't carry it: a settings cell that is off is just not in effect.
#' * `upstream`, `downstream`: `id -> character` of direct neighbours, in
#'   display order, derived from `edges` at build time (including
#'   `"disabled"` and `"setting"` edges: a disabled cell is ordered, and
#'   its dependents found, like any other).
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
#' no definitions and no references but keeps its setting edges.
new_graph <- function(ids, settings, analyses, learned, exports, cells, edges,
                      disabled, off, upstream, downstream, order, errors,
                      reread, read_file = NULL) {
  structure(list(ids = ids, settings = settings, analyses = analyses,
                 learned = learned, exports = exports, cells = cells,
                 edges = edges, disabled = disabled, off = off,
                 upstream = upstream, downstream = downstream,
                 order = order, errors = errors, reread = reread,
                 read_file = read_file),
            class = "ember_graph")
}

#' A graph-level error.
#'
#' `kind` is one of `"parse"`, `"multiple_definitions"`, `"cycle"`,
#' `"private_name"`, `"setting_conflict"` (one setting set in two cells),
#' `"package_conflict"` (one package attached in two cells),
#' `"mixed_text"` (a cell mixing `#'` lines and code; text-cells.R's
#' `is_mixed()`). `cells` are the ids the error is reported on (all of
#' them can't run). `names` are the globals, settings or packages involved
#' (empty for `parse`). `lines` is a data frame `cell`,
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
#' * setting in two cells: "Set it in one cell, or use
#'   withr::with_options() to change it for one piece of code" (the scoped
#'   function by kind; `setting_fix()`).
#' * package in two cells: "Keep one library(pkg) and remove the other".
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
#' @param exports Named list, package name -> character vector of exported
#'   names (`getNamespaceExports()`), for the packages that are installed.
#'   A package not in the list contributes no edges.
#' @param learned `list(definitions = <id -> character>, references = <id ->
#'   character>, settings = <id -> character>)` from the footer, the
#'   formula checks and the worker's settings reports; `NULL` means none.
#'   Ids not in `cells` are dropped.
#' @param disabled Character ids of disabled cells (the user's choice; see
#'   `disable_cell()`). Ids not in `cells` are dropped. Disabled cells are
#'   analysed like any other, but satisfy no other cell's reference
#'   (`resolve_edges()`) and are left out of every `find_errors()` rule but
#'   `parse`.
#' @param previous An earlier `ember_graph` for the same notebook, or
#'   `NULL`. Analyses are reused for cells whose code is identical and whose
#'   sourced files still read the same; everything else is recomputed.
#'   Passing `previous` never changes the result, only the work done.
#' @param read_file Reader for `source()` paths; see `read_cell()`.
#' @return An `ember_graph`.
#'
#' The build is deterministic and idempotent: the same inputs give an
#' identical graph, with or without `previous`.
notebook_graph <- function(cells, exports = list(),
                           learned = NULL, disabled = character(),
                           previous = NULL, read_file = NULL) {
  ids <- names(cells)
  if (is.null(ids) || any(is.na(ids)) || any(ids == "") ||
      any(duplicated(ids))) {
    stop("cells must be a named character vector with unique, non-empty names")
  }
  disabled <- intersect(disabled, ids)

  if (is.null(learned)) learned <- list()
  if (is.null(learned$definitions)) learned$definitions <- list()
  if (is.null(learned$references)) learned$references <- list()
  if (is.null(learned$settings)) learned$settings <- list()
  learned$definitions <- learned$definitions[names(learned$definitions) %in% ids]
  learned$references <- learned$references[names(learned$references) %in% ids]
  learned$settings <- learned$settings[names(learned$settings) %in% ids]

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
  cells_resolved <- resolve_methods(cells_resolved, analyses, exports, ids)

  # 3. edges: resolve_edges(cells, exports, disabled). Setting edges come
  #    after the order (step 6).
  edges <- resolve_edges(cells_resolved, exports, ids, disabled)

  # upstream/downstream from edges, in display order.
  rank <- setNames(seq_along(ids), ids)
  upstream_list <- neighbour_lists(ids, rank, edges$from, edges$to)
  downstream_list <- neighbour_lists(ids, rank, edges$to, edges$from)

  # Strongly connected components of the dependency graph, computed once and
  # shared by compute_order (which cells can't force an order onto one
  # another) and, when nothing is disabled, by find_errors (the cycle
  # error) too.
  components <- scc_components(ids, upstream_list)

  # A cycle that only exists through a "disabled" edge isn't one: that edge
  # is already how a dependent of a disabled cell is found (upstream/
  # downstream), not a real ordering constraint. find_errors() gets
  # components of the graph without those edges instead, computed only when
  # something is disabled (otherwise identical to `components` above).
  error_components <- if (length(disabled) == 0) {
    components
  } else {
    no_disabled <- split(edges$to[edges$via != "disabled"], edges$from[edges$via != "disabled"])
    upstream_no_disabled <- setNames(vector("list", length(ids)), ids)
    for (id in ids) upstream_no_disabled[[id]] <- character()
    for (f in names(no_disabled)) upstream_no_disabled[[f]] <- unique(no_disabled[[f]])
    scc_components(ids, upstream_no_disabled)
  }

  # 4. errors: find_errors(cells, analyses, edges, ids, disabled).
  errors <- find_errors(cells_resolved, analyses, edges, ids, error_components, disabled)

  # off: disabled cells and everything downstream of them.
  off <- compute_off(ids, disabled, downstream_list)

  # 5. order <- compute_order(...).
  comp_of <- setNames(rep(NA_integer_, length(ids)), ids)
  for (i in seq_along(components)) comp_of[components[[i]]] <- i
  attaches_list <- setNames(lapply(ids, function(id) cells_resolved[[id]]$attaches), ids)
  is_markdown <- setNames(vapply(ids, function(id) grepl("^\\s*$", analyses[[id]]$code), logical(1)), ids)
  settings <- ids[vapply(ids, function(id) {
    !(id %in% disabled) && nrow(cells_resolved[[id]]$setting_keys) > 0
  }, logical(1))]
  order <- compute_order(ids, settings, upstream_list, attaches_list, comp_of, is_markdown)

  # 6. setting edges: every non-markdown cell to each settings cell before
  #    it in the order. They agree with the order by construction, so they
  #    are added after the cycle check and change nothing above; they do
  #    change upstream/downstream (staleness, what runs first).
  if (length(settings) > 0) {
    setting_edges <- setting_edges_of(order, settings, cells_resolved, is_markdown)
    if (nrow(setting_edges) > 0) {
      edges <- rbind(edges, setting_edges)
      upstream_list <- neighbour_lists(ids, rank, edges$from, edges$to)
      downstream_list <- neighbour_lists(ids, rank, edges$to, edges$from)
    }
  }

  new_graph(ids = ids, settings = settings, analyses = analyses, learned = learned,
            exports = exports, cells = cells_resolved, edges = edges,
            disabled = disabled, off = off,
            upstream = upstream_list, downstream = downstream_list,
            order = order, errors = errors, reread = reread,
            read_file = read_file)
}

#' Disabled cells and every cell downstream of them, through any edge
#' (Pluto's `depends_on_disabled_cells`). Named character: off id -> the
#' disabled cell it comes from. A disabled cell maps to itself; a dependent
#' to the first disabled cell, in display order, whose downstream walk
#' reaches it. Empty when nothing is disabled.
#' Walks with `downstream(..., transitive = TRUE)` (queries.R) against a
#' graph-shaped `list(downstream = downstream_list, order = ids)` -- all
#' that function reads -- instead of a second transitive-walk
#' implementation. `order` here is display order, not the run order the
#' real graph will get (computed after `off`, since `compute_order()` needs
#' `off` nowhere); that only changes the order `downstream()` hands back,
#' not which ids it reaches, and the assignment loop below doesn't care
#' about that order, only about which disabled cell's walk gets there first.
compute_off <- function(ids, disabled, downstream_list) {
  ordered <- ids[ids %in% disabled]
  off <- character()
  for (did in ordered) off[[did]] <- did
  fake_graph <- list(downstream = downstream_list, order = ids)
  for (did in ordered) {
    reached <- downstream(fake_graph, did, transitive = TRUE)
    for (d in reached) if (!(d %in% names(off))) off[[d]] <- did
  }
  off
}

#' Add what the worker learned about one cell, and rebuild.
#'
#' `definitions` replaces the learned definitions of `cell` (the worker
#' reports the full set after each run, so a name that stopped appearing
#' drops out); `references` replaces its learned references (the formula
#' check's missing columns); `settings` replaces its learned setting keys
#' (`character()` drops them). `NULL` leaves that part as it was. Returns a
#' new graph built with `previous = graph`, so nothing is re-read.
#'
#' The caller persists `graph$learned$definitions` and
#' `graph$learned$settings` in the footer.
graph_learn <- function(graph, cell, definitions = NULL, references = NULL,
                        settings = NULL) {
  learned <- graph$learned
  if (!is.null(definitions)) learned$definitions[[cell]] <- definitions
  if (!is.null(references)) learned$references[[cell]] <- references
  if (!is.null(settings)) {
    learned$settings[[cell]] <- if (length(settings) > 0) settings else NULL
  }
  cells <- setNames(vapply(graph$ids, function(id) graph$analyses[[id]]$code,
                            character(1)), graph$ids)
  notebook_graph(cells, exports = graph$exports,
                 learned = learned, disabled = graph$disabled,
                 previous = graph, read_file = graph$read_file)
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
    learned_settings <- learned$settings[[id]]
    if (is.null(learned_settings)) learned_settings <- character()

    defs_all <- unique(c(definitions_of(a), learned_defs))
    private <- defs_all[is_private_name(defs_all)]
    definitions <- defs_all[!is_private_name(defs_all)]
    references <- unique(c(references_of(a), learned_refs))
    attaches <- unique(a$packages$name[a$packages$attached])

    cells[[id]] <- list(definitions = definitions, learned = learned_defs,
                        references = references,
                        packages = unique(a$packages$name),
                        attaches = attaches, settings = a$settings,
                        setting_keys = setting_keys_of(a$settings, learned_settings),
                        private = private, methods = a$methods)
  }
  cells
}

#' The methods each cell defines, as the graph counts them (the Pluto
#' model: a method definition defines the (generic, class) pair, and every
#' cell that reads the generic depends on it).
#'
#' `"register"` and `"s4"` rows (`registerS3method()`, `setMethod()`) always
#' count. A `"name"` row (`print.foo <- function`) counts only when its
#' generic is in `s3_generics`, is a function or `setGeneric()` some cell
#' defines (kind `"function"` or `"generic"`), or is a name an installed
#' package exports; a dotted helper name whose prefix is none of those
#' (`fit.plot`) is just a function. `key` names the (generic, class) pair
#' for the duplicate check: `generic.class` for S3 (so `print.foo` and
#' `registerS3method("print", "foo")` meet), `generic(signature)` for S4,
#' `NA` when the class or signature is computed. Replaces each cell's
#' `methods` with the rows that count plus `key`; `file`, `col` and
#' `end_col` are dropped.
resolve_methods <- function(cells, analyses, exports, ids) {
  has <- ids[vapply(ids, function(id) nrow(cells[[id]]$methods) > 0, logical(1))]
  if (length(has) == 0) {
    for (id in ids) cells[[id]]$methods <- empty_resolved_methods()
    return(cells)
  }
  # Generics the notebook defines itself: functions and setGeneric() names.
  user_generics <- unique(unlist(lapply(ids, function(id) {
    d <- analyses[[id]]$definitions
    d$name[d$kind %in% c("function", "generic")]
  }), use.names = FALSE))
  is_generic <- function(g) {
    g %in% s3_generics || g %in% user_generics ||
      any(vapply(exports, function(x) g %in% x, logical(1)))
  }
  for (id in ids) {
    m <- cells[[id]]$methods
    if (nrow(m) == 0) {
      cells[[id]]$methods <- empty_resolved_methods()
      next
    }
    keep <- m$form != "name" | vapply(m$generic, is_generic, logical(1))
    m <- m[keep, , drop = FALSE]
    key <- ifelse(is.na(m$signature), NA_character_,
                  ifelse(m$form == "s4", sprintf("%s(%s)", m$generic, m$signature),
                         paste0(m$generic, ".", m$signature)))
    cells[[id]]$methods <- data.frame(generic = m$generic, signature = m$signature,
                                      form = m$form, key = key, line = m$line,
                                      stringsAsFactors = FALSE)
  }
  cells
}

empty_resolved_methods <- function() {
  data.frame(generic = character(), signature = character(), form = character(),
             key = character(), line = integer(), stringsAsFactors = FALSE)
}

#' Edges from references to the cells that satisfy them.
#'
#' For each reference `n` of cell `b`, in this order, stopping at the first
#' rule that yields cells:
#' 1. enabled cells (other than `b`) whose public definitions include `n`:
#'    one edge each, via "definition". If `n` is a dot-name defined in
#'    another cell, no edge; `find_errors` reports it.
#' 2. else enabled cells (other than `b`) attaching a package whose exports
#'    include `n`: one edge each, via "package". A global definition
#'    shadows a package export, as the global environment comes first on
#'    R's search path, which is why rule 1 stops the search before this
#'    one; an enabled package export likewise wins over a disabled global
#'    definer, which is why rules 3-4 come after this one, not before.
#' 3. else disabled cells (other than `b`) whose public definitions include
#'    `n`: one edge each, via "disabled" -- what `b` would read if they
#'    were enabled.
#' 4. else disabled cells (other than `b`) attaching such a package: one
#'    edge each, via "disabled".
#' A disabled cell's own references resolve the same way (rules 1-4 look at
#' the target's status, not `b`'s), so it keeps edges to what it reads.
#'
#' Methods (`resolve_methods()`) add to whichever rule matched: for a
#' reference `n` of `b`, every other enabled cell defining a method of the
#' generic `n` gets an edge via "method", unless it already has an edge
#' for `n` or `b` itself defines a method of `n`. That last exception keeps
#' two cells that each define a `print` method and call `print()` from
#' forming a cycle: a method for one class doesn't change how the other
#' class's objects print (inheritance aside). A disabled cell's methods
#' give no edge, since R falls back to another method without them. A
#' `registerS3method()` or `setMethod()` call also reads its generic, by
#' rules 1-4 only, so it runs after the cell that defines the generic
#' (`setGeneric()`) or attaches the package exporting it.
#' Setting edges are added later, once the order is known
#' (`setting_edges_of()`).
resolve_edges <- function(cells, exports, ids, disabled = character()) {
  # Four lookup tables, each built in one pass so the whole function is
  # linear in (total definitions + total exports + total references)
  # instead of the reference-times-cells cost of testing every id against
  # every reference:
  #  - definer_lookup, disabled_definer_lookup: name -> ids that publicly
  #    define it (enabled / disabled), display order.
  #  - attachers, disabled_attachers: package -> ids attaching it (enabled /
  #    disabled), display order.
  #  - name_to_pkgs: name -> packages (from `exports`) that export it.
  # A reference is then resolved by two hash lookups (plus, for rules 3-4,
  # one lookup per exporting package) rather than a scan of every id.
  definer_lookup <- new.env(parent = emptyenv())
  disabled_definer_lookup <- new.env(parent = emptyenv())
  for (id in ids) {
    tbl <- if (id %in% disabled) disabled_definer_lookup else definer_lookup
    for (n in cells[[id]]$definitions) {
      tbl[[n]] <- c(tbl[[n]], id)
    }
  }
  attachers <- new.env(parent = emptyenv())
  disabled_attachers <- new.env(parent = emptyenv())
  for (id in ids) {
    tbl <- if (id %in% disabled) disabled_attachers else attachers
    for (p in cells[[id]]$attaches) {
      tbl[[p]] <- c(tbl[[p]], id)
    }
  }
  name_to_pkgs <- new.env(parent = emptyenv())
  for (p in names(exports)) {
    for (n in exports[[p]]) {
      name_to_pkgs[[n]] <- c(name_to_pkgs[[n]], p)
    }
  }

  # generic -> enabled ids defining a method of it, display order. Empty
  # (and skipped below) for the usual notebook with no methods.
  method_lookup <- new.env(parent = emptyenv())
  for (id in ids) {
    if (id %in% disabled) next
    for (g in unique(cells[[id]]$methods$generic)) {
      method_lookup[[g]] <- c(method_lookup[[g]], id)
    }
  }
  has_methods <- length(ls(method_lookup, all.names = TRUE)) > 0

  package_providers <- function(n, tbl) {
    pkgs <- name_to_pkgs[[n]]
    if (is.null(pkgs)) return(character())
    unique(unlist(lapply(pkgs, function(p) tbl[[p]]), use.names = FALSE))
  }

  # Rule 1 only sees public definitions: private names never appear in
  # `cells[[id]]$definitions`, so a dot-name reference falls through to no
  # edge without a special case here. Each cell's own edges are built as
  # plain vectors and combined with `unlist()` once, rather than growing
  # one shared vector element by element.
  ref_edges <- lapply(ids, function(b) {
    refs <- cells[[b]]$references
    m_b <- cells[[b]]$methods
    own_generics <- unique(m_b$generic)
    refs <- c(refs, setdiff(unique(m_b$generic[m_b$form != "name"]), refs))
    if (length(refs) == 0) return(NULL)
    resolve_ref <- function(n) {
      definers <- definer_lookup[[n]]
      if (!is.null(definers)) definers <- definers[definers != b]
      if (length(definers) > 0) {
        return(list(from = rep(b, length(definers)), to = definers,
                    name = rep(n, length(definers)),
                    via = rep("definition", length(definers))))
      }
      provider_ids <- package_providers(n, attachers)
      provider_ids <- provider_ids[provider_ids != b]
      if (length(provider_ids) > 0) {
        provider_ids <- ids[ids %in% provider_ids]
        return(list(from = rep(b, length(provider_ids)), to = provider_ids,
                    name = rep(n, length(provider_ids)), via = rep("package", length(provider_ids))))
      }
      disabled_definers <- disabled_definer_lookup[[n]]
      if (!is.null(disabled_definers)) disabled_definers <- disabled_definers[disabled_definers != b]
      if (length(disabled_definers) > 0) {
        return(list(from = rep(b, length(disabled_definers)), to = disabled_definers,
                    name = rep(n, length(disabled_definers)),
                    via = rep("disabled", length(disabled_definers))))
      }
      disabled_provider_ids <- package_providers(n, disabled_attachers)
      disabled_provider_ids <- disabled_provider_ids[disabled_provider_ids != b]
      if (length(disabled_provider_ids) == 0) return(NULL)
      disabled_provider_ids <- ids[ids %in% disabled_provider_ids]
      list(from = rep(b, length(disabled_provider_ids)), to = disabled_provider_ids,
          name = rep(n, length(disabled_provider_ids)), via = rep("disabled", length(disabled_provider_ids)))
    }
    parts <- lapply(refs, function(n) {
      res <- resolve_ref(n)
      if (!has_methods || n %in% own_generics) return(res)
      m <- method_lookup[[n]]
      m <- m[m != b & !(m %in% res$to)]
      if (length(m) == 0) return(res)
      list(from = c(res$from, rep(b, length(m))), to = c(res$to, m),
           name = c(res$name, rep(n, length(m))), via = c(res$via, rep("method", length(m))))
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

  if (is.null(from)) from <- to <- name <- via <- character()
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

#' All graph errors. `disabled` cells count towards no rule but `parse`
#' (the user still sees that their code is broken): they define nothing for
#' `multiple_definitions`, own no private name for `private_name`, set or
#' attach nothing for the two conflict rules, and the cycle check (via `components`) has
#' already had their edges to and from other cells excluded by the caller.
find_errors <- function(cells, analyses, edges, ids, components,
                        disabled = character()) {
  errors <- list()

  # parse: analyses[[id]]$parse_error non-NULL. lines carries pe$line
  # through to project_parse_error() (pluto-state.R) so the diagnostic
  # lands on the real line instead of always line 1.
  for (id in ids) {
    pe <- analyses[[id]]$parse_error
    if (!is.null(pe)) {
      errors[[length(errors) + 1]] <- new_graph_error(
        kind = "parse", cells = id, names = character(),
        lines = if (!is.null(pe$line) && !is.na(pe$line)) {
          data.frame(line = pe$line)
        },
        message = sprintf("Syntax error: %s", pe$message),
        fixes = character())
    }
  }

  # multiple_definitions: public name with >1 definer (learned included);
  # cells = the definers; lines from each analysis's definitions rows;
  # fix wording depends on whether any row has kind "replacement", or all
  # are kind "for". A disabled cell defines nothing here (Pluto's rule): it
  # doesn't count as a definer, and can't be named alongside one.
  definer_map <- list()
  for (id in ids) {
    if (id %in% disabled) next
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

  # multiple_definitions of a method: one (generic, class) key in two or
  # more enabled cells, where at least one of them registers it by a call
  # (two `print.foo <- function` cells are already caught above, by name).
  method_map <- list()
  for (id in ids) {
    if (id %in% disabled) next
    m <- cells[[id]]$methods
    m <- m[!is.na(m$key), , drop = FALSE]
    for (i in seq_len(nrow(m))) {
      method_map[[m$key[i]]] <- rbind(method_map[[m$key[i]]],
                                      data.frame(cell = id, form = m$form[i], generic = m$generic[i],
                                                 signature = m$signature[i], line = m$line[i],
                                                 stringsAsFactors = FALSE))
    }
  }
  for (k in names(method_map)) {
    rows <- method_map[[k]]
    rows <- rows[!duplicated(rows$cell), , drop = FALSE]
    if (nrow(rows) <= 1 || all(rows$form == "name")) next
    named_by <- rows[rows$form != "name", , drop = FALSE][1, ]
    cls <- gsub(",", ", ", named_by$signature, fixed = TRUE)
    errors[[length(errors) + 1]] <- new_graph_error(
      kind = "multiple_definitions", cells = rows$cell, names = k,
      lines = data.frame(cell = rows$cell, line = rows$line, stringsAsFactors = FALSE),
      message = sprintf("The %s method for %s is defined in more than one cell.",
                        named_by$generic, cls),
      fixes = "Keep the method in one cell and remove the others")
  }

  # private_name: reference n of b with is_private_name(n) and some other
  # cell defining n; cells = b. The message names no cell (cell ids are
  # UUIDs and never belong in user-facing text), only the private name.
  # Built from a name -> owning ids lookup (one pass over private names)
  # instead of testing every id against every private reference.
  private_owner_map <- list()
  for (id in ids) {
    if (id %in% disabled) next
    for (n in cells[[id]]$private) private_owner_map[[n]] <- union(private_owner_map[[n]], id)
  }
  for (b in ids) {
    if (b %in% disabled) next
    for (n in cells[[b]]$references) {
      if (!is_private_name(n)) next
      owners <- private_owner_map[[n]]
      if (is.null(owners)) next
      owners <- owners[owners != b]
      if (length(owners) == 0) next
      errors[[length(errors) + 1]] <- new_graph_error(
        kind = "private_name", cells = b, names = n, lines = NULL,
        message = sprintf("%s is private to the cell that defines it.", n),
        fixes = sprintf("Drop the dot: %s", sub("^\\.", "", n)))
    }
  }

  # setting_conflict: one setting key in two or more enabled cells, static
  # or learned (settings-cells.md, "One cell per setting"). A disabled cell
  # sets nothing here, as it defines nothing above.
  setter_map <- list()
  for (id in ids) {
    if (id %in% disabled) next
    for (k in cells[[id]]$setting_keys$key) setter_map[[k]] <- union(setter_map[[k]], id)
  }
  for (k in names(setter_map)) {
    setters <- setter_map[[k]]
    if (length(setters) <= 1) next
    lines_df <- do.call(rbind, lapply(setters, function(id) {
      rows <- analyses[[id]]$settings
      ln <- rows$line[!is.na(rows$setting) & rows$setting == k]
      if (length(ln) == 0) ln <- NA_integer_
      data.frame(cell = id, line = ln, stringsAsFactors = FALSE)
    }))
    label <- setting_label(k)
    errors[[length(errors) + 1]] <- new_graph_error(
      kind = "setting_conflict", cells = setters, names = label, lines = lines_df,
      message = sprintf("%s is set in %s cells.", label, count_word(length(setters))),
      fixes = setting_fix(k))
  }

  # package_conflict: one package attached at the top level of two or more
  # enabled cells (settings-cells.md, "Attaching a package is a
  # definition"). Only literal names count: `attaches` never holds a
  # computed one, nor a package attached inside a function body.
  attacher_map <- list()
  for (id in ids) {
    if (id %in% disabled) next
    for (p in cells[[id]]$attaches) attacher_map[[p]] <- union(attacher_map[[p]], id)
  }
  for (p in names(attacher_map)) {
    attachers <- attacher_map[[p]]
    if (length(attachers) <= 1) next
    lines_df <- do.call(rbind, lapply(attachers, function(id) {
      rows <- analyses[[id]]$packages
      ln <- rows$line[rows$name == p & rows$attached]
      if (length(ln) == 0) ln <- NA_integer_
      data.frame(cell = id, line = ln, stringsAsFactors = FALSE)
    }))
    errors[[length(errors) + 1]] <- new_graph_error(
      kind = "package_conflict", cells = attachers, names = p, lines = lines_df,
      message = sprintf("%s is attached in %s cells.", p, count_word(length(attachers))),
      fixes = sprintf("Keep one library(%s) and remove the other", p))
  }

  # mixed_text: a cell mixing #' lines and code (text-cells.R's
  # is_mixed()) is "code" (cell_kind()), so it stays a graph node here, but
  # nothing in it has run: fixes = character() because the fix is the
  # Split button (ember$split, pluto-state.R), not a wording suggestion.
  # A text cell's analysed code has no #' lines (code_of()), so only code
  # cells can ever match.
  for (id in ids) {
    if (id %in% disabled) next
    if (!is_mixed(analyses[[id]]$code)) next
    errors[[length(errors) + 1]] <- new_graph_error(
      kind = "mixed_text", cells = id, names = character(), lines = NULL,
      message = "Text and code in one cell. A cell is either text (only #' lines) or code. Nothing in it has run.",
      fixes = character())
  }

  # cycle: strongly connected components of `edges` (Tarjan over the
  # upstream lists) with more than one cell; one error per component,
  # names = the edge names inside the component, in display order of the
  # cells defining them.
  for (comp in components) {
    if (length(comp) <= 1) next
    comp_ord <- ids[ids %in% comp]
    inside <- edges[edges$from %in% comp & edges$to %in% comp &
                      edges$via != "setting" & !is.na(edges$name), , drop = FALSE]
    inside <- inside[order(match(inside$to, ids)), , drop = FALSE]
    names_in_comp <- unique(inside$name)
    # A generic read through a method edge is a function call, never a
    # column, so it gets the method fix instead of the column one.
    generics <- unique(inside$name[inside$via == "method"])
    columns <- setdiff(names_in_comp, generics)
    fix <- if (length(columns) == 1) {
      sprintf("If %s is a column name, rename the global", columns)
    } else if (length(columns) > 1) {
      sprintf("If one of %s is a column name, rename the global",
              paste(columns, collapse = ", "))
    } else {
      character()
    }
    if (length(generics) > 0) {
      fix <- c(fix, sprintf("Pass what the %s %s needs as an argument, or move %s into a cell of its own",
                            paste(generics, collapse = ", "),
                            if (length(generics) == 1) "method" else "methods",
                            if (length(generics) == 1) "it" else "them"))
    }
    cycle_msg <- if (length(names_in_comp) > 0) {
      sprintf("%s form a cycle.", paste(names_in_comp, collapse = ", "))
    } else {
      # No named edge inside the component (every link is a bare
      # for dependency): name no cell (cell ids are UUIDs and
      # never belong in user-facing text).
      "These cells form a cycle."
    }
    errors[[length(errors) + 1]] <- new_graph_error(
      kind = "cycle", cells = comp_ord, names = names_in_comp, lines = NULL,
      message = cycle_msg, fixes = fix)
  }

  errors
}

#' Run order over all cells.
#'
#' A topological order that keeps display order wherever the edges allow
#' it, with package-attaching cells before the rest:
#'
#' 1. for each settings cell, in display order: emit(cell)
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
compute_order <- function(ids, settings, upstream, attaches, comp_of, is_markdown) {
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

  for (id in settings) emit(id)
  for (id in ids) if (!isTRUE(is_markdown[[id]]) && length(attaches[[id]]) > 0) emit(id)
  for (id in ids) if (!isTRUE(is_markdown[[id]])) emit(id)
  for (id in ids) if (isTRUE(is_markdown[[id]]) && !isTRUE(emitted_flag[[id]])) place(id)
  emitted
}

# ---- Settings cells -------------------------------------------------------

#' A cell's setting keys: its static keys (the analysis's `settings` rows
#' with a known key), then learned ones it doesn't already have, as a data
#' frame `key`, `found` (`"code"` or `"run"`). A cell whose only setting
#' call has a computed name gets one row with `key = NA` until the worker
#' reports the names, so it is a settings cell from the start
#' (settings-cells.md, "Computed names"); `NA` never conflicts.
setting_keys_of <- function(settings, learned) {
  static <- unique(settings$setting[!is.na(settings$setting)])
  run <- setdiff(learned, static)
  keys <- c(static, run)
  found <- c(rep("code", length(static)), rep("run", length(run)))
  if (length(keys) == 0 && nrow(settings) > 0) {
    keys <- NA_character_
    found <- "code"
  }
  data.frame(key = as.character(keys), found = found, stringsAsFactors = FALSE)
}

#' A setting key as the page shows it: `option:digits` -> `digits`,
#' `env:TZ` -> `TZ`, `attach:survey` -> `attach(survey)`; `wd`, `locale`
#' and `theme` as they are.
setting_label <- function(key) {
  vapply(key, function(k) {
    if (is.na(k)) return(NA_character_)
    if (startsWith(k, "option:")) return(substring(k, 8))
    if (startsWith(k, "env:")) return(substring(k, 5))
    if (startsWith(k, "attach:")) return(sprintf("attach(%s)", substring(k, 8)))
    k
  }, character(1), USE.NAMES = FALSE)
}

#' The fix for a setting set in two cells: the scoped form for its kind.
setting_fix <- function(key) {
  kind <- sub(":.*$", "", key)
  label <- setting_label(key)
  switch(kind,
    option = "Set it in one cell, or use withr::with_options() to change it for one piece of code",
    env = "Set it in one cell, or use withr::with_envvar() to change it for one piece of code",
    wd = "Set it in one cell, or use withr::with_dir() to change it for one piece of code",
    locale = "Set it in one cell, or use withr::with_locale() to change it for one piece of code",
    theme = "Set it in one cell, or add the theme to the plot (p + theme_minimal())",
    attach = sprintf("Attach it in one cell, or use with(%s, ...) or %s$col",
                     substring(key, 8), substring(key, 8)),
    "Set it in one cell")
}

#' "two", "three", ... for small counts, else the number.
count_word <- function(n) {
  words <- c("one", "two", "three", "four", "five", "six", "seven", "eight", "nine")
  if (n >= 1 && n <= length(words)) words[[n]] else as.character(n)
}

#' Setting edges: each non-markdown cell to every settings cell before it
#' in `order`, one row per (from, to), `via = "setting"`, named by that
#' settings cell's first known setting (`setting_label()`).
setting_edges_of <- function(order, settings, cells, is_markdown) {
  from <- character()
  to <- character()
  name <- character()
  seen <- character()
  for (id in order) {
    if (isTRUE(is_markdown[[id]])) next
    if (length(seen) > 0) {
      from <- c(from, rep(id, length(seen)))
      to <- c(to, seen)
    }
    if (id %in% settings) seen <- c(seen, id)
  }
  labels <- vapply(settings, function(s) {
    keys <- cells[[s]]$setting_keys$key
    keys <- keys[!is.na(keys)]
    if (length(keys) == 0) NA_character_ else setting_label(keys[[1]])
  }, character(1))
  name <- unname(labels[to])
  data.frame(from = from, to = to, name = if (length(to)) name else character(),
             via = rep("setting", length(from)), stringsAsFactors = FALSE)
}

#' Neighbour lists from parallel edge vectors: `key[i]` -> `value[i]`,
#' every id present (empty when it has none), each list unique and in
#' display order (`rank`). Grouped with split() (one pass over the edge
#' rows) rather than a per-row union(), which rescans the growing vector on
#' every edge.
neighbour_lists <- function(ids, rank, key, value) {
  out <- setNames(rep(list(character()), length(ids)), ids)
  if (length(key) > 0) {
    groups <- split(value, key)
    for (k in names(groups)) {
      v <- unique(groups[[k]])
      out[[k]] <- v[order(rank[v])]
    }
  }
  out
}
