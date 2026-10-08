# The notebook file: parse the text into an `ember_notebook_file` and
# format one back into text. Both pure; the shell does the reading and
# writing. A file Ember wrote round-trips byte for byte:
# `format_notebook(parse_notebook(text)) == text`.
#
# Layout of a file (design.md, File format):
#
#   ### An Ember notebook ###
#   # /// environment
#   # ember_version = "0.1.0"
#   # r_version = "4.6.1"
#   # snapshot = "2026-09-01"
#   # bioc_version = "3.22"          (only when set)
#   # on_cell_change = "lazy"        (only when lazy)
#   # [sources]                      (only when non-empty)
#   # mypkg = "github:lab/mypkg@3f2a1c9"
#   # [extra_packages]               (only when non-empty)
#   # svglite
#   # ///
#   <blank>
#   # %% id=<uuid>
#   <code lines>
#   <blank>
#   # %% id=<uuid>
#   #' <text lines>                  (kind is read from the code: all #' lines is text)
#   <blank>
#   ...                              (cells in run order)
#   # /// cell order                 (display order, "folded" after an id)
#   # ///
#   # /// sourced files              (only when non-empty)
#   # /// learned definitions        (only when non-empty)
#   # /// learned settings           (only when non-empty)
#   # /// lock                       (only when non-empty)
#   # /// <unknown block>            (kept verbatim, in the order read)
#
# An older Ember marked a setup cell `[setup]` on its marker line. The tag
# is read and ignored, and the next save drops it: the setup cell is gone
# and that cell is an ordinary one (settings-cells.md, Old notebooks).

# ---- Types -------------------------------------------------------------------

#' The parsed file.
#'
#' * `header`: `ember_header`.
#' * `cells`: named list id -> `list(code, kind, folded, disabled)` in
#'   display order.
#' * `run_order`: ids in the order they appear in the file (the run order
#'   when Ember wrote it). Informational: the graph recomputes the order.
#' * `learned`: named list id -> character, from "learned definitions".
#' * `learned_settings`: named list id -> character setting keys, from
#'   "learned settings".
#' * `sourced`: data frame `path`, `hash`.
#' * `commented`: character ids written with `## ` before each line because
#'   they are off (a dependent of a disabled cell), as read from the
#'   footer. Recomputed on every save; a disabled cell is not included
#'   here (it is marked `disabled` instead).
#' * `lock`: `ember_lock` (lock.R), parsed from the lock block's lines.
#'   `format_lock_lines()` turns it back into the block's lines.
#' * `extra_blocks`: named list block name -> character lines, verbatim.
#' * `format`: integer format number the text was in (before conversion).
#' * `read_only`: `TRUE` when `header$ember_version` is newer than this
#'   Ember.
#' * `problems`: data frame `kind`, `detail`: what was repaired. Kinds:
#'   `"no_header"`, `"no_header_close"`, `"no_footer"`, `"duplicate_id"`,
#'   `"bad_id"`, `"unknown_order_id"`, `"duplicate_order_id"`,
#'   `"cell_missing_from_order"`,
#'   `"text_before_first_cell"`, `"newer_version"`, `"converted"`,
#'   `"uncommented_line"`, `"disabled_text_cell"`.
new_notebook_file <- function(header, cells, run_order, learned,
                              sourced, lock, extra_blocks, format,
                              read_only = FALSE, problems = NULL,
                              commented = character(),
                              learned_settings = list()) {
  structure(list(header = header, cells = cells,
                 run_order = run_order, learned = learned,
                 learned_settings = learned_settings, sourced = sourced,
                 lock = lock, extra_blocks = extra_blocks, format = format,
                 read_only = read_only, problems = problems,
                 commented = commented),
            class = "ember_notebook_file")
}

#' The `/// environment` block.
#'
#' `ember_version`, `r_version`, `snapshot` (character, `NA` when absent),
#' `bioc_version` (`NA` when absent), `on_cell_change` (`"autorun"` or
#' `"lazy"`; written only when `"lazy"`, after `bioc_version`), `sources` (named character: package
#' -> source string), `extra_packages` (character), `extra` (character:
#' lines with keys this Ember doesn't know, kept in order and written back
#' after the known keys).
new_header <- function(ember_version, r_version, snapshot,
                       bioc_version = NA_character_,
                       on_cell_change = "autorun",
                       sources = character(), extra_packages = character(),
                       extra = character()) {
  structure(list(ember_version = ember_version, r_version = r_version,
                 snapshot = snapshot, bioc_version = bioc_version,
                 on_cell_change = on_cell_change, sources = sources, extra_packages = extra_packages,
                 extra = extra), class = "ember_header")
}

