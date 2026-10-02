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

#' `</script` anywhere in text destined for inside a `<script>` element,
#' escaped so the embedding tag can't be closed early (docs/ui-2.md,
#' "Exports"). Safe to apply to already-JSON-encoded text: a literal
#' `</script` inside a JSON string isn't escaped by `jsonlite::toJSON()`
#' (it doesn't escape `/`), so this still finds it; `JSON.parse()` on the
#' browser side un-escapes `\/` back to `/`, so the decoded value is
#' unchanged.
escape_closing_script <- function(text) {
  gsub("</script", "<\\/script", text, fixed = TRUE)
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
#' server, and these files are already as trusted as the worker that wrote
#' them).
collect_output_deps <- function(state) {
  deps <- list()
  for (r in state$results) {
    if (is.null(r$output) || !identical(r$output$mime, "text/html")) next
    for (d in r$output$deps %||% list()) {
      if (is.null(d$dir)) next
      key <- sprintf("%s-%s", d$name, d$version)
      if (is.null(deps[[key]])) deps[[key]] <- d
    }
  }
  deps
}

#' `html` (one cell's projected `text/html` output body) with every
#' `href="deps/<key>/<file>"` / `src="deps/<key>/<file>"` `project_dep_tags()`
#' wrote turned into a `data:` URL read from `deps[[key]]$dir`. A key not in
#' `deps`, or a file that doesn't exist, is left as it is (the widget then
#' renders without that file, as it would live if the dependency were
#' refused).
inline_output_deps <- function(html, deps) {
  if (length(deps) == 0) return(html)
  pattern <- '(href|src)="deps/([^"/]+)/([^"]+)"'
  regex_replace_fn(html, pattern, function(m) {
    parts <- regmatches(m, regexec(pattern, m, perl = TRUE))[[1]]
    d <- deps[[parts[3]]]
    if (is.null(d)) return(m)
    full <- file.path(d$dir, parts[4])
    if (!file.exists(full)) return(m)
    sprintf('%s="%s"', parts[2], data_url_for_file(full))
  })
}

#' `js` (`pluto_state(state)$js`) with every cell's `text/html` output body
#' passed through `inline_output_deps()`, so widget files are embedded
#' before the state is encoded into the export's `pluto_statefile`.
inline_state_deps <- function(js, state) {
  deps <- collect_output_deps(state)
  if (length(deps) == 0) return(js)
  for (id in names(js$cell_results)) {
    out <- js$cell_results[[id]]$output
    if (is.null(out) || !identical(out$mime, "text/html")) next
    js$cell_results[[id]]$output$body <- inline_output_deps(out$body, deps)
  }
  js
}

#' Static HTML export, self-contained: editor.html with the launch
#' parameters (as increment 1), and the whole frontend inlined -- CSS,
#' favicon/logo, iframe-resizer, and every `.js`/`.json` file keyed for
#' `export-loader.js`'s import map -- so the file opens from `file://`
#' offline (MathJax aside, the one CDN allowlisted) with code highlighted
#' as R and widgets working. `/notebookexport` serves this with or without
#' `offline_bundle=true`: there is no second, smaller export -- the live
#' page and the export already load the same bundled frontend.
export_html <- function(state) {
  frontend_dir <- system.file("frontend", package = "ember")
  template <- read_file_utf8(file.path(frontend_dir, "editor.html"))

  js <- inline_state_deps(pluto_state(state)$js, state)
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
  modules_json <- escape_closing_script(as.character(
    jsonlite::toJSON(modules, auto_unbox = TRUE, null = "null")))
  modules_script <- paste0('<script type="application/json" id="ember-modules">', modules_json, "</script>")
  loader_text <- escape_closing_script(read_file_utf8(file.path(frontend_dir, "export-loader.js")))
  loader_script <- paste0("<script>", loader_text, "</script>")

  html <- sub_literal('<script src="\\./editor\\.js" type="module" defer></script>',
                      paste0(modules_script, loader_script), html)
  html <- sub_literal('<script src="\\./warn_old_browsers\\.js"></script>',
                      paste0("<script>", escape_closing_script(read_file_utf8(
                        file.path(frontend_dir, "warn_old_browsers.js"))), "</script>"),
                      html)

  html
}
