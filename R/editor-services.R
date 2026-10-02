# Completion, help and signatures (ui-2.md, "4. Editor services"). Pure
# helpers only: the worker query and the request handlers that call them
# live in shell.R and server.R. These never change the notebook, so they
# take `state` (an `ember_state`), not `nb`.

# ---- Completion ----------------------------------------------------------

#' What is being completed, from the page's `query_full` (the cell's text
#' up to the cursor): `list(line, cursor, token, start, namespace)`.
#' `line` is `query_full`'s last line only (a multi-line query is the text
#' before the cursor, and only the current line matters to completion);
#' `cursor` is `line`'s length in UTF-8 bytes. `token` is the identifier
#' being typed, read backwards from the end of `line`; when it is preceded
#' by `pkg::` or `pkg:::`, `namespace` is `pkg` and `token` starts after the
#' colons. `start` is `token`'s UTF-8 byte offset into `line` (and so into
#' `query_full`, since `token` is always on the last line).
completion_context <- function(query_full) {
  query_full <- query_full %||% ""
  lines <- strsplit(query_full, "\n", fixed = TRUE)[[1]]
  line <- if (length(lines) == 0) "" else lines[length(lines)]

  pattern <- "(?:([.\\p{L}\\p{N}_]+)(:::|::))?([.\\p{L}\\p{N}_]*)$"
  m <- regexpr(pattern, line, perl = TRUE)
  starts <- attr(m, "capture.start")[1, ]
  lens <- attr(m, "capture.length")[1, ]

  namespace <- if (lens[1] > 0) substr(line, starts[1], starts[1] + lens[1] - 1) else NULL
  token <- substr(line, starts[3], starts[3] + lens[3] - 1)
  before <- if (starts[3] > 1) substr(line, 1, starts[3] - 1) else ""

  list(line = line, cursor = nchar(line, type = "bytes"), token = token,
      start = nchar(before, type = "bytes"), namespace = namespace,
      field = is.null(namespace) && grepl("[$@]\\s*$", before))
}

#' Base R names, computed once per server process: `ls(baseenv())`, the
#' exports of stats, utils, graphics, grDevices and methods, the datasets,
#' and R's reserved words (design.md, "Editor services").
base_names <- local({
  cache <- NULL
  function() {
    if (is.null(cache)) {
      pkgs <- c("stats", "utils", "graphics", "grDevices", "methods", "datasets")
      exported <- unlist(lapply(pkgs, function(p) {
        tryCatch(getNamespaceExports(p), error = function(e) character())
      }), use.names = FALSE)
      reserved <- c("if", "else", "repeat", "while", "function", "for", "next", "break",
                   "TRUE", "FALSE", "NULL", "Inf", "NaN", "NA", "NA_integer_",
                   "NA_real_", "NA_character_", "NA_complex_", "in", "...")
      cache <<- sort(unique(c(ls(baseenv(), all.names = FALSE), exported, reserved)))
    }
    cache
  }
})

#' Every public definition in `state`'s notebook, across all cells.
notebook_names <- function(state) {
  unique(unlist(lapply(state$graph$cells, function(c) c$definitions), use.names = FALSE))
}

#' Whether `name` is a function, read from `envir` without evaluating an
#' active binding (editor-services.R's callers only ever look at
#' functions and packages' own namespaces, never user data).
is_function_binding <- function(name, envir) {
  active <- tryCatch(bindingIsActive(name, envir), error = function(e) FALSE)
  if (active) return(FALSE)
  val <- tryCatch(get0(name, envir = envir, inherits = FALSE), error = function(e) NULL)
  is.function(val)
}

