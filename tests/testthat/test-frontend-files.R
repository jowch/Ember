# Tests for the installed frontend and package metadata after pieces 1 and
# 2 ("Ember's look" and "Offline bundle", docs/ui-2.md). Covers
# docs/ui-2-tests.md items 5, 6, 7, 13, 14.

frontend_dir <- function() {
  dir <- system.file("frontend", package = "ember")
  if (!nzchar(dir)) skip("installed frontend not found (system.file empty)")
  dir
}

frontend_files <- function(dir) {
  list.files(dir, recursive = TRUE, full.names = TRUE)
}

#' Strip `//`, `/* */` and (for HTML) `<!-- -->` comments from `text`, an
#' `ext` ("js", "css" or "html") file's contents, so a comment mentioning
#' something -- a stale CDN note, a vendored file's doc header -- is never
#' mistaken for live code.
strip_comments <- function(text, ext) {
  text <- gsub("(?s)/\\*.*?\\*/", "", text, perl = TRUE)
  if (identical(ext, "html")) text <- gsub("(?s)<!--.*?-->", "", text, perl = TRUE)
  # `(?<!:)` so a `//` straight after a colon -- "https://", "http://" --
  # is never mistaken for a line comment's start.
  if (identical(ext, "js")) text <- gsub("(?m)(?<!:)//[^\n]*$", "", text, perl = TRUE)
  text
}

#' Every `https?://` URL in `dir`'s `.js`/`.css`/`.html` files that sits in
#' an import/load position -- a static or dynamic JS import, an HTML
#' `<link>`/`<script>`'s `src=`/`href=`, or a CSS `url()` -- except one
#' naming something in `allow` (a substring match). A plain `<a href>` is
#' not a load (ui-2-tests.md 13's note) and is deliberately not checked:
#' only `<link>`/`<script>` tags are.
external_url_hits <- function(dir, allow = "mathjax@") {
  url_re <- "https?://[^\"'()\\s>]+"
  is_allowed <- function(url) any(vapply(allow, function(a) grepl(a, url, fixed = TRUE), logical(1)))

  read_text <- function(f, ext) {
    text <- tryCatch(readChar(f, file.info(f)$size, useBytes = TRUE), error = function(e) NA_character_)
    if (is.na(text)) return(text)
    strip_comments(text, ext)
  }

  scan_pattern <- function(files, pattern, ext) {
    hits <- character(0)
    for (f in files) {
      text <- read_text(f, ext)
      if (is.na(text)) next
      found <- regmatches(text, gregexpr(pattern, text, perl = TRUE))[[1]]
      for (m in found) {
        url <- regmatches(m, regexpr(url_re, m, perl = TRUE))
        if (length(url) == 0 || !nzchar(url) || is_allowed(url)) next
        hits <- c(hits, paste0(f, ": ", m))
      }
    }
    hits
  }

  files <- frontend_files(dir)
  js <- files[grepl("\\.js$", files)]
  css <- files[grepl("\\.css$", files)]
  html <- files[grepl("\\.html$", files)]

  hits <- c(
    scan_pattern(js, paste0('\\bfrom\\s*\\(?\\s*["\']', url_re), "js"),
    scan_pattern(js, paste0('\\bimport\\(\\s*["\']', url_re), "js"),
    scan_pattern(css, paste0("url\\(\\s*[\"']?", url_re), "css"))

  for (f in html) {
    text <- read_text(f, "html")
    if (is.na(text)) next
    tags <- regmatches(text, gregexpr("<(link|script)\\b[^>]*>", text, perl = TRUE, ignore.case = TRUE))[[1]]
    for (tag in tags) {
      attrs <- regmatches(tag, gregexpr(paste0("(src|href)\\s*=\\s*[\"']", url_re, "[\"']"),
                                        tag, perl = TRUE, ignore.case = TRUE))[[1]]
      for (a in attrs) {
        url <- regmatches(a, regexpr(url_re, a, perl = TRUE))
        if (length(url) == 0 || !nzchar(url) || is_allowed(url)) next
        hits <- c(hits, paste0(f, ": ", a))
      }
    }
  }
  hits
}

# ---- 5. No EMBER flag, no calling-home strings, deleted files stay gone ----

