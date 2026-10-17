# Interactive inputs (docs/inputs.md): which top-level assignments in a
# cell bind an input to a name. Rules 1 and 3 of the binding rule are
# checks on the code, made here from the cell's parse; rule 2 (the call
# reports itself) is the worker's, at run time (`input_hook()` in
# inst/worker.R).

#' The input functions of the first version, without the `input_` prefix.
input_types <- c("slider", "number", "checkbox", "text", "select", "radio")

#' The bindings a code cell's text sets up.
#'
#' `list(bind, blocked)`, each a list of `list(name, index)`: `index` is
#' the top-level expression (1-based, in the cell's own parse) whose
#' right-hand side is the input call. `bind` holds the assignments that
#' meet rules 1 and 3; `blocked` those that meet rule 1 only, because
#' something else in the cell reads or redefines the name (the widget is
#' shown greyed, "Read `n` in another cell"). Empty for code that doesn't
#' parse or names no input function.
input_bindings <- function(code) {
  none <- list(bind = list(), blocked = list())
  # Most cells have no input; skip the parse for them, since this runs for
  # every cell sent to the worker.
  if (!grepl("input_", code, fixed = TRUE)) return(none)
  exprs <- tryCatch(parse(text = code, keep.source = FALSE), error = function(e) NULL)
  if (length(exprs) == 0) return(none)
  out <- none
  for (k in seq_along(exprs)) {
    name <- input_assignment(exprs[[k]])
    if (is.null(name)) next
    others <- unlist(lapply(exprs[-k], symbols_read), use.names = FALSE)
    rhs_reads <- symbols_read(exprs[[k]][[3]])
    slot <- if (name %in% others || name %in% rhs_reads) "blocked" else "bind"
    out[[slot]][[length(out[[slot]]) + 1L]] <- list(name = name, index = k)
  }
  out
}

#' The name `e` binds an input to under rule 1, or `NULL`: `e` is
#' `name <- input_*(...)` or `name = input_*(...)`, the function written
#' bare or as `emberui::input_*`.
input_assignment <- function(e) {
  if (!is.call(e) || length(e) != 3) return(NULL)
  op <- e[[1]]
  if (!(identical(op, as.name("<-")) || identical(op, as.name("=")))) return(NULL)
  if (!is.name(e[[2]])) return(NULL)
  rhs <- e[[3]]
  if (!is.call(rhs) || !is_input_function(rhs[[1]])) return(NULL)
  as.character(e[[2]])
}

is_input_function <- function(f) {
  if (is.call(f) && length(f) == 3 && identical(f[[1]], as.name("::")) &&
      identical(f[[2]], as.name("emberui"))) {
    f <- f[[3]]
  }
  is.name(f) && as.character(f) %in% paste0("input_", input_types)
}

#' Every symbol in `e`, leaving out the field names after `$` and `@`
#' (`x$n` doesn't read `n`). Errs towards finding a name: a symbol in a
#' formula or a function's body counts, which can only grey a widget, never
#' bind one that shouldn't be.
symbols_read <- function(e) {
  if (is.name(e)) return(as.character(e))
  if (!is.call(e) && !is.pairlist(e) && !is.expression(e)) return(character())
  parts <- as.list(e)
  if (is.call(e) && length(parts) == 3 &&
      (identical(parts[[1]], as.name("$")) || identical(parts[[1]], as.name("@")))) {
    parts <- parts[1:2]
  }
  unlist(lapply(parts, function(p) if (missing(p)) character() else symbols_read(p)), use.names = FALSE)
}
