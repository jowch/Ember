# The projection: Pluto's notebook object (notebook_to_js's shape) as a pure
# function of the engine's `ember_state`. It is never a second source of
# truth: nothing writes to it but this file, and the server never edits it
# except to record a client's own patches in that client's copy.
#
# Cheap because of reuse. `pluto_state(state, previous)` rebuilds only the
# cells whose engine inputs changed, and hands back the previous object for
# every part that came out equal, so consecutive projections share memory
# the way consecutive engine states do and fb_diff() meets identical R
# objects (design.md, Performance).
#
# Pure: reads only `state` and `previous`. No clock, no IO, no options.

PLUTO_VERSION <- "v1.0.3"

#' Two constant metadata objects, shared by every cell input with that
#' `disabled` value, so cells with the same value are the same R object in
#' every projection. Ember supports only `metadata.disabled`; a client
#' that changes another key gets "\U0001F44E" (see pluto_edits()).
CELL_METADATA <- list(disabled = FALSE, show_logs = TRUE, skip_as_script = FALSE)
CELL_METADATA_DISABLED <- list(disabled = TRUE, show_logs = TRUE, skip_as_script = FALSE)

# ---- The value ---------------------------------------------------------------

#' A projection.
#'
#' * `js`: the frontend notebook object (NotebookData in Editor.js), built
#'   per protocol.R's convention. This is what clients are diffed against.
#' * `state`: the `ember_state` it came from. `identical(state,
#'   previous$state)` (pointer-equal in practice) returns `previous` at once,
#'   which makes extra flushes free.
#' * `keys`: list aligned with `names(js$cell_inputs)`: per cell, the engine
#'   inputs its two entries were built from (see cell_key()). A cell whose
#'   key is identical() keeps its previous entries without rebuilding them.
#' * `graph`: the `ember_graph` `js$cell_dependencies` was built from.
new_pluto_state <- function(js, state, keys, graph) {
  structure(list(js = js, state = state, keys = keys, graph = graph),
            class = "ember_pluto_state")
}

#' Project the engine's state.
#'
#' @param state `ember_state` (notebook_state(nb)).
#' @param previous The last `ember_pluto_state` for this notebook, or NULL.
#' @return `ember_pluto_state`. Invariants (tested):
#'   * `pluto_state(s, p)$js` equals `pluto_state(s, NULL)$js` (reuse never
#'     changes values, only which objects hold them);
#'   * `check_wire(result$js)` passes;
#'   * if only cell `a`'s engine inputs changed, every patch of
#'     `fb_diff(previous$js, result$js)` is under `cell_results/a`,
#'     `cell_inputs/a` or a top-level scalar.
pluto_state <- function(state, previous = NULL) {
  if (!is.null(previous) && identical(state, previous$state)) return(previous)
  pj  <- previous$js
  ctx <- view_context(state)            # state.R: queued set, waiting,
                                        # errors by cell, running id, once
                                        # per call
  ids <- ctx$ids; n <- length(ids)
  at  <- if (is.null(pj)) rep(NA_integer_, n) else match(ids, names(pj$cell_inputs))
                                             # one match, never `[[name]]`
                                             # in a loop (quadratic, spike)
  inputs <- results <- keys <- vector("list", n)
  for (i in seq_len(n)) {
    j <- at[i]
    prev_key <- if (!is.na(j) && !is.null(previous)) previous$keys[[j]] else NULL
    # `key_unchanged()` compares this cell's inputs against `prev_key`'s
    # fields directly, with no new list built: at 2000 cells, most calls
    # land here, and building a fresh `cell_key()` list just to throw it
    # away on an `identical()` match would cost as much as the rebuild it's
    # meant to avoid (the spike's 0.95ms-per-changed-cell number assumes
    # this). Every lookup inside is by position `i` (state.R's
    # view_context()), never by id: a 2000-cell notebook made the named
    # lookups alone cost tens of milliseconds (measured).
    if (!is.null(prev_key) && key_unchanged(state, ctx, i, prev_key)) {
      keys[[i]] <- prev_key
      inputs[i] <- pj$cell_inputs[j]; results[i] <- pj$cell_results[j]
    } else {
      keys[[i]] <- cell_key(state, ctx, i)
      view <- cell_view(state, ctx, i)          # state.R, shared with snapshot_of()
      old_input  <- if (!is.na(j)) pj$cell_inputs[[j]] else NULL
      old_result <- if (!is.na(j)) pj$cell_results[[j]] else NULL
      inputs[[i]]  <- reuse(project_cell_input(view),  old_input)
      results[[i]] <- reuse(project_cell_result(view, ids), old_result)
    }
  }
  names(inputs) <- names(results) <- ids

  # `edges` and `cells` (for `attaches`) are everything project_dependencies()
  # reads from the graph; comparing just those, instead of the whole graph
  # object, skips a full O(cells) rebuild on a plain code edit that doesn't
  # touch any cell's references (the common case: `graph$analyses` and
  # `graph$cells` differ for the edited cell regardless, so the whole-graph
  # `identical()` a code edit would otherwise force can't be used as the
  # gate here).
  unchanged_deps <- !is.null(previous) && !is.null(previous$state$graph) &&
    identical(state$graph$edges, previous$state$graph$edges) &&
    identical(state$graph$cells, previous$state$graph$cells)
  deps <- if (unchanged_deps) {
    pj$cell_dependencies
  } else {
    project_dependencies(state$graph, if (!is.null(pj)) pj$cell_dependencies else NULL)
  }

  js <- list(
    pluto_version = PLUTO_VERSION,
    julia_version = paste("R", state$options$r$version),
    notebook_id = state$id, path = state$path, shortpath = basename(state$path),
    in_temp_dir = FALSE,
    process_status = project_process_status(state),
    last_save_time = 0, last_hot_reload_time = 0,   # unused by the frontend
    cell_inputs  = reuse(inputs,  if (!is.null(pj)) pj$cell_inputs else NULL),
    cell_results = reuse(results, if (!is.null(pj)) pj$cell_results else NULL),
    cell_order = reuse(as_arr(ids), if (!is.null(pj)) pj$cell_order else NULL),
    published_objects = emptymap(), bonds = emptymap(), metadata = emptymap(),
    nbpkg = reuse(project_nbpkg(state), if (!is.null(pj)) pj$nbpkg else NULL),
    cell_dependencies = deps,
    cell_execution_order = reuse(as_arr(state$graph$order), if (!is.null(pj)) pj$cell_execution_order else NULL),
    ember = reuse_fields(project_ember(state, ctx), if (!is.null(pj)) pj$ember else NULL))
  new_pluto_state(js, state, keys, state$graph)
}

