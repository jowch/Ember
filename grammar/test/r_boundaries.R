# Emits, for each file in the corpus manifest, R's own top-level
# expression boundaries (as character offsets into the UTF-8 text) so a
# Node script can compare them against the Lezer grammar's top-level
# statements. Run as:
#   Rscript --vanilla test/r_boundaries.R <manifest.csv> <corpus-root> <out.json>

args <- commandArgs(trailingOnly = TRUE)
manifest_path <- args[[1]]
corpus_root <- args[[2]]
out_path <- args[[3]]

m <- read.csv(manifest_path, stringsAsFactors = FALSE)

# R's getParseData() reports 1-based (line, column) positions. Columns are
# counted in characters (verified against a UTF-8 file containing
# multibyte characters: nchar() of the line matches col2) -- EXCEPT that a
# tab does not count as one column: it advances the column to the next
# multiple of 8, the same way a terminal would render it (verified: a
# comment "#\tcomment" after 8 preceding columns gets col2 = 23, i.e. the
# tab consumed 8 columns, not 1). So per line we build a map from visual
# column to character index, expanding each tab's column range to all
# map to that one tab character.
col_to_char_map <- function(line) {
  chars <- strsplit(line, "", fixed = TRUE)[[1]]
  map <- integer(0)
  col <- 1
  for (i in seq_along(chars)) {
    if (chars[i] == "\t") {
      next_stop <- (((col - 1) %/% 8) + 1) * 8 + 1
      map[col:(next_stop - 1)] <- i
      col <- next_stop
    } else {
      map[col] <- i
      col <- col + 1
    }
  }
  map
}

# Character offset (0-based) of the first character of line `line`, i.e.
# the sum of (character count of) all preceding lines plus one newline
# character each.
line_starts <- function(lines) {
  n <- nchar(lines, type = "chars")
  cumsum(c(0, n + 1))
}

to_offset <- function(colmaps, starts, line, col) {
  starts[line] + (colmaps[[line]][col] - 1)
}

results <- vector("list", nrow(m))
names(results) <- m$id

for (i in seq_len(nrow(m))) {
  id <- m$id[i]
  path <- file.path(corpus_root, basename(m$file[i]))
  code <- tryCatch(
    paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n"),
    error = function(e) NA_character_
  )
  if (is.na(code)) {
    results[[id]] <- list(error = "read-failed")
    next
  }
  p <- tryCatch(parse(text = code, keep.source = TRUE), error = function(e) e)
  if (inherits(p, "error")) {
    results[[id]] <- list(error = conditionMessage(p))
    next
  }
  pd <- getParseData(p)
  # Exclude comments and bare ";" separators between statements, both of
  # which getParseData() records as their own parent == 0 rows but which
  # are not expressions.
  top <- pd[pd$parent == 0 & !pd$token %in% c("COMMENT", "';'"), , drop = FALSE]
  if (nrow(top) == 0) {
    results[[id]] <- list(error = NULL, boundaries = list())
    next
  }
  lines <- strsplit(code, "\n", fixed = TRUE)[[1]]
  starts <- line_starts(lines)
  colmaps <- lapply(lines, col_to_char_map)
  from <- mapply(to_offset, line = top$line1, col = top$col1,
                 MoreArgs = list(colmaps = colmaps, starts = starts))
  # End offset (exclusive): col2 is the column of the LAST character, so
  # the exclusive end is that character's 1-based index (not -1, since
  # that already equals "one past" the 0-based index).
  to <- starts[top$line2] + vapply(seq_len(nrow(top)), function(k) colmaps[[top$line2[k]]][top$col2[k]], numeric(1))
  ord <- order(from)
  results[[id]] <- list(error = NULL, boundaries = unname(Map(function(a, b) list(a, b), from[ord], to[ord])))
}

jsonlite::write_json(results, out_path, auto_unbox = TRUE, null = "null")
cat("wrote", out_path, "\n")
