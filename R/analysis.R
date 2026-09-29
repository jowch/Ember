# Reading one cell's code statically. Pure: the only outside input is the
# injected `read_file` for `source()` with a literal path. The walker is a
# plain recursion over the language objects that tracks scope and order
# itself: codetools' walker would only supply the recursion, and its
# `findGlobals()` rules differ from Ember's (it treats `s` in `s <- s + 1` as
# local and skips formulas).

# ---- Result type -----------------------------------------------------------

#' A cell analysis: everything the graph needs to know about one cell.
#'
#' Fields, all always present (empty data frames when there is nothing):
#'
#' * `code`: the code that was read. The graph compares it to decide whether
#'   a cell needs re-reading; there is no separate hash.
#' * `parse_error`: `NULL`, or `list(message, line, column)`. When set, every
#'   other field is empty: a cell that doesn't parse defines and reads
#'   nothing.
#' * `definitions`: data frame `name`, `line`, `kind`, `file`. `kind` is one
#'   of `"assign"` (`x <- v`, `=`, `->`, top-level `<<-`), `"replacement"`
#'   (`df$col <- v`, `names(x) <- v`, `x %<>% f()`: the innermost target),
#'   `"for"`, `"function"`, `"call"` (`assign("x", v)`, `data(iris)`),
#'   `"alias"` (`box::use(dplyr[mutate])` binds `mutate`). `file` is `NA`
#'   for the cell's own code, else the sourced file's path. Dot-names are
#'   included; the graph decides what private means.
#' * `references`: data frame `name`, `line`, `where`, `file`. Names read at
#'   the top level before the cell defines them, plus free names inside
#'   function bodies that the cell never defines. `where` is `"code"` or
#'   `"formula"`. Names local to functions, `local()`, and formula columns
#'   are not here. Function heads (`helper()`) are references.
#' * `packages`: data frame `name`, `attached`, `line`. `attached` is `TRUE`
#'   for `library`, `require`, `pacman::p_load`; `FALSE` for `pkg::fn`,
#'   `requireNamespace`, `box::use`. A package can appear once per line. A
#'   qualified call (`pkg::fn(...)`) always records `pkg` here, even when
#'   `fn` is itself an attach/setting/source/etc. function handled by the
#'   same rule as its unqualified form (see `dispatch_call_by_name()`).
#' * `settings`: data frame `fn`, `line`: top-level calls to a global
#'   setting function (see `setting_functions`). Top-level means not inside
#'   a function definition; `local({ options(...) })` counts, and so does
#'   `pkg::fn(...)` when `fn` is a setting function.
#' * `formulas`: list of `formula_site` (see below): each formula that was
#'   read with the column rule, for the worker to check after the run.
#' * `sourced`: data frame `path`, `text`, `found`: literal `source()` paths
#'   and the contents the reader returned (`NA` when not found). The graph
#'   compares `text` to decide whether a cached analysis is still valid.
#' * `notes`: data frame `kind`, `line`, `detail`. `kind` is one of
#'   `"untracked_read"` (`get`, `exists`, `eval(parse())`),
#'   `"computed_source"`, `"computed_package"`, `"missing_file"`,
#'   `"source_parse_error"` (a sourced file that fails to parse; `detail`
#'   is the parser's message).
#'
#' Invariants: rows are in source order within the cell's own code and
#' within each sourced file; a sourced file's rows are appended as a block
#' at the point the analysis is finished, not interleaved with the cell's
#' own rows (an implementation choice for `read_cell()`'s performance, not
#' a rule anything depends on: consumers key rows by `name`/`file`, not
#' position). `line` is the first line of the top-level expression the item
#' sits in, as R's srcref gives it; a name is never both a formula column
#' and a reference from the same formula.
new_cell_analysis <- function(code,
                              parse_error = NULL,
                              definitions = empty_definitions(),
                              references = empty_references(),
                              packages = empty_packages(),
                              settings = empty_settings(),
                              formulas = list(),
                              sourced = empty_sourced(),
                              notes = empty_notes()) {
  structure(list(code = code, parse_error = parse_error,
                 definitions = definitions, references = references,
                 packages = packages, settings = settings,
                 formulas = formulas, sourced = sourced, notes = notes),
            class = "ember_cell_analysis")
}

empty_definitions <- function() {
  data.frame(name = character(), line = integer(), kind = character(),
             file = character(), stringsAsFactors = FALSE)
}
empty_references <- function() {
  data.frame(name = character(), line = integer(), where = character(),
             file = character(), stringsAsFactors = FALSE)
}
empty_packages <- function() {
  data.frame(name = character(), attached = logical(), line = integer(),
             stringsAsFactors = FALSE)
}
empty_settings <- function() {
  data.frame(fn = character(), line = integer(), stringsAsFactors = FALSE)
}
empty_sourced <- function() {
  data.frame(path = character(), text = character(), found = logical(),
             stringsAsFactors = FALSE)
}
empty_notes <- function() {
  data.frame(kind = character(), line = integer(), detail = character(),
             stringsAsFactors = FALSE)
}