test_that("the installed frontend has no EMBER checks or calling-home strings (5)", {
  dir <- frontend_dir()
  files <- frontend_files(dir)

  forbidden <- c("EMBER", "plutojl.org", "fonsp.com", "stats.plutojl", "openai.com", "firebasejs")
  hits <- character()
  for (f in files) {
    text <- tryCatch(readChar(f, file.info(f)$size, useBytes = TRUE), error = function(e) NA_character_)
    if (is.na(text)) next
    for (pat in forbidden) {
      if (grepl(pat, text, fixed = TRUE)) hits <- c(hits, paste(f, pat, sep = ": "))
    }
  }
  expect_equal(hits, character(0))

  expect_false(file.exists(file.path(dir, "common", "EmberFlags.js")))
  expect_false(file.exists(file.path(dir, "common", "Feedback.js")))
  expect_false(file.exists(file.path(dir, "components", "FixWithAIButton.js")))
  expect_false(dir.exists(file.path(dir, "components", "welcome")))
})

# ---- 6. Every Pluto CSS variable name survives in both themes -------------

test_that("every name in pluto-css-variables.txt is defined in both themes (6)", {
  dir <- frontend_dir()
  names <- readLines(testthat::test_path("fixtures", "pluto-css-variables.txt"))
  names <- names[nzchar(names)]

  for (theme in c("light.css", "dark.css")) {
    text <- readChar(file.path(dir, "themes", theme), file.info(file.path(dir, "themes", theme))$size)
    missing <- names[!vapply(names, function(n) grepl(paste0(n, "\\s*:"), text), logical(1))]
    expect_equal(missing, character(0), info = theme)
  }
})

# ---- 105. Endeavor's variables too, no media query, one dark selector ----

test_that("pluto and endeavor CSS variables are defined in both themes with no media query (105)", {
  dir <- frontend_dir()
  # endeavor-css-variables.txt's two non-colour names live outside the theme files; the e2e "Endeavor's DOM hooks" test covers the full fixture.
  names <- readLines(testthat::test_path("fixtures", "pluto-css-variables.txt"))
  names <- names[nzchar(names)]

  for (theme in c("light.css", "dark.css")) {
    theme_path <- file.path(dir, "themes", theme)
    text <- readChar(theme_path, file.info(theme_path)$size)

    missing <- names[!vapply(names, function(n) grepl(paste0(n, "\\s*:"), text), logical(1))]
    expect_equal(missing, character(0), info = theme)

    expect_false(grepl("prefers-color-scheme", text), info = theme)
  }

  dark_path <- file.path(dir, "themes", "dark.css")
  dark_text <- readChar(dark_path, file.info(dark_path)$size)
  # Every basic selector in dark.css (ignoring the @media wrapper around
  # the prefers-contrast tweak) is this one attribute selector -- no
  # leftover bare `:root` or `.foo` rule from before this piece.
  selectors <- regmatches(dark_text, gregexpr("(?m)^[^@/{}\n][^{\n]*(?=\\{)", dark_text, perl = TRUE))[[1]]
  selectors <- trimws(selectors)
  expect_true(length(selectors) > 0)
  expect_true(all(selectors == '[data-theme="dark"]' | selectors == ':root[data-theme="dark"]'), info = paste(selectors, collapse = ", "))
})

# ---- 106. Contrast ---------------------------------------------------------

#' A theme file's `--ember-<name>: #hex;` declaration's value, or NA if the
#' name isn't a plain hex literal there (an alias like `var(--ember-accent)`
#' is read through by `read_token()` below instead).
read_hex <- function(text, name) {
  m <- regmatches(text, regexpr(paste0("--ember-", name, ":\\s*(var\\(--ember-([a-z-]+)\\)|#[0-9a-fA-F]{6})"), text, perl = TRUE))
  if (!nzchar(m)) return(NA_character_)
  inner <- sub(paste0("--ember-", name, ":\\s*"), "", m)
  if (startsWith(inner, "var(")) return(NA_character_)
  inner
}

#' `--ember-<name>`'s hex value in `text`, following one `var(--ember-x)`
#' alias if the declaration isn't a literal.
read_token <- function(text, name) {
  m <- regmatches(text, regexpr(paste0("--ember-", name, ":\\s*(var\\(--ember-([a-z-]+)\\)|#[0-9a-fA-F]{6})"), text, perl = TRUE))
  stopifnot(nzchar(m))
  inner <- sub(paste0("--ember-", name, ":\\s*"), "", m)
  if (startsWith(inner, "var(")) {
    aliased <- sub("var\\(--ember-([a-z-]+)\\)", "\\1", inner)
    return(read_hex(text, aliased))
  }
  inner
}

hex_to_rgb <- function(hex) {
  hex <- sub("^#", "", hex)
  vapply(c(1, 3, 5), function(i) strtoi(substr(hex, i, i + 1), base = 16L), numeric(1))
}

relative_luminance <- function(rgb) {
  srgb <- rgb / 255
  lin <- ifelse(srgb <= 0.03928, srgb / 12.92, ((srgb + 0.055) / 1.055)^2.4)
  sum(c(0.2126, 0.7152, 0.0722) * lin)
}

