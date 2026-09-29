# Parse-data position matching: recovering the exact token a language-object
# node came from, for every row the walker in walk.R/walk-formula.R/
# walk-calls.R records.
#
# ---- Exact positions --------------------------------------------------------
#
# Every recorded row carries the exact token it came from (`line`, `col`,
# `end_col`), not just the enclosing top-level expression's first line, for
# the editor's go-to-definition and error markers. The trouble: the walker
# recurses over *language objects* (the parsed calls/symbols R gives back),
# which carry no position below the top-level expression they came from,
# while `getParseData()` gives positions only for the *token tree*, not the
# language objects. The two trees are not the same shape: R desugars `v ->
# x` into a call to `` `<-` `` with the operands swapped, a native pipe `x
# |> f(y)` into the plain call `f(x, y)`, and `\(x) x` keeps `\\` as the
# call head instead of `function` -- so a naive parallel walk of the two
# trees by position would visit the wrong sub-node for any of these.
#
# The fix: `pd_call_parts()` decomposes one parse-data node into a head
# position and an ordered list of argument positions by looking at the
# *shape* of its filtered children (see below), not by assuming the
# language object and the token tree agree on order; `pd_resolve_pipe()`
# handles the one case (the native pipe) where R's desugaring truly
# discards a token-tree node the language object no longer has a
# counterpart for. The walker threads a `pid` argument (a parse-data node
# id, or `NA` once a shape doesn't match) alongside `scope`/`acc` through
# every `walk_*` function, mirroring the recursion it already does: a
# handler that knows how to align its own construct's shape computes its
# children's pids and passes them on; one that doesn't (or meets a shape
# that doesn't match what it expected -- a malformed backtick-called
# special form, for instance) passes `NA` down, and every `record_*` call
# below it then reports the top-level expression's own line with `col =
# NA` rather than guessing. A name found inside a glue string's `"{...}"`
# segment is reported at the position of the whole string literal, not a
# position inside it: the segment is reparsed from a plain string with no
# relation to the enclosing file's coordinates.

# ---- Positions ---------------------------------------------------------------
#
# See "Exact positions" at the top of this file. A `pid` below is always
# either a single integer id into `acc$pd`, or `NA_integer_` meaning
# "unknown"; every function here is defined on `NA_integer_` too, returning
# the same "unknown" result, so a caller never needs to guard a `pid`
# before passing it on.

#' Parse-data tokens that never carry position information the walker
#' needs by themselves: grouping punctuation, formal-argument and
#' named-argument markers (their value has its own token), keywords that
#' introduce a special form the walker already dispatches on by name (`if`,
#' `for`, `function`, ...), and the `;` that can separate two top-level
#' expressions on one line (`f(x); g(x)`, parsed with `parent == 0` like
#' the expressions themselves -- left undiscarded, it would throw off the
#' count `top_pids` in `read_cell_in()` expects to match `length(exprs)`).
#' `'['`/`'['`/LBB (`[[`'s opening) are deliberately not here: they are
#' kept as the operator token of an indexing call (see `pd_call_parts()`),
#' the same way `'$'`/`'@'`/`'~'` and the arithmetic operators are.
pd_discard_tokens <- c("'('", "')'", "','", "']'", "'{'", "'}'", "';'",
                       "SYMBOL_FORMALS", "EQ_FORMALS", "SYMBOL_SUB", "EQ_SUB",
                       "IF", "ELSE", "FOR", "WHILE", "REPEAT", "FUNCTION", "IN")