#' One formula read with the column rule.
#'
#' `fn` is the enclosing call's head (`"lm"`, `"glm"`, `"mgcv::gam"`),
#' `data` the deparsed `data` argument, `columns` the names taken as
#' columns. `index` is the position of the top-level expression in the
#' cell and `line` its first line. The worker matches the call by `fn`
#' and evaluates `data` in the global environment after the cell ran, then
#' reports which `columns` are not in `names()` of that value; the graph
#' turns those into references through `graph_learn()`.
formula_site <- function(index, line, fn, data, columns) {
  structure(list(index = index, line = line, fn = fn, data = data,
                 columns = columns), class = "ember_formula_site")
}

# ---- Entry point -----------------------------------------------------------

#' Read one cell's code.
#'
#' @param code A single string: the cell's code.
#' @param read_file `function(path) -> character(1) or NULL`, used for
#'   `source("literal.R")`. `NULL` means every sourced path is reported as
#'   missing. The path is passed as written in the code; resolving it
#'   against the notebook's directory is the reader's job.
#' @return An `ember_cell_analysis`. Never errors on bad code: a parse
#'   failure comes back in `parse_error`, and a call argument left empty
#'   (`f(x, , y)`) is skipped wherever the walker meets it rather than
#'   read as a value (reading R's missing-argument marker raises "argument
#'   is missing"; `missing_arg()` probes for it under `tryCatch`).
#'
#' Rules applied, in the order the walker meets them:
#'
#' * Top-level reads are ordered: in `s <- s + 1` and `y <- x; x <- 1` the
#'   first read is a reference, because it happens before the cell defines
#'   the name. The graph gives no self edge for it: the worker removes a
#'   cell's variables before rerunning it, so the read fails at run time as
#'   it does under `Rscript`. Reads inside function bodies are the same
#'   idea one level down: a name is local to the body from the point of its
#'   first assignment in walk order (arguments are local from the start),
#'   textual order across branches and loops rather than real control-flow
#'   analysis (an `if`'s two arms both contribute their names once the `if`
#'   is behind us, same as at the top level: an assumed extra edge is
#'   cheaper than a missed one). A read before that point is deferred and
#'   resolved once the whole cell is read: it becomes a reference unless the
#'   cell defines the same name at its own top level, since the function
#'   runs after the whole cell. (codetools' `findGlobals()` gets the
#'   top-level case wrong, treating `s` as local; the walker tracks order
#'   itself.)
#' * Assignment inside a function, `local()` or a `function` argument
#'   default is local. `<<-` counts only at the top level; inside a
#'   function it is the worker's to see at run time.
#' * `for` defines its variable. `if` defines what either branch defines.
#' * `df$x <- v` and every other replacement form defines `df` with kind
#'   `"replacement"`. `x %<>% f()` reads and redefines `x`.
#' * `pkg::fn` records package `pkg` (not attached), then dispatches on
#'   `fn` exactly as an unqualified call to `fn` would (`rules.R`: "a call
#'   matches by its head symbol or by pkg::name with the package
#'   dropped"), except that `fn` itself is never recorded as a reference:
#'   `base::library(dplyr)` attaches `dplyr`, `base::options(digits = 2)`
#'   and top-level `withr::local_options(...)` are settings,
#'   `base::source("a.R")` is followed, `utils::data(iris)` defines `iris`,
#'   `base::get("x")` gets the `untracked_read` note. `x$name` and `x@slot`
#'   read `x` only, including inside a formula.
#' * A formula argument of a call is read by the column rule when the call
#'   has a named `data` argument, or is in `formula_data_positional` with a
#'   second unnamed argument (`lm(y ~ x, df)`); otherwise every symbol in it
#'   is a reference. A formula outside a call (`f <- y ~ x`) is all
#'   references. `d$y ~ d$x` references `d` only, the same as `$` anywhere
#'   else: a `$`/`@` term is never split into a column.
#' * `source("p.R")` merges the file's definitions, references, packages,
#'   settings and formulas into this cell, tagged with `file = "p.R"`,
#'   following `source()` inside the file. This happens whenever the call
#'   is reached from outside a function body, including nested inside any
#'   number of `local()`s (`local()` only shadows plain assignments; a
#'   `source()` or `data()` reached through it still writes globally, so
#'   its definitions are still the cell's). `local = TRUE` on that
#'   `source()` call reads its own definitions into the block instead, so
#'   they don't escape: noted (`computed_source`) but not merged. `local =
#'   <env>`, `sys.source`, and a computed path also get a note and nothing
#'   else. A path already on the source stack is skipped (a file that
#'   sources itself); a sourced file that fails to parse gets a
#'   `source_parse_error` note instead of merging anything.
read_cell <- function(code, read_file = NULL) {
  read_cell_in(code, read_file, file = NA_character_, stack = character())
}

