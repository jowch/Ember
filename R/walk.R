# walk_expr dispatch and the core language constructs it doesn't hand off
# elsewhere: assignment and replacement targets, function/local/if/for, and
# the generic call-argument walk.

# ---- Walking ---------------------------------------------------------------

#' Walk one expression in a scope.
#'
#' `pid` is the parse-data id of `e` itself (see "Exact positions" at the
#' top of this file), or `NA_integer_` when it's unknown; every branch that
#' recurses into a piece of `e` first works out that piece's own pid, via
#' `pd_call_parts()`/`pd_arg_only()` (or a dedicated decomposition for a
#' special form neither handles, e.g. `for`), and passes it down -- falling
#' back to `NA` wherever the shapes don't line up.
#'
#' Dispatches on the call head. `walk_call_args` handles the generic case
#' (an ordinary call): it never reads the head itself, only decides which
#' arguments are formulas and walks the rest as code, so every special-cased
#' head below is responsible for its own head handling.
walk_expr <- function(e, scope, acc, pid = NA_integer_) {
  if (is.symbol(e)) {
    name <- as.character(e)
    if (nzchar(name)) record_read(acc, scope, name, pos = pd_position(acc, pid))
    return(invisible())
  }
  if (!is.call(e)) return(invisible())

  head <- e[[1]]
  if (is.call(head)) {
    q <- qualified_head(head)
    if (!is.null(q)) {
      walk_qualified_call(e, scope, acc, q, pid)
    } else {
      parts <- pd_call_parts(acc$pd, e, pid)
      walk_expr(head, scope, acc, parts$head)
      walk_call_args(e, scope, acc, parts$args)
    }
    return(invisible())
  }
  if (!is.symbol(head)) {
    parts <- pd_call_parts(acc$pd, e, pid)
    walk_call_args(e, scope, acc, parts$args)
    return(invisible())
  }

  name <- as.character(head)
  switch(name,
    "function" = ,
    "\\" = { walk_function(e, scope, acc, pid); return(invisible()) },
    "for" = { walk_for(e, scope, acc, pid); return(invisible()) },
    "if" = { walk_if(e, scope, acc, pid); return(invisible()) },
    "while" = ,
    "repeat" = ,
    "{" = ,
    "(" = {
      arg_pids <- pd_arg_only(acc$pd, e, pid)
      subs <- as.list(e)[-1]
      for (i in seq_along(subs)) walk_expr(subs[[i]], scope, acc, arg_pids[[i]])
      return(invisible())
    },
    "local" = {
      parts <- pd_call_parts(acc$pd, e, pid)
      record_read(acc, scope, "local", pos = pd_position(acc, parts$head))
      walk_local(e, scope, acc, parts$args)
      return(invisible())
    },
    "::" = ,
    ":::" = {
      record_package(acc, as.character(e[[2]]), attached = FALSE)
      return(invisible())
    },
    "$" = ,
    "@" = {
      parts <- pd_call_parts(acc$pd, e, pid)
      walk_expr(e[[2]], scope, acc, safe_pid(parts$args, 1))
      return(invisible())
    },
    "~" = { walk_formula(e, scope, acc, has_data = FALSE, pid = pid); return(invisible()) }
  )

  dispatch_call_by_name(e, scope, acc, name, pid = pid)
}

#' `pkg::fn(...)` or `pkg:::fn(...)` used as a call head: not a plain symbol
#' head, so dispatch on a symbol head never sees it.
qualified_head <- function(head) {
  if (is.call(head) && length(head) == 3 && is.symbol(head[[1]]) &&
      as.character(head[[1]]) %in% c("::", ":::")) {
    list(pkg = as.character(head[[2]]), fn = as.character(head[[3]]))
  } else {
    NULL
  }
}

walk_qualified_call <- function(e, scope, acc, q, pid = NA_integer_) {
  if (identical(q$pkg, "pacman") && identical(q$fn, "p_load")) {
    record_package(acc, "pacman", attached = FALSE)
    parts <- pd_call_parts(acc$pd, e, pid)
    walk_attach_args(e, scope, acc, parts$args)
  } else if (identical(q$pkg, "box") && identical(q$fn, "use")) {
    record_package(acc, "box", attached = FALSE)
    parts <- pd_call_parts(acc$pd, e, pid)
    walk_box_use_args(e, scope, acc, parts$args)
  } else {
    record_package(acc, q$pkg, attached = FALSE)
    dispatch_call_by_name(e, scope, acc, q$fn, qualified = TRUE, pid = pid)
  }
}