#' `getParseData()`'s data frame, indexed for O(1) lookups instead of the
#' `data.frame` scans (`pd[pd$id == x, ]`, `pd[pd$parent == x, ]`) that
#' would otherwise run once per node visited: `read_cell()` on a 6000-line
#' cell built one of those scans per token, which is quadratic in the
#' cell's size and measured in tens of seconds, not milliseconds. `line1`,
#' `col1`, `col2`, `token` and `text` are plain vectors positioned by id
#' (parse-data ids are small integers, so this is a dense array, not a
#' hash); `children` is positioned by parent id the same way (offset by 1,
#' since a top-level node's parent is `0`) rather than a list keyed by the
#' id as a string, since a plain list's `[[name]]` is itself a linear scan
#' of its names, not a hash lookup -- the same quadratic cost one level
#' down. Each element is `pid`'s own children, already sorted by source
#' position and already filtered by `pd_discard_tokens` -- the one `split()`
#' builds, rather than re-filtering the same rows on every
#' `pd_child_ids()` call.
build_pd_index <- function(pd) {
  if (nrow(pd) == 0) {
    return(list(max_id = 0L, line1 = integer(), col1 = integer(),
               col2 = integer(), token = character(), text = character(),
               children = list()))
  }
  max_id <- max(pd$id)
  line1 <- integer(max_id); line1[pd$id] <- pd$line1
  col1  <- integer(max_id); col1[pd$id]  <- pd$col1
  col2  <- integer(max_id); col2[pd$id]  <- pd$col2
  token <- character(max_id); token[pd$id] <- pd$token
  text  <- character(max_id); text[pd$id]  <- pd$text

  # `pd$parent < 0` is a comment, attached to the statement it trails
  # (parent negated) rather than nested inside it: never a candidate slot,
  # and left in would poison `children`'s index-by-parent-id-plus-1 scheme
  # with a negative index.
  keep <- !(pd$token %in% pd_discard_tokens) & !(pd$terminal & pd$text == "\\") &
    pd$parent >= 0
  kept <- pd[keep, c("id", "parent", "line1", "col1"), drop = FALSE]
  kept <- kept[order(kept$parent, kept$line1, kept$col1), ]
  children <- vector("list", max_id + 1L)
  if (nrow(kept) > 0) {
    grp <- split(kept$id, kept$parent)
    children[as.integer(names(grp)) + 1L] <- grp
  }

  list(max_id = max_id, line1 = line1, col1 = col1, col2 = col2,
       token = token, text = text, children = children)
}

#' A language-object node's own position from its parse-data id, or a
#' fallback to the enclosing top-level expression's line with `col = NA`
#' when `pid` is `NA` or not found (a shape the matcher didn't align). `pd`
#' is a `build_pd_index()` result; an id past `max_id` (or `NA`) never
#' happened, since ids only ever come from `pd` itself, but is guarded
#' rather than assumed.
pd_position <- function(acc, pid) {
  pd <- acc$pd
  if (is.null(pid) || is.na(pid) || is.null(pd) || pid < 1L || pid > pd$max_id) {
    return(list(line = acc$line, col = NA_integer_, end_col = NA_integer_))
  }
  list(line = pd$line1[pid], col = pd$col1[pid], end_col = pd$col2[pid])
}

#' `pid`'s direct children in source order, minus `pd_discard_tokens` and
#' minus a literal backslash (`\(x) ...`'s head): the candidate slots for
#' `pd_call_parts()` to align against a language object's own children.
pd_child_ids <- function(pd, pid) {
  if (is.na(pid) || pid + 1L > length(pd$children)) return(integer())
  kids <- pd$children[[pid + 1L]]
  if (is.null(kids)) integer() else kids
}

