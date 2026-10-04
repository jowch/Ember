# Package calls (library/box/qualified calls), source() following,
# data()/assign(), glue and str_interp interpolation, get-family literal
# names, and quoting calls.

#' `library(x)`, `require("x")`, `pacman::p_load(a, b)`, `requireNamespace`.
#'
#' The package name is the first argument (or `package =`), as a symbol or
#' string; `p_load` takes every unnamed argument. With `character.only =
#' TRUE`, or a non-literal argument, the cell gets a `computed_package`
#' note. Other arguments are walked as code.
walk_package_call <- function(e, scope, acc, attached, name, arg_pids = NULL) {
  args <- as.list(e)[-1]
  if (is.null(arg_pids)) arg_pids <- rep(list(NA_integer_), length(args))
  if (identical(name, "p_load")) {
    walk_attach_args(e, scope, acc, arg_pids)
    return(invisible())
  }

  nms <- names2(args)

  pkg_idx <- NA_integer_
  if ("package" %in% nms) {
    pkg_idx <- which(nms == "package")[1]
  } else {
    unnamed <- which(nms == "")
    if (length(unnamed) >= 1) pkg_idx <- unnamed[1]
  }

  char_only <- FALSE
  co_idx <- which(nms == "character.only")
  if (length(co_idx) >= 1) {
    v <- args[[co_idx[1]]]
    char_only <- is.logical(v) && isTRUE(v)
  }

  if (!is.na(pkg_idx)) {
    if (char_only) {
      record_note(acc, "computed_package", name, pd_position(acc, arg_pids[[pkg_idx]]))
    } else {
      pkgname <- literal_package_name(args[[pkg_idx]])
      if (!is.null(pkgname)) {
        record_package(acc, pkgname, attached = attached)
      } else {
        record_note(acc, "computed_package", name, pd_position(acc, arg_pids[[pkg_idx]]))
      }
    }
  }

  for (i in seq_along(args)) {
    if (!is.na(pkg_idx) && i == pkg_idx) next
    if (missing_arg(args[[i]])) next
    walk_expr(args[[i]], scope, acc, arg_pids[[i]])
  }
}

#' Every unnamed argument of `p_load(a, b)` is a package to attach.
walk_attach_args <- function(e, scope, acc, arg_pids = NULL) {
  args <- as.list(e)[-1]
  if (is.null(arg_pids)) arg_pids <- rep(list(NA_integer_), length(args))
  for (i in seq_along(args)) {
    a <- args[[i]]
    if (missing_arg(a)) next
    pkgname <- literal_package_name(a)
    if (!is.null(pkgname)) {
      record_package(acc, pkgname, attached = TRUE)
    } else {
      walk_expr(a, scope, acc, arg_pids[[i]])
    }
  }
}

#' `quote(x)`, `substitute(expr, env)`, `expression(...)`, `alist(...)`.
#'
#' Every argument is quoted code except `substitute()`'s second argument
#' (`env`, its lookup environment): that one argument is evaluated by R, so
#' it is walked as ordinary code like any other call argument
#' (`substitute(f(), list(f = my_fn))` references `list` and `my_fn`, not
#' `f`).
walk_quoting_call <- function(e, scope, acc, name, arg_pids = NULL) {
  if (!identical(name, "substitute")) return(invisible())
  args <- as.list(e)[-1]
  if (is.null(arg_pids)) arg_pids <- rep(list(NA_integer_), length(args))
  if (length(args) <= 1) return(invisible())
  for (i in 2:length(args)) {
    a <- args[[i]]
    if (missing_arg(a)) next
    walk_expr(a, scope, acc, arg_pids[[i]])
  }
  invisible()
}