#' Completion without the worker: the notebook's definitions, the exports
#' of packages any cell attaches (`exports_of(state)`), and base R names;
#' for `pkg::`, only that package's exports. Prefix match, notebook first,
#' at most 500. Returns `list(token, items, too_long)`, `items` a list of
#' `list(name, kind, notebook)` -- the same shape `handle_next()`'s
#' `complete` reply uses, so `completion_reply()` treats both alike.
fallback_completions <- function(state, ctx, base = base_names()) {
  prefix <- ctx$token
  # After `x$` or `x@` only the worker, which has `x`, knows the fields.
  if (isTRUE(ctx$field)) return(list(token = ctx$token, items = list(), too_long = FALSE))

  if (!is.null(ctx$namespace)) {
    # The engine's own tracking (exports_of()) only has a package once some
    # cell attaches it; R's always-loaded default packages (stats, utils,
    # ...) never go through that, so their own namespace is read directly
    # -- never a package the engine hasn't already loaded into this process.
    exports <- exports_of(state)[[ctx$namespace]]
    if (is.null(exports)) {
      exports <- tryCatch(getNamespaceExports(ctx$namespace), error = function(e) character())
    }
    exports <- sort(unique(exports))
    names <- exports[startsWith(exports, prefix)]
    too_long <- length(names) > 500
    if (too_long) names <- names[seq_len(500)]
    items <- lapply(names, function(n) {
      kind <- if (is_function_binding(n, tryCatch(asNamespace(ctx$namespace), error = function(e) baseenv()))) "function" else "other"
      list(name = n, kind = kind, notebook = FALSE)
    })
    return(list(token = ctx$token, items = items, too_long = too_long))
  }

  nb_names <- notebook_names(state)
  nb_hits <- sort(unique(nb_names[startsWith(nb_names, prefix)]))

  pkg_exports <- exports_of(state)
  pkg_hits <- character()
  for (pkg in names(pkg_exports)) {
    ex <- pkg_exports[[pkg]]
    pkg_hits <- c(pkg_hits, ex[startsWith(ex, prefix)])
  }
  pkg_hits <- setdiff(sort(unique(pkg_hits)), nb_hits)

  base_hits <- setdiff(sort(base[startsWith(base, prefix)]), c(nb_hits, pkg_hits))

  ordered <- c(nb_hits, pkg_hits, base_hits)
  too_long <- length(ordered) > 500
  if (too_long) ordered <- ordered[seq_len(500)]

  items <- lapply(ordered, function(n) {
    kind <- if (n %in% nb_hits) "other" else if (is_function_binding(n, baseenv())) "function" else "other"
    list(name = n, kind = kind, notebook = n %in% nb_hits)
  })
  list(token = ctx$token, items = items, too_long = too_long)
}

#' Pluto's `complete_result` reply: `list(start, stop, results, too_long)`.
#' Each result is `arr(text, value_type, is_exported, is_from_notebook,
#' completion_type, NULL)` (CellInput.js:700-708): `value_type` is
#' `"Function"` for a function, else `"Any"`; `completion_type` is
#' `"keyword_argument"` for an argument, `"path"` for a file, else `""`.
#' `is_exported` is always `TRUE`: R has no module-private-symbol styling
#' for the page to show. `start`/`stop` are UTF-8 byte offsets into
#' `query_full`, as the page expects; `stop` is `start` plus the replaced
#' token's byte length. `items` is `ctx`'s token's own `list(token, items,
#' too_long)` (from the worker's `completions` reply, or
#' `fallback_completions()`).
completion_reply <- function(ctx, items) {
  start <- ctx$start
  stop <- start + nchar(ctx$token %||% "", type = "bytes")
  results <- lapply(items$items %||% list(), function(it) {
    kind <- it$kind %||% "other"
    value_type <- if (identical(kind, "function")) "Function" else "Any"
    completion_type <- switch(kind, argument = "keyword_argument", path = "path", "")
    arr(it$name, value_type, TRUE, isTRUE(it$notebook), completion_type, NULL)
  })
  list(start = start, stop = stop, results = as_arr(results), too_long = isTRUE(items$too_long))
}

# ---- Help ------------------------------------------------------------------

#' Split a help query into `list(package, name)`: `"pkg::name"` or
#' `"pkg:::name"` gives both; a bare name gives `package = NULL`.
parse_help_query <- function(query) {
  query <- trimws(query %||% "")
  if (grepl(":::?", query, perl = TRUE)) {
    parts <- strsplit(query, ":::?", perl = TRUE)[[1]]
    return(list(package = parts[1], name = parts[length(parts)]))
  }
  list(package = NULL, name = query)
}