#' The shared machinery behind `read_cell()` and `source()` following.
#'
#' `file` tags every row this level's own top-level code produces (`NA` for
#' the cell itself, the sourced path otherwise). `stack` is the chain of
#' paths currently being sourced, to skip a file that sources itself.
read_cell_in <- function(code, read_file, file, stack) {
  exprs <- tryCatch(parse(text = code, keep.source = TRUE),
                     error = function(e) e)
  if (inherits(exprs, "condition")) {
    return(new_cell_analysis(code,
                              parse_error = parse_error_from_condition(exprs)))
  }
  acc <- new_accumulator(read_file, file, stack)
  top <- top_scope(acc)
  for (i in seq_along(exprs)) {
    acc$index <- i
    acc$line <- expression_line(exprs, i)
    walk_expr(exprs[[i]], top, acc)
  }
  finish(acc, code)
}

parse_error_from_condition <- function(cond) {
  msg <- conditionMessage(cond)
  first_line <- strsplit(msg, "\n", fixed = TRUE)[[1]][1]
  m <- regmatches(first_line,
                   regexec("^<text>:([0-9]+):([0-9]+): (.*)$", first_line))[[1]]
  if (length(m) == 4) {
    list(message = m[4], line = as.integer(m[2]), column = as.integer(m[3]))
  } else {
    list(message = msg, line = NA_integer_, column = NA_integer_)
  }
}

#' Which names the cell defines for the graph: unique, source order.
definitions_of <- function(analysis) {
  unique(analysis$definitions$name)
}

#' Which names the cell reads: unique, source order.
references_of <- function(analysis) {
  unique(analysis$references$name)
}

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
  acc$top_scope <- new_scope("top")
  acc$def_rows <- list()
  acc$ref_rows <- list()
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
#' A read of `name` is a reference when no scope in the chain binds it.
#' Inside a function scope the read is deferred (resolved against all
#' top-level definitions when the cell finishes); at top or local scope it
#' is recorded at once.
#'
#' Scopes are environments, not plain lists: a scope's `names` grows as the
#' walker meets more definitions, and every holder of that scope (an `if`'s
#' two branches aside, which fork and merge back) sees the growth without
#' anything being threaded back through return values.
new_scope <- function(kind, names = character(), parent = NULL) {
  self <- new.env(parent = emptyenv())
  self$kind <- kind
  self$names <- names
  self$parent <- parent
  class(self) <- "ember_scope"
  self
}

#' An independent copy for a branch that must not see the other branch's
#' definitions while it is walked (`if`'s two arms).
fork_scope <- function(scope) {
  new_scope(scope$kind, scope$names, scope$parent)
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
    if (name %in% scope$names) return(TRUE)
    scope <- scope$parent
  }
  FALSE
}

#' Walk up to the cell's top scope, crossing any number of `local()`
#' nestings. Used by `<<-`/`->>` at top level: R resolves them in the
#' enclosing environment, which for a `local()` at any depth outside a
#' function is ultimately the global environment.
escape_to_top <- function(scope) {
  while (!identical(scope$kind, "top")) scope <- scope$parent
  scope
}

# ---- Walking ---------------------------------------------------------------