#' `glue()`, `glue::glue()`, `glue_data()`, `str_glue()`,
#' `stringr::str_glue()`, and cli's `cli_*` message functions: every
#' string-literal argument is a glue template, its `"{...}"` segments
#' interpolated at run time from the calling environment. Each segment is
#' parsed and walked as code, so a cell that only uses another cell's
#' variable inside such a string still gets the edge (cell-graph.md's glue
#' design gap); an unparsable segment is ignored, same as "never errors on
#' bad code" for the rest of the walker.
#'
#' `.open`/`.close` change the delimiters when given as a literal
#' single-character string; any other dot-prefixed named argument (`.sep`,
#' `.envir`, ...) is a glue setting, not a template, and is walked as
#' ordinary code instead of scanned. `glue_data()`'s first argument (`.x`,
#' named or positional) is the data to interpolate from, not a template.
#'
#' Positions: a name found inside one string literal's segments is
#' reported at that string's own token position (`arg_pids[[i]]`), not a
#' position within it -- the segment is reparsed from a bare substring with
#' no coordinates of its own in the enclosing file. This is exact for the
#' common case, a bare `{name}` segment: `walk_expr()`'s symbol branch uses
#' `str_pid` directly with no decomposition needed. A segment that is
#' itself a call (`{f(x)}`) tries to decompose `str_pid` as if it were that
#' call's own node, finds no children under a string-literal leaf, and
#' falls back to `NA` like any other unmatched shape (see "Exact
#' positions" above) -- for the whole call, `f` included, not just `x`.
walk_glue_call <- function(e, scope, acc, name, arg_pids = NULL) {
  args <- as.list(e)[-1]
  if (is.null(arg_pids)) arg_pids <- rep(list(NA_integer_), length(args))
  nms <- names2(args)

  open <- glue_delim(args, nms, ".open", "{")
  close <- glue_delim(args, nms, ".close", "}")

  data_idx <- NA_integer_
  if (identical(name, "glue_data")) {
    if (".x" %in% nms) {
      data_idx <- which(nms == ".x")[1]
    } else {
      unnamed <- which(nms == "")
      if (length(unnamed) >= 1) data_idx <- unnamed[1]
    }
  }

  for (i in seq_along(args)) {
    a <- args[[i]]
    if (missing_arg(a)) next
    is_data <- !is.na(data_idx) && i == data_idx
    is_setting <- nzchar(nms[i]) && startsWith(nms[i], ".")
    if (!is_data && !is_setting && is.character(a) && length(a) == 1) {
      str_pid <- arg_pids[[i]]
      for (seg in glue_segments(a, open, close)) {
        parsed <- tryCatch(parse(text = seg), error = function(e) NULL)
        if (is.null(parsed)) next
        for (k in seq_along(parsed)) walk_expr(parsed[[k]], scope, acc, str_pid)
      }
    } else {
      walk_expr(a, scope, acc, arg_pids[[i]])
    }
  }
}

#' A literal `.open`/`.close` argument's value, or `default` when it isn't
#' given or isn't a literal non-empty string (a computed delimiter is left
#' at the default, best effort). glue's delimiters can be more than one
#' character (`.open = "<<"`).
glue_delim <- function(args, nms, argname, default) {
  idx <- which(nms == argname)
  if (length(idx) == 0) return(default)
  v <- args[[idx[1]]]
  if (is.character(v) && length(v) == 1 && !is.na(v) && nchar(v) >= 1) v else default
}

