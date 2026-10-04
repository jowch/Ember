# Tests for R/notebook.R: parse_notebook() / format_notebook() and the
# repairs that let any .R file open. See docs/engine-tests.md, "File format".

new_id_seq <- function(prefix = "id") {
  i <- 0L
  function() {
    i <<- i + 1L
    sprintf("%s-%03d", prefix, i)
  }
}

problem_kinds <- function(file) {
  if (is.null(file$problems)) character() else file$problems$kind
}

problem_detail <- function(file, kind) {
  file$problems$detail[file$problems$kind == kind]
}

format_files <- list.files("files/format-1", full.names = TRUE)

read_raw <- function(path) {
  readChar(path, file.info(path)$size, useBytes = TRUE)
}

test_that("parse_canonical_example parses the design.md example", {
  text <- read_raw("files/format-1/canonical.R")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")

  expect_equal(file$header$ember_version, "0.1.0")
  expect_equal(file$header$r_version, "4.5.1")
  expect_equal(file$header$snapshot, "2026-09-01")
  expect_equal(file$header$bioc_version, "3.22")
  expect_equal(file$header$on_cell_change, "autorun")
  expect_equal(unname(file$header$sources), "github:lab/mypkg@3f2a1c9")
  expect_equal(names(file$header$sources), "mypkg")
  expect_equal(file$header$extra_packages, "svglite")

  expect_equal(length(file$cells), 4)
  expect_equal(names(file$cells), c("setup", "md1", "a", "load1"))
  expect_equal(file$setup, "setup")

  expect_true(unname(file$cells[["md1"]]$folded))
  expect_false(file$cells[["a"]]$folded)
  expect_true(startsWith(file$cells[["md1"]]$code, "#' "))
  expect_equal(file$cells[["md1"]]$kind, "markdown")

  expect_equal(file$learned, list(load1 = "fits"))
  expect_equal(file$sourced, data.frame(path = "helpers.R", hash = "sha256:9c1e",
                                        stringsAsFactors = FALSE))
  expect_equal(format_lock_lines(file$lock),
              c("cli 3.6.5 CRAN", "dplyr 1.1.4 CRAN", "ggplot2 3.5.2 CRAN"))
  expect_null(file$problems)
})

#' A `[markdown]`-tagged cell's fixture loses that tag on save (piece 2,
#' ui-3-plan.md): reading it, writing it, and reading that back gives the
#' same cells, but the written text itself is no longer byte-identical to
#' the old-layout fixture.
has_markdown_tag <- function(path) any(grepl("\\[markdown\\]", read_raw(path)))

test_that("round_trip_byte_stable: every format-1 fixture without a [markdown] tag round-trips exactly", {
  for (path in format_files) {
    if (has_markdown_tag(path)) next
    text <- read_raw(path)
    file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
    expect_identical(format_notebook(file), text, info = path)
  }
})

test_that("round_trip_lost_markdown_tag: a [markdown] fixture loses the tag but reads back the same (41)", {
  for (path in format_files) {
    if (!has_markdown_tag(path)) next
    text <- read_raw(path)
    file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
    once <- format_notebook(file)
    expect_false(grepl("[markdown]", once, fixed = TRUE), info = path)
    reparsed <- parse_notebook(once, new_id = new_id_seq(), version = "0.1.0")
    expect_equal(reparsed$cells, file$cells, info = path)
    # A new-layout file (no [markdown] tag left to lose) round-trips byte
    # for byte from here on.
    twice <- format_notebook(reparsed)
    expect_identical(twice, once, info = path)
  }
})

# ---- Generated round trips ---------------------------------------------------

random_text_line <- function() {
  sample(c("x <- 1", "y <- 2 + 3", "f(a, b)", "h\u00e9llo w\u00f6rld",
          "emoji \U0001F389\U0001F600", "z <- \"quoted\"", "\u4e2d\u6587\u6d4b\u8bd5",
          "result <- x + y", "for (i in 1:3) print(i)"), 1)
}