#' Dispatch a call by its bare function name: the shared tail of
#' `walk_expr`'s symbol-head handling and `walk_qualified_call`'s fallback,
#' since rules.R's tables are written to match either form ("a call matches
#' by its head symbol or by pkg::name with the package dropped"). Only
#' called with names that aren't one of `walk_expr`'s special forms
#' (`function`, `if`, `local`, `~`, ...), which a `pkg::` head can't spell
#' anyway.
#'
#' `qualified` is `TRUE` for a `pkg::fn` head. It suppresses every branch
#' that would otherwise record `name` itself as a reference (`pkg::fn` is a
#' package use, never a reference to `fn`; the caller already recorded
#' `pkg`), and it skips the assignment-operator branch entirely (there is
#' no sensible qualified spelling of `<-`).
#'
#' `pid` is `e`'s own pid, decomposed once here into `arg_pids` (shared by
#' every branch below) and `head_pos_pid`, the position "responsible" for a
#' reference/setting/note recorded against `name`: `e`'s own head token
#' when unqualified, or -- one more decomposition step in, since `e`'s head
#' is then the call `pkg::fn` -- `fn`'s own token when qualified.
dispatch_call_by_name <- function(e, scope, acc, name, qualified = FALSE,
                                  pid = NA_integer_) {
  parts <- pd_call_parts(acc$pd, e, pid)
  arg_pids <- parts$args
  head_pos_pid <- if (qualified) {
    if (is.na(parts$head)) NA_integer_ else pd_qualified_fn_pid(acc$pd, e[[1]], parts$head)
  } else {
    parts$head
  }
  head_pos <- function() pd_position(acc, head_pos_pid)

  maybe_record_name_read <- function() {
    if (!qualified) record_read(acc, scope, name, pos = head_pos())
  }

  if (!qualified && name %in% names(assignment_ops)) {
    walk_assignment(e, scope, acc, name, pid)
    return(invisible())
  }
  if (name %in% quoting_functions) {
    maybe_record_name_read()
    walk_quoting_call(e, scope, acc, name, arg_pids)
    return(invisible())
  }
  if (is_glue_function(name)) {
    maybe_record_name_read()
    walk_glue_call(e, scope, acc, name, arg_pids)
    return(invisible())
  }
  if (name %in% attach_functions) {
    maybe_record_name_read()
    walk_package_call(e, scope, acc, attached = TRUE, name = name, arg_pids = arg_pids)
    return(invisible())
  }
  if (name %in% use_functions) {
    maybe_record_name_read()
    walk_package_call(e, scope, acc, attached = FALSE, name = name, arg_pids = arg_pids)
    return(invisible())
  }
  if (name %in% setting_functions$always || name %in% setting_functions$write_only) {
    maybe_record_name_read()
    is_write <- TRUE
    if (name %in% setting_functions$write_only) {
      args <- as.list(e)[-1]
      nms <- names2(args)
      is_write <- any(nzchar(nms))
      # An unnamed argument that isn't a bare string (`options(op)`, saved
      # options being restored) also writes; `options()` and
      # `options("digits")` are reads.
      if (!is_write) {
        for (i in seq_along(args)) {
          if (nzchar(nms[i])) next
          a <- args[[i]]
          if (missing_arg(a)) next
          if (!(is.character(a) && length(a) == 1)) {
            is_write <- TRUE
            break
          }
        }
      }
    }
    if (is_write && !in_function(scope)) record_setting(acc, name, head_pos())
    walk_call_args(e, scope, acc, arg_pids)
    return(invisible())
  }
  if (name %in% untracked_reads) {
    maybe_record_name_read()
    record_note(acc, "untracked_read", name, head_pos())
    walk_call_args(e, scope, acc, arg_pids)
    return(invisible())
  }
  if (name %in% literal_definers) {
    maybe_record_name_read()
    if (!in_function(scope)) {
      walk_literal_definer(e, scope, acc, name, arg_pids)
    } else {
      walk_call_args(e, scope, acc, arg_pids)
    }
    return(invisible())
  }
  if (identical(name, "source")) {
    maybe_record_name_read()
    if (!in_function(scope)) {
      walk_source(e, scope, acc, arg_pids)
    } else {
      walk_call_args(e, scope, acc, arg_pids)
    }
    return(invisible())
  }

  maybe_record_name_read()
  walk_call_args(e, scope, acc, arg_pids)
}

