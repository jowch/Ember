# Test-only helpers for R/graph.R. read_cell() (R/analysis.R) isn't
# implemented yet, so tests build ember_cell_analysis values directly and
# feed them to notebook_graph() as a `previous` graph, which makes
# reuse_analysis() take them as-is without calling read_cell().

#' Build one `ember_cell_analysis` from plain vectors.
#'
#' `defs`/`kinds` are parallel: default kind is "assign" for every name.
#' `attaches`/`used` are package names split by whether they're attached.
fake_cell <- function(code = "",
                      defs = character(), kinds = NULL,
                      refs = character(),
                      attaches = character(), used = character(),
                      settings = character(),
                      sourced = NULL,
                      parse_error = NULL) {
  def_kinds <- if (is.null(kinds)) rep("assign", length(defs)) else kinds
  definitions <- if (length(defs) == 0) {
    empty_definitions()
  } else {
    data.frame(name = defs, line = seq_along(defs), kind = def_kinds,
              file = NA_character_, stringsAsFactors = FALSE)
  }
  references <- if (length(refs) == 0) {
    empty_references()
  } else {
    data.frame(name = refs, line = seq_along(refs), where = "code",
              file = NA_character_, stringsAsFactors = FALSE)
  }
  pkg_names <- c(attaches, used)
  pkg_attached <- c(rep(TRUE, length(attaches)), rep(FALSE, length(used)))
  packages <- if (length(pkg_names) == 0) {
    empty_packages()
  } else {
    data.frame(name = pkg_names, attached = pkg_attached,
              line = seq_along(pkg_names), stringsAsFactors = FALSE)
  }
  settings_df <- if (length(settings) == 0) {
    empty_settings()
  } else {
    data.frame(fn = settings, line = seq_along(settings), stringsAsFactors = FALSE)
  }
  sourced_df <- if (is.null(sourced)) empty_sourced() else sourced

  new_cell_analysis(code = code, parse_error = parse_error,
                    definitions = definitions, references = references,
                    packages = packages, settings = settings_df,
                    sourced = sourced_df)
}

#' Build an `ember_graph` from a named list of `ember_cell_analysis` values,
#' without calling `read_cell()`: `notebook_graph()` is given a `previous`
#' whose `analyses` are exactly these, keyed by the same ids and code, so
#' every one is reused as-is.
build_test_graph <- function(analyses, setup = names(analyses)[1],
                             exports = list(), learned = NULL,
                             read_file = NULL) {
  ids <- names(analyses)
  cells <- vapply(ids, function(id) analyses[[id]]$code, character(1))
  previous <- list(analyses = analyses)
  notebook_graph(cells, setup = setup, exports = exports, learned = learned,
                 previous = previous, read_file = read_file)
}
