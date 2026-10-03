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

#' "markdown" when not the setup cell, at least one line is non-blank, and
#' every non-blank line is a text line. Otherwise "code". A mixed cell is
#' "code", so it stays a graph node and gets the mixed_text graph error.
#' `#|` lines (piece 3) count as code lines: they never start with `#'`.
cell_kind <- function(code, setup = FALSE) {
  if (isTRUE(setup)) return("code")
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

#' The inline expressions of a text cell, in reading order:
#' `data.frame(line = <int, line in the cell>, expr = <chr>)`. Matched on
#' text lines only, with knitr's pattern (knitr 1.52, all_patterns$md$inline.code):
#' `"(?<!(^``))(?<!(\n``))`r[ #]([^`]+)\\s*`"`. An expression can't span
#' lines: each `#'` line is matched on its own.
inline_spans <- function(code) {
  lines <- strsplit(code, "\n", fixed = TRUE)[[1]]
  if (length(lines) == 0) return(data.frame(line = integer(), expr = character(), stringsAsFactors = FALSE))
  pattern <- "(?<!(^``))(?<!(\\n``))`r[ #]([^`]+)\\s*`"
  out_line <- integer()
  out_expr <- character()
  for (i in seq_along(lines)) {
    ln <- lines[[i]]
    if (!text_line(ln)) next
    m <- gregexpr(pattern, ln, perl = TRUE)[[1]]
    if (m[[1]] == -1) next
    matched <- regmatches(ln, gregexpr(pattern, ln, perl = TRUE))[[1]]
    for (one in matched) {
      expr <- sub("^`r[ #]", "", one)
      expr <- sub("`$", "", expr)
      expr <- trimws(expr)
      out_line <- c(out_line, i)
      out_expr <- c(out_expr, expr)
    }
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

#' `TRUE` when the commonmark package can be used to render markdown. A
#' `Suggests` dependency, not `Imports`: the server runs without it.
commonmark_available <- function() requireNamespace("commonmark", quietly = TRUE)

#' Markdown to HTML with commonmark, or escaped `<pre>` text without it. The
#' one renderer for text cells and function docs.
render_markdown <- function(text) {
  text <- text %||% ""
  if (commonmark_available()) return(commonmark::markdown_html(text))
  sprintf("<pre>%s</pre>", html_escape(text))
}