#' Decompose one call-shaped parse-data node into a head position and an
#' ordered list of argument positions, matching `e`'s own `as.list(e)[-1]`
#' (including a `NA` slot for each argument `missing_arg()` finds empty,
#' which has no parse-data node of its own to match).
#'
#' The token tree and the language object agree on shape far more often
#' than not, since R desugars only a handful of forms (see "Exact
#' positions" above); the two are told apart by how many of `pid`'s
#' filtered children are themselves further sub-expressions ("expr" nodes)
#' versus bare operator/keyword tokens:
#'
#' * No bare token (every child is "expr"): an ordinary prefix call
#'   (`f(a, b)`, a qualified call's own `pkg::fn` head, `box::use`'s inner
#'   `dplyr[mutate]`) or an empty-argument call (`f()`). The first child is
#'   the head, the rest are arguments in order.
#' * Exactly one bare token: an infix or indexing form (`x + y`, `df$z`,
#'   `x[i, j]`, `x <- v`, `pkg::fn`, `x |> f(y)`) or a prefix unary one
#'   (`-x`, a one-sided `~x`). That token is the head/operator; every other
#'   child is an argument, in source order -- except `->`/`->>`, which R
#'   parses with the value first and the target second (`v -> x` is
#'   grammatically "value RIGHT_ASSIGN target") while the *language*
#'   object always has target before value (`` `<-`(x, v) ``, whichever
#'   way it was spelled): detected from the operator token's own text and
#'   corrected by reversing the two arguments. The native pipe (`|>`) is
#'   the one case a bare operator's own two children don't line up with
#'   `e`'s at all -- R discards the pipe's rhs-call framing when it
#'   desugars `x |> f(y)` into the plain call `f(x, y)` -- so it is
#'   recognised by the operator token's type and handed to
#'   `pd_resolve_pipe()` instead of the rule above.
#' * More than one bare token, or a filtered-child count that doesn't match
#'   `e`'s non-missing argument count once a head is assumed: the shape
#'   isn't one this function recognises (or `pid` is `NA`). Falls back to
#'   `head = NA` and every argument `NA`.
#'
#' `pd_leaf_tokens` names the parse-data tokens for a leaf value (a symbol,
#' string, number or the native pipe's `_` placeholder) standing bare --
#' not wrapped in its own "expr" -- as a direct child of a call-shaped
#' node. Most argument positions are "expr"-wrapped even when they're a
#' single symbol (`f(x)`'s `x` is), but a few grammar productions restrict
#' a slot to a raw name and never wrap it: `$`/`@`'s right side (`df$z`'s
#' `z`) is the one this function meets. Without excluding these, the one
#' bare token they produce would be mistaken for an operator/head slot the
#' way `` `$` `` genuinely is one.
pd_leaf_tokens <- c("SYMBOL", "SYMBOL_FUNCTION_CALL", "SYMBOL_PACKAGE",
                    "STR_CONST", "NUM_CONST", "NULL_CONST", "PLACEHOLDER")

pd_call_parts <- function(pd, e, pid) {
  args <- as.list(e)[-1]
  n <- length(args)
  non_missing <- which(!vapply(args, missing_arg, logical(1)))
  empty <- list(head = NA_integer_, args = rep(list(NA_integer_), n))
  if (is.na(pid)) return(empty)

  kids <- pd_child_ids(pd, pid)
  if (length(kids) == 0) {
    if (n == 0) return(list(head = NA_integer_, args = list()))
    return(empty)
  }
  toks <- pd$token[kids]
  op_idx <- which(toks != "expr" & !(toks %in% pd_leaf_tokens))

  if (length(op_idx) == 1 && identical(toks[op_idx], "PIPE")) {
    piped <- pd_resolve_pipe(pd, e, kids, op_idx)
    return(if (is.null(piped)) empty else piped)
  }

  if (length(op_idx) == 0) {
    head_id <- kids[1]
    arg_kids <- kids[-1]
  } else if (length(op_idx) == 1) {
    head_id <- kids[op_idx]
    arg_kids <- kids[-op_idx]
    optext <- pd$text[head_id]
    if (identical(optext, "->") || identical(optext, "->>")) {
      arg_kids <- rev(arg_kids)
    }
  } else {
    return(empty)
  }

  if (length(arg_kids) != length(non_missing)) return(empty)
  arg_ids <- rep(list(NA_integer_), n)
  arg_ids[non_missing] <- as.list(arg_kids)
  list(head = head_id, args = arg_ids)
}