# ---- Versions ----------------------------------------------------------------

#' The current format number. Raised only when the text layout changes,
#' not on every Ember release.
ember_format <- 1L

#' Which format each Ember version wrote: the first version of each format.
#' `format_of(v)` is the last row with `since <= v`.
format_history <- data.frame(since = "0.1.0", format = 1L)

#' Text converters, `converters[[k]]` turns format k text into format k+1
#' text. Empty while there is one format. Each is tested against example
#' files saved by an Ember of format k (tests/testthat/files/format-k/).
converters <- list()

#' Version policy, applied by `parse_notebook()`:
#'
#' * no `ember_version`: a file Ember didn't write; parse as the current
#'   format, note `"no_header"`.
#' * `ember_version` newer than this Ember (`packageVersion("ember")`):
#'   parse with the current parser as far as it goes and set `read_only`;
#'   the file may follow rules this Ember doesn't know (design.md).
#' * older format: run `converters[[format]]`, ... up to `ember_format` on
#'   the text, then parse; note `"converted"`. Nothing is written until the
#'   next save, which writes the current format.
#' * same format, older or equal version: parse as is.
format_of <- function(version) {
  v <- numeric_version(as.character(version))
  sinces <- numeric_version(format_history$since)
  ok <- sinces <= v
  if (!any(ok)) return(format_history$format[[1]])
  # `order()`, not `which.max()`: the latter takes a numeric_version only
  # from R 4.4.
  format_history$format[ok][[order(sinces[ok], decreasing = TRUE)[[1]]]]
}

# ---- TOML strings --------------------------------------------------------------

#' TOML basic string, for header values and odd paths.
toml_string <- function(x) {
  paste0("\"", gsub("\"", "\\\\\"", gsub("\\\\", "\\\\\\\\", x)), "\"")
}

#' Reverse of `toml_string()`: `raw` includes the surrounding quotes.
toml_unquote <- function(raw) {
  inner <- substr(raw, 2, nchar(raw) - 1)
  chars <- strsplit(inner, "", fixed = TRUE)[[1]]
  out <- character(0)
  i <- 1
  n <- length(chars)
  while (i <= n) {
    ch <- chars[[i]]
    if (ch == "\\" && i < n && chars[[i + 1]] %in% c("\"", "\\")) {
      out <- c(out, chars[[i + 1]])
      i <- i + 2
    } else {
      out <- c(out, ch)
      i <- i + 1
    }
  }
  paste(out, collapse = "")
}

# ---- Parse -------------------------------------------------------------------

#' Build an empty-footer problems accumulator: a list of `list(kind, detail)`.
new_problems <- function() list()

add_problem <- function(problems, kind, detail = NA_character_) {
  c(problems, list(list(kind = kind, detail = detail)))
}

problems_to_df <- function(problems) {
  if (length(problems) == 0) return(NULL)
  data.frame(kind = vapply(problems, `[[`, character(1), "kind"),
            detail = vapply(problems, function(p) as.character(p$detail), character(1)),
            stringsAsFactors = FALSE)
}

#' Strip one leading "# " (or a bare "#") from a footer/header body line.
strip_hash <- function(line) {
  if (startsWith(line, "# ")) return(substring(line, 3))
  if (identical(line, "#")) return("")
  line
}