#' What a cell's two entries depend on, as a list whose big parts are the
#' engine's own shared objects, so comparing two keys is pointer comparisons
#' plus a few scalars.
#'
#' `list(cell = state$cells[[id]], result = state$results[[id]],
#'       console = <worker$running$console when this cell runs, else NULL>,
#'       flags = ctx$flags[[id]],   # queued, running, waiting_for
#'       errors = ctx$errors[[id]], # graph errors on this cell: shared within one graph
#'       disabled_by = ctx$disabled_by[[id]],  # off, from graph$off
#'       allowed = state$allowed)   # sanitize/preview only changes with this
#'
#' Must cover every input cell_view() reads for this cell; a missed input
#' shows as a stale cell in the browser. Tested by building every engine
#' fixture's projection with and without `previous` and comparing.
#'
#' Fields are raw `ctx` lookups, not the normalised (`%||%`-defaulted)
#' values `cell_view()` shows: the key only ever answers "did this cell's
#' inputs change", so `NULL` (not queued, no error, nothing waiting) is as
#' good a sentinel as a filled-in default. Every lookup is by position `i`
#' (`ctx$ids[i]` is this cell's id), never by id: see view_context()'s doc
#' in state.R for why that matters at 2000 cells. `disabled_by` is kept as
#' `NA` rather than left absent when there's nothing to report (it is a
#' plain character vector, so `ctx$disabled_by[[i]]` is always `NA`, never
#' `NULL`); the cell's own `disabled` flag is already in the key through
#' `cell`, so only the dependent relationship needs this field.
#' `can_disable` needs no key field: it depends only on `kind` (in `cell`)
#' and `setup`, which never changes after open.
cell_key <- function(state, ctx, i) {
  id <- ctx$ids[[i]]
  running <- ctx$running
  is_running <- !is.null(running) && identical(running$cell, id)
  list(cell = state$cells[[i]], result = ctx$results[[i]],
       is_running = is_running, console = if (is_running) running$console else NULL,
       queued = ctx$queued[[i]], waiting_for = ctx$waiting[[i]],
       errors = ctx$errors_by_cell[[i]], disabled_by = ctx$disabled_by[[i]],
       allowed = state$allowed)
}

#' `identical(cell_key(state, ctx, i), prev_key)`, field by field against an
#' already-built key, with no new list allocated to do the comparison. At
#' 2000 cells this is what keeps an edit to one cell cheap: building a fresh
#' key for all 1999 untouched cells just to `identical()` it away would cost
#' as much as the `reuse()` it's meant to avoid. Must compare exactly the
#' fields `cell_key()` builds.
key_unchanged <- function(state, ctx, i, prev_key) {
  if (!identical(state$cells[[i]], prev_key$cell)) return(FALSE)
  id <- ctx$ids[[i]]
  if (!identical(ctx$results[[i]], prev_key$result)) return(FALSE)
  running <- ctx$running
  is_running <- !is.null(running) && identical(running$cell, id)
  if (!identical(is_running, prev_key$is_running)) return(FALSE)
  if (!identical(if (is_running) running$console else NULL, prev_key$console)) return(FALSE)
  if (!identical(ctx$queued[[i]], prev_key$queued)) return(FALSE)
  if (!identical(ctx$waiting[[i]], prev_key$waiting_for)) return(FALSE)
  if (!identical(ctx$errors_by_cell[[i]], prev_key$errors)) return(FALSE)
  if (!identical(ctx$disabled_by[[i]], prev_key$disabled_by)) return(FALSE)
  identical(state$allowed, prev_key$allowed)
}

# ---- Cells -------------------------------------------------------------------

#' CellInputData. `metadata` is the shared CELL_METADATA or
#' CELL_METADATA_DISABLED, picked by `view$disabled`, so cells still share
#' one R object each. `kind` is `view$kind` ("code" or "markdown"); the
#' cell key already covers it (it holds `state$cells[[i]]`).
project_cell_input <- function(view) {
  list(cell_id = view$id, code = view$code, code_folded = view$folded,
       kind = view$kind,
       metadata = if (isTRUE(view$disabled)) CELL_METADATA_DISABLED else CELL_METADATA)
}