random_lines <- function(n, prefix = NULL) {
  out <- character()
  for (i in seq_len(n)) {
    if (i > 1 && stats::runif(1) < 0.3) out <- c(out, "")
    line <- random_text_line()
    if (!is.null(prefix)) line <- paste(prefix, line)
    out <- c(out, line)
  }
  paste(out, collapse = "\n")
}

random_notebook_file <- function(new_id) {
  n_cells <- sample(2:5, 1)
  cell_ids <- replicate(n_cells, new_id())
  kinds <- sample(c("code", "markdown"), n_cells, replace = TRUE)
  if (!("code" %in% kinds)) kinds[[1]] <- "code"

  cells <- list()
  for (i in seq_len(n_cells)) {
    code <- if (identical(kinds[[i]], "code")) {
      random_lines(sample(1:4, 1))
    } else {
      random_lines(sample(1:4, 1), prefix = "#'")
    }
    cells[[cell_ids[[i]]]] <- list(code = code, kind = kinds[[i]],
                                   folded = sample(c(TRUE, FALSE), 1), disabled = FALSE)
  }
  display_order <- sample(cell_ids)
  cells <- cells[display_order]
  code_ids <- cell_ids[kinds == "code"]
  setup <- sample(code_ids, 1)
  run_order <- sample(cell_ids)

  # A random third of the non-setup code cells disabled, another third
  # commented (ui-3 19): both are written with "## " before each line, so
  # both exercise the same comment/uncomment round trip.
  other_code <- setdiff(code_ids, setup)
  shuffled <- sample(other_code)
  n_third <- length(shuffled) %/% 3L
  disabled_ids <- shuffled[seq_len(n_third)]
  commented_ids <- shuffled[seq_len(n_third) + n_third]
  for (id in disabled_ids) cells[[id]]$disabled <- TRUE

  header <- new_header(ember_version = "0.1.0", r_version = "4.5.1", snapshot = "2026-09-01",
                       bioc_version = if (stats::runif(1) < 0.3) "3.22" else NA_character_,
                       on_cell_change = if (stats::runif(1) < 0.3) "lazy" else "autorun")
  new_notebook_file(header = header, cells = cells, setup = setup, run_order = run_order,
                    learned = list(),
                    sourced = data.frame(path = character(), hash = character(),
                                         stringsAsFactors = FALSE),
                    lock = empty_lock(), extra_blocks = list(), format = 1L,
                    commented = commented_ids)
}

test_that("round_trip_generated: 200 generated notebooks round-trip byte for byte", {
  set.seed(20260930)
  new_id <- new_id_seq("gen")
  for (k in 1:200) {
    file <- random_notebook_file(new_id)
    text <- format_notebook(file, order = file$run_order)
    reparsed <- parse_notebook(text, new_id = new_id, version = "0.1.0")
    expect_null(reparsed$problems, info = paste("iteration", k))
    expect_identical(format_notebook(reparsed), text, info = paste("iteration", k))
  }
})

# ---- Individual repairs and structural rules ---------------------------------

test_that("cells_written_in_run_order writes cells in run order, display order in the footer", {
  header <- new_header(ember_version = "0.1.0", r_version = "4.5.1", snapshot = "2026-09-01")
  cells <- list(
    b = list(code = "y <- 2", kind = "code", folded = FALSE),
    a = list(code = "x <- 1", kind = "code", folded = FALSE)
  )
  file <- new_notebook_file(header = header, cells = cells, setup = "a",
                            run_order = c("a", "b"), learned = list(),
                            sourced = data.frame(path = character(), hash = character(),
                                                 stringsAsFactors = FALSE),
                            lock = empty_lock(), extra_blocks = list(), format = 1L)
  text <- format_notebook(file, order = c("a", "b"))
  lines <- strsplit(text, "\n", fixed = TRUE)[[1]]
  expect_equal(which(grepl("^# %% id=a", lines)) < which(grepl("^# %% id=b", lines)), TRUE)
  order_lines <- lines[(which(lines == "# /// cell order") + 1):(which(lines == "# ///")[1] + 10)]
  expect_equal(lines[which(lines == "# /// cell order") + 1], "# b")
  expect_equal(lines[which(lines == "# /// cell order") + 2], "# a")
})