#' Parse the `/// environment` header block, starting at `lines[[1]] ==
#' "### An Ember notebook ###"`. Returns `list(header, next_index, closed)`,
#' where `next_index` is the first body line after the closing "# ///" (or,
#' when the header was never closed, the line that ended it), and `closed`
#' is `FALSE` when the loop stopped without finding "# ///".
#'
#' A header with no closing line would otherwise read every following line,
#' including cell markers and footer blocks, as header content, silently
#' swallowing the rest of the file. The first cell marker (`"# %%"`) or the
#' opening of another block (`"# /// <name>"`, as opposed to the bare
#' closing `"# ///"`) ends the header instead, so the caller can note the
#' repair and parse the rest normally.
parse_header_block <- function(lines) {
  n <- length(lines)
  known <- list(ember_version = NA_character_, r_version = NA_character_,
               snapshot = NA_character_, bioc_version = NA_character_,
               on_cell_change = "autorun")
  sources <- character()
  extra_packages <- character()
  extra <- character()
  section <- "main"
  i <- 3L
  closed <- FALSE
  while (i <= n) {
    line <- lines[[i]]
    if (identical(line, "# ///")) { closed <- TRUE; break }
    if (grepl("^# %%", line) || grepl("^# /// .+$", line)) break
    content <- strip_hash(line)
    if (identical(content, "[sources]")) {
      section <- "sources"
      i <- i + 1L
      next
    }
    if (identical(content, "[extra_packages]")) {
      section <- "extra_packages"
      i <- i + 1L
      next
    }
    if (section == "extra_packages") {
      extra_packages <- c(extra_packages, content)
      i <- i + 1L
      next
    }
    m <- regmatches(content, regexec("^([^=]+) = (.*)$", content))[[1]]
    if (length(m) == 3) {
      key <- trimws(m[[2]])
      valraw <- m[[3]]
      val <- if (grepl('^".*"$', valraw)) toml_unquote(valraw) else valraw
      if (section == "sources") {
        sources[key] <- val
      } else if (key %in% names(known)) {
        known[[key]] <- val
      } else {
        extra <- c(extra, content)
      }
    } else {
      extra <- c(extra, content)
    }
    i <- i + 1L
  }
  header <- new_header(ember_version = known$ember_version, r_version = known$r_version,
                       snapshot = known$snapshot, bioc_version = known$bioc_version,
                       on_cell_change = known$on_cell_change, sources = sources,
                       extra_packages = extra_packages, extra = extra)
  next_index <- if (closed) i + 1L else min(i, n + 1L)
  list(header = header, next_index = next_index, closed = closed)
}

#' Drop trailing elements of `lines` that are blank.
drop_trailing_blank <- function(lines) {
  while (length(lines) > 0 && identical(trimws(lines[[length(lines)]]), "")) {
    lines <- lines[-length(lines)]
  }
  lines
}

#' Parse one line as a cell marker, or `NULL` if it isn't one.
#' Returns `list(id, tags)`, `id` `NA` when missing or empty.
parse_marker <- function(line) {
  if (!grepl("^# %%", line)) return(NULL)
  id <- NA_character_
  m <- regmatches(line, regexec("id=(\\S+)", line))[[1]]
  if (length(m) == 2 && nchar(m[[2]]) > 0) id <- m[[2]]
  tag_matches <- regmatches(line, gregexpr("\\[(markdown|setup)\\]", line))[[1]]
  tags <- gsub("\\[|\\]", "", tag_matches)
  list(id = id, tags = tags)
}

#' The default figure size (inches), used when a cell has no `#|` lines or
#' an invalid one.
FIGURE_DEFAULT <- list(width = 7.5, height = 5)