#' CellResultData from an `ember_cell_view` (state.R).
#'
#' * `queued`, `running`: the view's.
#' * `errored`: any error on the view, or status "error"/"interrupted".
#' * `runtime`: seconds -> nanoseconds as a double, or NULL when not run.
#' * `depends_on_disabled_cells`: `view$disabled || !is.na(view$disabled_by)`
#'   (Pluto's own field, Run.jl:86-91) -- true for a disabled cell itself,
#'   too.
#' * `ember`: `list(stale, code_changed, upstream_error?, disabled_by?,
#'   can_disable, split?, figure?)`, from the view's `stale` and
#'   `code_differs` -- both already in `cell_key()`'s key (`code_differs`
#'   is derived from `cell$code` and `result$code`). `stale` is
#'   `isTRUE(view$stale) && !off`: an off cell shows as disabled, not also
#'   as stale.
#'   `upstream_error` is present only when the last error's kind is
#'   `"upstream"`, as `as_arr(list(list(name, cell), ...))` from that
#'   error's `names`/`cells` (also in the key, through `result`). The page
#'   shows a "stale" or "code changed" label (ui-2.md, 5); an upstream
#'   error is an ordinary error box, not a dimmed/labelled cell.
#'   `disabled_by` is present only for a dependent of a disabled cell
#'   (absent for the disabled cell itself). `can_disable` is `TRUE` for a
#'   non-setup code cell. `split` is present, as `length(split_mixed(view$code))`,
#'   only when `view$errors` has a `mixed_text` error: the Split button's
#'   label (Cell.js), answered by the `ember_split_cell` request (server.R).
#'   `figure` is present, as `list(width, height)` inches, only when the
#'   output is `image/png`. It comes from `cell_figure_size(view$code)` --
#'   the cell's own `#|` lines -- never from the stored image's actual
#'   pixel size: an API `render_png(width, height)` call replaces that
#'   stored image (it's an Endeavor-facing API, left as is) without
#'   changing the cell's figure size every other viewer sees, so reading
#'   the size back out of it would make one such call resize the figure
#'   on every open page. `code` is already in the key (through `cell`).
#'   `variables` is present, as `as_arr(view$variables)` (already
#'   `list(name, type, value, kind)` per global, sorted, dot-names and an
#'   off cell's excluded by `cell_variables()`), only when non-empty: the
#'   Variables tab's contract. It comes from `result`, already in the key.
#' * `output`: project_output() of the view.
#' * `logs`: project_logs() of the view's console.
#' * `published_object_keys = list()`, `depends_on_skipped_cells = FALSE`.
project_cell_result <- function(view, known_ids = NULL) {
  errored <- length(view$errors) > 0 || view$status %in% c("error", "interrupted")
  last_error <- if (length(view$errors) > 0) view$errors[[length(view$errors)]] else NULL
  upstream_error <- if (!is.null(last_error) && identical(last_error$kind, "upstream")) {
    as_arr(Map(function(n, c) list(name = n, cell = c), last_error$names, last_error$cells))
  } else {
    NULL
  }
  mixed <- Find(function(e) identical(e$kind, "mixed_text"), view$errors)
  split <- if (!is.null(mixed)) length(split_mixed(view$code)) else NULL
  off <- isTRUE(view$disabled) || !is.na(view$disabled_by)
  can_disable <- identical(view$kind, "code") && !view$setup
  figure <- if (!is.null(view$output) && identical(view$output$mime, "image/png")) {
    fig <- cell_figure_size(view$code)
    list(width = fig$width, height = fig$height)
  } else {
    NULL
  }
  ember <- c(list(stale = isTRUE(view$stale) && !off, code_changed = isTRUE(view$code_differs)),
            if (!is.null(upstream_error)) list(upstream_error = upstream_error),
            if (!is.na(view$disabled_by)) list(disabled_by = view$disabled_by),
            list(can_disable = can_disable),
            if (!is.null(split)) list(split = split),
            if (!is.null(figure)) list(figure = figure),
            if (length(view$variables) > 0) list(variables = as_arr(view$variables)))
  list(cell_id = view$id,
      queued = isTRUE(view$queued), running = isTRUE(view$running),
      errored = errored,
      runtime = if (is.null(view$runtime)) NULL else as.double(view$runtime) * 1e9,
      depends_on_disabled_cells = off,
      ember = ember,
      output = project_output(view, known_ids),
      logs = project_logs(view$console, view$id),
      published_object_keys = list(), depends_on_skipped_cells = FALSE)
}

#' The `output` field: `list(body, mime, rootassignee = NULL,
#' last_run_timestamp, persist_js_state = FALSE, has_pluto_hook_features =
#' FALSE)`. `last_run_timestamp` is `max(as.numeric(view$last_run),
#' as.numeric(view$output$rendered_at))` (or 0): a re-render (a paged table
#' or tree, a resized plot) bumps it the same way a fresh run would, which
#' is what makes CellOutput.js redraw (ui-2.md, 3c).
#'
#' Precedence: an error on the view wins over the display, as Pluto shows a
#' cell's error in place of its output.
#'
#' | view                         | mime                                     | body                       |
#' |------------------------------|------------------------------------------|----------------------------|
#' | graph error, kind "parse"    | application/vnd.pluto.parseerror+object  | list(diagnostics = ...)    |
#' | any other error              | application/vnd.pluto.stacktrace+object  | project_error()            |
#' | status "interrupted"         | application/vnd.pluto.stacktrace+object  | msg "Interrupted", no frames |
#' | no output (not run, NULL)    | text/plain                               | ""                         |
#' | text/plain                   | text/plain                               | data (ANSI kept; the frontend colours it) |
#' | text/html                    | text/html                                | data, with dependency `<link>`/`<script>` tags prepended (3d) |
#' | image/png                    | image/png                                | data (raw -> msgpack bin)  |
#' | image/svg+xml                | image/svg+xml                            | data                       |
#' | text/markdown (and a text cell without values) | text/html if commonmark is installed in the server's library, else text/plain | rendered / text |
#' | application/vnd.ember.table  | application/vnd.pluto.table+object       | project_table(data)        |
#' | application/vnd.ember.tree   | application/vnd.pluto.tree+object        | project_tree(data)         |
#' | text/latex, anything else    | text/plain                                | `text` (the print() form)  |
#'
#' The running cell shows its previous output, as the snapshot does. A text
#' cell's errors (including a parse error: its line numbers are in
#' `inline_code()`'s analysed code, not the cell's own, so
#' `project_parse_error()` would misalign them) show as for code, ahead of
#' `project_text()` -- the one place a text cell without inline values still
#' takes the early return a code cell never reaches, since it has no
#' `output` to fall through to.
project_output <- function(view, known_ids = NULL) {
  last_ts <- if (is.null(view$last_run)) 0 else as.numeric(view$last_run)
  if (!is.null(view$output) && !is.null(view$output$rendered_at)) {
    last_ts <- max(last_ts, as.numeric(view$output$rendered_at))
  }
  wrap <- function(mime, body) list(body = body, mime = mime, rootassignee = NULL,
                                    last_run_timestamp = last_ts, persist_js_state = FALSE,
                                    has_pluto_hook_features = FALSE)

  parse_err <- if (!identical(view$kind, "markdown")) {
    Find(function(e) identical(e$kind, "parse"), view$errors)
  } else NULL
  if (!is.null(parse_err)) {
    return(wrap("application/vnd.pluto.parseerror+object",
               project_parse_error(parse_err, view$code)))
  }
  if (length(view$errors) > 0) {
    return(wrap("application/vnd.pluto.stacktrace+object",
               project_error(view$errors[[length(view$errors)]], known_ids)))
  }
  if (identical(view$status, "interrupted")) {
    return(wrap("application/vnd.pluto.stacktrace+object",
               list(msg = "Interrupted", stacktrace = list(), plain_error = "Interrupted")))
  }

  if (identical(view$kind, "markdown")) return(project_text(view, wrap))

  out <- view$output
  if (is.null(out)) return(wrap("text/plain", ""))

  switch(out$mime,
    "text/plain" = wrap("text/plain", out$data %||% out$text),
    "text/html" = wrap("text/html", paste0(project_dep_tags(out$deps), out$data)),
    "image/png" = wrap("image/png", out$data),
    "image/svg+xml" = wrap("image/svg+xml", out$data),
    "text/markdown" = if (commonmark_available()) wrap("text/html", render_markdown(out$data))
                      else wrap("text/plain", out$data),
    "application/vnd.ember.table" = wrap("application/vnd.pluto.table+object", project_table(out$data)),
    "application/vnd.ember.tree" = wrap("application/vnd.pluto.tree+object", project_tree(out$data)),
    wrap("text/plain", out$text))
}

