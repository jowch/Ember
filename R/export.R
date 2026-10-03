# Self-contained static export (docs/ui-2.md, "Offline bundle", "Exports").
# export_html(state) embeds the same frontend files the live page loads --
# there is no second build and no CDN root -- so the file opens from disk,
# offline, with code highlighted as R and widgets working. Pure function of
# `state` and the installed frontend folder; no network, no server object.

#' Apply `fn` to every match of `pattern` in `text` and replace it with
#' `fn`'s result. Base R's `gsub()` has no function-replacement form (no
#' `perl`-style `/e`); this is the general substitute, used for every
#' rewrite below (CSS `url()`/`@import`, HTML attributes, JS import
#' specifiers).
regex_replace_fn <- function(text, pattern, fn) {
  m <- gregexpr(pattern, text, perl = TRUE)
  matches <- regmatches(text, m)[[1]]
  if (length(matches) == 0) return(text)
  replacement <- vapply(matches, fn, character(1), USE.NAMES = FALSE)
  regmatches(text, m) <- list(replacement)
  text
}

#' Replace the first match of `pattern` in `text` with the literal string
#' `replacement`. Unlike `sub()`/`gsub()`, a backslash in `replacement`
#' is never reinterpreted (as a backreference, or dropped as an
#' unrecognised escape -- `sub()` does the latter for a plain string
#' replacement, which silently corrupts JSON or JS text that has its own,
#' unrelated backslashes: `"a\\nb"` as a `sub()` replacement inserts `anb`,
#' not `a\nb`). `regmatches<-` does a byte-for-byte substitution instead.
sub_literal <- function(pattern, replacement, text) {
  m <- regexpr(pattern, text, perl = TRUE)
  if (m == -1) return(text)
  regmatches(text, m) <- replacement
  text
}

#' MIME type by extension, for `data:` URLs and the embedded-module script.
mime_for_ext <- function(path) {
  ext <- tolower(tools::file_ext(path))
  switch(ext,
    svg = "image/svg+xml", png = "image/png", css = "text/css",
    js = "text/javascript", mjs = "text/javascript", json = "application/json",
    woff2 = "font/woff2", woff = "font/woff",
    "application/octet-stream")
}

#' `path`'s bytes as a `data:` URL.
data_url_for_file <- function(path) {
  bytes <- readBin(path, "raw", file.info(path)$size)
  paste0("data:", mime_for_ext(path), ";base64,", base64_encode(bytes))
}

#' `</script` anywhere in text destined for inside a *raw* (non-JSON)
#' `<script>` element -- the iframe-resizer scripts, `warn_old_browsers.js`,
#' and `export-loader.js` itself -- escaped case-insensitively (the HTML
#' tokenizer's own end-tag match is case-insensitive: an original file
#' spelling it `</SCRIPT>`, however unlikely, closes the element exactly
#' like `</script>` would) so the embedding tag can't be closed early
#' (docs/ui-2.md, "Exports"). Use `escape_json_for_script()` instead for a
#' JSON block (`#ember-modules`, `#ember-deps`): it also closes off `<!--`,
#' which this narrower escape does not.
escape_closing_script <- function(text) {
  gsub("(?i)</script", "<\\\\/script", text, perl = TRUE)
}

#' Every `<` in `text` (JSON, about to be written into a `<script
#' type="application/json">` element's text content) replaced with the JSON
#' unicode escape `<` -- valid JSON, and decoded back to a literal `<`
#' by `JSON.parse()` -- so neither `</script` (case-insensitively) nor
#' `<!--` can survive to be read by the HTML parser as anything but inert
#' text. `escape_closing_script()`'s narrower, `</script`-only escape still
#' leaves a `<!--<script>...` sequence able to open "script data escaped"
#' state early and change how the rest of the element is tokenized; a
#' frontend `.js` file's own source text, or a cell's HTML output, can
#' contain either sequence in a comment, a string literal, or markup
#' (docs/ui-2.md, "Exports"; a review flagged `<!--` specifically).
escape_json_for_script <- function(text) {
  gsub("<", "\\u003c", text, fixed = TRUE)
}

