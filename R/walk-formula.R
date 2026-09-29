# Formula reading by the column rule, and the one-sided lambda path.

#' Read a formula by position.
#'
#' `has_data = FALSE`: every symbol under `~` is a reference (`where =
#' "formula"`), including call heads (`poly`, `log`).
#' `has_data = TRUE`: symbols under `formula_transparent` operators and the
#' first argument of any other call are columns (recorded in `site`);
#' further arguments are always references, never columns, regardless of
#' `has_data` (`deg` in `poly(x, deg)`, `k` in `s(x, k = k)`), and the
#' column rule applies again inside a first argument that is itself a call
#' (`n` in `offset(log(n))`). Call heads are always references. `.` is
#' never anything. A `$`/`@` term (`d$y`) is never split into head plus
#' column: it reads its object only, exactly as `$`/`@` does outside a
#' formula, regardless of `has_data`.
#'
#' Positions: `pid`'s own decomposition via `pd_call_parts()` gives the
#' `~` token itself (`parts$head`, stored on `site` when there is one) and
#' the side(s) (`parts$args`, aligned with `e`'s own `as.list(e)[-1]`);
#' `term()` carries its own pid alongside each sub-term, re-decomposing at
#' every nested call the same way the rest of the walker does.
walk_formula <- function(e, scope, acc, has_data, site = NULL, pid = NA_integer_) {
  parts <- pd_call_parts(acc$pd, e, pid)
  if (!is.null(site)) {
    tpos <- pd_position(acc, parts$head)
    site$col <- tpos$col
    site$end_col <- tpos$end_col
  }
  parts_e <- as.list(e)[-1]

  # A one-sided formula outside a model-formula context is a purrr/rlang
  # lambda (`~ .x + 1`, `~ { v <- .x * 2; v + 1 }`): rlang evaluates it as a
  # function of `.`/`.x`/`.y`, so it gets its own scope like any function
  # body instead of the column/term rules below, which is what keeps a
  # local such as `v` out of the references (`has_data` is never true for a
  # lambda: a real model formula always has two sides or a `data` argument).
  if (!has_data && length(parts_e) == 1) {
    walk_formula_lambda(parts_e[[1]], scope, acc, safe_pid(parts$args, 1))
    return(invisible())
  }

  cols <- character()

  term <- function(t, hd, tpid) {
    if (missing_arg(t)) return(invisible())
    if (is.symbol(t)) {
      nm <- as.character(t)
      if (identical(nm, ".") || !nzchar(nm)) return(invisible())
      if (hd) {
        cols <<- c(cols, nm)
      } else {
        record_read(acc, scope, nm, where = "formula", pos = pd_position(acc, tpid))
      }
      return(invisible())
    }
    if (!is.call(t)) return(invisible())
    h <- t[[1]]
    hname <- if (is.symbol(h)) as.character(h) else NULL
    tparts <- pd_call_parts(acc$pd, t, tpid)
    if (!is.null(hname) && hname %in% c("$", "@")) {
      walk_expr(t[[2]], scope, acc, safe_pid(tparts$args, 1))
      return(invisible())
    }
    if (!is.null(hname) && hname %in% formula_transparent) {
      targs <- as.list(t)[-1]
      for (i in seq_along(targs)) term(targs[[i]], hd, safe_pid(tparts$args, i))
      return(invisible())
    }
    if (!is.null(hname)) record_read(acc, scope, hname, where = "formula", pos = pd_position(acc, tparts$head))
    targs <- as.list(t)[-1]
    if (length(targs) >= 1) {
      term(targs[[1]], hd, safe_pid(tparts$args, 1))
      if (length(targs) > 1) {
        for (i in 2:length(targs)) term(targs[[i]], FALSE, safe_pid(tparts$args, i))
      }
    }
  }

  for (i in seq_along(parts_e)) term(parts_e[[i]], has_data, safe_pid(parts$args, i))

  if (has_data && length(cols) > 0 && !is.null(site)) {
    site$columns <- unique(cols)
    acc$formulas[[length(acc$formulas) + 1]] <- site
  }
}

#' A one-sided formula's right side used as a purrr/rlang lambda: walked as
#' a function body with its own scope, so a local it assigns (`~ { v <- .x
#' * 2; v + 1 }`) isn't a reference, the same as any other function body.
walk_formula_lambda <- function(body, scope, acc, pid = NA_integer_) {
  inner <- new_scope("function", character(), parent = scope)
  inner$home <- inner
  inner$defer_target <- scope$home
  walk_expr(body, inner, acc, pid)
  finish_function_scope(inner, acc)
}