#' A text cell's body, wrapped with `wrap()` (`project_output()`'s own,
#' passed through so `last_run_timestamp` is computed once). `values` is
#' `view$output$data$values` when the output is `application/vnd.ember.inline`
#' and `!view$code_differs` (a run whose code the cell no longer has), else
#' `NULL`.
#'
#' Without values: the body (`text_body(view$code)`, the `#'` prefixes
#' stripped) is rendered as written, so each `` `r expr` `` shows as a
#' markdown code span.
#'
#' With values: each inline span is replaced by a plain token
#' ("EMBERINLINE<k>X", left alone by commonmark even inside a code span or
#' link) before rendering, then each token is replaced by its value --
#' `<span class="ember-inline">html-escaped value</span>` once rendered as
#' HTML, so a value is never itself interpreted as markup (ui-3.md,
#' Accessibility: "inline values read as plain text").
#'
#' Without commonmark: `text/plain`, with the values (without values, the
#' spans) put in as plain text -- no tokens, no escaping, no `<span>`.
project_text <- function(view, wrap) {
  body_lines <- text_body(view$code)
  body <- paste(body_lines, collapse = "\n")
  out <- view$output
  values <- if (!is.null(out) && identical(out$mime, "application/vnd.ember.inline") &&
                !isTRUE(view$code_differs)) {
    out$data$values
  } else {
    NULL
  }
  if (is.null(values)) {
    if (commonmark_available()) return(wrap("text/html", render_markdown(body)))
    return(wrap("text/plain", body))
  }

  # Marked line by line with replace_inline_matches() (text-cells.R), not
  # a single sub() over the whole multi-line body: `[^`]+` in
  # inline_span_pattern isn't anchored to one line, so a plain whole-body
  # match (unlike inline_spans(), which inline_code() already indexes
  # `values` by) can run past a line break onto the next span entirely.
  idx <- 0L
  tokens <- sprintf("EMBERINLINE%dX", seq_len(length(values)))
  marked_lines <- vapply(body_lines, function(ln) {
    mm <- line_inline_matches(ln)
    if (length(mm$exprs) == 0) return(ln)
    this_tokens <- tokens[idx + seq_along(mm$exprs)]
    idx <<- idx + length(mm$exprs)
    replace_inline_matches(ln, this_tokens)
  }, character(1), USE.NAMES = FALSE)
  marked <- paste(marked_lines, collapse = "\n")

  if (!commonmark_available()) {
    plain <- marked
    for (k in seq_along(tokens)) plain <- sub(tokens[[k]], values[[k]], plain, fixed = TRUE)
    return(wrap("text/plain", plain))
  }
  rendered <- render_markdown(marked)
  for (k in seq_along(tokens)) {
    rendered <- replace_inline_token(rendered, tokens[[k]], values[[k]])
  }
  wrap("text/html", rendered)
}

#' Replace one occurrence of `token` in `rendered` HTML with `value`: a
#' plain, HTML-escaped value when `token` sits inside an open tag's
#' attribute (e.g. a link's `href`, from a span inside `[text](` `r
#' url` `)`) -- markup there would corrupt the attribute, not display --
#' else the value wrapped in `<span class="ember-inline">`, as a value
#' outside an attribute always is.
replace_inline_token <- function(rendered, token, value) {
  pos <- regexpr(token, rendered, fixed = TRUE)[[1]]
  if (pos == -1) return(rendered)
  escaped <- html_escape(value)
  replacement <- if (inside_html_attribute(rendered, pos)) {
    escaped
  } else {
    sprintf('<span class="ember-inline">%s</span>', escaped)
  }
  sub(token, replacement, rendered, fixed = TRUE)
}

#' `TRUE` when character offset `pos` (1-based, where `token` is about to
#' be inserted) sits inside an HTML tag's attribute value: the last `<`
#' before `pos` comes after the last `>` (an open tag, not plain text
#' between tags), and the tag text since that `<` ends in an unclosed
#' `="..."` (an attribute has been opened but not yet closed). Checked
#' textually, not by parsing HTML: the only shape commonmark ever builds
#' around an inline token is a plain attribute value (a link's `href`, an
#' image's `src`), never a nested tag.
inside_html_attribute <- function(rendered, pos) {
  before <- substr(rendered, 1, pos - 1)
  lt <- gregexpr("<", before, fixed = TRUE)[[1]]
  gt <- gregexpr(">", before, fixed = TRUE)[[1]]
  last_lt <- if (lt[[1]] == -1) 0L else max(lt)
  last_gt <- if (gt[[1]] == -1) 0L else max(gt)
  if (last_lt <= last_gt) return(FALSE)
  grepl('="[^"]*$', substr(before, last_lt, nchar(before)))
}

#' `script_entry`'s `src` joined onto `base`, plus any other named element
#' (`type`, `integrity`, ...) as its own HTML attribute. htmltools allows a
#' dependency's `script` list to mix plain file names with such a list
#' (e.g. `list(src = "a.js", type = "module")`, for a script that needs an
#' attribute beyond `src`); a plain file name is the common case of this
#' with no extra attributes.
dep_script_tag <- function(base, script_entry) {
  if (is.list(script_entry)) {
    src <- script_entry$src
    extra <- script_entry[setdiff(names(script_entry), "src")]
    attrs <- paste(vapply(names(extra), function(n) sprintf(' %s="%s"', n, extra[[n]]), character(1)),
                   collapse = "")
  } else {
    src <- script_entry
    attrs <- ""
  }
  sprintf('<script src="%s%s"%s></script>', base, src, attrs)
}

