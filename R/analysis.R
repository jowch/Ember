# Reading one cell's code statically. Pure: the only outside input is the
# injected `read_file` for `source()` with a literal path. See walk.R,
# walk-formula.R, walk-calls.R and positions.R for the walker itself; this
# file holds the result type, the entry point, and finishing the
# accumulated rows into an `ember_cell_analysis`.

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
#' * `definitions`: data frame `name`, `line`, `col`, `end_col`, `kind`,
#'   `file`. `kind` is one of `"assign"` (`x <- v`, `=`, `->`, top-level
#'   `<<-`), `"replacement"` (`df$col <- v`, `names(x) <- v`, `x %<>% f()`:
#'   the innermost target), `"for"`, `"function"`, `"call"` (`assign("x",
#'   v)`, `data(iris)`), `"generic"` (`setGeneric("area")`), `"alias"`
#'   (`box::use(dplyr[mutate])` binds `mutate`). `file` is `NA` for the cell's own code, else the sourced
#'   file's path. Dot-names are included; the graph decides what private
#'   means. A name defined more than once at distinct positions (rare: e.g.
#'   `x <- 1; x <- 2` on one line) is one row per position, not
#'   deduplicated by name; `definitions_of()` still returns unique names.
#' * `references`: data frame `name`, `line`, `col`, `end_col`, `where`,
#'   `file`. Names read at the top level before the cell defines them, plus
#'   free names inside function bodies that the cell never defines. `where`
#'   is `"code"` or `"formula"`. Names local to functions, `local()`, and
#'   formula columns are not here. Function heads (`helper()`) are
#'   references. A name read more than once is one row per distinct
#'   position (deduplicated on `name`/`line`/`col`/`where`/`file`, not on
#'   `name` alone); `references_of()` still returns unique names.
#' * `packages`: data frame `name`, `attached`, `line`. `attached` is `TRUE`
#'   for `library`, `require`, `pacman::p_load`; `FALSE` for `pkg::fn`,
#'   `requireNamespace`, `box::use`. A package can appear once per line. A
#'   qualified call (`pkg::fn(...)`) always records `pkg` here, even when
#'   `fn` is itself an attach/setting/source/etc. function handled by the
#'   same rule as its unqualified form (see `dispatch_call_by_name()`).
#' * `settings`: data frame `fn`, `setting`, `line`, `col`, `end_col`:
#'   top-level calls to a global setting function (see
#'   `setting_functions`), positioned at the function name token (for
#'   `pkg::fn(...)`, `fn`'s own token, not `pkg`'s), one row per setting
#'   key the call names (`setting_keys()`; `NA` when computed). Top-level
#'   means not inside a function definition or a `local()` block;
#'   `pkg::fn(...)` counts when `fn` is a setting function.
#' * `formulas`: list of `formula_site` (see below): each formula that was
#'   read with the column rule, for the worker to check after the run.
#' * `sourced`: data frame `path`, `text`, `found`: literal `source()` paths
#'   and the contents the reader returned (`NA` when not found). The graph
#'   compares `text` to decide whether a cached analysis is still valid.
#' * `methods`: data frame `generic`, `signature`, `form`, `line`, `col`,
#'   `end_col`, `file`: the methods the cell defines. `form` is `"name"`
#'   for a top-level function whose name has a dot (`print.foo <-
#'   function(x, ...)`), one row per way of splitting the name at a dot
#'   (`as.data.frame.foo` gives `as`, `as.data` and `as.data.frame`, since
#'   which prefix is a generic is the graph's to decide, in
#'   `resolve_methods()`); `"register"` for `registerS3method()` and
#'   `.S3method()`; `"s4"` for `setMethod()`. `signature` is the class (S3)
#'   or the comma-joined signature (S4), `NA` when computed. Positions are
#'   the name's token or the generic argument's.
#' * `notes`: data frame `kind`, `line`, `col`, `end_col`, `detail`. `kind`
#'   is one of `"untracked_read"` (`get`, `exists`, `eval(parse())`),
#'   `"computed_source"`, `"computed_package"`, `"missing_file"`,
#'   `"source_parse_error"` (a sourced file that fails to parse; `detail`
#'   is the parser's message). `col`/`end_col` are `NA` for a note with no
#'   single responsible token (`"missing_file"`, `"source_parse_error"`).
#'
#' Invariants: rows are in source order within the cell's own code and
#' within each sourced file; a sourced file's rows are appended as a block
#' at the point the analysis is finished, not interleaved with the cell's
#' own rows (an implementation choice for `read_cell()`'s performance, not
#' a rule anything depends on: consumers key rows by `name`/`file`, not
#' position). `line`/`col`/`end_col` are the exact token's own position (1-
#' based, as `getParseData()` counts columns); a sourced file's rows carry
#' positions within that file, not the cell that sourced it. When the
#' walker can't line up an exact token for a row (a shape its position
#' matcher doesn't recognize), `col` and `end_col` are `NA` and `line`
#' falls back to the first line of the enclosing top-level expression, as
#' R's srcref gives it. A name is never both a formula column and a
#' reference from the same formula.
new_cell_analysis <- function(code,
                              parse_error = NULL,
                              definitions = empty_definitions(),
                              references = empty_references(),
                              packages = empty_packages(),
                              settings = empty_settings(),
                              formulas = list(),
                              sourced = empty_sourced(),
                              notes = empty_notes(),
                              methods = empty_methods()) {
  structure(list(code = code, parse_error = parse_error,
                 definitions = definitions, references = references,
                 packages = packages, settings = settings,
                 formulas = formulas, sourced = sourced, notes = notes,
                 methods = methods),
            class = "ember_cell_analysis")
}