#' The bare function name behind a call head, package-qualified or not, for
#' the `formula_data_positional` lookup. `NULL` when the head isn't a named
#' function at all (`f()()`).
bare_call_name <- function(head) {
  if (is.symbol(head)) return(as.character(head))
  q <- qualified_head(head)
  if (!is.null(q)) return(q$fn)
  NULL
}

#' `function(args) body`: a new function scope.
#'
#' `names` starts as the arguments only (see the scope doc above and
#' `record_definition()`), so a name becomes
#' local exactly when the walk reaches its first assignment, in textual
#' order. That is what makes `clean <- function() { data <- na.omit(data) }`
#' read the inner `data` as a reference (walked before the assignment binds
#' it) while a later use of the same name in the body is not.
#'
#' A malformed special form (`` `function`() ``, no body) is walked as an
#' ordinary call instead of erroring: real function literals always parse
#' with a pairlist of formals in `e[[2]]` and a body in `e[[3]]`, so
#' anything else can only come from calling `` `function` `` or `` `\` ``
#' directly with the wrong arity.
#'
#' Positions: `FUNCTION`/`\` and the formals' own names carry no position
#' the walker needs (a formal is never a definitions row; see the scope
#' doc), so `pid`'s filtered children are exactly the *default* value
#' expressions, in formal order, followed by the body -- a formal with no
#' default consumes no child, since it has no expression of its own to
#' match. A child count that doesn't match the number of formals with a
#' default falls back to `NA` for every default and the body alike.
walk_function <- function(e, scope, acc, pid = NA_integer_) {
  if (length(e) < 3 || !is.pairlist(e[[2]])) {
    parts <- pd_call_parts(acc$pd, e, pid)
    walk_call_args(e, scope, acc, parts$args)
    return(invisible())
  }
  formals_pl <- e[[2]]
  body <- e[[3]]
  arg_names <- names(formals_pl)
  if (is.null(arg_names)) arg_names <- character()
  inner <- new_scope("function", unique(arg_names), parent = scope)
  inner$home <- inner
  inner$defer_target <- scope$home

  kids <- pd_child_ids(acc$pd, pid)
  n_defaults <- sum(vapply(as.list(formals_pl),
                          function(f) !identical(f, quote(expr = )), logical(1)))
  ok_shape <- length(kids) == n_defaults + 1
  kid_i <- 1L
  # Indexed directly (never through a stored variable): a formal with no
  # default is R's missing-argument sentinel, which raises "argument is
  # missing" the moment a variable holding it is read back.
  for (i in seq_along(formals_pl)) {
    if (!identical(formals_pl[[i]], quote(expr = ))) {
      dpid <- if (ok_shape) kids[kid_i] else NA_integer_
      kid_i <- kid_i + 1L
      walk_expr(formals_pl[[i]], inner, acc, dpid)
    }
  }
  body_pid <- if (ok_shape && kid_i <= length(kids)) kids[kid_i] else NA_integer_
  walk_expr(body, inner, acc, body_pid)
  finish_function_scope(inner, acc)
}

#' Resolve a function (or lambda) scope's deferred reads -- reads that
#' escaped a function nested *inside* `inner`, queued here by
#' `record_read()` via that nested function's own `defer_target` -- against
#' `inner`'s own locals now that its whole body has been walked. Whatever
#' isn't one of `inner`'s own names bubbles further to `inner$defer_target`
#' (the enclosing function's own `deferred` list), or to the cell's own
#' top-level `acc$deferred` when there is none, resolved there against the
#' whole cell's top-level definitions in `finish()`.
finish_function_scope <- function(inner, acc) {
  unresolved <- Filter(function(d) !(d$name %in% inner$names), inner$deferred)
  if (length(unresolved) == 0) return(invisible())
  target <- inner$defer_target
  if (!is.null(target)) {
    target$deferred <- c(target$deferred, unresolved)
  } else {
    acc$deferred <- c(acc$deferred, unresolved)
  }
  invisible()
}