#' Walk one expression in a scope.
#'
#' Dispatches on the call head. `walk_call_args` handles the generic case
#' (an ordinary call): it never reads the head itself, only decides which
#' arguments are formulas and walks the rest as code, so every special-cased
#' head below is responsible for its own head handling.
walk_expr <- function(e, scope, acc) {
  if (is.symbol(e)) {
    name <- as.character(e)
    if (nzchar(name)) record_read(acc, scope, name)
    return(invisible())
  }
  if (!is.call(e)) return(invisible())

  head <- e[[1]]
  if (is.call(head)) {
    q <- qualified_head(head)
    if (!is.null(q)) {
      walk_qualified_call(e, scope, acc, q)
    } else {
      walk_expr(head, scope, acc)
      walk_call_args(e, scope, acc)
    }
    return(invisible())
  }
  if (!is.symbol(head)) {
    walk_call_args(e, scope, acc)
    return(invisible())
  }

  name <- as.character(head)
  switch(name,
    "function" = ,
    "\\" = { walk_function(e, scope, acc); return(invisible()) },
    "for" = { walk_for(e, scope, acc); return(invisible()) },
    "if" = { walk_if(e, scope, acc); return(invisible()) },
    "while" = ,
    "repeat" = ,
    "{" = ,
    "(" = {
      for (sub in as.list(e)[-1]) walk_expr(sub, scope, acc)
      return(invisible())
    },
    "local" = { walk_local(e, scope, acc); return(invisible()) },
    "::" = ,
    ":::" = {
      record_package(acc, as.character(e[[2]]), attached = FALSE)
      return(invisible())
    },
    "$" = ,
    "@" = { walk_expr(e[[2]], scope, acc); return(invisible()) },
    "~" = { walk_formula(e, scope, acc, has_data = FALSE); return(invisible()) }
  )

  dispatch_call_by_name(e, scope, acc, name)
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

walk_qualified_call <- function(e, scope, acc, q) {
  if (identical(q$pkg, "pacman") && identical(q$fn, "p_load")) {
    record_package(acc, "pacman", attached = FALSE)
    walk_attach_args(e, scope, acc)
  } else if (identical(q$pkg, "box") && identical(q$fn, "use")) {
    record_package(acc, "box", attached = FALSE)
    walk_box_use_args(e, scope, acc)
  } else {
    record_package(acc, q$pkg, attached = FALSE)
    dispatch_call_by_name(e, scope, acc, q$fn, qualified = TRUE)
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
dispatch_call_by_name <- function(e, scope, acc, name, qualified = FALSE) {
  maybe_record_name_read <- function() {
    if (!qualified) record_read(acc, scope, name)
  }

  if (!qualified && name %in% names(assignment_ops)) {
    walk_assignment(e, scope, acc, name)
    return(invisible())
  }
  if (name %in% quoting_functions) {
    return(invisible())
  }
  if (name %in% attach_functions) {
    walk_package_call(e, scope, acc, attached = TRUE, name = name)
    return(invisible())
  }
  if (name %in% use_functions) {
    walk_package_call(e, scope, acc, attached = FALSE, name = name)
    return(invisible())
  }
  if (name %in% setting_functions$always || name %in% setting_functions$write_only) {
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
    if (is_write && !in_function(scope)) record_setting(acc, name)
    walk_call_args(e, scope, acc)
    return(invisible())
  }
  if (name %in% untracked_reads) {
    record_note(acc, "untracked_read", name)
    walk_call_args(e, scope, acc)
    return(invisible())
  }
  if (name %in% literal_definers) {
    if (!in_function(scope)) {
      walk_literal_definer(e, scope, acc, name)
    } else {
      maybe_record_name_read()
      walk_call_args(e, scope, acc)
    }
    return(invisible())
  }
  if (identical(name, "source")) {
    if (!in_function(scope)) {
      walk_source(e, scope, acc)
    } else {
      maybe_record_name_read()
      walk_call_args(e, scope, acc)
    }
    return(invisible())
  }

  maybe_record_name_read()
  walk_call_args(e, scope, acc)
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
walk_function <- function(e, scope, acc) {
  formals_pl <- e[[2]]
  body <- e[[3]]
  arg_names <- names(formals_pl)
  if (is.null(arg_names)) arg_names <- character()
  inner <- new_scope("function", unique(arg_names), parent = scope)
  # Indexed directly (never through a stored variable): a formal with no
  # default is R's missing-argument sentinel, which raises "argument is
  # missing" the moment a variable holding it is read back.
  for (i in seq_along(formals_pl)) {
    if (!identical(formals_pl[[i]], quote(expr = ))) walk_expr(formals_pl[[i]], inner, acc)
  }
  walk_expr(body, inner, acc)
}

#' `local(expr)`: a new local scope.
#'
#' Definitions inside are private to the block. Settings calls, `source()`
#' and `data()` inside still count as reached from the top level (their
#' effect, or their following, is global) no matter how many `local()`s
#' they're nested in: gated on `!in_function(scope)`, not on the scope
#' being literally `"top"`. A `local(expr, envir = e)` form is treated the
#' same; the design accepts the extra edge.
walk_local <- function(e, scope, acc) {
  args <- as.list(e)[-1]
  if (length(args) == 0) return(invisible())
  local_scope <- new_scope("local", character(), parent = scope)
  walk_expr(args[[1]], local_scope, acc)
  if (length(args) > 1) {
    for (extra in args[-1]) walk_expr(extra, scope, acc)
  }
}

#' `for (var in seq) body`: `var` is bound before `body` is walked.
walk_for <- function(e, scope, acc) {
  var <- as.character(e[[2]])
  walk_expr(e[[3]], scope, acc)
  record_definition(acc, scope, var, "for")
  walk_expr(e[[4]], scope, acc)
}

#' `if (cond) then [else else_]`: the two arms are walked independently (one
#' arm must not see the other's definitions, since only one ever runs), then
#' whatever either arm defined becomes visible to what follows, in every
#' scope kind (function scopes included, per the order-aware rule: textual
#' order across branches, not real control-flow analysis).
walk_if <- function(e, scope, acc) {
  parts <- as.list(e)
  cond <- parts[[2]]
  then_branch <- parts[[3]]
  else_branch <- if (length(parts) >= 4) parts[[4]] else NULL

  walk_expr(cond, scope, acc)
  base_names <- scope$names

  then_scope <- fork_scope(scope)
  walk_expr(then_branch, then_scope, acc)
  added <- setdiff(then_scope$names, base_names)

  if (!is.null(else_branch)) {
    else_scope <- fork_scope(scope)
    walk_expr(else_branch, else_scope, acc)
    added <- union(added, setdiff(else_scope$names, base_names))
  }

  if (length(added) > 0 && scope$kind %in% c("top", "local", "function")) {
    scope$names <- unique(c(scope$names, added))
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
walk_assignment <- function(e, scope, acc, op) {
  side <- assignment_ops[[op]]
  raw_target <- if (identical(side, "lhs")) e[[2]] else e[[3]]
  value <- if (identical(side, "lhs")) e[[3]] else e[[2]]
  walk_expr(value, scope, acc)

  if (identical(op, "%<>%")) {
    target_name <- extract_target_name(raw_target)
    if (is.null(target_name)) return(invisible())
    record_read(acc, scope, target_name)
    record_definition(acc, scope, target_name, "replacement")
    return(invisible())
  }

  if (op %in% c("<<-", "->>")) {
    target_name <- extract_target_name(raw_target)
    if (is.null(target_name) || is_ignored(target_name)) return(invisible())
    if (in_function(scope)) {
      record_read(acc, scope, target_name)
    } else {
      top <- escape_to_top(scope)
      acc$def_rows[[length(acc$def_rows) + 1]] <-
        list(name = target_name, line = acc$line, kind = "assign", file = acc$file)
      top$names <- unique(c(top$names, target_name))
    }
    return(invisible())
  }

  simple_kind <- if (is_function_literal(value)) "function" else "assign"
  if (is.symbol(raw_target)) {
    record_definition(acc, scope, as.character(raw_target), simple_kind)
  } else if (is.character(raw_target) && length(raw_target) == 1) {
    record_definition(acc, scope, raw_target, simple_kind)
  } else if (is.call(raw_target)) {
    target_name <- extract_target_name(raw_target)
    if (!is.null(target_name)) {
      walk_replacement_target(raw_target, scope, acc)
      record_read(acc, scope, target_name)
      record_definition(acc, scope, target_name, "replacement")
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
walk_replacement_target <- function(t, scope, acc) {
  if (missing_arg(t)) return(invisible())
  if (!is.call(t)) return(invisible())
  h <- t[[1]]
  hname <- if (is.symbol(h)) as.character(h) else NULL
  args <- as.list(t)[-1]
  if (length(args) >= 1) walk_replacement_target(args[[1]], scope, acc)
  if (!is.null(hname) && hname %in% c("$", "@")) return(invisible())
  if (length(args) > 1) {
    for (rest in args[-1]) {
      if (missing_arg(rest)) next
      walk_expr(rest, scope, acc)
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

#' A call argument that was left empty (`f(x, , y)`). Guarded: once a
#' missing-argument value is bound to a plain variable, R raises "argument
#' is missing" the moment that variable is read, so a defensive
#' `tryCatch` is cheaper than tracking which callers already avoid it.
is_missing_arg <- function(x) {
  tryCatch(is.symbol(x) && !nzchar(as.character(x)), error = function(e) TRUE)
}

missing_arg <- function(x) is_missing_arg(x)

#' `library(x)`, `require("x")`, `pacman::p_load(a, b)`, `requireNamespace`.
#'
#' The package name is the first argument (or `package =`), as a symbol or
#' string; `p_load` takes every unnamed argument. With `character.only =
#' TRUE`, or a non-literal argument, the cell gets a `computed_package`
#' note. Other arguments are walked as code.
walk_package_call <- function(e, scope, acc, attached, name) {
  if (identical(name, "p_load")) {
    walk_attach_args(e, scope, acc)
    return(invisible())
  }

  args <- as.list(e)[-1]
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
      record_note(acc, "computed_package", name)
    } else {
      pkgname <- literal_package_name(args[[pkg_idx]])
      if (!is.null(pkgname)) {
        record_package(acc, pkgname, attached = attached)
      } else {
        record_note(acc, "computed_package", name)
      }
    }
  }

  for (i in seq_along(args)) {
    if (!is.na(pkg_idx) && i == pkg_idx) next
    if (missing_arg(args[[i]])) next
    walk_expr(args[[i]], scope, acc)
  }
}

#' Every unnamed argument of `p_load(a, b)` is a package to attach.
walk_attach_args <- function(e, scope, acc) {
  args <- as.list(e)[-1]
  for (a in args) {
    if (missing_arg(a)) next
    pkgname <- literal_package_name(a)
    if (!is.null(pkgname)) {
      record_package(acc, pkgname, attached = TRUE)
    } else {
      walk_expr(a, scope, acc)
    }
  }
}

#' `box::use(dplyr[mutate, filter], ./helpers)`. Best-effort: a bare or
#' bracketed package argument attaches the package (and, for `[...]`, binds
#' the selected names as `"alias"` definitions at top scope); a module path
#' argument (`./helpers`) is left untouched, since it names a file, not a
#' package.
walk_box_use_args <- function(e, scope, acc) {
  args <- as.list(e)[-1]
  for (a in args) {
    if (missing_arg(a)) next
    if (is.symbol(a)) {
      record_package(acc, as.character(a), attached = TRUE)
    } else if (is.call(a) && is.symbol(a[[1]]) && identical(as.character(a[[1]]), "[")) {
      pkg_expr <- a[[2]]
      if (is.symbol(pkg_expr)) {
        record_package(acc, as.character(pkg_expr), attached = TRUE)
      }
      for (sel in as.list(a)[-(1:2)]) {
        if (is.symbol(sel)) {
          record_definition(acc, scope, as.character(sel), "alias")
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
walk_literal_definer <- function(e, scope, acc, name) {
  args <- as.list(e)[-1]
  nms <- names2(args)
  if (identical(name, "assign")) {
    if (length(args) >= 1 && !missing_arg(args[[1]]) &&
        is.character(args[[1]]) && length(args[[1]]) == 1 &&
        !any(nms %in% c("envir", "pos"))) {
      record_top_level_definition(acc, scope, args[[1]], "call")
    }
    for (a in args) {
      if (missing_arg(a)) next
      walk_expr(a, scope, acc)
    }
  } else if (identical(name, "data")) {
    for (i in seq_along(args)) {
      a <- args[[i]]
      if (missing_arg(a)) next
      if (identical(nms[i], "list")) {
        if (is.call(a) && is.symbol(a[[1]]) && identical(as.character(a[[1]]), "c")) {
          for (sub in as.list(a)[-1]) {
            if (missing_arg(sub)) next
            pkgname <- literal_package_name(sub)
            if (!is.null(pkgname)) record_top_level_definition(acc, scope, pkgname, "call")
          }
        } else {
          walk_expr(a, scope, acc)
        }
      } else if (identical(nms[i], "")) {
        pkgname <- literal_package_name(a)
        if (!is.null(pkgname)) {
          record_top_level_definition(acc, scope, pkgname, "call")
        } else {
          walk_expr(a, scope, acc)
        }
      } else {
        walk_expr(a, scope, acc)
      }
    }
  }
}

#' `source("p.R")` at top scope (or `local()` nested there).
walk_source <- function(e, scope, acc) {
  args <- as.list(e)[-1]
  nms <- names2(args)

  path_idx <- NA_integer_
  if ("file" %in% nms) {
    path_idx <- which(nms == "file")[1]
  } else {
    unnamed <- which(nms == "")
    if (length(unnamed) >= 1) path_idx <- unnamed[1]
  }
  if (is.na(path_idx)) {
    for (a in args) {
      if (missing_arg(a)) next
      walk_expr(a, scope, acc)
    }
    return(invisible())
  }

  path_expr <- args[[path_idx]]
  local_idx <- which(nms == "local")
  local_val <- if (length(local_idx) >= 1) args[[local_idx[1]]] else NULL
  # `local = TRUE` or `local = <env>` evaluates the file somewhere other
  # than the global environment, so its definitions don't escape to the
  # cell; only an explicit `local = FALSE` (or no `local` argument at all,
  # the default) writes globally and is worth following.
  private_env <- !is.null(local_val) &&
    !(is.logical(local_val) && identical(local_val, FALSE))

  if (!(is.character(path_expr) && length(path_expr) == 1) || private_env) {
    record_note(acc, "computed_source", "source")
    for (a in args) {
      if (missing_arg(a)) next
      walk_expr(a, scope, acc)
    }
    return(invisible())
  }

  path <- path_expr
  for (a in args) {
    if (missing_arg(a)) next
    walk_expr(a, scope, acc)
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
    scope$names <- unique(c(scope$names, sub$definitions$name))
  }
  invisible()
}

#' Walk a call's arguments: decide which is the formula and which is the
#' data (by a named `data =` argument, or a second unnamed argument on a
#' `formula_data_positional` function), send `~` arguments to
#' `walk_formula`, everything else to `walk_expr`. Argument names are never
#' reads.
walk_call_args <- function(e, scope, acc) {
  head <- e[[1]]
  bare_fn <- bare_call_name(head)
  fn_display <- deparse_expr(head)
  args <- as.list(e)[-1]
  nms <- names2(args)

  has_data <- FALSE
  data_expr <- NULL
  if ("data" %in% nms) {
    has_data <- TRUE
    data_expr <- args[[which(nms == "data")[1]]]
  } else if (!is.null(bare_fn) && bare_fn %in% formula_data_positional) {
    unnamed_idx <- which(nms == "")
    if (length(unnamed_idx) >= 2) {
      has_data <- TRUE
      data_expr <- args[[unnamed_idx[2]]]
    }
  }
  data_text <- if (has_data) deparse_expr(data_expr) else NA_character_

  for (i in seq_along(args)) {
    a <- args[[i]]
    if (missing_arg(a)) next
    if (is.call(a) && is.symbol(a[[1]]) && identical(as.character(a[[1]]), "~")) {
      site <- formula_site(acc$index, acc$line, fn_display, data_text, character())
      walk_formula(a, scope, acc, has_data, site)
    } else {
      walk_expr(a, scope, acc)
    }
  }
}

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
walk_formula <- function(e, scope, acc, has_data, site = NULL) {
  parts <- as.list(e)[-1]
  cols <- character()

  term <- function(t, hd) {
    if (missing_arg(t)) return(invisible())
    if (is.symbol(t)) {
      nm <- as.character(t)
      if (identical(nm, ".") || !nzchar(nm)) return(invisible())
      if (hd) {
        cols <<- c(cols, nm)
      } else {
        record_read(acc, scope, nm, where = "formula")
      }
      return(invisible())
    }
    if (!is.call(t)) return(invisible())
    h <- t[[1]]
    hname <- if (is.symbol(h)) as.character(h) else NULL
    if (!is.null(hname) && hname %in% c("$", "@")) {
      walk_expr(t[[2]], scope, acc)
      return(invisible())
    }
    if (!is.null(hname) && hname %in% formula_transparent) {
      for (sub in as.list(t)[-1]) term(sub, hd)
      return(invisible())
    }
    if (!is.null(hname)) record_read(acc, scope, hname, where = "formula")
    targs <- as.list(t)[-1]
    if (length(targs) >= 1) {
      term(targs[[1]], hd)
      if (length(targs) > 1) {
        for (rest in targs[-1]) term(rest, FALSE)
      }
    }
  }

  for (p in parts) term(p, has_data)

  if (has_data && length(cols) > 0 && !is.null(site)) {
    site$columns <- unique(cols)
    acc$formulas[[length(acc$formulas) + 1]] <- site
  }
}

# ---- Recording -------------------------------------------------------------

record_read <- function(acc, scope, name, where = "code") {
  if (is_ignored(name)) return(invisible())
  if (is_bound(scope, name)) return(invisible())
  if (in_function(scope)) {
    acc$deferred[[length(acc$deferred) + 1]] <-
      list(name = name, line = acc$line, where = where, file = acc$file)
  } else {
    acc$ref_rows[[length(acc$ref_rows) + 1]] <-
      list(name = name, line = acc$line, where = where, file = acc$file)
  }
}

#' Record a definition at the point the walker meets it. Only a `"top"`
#' scope's definitions become the cell's own (`acc$def_rows`); every scope
#' kind's `names` grows from here on, which is what makes function-body
#' scoping order-aware (see `walk_function()`): a name is local to the rest
#' of the body from this point, not from the body's start.
record_definition <- function(acc, scope, name, kind) {
  if (is_ignored(name)) return(invisible())
  if (identical(scope$kind, "top")) {
    acc$def_rows[[length(acc$def_rows) + 1]] <-
      list(name = name, line = acc$line, kind = kind, file = acc$file)
  }
  if (scope$kind %in% c("top", "local", "function")) {
    scope$names <- c(scope$names, name)
  }
}

#' Record a definition made by `assign()`/`data()` reached from the top
#' level or from `local()` nested there (only ever called when
#' `!in_function(scope)`): it becomes the cell's own definition even when
#' the immediate scope is `"local"`, because the call itself writes to the
#' global environment, unlike an ordinary assignment inside `local()`,
#' which stays scoped to the block (see `walk_local()`).
record_top_level_definition <- function(acc, scope, name, kind) {
  if (is_ignored(name)) return(invisible())
  acc$def_rows[[length(acc$def_rows) + 1]] <-
    list(name = name, line = acc$line, kind = kind, file = acc$file)
  scope$names <- c(scope$names, name)
}

record_package <- function(acc, name, attached) {
  acc$pkg_rows[[length(acc$pkg_rows) + 1]] <-
    list(name = name, attached = attached, line = acc$line)
}

record_setting <- function(acc, fn) {
  acc$setting_rows[[length(acc$setting_rows) + 1]] <- list(fn = fn, line = acc$line)
}

record_note <- function(acc, kind, detail) {
  acc$note_rows[[length(acc$note_rows) + 1]] <-
    list(kind = kind, line = acc$line, detail = detail)
}

is_ignored <- function(name) {
  !is.null(name) && length(name) == 1 && nzchar(name) && name %in% ignored_names
}

#' Source-order line of a top-level expression.
expression_line <- function(exprs, i) {
  srcref <- attr(exprs, "srcref")[[i]]
  as.integer(srcref[1])
}

# ---- Small helpers ----------------------------------------------------------

names2 <- function(x) {
  n <- names(x)
  if (is.null(n)) rep("", length(x)) else ifelse(is.na(n), "", n)
}

deparse_expr <- function(x) {
  paste(deparse(x), collapse = " ")
}

# ---- Finishing ---------------------------------------------------------------

#' Turn the accumulator into an `ember_cell_analysis`: build each field's
#' data frame once from its accumulated rows (plus any whole frames merged
#' in from `source()`d files), fold the deferred function-body reads in
#' (dropping any the cell defines anywhere at its own top level), drop
#' ignored names, and de-duplicate.
finish <- function(acc, code) {
  defs <- rbind_all(def_rows_to_df(acc$def_rows), acc$extra_defs)
  row.names(defs) <- NULL
  def_names <- if (nrow(defs) > 0) unique(defs$name) else character()

  deferred_df <- deferred_to_df(acc$deferred)
  if (nrow(deferred_df) > 0) {
    deferred_df <- deferred_df[!(deferred_df$name %in% def_names), , drop = FALSE]
  }

  refs <- rbind_all(ref_rows_to_df(acc$ref_rows), acc$extra_refs)
  refs <- rbind(refs, deferred_df)
  if (nrow(refs) > 0) {
    refs <- refs[!(refs$name %in% ignored_names), , drop = FALSE]
  }
  if (nrow(refs) > 0) {
    refs <- refs[!duplicated(refs[c("name", "line", "where", "file")]), , drop = FALSE]
    refs <- refs[order(refs$line), , drop = FALSE]
  }
  row.names(refs) <- NULL

  pkgs <- rbind_all(pkg_rows_to_df(acc$pkg_rows), acc$extra_pkgs)
  if (nrow(pkgs) > 0) pkgs <- pkgs[!duplicated(pkgs[c("name", "line")]), , drop = FALSE]
  row.names(pkgs) <- NULL

  settings <- rbind_all(setting_rows_to_df(acc$setting_rows), acc$extra_settings)
  if (nrow(settings) > 0) settings <- settings[!duplicated(settings[c("fn", "line")]), , drop = FALSE]
  row.names(settings) <- NULL

  sourced <- rbind_all(sourced_rows_to_df(acc$sourced_rows), acc$extra_sourced)
  row.names(sourced) <- NULL

  notes <- rbind_all(note_rows_to_df(acc$note_rows), acc$extra_notes)
  row.names(notes) <- NULL

  new_cell_analysis(code, parse_error = NULL, definitions = defs,
                     references = refs, packages = pkgs, settings = settings,
                     formulas = acc$formulas, sourced = sourced, notes = notes)
}

#' Combine a data frame built from this level's own rows with any whole
#' frames merged in from `source()`d files. A single `rbind` call over
#' every piece at once, not one call per row.
rbind_all <- function(base, extra_list) {
  extra_list <- Filter(function(d) !is.null(d) && nrow(d) > 0, extra_list)
  if (length(extra_list) == 0) return(base)
  do.call(rbind, c(list(base), extra_list))
}

def_rows_to_df <- function(rows) {
  if (length(rows) == 0) return(empty_definitions())
  data.frame(
    name = vapply(rows, `[[`, character(1), "name"),
    line = vapply(rows, `[[`, integer(1), "line"),
    kind = vapply(rows, `[[`, character(1), "kind"),
    file = vapply(rows, `[[`, character(1), "file"),
    stringsAsFactors = FALSE
  )
}

ref_rows_to_df <- function(rows) {
  if (length(rows) == 0) return(empty_references())
  data.frame(
    name = vapply(rows, `[[`, character(1), "name"),
    line = vapply(rows, `[[`, integer(1), "line"),
    where = vapply(rows, `[[`, character(1), "where"),
    file = vapply(rows, `[[`, character(1), "file"),
    stringsAsFactors = FALSE
  )
}

pkg_rows_to_df <- function(rows) {
  if (length(rows) == 0) return(empty_packages())
  data.frame(
    name = vapply(rows, `[[`, character(1), "name"),
    attached = vapply(rows, `[[`, logical(1), "attached"),
    line = vapply(rows, `[[`, integer(1), "line"),
    stringsAsFactors = FALSE
  )
}

setting_rows_to_df <- function(rows) {
  if (length(rows) == 0) return(empty_settings())
  data.frame(
    fn = vapply(rows, `[[`, character(1), "fn"),
    line = vapply(rows, `[[`, integer(1), "line"),
    stringsAsFactors = FALSE
  )
}

sourced_rows_to_df <- function(rows) {
  if (length(rows) == 0) return(empty_sourced())
  data.frame(
    path = vapply(rows, `[[`, character(1), "path"),
    text = vapply(rows, `[[`, character(1), "text"),
    found = vapply(rows, `[[`, logical(1), "found"),
    stringsAsFactors = FALSE
  )
}

note_rows_to_df <- function(rows) {
  if (length(rows) == 0) return(empty_notes())
  data.frame(
    kind = vapply(rows, `[[`, character(1), "kind"),
    line = vapply(rows, `[[`, integer(1), "line"),
    detail = vapply(rows, `[[`, character(1), "detail"),
    stringsAsFactors = FALSE
  )
}

deferred_to_df <- function(deferred) {
  if (length(deferred) == 0) return(empty_references())
  data.frame(
    name = vapply(deferred, `[[`, character(1), "name"),
    line = vapply(deferred, `[[`, integer(1), "line"),
    where = vapply(deferred, `[[`, character(1), "where"),
    file = vapply(deferred, function(x) if (is.null(x$file) || is.na(x$file)) NA_character_ else x$file, character(1)),
    stringsAsFactors = FALSE
  )
}