empty_definitions <- function() {
  data.frame(name = character(), line = integer(), col = integer(),
             end_col = integer(), kind = character(),
             file = character(), stringsAsFactors = FALSE)
}
empty_references <- function() {
  data.frame(name = character(), line = integer(), col = integer(),
             end_col = integer(), where = character(),
             file = character(), stringsAsFactors = FALSE)
}
empty_packages <- function() {
  data.frame(name = character(), attached = logical(), line = integer(),
             stringsAsFactors = FALSE)
}
empty_settings <- function() {
  data.frame(fn = character(), setting = character(), line = integer(), col = integer(),
             end_col = integer(), stringsAsFactors = FALSE)
}
empty_sourced <- function() {
  data.frame(path = character(), text = character(), found = logical(),
             stringsAsFactors = FALSE)
}
empty_methods <- function() {
  data.frame(generic = character(), signature = character(), form = character(),
             line = integer(), col = integer(), end_col = integer(),
             file = character(), stringsAsFactors = FALSE)
}
empty_notes <- function() {
  data.frame(kind = character(), line = integer(), col = integer(),
             end_col = integer(), detail = character(),
             stringsAsFactors = FALSE)
}

#' One formula read with the column rule.
#'
#' `fn` is the enclosing call's head (`"lm"`, `"glm"`, `"mgcv::gam"`),
#' `data` the deparsed `data` argument, `columns` the names taken as
#' columns. `index` is the position of the top-level expression in the
#' cell and `line`/`col`/`end_col` the position of the formula's own `~`
#' token (`col`/`end_col` are `NA` when that token couldn't be matched; see
#' "Exact positions" above `read_cell()`). The worker matches the call by
#' `fn` and evaluates `data` in the global environment after the cell ran,
#' then reports which `columns` are not in `names()` of that value; the
#' graph turns those into references through `graph_learn()`.
formula_site <- function(index, line, fn, data, columns,
                          col = NA_integer_, end_col = NA_integer_) {
  structure(list(index = index, line = line, col = col, end_col = end_col,
                 fn = fn, data = data, columns = columns),
            class = "ember_formula_site")
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
                              parse_error = parse_error_from_condition(exprs, code)))
  }
  acc <- new_accumulator(read_file, file, stack)
  raw_pd <- getParseData(exprs)
  acc$pd <- build_pd_index(if (is.null(raw_pd)) data.frame() else raw_pd)
  # The `parent == 0` rows, already sorted by source position by
  # `build_pd_index()`: these correspond 1:1 with `exprs[[i]]`, since both
  # list every top-level expression in the order it appears in the file.
  # Index 1 (parent 0, offset by 1; see `build_pd_index()`).
  top_pids <- if (length(acc$pd$children) >= 1) acc$pd$children[[1]] else NULL
  if (is.null(top_pids) || length(top_pids) != length(exprs)) {
    top_pids <- rep(NA_integer_, length(exprs))
  }
  top <- top_scope(acc)
  for (i in seq_along(exprs)) {
    acc$index <- i
    acc$line <- expression_line(exprs, i)
    walk_expr(exprs[[i]], top, acc, top_pids[i])
  }
  finish(acc, code)
}