#' `<link>`/`<script>` tags for an HTML output's widget dependencies, in
#' order, prepended to the HTML (ui-2.md, 3d). A dependency with only
#' `href` uses that URL directly (normalized to end in "/", the way
#' htmltools joins a dependency's base with each file: a bare `href` with no
#' trailing slash, such as `"https://cdn.example.com/lib"`, would otherwise
#' have its first file concatenated straight onto it with nothing between
#' them); one resolved to a notebook-library folder uses
#' `deps/<name>-<version>/<file>` (server.R's register_deps()), already
#' built with a trailing slash, relative so it stays under a proxy's path
#' prefix. If any dependency is named "htmlwidgets", a script asking it to
#' render appends after the tags (htmlwidgets only binds on
#' DOMContentLoaded by itself). Pluto's script runner already copies each
#' `<script src>` into the page head once and runs it before inline scripts
#' (CellOutput.js), so loading a library once across many outputs needs no
#' further page change.
project_dep_tags <- function(deps) {
  if (length(deps) == 0) return("")
  tags <- character()
  has_htmlwidgets <- FALSE
  for (d in deps) {
    base <- if (!is.null(d$href)) d$href else sprintf("deps/%s-%s/", d$name, d$version)
    if (nzchar(base) && !endsWith(base, "/")) base <- paste0(base, "/")
    if (identical(d$name, "htmlwidgets")) has_htmlwidgets <- TRUE
    for (f in d$stylesheet %||% character()) {
      tags <- c(tags, sprintf('<link rel="stylesheet" href="%s%s">', base, f))
    }
    for (sc in d$script %||% list()) {
      tags <- c(tags, dep_script_tag(base, sc))
    }
    if (!is.null(d$head)) tags <- c(tags, d$head)
  }
  if (has_htmlwidgets) {
    tags <- c(tags, "<script>window.HTMLWidgets && HTMLWidgets.staticRender()</script>")
  }
  paste(tags, collapse = "")
}

#' Ember's table display as Pluto's table body (TreeView.js:203-262):
#' `list(objectid = "", ember_size = arr(nrow, ncol, more_rows, more_cols),
#' ember_na = arr(arr(<0-based column>, ...), ...) one per shown row,
#' schema = list(names = arr(names, "more"?), types = arr(types, "more"?)),
#' rows = list(arr(label, arr(arr(text, "text/plain"), ..., "more"?)), ...,
#' "more"?))`. "more" after the names and in each row when `more_cols > 0`;
#' a final "more" row when `more_rows > 0`. `objectid` `""` is the table
#' itself (what `reshow_cell` sends back). `data$na` is missing for an
#' older display fixture, read as no NA anywhere.
project_table <- function(data) {
  names_l <- as.list(data$names)
  types_l <- as.list(data$types)
  if (data$more_cols > 0) {
    names_l <- c(names_l, list("more"))
    types_l <- c(types_l, list("more"))
  }
  rows <- lapply(seq_along(data$rows), function(i) {
    cells <- lapply(data$rows[[i]], function(text) arr(text, "text/plain"))
    if (data$more_cols > 0) cells <- c(cells, list("more"))
    arr(data$row_labels[[i]], as_arr(cells))
  })
  if (data$more_rows > 0) rows <- c(rows, list("more"))
  # `data[["na", exact = TRUE]]`, not `data$na`: partial matching on `$`
  # would otherwise read `data$names` for a fixture with no `na` field.
  na_rows <- data[["na", exact = TRUE]] %||% rep(list(integer()), length(data$rows))
  ember_na <- lapply(na_rows, function(cols) as_arr(as.integer(cols - 1L)))
  list(objectid = "", ember_size = arr(data$nrow, data$ncol, data$more_rows, data$more_cols),
      ember_na = as_arr(ember_na),
      schema = list(names = as_arr(names_l), types = as_arr(types_l)),
      rows = as_arr(rows))
}

#' Pluto's tree body (TreeView.js:105-180): `list(objectid = path, type =
#' "r_list", prefix = "list", prefix_short = "", ember_length = n, elements =
#' list(arr(key, arr(<body>, <mime>)), ..., "more"?))`. A text leaf is
#' `arr(text, "text/plain")`; a long-vector leaf is
#' `arr(list(values, type_sum, length), "application/vnd.ember.vector+object")`
#' (worker.R's `display_tree_node()`, `type = "vector"`); a node is
#' `arr(project_tree(node), "application/vnd.pluto.tree+object")`. `data` is
#' one worker tree node (worker.R, 3c: `list(type, path, length, named,
#' items, more)`).
project_tree <- function(data) {
  elements <- lapply(data$items %||% list(), function(it) {
    pair <- if (identical(it$value$type, "text")) {
      arr(it$value$text, "text/plain")
    } else if (identical(it$value$type, "vector")) {
      arr(list(values = as_arr(it$value$values), type_sum = it$value$type_sum,
               length = it$value$length), "application/vnd.ember.vector+object")
    } else {
      arr(project_tree(it$value), "application/vnd.pluto.tree+object")
    }
    arr(it$key, pair)
  })
  if (!is.null(data$more) && data$more > 0) elements <- c(elements, list("more"))
  list(objectid = data$path, type = "r_list", prefix = "list", prefix_short = "",
      ember_length = data$length, elements = as_arr(elements))
}

#' Join names the way the frontend's rewritten messages read: one name as
#' is, two with `conj`, more as a comma list with `conj` before the last.
#' `conj` is `"and"` for multiple definitions and cycles, `"or"` for an
#' upstream error (several names could each fix the cell; any one would do).
join_names <- function(names, conj = "and") {
  if (length(names) <= 1) return(if (length(names) == 0) "" else names)
  if (length(names) == 2) return(paste(names, collapse = paste0(" ", conj, " ")))
  paste0(paste(names[-length(names)], collapse = ", "), " ", conj, " ", names[length(names)])
}