#' The figure size a cell asks for with Quarto's comment lines, in inches.
#' Only the run of `#|` lines at the top of the cell counts (Quarto's
#' rule; blank lines before it are skipped); a `#|` line further down is
#' an ordinary comment. Keys `fig-width`/`fig-height` and knitr's
#' `fig.width`/`fig.height`; other keys (`echo: false`, ...) are ignored.
#' Knitr's equals-sign form (`fig.width = 6`) isn't read as a size (only
#' Quarto's colon syntax is), but adds a problem naming the colon form to
#' use instead. A value may be quoted (`"6"`) and may carry a trailing
#' comment (`6 # wide`); a hex literal (`0x10`) is rejected even though
#' `as.numeric()` would parse it. A value must otherwise be a plain
#' number between 0.5 and 30; anything else uses the default for that
#' side and adds a problem sentence.
#' @return list(width = <dbl>, height = <dbl>, problems = <chr>)
cell_figure_size <- function(code) {
  lines <- strsplit(code, "\n", fixed = TRUE)[[1]]
  n <- length(lines)
  i <- 1L
  while (i <= n && !nzchar(trimws(lines[[i]]))) i <- i + 1L

  key_pattern <- "fig[-.](width|height)"
  out <- list(width = FIGURE_DEFAULT$width, height = FIGURE_DEFAULT$height,
             problems = character())
  while (i <= n && grepl("^#\\|", lines[[i]])) {
    line <- lines[[i]]
    m <- regmatches(line,
                    regexec(paste0("^#\\|\\s*(", key_pattern, ")\\s*:\\s*(.*?)\\s*$"),
                            line, perl = TRUE))[[1]]
    if (length(m) == 4) {
      side <- m[[3]]
      raw <- m[[4]]
      raw <- sub("\\s*#.*$", "", raw)                  # a trailing YAML-style comment
      if (grepl('^"[^"]*"$', raw) || grepl("^'[^']*'$", raw)) {
        raw <- substr(raw, 2, nchar(raw) - 1)           # a quoted number ("6")
      }
      raw <- trimws(raw)
      is_hex <- grepl("^[+-]?0[xX][0-9a-fA-F]+$", raw)  # rejected, not a plain number
      value <- if (is_hex) NA_real_ else suppressWarnings(as.numeric(raw))
      default_text <- format(FIGURE_DEFAULT[[side]], trim = TRUE)
      if (is.na(value)) {
        out$problems <- c(out$problems,
          sprintf("%s is not a number of inches; using %s.", trimws(line), default_text))
      } else if (value < 0.5 || value > 30) {
        out$problems <- c(out$problems,
          sprintf("%s must be between 0.5 and 30 inches; using %s.", trimws(line), default_text))
      } else {
        out[[side]] <- value
      }
    } else {
      # knitr's dot-key, equals-sign form ("fig.width = 6"): not read as a
      # figure size (Quarto's colon syntax is), but worth a problem rather
      # than silently falling through as an unrelated key.
      eq <- regmatches(line,
                       regexec(paste0("^#\\|\\s*(", key_pattern, ")\\s*=\\s*(.*?)\\s*$"),
                               line, perl = TRUE))[[1]]
      if (length(eq) == 4) {
        out$problems <- c(out$problems,
          sprintf("%s; use fig-%s: %s", trimws(line), eq[[3]], trimws(eq[[4]])))
      }
    }
    i <- i + 1L
  }
  out
}

#' Resolve the display order, fold state, and the `disabled`/`commented`
#' flags from the "cell order" footer block (or file order when there is
#' none). Words after the id are read as a set (`folded`, `disabled`,
#' `commented`); unknown words are still ignored.
resolve_order <- function(file_order, order_lines, problems) {
  if (is.null(order_lines)) {
    folded <- stats::setNames(rep(FALSE, length(file_order)), file_order)
    disabled <- stats::setNames(rep(FALSE, length(file_order)), file_order)
    commented <- stats::setNames(rep(FALSE, length(file_order)), file_order)
    return(list(order = file_order, folded = folded, disabled = disabled,
               commented = commented,
               problems = add_problem(problems, "no_footer")))
  }
  listed <- character()
  folded_v <- logical()
  disabled_v <- logical()
  commented_v <- logical()
  for (ln in order_lines) {
    parts <- strsplit(trimws(ln), "\\s+")[[1]]
    if (length(parts) == 0 || identical(parts[[1]], "")) next
    id <- parts[[1]]
    flags <- if (length(parts) > 1) parts[-1] else character()
    if (!(id %in% file_order)) {
      problems <- add_problem(problems, "unknown_order_id", id)
      next
    }
    if (id %in% listed) {
      problems <- add_problem(problems, "duplicate_order_id", id)
      next
    }
    listed <- c(listed, id)
    folded_v <- c(folded_v, "folded" %in% flags)
    disabled_v <- c(disabled_v, "disabled" %in% flags)
    commented_v <- c(commented_v, "commented" %in% flags)
  }
  names(folded_v) <- names(disabled_v) <- names(commented_v) <- listed
  result <- listed
  for (id in file_order) {
    if (id %in% result) next
    file_pos <- match(id, file_order)
    pred <- NULL
    if (file_pos > 1) {
      for (j in (file_pos - 1):1) {
        candidate <- file_order[[j]]
        if (candidate %in% result) { pred <- candidate; break }
      }
    }
    if (is.null(pred)) {
      result <- c(id, result)
    } else {
      result <- append(result, id, after = match(pred, result))
    }
    folded_v[id] <- FALSE
    disabled_v[id] <- FALSE
    commented_v[id] <- FALSE
    problems <- add_problem(problems, "cell_missing_from_order", id)
  }
  list(order = result, folded = folded_v[result], disabled = disabled_v[result],
      commented = commented_v[result], problems = problems)
}