#' `path`, relative to `base_specifier_dir` (a frontend-relative folder, ""
#' for the frontend root), with `.`/`..` segments collapsed. Pure string
#' arithmetic: no filesystem access, so it works the same whether or not
#' the target exists.
normalize_frontend_path <- function(base_dir, rel_specifier) {
  combined <- if (nzchar(base_dir)) paste0(base_dir, "/", rel_specifier) else rel_specifier
  parts <- strsplit(combined, "/", fixed = TRUE)[[1]]
  stack <- character(0)
  for (p in parts) {
    if (identical(p, ".") || !nzchar(p)) next
    if (identical(p, "..")) stack <- utils::head(stack, -1)
    else stack <- c(stack, p)
  }
  paste(stack, collapse = "/")
}

#' `text` (one frontend `.js` file, whose own frontend-relative path is
#' `rel`) with every relative import specifier -- static `from "..."`,
#' `import "..."`, `export ... from "..."`, and `import("...")` with a
#' literal -- rewritten to the bare key `ember/<path>` the embedded import
#' map will resolve, `<path>` resolved against `rel`'s folder. A specifier
#' that isn't relative (doesn't start with `.`) is left alone: the one
#' computed `import()` in the frontend, `common/Environment.js`, imports a
#' data URL built at run time, never a literal, so it never matches this
#' pattern (checked: docs/ui-2.md, "Exports"; ui-2-tests.md 15).
rewrite_module_specifiers <- function(text, rel) {
  base_dir <- dirname(rel)
  if (identical(base_dir, ".")) base_dir <- ""
  pattern <- '((?:from|import)\\s*\\(?\\s*)"(\\.[^"]*)"'
  regex_replace_fn(text, pattern, function(m) {
    parts <- regmatches(m, regexec(pattern, m, perl = TRUE))[[1]]
    resolved <- normalize_frontend_path(base_dir, parts[3])
    sprintf('%s"ember/%s"', parts[2], resolved)
  })
}

#' Every `.js` and `.json` file under `frontend_dir`, as a named list
#' (frontend-relative path -> file text). `.js` files have their relative
#' import specifiers rewritten first (above); `.json` files are embedded
#' verbatim (lang_imports.js imports one `with { type: "json" }`, an
#' attribute the specifier rewrite leaves untouched since it only touches
#' the quoted string).
embed_modules <- function(frontend_dir) {
  files <- list.files(frontend_dir, pattern = "\\.(js|json)$", recursive = TRUE, full.names = TRUE)
  modules <- vector("list", length(files))
  names_v <- character(length(files))
  for (i in seq_along(files)) {
    rel <- gsub("\\\\", "/", substring(files[i], nchar(frontend_dir) + 2L))
    text <- read_file_utf8(files[i])
    if (grepl("\\.js$", rel)) text <- rewrite_module_specifiers(text, rel)
    names_v[i] <- rel
    modules[[i]] <- text
  }
  names(modules) <- names_v
  modules
}

#' `path` (under `dir`)'s `@import url("...")` lines expanded in place,
#' recursively -- each imported file's own `url()`s resolve against ITS
#' folder, so expansion happens before this file's own `url()`s are
#' rewritten -- and every local `url("./...")` turned into a `data:` URL.
#' `url(data:...)` (none exist yet, but future-proof) and external URLs
#' (the MathJax allowlist is a `<link>`, not CSS, so none are expected
#' here) are left alone.
inline_css <- function(path) {
  dir <- dirname(path)
  text <- read_file_utf8(path)
  text <- regex_replace_fn(text, '@import url\\("([^"]+)"\\);', function(m) {
    rel <- sub('^@import url\\("([^"]+)"\\);$', "\\1", m)
    if (grepl("^https?://", rel)) return(m)
    inline_css(file.path(dir, rel))
  })
  regex_replace_fn(text, 'url\\("(\\.[^"]+)"\\)', function(m) {
    rel <- sub('^url\\("(\\.[^"]+)"\\)$', "\\1", m)
    sprintf('url("%s")', data_url_for_file(file.path(dir, rel)))
  })
}