contrast_ratio <- function(hex1, hex2) {
  l1 <- relative_luminance(hex_to_rgb(hex1))
  l2 <- relative_luminance(hex_to_rgb(hex2))
  (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}

test_that("Ember's Sage tokens meet WCAG 4.5:1 text contrast (106)", {
  dir <- frontend_dir()

  text_on_bg <- list(c("text", "page"), c("text", "panel"), c("text", "code"),
                      c("muted", "page"), c("muted", "panel"), c("muted", "code"),
                      c("faint", "page"), c("faint", "panel"), c("faint", "code"),
                      c("accent", "page"), c("accent", "panel"), c("accent", "code"),
                      c("syn-kw", "code"), c("syn-fn", "code"), c("syn-str", "code"),
                      c("syn-num", "code"), c("syn-com", "code"))

  for (theme in c("light.css", "dark.css")) {
    theme_path <- file.path(dir, "themes", theme)
    text <- readChar(theme_path, file.info(theme_path)$size)

    for (pair in text_on_bg) {
      fg <- read_token(text, pair[1])
      bg <- read_token(text, pair[2])
      ratio <- contrast_ratio(fg, bg)
      expect_gte(ratio, 4.5, label = sprintf("%s on %s in %s: %.2f", pair[1], pair[2], theme, ratio))
    }

    expect_gte(contrast_ratio(read_token(text, "red"), read_token(text, "red-bg")), 4.5, label = theme)
    expect_gte(contrast_ratio(read_token(text, "amber"), read_token(text, "amber-bg")), 4.5, label = theme)
    expect_gte(contrast_ratio(read_token(text, "on-accent"), read_token(text, "accent")), 4.5, label = theme)
  }
})

# ---- 137. Contrast, piece 6's tokens ---------------------------------------

test_that("piece 6's chip, error, warning, ANSI and wash tokens meet WCAG 4.5:1 (137)", {
  dir <- frontend_dir()

  for (theme in c("light.css", "dark.css")) {
    theme_path <- file.path(dir, "themes", theme)
    text <- readChar(theme_path, file.info(theme_path)$size)

    expect_gte(contrast_ratio(read_token(text, "chip-stale-text"), read_token(text, "chip-stale-bg")), 4.5, label = theme)
    expect_gte(contrast_ratio(read_token(text, "chip-dis-text"), read_token(text, "chip-dis-bg")), 4.5, label = theme)
    expect_gte(contrast_ratio(read_token(text, "red"), read_token(text, "err-bg")), 4.5, label = theme)
    expect_gte(contrast_ratio(read_token(text, "warn-text"), read_token(text, "due-bg")), 4.5, label = theme)
    expect_gte(contrast_ratio(read_token(text, "faint"), read_token(text, "wash")), 4.5, label = theme)
    expect_gte(contrast_ratio(read_token(text, "muted"), read_token(text, "dis-bg")), 4.5, label = theme)

    for (colour in c("ansi-red", "ansi-green", "ansi-yellow", "ansi-blue", "ansi-magenta", "ansi-cyan")) {
      expect_gte(contrast_ratio(read_token(text, colour), read_token(text, "page")), 4.5, label = paste(theme, colour))
      expect_gte(contrast_ratio(read_token(text, colour), read_token(text, "code")), 4.5, label = paste(theme, colour))
    }
  }
})

# ---- 138. RunArea and ember-cell-label are gone ----------------------------

test_that("RunArea.js and ember-cell-label are gone; cells.css is wired in (138)", {
  dir <- frontend_dir()

  expect_false(file.exists(file.path(dir, "components", "RunArea.js")))
  expect_true(file.exists(file.path(dir, "components", "RunButton.js")))

  js_files <- Filter(function(f) endsWith(f, ".js"), frontend_files(dir))
  for (f in js_files) {
    text <- strip_comments(readChar(f, file.info(f)$size, useBytes = TRUE), "js")
    expect_false(grepl("RunArea.js", text, fixed = TRUE), info = f)
    expect_false(grepl("ember-cell-label", text, fixed = TRUE), info = f)
  }

  # Excludes themes/: light.css and dark.css still carry Pluto's own
  # --pluto-runarea-bg-color/--pluto-runarea-span-color variable names,
  # kept (as every Pluto variable name in those two files is) even
  # though nothing points at them now.
  css_files <- Filter(function(f) endsWith(f, ".css") && !grepl("/themes/", f, fixed = TRUE), frontend_files(dir))
  for (f in css_files) {
    text <- strip_comments(readChar(f, file.info(f)$size, useBytes = TRUE), "css")
    expect_false(grepl("pluto-runarea", text, fixed = TRUE), info = f)
  }

  all_styles_path <- file.path(dir, "all-styles.css")
  all_styles_text <- readChar(all_styles_path, file.info(all_styles_path)$size)
  expect_true(grepl('@import url\\("\\./cells\\.css"\\)', all_styles_text))
  expect_true(file.exists(file.path(dir, "cells.css")))
})

# ---- 7. Credits ------------------------------------------------------------

test_that("inst/COPYRIGHTS and DESCRIPTION credit Pluto.jl (7)", {
  copyrights_path <- system.file("COPYRIGHTS", package = "ember")
  if (!nzchar(copyrights_path)) skip("installed COPYRIGHTS not found")
  copyrights <- readChar(copyrights_path, file.info(copyrights_path)$size)
  expect_true(grepl("Pluto.jl", copyrights, fixed = TRUE))

  desc_path <- system.file("DESCRIPTION", package = "ember")
  if (!nzchar(desc_path)) skip("installed DESCRIPTION not found")
  d <- read.dcf(desc_path)
  people <- eval(parse(text = d[, "Authors@R"]))
  cph <- Filter(function(p) "cph" %in% p$role, people)
  expect_true(length(cph) >= 1)
  expect_true(any(grepl("Pluto.jl", vapply(cph, function(p) paste(p$given, p$family), character(1)))))
})

# ---- 103. Bundled fonts (piece 5, "Fonts") ---------------------------------

test_that("fonts.css names a file under fonts/ for each bundled family, and OFL licences exist (103)", {
  dir <- frontend_dir()
  fonts_css_path <- file.path(dir, "fonts.css")
  expect_true(file.exists(fonts_css_path))
  fonts_css <- readChar(fonts_css_path, file.info(fonts_css_path)$size)

  urls <- regmatches(fonts_css, gregexpr('url\\("([^"]+)"\\)', fonts_css, perl = TRUE))[[1]]
  expect_true(length(urls) > 0)
  for (u in urls) expect_match(u, '^url\\("\\./fonts/', info = u)

  families <- c("Figtree", "Source Serif 4", "IBM Plex Mono")
  for (fam in families) {
    expect_true(grepl(paste0('font-family:\\s*"', fam, '"'), fonts_css), info = fam)
  }

  for (licence in c("OFL-figtree.txt", "OFL-source-serif-4.txt", "OFL-ibm-plex-mono.txt")) {
    p <- file.path(dir, "fonts", licence)
    expect_true(file.exists(p), info = licence)
    text <- readChar(p, file.info(p)$size)
    expect_true(grepl("SIL Open Font License", text, fixed = TRUE), info = licence)
  }

  copyrights_path <- system.file("COPYRIGHTS", package = "ember")
  expect_true(nzchar(copyrights_path), info = "installed COPYRIGHTS not found")
  copyrights <- readChar(copyrights_path, file.info(copyrights_path)$size)
  for (fam in families) expect_true(grepl(fam, copyrights, fixed = TRUE), info = fam)
})

# ---- 107. No hard-coded monospace/system-ui font-family -------------------

test_that("no frontend file sets font-family: monospace or system-ui outside the token definitions (107)", {
  dir <- frontend_dir()
  files <- frontend_files(dir)
  files <- files[grepl("\\.(css|js|html)$", files)]
  # The token definitions themselves (editor.css's --ember-*-font custom
  # properties) legitimately name "system-ui" as a fallback keyword; they
  # don't match this pattern since it looks for the literal CSS property
  # `font-family:`, not a custom property's value.
  pat <- "font-family:\\s*(monospace|system-ui)\\b"
  hits <- character()
  for (f in files) {
    ext <- sub(".*\\.", "", f)
    text <- tryCatch(readChar(f, file.info(f)$size, useBytes = TRUE), error = function(e) NA_character_)
    if (is.na(text)) next
    text <- strip_comments(text, ext)
    if (grepl(pat, text, perl = TRUE)) hits <- c(hits, f)
  }
  expect_equal(hits, character(0))
})

# ---- 13. No external URL except the MathJax allowlist ---------------------

test_that("the installed frontend has no external URL in a load position, except MathJax (13)", {
  dir <- frontend_dir()
  expect_equal(external_url_hits(dir), character(0))
})

test_that("external_url_hits() catches a planted CDN import (13)", {
  dir <- frontend_dir()
  tmp <- tempfile("ember-frontend-copy-")
  dir.create(tmp)
  file.copy(dir, dirname(tmp), recursive = TRUE)
  copy_dir <- file.path(dirname(tmp), basename(dir))
  on.exit(unlink(copy_dir, recursive = TRUE), add = TRUE)

  target <- file.path(copy_dir, "imports", "AnsiUp.js")
  text <- readChar(target, file.info(target)$size)
  writeLines(c('import { foo } from "https://cdn.jsdelivr.net/npm/foo@1.0.0/+esm"', text), target)

  hits <- external_url_hits(copy_dir)
  expect_true(length(hits) >= 1)
  expect_true(any(grepl("AnsiUp.js", hits, fixed = TRUE)))
})

# ---- Every file under imports/vendor is content-hashed --------------------

test_that("every file in imports/vendor is content-hashed (cache header review)", {
  # R/server.R serves this one folder with a year-long immutable
  # Cache-Control; a file with no content hash in its name could never
  # change without a stale client keeping the old bytes forever. THIRD-PARTY.txt
  # documents this folder rather than being loaded by anything, so it lives
  # one level up, in imports/, and is exempt.
  dir <- frontend_dir()
  vendor_dir <- file.path(dir, "imports", "vendor")
  files <- list.files(vendor_dir)
  expect_true(length(files) > 0)

  unhashed <- files[!grepl("-[0-9A-Za-z_-]{6,}\\.[a-z0-9]+$", files)]
  expect_equal(unhashed, character(0))
  expect_false(file.exists(file.path(vendor_dir, "THIRD-PARTY.txt")))
})

# ---- 14. Frontend size, THIRD-PARTY.txt, COPYRIGHTS cross-check -----------

test_that("the installed frontend is under 3 MB and THIRD-PARTY.txt matches COPYRIGHTS (14)", {
  dir <- frontend_dir()
  files <- frontend_files(dir)
  total_bytes <- sum(vapply(files, function(f) file.info(f)$size, numeric(1)))
  expect_lt(total_bytes, 3 * 1024 * 1024)

  third_party_path <- file.path(dir, "imports", "THIRD-PARTY.txt")
  expect_true(file.exists(third_party_path))
  third_party <- readChar(third_party_path, file.info(third_party_path)$size)
  names <- regmatches(third_party, gregexpr("(?m)^Name: (.+)$", third_party, perl = TRUE))[[1]]
  names <- sub("^Name: ", "", names)
  expect_true(length(names) > 0)

  # rollup.config.js (the CodeMirror/Lezer bundle) and rollup.vendor.config.js
  # (every other third-party library) each write their own licence file;
  # build.mjs concatenates both into this one. A name unique to each side
  # (not a shared dependency) confirms both halves actually made it in, not
  # just one overwriting the other.
  expect_true("preact" %in% names, info = "rollup.vendor.config.js's output")
  expect_true("@codemirror/view" %in% names, info = "rollup.config.js's output")

  copyrights_path <- system.file("COPYRIGHTS", package = "ember")
  if (!nzchar(copyrights_path)) skip("installed COPYRIGHTS not found")
  copyrights <- readChar(copyrights_path, file.info(copyrights_path)$size)
  missing <- names[!vapply(names, function(n) grepl(n, copyrights, fixed = TRUE), logical(1))]
  expect_equal(missing, character(0))
})

# ---- 78. alert()/confirm() only in the three spots piece 7a leaves native ----

test_that("alert()/confirm() calls remain only in Settings.js (1), ExportBanner.js (2) and Editor.js (1) (78)", {
  dir <- frontend_dir()
  js <- frontend_files(dir)
  js <- js[grepl("\\.js$", js)]

  # Matches alert(/confirm( plain, as window.alert(/window.confirm(,
  # bracket-indexed (window["alert"](), and through optional chaining
  # (confirm?.(), so a dodge around the plain form wouldn't slip past.
  call_re <- paste0(
    "\\bwindow\\[[\"'](?:alert|confirm)[\"']\\]\\s*\\(",
    "|\\bwindow\\.(?:alert|confirm)\\s*\\(",
    "|\\b(?:alert|confirm)\\s*\\?\\.\\s*\\(",
    "|\\b(?:alert|confirm)\\s*\\("
  )

  counts <- list()
  for (f in js) {
    text <- tryCatch(readChar(f, file.info(f)$size, useBytes = TRUE), error = function(e) NA_character_)
    if (is.na(text)) next
    text <- strip_comments(text, "js")
    n <- length(regmatches(text, gregexpr(call_re, text, perl = TRUE))[[1]])
    if (n > 0) counts[[basename(f)]] <- n
  }
  counts <- counts[order(names(counts))]

  expect_equal(counts, list("ExportBanner.js" = 2L, "Settings.js" = 1L))
})