test_that("setup_marker_read_and_written sets setup and writes it back on that cell only", {
  text <- paste("# %% id=a", "1", "", "# %% id=b [setup]", "2", "",
               "# /// cell order", "# a", "# b", "# ///", "", sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(file$setup, "b")
  out <- format_notebook(file)
  lines <- strsplit(out, "\n", fixed = TRUE)[[1]]
  expect_equal(lines[grepl("^# %% id=b", lines)], "# %% id=b [setup]")
  expect_equal(lines[grepl("^# %% id=a", lines)], "# %% id=a")
})

test_that("no_setup_marker_first_code_cell takes the first code cell and notes it", {
  text <- paste("# %% id=md [markdown]", "#' text", "", "# %% id=a", "1", "",
               "# %% id=b", "2", "", "# /// cell order", "# md", "# a", "# b", "# ///", "",
               sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(file$setup, "a")
  expect_true("no_setup_marker" %in% problem_kinds(file))
  # ui-2-tests.md 4: a markdown cell listed without "folded" opens unfolded.
  expect_false(unname(file$cells[["md"]]$folded))
})

test_that("a [markdown] cell keeps its #' lines as written; an unprefixed line gets one added", {
  text <- paste("# %% id=a [markdown]", "#' heading", "#'", "#'content-no-space",
               "not-prefixed-at-all", "", sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(file$cells[["a"]]$code,
              "#' heading\n#'\n#'content-no-space\n#' not-prefixed-at-all")
  expect_equal(file$cells[["a"]]$kind, "markdown")
})

test_that("trailing_blank_lines_normalised drops trailing blanks and is then stable", {
  text <- paste("### An Ember notebook ###", "# /// environment",
               "# ember_version = \"0.1.0\"", "# r_version = \"4.5.1\"",
               "# snapshot = \"2026-09-01\"", "# ///", "",
               "# %% id=a", "x <- 1", "", "", "", "# /// cell order", "# a", "# ///", "",
               sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(file$cells[["a"]]$code, "x <- 1")
  once <- format_notebook(file)
  twice <- format_notebook(parse_notebook(once, new_id = new_id_seq(), version = "0.1.0"))
  expect_identical(once, twice)
})

test_that("plain_script_opens becomes one code cell and notes no_header", {
  text <- "x <- 1\ny <- 2\n"
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(length(file$cells), 1)
  expect_equal(file$cells[[1]]$code, "x <- 1\ny <- 2")
  expect_equal(file$setup, names(file$cells)[[1]])
  expect_true("no_header" %in% problem_kinds(file))
})

test_that("markers_without_ids get ids from new_id and note bad_id", {
  text <- paste("# %%", "a <- 1", "", "# %%", "b <- 2", "", sep = "\n")
  gen <- new_id_seq("fresh")
  file <- parse_notebook(text, new_id = gen, version = "0.1.0")
  expect_equal(names(file$cells), c("fresh-001", "fresh-002"))
  expect_equal(sum(problem_kinds(file) == "bad_id"), 2)
})

test_that("duplicate_ids_repaired gives the second cell a new id; the first keeps its id", {
  text <- paste("# %% id=x", "a <- 1", "", "# %% id=x", "b <- 2", "", sep = "\n")
  gen <- new_id_seq("fresh")
  file <- parse_notebook(text, new_id = gen, version = "0.1.0")
  expect_equal(names(file$cells)[[1]], "x")
  expect_equal(names(file$cells)[[2]], "fresh-001")
  expect_equal(problem_detail(file, "duplicate_id"), "x")
})

test_that("missing_footer uses file order as display order and notes no_footer", {
  text <- paste("# %% id=b", "1", "", "# %% id=a", "2", "", sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(names(file$cells), c("b", "a"))
  expect_true("no_footer" %in% problem_kinds(file))
})

test_that("order_block_mismatch drops unknown ids and places missing cells after their predecessor", {
  text <- paste("# %% id=a", "1", "", "# %% id=b", "2", "", "# %% id=c", "3", "",
               "# /// cell order", "# a", "# zzz", "# c", "# ///", "", sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(names(file$cells), c("a", "b", "c"))
  expect_equal(problem_detail(file, "unknown_order_id"), "zzz")
  expect_equal(problem_detail(file, "cell_missing_from_order"), "b")
})

test_that("text_before_first_marker becomes its own cell", {
  text <- paste("stray <- 1", "", "# %% id=a", "x <- 2", "", sep = "\n")
  gen <- new_id_seq("fresh")
  file <- parse_notebook(text, new_id = gen, version = "0.1.0")
  expect_equal(length(file$cells), 2)
  expect_equal(file$cells[["fresh-001"]]$code, "stray <- 1")
  expect_equal(file$cells[["a"]]$code, "x <- 2")
  expect_true("text_before_first_cell" %in% problem_kinds(file))
})

test_that("unknown_header_keys_kept and footer blocks survive a round trip verbatim", {
  text <- read_raw("files/format-1/unknown-blocks.R")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(file$header$extra, "future_key = \"value\"")
  expect_equal(file$extra_blocks[["future block"]], c("line one", "line two"))
  expect_identical(format_notebook(file), text)
})

test_that("header_optional_fields are written only when set", {
  header <- new_header(ember_version = "0.1.0", r_version = "4.5.1", snapshot = "2026-09-01")
  cells <- list(a = list(code = "1", kind = "code", folded = FALSE))
  file <- new_notebook_file(header = header, cells = cells, setup = "a", run_order = "a",
                            learned = list(),
                            sourced = data.frame(path = character(), hash = character(),
                                                 stringsAsFactors = FALSE),
                            lock = empty_lock(), extra_blocks = list(), format = 1L)
  text <- format_notebook(file)
  expect_false(grepl("bioc_version", text))
  expect_false(grepl("\\[sources\\]", text))
  expect_false(grepl("\\[extra_packages\\]", text))

  header2 <- new_header(ember_version = "0.1.0", r_version = "4.5.1", snapshot = "2026-09-01",
                        bioc_version = "3.22", sources = c(p = "github:a/b@c"),
                        extra_packages = "svglite")
  file2 <- new_notebook_file(header = header2, cells = cells, setup = "a", run_order = "a",
                             learned = list(),
                             sourced = data.frame(path = character(), hash = character(),
                                                  stringsAsFactors = FALSE),
                             lock = empty_lock(), extra_blocks = list(), format = 1L)
  text2 <- format_notebook(file2)
  expect_true(grepl("bioc_version = \"3.22\"", text2, fixed = TRUE))
  expect_true(grepl("[sources]", text2, fixed = TRUE))
  expect_true(grepl("[extra_packages]", text2, fixed = TRUE))
})

test_that("toml_strings round-trip quotes, backslashes and spaces", {
  odd <- "a \"quoted\" \\path with spaces"
  expect_equal(toml_unquote(toml_string(odd)), odd)

  header <- new_header(ember_version = "0.1.0", r_version = "4.5.1", snapshot = "2026-09-01",
                       sources = c(p = odd))
  cells <- list(a = list(code = "1", kind = "code", folded = FALSE))
  file <- new_notebook_file(header = header, cells = cells, setup = "a", run_order = "a",
                            learned = list(),
                            sourced = data.frame(path = odd, hash = "md5:abc",
                                                 stringsAsFactors = FALSE),
                            lock = empty_lock(), extra_blocks = list(), format = 1L)
  text <- format_notebook(file)
  reparsed <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(unname(reparsed$header$sources["p"]), odd)
  expect_equal(reparsed$sourced$path, odd)
  expect_identical(format_notebook(reparsed), text)
})

test_that("newer_version_read_only sets read_only and notes newer_version", {
  header <- new_header(ember_version = "99.0.0", r_version = "4.5.1", snapshot = "2026-09-01")
  cells <- list(a = list(code = "1", kind = "code", folded = FALSE))
  file0 <- new_notebook_file(header = header, cells = cells, setup = "a", run_order = "a",
                             learned = list(),
                             sourced = data.frame(path = character(), hash = character(),
                                                  stringsAsFactors = FALSE),
                             lock = empty_lock(), extra_blocks = list(), format = 1L)
  text <- format_notebook(file0)
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_true(file$read_only)
  expect_true("newer_version" %in% problem_kinds(file))
})

test_that("older_format_converted converts format-1 text and notes converted", {
  text <- read_raw("files/format-1/minimal.R")
  env <- environment(parse_notebook)
  old_format <- get("ember_format", envir = env)
  old_converters <- get("converters", envir = env)
  on.exit({
    unlockBinding("ember_format", env)
    unlockBinding("converters", env)
    assign("ember_format", old_format, envir = env)
    assign("converters", old_converters, envir = env)
    lockBinding("ember_format", env)
    lockBinding("converters", env)
  })
  unlockBinding("ember_format", env)
  unlockBinding("converters", env)
  assign("ember_format", 2L, envir = env)
  assign("converters", list(function(t) paste0(t, "# converter ran\n")), envir = env)

  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(file$format, 1L)
  expect_true("converted" %in% problem_kinds(file))
})

test_that("crlf_read parses \\r\\n text like \\n text", {
  lf <- read_raw("files/format-1/minimal.R")
  crlf <- gsub("\n", "\r\n", lf, fixed = TRUE)
  f_lf <- parse_notebook(lf, new_id = new_id_seq(), version = "0.1.0")
  f_crlf <- parse_notebook(crlf, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(f_lf$cells, f_crlf$cells)
  expect_equal(f_lf$header, f_crlf$header)
  expect_equal(f_lf$setup, f_crlf$setup)
})

# ---- Review fixes ------------------------------------------------------------

test_that("duplicate_order_id_repaired drops the repeated id instead of duplicating the cell (item 15)", {
  text <- paste("# %% id=a [setup]", "1", "", "# %% id=b", "2", "",
               "# /// cell order", "# a", "# b", "# a", "# ///", "", sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(names(file$cells), c("a", "b"))
  expect_true("duplicate_order_id" %in% problem_kinds(file))
  expect_equal(problem_detail(file, "duplicate_order_id"), "a")
})

test_that("a header with no closing marker ends at the first cell marker, not at EOF (item 16)", {
  text <- paste("### An Ember notebook ###", "# /// environment",
               "# ember_version = \"0.1.0\"",
               "# %% id=a [setup]", "x <- 1", "",
               "# %% id=b", "y <- 2", "", "# /// cell order", "# a", "# b", "# ///", "",
               sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(names(file$cells), c("a", "b"))
  expect_equal(file$cells[["a"]]$code, "x <- 1")
  expect_equal(file$cells[["b"]]$code, "y <- 2")
  expect_true("no_header_close" %in% problem_kinds(file))
})

test_that("a header with no closing marker, ended by a footer block instead of a cell", {
  text <- paste("### An Ember notebook ###", "# /// environment",
               "# ember_version = \"0.1.0\"",
               "# /// cell order", "# ///", "", sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_true("no_header_close" %in% problem_kinds(file))
  expect_equal(length(file$cells), 1)  # no cell markers at all: a synthetic setup cell
})

# ---- Disable cell: file format (ui-3 15-19) ---------------------------------

header_lines <- function() {
  c("### An Ember notebook ###", "# /// environment",
   "# ember_version = \"0.1.0\"", "# r_version = \"4.5.1\"",
   "# snapshot = \"2026-09-01\"", "# ///", "")
}

test_that("a disabled cell's code lines are each written with '## ' (ui-3 15)", {
  text <- paste(c(header_lines(), "# %% id=a [setup]", "0", "",
               "# %% id=b", "## x <- 1", "##", "##   y", "## # note",
               "## #' not text", "## #| fig-width: 4", "## ##", "## %% 2", "",
               "# /// cell order", "# a", "# b disabled", "# ///", ""), collapse = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(file$cells[["b"]]$code,
              "x <- 1\n\n  y\n# note\n#' not text\n#| fig-width: 4\n##\n%% 2")
  expect_true(file$cells[["b"]]$disabled)
  expect_null(file$problems)
  expect_identical(format_notebook(file), text)
})

test_that("folded and disabled both appear on the footer line, folded first (ui-3 15)", {
  text <- paste(c(header_lines(), "# %% id=a [setup]", "0", "",
               "# %% id=b", "## x <- 1", "",
               "# /// cell order", "# a", "# b folded disabled", "# ///", ""), collapse = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_true(unname(file$cells[["b"]]$folded))
  expect_true(file$cells[["b"]]$disabled)
  expect_identical(format_notebook(file), text)
})

test_that("a commented '%% 2' or '/// x' line inside a disabled cell makes no extra cell or footer block (ui-3 16)", {
  text <- paste(c(header_lines(), "# %% id=a [setup]", "0", "",
               "# %% id=b", "## %% 2", "## /// x", "",
               "# /// cell order", "# a", "# b disabled", "# ///", ""), collapse = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(names(file$cells), c("a", "b"))
  expect_equal(file$cells[["b"]]$code, "%% 2\n/// x")
  expect_identical(format_notebook(file), text)
})

test_that("a commented cell reads back with its exact code and disabled = FALSE (ui-3 17)", {
  text <- paste("# %% id=a [setup]", "0", "",
               "# %% id=b", "## x + 1", "",
               "# /// cell order", "# a", "# b commented", "# ///", "", sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(file$cells[["b"]]$code, "x + 1")
  expect_false(file$cells[["b"]]$disabled)
  expect_equal(file$commented, "b")
})

test_that("a line without '##' in a disabled cell is kept as is, with problem uncommented_line (ui-3 18)", {
  text <- paste("# %% id=a [setup]", "0", "",
               "# %% id=b", "## x <- 1", "y <- 2", "",
               "# /// cell order", "# a", "# b disabled", "# ///", "", sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(file$cells[["b"]]$code, "x <- 1\ny <- 2")
  expect_true(file$cells[["b"]]$disabled)
  expect_true("uncommented_line" %in% problem_kinds(file))
  expect_equal(problem_detail(file, "uncommented_line"), "b")
})

test_that("several uncommented lines in one disabled cell give one problem row, not one per line (review)", {
  text <- paste("# %% id=a [setup]", "0", "",
               "# %% id=b", "y <- 2", "z <- 3", "",
               "# /// cell order", "# a", "# b disabled", "# ///", "", sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(file$cells[["b"]]$code, "y <- 2\nz <- 3")
  expect_equal(sum(problem_kinds(file) == "uncommented_line"), 1)
  expect_equal(problem_detail(file, "uncommented_line"), "b")
})

test_that("disabled on a text cell gives disabled_text_cell and the cell unchanged (ui-3 18)", {
  text <- paste("# %% id=a [setup]", "0", "",
               "# %% id=b [markdown]", "#' hello", "",
               "# /// cell order", "# a", "# b disabled", "# ///", "", sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(file$cells[["b"]]$code, "#' hello")
  expect_false(file$cells[["b"]]$disabled)
  expect_true("disabled_text_cell" %in% problem_kinds(file))
})

test_that("a disabled cell whose un-commented code is only #' lines also gets disabled_text_cell (41)", {
  # No [markdown] tag: the cell was written (or hand-edited) as disabled
  # code whose content, once un-commented, turns out to be pure text --
  # main's Ember once allowed disabling a text cell this way.
  text <- paste("# %% id=a [setup]", "0", "",
               "# %% id=d", "## #' hello", "",
               "# /// cell order", "# a", "# d disabled", "# ///", "", sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(file$cells[["d"]]$code, "#' hello")
  expect_equal(file$cells[["d"]]$kind, "markdown")
  expect_false(file$cells[["d"]]$disabled)
  expect_true("disabled_text_cell" %in% problem_kinds(file))
})

test_that("disabled on the setup cell un-comments the code and clears the flag (ui-3 18)", {
  text <- paste("# %% id=a [setup]", "## x <- 1", "",
               "# /// cell order", "# a disabled", "# ///", "", sep = "\n")
  file <- parse_notebook(text, new_id = new_id_seq(), version = "0.1.0")
  expect_equal(file$cells[["a"]]$code, "x <- 1")
  expect_false(file$cells[["a"]]$disabled)
  expect_true("disabled_setup_cell" %in% problem_kinds(file))
})

test_that("cell_figure_size(): no #| lines gives the default, 7.5 x 5 (ui-3 62)", {
  fig <- cell_figure_size("plot(1)")
  expect_equal(fig$width, 7.5)
  expect_equal(fig$height, 5)
  expect_equal(fig$problems, character())
})

test_that("cell_figure_size(): fig-width and fig-height lines are read (ui-3 62)", {
  fig <- cell_figure_size("#| fig-width: 8\n#| fig-height: 4\nplot(1)")
  expect_equal(fig$width, 8)
  expect_equal(fig$height, 4)
  expect_equal(fig$problems, character())
})

test_that("cell_figure_size(): knitr's fig.width key also works (ui-3 62)", {
  fig <- cell_figure_size("#| fig.width: 6\nplot(1)")
  expect_equal(fig$width, 6)
})

test_that("cell_figure_size(): a #| line after a code line is an ordinary comment (ui-3 62)", {
  fig <- cell_figure_size("plot(1)\n#| fig-width: 3")
  expect_equal(fig$width, 7.5)
})

test_that("cell_figure_size(): leading blank lines before the #| run are skipped (ui-3 62)", {
  fig <- cell_figure_size("\n\n#| fig-width: 6")
  expect_equal(fig$width, 6)
})

test_that("cell_figure_size(): a non-numeric value uses the default and reports a problem naming the line (ui-3 62)", {
  fig <- cell_figure_size("#| fig-width: wide\nplot(1)")
  expect_equal(fig$width, 7.5)
  expect_length(fig$problems, 1)
  expect_match(fig$problems[[1]], "^#\\| fig-width: wide is not a number of inches; using 7.5\\.$")
})

test_that("cell_figure_size(): a value outside 0.5-30 uses the default and reports a 'must be between' problem (review)", {
  fig <- cell_figure_size("#| fig-width: 0\nplot(1)")
  expect_equal(fig$width, 7.5)
  expect_length(fig$problems, 1)
  expect_match(fig$problems[[1]], "fig-width: 0 must be between 0\\.5 and 30 inches; using 7\\.5\\.$")

  fig2 <- cell_figure_size("#| fig-width: 40\nplot(1)")
  expect_equal(fig2$width, 7.5)
  expect_match(fig2$problems[[1]], "must be between 0\\.5 and 30 inches")
})

test_that("cell_figure_size(): an unrelated #| key is ignored, with no problem (ui-3 62)", {
  fig <- cell_figure_size("#| echo: false\nplot(1)")
  expect_equal(fig$width, 7.5)
  expect_equal(fig$height, 5)
  expect_equal(fig$problems, character())
})

test_that("cell_figure_size(): a quoted number is read (review)", {
  fig <- cell_figure_size('#| fig-width: "6"\nplot(1)')
  expect_equal(fig$width, 6)
  expect_equal(fig$problems, character())
})

test_that("cell_figure_size(): a trailing YAML-style comment is stripped before parsing (review)", {
  fig <- cell_figure_size("#| fig-width: 6 # wide\nplot(1)")
  expect_equal(fig$width, 6)
  expect_equal(fig$problems, character())
})

test_that("cell_figure_size(): a hex literal is rejected even though as.numeric() would parse it (review)", {
  fig <- cell_figure_size("#| fig-width: 0x10\nplot(1)")
  expect_equal(fig$width, 7.5)
  expect_length(fig$problems, 1)
  expect_match(fig$problems[[1]], "fig-width: 0x10 is not a number of inches; using 7\\.5\\.$")
})

test_that("cell_figure_size(): knitr's equals-sign form is reported as a problem naming the colon form (review)", {
  fig <- cell_figure_size("#| fig.width = 6\nplot(1)")
  expect_equal(fig$width, 7.5)
  expect_length(fig$problems, 1)
  expect_match(fig$problems[[1]], "use fig-width: 6")

  fig2 <- cell_figure_size("#| fig.height = 4\nplot(1)")
  expect_match(fig2$problems[[1]], "use fig-height: 4")
})