#' `{status: THUMBS_UP, doc: ...}` for a name the notebook itself defines (and no
#' `pkg::` prefix): the defining cell's code, headed "Defined in this
#' notebook". `NULL` when no cell defines `name`, so the caller falls
#' through to the worker or the "needs R running" fallback.
notebook_definition_doc <- function(state, name) {
  for (id in names(state$graph$cells %||% list())) {
    if (name %in% (state$graph$cells[[id]]$definitions %||% character())) {
      code <- state$cells[[id]]$code %||% ""
      return(sprintf("<h2>Defined in this notebook</h2><pre><code class=\"language-r\">%s</code></pre>",
                     html_escape(code)))
    }
  }
  NULL
}

#' Rd2HTML's cross-reference links (with `dynamic = TRUE`) read
#' `../../pkg/help/topic`; LiveDocsTab.js already turns an `@ref` link into
#' a new query (LiveDocsTab.js:126-135), so this is all the rewriting a
#' help page needs. Pure; any other link (an external URL, an anchor) is
#' left alone.
rewrite_help_links <- function(html) {
  gsub('(href=")\\.\\./\\.\\./([^/"]+)/help/([^"]+)(")', "\\1@ref \\2::\\3\\4", html %||% "", perl = TRUE)
}

#' Help HTML is a package's own Rd, not the notebook's: it must never run
#' code or navigate the editor away. Drops `<script>`/`<style>`/`<iframe>`
#' elements (Rd2HTML appends a `<script src="/doc/html/prism.js">` for
#' syntax highlighting the page never needs, since the page does its own),
#' inline event-handler attributes, and `javascript:` links. Pure.
sanitize_help_html <- function(html) {
  html <- html %||% ""
  html <- gsub("(?is)<(script|style|iframe)\\b[^>]*>.*?</\\1\\s*>", "", html, perl = TRUE)
  html <- gsub("(?is)<(script|style|iframe)\\b[^>]*/?>", "", html, perl = TRUE)
  html <- gsub("(?i)\\s+on[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*')", "", html, perl = TRUE)
  html <- gsub("(?i)(href\\s*=\\s*[\"'])\\s*javascript:[^\"']*", "\\1#", html, perl = TRUE)
  html
}

#' The `docs` reply body for a worker's `help_page` message: the sanitized,
#' rewritten page, or, when the topic exists in more than one package, a
#' list of `pkg::topic` links for the user to choose from.
help_reply_html <- function(reply) {
  if (length(reply$matches %||% list()) > 0) {
    items <- vapply(reply$matches, function(m) {
      ref <- sprintf("%s::%s", m$package, m$topic)
      sprintf("<li><a href=\"@ref %s\">%s</a></li>", ref, html_escape(ref))
    }, character(1))
    return(sprintf("<p>More than one package has this topic:</p><ul>%s</ul>", paste(items, collapse = "")))
  }
  rewrite_help_links(sanitize_help_html(reply$html %||% ""))
}

#' `formals()` of a base-R function, for the `docs`/`ember_signature`
#' handlers when the worker can't answer: `formals()` of the function named
#' `name` in `package` (or, when `NULL`, in base, stats, utils, graphics,
#' grDevices or methods -- the server's own R, same version as the
#' worker). `NULL` when no such function exists; no fallback for a
#' notebook or other package's function, which would need R to load it.
signature_fallback <- function(name, package = NULL) {
  pkgs <- if (!is.null(package)) package else c("base", "stats", "utils", "graphics", "grDevices", "methods")
  for (p in pkgs) {
    fn <- tryCatch(get0(name, envir = asNamespace(p), inherits = FALSE), error = function(e) NULL)
    if (is.function(fn)) return(format_signature(name, fn))
  }
  NULL
}

#' `name(arg1, arg2 = default, ...)`, from `args(fn)` deparsed with the
#' trailing `NULL` body dropped and the `function` keyword replaced by
#' `name` -- the same text the worker's `signature` reply sends.
format_signature <- function(name, fn) {
  a <- tryCatch(args(fn), error = function(e) NULL)
  if (is.null(a)) return(NULL)
  d <- deparse(a)
  d <- d[seq_len(max(0, length(d) - 1))]  # drop the trailing "NULL"
  text <- gsub("\\s+", " ", paste(d, collapse = " "))
  text <- sub("^function\\s*", name, text)
  trimws(text)
}