#' Every dependency any cell's `text/html` output used, keyed the way
#' `project_dep_tags()` spells it in the HTML (`"<name>-<version>"`), read
#' straight from the engine state (not `server$deps`: the export has no
#' server). A `dir` outside the notebook's library is dropped by the same
#' `dep_path_allowed()` check `register_deps()` applies on the live server
#' (R/server.R): the export must never embed a file the live page would have
#' refused to serve, even though nothing here goes through an HTTP route.
collect_output_deps <- function(state) {
  lib <- state$packages$active$path
  deps <- list()
  for (r in state$results) {
    if (is.null(r$output) || !identical(r$output$mime, "text/html")) next
    for (d in r$output$deps %||% list()) {
      if (is.null(d$dir) || !dep_path_allowed(d$dir, lib)) next
      key <- sprintf("%s-%s", d$name, d$version)
      if (is.null(deps[[key]])) deps[[key]] <- d
    }
  }
  deps
}

#' Is `file` (the `<file>` segment of a `deps/<key>/<file>` URL) safe to join
#' onto a dependency's `dir`: no `..` segment and not itself an absolute
#' path. A cell's `text/html` output is notebook content, so this file name
#' is attacker-influenced in principle even once `dir` itself is known-good
#' (`collect_output_deps()`'s `dep_path_allowed()` check) -- without this, a
#' widget's own HTML could still spell `src="deps/<key>/../../../etc/passwd"`
#' and have the export embed a file from outside `dir` entirely.
dep_file_allowed <- function(file) {
  if (is_absolute_path(file)) return(FALSE)
  parts <- strsplit(gsub("\\\\", "/", file), "/", fixed = TRUE)[[1]]
  !(".." %in% parts)
}

#' Every `deps/<key>/<file>` URL referenced in any cell's projected
#' `text/html` output body (`js$cell_results[[id]]$output$body` --
#' `project_dep_tags()`'s own output, identical to what the live page gets,
#' since this reads `js` rather than changing it), mapped to the on-disk
#' file it names, deduplicated by the URL string itself. Earlier, each
#' output's body was rewritten to embed its own `data:` copy of every
#' dependency file it used; ten plotly outputs sharing plotly's ~2 MB bundle
#' each got their own copy, so the export grew to ~20 MB from that one
#' dependency alone and took seconds to assemble on the server's one thread.
#' Reading every body first and returning one url -> path map embeds each
#' distinct file exactly once instead, however many outputs share it; the
#' bodies themselves are never touched, so the live page's HTML and the
#' export's are the same bytes. A `<key>` not in `deps`, a `<file>` that
#' fails `dep_file_allowed()`, or a file that doesn't exist is dropped (the
#' widget then renders without that file in the export, as it would live if
#' the dependency were refused).
collect_dep_file_paths <- function(js, deps) {
  if (length(deps) == 0) return(list())
  pattern <- '(?:href|src)="(deps/([^"/]+)/([^"]+))"'
  paths <- list()
  for (id in names(js$cell_results)) {
    out <- js$cell_results[[id]]$output
    if (is.null(out) || !identical(out$mime, "text/html")) next
    m <- gregexpr(pattern, out$body, perl = TRUE)
    for (txt in regmatches(out$body, m)[[1]]) {
      parts <- regmatches(txt, regexec(pattern, txt, perl = TRUE))[[1]]
      url <- parts[2]
      if (!is.null(paths[[url]])) next
      d <- deps[[parts[3]]]
      if (is.null(d) || !dep_file_allowed(parts[4])) next
      full <- file.path(d$dir, parts[4])
      if (!file.exists(full)) next
      paths[[url]] <- full
    }
  }
  paths
}

#' `collect_dep_file_paths()`'s result read into memory, one `list(mime,
#' data)` (base64) per URL, for the `#ember-deps` JSON block:
#' export-loader.js turns each into one Blob URL, and CellOutput.js rewrites
#' `deps/<key>/<file>` src/href attributes to that Blob URL when the map
#' exists (never on the live page, which has no such map and serves
#' `/deps/<key>/<file>` for real).
dep_files_json <- function(dep_paths) {
  if (length(dep_paths) == 0) return(NULL)
  entries <- lapply(dep_paths, function(full) {
    list(mime = mime_for_ext(full), data = base64_encode(readBin(full, "raw", file.info(full)$size)))
  })
  as.character(jsonlite::toJSON(entries, auto_unbox = TRUE, null = "null"))
}