#' `local(expr)`: a new local scope.
#'
#' Definitions inside are private to the block. Settings calls, `source()`
#' and `data()` inside still count as reached from the top level (their
#' effect, or their following, is global) no matter how many `local()`s
#' they're nested in: gated on `!in_function(scope)`, not on the scope
#' being literally `"top"`. A `local(expr, envir = e)` form is treated the
#' same; the design accepts the extra edge.
walk_local <- function(e, scope, acc, arg_pids = NULL) {
  args <- as.list(e)[-1]
  if (length(args) == 0) return(invisible())
  if (is.null(arg_pids)) arg_pids <- rep(list(NA_integer_), length(args))
  local_scope <- new_scope("local", character(), parent = scope,
                            home = scope$home, defer_target = scope$defer_target)
  walk_expr(args[[1]], local_scope, acc, arg_pids[[1]])
  if (length(args) > 1) {
    for (i in 2:length(args)) walk_expr(args[[i]], scope, acc, arg_pids[[i]])
  }
}

#' `for (var in seq) body`: `var` is bound before `body` is walked.
#'
#' A malformed special form (`` `for`(i) ``, missing the sequence and body)
#' is walked as an ordinary call instead of erroring: a real `for` always
#' parses with 3 arguments.
#'
#' Positions: `for`'s grammar wraps the header in its own "forcond" node
#' (`(var IN seq)`) rather than laying `var`/`seq` alongside the body as
#' direct children, so this decomposes it in the two steps that shape
#' implies (unlike `if`, whose branches sit directly under the `if` node)
#' instead of going through `pd_call_parts()`, which doesn't expect an
#' intermediate node here. `var` is a bare token (like `$`'s field), not an
#' "expr" of its own.
walk_for <- function(e, scope, acc, pid = NA_integer_) {
  if (length(e) < 4 || !is.symbol(e[[2]])) {
    parts <- pd_call_parts(acc$pd, e, pid)
    walk_call_args(e, scope, acc, parts$args)
    return(invisible())
  }
  var <- as.character(e[[2]])
  outer_kids <- pd_child_ids(acc$pd, pid)
  var_pid <- NA_integer_
  seq_pid <- NA_integer_
  body_pid <- NA_integer_
  if (length(outer_kids) == 2) {
    body_pid <- outer_kids[2]
    cond_kids <- pd_child_ids(acc$pd, outer_kids[1])
    if (length(cond_kids) == 2) {
      var_pid <- cond_kids[1]
      seq_pid <- cond_kids[2]
    }
  }
  walk_expr(e[[3]], scope, acc, seq_pid)
  record_definition(acc, scope, var, "for", pd_position(acc, var_pid))
  walk_expr(e[[4]], scope, acc, body_pid)
}

#' `if (cond) then [else else_]`: the two arms are walked independently (one
#' arm must not see the other's definitions, since only one ever runs), then
#' whatever either arm defined becomes visible to what follows, in every
#' scope kind (function scopes included, per the order-aware rule: textual
#' order across branches, not real control-flow analysis).
#'
#' A malformed special form (`` `if`() ``, missing the condition and `then`
#' branch) is walked as an ordinary call instead of erroring: a real `if`
#' always parses with at least 2 arguments.
#' Positions: `if`'s condition/branches sit directly under the `if` node
#' (unlike `for`'s header), so `IF`/`ELSE`/parens filtered out leave
#' exactly 2 or 3 children in the same order as `e[[2]]`, `e[[3]]`,
#' `e[[4]]` -- no `pd_call_parts()` needed, and no bare-operator token to
#' tell apart from a leaf.
walk_if <- function(e, scope, acc, pid = NA_integer_) {
  if (length(e) < 3) {
    parts <- pd_call_parts(acc$pd, e, pid)
    walk_call_args(e, scope, acc, parts$args)
    return(invisible())
  }
  parts_e <- as.list(e)
  cond <- parts_e[[2]]
  then_branch <- parts_e[[3]]
  else_branch <- if (length(parts_e) >= 4) parts_e[[4]] else NULL

  kids <- pd_child_ids(acc$pd, pid)
  ok_shape <- length(kids) == length(parts_e) - 1
  cond_pid <- if (ok_shape) kids[1] else NA_integer_
  then_pid <- if (ok_shape) kids[2] else NA_integer_
  else_pid <- if (ok_shape && length(kids) >= 3) kids[3] else NA_integer_

  walk_expr(cond, scope, acc, cond_pid)
  base_names <- scope$names

  then_scope <- fork_scope(scope)
  walk_expr(then_branch, then_scope, acc, then_pid)
  added <- setdiff(then_scope$names, base_names)

  if (!is.null(else_branch)) {
    else_scope <- fork_scope(scope)
    walk_expr(else_branch, else_scope, acc, else_pid)
    added <- union(added, setdiff(else_scope$names, base_names))
  }

  if (length(added) > 0 && scope$kind %in% c("top", "local", "function")) {
    bind_names(scope, added)
  }
}

