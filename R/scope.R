# Lexical scopes, the walker's mutable accumulator, and the record_*()
# functions that turn a walk step into a row on it.

# ---- Walker state ----------------------------------------------------------

#' Accumulator: a mutable environment the handlers write into.
#'
#' Internal to `read_cell`; never escapes. Holds the growing record lists
#' (one small list per row, converted to a data frame once in `finish()`
#' rather than rbound one row at a time: `rbind.data.frame` redoes type
#' checking and coercion on the whole accumulated frame on every call, which
#' made a 6000-line cell take seconds), the current top-level `index` and
#' `line`, the `read_file` function, the current `file` tag and the `stack`
#' of files being sourced. `extra_*` holds whole data frames merged in from
#' a `source()`d file (rare, one entry per `source()` call, so rbinding
#' those directly costs nothing) to keep them out of the hot per-row path.
new_accumulator <- function(read_file, file, stack) {
  acc <- new.env(parent = emptyenv())
  acc$read_file <- read_file
  acc$file <- file
  acc$stack <- stack
  acc$index <- 0L
  acc$line <- 0L
  acc$pd <- NULL
  acc$top_scope <- new_scope("top")
  acc$def_rows <- new_rows()
  acc$ref_rows <- new_rows()
  acc$pkg_rows <- list()
  acc$setting_rows <- list()
  acc$sourced_rows <- list()
  acc$note_rows <- list()
  acc$formulas <- list()
  acc$deferred <- list()
  acc$extra_defs <- list()
  acc$extra_refs <- list()
  acc$extra_pkgs <- list()
  acc$extra_settings <- list()
  acc$extra_sourced <- list()
  acc$extra_notes <- list()
  acc
}

#' The cell's single, mutable top-level scope.
top_scope <- function(acc) {
  acc$top_scope
}

#' A lexical scope during the walk.
#'
#' `kind` is `"top"`, `"local"` or `"function"`. `names` are the names bound
#' in this scope so far: for every kind, this grows in walk order as the
#' walker meets assignments (arguments are in a function scope's `names`
#' from the start). A nested function's scope chains to its enclosing
#' function scope, so it sees exactly the locals bound "so far" at the
#' point the nested function literal is walked, and no others: no
#' separate pre-scan is needed for that, since the chain is a live
#' reference to the same mutable scope. `parent` is the enclosing scope or
#' `NULL`.
#'
#' `home` is the nearest enclosing `"function"`-kind scope: itself, for one
#' created by `walk_function`/`walk_formula_lambda`; inherited from the
#' parent otherwise (through an `if`'s forked branches and a `local()`
#' nested in a function, neither of which is its own function boundary).
#' `NULL` when there is no enclosing function.
#'
#' `defer_target` is where a read that escapes `home` entirely should be
#' resolved: `home`'s own lexical parent's `home` (set once, when `home` is
#' created), or `NULL` to mean the cell's own top-level definitions. This
#' is the scope one level further out than `home` itself, because a read
#' inside a function is never resolved by that *same* function's own later
#' locals -- R already looked it up and found nothing there by the time the
#' assignment runs -- only by whatever the *enclosing* scope eventually
#' defines (`clean <- function() { data <- na.omit(data) }` reads the
#' global `data`, never its own local one, no matter how the walker orders
#' things). `home`'s own `deferred` list instead collects reads escaping a
#' function nested *inside* it (`g <- function() { h <- function(n) if (n
#' > 0) h(n - 1); h(3) }`: `h`'s self-reference has `defer_target ==
#' g_scope`, checked against `g_scope$names` once `g`'s whole body is
#' walked, in `finish_function_scope()` -- which is what keeps a locally
#' recursive function from referencing itself, the same rule the top level
#' already applies to the cell's own definitions, one level down).
#'
#' A read of `name` is a reference when no scope in the chain binds it.
#' Inside a function scope the read is deferred to `home$defer_target`'s
#' `deferred` list (or the cell's own `acc$deferred` when `defer_target` is
#' `NULL`); at top or local scope with no enclosing function, it is
#' recorded at once.
#'
#' Scopes are environments, not plain lists: a scope's `names` grows as the
#' walker meets more definitions, and every holder of that scope (an `if`'s
#' two branches aside, which fork and merge back) sees the growth without
#' anything being threaded back through return values.
new_scope <- function(kind, names = character(), parent = NULL,
                       home = NULL, defer_target = NULL) {
  self <- new.env(parent = emptyenv())
  self$kind <- kind
  self$names <- character()
  self$bound <- new.env(parent = emptyenv(), hash = TRUE)
  bind_names(self, names)
  self$parent <- parent
  self$home <- home
  self$defer_target <- defer_target
  self$deferred <- list()
  class(self) <- "ember_scope"
  self
}

#' An independent copy for a branch that must not see the other branch's
#' definitions while it is walked (`if`'s two arms). Shares the original's
#' `home`/`defer_target`: a fork is never itself a function boundary, even
#' when its `kind` is `"function"`.
fork_scope <- function(scope) {
  new_scope(scope$kind, scope$names, scope$parent,
            home = scope$home, defer_target = scope$defer_target)
}

in_function <- function(scope) {
  while (!is.null(scope)) {
    if (identical(scope$kind, "function")) return(TRUE)
    scope <- scope$parent
  }
  FALSE
}

is_bound <- function(scope, name) {
  while (!is.null(scope)) {
    if (exists(name, envir = scope$bound, inherits = FALSE)) return(TRUE)
    scope <- scope$parent
  }
  FALSE
}