#' The code inside each `"{...}"` segment of a glue template, as character
#' strings to be parsed. A doubled delimiter (`{{`/`}}`) escapes a literal
#' brace outside a segment; nested delimiters inside a segment (rare, but
#' `{if (x) 1 else 2}` style expressions can contain them) extend it rather
#' than closing it early. `open`/`close` may be more than one character
#' (a literal `.open`/`.close` argument).
glue_segments <- function(s, open = "{", close = "}") {
  n <- nchar(s)
  ol <- nchar(open)
  cl <- nchar(close)
  segs <- character()
  depth <- 0L
  buf_start <- NA_integer_
  i <- 1L
  starts_with <- function(pos, needle, needle_len) {
    pos + needle_len - 1L <= n && identical(substr(s, pos, pos + needle_len - 1L), needle)
  }
  while (i <= n) {
    if (depth == 0L) {
      if (starts_with(i, open, ol) && starts_with(i + ol, open, ol)) {
        i <- i + 2L * ol
      } else if (starts_with(i, close, cl) && starts_with(i + cl, close, cl)) {
        i <- i + 2L * cl
      } else if (starts_with(i, open, ol)) {
        depth <- 1L
        buf_start <- i + ol
        i <- i + ol
      } else {
        i <- i + 1L
      }
    } else {
      if (starts_with(i, close, cl)) {
        depth <- depth - 1L
        if (depth == 0L) {
          segs <- c(segs, substr(s, buf_start, i - 1L))
          i <- i + cl
        } else {
          i <- i + cl
        }
      } else if (starts_with(i, open, ol)) {
        depth <- depth + 1L
        i <- i + ol
      } else {
        i <- i + 1L
      }
    }
  }
  segs
}

#' `str_interp()`/`stringr::str_interp()`: the `string` argument (first
#' positional, or named `string`) is a template whose `${expr}` and
#' `$[fmt]{expr}` segments are parsed and walked as code, same design as
#' `walk_glue_call()` -- a cell that only uses another cell's variable
#' inside the template still gets the edge. The second argument, `env`
#' (named, or the second positional), is ordinary code: str_interp()'s
#' interpolation only ever touches its `string` argument.
walk_str_interp_call <- function(e, scope, acc, name, arg_pids = NULL) {
  args <- as.list(e)[-1]
  if (is.null(arg_pids)) arg_pids <- rep(list(NA_integer_), length(args))
  nms <- names2(args)

  string_idx <- NA_integer_
  if ("string" %in% nms) {
    string_idx <- which(nms == "string")[1]
  } else {
    unnamed <- which(nms == "")
    if (length(unnamed) >= 1) string_idx <- unnamed[1]
  }

  for (i in seq_along(args)) {
    a <- args[[i]]
    if (missing_arg(a)) next
    is_string <- !is.na(string_idx) && i == string_idx
    if (is_string && is.character(a) && length(a) == 1) {
      str_pid <- arg_pids[[i]]
      for (seg in str_interp_segments(a)) {
        parsed <- tryCatch(parse(text = seg), error = function(e) NULL)
        if (is.null(parsed)) next
        for (k in seq_along(parsed)) walk_expr(parsed[[k]], scope, acc, str_pid)
      }
    } else {
      walk_expr(a, scope, acc, arg_pids[[i]])
    }
  }
}

#' The code inside each `${...}` / `$[fmt]{...}` segment of a `str_interp`
#' template, as character strings to be parsed. `$[fmt]` carries a sprintf
#' conversion spec (`.2f`) that isn't code and is discarded; only the
#' `{...}` body is returned, brace-balanced so a nested `{` in the
#' expression (`${if (x) 1 else 2}`'s own braces, if any) doesn't close the
#' segment early. A `$` not followed by `{` or by a well-formed `[...]{`
#' is a plain character, not a template start, and malformed syntax (no
#' closing `}`, no `{` after `[...]`) stops scanning that `$` and falls
#' back to treating it as literal -- never an error, same as the rest of
#' the walker.
str_interp_segments <- function(s) {
  n <- nchar(s)
  segs <- character()
  find_close_brace <- function(start) {
    depth <- 1L
    j <- start
    while (j <= n) {
      ch <- substr(s, j, j)
      if (identical(ch, "{")) {
        depth <- depth + 1L
      } else if (identical(ch, "}")) {
        depth <- depth - 1L
        if (depth == 0L) return(j)
      }
      j <- j + 1L
    }
    NA_integer_
  }
  i <- 1L
  while (i <= n) {
    if (identical(substr(s, i, i), "$") && i < n) {
      nxt <- substr(s, i + 1L, i + 1L)
      if (identical(nxt, "{")) {
        close <- find_close_brace(i + 2L)
        if (!is.na(close)) {
          segs <- c(segs, substr(s, i + 2L, close - 1L))
          i <- close + 1L
          next
        }
      } else if (identical(nxt, "[")) {
        bracket_pos <- regexpr("]", substr(s, i + 2L, n), fixed = TRUE)[1]
        if (bracket_pos != -1) {
          close_bracket <- i + 1L + bracket_pos
          if (close_bracket < n && identical(substr(s, close_bracket + 1L, close_bracket + 1L), "{")) {
            close <- find_close_brace(close_bracket + 2L)
            if (!is.na(close)) {
              segs <- c(segs, substr(s, close_bracket + 2L, close - 1L))
              i <- close + 1L
              next
            }
          }
        }
      }
    }
    i <- i + 1L
  }
  segs
}

