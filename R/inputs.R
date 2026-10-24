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
#' something else in the cell reads or redefines the name (shown as a
#' read-only line, "Read `n` in another cell"). Empty for code that doesn't
#' parse or names no input function.
input_bindings <- function(code) {
  none <- list(bind = list(), blocked = list())
  # Most cells have no input; skip the parse for them, since this runs for
  # every cell sent to the worker.
  if (!grepl("input_", code, fixed = TRUE)) return(none)
  exprs <- tryCatch(parse(text = code, keep.source = TRUE), error = function(e) NULL)
  if (length(exprs) == 0) return(none)
  targets <- vapply(exprs, function(e) input_assignment(e) %||% NA_character_, character(1))
  if (all(is.na(targets))) return(none)
  srcrefs <- attr(exprs, "srcref")
  # What each top-level expression reads or defines, by the same analysis
  # the graph uses, each read alone: a read of `n` that would give another
  # cell an edge to the input's cell (`get("n")`, a glue template) blocks
  # the binding too.
  touched <- lapply(seq_along(exprs), function(i) {
    expression_names(paste(as.character(srcrefs[[i]]), collapse = "\n"))
  })
  out <- none
  for (k in which(!is.na(targets))) {
    name <- targets[[k]]
    rhs <- paste(deparse(exprs[[k]][[3]]), collapse = "\n")
    blocked <- name %in% unlist(touched[-k], use.names = FALSE) ||
      name %in% references_of(read_cell(rhs))
    slot <- if (blocked) "blocked" else "bind"
    out[[slot]][[length(out[[slot]]) + 1L]] <- list(name = name, index = k)
  }
  out
}

#' The names `text` (one top-level expression) reads or defines, as
#' `read_cell()` finds them.
expression_names <- function(text) {
  a <- read_cell(text)
  c(references_of(a), definitions_of(a))
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

# ---- On the page ------------------------------------------------------------------
#
# A dropdown's or radio's value goes to the page as the 0-based position of
# its choice (a list of them for a multiple dropdown), since a choice may be
# any R object; every other input's value goes as it is. The page sends
# values back the same way (`input_from_page()`).

#' Where `x` is in `choices` (1-based), or NA: emberui's `choice_index()`,
#' which the worker's check uses, so a value the worker accepted is found.
input_choice_index <- function(choices, x) {
  x <- unname(x)
  plain <- function(v) is.numeric(v) && is.null(attr(v, "class"))
  for (i in seq_along(choices)) {
    ch <- unname(choices[[i]])
    if (identical(ch, x)) return(i)
    if (plain(ch) && plain(x) && length(ch) == length(x) && length(x) > 0 && isTRUE(all(ch == x))) return(i)
  }
  NA_integer_
}

#' An input's R value as the page shows it, or `NULL` when a choice can't
#' be found (the page then shows none picked).
input_to_page <- function(spec, value) {
  if (!(spec$type %in% c("select", "radio"))) return(value)
  if (isTRUE(spec$multiple)) {
    items <- if (is.list(value)) value else as.list(value)
    idx <- vapply(items, function(v) input_choice_index(spec$choices, v), integer(1))
    return(as_arr(idx[!is.na(idx)] - 1L))
  }
  i <- input_choice_index(spec$choices, value)
  if (is.na(i)) NULL else i - 1L
}

#' The page's value for an input as the R value to set, or a refusal (one
#' sentence) for a position that isn't a choice. Everything else is left
#' to the worker's check, which says what the input allows.
input_from_page <- function(spec, v) {
  if (!(spec$type %in% c("select", "radio"))) {
    return(if (is.list(v)) unlist(v) else v)
  }
  idx <- unlist(v, use.names = FALSE) %||% integer()
  n <- length(spec$choices)
  if (!is.numeric(idx) || anyNA(idx) || any(idx != round(idx)) || any(idx < 0 | idx >= n) ||
      (!isTRUE(spec$multiple) && length(idx) != 1)) {
    return(structure("That isn't one of the input's choices.", class = "ember_page_refusal"))
  }
  i <- as.integer(idx) + 1L
  if (isTRUE(spec$multiple)) unname(spec$choices[i]) else spec$choices[[i]]
}

#' The value the page shows for each bound input, as Pluto's `bonds`:
#' `name -> list(value)`. A value waiting to be sent, else the one with the
#' worker, else the cell's: the page's own latest value, so its widget
#' doesn't snap back while the worker catches up. When the worker refused
#' the page's last value for the name, the entry also has `error`, its
#' message (`state$input_errors`), which the widget shows; `set_bond`
#' replaces the entry with `{value}`, so a new value clears it on the page
#' at once.
project_bonds <- function(state) {
  out <- emptymap()
  w <- state$worker
  for (r in state$results) {
    for (i in r$inputs) {
      if (!isTRUE(i$bound) || is.null(i$name)) next
      value <- if (!is.null(w$next_inputs[[i$name]])) w$next_inputs[[i$name]]$value
               else if (identical(w$input$name, i$name)) w$input$value
               else i$value
      out[[i$name]] <- c(list(value = input_to_page(i$spec, value)),
                         if (!is.null(state$input_errors[[i$name]])) list(error = state$input_errors[[i$name]]))
    }
  }
  out
}

#' A cell's inputs as the page draws them (`cell_results[id].ember.inputs`),
#' in the order the cell called them. `output`: the bound input on the
#' cell's last line, drawn as its widget in the cell's output area; the
#' others are read-only lines below the cell. `disabled` while the cell is stale,
#' edited since it ran, queued or running: a value checked against an old
#' spec must not reach the worker (`reduce_set_input()`).
project_inputs <- function(view) {
  busy <- isTRUE(view$stale) || isTRUE(view$code_differs) || isTRUE(view$queued) || isTRUE(view$running)
  as_arr(lapply(view$inputs, function(i) {
    s <- i$spec
    na_null <- function(x) if (is.null(x) || (length(x) == 1 && is.na(x))) NULL else x
    c(list(type = s$type, name = i$name, label = s[["label"]] %||% i$name,
           bound = isTRUE(i$bound), output = isTRUE(i$output)),
      if (!isTRUE(i$bound)) list(reason = i$reason %||% "not_assigned"),
      list(value = input_to_page(s, i$value), default = input_to_page(s, i$default),
           changed = !identical(i$value, i$default),
           disabled = busy || !isTRUE(i$bound)),
      if (s$type %in% c("slider", "number"))
        c(Filter(Negate(is.null), list(min = na_null(s$min), max = na_null(s$max), step = na_null(s$step))),
          list(integer = is.integer(s$value))),
      if (s$type %in% c("select", "radio")) list(labels = as_arr(s$labels %||% character())),
      if (identical(s$type, "select")) list(multiple = isTRUE(s$multiple)))
  }))
}