#' A stack-trace body: `list(msg, stacktrace, plain_error)`.
#'
#' `msg` is written to match the frontend's rewriters where Pluto has one:
#' "Multiple definitions for x and y" and "Cyclic references among a, b."
#' are built from the error's `names` (the engine's own `message` reads
#' differently); every other kind uses the engine's `message`. Each of the
#' error's `fixes` is a further line (ErrorMessage.js is changed to show
#' those lines as they are instead of Julia's "begin ... end" hint).
#'
#' `"upstream"` is its own case: `msg` is "Another cell defining a contains
#' errors." (names joined with "or": any one of them failing is enough),
#' `stacktrace` is empty (there is nothing of the engine's own to show), and
#' `plain_error` is `msg` plus R's own message on a second line, for anyone
#' who copies it -- unlike every other kind, where `plain_error` is just
#' `msg` (with `fixes`), because the engine's own `message` already reads
#' that way.
#'
#' `stacktrace`: one frame per traceback call, innermost first:
#' `list(call, call_short, func, inlined = FALSE, from_c = FALSE, file = "",
#' path = "", line = -1L, linfo_type = "", url = NULL, source_package =
#' NULL, parent_module = NULL, ember_cell = NULL)`. R tracebacks have no
#' file and line unless srcrefs are kept; `file = ""` keeps the frontend
#' from linking frames to cells. `source_package` and `ember_cell` come
#' from `error$frames` (worker.R's `clean_frames()`, also innermost last,
#' same length as `traceback`), read by the matching reversed position.
#' `ember_cell` is dropped (set to `NULL`) when it isn't one of
#' `known_ids` -- a frame's srcref file name can be `"<text>"` (a text
#' cell's per-line parse, which keeps no srcfile), a `source()`d file's
#' path, or a package built with `keep.source`, none of them a real cell
#' id. `known_ids = NULL` (the default, every caller but
#' `project_output()`) skips the check.
#'
#' `ember_call`, `ember_line` and `ember_deep` are `error$call`,
#' `error$line` and `error$deep` -- unset (`NULL`/`FALSE`) for an upstream
#' error or any kind besides a plain "error", since those have nothing of
#' the engine's own to show there.
project_error <- function(error, known_ids = NULL) {
  if (identical(error$kind, "upstream")) {
    msg <- sprintf("Another cell defining %s contains errors.", join_names(error$names, conj = "or"))
    return(list(msg = msg, stacktrace = list(), plain_error = paste(msg, error$message, sep = "\n"),
               ember_call = NULL, ember_line = NULL, ember_deep = FALSE))
  }
  msg <- switch(error$kind,
    multiple_definitions = sprintf("Multiple definitions for %s", join_names(error$names)),
    cycle = sprintf("Cyclic references among %s.", join_names(error$names)),
    error$message)
  text <- paste(c(msg, error$fixes), collapse = "\n")
  rev_traceback <- rev(error$traceback %||% character())
  rev_frames <- rev(error$frames %||% list())
  stacktrace <- lapply(seq_along(rev_traceback), function(k) {
    fr <- if (k <= length(rev_frames)) rev_frames[[k]] else NULL
    cell <- fr$cell %||% NULL
    if (!is.null(cell) && !is.null(known_ids) && !(cell %in% known_ids)) cell <- NULL
    list(call = rev_traceback[[k]], call_short = rev_traceback[[k]], func = NULL,
        inlined = FALSE, from_c = FALSE, file = "", path = "", line = -1L,
        linfo_type = "", url = NULL, source_package = fr$package %||% NULL,
        parent_module = NULL, ember_cell = cell)
  })
  list(msg = text, stacktrace = stacktrace, plain_error = text,
      ember_call = error$call, ember_line = error$line, ember_deep = isTRUE(error$deep))
}

#' Parse-error diagnostics: `list(list(message, from, to, line))` from the
#' graph error's `lines`; `from`/`to` are the 0-based character offsets of
#' that whole line in the cell's code (the engine has no column).
project_parse_error <- function(error, code) {
  lines <- strsplit(code, "\n", fixed = TRUE)[[1]]
  if (length(lines) == 0) lines <- ""
  nch <- nchar(lines, type = "chars")
  starts <- cumsum(c(0, nch[-length(nch)] + 1))
  ends <- starts + nch

  rows <- error$lines
  diagnostics <- if (is.null(rows) || nrow(rows) == 0) {
    list(list(message = error$message, from = 0L,
             to = as.integer(ends[1]), line = 1L))
  } else {
    lapply(seq_len(nrow(rows)), function(i) {
      ln <- min(max(as.integer(rows$line[i]), 1L), length(lines))
      list(message = error$message, from = as.integer(starts[ln]),
          to = as.integer(ends[ln]), line = as.integer(rows$line[i]))
    })
  }
  list(diagnostics = diagnostics)
}

#' LogEntryData per console item, in order:
#' `list(id = "<cell>_<i>", cell_id, level, msg = arr(text, "text/plain"),
#' file = "", line = -1L, kwargs = list())` with level "LogLevel(-555)"
#' (stdout: the frontend joins consecutive ones), "Info" (message) or
#' "Warn" (warning). Built so a growing console gives a list whose prefix is
#' identical to the previous one: fb_diff() then sends only the new items.
#'
#' `ember = list(call = item$call)` is added only when the worker's item
#' carries a `call` (a warning raised inside a function); an item with
#' none -- every message, and a warning with no call -- gets no `ember`
#' field at all.
project_logs <- function(console, cell_id) {
  level_of <- function(kind) switch(kind, stdout = "LogLevel(-555)",
                                    message = "Info", warning = "Warn", "Info")
  lapply(seq_along(console), function(i) {
    item <- console[[i]]
    entry <- list(id = sprintf("%s_%d", cell_id, i), cell_id = cell_id,
                  level = level_of(item$kind), msg = arr(item$text, "text/plain"),
                  file = "", line = -1L, kwargs = list())
    call <- item[["call", exact = TRUE]]
    if (!is.null(call)) entry$ember <- list(call = call)
    entry
  })
}

# ---- Graph -------------------------------------------------------------------