#' `get(x)`, `get0(x)`, `exists(x)`, `dynGet(x)` and `mget(x)`: when `x`
#' (the first argument, or named `x`) is a string literal -- or, for
#' `mget`, a `c("a", "b")` of literals -- and no `envir`/`pos` argument is
#' given, and `inherits` isn't literally `FALSE`, each name is recorded as
#' a reference and the `untracked_read` note is dropped: the cell no
#' longer reads untrackably, it reads specific globals (`exists()` counts
#' too, even though it only tests presence, not value: whether the name
#' exists still depends on the defining cell having run). Anything else
#' (a computed name, or an `envir`/`pos`/`inherits = FALSE` argument)
#' leaves the call exactly as before: the `untracked_read` note, and its
#' arguments walked as ordinary code.
walk_get_family_call <- function(e, scope, acc, name, arg_pids = NULL, head_pos = function() NULL) {
  args <- as.list(e)[-1]
  if (is.null(arg_pids)) arg_pids <- rep(list(NA_integer_), length(args))
  nms <- names2(args)

  disqualified <- any(nms %in% c("envir", "pos"))
  if (!disqualified && "inherits" %in% nms) {
    v <- args[[which(nms == "inherits")[1]]]
    if (is.logical(v) && length(v) == 1 && !is.na(v) && !isTRUE(v)) disqualified <- TRUE
  }

  x_idx <- NA_integer_
  if ("x" %in% nms) {
    x_idx <- which(nms == "x")[1]
  } else {
    unnamed <- which(nms == "")
    if (length(unnamed) >= 1) x_idx <- unnamed[1]
  }

  resolved <- NULL
  if (!disqualified && !is.na(x_idx) && !missing_arg(args[[x_idx]])) {
    resolved <- get_family_literal_names(args[[x_idx]])
  }

  if (is.null(resolved)) {
    record_note(acc, "untracked_read", name, head_pos())
  } else {
    x_pos <- pd_position(acc, arg_pids[[x_idx]])
    for (nm in resolved) record_read(acc, scope, nm, pos = x_pos)
  }

  for (i in seq_along(args)) {
    a <- args[[i]]
    if (missing_arg(a)) next
    if (!is.null(resolved) && !is.na(x_idx) && i == x_idx) next
    walk_expr(a, scope, acc, arg_pids[[i]])
  }
}

#' The literal name(s) in a get-family call's `x` argument: the string
#' itself, or, for `mget(c("a", "b"))`, every element of a `c(...)` call
#' whose arguments are all string literals. `NULL` when `x` isn't one of
#' these shapes (a variable, a computed name, a mixed `c(...)`).
get_family_literal_names <- function(a) {
  if (is.character(a) && length(a) == 1 && !is.na(a)) return(a)
  if (is.call(a) && is.symbol(a[[1]]) && identical(as.character(a[[1]]), "c")) {
    subs <- as.list(a)[-1]
    if (length(subs) == 0) return(NULL)
    out <- character(length(subs))
    for (i in seq_along(subs)) {
      s <- subs[[i]]
      if (missing_arg(s) || !is.character(s) || length(s) != 1 || is.na(s)) return(NULL)
      out[i] <- s
    }
    return(out)
  }
  NULL
}