#' Static HTML export, self-contained: editor.html with the launch
#' parameters (as increment 1), and the whole frontend inlined -- CSS,
#' favicon/logo, iframe-resizer, and every `.js`/`.json` file keyed for
#' `export-loader.js`'s import map -- so the file opens from `file://`
#' offline (MathJax aside, the one CDN allowlisted) with code highlighted
#' as R and widgets working. `/notebookexport` serves this with or without
#' `offline_bundle=true`: there is no second, smaller export -- the live
#' page and the export already load the same bundled frontend. Every
#' cell's `ember$variables` is dropped before encoding: a value the
#' notebook never printed must not land in a downloaded HTML file.
export_html <- function(state) {
  frontend_dir <- system.file("frontend", package = "ember")
  template <- read_file_utf8(file.path(frontend_dir, "editor.html"))

  js <- pluto_state(state)$js
  js$cell_results <- lapply(js$cell_results, function(r) {
    r$ember$variables <- NULL
    r
  })
  statefile <- paste0("data:;base64,", base64_encode(mp_encode(js)))
  text <- format_notebook(notebook_file_of(state))
  notebookfile <- paste0("data:;base64,", base64_encode(charToRaw(enc2utf8(text))))

  params <- paste0(
    '<script data-pluto-file="launch-parameters">',
    "window.pluto_notebook_id = ", js_string_literal(state$id), ";",
    "window.pluto_disable_ui = true;",
    "window.pluto_statefile = ", js_string_literal(statefile), ";",
    "window.pluto_notebookfile = ", js_string_literal(notebookfile), ";",
    "</script>")
  html <- sub_literal('<meta name="pluto-insertion-spot-parameters"[^>]*/?>', params, template)

  html <- regex_replace_fn(html, 'href="(\\./img/[^"]+)"', function(m) {
    rel <- sub('^href="(\\./img/[^"]+)"$', "\\1", m)
    sprintf('href="%s"', data_url_for_file(file.path(frontend_dir, rel)))
  })

  css <- inline_css(file.path(frontend_dir, "all-styles.css"))
  html <- sub_literal('<link rel="stylesheet" href="\\./all-styles\\.css" type="text/css" />',
                      paste0("<style>", escape_closing_script(css), "</style>"), html)

  iframe_pattern <- '<script([^>]*) src="\\./imports/vendor/(iframeResizer[^"]+\\.js)"([^>]*)></script>'
  html <- regex_replace_fn(html, iframe_pattern, function(m) {
    parts <- regmatches(m, regexec(iframe_pattern, m, perl = TRUE))[[1]]
    attrs <- gsub('\\s*crossorigin="[^"]*"', "", paste0(parts[2], parts[4]))
    src_text <- read_file_utf8(file.path(frontend_dir, "imports", "vendor", parts[3]))
    sprintf("<script%s>%s</script>", attrs, escape_closing_script(src_text))
  })

  modules <- embed_modules(frontend_dir)
  modules_json <- escape_json_for_script(as.character(
    jsonlite::toJSON(modules, auto_unbox = TRUE, null = "null")))
  modules_script <- paste0('<script type="application/json" id="ember-modules">', modules_json, "</script>")

  dep_paths <- collect_dep_file_paths(js, collect_output_deps(state))
  deps_json <- dep_files_json(dep_paths)
  deps_script <- if (is.null(deps_json)) "" else {
    paste0('<script type="application/json" id="ember-deps">',
          escape_json_for_script(deps_json), "</script>")
  }

  loader_text <- escape_closing_script(read_file_utf8(file.path(frontend_dir, "export-loader.js")))
  loader_script <- paste0("<script>", loader_text, "</script>")

  html <- sub_literal('<script src="\\./editor\\.js" type="module" defer></script>',
                      paste0(modules_script, deps_script, loader_script), html)
  html <- sub_literal('<script src="\\./warn_old_browsers\\.js"></script>',
                      paste0("<script>", escape_closing_script(read_file_utf8(
                        file.path(frontend_dir, "warn_old_browsers.js"))), "</script>"),
                      html)

  html
}