#' Parse the "sourced files" footer block into a `path`, `hash` data frame.
parse_sourced_block <- function(lines) {
  if (length(lines) == 0) return(data.frame(path = character(), hash = character(),
                                            stringsAsFactors = FALSE))
  rows <- lapply(lines, function(ln) {
    trimmed <- trimws(ln)
    if (startsWith(trimmed, "\"")) {
      chars <- strsplit(trimmed, "", fixed = TRUE)[[1]]
      i <- 2L
      n <- length(chars)
      while (i <= n) {
        if (identical(chars[[i]], "\\")) { i <- i + 2L; next }
        if (identical(chars[[i]], "\"")) break
        i <- i + 1L
      }
      path <- toml_unquote(substr(trimmed, 1, i))
      hash <- trimws(substr(trimmed, i + 1, nchar(trimmed)))
    } else {
      idx <- regexpr("\\s+\\S+$", trimmed)
      hash <- trimws(regmatches(trimmed, idx))
      path <- trimws(sub("\\s+\\S+$", "", trimmed))
    }
    data.frame(path = path, hash = hash, stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}

#' Parse the "learned definitions" footer block, filtering to known ids.
parse_learned_block <- function(lines, known_ids) {
  learned <- list()
  for (ln in lines) {
    parts <- strsplit(trimws(ln), "\\s+")[[1]]
    if (length(parts) == 0 || identical(parts[[1]], "")) next
    id <- parts[[1]]
    if (!(id %in% known_ids)) next
    learned[[id]] <- parts[-1]
  }
  learned
}

#' Core structural parse: header, cells, footer blocks. Does not apply the
#' version policy (conversion / read-only); `parse_notebook()` wraps this.
parse_notebook_core <- function(text, new_id) {
  problems <- new_problems()
  lines <- strsplit(text, "\n", fixed = TRUE)[[1]]
  if (length(lines) == 0) lines <- character()

  has_header <- length(lines) >= 2 && identical(lines[[1]], "### An Ember notebook ###") &&
    identical(lines[[2]], "# /// environment")
  if (has_header) {
    parsed_header <- parse_header_block(lines)
    header <- parsed_header$header
    i <- parsed_header$next_index
    if (!parsed_header$closed) {
      problems <- add_problem(problems, "no_header_close")
    }
  } else {
    header <- new_header(ember_version = NA_character_, r_version = NA_character_,
                         snapshot = NA_character_)
    problems <- add_problem(problems, "no_header")
    i <- 1L
  }

  n <- length(lines)
  cells <- list()
  file_order <- character()
  footer_blocks <- list()

  cur_id <- NULL
  cur_tag_markdown <- FALSE
  cur_lines <- character()
  footer_name <- NULL
  footer_lines <- character()
  mode <- "none"
  leading_noted <- FALSE
  used_ids <- character()
  has_marker <- any(vapply(lines, function(l) !is.null(parse_marker(l)), logical(1)))

  # The raw lines are kept as read; whether they need un-commenting isn't
  # known until the footer (read later in the file) says which ids are
  # `disabled` or `commented`, so that pass happens after the whole file is
  # read, below. `tag_markdown` is only the marker's own `[markdown]` tag
  # (for reading an older Ember's file); a cell's real kind is always
  # `cell_kind()` of its code.
  flush_cell <- function() {
    if (!is.null(cur_id)) {
      cells[[cur_id]] <<- list(raw = cur_lines, tag_markdown = cur_tag_markdown,
                               folded = FALSE, disabled = FALSE)
      file_order <<- c(file_order, cur_id)
    }
  }
  flush_footer <- function() {
    if (!is.null(footer_name)) {
      footer_blocks[[footer_name]] <<- footer_lines
    }
  }

  while (i <= n) {
    line <- lines[[i]]
    marker <- parse_marker(line)
    is_footer_open <- grepl("^# /// (.+)$", line)
    is_footer_close <- identical(line, "# ///")

    if (!is.null(marker)) {
      if (mode == "cell") flush_cell()
      if (mode == "footer") flush_footer()
      id <- marker$id
      if (is.na(id) || !nchar(id)) {
        id <- new_id()
        problems <- add_problem(problems, "bad_id")
      } else if (id %in% used_ids) {
        problems <- add_problem(problems, "duplicate_id", id)
        id <- new_id()
      }
      used_ids <- c(used_ids, id)
      cur_id <- id
      cur_tag_markdown <- "markdown" %in% marker$tags
      cur_lines <- character()
      mode <- "cell"
    } else if (is_footer_open) {
      if (mode == "cell") flush_cell()
      if (mode == "footer") flush_footer()
      footer_name <- trimws(sub("^# /// (.+)$", "\\1", line))
      footer_lines <- character()
      mode <- "footer"
    } else if (is_footer_close && mode == "footer") {
      flush_footer()
      footer_name <- NULL
      footer_lines <- character()
      mode <- "none"
    } else if (mode == "cell") {
      cur_lines <- c(cur_lines, line)
    } else if (mode == "footer") {
      footer_lines <- c(footer_lines, strip_hash(line))
    } else {
      if (!identical(trimws(line), "")) {
        if (!leading_noted && has_marker) {
          problems <- add_problem(problems, "text_before_first_cell")
          leading_noted <- TRUE
        }
        id <- new_id()
        used_ids <- c(used_ids, id)
        cur_id <- id
        cur_tag_markdown <- FALSE
        cur_lines <- c(line)
        mode <- "cell"
      }
    }
    i <- i + 1L
  }
  if (mode == "cell") flush_cell()
  if (mode == "footer") flush_footer()

  order_block <- footer_blocks[["cell order"]]
  resolved <- resolve_order(file_order, order_block, problems)
  problems <- resolved$problems
  display_order <- resolved$order

  # Un-comment (disabled/commented) or repair a [markdown]-tagged cell's
  # lines into plain code text, for every cell; its kind is then
  # `cell_kind()` of the result, not the marker's own tag.
  codes <- list()
  tentative_disabled <- character()
  file_commented <- character()
  for (id in display_order) {
    raw <- cells[[id]]$raw
    is_disabled <- isTRUE(unname(resolved$disabled[id]))
    is_commented <- isTRUE(unname(resolved$commented[id]))

    if (isTRUE(cells[[id]]$tag_markdown)) {
      body <- drop_trailing_blank(raw)
      # A line without the `#'` prefix (an older Ember's own output used
      # one before every line; a hand edit might not) gets one added, so a
      # `[markdown]`-tagged cell can't come out mixed just from this repair.
      body <- vapply(body, function(l) {
        if (identical(trimws(l), "") || text_line(l)) l else paste0("#' ", l)
      }, character(1), USE.NAMES = FALSE)
      codes[[id]] <- paste(body, collapse = "\n")
      if (is_disabled) problems <- add_problem(problems, "disabled_text_cell", id)
      next
    }

    # The blank line separating this cell from the next is still a plain
    # blank line in `raw` (dropped here, before un-commenting): a disabled
    # cell's own trailing blank code line is written as a non-blank "##",
    # which only the second drop_trailing_blank() below (after
    # un-commenting) removes.
    body_lines <- drop_trailing_blank(raw)
    if (is_disabled || is_commented) {
      any_uncommented <- FALSE
      for (k in seq_along(body_lines)) {
        one <- body_lines[[k]]
        if (identical(one, "##")) {
          body_lines[[k]] <- ""
        } else if (startsWith(one, "## ")) {
          body_lines[[k]] <- substring(one, 4)
        } else {
          any_uncommented <- TRUE
        }
      }
      if (any_uncommented) problems <- add_problem(problems, "uncommented_line", id)
    }
    codes[[id]] <- paste(drop_trailing_blank(body_lines), collapse = "\n")
    if (is_disabled) tentative_disabled <- c(tentative_disabled, id)
    if (is_commented && !is_disabled) file_commented <- c(file_commented, id)
  }

  # A file with no cells gets one empty code cell: a notebook always has
  # at least one.
  if (length(display_order) == 0) {
    only <- new_id()
    codes[[only]] <- ""
    display_order <- only
  }

  for (id in display_order) {
    folded <- isTRUE(unname(resolved$folded[id]))
    disabled <- id %in% tentative_disabled
    code <- codes[[id]] %||% ""
    kind <- cell_kind(code)
    # A disabled cell whose un-commented code turns out to be only `#'`
    # lines (main's Ember once allowed disabling text; a hand edit can
    # still write it): the same repair as a `[markdown]`-tagged cell
    # marked disabled, since a text cell can't be disabled either way.
    if (disabled && identical(kind, "markdown")) {
      problems <- add_problem(problems, "disabled_text_cell", id)
      disabled <- FALSE
    }
    cells[[id]] <- list(code = code, kind = kind, folded = folded, disabled = disabled)
  }
  cells <- cells[display_order]

  sourced <- parse_sourced_block(footer_blocks[["sourced files"]])
  learned <- parse_learned_block(footer_blocks[["learned definitions"]], display_order)
  learned_settings <- parse_learned_block(footer_blocks[["learned settings"]], display_order)
  lock_lines <- footer_blocks[["lock"]]
  if (is.null(lock_lines)) lock_lines <- character()
  lock <- parse_lock_lines(lock_lines)$lock

  known_footer <- c("cell order", "sourced files", "learned definitions",
                    "learned settings", "lock")
  extra_names <- setdiff(names(footer_blocks), known_footer)
  extra_blocks <- footer_blocks[extra_names]

  list(header = header, cells = cells, run_order = file_order,
      learned = learned, learned_settings = learned_settings,
      sourced = sourced, lock = lock,
      extra_blocks = extra_blocks, problems = problems, commented = file_commented)
}

#' Parse notebook text.
#'
#' Never fails on a readable text file: every irregularity becomes a repair
#' and a row in `problems`, so any `.R` file opens.
#'
#' @param text One string, the whole file (UTF-8). `\r\n` is read as `\n`.
#' @param new_id Function of no arguments returning a fresh UUID, for cells
#'   without a usable id. Injected so parsing stays deterministic in tests.
#' @param version This Ember's version (for the read-only check).
parse_notebook <- function(text, new_id, version = utils::packageVersion("ember")) {
  text <- gsub("\r\n", "\n", text, fixed = TRUE)
  parsed <- parse_notebook_core(text, new_id)
  problems <- parsed$problems
  ever <- parsed$header$ember_version
  read_only <- FALSE
  file_format <- ember_format

  if (!is.na(ever)) {
    if (numeric_version(ever) > numeric_version(as.character(version))) {
      read_only <- TRUE
      file_format <- ember_format
      problems <- add_problem(problems, "newer_version", ever)
    } else {
      fmt <- format_of(ever)
      if (fmt < ember_format) {
        conv_text <- text
        for (k in fmt:(ember_format - 1L)) conv_text <- converters[[k]](conv_text)
        parsed <- parse_notebook_core(conv_text, new_id)
        problems <- add_problem(parsed$problems, "converted", paste0(fmt, " -> ", ember_format))
      }
      file_format <- fmt
    }
  }

  new_notebook_file(header = parsed$header, cells = parsed$cells,
                    run_order = parsed$run_order, learned = parsed$learned,
                    learned_settings = parsed$learned_settings,
                    sourced = parsed$sourced, lock = parsed$lock,
                    extra_blocks = parsed$extra_blocks, format = file_format,
                    read_only = read_only, problems = problems_to_df(problems),
                    commented = parsed$commented)
}

# ---- Format ------------------------------------------------------------------

#' Format a parsed file as text: the canonical layout above.
#'
#' Cells are written in `order` (the graph's run order, which keeps
#' display order wherever edges allow, so small edits don't reshuffle the
#' file). Every line ends in "\n"; one blank line separates blocks.
#'
#' Byte stability holds because every choice is canonical: fixed key order
#' in the header, one blank line between cells, code stored without
#' trailing blank lines (normalised on edit and on parse), footer blocks in
#' a fixed order followed by extra blocks in the order read.
#'
#' @param file An `ember_notebook_file`.
#' @param order Ids in run order; `NULL` uses `file$run_order`.
format_notebook <- function(file, order = NULL) {
  if (is.null(order)) order <- file$run_order

  header <- file$header
  header_lines <- c("### An Ember notebook ###", "# /// environment")
  for (key in c("ember_version", "r_version", "snapshot", "bioc_version")) {
    if (!is.na(header[[key]])) {
      header_lines <- c(header_lines, paste0("# ", key, " = ", toml_string(header[[key]])))
    }
  }
  if (identical(header$on_cell_change, "lazy")) {
    header_lines <- c(header_lines, paste0("# on_cell_change = ", toml_string("lazy")))
  }
  if (length(header$extra) > 0) {
    header_lines <- c(header_lines, paste0("# ", header$extra))
  }
  if (length(header$sources) > 0) {
    header_lines <- c(header_lines, "# [sources]",
                      paste0("# ", names(header$sources), " = ",
                            vapply(header$sources, toml_string, character(1))))
  }
  if (length(header$extra_packages) > 0) {
    header_lines <- c(header_lines, "# [extra_packages]",
                      paste0("# ", header$extra_packages))
  }
  header_lines <- c(header_lines, "# ///")

  cell_block_lines <- function(id) {
    cell <- file$cells[[id]]
    marker <- paste0("# %% id=", id)
    body <- if (identical(cell$code, "")) character(0) else strsplit(cell$code, "\n", fixed = TRUE)[[1]]
    # A text cell's code already carries its `#'` prefixes (they are the
    # text, not added here); only a code cell is ever commented out.
    comment_out <- !identical(cell$kind, "markdown") &&
      (isTRUE(cell$disabled) || (id %in% file$commented))
    content <- if (comment_out) {
      vapply(body, function(l) if (identical(l, "")) "##" else paste0("## ", l), character(1))
    } else {
      body
    }
    c(marker, content)
  }

  display_order <- names(file$cells)
  cell_order_lines <- vapply(display_order, function(id) {
    flags <- character()
    if (isTRUE(file$cells[[id]]$folded)) flags <- c(flags, "folded")
    if (isTRUE(file$cells[[id]]$disabled)) {
      flags <- c(flags, "disabled")
    } else if (id %in% file$commented) {
      flags <- c(flags, "commented")
    }
    if (length(flags) == 0) paste0("# ", id) else paste0("# ", id, " ", paste(flags, collapse = " "))
  }, character(1), USE.NAMES = FALSE)
  footer <- c("# /// cell order", cell_order_lines, "# ///")

  sourced <- file$sourced
  if (!is.null(sourced) && nrow(sourced) > 0) {
    lines <- vapply(seq_len(nrow(sourced)), function(i) {
      p <- sourced$path[[i]]
      p_fmt <- if (grepl("[ \"\\\\]", p)) toml_string(p) else p
      paste0("# ", p_fmt, " ", sourced$hash[[i]])
    }, character(1))
    footer <- c(footer, "# /// sourced files", lines, "# ///")
  }

  if (length(file$learned) > 0) {
    lines <- vapply(names(file$learned), function(id) {
      paste0("# ", paste(c(id, file$learned[[id]]), collapse = " "))
    }, character(1))
    footer <- c(footer, "# /// learned definitions", lines, "# ///")
  }

  if (length(file$learned_settings) > 0) {
    lines <- vapply(names(file$learned_settings), function(id) {
      paste0("# ", paste(c(id, file$learned_settings[[id]]), collapse = " "))
    }, character(1))
    footer <- c(footer, "# /// learned settings", lines, "# ///")
  }

  lock_lines <- format_lock_lines(file$lock)
  if (length(lock_lines) > 0) {
    footer <- c(footer, "# /// lock", paste0("# ", lock_lines), "# ///")
  }

  for (nm in names(file$extra_blocks)) {
    footer <- c(footer, paste0("# /// ", nm), paste0("# ", file$extra_blocks[[nm]]), "# ///")
  }

  blocks <- c(list(header_lines), lapply(order, cell_block_lines), list(footer))
  all_lines <- blocks[[1]]
  for (b in blocks[-1]) all_lines <- c(all_lines, "", b)
  paste0(paste(all_lines, collapse = "\n"), "\n")
}
