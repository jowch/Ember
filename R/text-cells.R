# A cell's kind, worked out from its code (ui-3.md): `#'` lines are text,
# anything else is code. Pure; no cell ever stores its own kind as
# anything but the result of `cell_kind()` on its current code.

#' A text line is knitr::spin's text line: `#'`, `##'`, ... at column 1
#' (spin's default `doc = "^#+'[ ]?"`).
text_line <- function(lines) grepl("^#+'", lines)

#' Non-blank lines of `code`, split on "\n".
nonblank_lines <- function(code) {
  lines <- strsplit(code, "\n", fixed = TRUE)[[1]]
  lines[!grepl("^\\s*$", lines)]
}

#' "markdown" when at least one line is non-blank and every non-blank line
#' is a text line. Otherwise "code". A mixed cell is
#' "code", so it stays a graph node and gets the mixed_text graph error.
#' `#|` lines (cell options) count as code lines: they never start with `#'`.
cell_kind <- function(code) {
  nb <- nonblank_lines(code)
  if (length(nb) == 0) return("code")
  if (all(text_line(nb))) "markdown" else "code"
}

#' TRUE when some lines are text lines and some other non-blank lines are
#' not: a cell mixing `#'` lines and code (ui-3.md decides this is always an
#' error, never a hybrid cell -- including a roxygen-style block above a
#' function).
is_mixed <- function(code) {
  nb <- nonblank_lines(code)
  if (length(nb) == 0) return(FALSE)
  tl <- text_line(nb)
  any(tl) && !all(tl)
}

#' The cell split at each change between text and code: a character vector
#' of codes. Blank lines go with the run of lines before them; blank lines
#' at the start or end of a piece are dropped.
split_mixed <- function(code) {
  lines <- strsplit(code, "\n", fixed = TRUE)[[1]]
  if (length(lines) == 0) return(character())
  is_blank <- grepl("^\\s*$", lines)
  is_text <- text_line(lines)

  group <- integer(length(lines))
  cur <- 0L
  last_kind <- NA
  for (i in seq_along(lines)) {
    if (is_blank[[i]]) {
      group[[i]] <- cur
    } else {
      kind <- is_text[[i]]
      if (!identical(kind, last_kind)) {
        cur <- cur + 1L
        last_kind <- kind
      }
      group[[i]] <- cur
    }
  }

  if (cur == 0L) return(character())
  vapply(seq_len(cur), function(g) {
    piece <- lines[group == g]
    piece <- drop_trailing_blank(piece)
    while (length(piece) > 0 && identical(trimws(piece[[1]]), "")) piece <- piece[-1]
    paste(piece, collapse = "\n")
  }, character(1))
}

#' knitr's inline-code pattern (knitr 1.52, `all_patterns$md$inline.code`).
#' Applied one line at a time everywhere it's used: an expression can't
#' span lines, so this is never run against more than one line.
inline_span_pattern <- "(?<!(^``))(?<!(\\n``))`r[ #]([^`]+)\\s*`"

#' Every `` `r expr` `` span on one line (already known to be a text
#' line), as `list(starts, lengths, exprs)` (all parallel, left to right;
#' `starts`/`lengths` are 1-based character offsets into `line`, for
#' splicing in a replacement). Empty lists when there are none. The one
#' primitive `inline_spans()` (reading) and `project_text()`
#' (pluto-state.R, substituting a span for a token) both build on, so a
#' substitution never touches more of the line than a read would ever
#' say was a span -- unlike matching `inline_span_pattern` against a
#' whole multi-line body at once, where `[^`]+` can cross a line break
#' `inline_spans()` would never let it cross.
line_inline_matches <- function(line) {
  none <- list(starts = integer(), lengths = integer(), exprs = character())
  m <- gregexpr(inline_span_pattern, line, perl = TRUE)[[1]]
  if (length(m) == 1 && m[[1]] == -1) return(none)
  lens <- attr(m, "match.length")
  matched <- regmatches(line, list(m))[[1]]
  exprs <- vapply(matched, function(one) {
    expr <- sub("^`r[ #]", "", one)
    expr <- sub("`$", "", expr)
    trimws(expr)
  }, character(1), USE.NAMES = FALSE)
  list(starts = as.integer(m), lengths = as.integer(lens), exprs = exprs)
}

#' `line` with each of its inline spans (in order) replaced by the
#' matching element of `replacements` (same length as
#' `line_inline_matches(line)$exprs`). Splices right to left so earlier
#' offsets stay valid as the line's length changes.
replace_inline_matches <- function(line, replacements) {
  mm <- line_inline_matches(line)
  if (length(mm$starts) == 0) return(line)
  for (k in rev(seq_along(mm$starts))) {
    s <- mm$starts[[k]]
    e <- s + mm$lengths[[k]] - 1L
    line <- paste0(substr(line, 1, s - 1L), replacements[[k]], substr(line, e + 1L, nchar(line)))
  }
  line
}

#' The inline expressions of a text cell, in reading order:
#' `data.frame(line = <int, line in the cell>, expr = <chr>)`. Matched on
#' text lines only, via `line_inline_matches()`.
inline_spans <- function(code) {
  lines <- strsplit(code, "\n", fixed = TRUE)[[1]]
  if (length(lines) == 0) return(data.frame(line = integer(), expr = character(), stringsAsFactors = FALSE))
  out_line <- integer()
  out_expr <- character()
  for (i in seq_along(lines)) {
    if (!text_line(lines[[i]])) next
    mm <- line_inline_matches(lines[[i]])
    if (length(mm$exprs) == 0) next
    out_line <- c(out_line, rep(i, length(mm$exprs)))
    out_expr <- c(out_expr, mm$exprs)
  }
  data.frame(line = out_line, expr = out_expr, stringsAsFactors = FALSE)
}

#' One expression per line, joined with "\n": what the graph analyses and
#' what the worker runs. "" when there are none.
inline_code <- function(code) {
  spans <- inline_spans(code)
  if (nrow(spans) == 0) return("")
  paste(spans$expr, collapse = "\n")
}

#' TRUE when the cell runs in the worker: a code cell, or a text cell with
#' at least one inline expression.
cell_runs <- function(cell) {
  if (identical(cell$kind, "code")) return(TRUE)
  nrow(inline_spans(cell$code)) > 0
}

#' The markdown body: each text line with `^#+'[ ]?` removed.
text_body <- function(code) {
  lines <- strsplit(code, "\n", fixed = TRUE)[[1]]
  vapply(lines, function(l) sub("^#+'[ ]?", "", l), character(1), USE.NAMES = FALSE)
}

#' Markdown to HTML with commonmark. The one renderer for text cells and
#' function docs.
render_markdown <- function(text) {
  commonmark::markdown_html(text %||% "")
}