#' The one shape `pd_call_parts()` can't align by simple position: a
#' native pipe. `kids`/`bare` are the already-computed filtered children of
#' the outer `lhs |> rhs(...)` node and the index of its `PIPE` token
#' (always length 3: lhs, `|>`, rhs). `rhs` must itself decompose as a
#' plain prefix call (no bare token of its own): `x |> (\(d) f(d))()`-style
#' rhs expressions aren't matched, same as any other shape this module
#' doesn't recognise.
#'
#' The desugared call's arguments either equal the rhs call's own explicit
#' arguments with `lhs` inserted as a new first argument (the common case,
#' no placeholder), or equal them one-for-one with `lhs` substituted for
#' whichever explicit argument was written as `_` (`data = _`).
pd_resolve_pipe <- function(pd, e, kids, op_idx) {
  lhs_pid <- kids[1]
  rhs_pid <- kids[3]
  rhs_kids <- pd_child_ids(pd, rhs_pid)
  if (length(rhs_kids) == 0) return(NULL)
  rhs_toks <- pd$token[rhs_kids]
  if (any(rhs_toks != "expr")) return(NULL)
  rhs_head <- rhs_kids[1]
  rhs_args <- rhs_kids[-1]

  args <- as.list(e)[-1]
  n <- length(args)
  non_missing <- which(!vapply(args, missing_arg, logical(1)))
  arg_ids <- rep(list(NA_integer_), n)

  if (length(rhs_args) == length(non_missing) - 1 && length(non_missing) >= 1) {
    arg_ids[[non_missing[1]]] <- lhs_pid
    if (length(non_missing) > 1) arg_ids[non_missing[-1]] <- as.list(rhs_args)
    return(list(head = rhs_head, args = arg_ids))
  }
  if (length(rhs_args) == length(non_missing)) {
    is_placeholder <- vapply(rhs_args, function(a) pd_is_placeholder(pd, a), logical(1))
    if (!any(is_placeholder)) return(NULL)
    replaced <- rhs_args
    replaced[[which(is_placeholder)[1]]] <- lhs_pid
    arg_ids[non_missing] <- as.list(replaced)
    return(list(head = rhs_head, args = arg_ids))
  }
  NULL
}

#' Is the argument slot `pid` the native pipe's `_` placeholder? It's a
#' bare `PLACEHOLDER` token wrapped in its own "expr", one level down from
#' the argument slot `pd_child_ids()` returns.
pd_is_placeholder <- function(pd, pid) {
  if (pid < 1L || pid > pd$max_id) return(FALSE)
  if (identical(pd$token[pid], "PLACEHOLDER")) return(TRUE)
  kids <- pd_child_ids(pd, pid)
  length(kids) == 1 && identical(pd$token[kids[1]], "PLACEHOLDER")
}

#' The position of a qualified call's own function-name token
#' (`pkg::fn`'s `fn`, not `pkg`): `head` is the language object `pkg::fn`
#' (a call to `` `::` ``/`` `:::` ``), `head_pid` its parse-data id (from
#' the enclosing call's own `pd_call_parts()$head`). Used for `settings`
#' rows on a qualified call, which are keyed to the function name.
pd_qualified_fn_pid <- function(pd, head, head_pid) {
  parts <- pd_call_parts(pd, head, head_pid)
  safe_pid(parts$args, 2)
}

#' Argument-only decomposition, for a special form with no head slot of
#' its own to recover: `{ ... }`, `(...)`, `while (cond) body`, `repeat
#' body`. Every filtered child is an argument, in order; there is no "one
#' bare token is the operator" case to detect; a filtered-child count that
#' doesn't match `e`'s non-missing argument count falls back to every
#' argument `NA`, the same as `pd_call_parts()`.
pd_arg_only <- function(pd, e, pid) {
  args <- as.list(e)[-1]
  n <- length(args)
  non_missing <- which(!vapply(args, missing_arg, logical(1)))
  empty <- rep(list(NA_integer_), n)
  if (is.na(pid)) return(empty)
  kids <- pd_child_ids(pd, pid)
  if (length(kids) != length(non_missing)) return(empty)
  out <- rep(list(NA_integer_), n)
  out[non_missing] <- as.list(kids)
  out
}

#' `lst[[i]]`, or `NA_integer_` when `lst` is too short: guards an index
#' into a `pd_call_parts()`/`pd_arg_only()` result against a shape that
#' didn't align the way a caller expected (a malformed backtick-called
#' special form, `` `$`() ``, ...).
safe_pid <- function(lst, i) {
  if (length(lst) >= i) {
    v <- lst[[i]]
    if (is.null(v)) NA_integer_ else v
  } else {
    NA_integer_
  }
}

#' A call argument that was left empty (`f(x, , y)`). Guarded: once a
#' missing-argument value is bound to a plain variable, R raises "argument
#' is missing" the moment that variable is read, so a defensive
#' `tryCatch` is cheaper than tracking which callers already avoid it.
is_missing_arg <- function(x) {
  tryCatch(is.symbol(x) && !nzchar(as.character(x)), error = function(e) TRUE)
}

missing_arg <- function(x) is_missing_arg(x)