#' An assignment: walk the value, then define the target.
#'
#' Target forms: symbol; string (`"x" <- 1`); a replacement call
#' (`f(g(x, ...), ...) <- v`), whose target is the innermost symbol and
#' whose kind is `"replacement"`; any other target (`NULL <- 1`) is
#' ignored. In a function scope the target becomes bound from this point
#' on (order-aware: a read of the same name earlier in the body was already
#' recorded as a reference candidate before this runs). At top scope the
#' definition is appended to `scope$names` so later top-level reads of it
#' aren't references. `<<-`/`->>` at top scope (or any depth of `local()`
#' outside a function) define; in a function scope they record nothing but
#' a read. `%<>%` first records a read of the target, then defines it as
#' `"replacement"`. A replacement target at the top level also records a
#' read of the target (`df$x <- v` reads `df`), so a cell that modifies
#' another cell's object gets an edge as well as the definition error.
#' Positions: `pd_call_parts()` gives the position of `e[[2]]` and `e[[3]]`
#' directly (correcting for `->`/`->>`'s reversed grammar itself, since
#' `pid` is the position of the whole assignment however it was spelled),
#' so `target_pid`/`value_pid` below already correspond to `e[[2]]`/`e[[3]]`
#' regardless of `side`; only the raw-target/value *language objects*
#' still need `side`'s lhs/rhs swap to know which is which.
walk_assignment <- function(e, scope, acc, op, pid = NA_integer_) {
  parts <- pd_call_parts(acc$pd, e, pid)
  target_pid <- safe_pid(parts$args, 1)
  value_pid <- safe_pid(parts$args, 2)

  side <- assignment_ops[[op]]
  raw_target <- if (identical(side, "lhs")) e[[2]] else e[[3]]
  value <- if (identical(side, "lhs")) e[[3]] else e[[2]]
  raw_target_pid <- if (identical(side, "lhs")) target_pid else value_pid
  value_expr_pid <- if (identical(side, "lhs")) value_pid else target_pid

  walk_expr(value, scope, acc, value_expr_pid)

  if (identical(op, "%<>%")) {
    target_name <- extract_target_name(raw_target)
    if (is.null(target_name)) return(invisible())
    tpid <- extract_target_pid(acc$pd, raw_target, raw_target_pid)
    record_read(acc, scope, target_name, pos = pd_position(acc, tpid))
    record_definition(acc, scope, target_name, "replacement", pd_position(acc, tpid))
    return(invisible())
  }

  if (op %in% c("<<-", "->>")) {
    target_name <- extract_target_name(raw_target)
    if (is.null(target_name) || is_ignored(target_name)) return(invisible())
    tpid <- extract_target_pid(acc$pd, raw_target, raw_target_pid)
    if (in_function(scope)) {
      record_read(acc, scope, target_name, pos = pd_position(acc, tpid))
    } else {
      top <- escape_to_top(scope)
      tpos <- pd_position(acc, tpid)
      rows_push(acc$def_rows,
                list(name = target_name, line = tpos$line, col = tpos$col,
                     end_col = tpos$end_col, kind = "assign", file = acc$file))
      bind_names(top, target_name)
    }
    return(invisible())
  }

  simple_kind <- if (is_function_literal(value)) "function" else "assign"
  if (is.symbol(raw_target)) {
    record_definition(acc, scope, as.character(raw_target), simple_kind,
                      pd_position(acc, raw_target_pid))
  } else if (is.character(raw_target) && length(raw_target) == 1) {
    record_definition(acc, scope, raw_target, simple_kind, pd_position(acc, raw_target_pid))
  } else if (is.call(raw_target)) {
    target_name <- extract_target_name(raw_target)
    if (!is.null(target_name)) {
      tpid <- extract_target_pid(acc$pd, raw_target, raw_target_pid)
      walk_replacement_target(raw_target, scope, acc, raw_target_pid)
      record_read(acc, scope, target_name, pos = pd_position(acc, tpid))
      record_definition(acc, scope, target_name, "replacement", pd_position(acc, tpid))
    }
  }
  invisible()
}