#' `cell_dependencies`: per cell, `list(cell_id, downstream_cells_map,
#' upstream_cells_map, precedence_heuristic)`.
#'
#' From `graph$edges` (`from` depends on `to` through `name`): a cell's
#' upstream map is name -> arr(cells it reads that name from), its downstream
#' map name -> arr(cells reading a name it defines or exports). Setup edges
#' (name NA) are left out; package edges are kept under the exported name.
#' `precedence_heuristic` is 5L for a cell that attaches packages, else 9L
#' (Pluto's "runs early" hint, display only).
#'
#' Built only when the graph object changed; each cell's entry goes through
#' reuse() against `previous`, so an edit that changes one cell's edges sends
#' only that cell's (and its neighbours') entries. Splits `edges` by `from`
#' and by `to` once (vectorised), never filters per cell.
project_dependencies <- function(graph, previous) {
  ids <- graph$ids
  edges <- graph$edges
  e <- if (is.null(edges) || nrow(edges) == 0) edges else edges[!is.na(edges$name), , drop = FALSE]
  up_groups <- if (!is.null(e) && nrow(e) > 0) split(e, e$from) else list()
  down_groups <- if (!is.null(e) && nrow(e) > 0) split(e, e$to) else list()

  #' A cell's name -> arr(other cells) map, built from its rows of `e`
  #' (already split by `from` or `to`), reading the *other* endpoint
  #' (`other_col`) per distinct name.
  name_map <- function(rows, other_col) {
    if (is.null(rows) || nrow(rows) == 0) return(emptymap())
    out <- list()
    for (nm in unique(rows$name)) {
      others <- unique(rows[[other_col]][rows$name == nm])
      others <- others[order(match(others, ids))]
      out[[nm]] <- as_arr(others)
    }
    out
  }

  #' Pluto lists every definition in `downstream_cells_map`, with an empty
  #' array when no cell reads it yet (completion of notebook names, and the
  #' go-to-definition anchor, both read its keys). `name_map()` above only
  #' has an entry for a name some cell actually reads.
  with_every_definition <- function(id, down) {
    defs <- graph$cells[[id]]$definitions %||% character()
    missing <- setdiff(defs, names(down))
    if (length(missing) == 0) return(down)
    down[missing] <- list(as_arr(character()))
    down
  }

  entries <- stats::setNames(lapply(ids, function(id) {
    list(cell_id = id,
        downstream_cells_map = with_every_definition(id, name_map(down_groups[[id]], "from")),
        upstream_cells_map = name_map(up_groups[[id]], "to"),
        precedence_heuristic = if (length(graph$cells[[id]]$attaches) > 0) 5L else 9L)
  }), ids)
  if (is.null(previous)) return(entries)
  stats::setNames(lapply(ids, function(id) reuse(entries[[id]], previous[[id]])), ids)
}

# ---- Notebook-level fields ---------------------------------------------------

#' ProcessStatus (frontend/common/ProcessStatus.js):
#'
#' | engine                                 | Pluto                    |
#' |----------------------------------------|--------------------------|
#' | `!allowed` (safe preview)              | "waiting_for_permission" |
#' | worker "off" or "starting"             | "starting"               |
#' | worker "ready" or "busy"               | "ready"                  |
#' | worker "stopped" (exited, crashed)     | "no_process"             |
#'
#' "no_process" shows Pluto's "process exited" bar with a restart link,
#' which sends restart_process; the server maps that to restart_notebook().
project_process_status <- function(state) {
  if (!isTRUE(state$allowed)) return("waiting_for_permission")
  switch(state$worker$status,
    off = , starting = "starting",
    ready = , busy = "ready",
    stopped = "no_process",
    "no_process")
}

#' Package status in Pluto's `nbpkg` shape, from packages_view(state). The
#' frontend's package bubbles hang off Julia `using` lines and never appear;
#' what remains visible are the restart banners and the Pkg terminal in the
#' status tab, and that is what this fills:
#'
#' * `enabled = TRUE`, `waiting_for_permission = !allowed`,
#'   `waiting_for_permission_but_probably_disabled = FALSE`.
#' * `installed_versions`: name -> version for rows with status "installed".
#' * `busy_packages`: arr(names with status "installing").
#' * `terminal_outputs`: `list(nbpkg_sync = <library message, the install
#'   progress line, and any failed/not_found rows, one per line>)`.
#' * `restart_required_msg`: when `plan$restart` is non-empty, "Restart R to
#'   use the new versions of: <names>".
#' * `restart_recommended_msg`: when the snapshot's `restart_offered` (a
#'   cell ignored the interrupt), "The running cell hasn't stopped. Restart R
#'   to stop it; every cell will be left not run." Pluto's banner for this
#'   has a restart link, which is the action Ember offers.
#' * `install_time_ns = NULL`, `instantiated = library status is "ready"`.
#'
#' Kept filled alongside Ember's own `ember$packages` (project_ember(),
#' above): Endeavor's page adapter still reads these Pluto-shaped fields
#' (`endeavor/frontend/src/drawer.ts:218, 244`), so they stay, not just until
#' increment 2.
project_nbpkg <- function(state) {
  pv <- packages_view(state)
  p <- state$packages
  pkgs <- pv$packages

  installed_rows <- pkgs[pkgs$status == "installed", , drop = FALSE]
  installed <- if (nrow(installed_rows) == 0) emptymap() else {
    stats::setNames(as.list(installed_rows$version), installed_rows$name)
  }
  busy <- as_arr(pkgs$name[pkgs$status == "installing"])

  lines <- character()
  if (!is.null(p$target$progress)) {
    pr <- p$target$progress
    lines <- c(lines, sprintf("Installing %s (%d/%d)...",
                              pr$current %||% "", pr$done %||% 0L, pr$total %||% 0L))
  }
  nf <- pkgs[pkgs$status == "not_found", , drop = FALSE]
  if (nrow(nf) > 0) lines <- c(lines, sprintf("%s: %s", nf$name, nf$message))
  if (identical(p$target$status, "failed") && !is.null(p$target$message)) {
    lines <- c(lines, p$target$message)
  }

  restart_required <- if (!is.null(pv$plan) && length(pv$plan$restart) > 0) {
    sprintf("Restart R to use the new versions of: %s", paste(pv$plan$restart, collapse = ", "))
  } else NULL
  restart_recommended <- if (isTRUE(state$worker$restart_offered)) {
    "The running cell hasn't stopped. Restart R to stop it; every cell will be left not run."
  } else NULL

  list(enabled = TRUE, waiting_for_permission = !isTRUE(state$allowed),
      waiting_for_permission_but_probably_disabled = FALSE,
      installed_versions = installed, busy_packages = busy,
      terminal_outputs = list(nbpkg_sync = paste(lines, collapse = "\n")),
      restart_required_msg = restart_required,
      restart_recommended_msg = restart_recommended,
      install_time_ns = NULL,
      instantiated = identical(p$active$status, "ready"))
}