parse_error_from_condition <- function(cond, code) {
  msg <- conditionMessage(cond)
  first_line <- strsplit(msg, "\n", fixed = TRUE)[[1]][1]
  m <- regmatches(first_line,
                   regexec("^<text>:([0-9]+):([0-9]+): (.*)$", first_line))[[1]]
  if (length(m) == 4) {
    # "unexpected end of input" is reported on the line after a trailing
    # newline, which the cell doesn't show.
    n_lines <- max(1L, length(strsplit(sub("\n+$", "", code), "\n")[[1]]))
    list(message = m[4], line = min(as.integer(m[2]), n_lines),
         column = as.integer(m[3]))
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

#' Source-order line of a top-level expression.
expression_line <- function(exprs, i) {
  srcref <- attr(exprs, "srcref")[[i]]
  as.integer(srcref[1])
}

# ---- Finishing ---------------------------------------------------------------

#' Turn the accumulator into an `ember_cell_analysis`: build each field's
#' data frame once from its accumulated rows (plus any whole frames merged
#' in from `source()`d files), fold the deferred function-body reads in
#' (dropping any the cell defines anywhere at its own top level), drop
#' ignored names, and de-duplicate.
finish <- function(acc, code) {
  own_defs <- def_rows_to_df(rows_list(acc$def_rows))
  defs <- rbind_all(own_defs, acc$extra_defs)
  row.names(defs) <- NULL
  def_names <- if (nrow(defs) > 0) unique(defs$name) else character()

  deferred_df <- deferred_to_df(acc$deferred)
  if (nrow(deferred_df) > 0) {
    deferred_df <- deferred_df[!(deferred_df$name %in% def_names), , drop = FALSE]
  }

  refs <- rbind_all(ref_rows_to_df(rows_list(acc$ref_rows)), acc$extra_refs)
  refs <- rbind(refs, deferred_df)
  if (nrow(refs) > 0) {
    refs <- refs[!vapply(refs$name, is_ignored, logical(1)), , drop = FALSE]
  }
  if (nrow(refs) > 0) {
    # Deduplicated on position, not just name/line: a name read twice on
    # the same line at different columns is two distinct rows, since each
    # occurrence is a separate go-to-definition/highlight target.
    refs <- refs[!duplicated(refs[c("name", "line", "col", "where", "file")]), , drop = FALSE]
    refs <- refs[order(refs$line), , drop = FALSE]
  }
  row.names(refs) <- NULL

  pkgs <- rbind_all(pkg_rows_to_df(acc$pkg_rows), acc$extra_pkgs)
  if (nrow(pkgs) > 0) pkgs <- pkgs[!duplicated(pkgs[c("name", "line")]), , drop = FALSE]
  row.names(pkgs) <- NULL

  settings <- rbind_all(setting_rows_to_df(acc$setting_rows), acc$extra_settings)
  if (nrow(settings) > 0) settings <- settings[!duplicated(settings[c("fn", "setting", "line", "col")]), , drop = FALSE]
  row.names(settings) <- NULL

  sourced <- rbind_all(sourced_rows_to_df(acc$sourced_rows), acc$extra_sourced)
  row.names(sourced) <- NULL

  notes <- rbind_all(note_rows_to_df(acc$note_rows), acc$extra_notes)
  row.names(notes) <- NULL

  # A sourced file's name-form methods come in with `extra_methods`, so only
  # this level's own definitions are split here.
  methods <- rbind(name_method_rows(own_defs), method_rows_to_df(acc$method_rows))
  methods <- methods[order(methods$line), , drop = FALSE]
  methods <- rbind_all(methods, acc$extra_methods)
  row.names(methods) <- NULL

  new_cell_analysis(code, parse_error = NULL, definitions = defs,
                     references = refs, packages = pkgs, settings = settings,
                     formulas = acc$formulas, sourced = sourced, notes = notes,
                     methods = methods)
}

#' The `"name"`-form method rows of a cell's own definitions: each
#' top-level function (kind `"function"`) with a public name that has a
#' dot, once per dot with a non-empty part on each side. Whether the
#' prefix is really a generic needs the whole notebook; see
#' `resolve_methods()`.
name_method_rows <- function(defs) {
  defs <- defs[defs$kind == "function" & !is_private_name(defs$name) &
                 grepl(".", defs$name, fixed = TRUE), , drop = FALSE]
  if (nrow(defs) == 0) return(empty_methods())
  rows <- lapply(seq_len(nrow(defs)), function(i) {
    n <- defs$name[i]
    dots <- gregexpr(".", n, fixed = TRUE)[[1]]
    dots <- dots[dots > 1 & dots < nchar(n)]
    if (length(dots) == 0) return(NULL)
    data.frame(generic = substring(n, 1, dots - 1), signature = substring(n, dots + 1),
               form = "name", line = defs$line[i], col = defs$col[i],
               end_col = defs$end_col[i], file = defs$file[i], stringsAsFactors = FALSE)
  })
  rows <- Filter(Negate(is.null), rows)
  if (length(rows) == 0) return(empty_methods())
  do.call(rbind, rows)
}

method_rows_to_df <- function(rows) {
  if (length(rows) == 0) return(empty_methods())
  data.frame(
    generic = vapply(rows, `[[`, character(1), "generic"),
    signature = vapply(rows, `[[`, character(1), "signature"),
    form = vapply(rows, `[[`, character(1), "form"),
    line = vapply(rows, function(r) as.integer(r$line), integer(1)),
    col = vapply(rows, function(r) as.integer(r$col), integer(1)),
    end_col = vapply(rows, function(r) as.integer(r$end_col), integer(1)),
    file = vapply(rows, function(r) as.character(r$file), character(1)),
    stringsAsFactors = FALSE
  )
}

#' Combine a data frame built from this level's own rows with any whole
#' frames merged in from `source()`d files. A single `rbind` call over
#' every piece at once, not one call per row.
rbind_all <- function(base, extra_list) {
  extra_list <- Filter(function(d) !is.null(d) && nrow(d) > 0, extra_list)
  if (length(extra_list) == 0) return(base)
  do.call(rbind, c(list(base), extra_list))
}

#' A field that may be `NA_integer_` on some rows still needs a plain
#' `vapply(..., integer(1), ...)` to work: `[[` on a list element that is
#' itself `NA_integer_` returns it unchanged, so this is only about
#' documenting the intent, not a real edge case to guard.
def_rows_to_df <- function(rows) {
  if (length(rows) == 0) return(empty_definitions())
  data.frame(
    name = vapply(rows, `[[`, character(1), "name"),
    line = vapply(rows, `[[`, integer(1), "line"),
    col = vapply(rows, `[[`, integer(1), "col"),
    end_col = vapply(rows, `[[`, integer(1), "end_col"),
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
    col = vapply(rows, `[[`, integer(1), "col"),
    end_col = vapply(rows, `[[`, integer(1), "end_col"),
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
    setting = vapply(rows, `[[`, character(1), "setting"),
    line = vapply(rows, `[[`, integer(1), "line"),
    col = vapply(rows, `[[`, integer(1), "col"),
    end_col = vapply(rows, `[[`, integer(1), "end_col"),
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
    col = vapply(rows, `[[`, integer(1), "col"),
    end_col = vapply(rows, `[[`, integer(1), "end_col"),
    detail = vapply(rows, `[[`, character(1), "detail"),
    stringsAsFactors = FALSE
  )
}

deferred_to_df <- function(deferred) {
  if (length(deferred) == 0) return(empty_references())
  data.frame(
    name = vapply(deferred, `[[`, character(1), "name"),
    line = vapply(deferred, `[[`, integer(1), "line"),
    col = vapply(deferred, `[[`, integer(1), "col"),
    end_col = vapply(deferred, `[[`, integer(1), "end_col"),
    where = vapply(deferred, `[[`, character(1), "where"),
    file = vapply(deferred, function(x) if (is.null(x$file) || is.na(x$file)) NA_character_ else x$file, character(1)),
    stringsAsFactors = FALSE
  )
}