#' A replacement target's own index/argument expressions are reads
#' (`i` in `names(x)[i] <- nm`), but a `$`/`@` field or slot name never is
#' (`col` in `df$col <- v`): read only down the object chain. `t` can be an
#' empty argument (`m[, 2] <- 0`'s target is `` `[`(m, , 2) ``, whose second
#' argument is the empty symbol); guarded like every other loop over call
#' arguments.
walk_replacement_target <- function(t, scope, acc, pid = NA_integer_) {
  if (missing_arg(t)) return(invisible())
  if (!is.call(t)) return(invisible())
  h <- t[[1]]
  hname <- if (is.symbol(h)) as.character(h) else NULL
  args <- as.list(t)[-1]
  parts <- pd_call_parts(acc$pd, t, pid)
  if (length(args) >= 1) walk_replacement_target(args[[1]], scope, acc, safe_pid(parts$args, 1))
  if (!is.null(hname) && hname %in% c("$", "@")) return(invisible())
  if (length(args) > 1) {
    for (i in 2:length(args)) {
      rest <- args[[i]]
      if (missing_arg(rest)) next
      walk_expr(rest, scope, acc, safe_pid(parts$args, i))
    }
  }
}

#' Is the assigned value a function literal (`function(...) ...`, `\(...)
#' ...`)? Such a target gets kind `"function"` instead of `"assign"`.
is_function_literal <- function(value) {
  is.call(value) && is.symbol(value[[1]]) &&
    as.character(value[[1]]) %in% c("function", "\\")
}

#' The innermost symbol (or string) of an assignment target: itself if it's
#' already one, else the first argument of a replacement call, recursively
#' (`names(x)[i] <- v`'s target is `` `[`(names(x), i) ``, whose first
#' argument is `names(x)`, whose first argument is `x`).
extract_target_name <- function(raw_target) {
  if (is.symbol(raw_target)) return(as.character(raw_target))
  if (is.character(raw_target) && length(raw_target) == 1) return(raw_target)
  if (is.call(raw_target) && length(raw_target) >= 2) {
    return(extract_target_name(raw_target[[2]]))
  }
  NULL
}

#' The position `extract_target_name()` settled on: the same recursion,
#' one step at a time decomposing `raw_target`'s own pid to find its first
#' argument's pid, mirroring `raw_target[[2]]`.
extract_target_pid <- function(pd, raw_target, raw_target_pid) {
  if (is.symbol(raw_target)) return(raw_target_pid)
  if (is.character(raw_target) && length(raw_target) == 1) return(raw_target_pid)
  if (is.call(raw_target) && length(raw_target) >= 2) {
    parts <- pd_call_parts(pd, raw_target, raw_target_pid)
    return(extract_target_pid(pd, raw_target[[2]], safe_pid(parts$args, 1)))
  }
  NA_integer_
}

#' Walk a call's arguments: decide which is the formula and which is the
#' data (by a named `data =` argument, or a second unnamed argument on a
#' `formula_data_positional` function), send `~` arguments to
#' `walk_formula`, everything else to `walk_expr`. Argument names are never
#' reads.
walk_call_args <- function(e, scope, acc, arg_pids = NULL) {
  head <- e[[1]]
  bare_fn <- bare_call_name(head)
  fn_display <- deparse_expr(head)
  args <- as.list(e)[-1]
  if (is.null(arg_pids)) arg_pids <- rep(list(NA_integer_), length(args))
  nms <- names2(args)

  has_data <- FALSE
  data_expr <- NULL
  if ("data" %in% nms) {
    candidate <- args[[which(nms == "data")[1]]]
    if (!missing_arg(candidate)) {
      has_data <- TRUE
      data_expr <- candidate
    }
  } else if (!is.null(bare_fn) && bare_fn %in% formula_data_positional) {
    unnamed_idx <- which(nms == "")
    if (length(unnamed_idx) >= 2) {
      candidate <- args[[unnamed_idx[2]]]
      if (!missing_arg(candidate)) {
        has_data <- TRUE
        data_expr <- candidate
      }
    }
  }
  data_text <- if (has_data) deparse_expr(data_expr) else NA_character_

  for (i in seq_along(args)) {
    a <- args[[i]]
    if (missing_arg(a)) next
    if (is.call(a) && is.symbol(a[[1]]) && identical(as.character(a[[1]]), "~")) {
      site <- formula_site(acc$index, acc$line, fn_display, data_text, character())
      walk_formula(a, scope, acc, has_data, site, arg_pids[[i]])
    } else {
      walk_expr(a, scope, acc, arg_pids[[i]])
    }
  }
}

deparse_expr <- function(x) {
  paste(deparse(x), collapse = " ")
}