#' Ember's own top-level status (ui-2.md, 5): packages, "N cells not run",
#' the worker's memory, and the plan the safe-preview banner describes.
#' Pluto's `nbpkg` and `process_status` stay filled beside this
#' (project_nbpkg(), above); the page still reads both.
#'
#' `list(process, worker_memory, not_run, stale, plan, packages)`:
#'
#' * `process`: `"preview"`, `"starting"`, `"ready"`, `"busy"` or
#'   `"stopped"` -- `state$worker$status`, or `"preview"` in safe preview
#'   (the same rule `snapshot_of()`'s `process` uses; not Pluto's
#'   `process_status`, which collapses some of these together).
#' * `worker_memory`: bytes, or `NULL` when none has been sampled yet, or
#'   the sample on record is from a worker generation that isn't the current
#'   one (a restart happened since the last sample; the new worker hasn't
#'   reported yet).
#' * `not_run`, `stale`: counts, from `not_run_ids()` (state.R) and the
#'   views' `stale` flag.
#' * `plan`: `packages_view(state)$plan`, `list(install, restart)` or `NULL`.
#' * `packages`: the snapshot date, R/Bioconductor versions, the library's
#'   status, and one row per locked or not-found package, from
#'   `packages_view(state)`. `NA` fields (no version, no source, no message)
#'   become `NULL` for the wire.
#'
#'   `packages$library` adds `log` (one string, the installer's last 200
#'   lines, joined with "\n") and `failures` (`arr(list(package, version,
#'   kind, detail, needed_by))`, `version` looked up from `packages$rows`
#'   and `needed_by` from `packages_view()`'s own `library$failures`
#'   column) -- both only while the library's `status` is `"failed"`;
#'   `NULL`/`arr()` otherwise, so a page that has never seen a failure
#'   never sees these fields change.
#' * `update`: `list(date, status = "checking"|"ready"|"failed",
#'   restart = arr(<names>), changes = <int>, message)` while a proposal
#'   from `ember_update_packages` (`ev_preview_date(..., apply = TRUE)`)
#'   exists, else `NULL`. A plain `preview_date()` call from R itself
#'   shows nothing here: its proposal has `apply = FALSE`. `status`
#'   `"checking"` is the proposal's `"fetching"` (the page's wording, not
#'   the core's); `message` is set only once `status == "failed"`.
#' * `on_cell_change`: `state$file$header$on_cell_change`, `"autorun"` or
#'   `"lazy"`.
#' * `r_version`, `worker_started_at`: the running worker's own report
#'   (`state$worker$info$r_version`, `state$worker$started_at`), `NULL`
#'   before the current worker's `wk_hello`, in safe preview, and once it
#'   stops (`reduce_wk_exited()`/`reduce_wk_failed()` clear both).
#' * `read_only`: `isTRUE(state$read_only)`, the same flag
#'   `notebook_snapshot()` projects -- the page disables the Status tab's
#'   autorun/lazy radios with it; `ember_set_mode` refuses regardless.
project_ember <- function(state, ctx) {
  stale <- 0L
  if (isTRUE(state$allowed)) {
    for (i in seq_along(ctx$ids)) {
      r <- ctx$results[[i]]
      if (!is.null(r) && isTRUE(r$stale)) stale <- stale + 1L
    }
  }
  worker_memory <- NULL
  wu <- state$worker_usage
  if (!is.null(wu) && identical(wu$gen, state$worker$gen)) worker_memory <- as.double(wu$rss)

  pv <- packages_view(state)
  pkgs <- pv$packages
  rows <- lapply(seq_len(nrow(pkgs)), function(i) {
    list(name = pkgs$name[[i]],
        version = if (is.na(pkgs$version[[i]])) NULL else pkgs$version[[i]],
        source = if (is.na(pkgs$source[[i]])) NULL else pkgs$source[[i]],
        direct = isTRUE(pkgs$direct[[i]]), status = pkgs$status[[i]],
        message = if (is.na(pkgs$message[[i]])) NULL else pkgs$message[[i]])
  })
  library_failed <- identical(pv$library$status, "failed")
  log <- if (library_failed && length(pv$library$log) > 0) {
    paste(pv$library$log, collapse = "\n")
  } else {
    NULL
  }
  fdf <- pv$library$failures
  failures <- if (!library_failed || is.null(fdf) || nrow(fdf) == 0) {
    list()
  } else {
    lapply(seq_len(nrow(fdf)), function(i) {
      ver <- pkgs$version[match(fdf$package[[i]], pkgs$name)]
      list(package = fdf$package[[i]],
          version = if (length(ver) == 0 || is.na(ver)) NULL else ver,
          kind = fdf$kind[[i]],
          detail = if (is.na(fdf$detail[[i]])) NULL else fdf$detail[[i]],
          needed_by = as_arr(fdf$needed_by[[i]] %||% character()))
    })
  }
  packages <- list(
    snapshot = pv$snapshot %||% NA_character_, r_version = pv$r_version %||% NA_character_,
    bioc_version = pv$bioc_version %||% NA_character_,
    library = list(status = pv$library$status, message = pv$library$message %||% NA_character_,
                  progress = pv$library$progress, log = log, failures = as_arr(failures)),
    rows = as_arr(rows))
  # `snapshot`/`r_version`/`bioc_version`/`library$message` are NA when
  # unset (packages-core.R: a fresh header has no snapshot date until
  # packages are resolved); the wire has no NA (check_wire()), so each
  # becomes NULL the same way a row's NA fields do above.
  if (is.na(packages$snapshot)) packages$snapshot <- NULL
  if (is.na(packages$r_version)) packages$r_version <- NULL
  if (is.na(packages$bioc_version)) packages$bioc_version <- NULL
  if (is.na(packages$library$message)) packages$library$message <- NULL

  if (!is.null(pv$proposal) && isTRUE(pv$proposal$apply)) {
    ui_status <- switch(pv$proposal$status, fetching = "checking", pv$proposal$status)
    packages$update <- list(date = pv$proposal$date, status = ui_status,
                            restart = as_arr(pv$proposal$restart %||% character()),
                            changes = if (is.null(pv$proposal$changes)) 0L else nrow(pv$proposal$changes),
                            message = pv$proposal$message)
  }

  plan <- pv$plan
  if (!is.null(plan)) plan <- list(install = as.integer(plan$install), restart = as_arr(plan$restart))

  # Ember's own vocabulary, not Pluto's `process_status` mapping
  # (project_process_status() collapses "starting"/"off" together and never
  # says "stopped"): the same rule snapshot_of() uses for its `process`.
  process <- if (!isTRUE(state$allowed)) "preview" else state$worker$status

  list(process = process, worker_memory = worker_memory,
      not_run = length(not_run_ids(state, ctx)), stale = stale,
      plan = plan, packages = packages,
      on_cell_change = state$file$header$on_cell_change,
      r_version = state$worker$info$r_version %||% NULL,
      worker_started_at = if (is.null(state$worker$started_at)) NULL
                          else as.numeric(state$worker$started_at),
      read_only = isTRUE(state$read_only))
}