#' `box::use(dplyr[mutate, filter], ./helpers)`. Best-effort: a bare or
#' bracketed package argument attaches the package (and, for `[...]`, binds
#' the selected names as `"alias"` definitions at top scope); a module path
#' argument (`./helpers`) is left untouched, since it names a file, not a
#' package.
walk_box_use_args <- function(e, scope, acc, arg_pids = NULL) {
  args <- as.list(e)[-1]
  if (is.null(arg_pids)) arg_pids <- rep(list(NA_integer_), length(args))
  for (i in seq_along(args)) {
    a <- args[[i]]
    if (missing_arg(a)) next
    if (is.symbol(a)) {
      record_package(acc, as.character(a), attached = TRUE)
    } else if (is.call(a) && is.symbol(a[[1]]) && identical(as.character(a[[1]]), "[")) {
      aparts <- pd_call_parts(acc$pd, a, arg_pids[[i]])
      pkg_expr <- a[[2]]
      if (is.symbol(pkg_expr)) {
        record_package(acc, as.character(pkg_expr), attached = TRUE)
      }
      sels <- as.list(a)[-(1:2)]
      for (j in seq_along(sels)) {
        sel <- sels[[j]]
        if (missing_arg(sel)) next
        if (is.symbol(sel)) {
          record_definition(acc, scope, as.character(sel), "alias",
                            pd_position(acc, safe_pid(aparts$args, j + 1)))
        }
      }
    }
  }
}

literal_package_name <- function(a) {
  if (is.symbol(a)) return(as.character(a))
  if (is.character(a) && length(a) == 1) return(a)
  NULL
}

#' `assign("x", v)` and `data(iris)` at top scope (or `local()` nested
#' there; see `dispatch_call_by_name()`).
#'
#' `data()` only defines the datasets named by its unnamed arguments
#' (symbols or strings) and the `list = c(...)` literal vector: a named
#' argument such as `package =`, `envir =`, or `lib.loc =` is code, not a
#' dataset name, and is walked like any other argument
#' (`data(iris, envir = e)` defines `iris` and reads `e`).
walk_literal_definer <- function(e, scope, acc, name, arg_pids = NULL) {
  args <- as.list(e)[-1]
  if (is.null(arg_pids)) arg_pids <- rep(list(NA_integer_), length(args))
  nms <- names2(args)
  if (identical(name, "assign")) {
    if (length(args) >= 1 && !missing_arg(args[[1]]) &&
        is.character(args[[1]]) && length(args[[1]]) == 1 &&
        !any(nms %in% c("envir", "pos"))) {
      record_top_level_definition(acc, scope, args[[1]], "call", pd_position(acc, arg_pids[[1]]))
    }
    for (i in seq_along(args)) {
      a <- args[[i]]
      if (missing_arg(a)) next
      walk_expr(a, scope, acc, arg_pids[[i]])
    }
  } else if (identical(name, "data")) {
    for (i in seq_along(args)) {
      a <- args[[i]]
      if (missing_arg(a)) next
      if (identical(nms[i], "list")) {
        if (is.call(a) && is.symbol(a[[1]]) && identical(as.character(a[[1]]), "c")) {
          lparts <- pd_call_parts(acc$pd, a, arg_pids[[i]])
          subs <- as.list(a)[-1]
          for (j in seq_along(subs)) {
            sub <- subs[[j]]
            if (missing_arg(sub)) next
            pkgname <- literal_package_name(sub)
            if (!is.null(pkgname)) {
              record_top_level_definition(acc, scope, pkgname, "call",
                                          pd_position(acc, safe_pid(lparts$args, j)))
            }
          }
        } else {
          walk_expr(a, scope, acc, arg_pids[[i]])
        }
      } else if (identical(nms[i], "")) {
        pkgname <- literal_package_name(a)
        if (!is.null(pkgname)) {
          record_top_level_definition(acc, scope, pkgname, "call", pd_position(acc, arg_pids[[i]]))
        } else {
          walk_expr(a, scope, acc, arg_pids[[i]])
        }
      } else {
        walk_expr(a, scope, acc, arg_pids[[i]])
      }
    }
  }
}