#' Add names to a scope. `names` keeps their order for the branch logic in
#' `walk_if()`; `bound` is the hashed set `is_bound()` looks in, so a cell
#' with thousands of definitions doesn't search a long vector per read.
bind_names <- function(scope, names) {
  new <- names[!vapply(names, exists, logical(1), envir = scope$bound, inherits = FALSE)]
  new <- unique(new)
  if (length(new) == 0) return(invisible())
  for (n in new) assign(n, TRUE, envir = scope$bound)
  scope$names <- c(scope$names, new)
  invisible()
}

#' An append-only list of rows. Appending to a list held in an environment
#' copies the whole list each time; this keeps rows by number instead.
new_rows <- function() {
  store <- new.env(parent = emptyenv(), hash = TRUE)
  store$n <- 0L
  store
}

rows_push <- function(store, row) {
  store$n <- store$n + 1L
  assign(sprintf("r%d", store$n), row, envir = store)
  invisible()
}

rows_list <- function(store) {
  if (store$n == 0L) return(list())
  unname(mget(sprintf("r%d", seq_len(store$n)), envir = store))
}

#' Walk up to the cell's top scope, crossing any number of `local()`
#' nestings. Used by `<<-`/`->>` at top level: R resolves them in the
#' enclosing environment, which for a `local()` at any depth outside a
#' function is ultimately the global environment.
escape_to_top <- function(scope) {
  while (!identical(scope$kind, "top")) scope <- scope$parent
  scope
}

# ---- Recording -------------------------------------------------------------

#' `pos`, when given, is `list(line, col, end_col)` from `pd_position()`;
#' `NULL` (the default: the caller had no pid to try) falls back to the
#' enclosing top-level expression's line with `col`/`end_col` `NA`, the
#' same fallback `pd_position()` itself returns for an unresolved pid --
#' kept separate so a caller that never threads a pid at all (there is
#' none left after this change, but a future one might skip it) doesn't
#' need `acc$pd` to exist.
fallback_pos <- function(acc) {
  list(line = acc$line, col = NA_integer_, end_col = NA_integer_)
}

record_read <- function(acc, scope, name, where = "code", pos = NULL) {
  if (is_ignored(name)) return(invisible())
  if (is_bound(scope, name)) return(invisible())
  if (is.null(pos)) pos <- fallback_pos(acc)
  if (in_function(scope)) {
    target <- scope$home$defer_target
    row <- list(name = name, line = pos$line, col = pos$col, end_col = pos$end_col,
               where = where, file = acc$file)
    if (!is.null(target)) {
      target$deferred[[length(target$deferred) + 1]] <- row
      return(invisible())
    }
    acc$deferred[[length(acc$deferred) + 1]] <- row
  } else {
    rows_push(acc$ref_rows, list(name = name, line = pos$line, col = pos$col, end_col = pos$end_col,
           where = where, file = acc$file))
  }
}

#' Record a definition at the point the walker meets it. Only a `"top"`
#' scope's definitions become the cell's own (`acc$def_rows`); every scope
#' kind's `names` grows from here on, which is what makes function-body
#' scoping order-aware (see `walk_function()`): a name is local to the rest
#' of the body from this point, not from the body's start.
record_definition <- function(acc, scope, name, kind, pos = NULL) {
  if (is_ignored(name)) return(invisible())
  if (is.null(pos)) pos <- fallback_pos(acc)
  if (identical(scope$kind, "top")) {
    rows_push(acc$def_rows,
              list(name = name, line = pos$line, col = pos$col, end_col = pos$end_col,
                   kind = kind, file = acc$file))
  }
  if (scope$kind %in% c("top", "local", "function")) bind_names(scope, name)
}

#' Record a definition made by `assign()`/`data()` reached from the top
#' level or from `local()` nested there (only ever called when
#' `!in_function(scope)`): it becomes the cell's own definition even when
#' the immediate scope is `"local"`, because the call itself writes to the
#' global environment, unlike an ordinary assignment inside `local()`,
#' which stays scoped to the block (see `walk_local()`).
record_top_level_definition <- function(acc, scope, name, kind, pos = NULL) {
  if (is_ignored(name)) return(invisible())
  if (is.null(pos)) pos <- fallback_pos(acc)
  rows_push(acc$def_rows,
            list(name = name, line = pos$line, col = pos$col, end_col = pos$end_col,
                 kind = kind, file = acc$file))
  bind_names(scope, name)
}

record_package <- function(acc, name, attached) {
  acc$pkg_rows[[length(acc$pkg_rows) + 1]] <-
    list(name = name, attached = attached, line = acc$line)
}

record_setting <- function(acc, fn, pos = NULL) {
  if (is.null(pos)) pos <- fallback_pos(acc)
  acc$setting_rows[[length(acc$setting_rows) + 1]] <-
    list(fn = fn, line = pos$line, col = pos$col, end_col = pos$end_col)
}

#' `pos` is `NULL` (falls back, `col`/`end_col` `NA`) for a note with no
#' single responsible token: `"missing_file"` and `"source_parse_error"`.
record_note <- function(acc, kind, detail, pos = NULL) {
  if (is.null(pos)) pos <- fallback_pos(acc)
  acc$note_rows[[length(acc$note_rows) + 1]] <-
    list(kind = kind, line = pos$line, col = pos$col, end_col = pos$end_col, detail = detail)
}

is_ignored <- function(name) {
  !is.null(name) && length(name) == 1 && nzchar(name) &&
    (name %in% ignored_names || is_dot_dot_name(name))
}