#' `source("p.R")` at top scope (or `local()` nested there).
walk_source <- function(e, scope, acc, arg_pids = NULL) {
  args <- as.list(e)[-1]
  if (is.null(arg_pids)) arg_pids <- rep(list(NA_integer_), length(args))
  nms <- names2(args)

  path_idx <- NA_integer_
  if ("file" %in% nms) {
    path_idx <- which(nms == "file")[1]
  } else {
    unnamed <- which(nms == "")
    if (length(unnamed) >= 1) path_idx <- unnamed[1]
  }
  if (is.na(path_idx) || missing_arg(args[[path_idx]])) {
    for (i in seq_along(args)) {
      if (missing_arg(args[[i]])) next
      walk_expr(args[[i]], scope, acc, arg_pids[[i]])
    }
    return(invisible())
  }

  path_expr <- args[[path_idx]]
  local_idx <- which(nms == "local")
  local_val <- if (length(local_idx) >= 1 && !missing_arg(args[[local_idx[1]]])) {
    args[[local_idx[1]]]
  } else {
    NULL
  }
  # `local = TRUE` or `local = <env>` evaluates the file somewhere other
  # than the global environment, so its definitions don't escape to the
  # cell; only an explicit `local = FALSE` (or no `local` argument at all,
  # the default) writes globally and is worth following.
  private_env <- !is.null(local_val) &&
    !(is.logical(local_val) && identical(local_val, FALSE))

  if (!(is.character(path_expr) && length(path_expr) == 1) || private_env) {
    record_note(acc, "computed_source", "source", pd_position(acc, arg_pids[[path_idx]]))
    for (i in seq_along(args)) {
      if (missing_arg(args[[i]])) next
      walk_expr(args[[i]], scope, acc, arg_pids[[i]])
    }
    return(invisible())
  }

  path <- path_expr
  for (i in seq_along(args)) {
    if (missing_arg(args[[i]])) next
    walk_expr(args[[i]], scope, acc, arg_pids[[i]])
  }

  if (path %in% acc$stack) return(invisible())

  text <- if (is.null(acc$read_file)) NULL else acc$read_file(path)
  if (is.null(text)) {
    acc$sourced_rows[[length(acc$sourced_rows) + 1]] <-
      list(path = path, text = NA_character_, found = FALSE)
    record_note(acc, "missing_file", path)
    return(invisible())
  }

  acc$sourced_rows[[length(acc$sourced_rows) + 1]] <-
    list(path = path, text = text, found = TRUE)
  sub <- read_cell_in(text, acc$read_file, file = path, stack = c(acc$stack, path))
  if (!is.null(sub$parse_error)) {
    record_note(acc, "source_parse_error", sub$parse_error$message)
    return(invisible())
  }

  acc$extra_defs[[length(acc$extra_defs) + 1]] <- sub$definitions
  acc$extra_refs[[length(acc$extra_refs) + 1]] <- sub$references
  acc$extra_pkgs[[length(acc$extra_pkgs) + 1]] <- sub$packages
  acc$extra_settings[[length(acc$extra_settings) + 1]] <- sub$settings
  acc$formulas <- c(acc$formulas, sub$formulas)
  acc$extra_sourced[[length(acc$extra_sourced) + 1]] <- sub$sourced
  acc$extra_notes[[length(acc$extra_notes) + 1]] <- sub$notes
  if (nrow(sub$definitions) > 0) {
    bind_names(scope, sub$definitions$name)
  }
  invisible()
}

names2 <- function(x) {
  n <- names(x)
  if (is.null(n)) rep("", length(x)) else ifelse(is.na(n), "", n)
}
