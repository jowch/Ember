# The UI server: httpuv serving the frontend and one websocket per page,
# hosting any number of notebooks. The shell around three pure parts:
# protocol.R (the wire), pluto-state.R (the projection), pluto-edits.R (the
# translation). What it keeps:
#
# * per notebook, a hub: the `ember_notebook` and the last projection;
# * per client (one browser tab), the frontend object last sent to it.
#
# That is all the UI state there is. Everything a page shows is
# fb_diff(client$sent, pluto_state(notebook_state(nb), hub$proj)$js), and
# `flush_clients()` computes exactly that, for every client of a notebook, after
# every engine notification and at the end of every request. A flush that
# finds nothing new sends nothing, so calling it too often is harmless:
# that is the property every handler below leans on.
#
# Everything runs on R's one thread (httpuv and the engine both use
# `later`). A handler runs between engine drains, never inside one.

THUMBS_UP <- "\U0001F44D"
THUMBS_DOWN <- "\U0001F44E"
WAVE <- "\U0001F44B"

# ---- Public API --------------------------------------------------------------

#' Run the UI server in this process, blocking until it is stopped.
#'
#' For hosts that start their own R process (Endeavor), as `Pluto.run()`
#' is. `on_ready(server)` is called once the port is listening; a host
#' opens notebooks with the R API there (or later, from its own callbacks)
#' and hands them to the server with host_notebook().
#'
#' @param paths Notebook files to open in safe preview at start.
#' @param port Port on 127.0.0.1; 0 picks a free one.
#' @param secret The URL secret; every page, file and socket needs it.
#' @param on_ready `function(server)` or NULL.
#' @param launch_browser Open the first notebook's URL (or the server's).
#' @return Invisibly, when stop_server() is called from a callback.
#' @export
serve <- function(paths = character(), port = 0L, secret = random_secret(32),
                  on_ready = NULL, launch_browser = FALSE) {
  server <- new_server(secret)
  actual_port <- if (identical(port, 0L) || identical(port, 0)) pick_free_port() else port
  server$http <- httpuv::startServer("127.0.0.1", actual_port, http_app(server))
  server$port <- actual_port

  first_url <- NULL
  for (p in paths) {
    nb <- open_notebook(p)
    url <- host_notebook(server, nb, owned = TRUE)
    if (is.null(first_url)) first_url <- url
  }

  cat("ember: listening on ", server_url(server), "\n", sep = "")
  if (!is.null(on_ready)) on_ready(server)
  if (isTRUE(launch_browser)) utils::browseURL(first_url %||% server_url(server))

  while (!isTRUE(server$stopped)) later::run_now(timeout = 1)

  for (hub in mget(ls(server$hubs), envir = server$hubs, ifnotfound = list(NULL))) {
    if (is.null(hub)) next
    if (!is.null(hub$unsubscribe)) hub$unsubscribe()
    if (isTRUE(hub$owned)) close_notebook(hub$nb)
  }
  httpuv::stopServer(server$http)
  invisible(NULL)
}

#' Start the UI server as a background R process and return at once.
#'
#' For the interactive console: running httpuv in the user's session would
#' freeze the UI whenever the session is busy (design.md, Processes). The
#' child runs serve(); the secret reaches it through an environment
#' variable (not argv, which other users can read), and this call waits for
#' the child's "listening" line to learn the port.
#'
#' @param path Notebook to open, or NULL for none.
#' @param open Open the notebook in the browser.
#' @param timeout Seconds to wait for the child to listen.
#' @return An `ember_server_handle`: an environment with
#'   * `url`: the server's base URL including `?secret=`;
#'   * `open(path)`: opens a notebook in the browser through `/open`, the
#'     same route a bookmark uses, and returns its edit URL invisibly. The
#'     browser does the opening; this R session needs no channel to the
#'     child beyond HTTP;
#'   * `stop()`: kills the child (its workers die with it);
#'   * `process`: the processx handle (`cleanup = TRUE`, `supervise = TRUE`:
#'     the child goes when this session does).
#' @export
start_server <- function(path = NULL, port = 0L, open = interactive(), timeout = 15) {
  secret <- random_secret(32)
  path_env <- if (!is.null(path)) normalizePath(path, mustWork = TRUE) else ""
  r_bin <- file.path(R.home("bin"), "Rscript")

  proc <- processx::process$new(
    r_bin, c("--vanilla", "-e", "ember:::serve_child()"),
    env = c("current", EMBER_SECRET = secret, EMBER_PORT = as.character(port),
            EMBER_PATHS = path_env),
    stdout = "|", stderr = "2>&1", cleanup = TRUE, supervise = TRUE)

  deadline <- Sys.time() + timeout
  url <- NULL
  repeat {
    proc$poll_io(200)
    for (ln in proc$read_output_lines()) {
      if (startsWith(ln, "ember: listening on ")) url <- sub("^ember: listening on ", "", ln)
    }
    if (!is.null(url)) break
    if (!proc$is_alive()) {
      out <- paste(proc$read_all_output_lines(), collapse = "\n")
      stop("ember: server process exited before it started listening:\n", out)
    }
    if (Sys.time() >= deadline) {
      proc$kill()
      stop("ember: server did not start within ", timeout, "s")
    }
  }

  port_num <- as.integer(sub("^http://[^:]+:([0-9]+)/.*$", "\\1", url))

  handle <- new.env(parent = emptyenv())
  handle$url <- url
  handle$process <- proc
  handle$open <- function(path) {
    full_path <- normalizePath(path, mustWork = TRUE)
    qs <- sprintf("path=%s&secret=%s", utils::URLencode(full_path, reserved = TRUE), secret)
    resp <- http_get_raw("127.0.0.1", port_num, paste0("/open?", qs))
    loc <- resp$headers[["location"]]
    edit <- if (!is.null(loc)) {
      if (grepl("^https?://", loc)) loc else paste0("http://127.0.0.1:", port_num, loc)
    } else url
    invisible(edit)
  }
  handle$stop <- function() {
    if (proc$is_alive()) proc$kill()
    invisible(NULL)
  }
  class(handle) <- "ember_server_handle"

  if (isTRUE(open) && !is.null(path)) {
    edit <- handle$open(path)
    utils::browseURL(edit)
  }
  handle
}

#' @export
print.ember_server_handle <- function(x, ...) {
  cat(sprintf("<ember_server> %s\n", x$url))
  invisible(x)
}

#' Show a notebook opened through the R API in this server's UI.
#'
#' @param server The `ember_server` given to `on_ready`.
#' @param nb An `ember_notebook`. If the server already hosts it, nothing
#'   changes.
#' @param owned `TRUE` when the server opened it and should close it on stop
#'   or on the page's "shut down"; a host's notebooks are the host's to close.
#' @return The notebook's edit URL (with the secret), for the host to show.
#' @export
host_notebook <- function(server, nb, owned = FALSE) {
  id <- notebook_state(nb)$id
  existing <- mget(id, envir = server$hubs, ifnotfound = list(NULL))[[1]]
  if (!is.null(existing)) return(edit_url(server, id))

  hub <- new.env(parent = emptyenv())
  hub$id <- id
  hub$nb <- nb
  hub$proj <- NULL
  hub$owned <- isTRUE(owned)
  hub$due <- FALSE
  hub$last_flush <- Sys.time() - 1
  hub$unsubscribe <- on_notebook_event(nb, function(note) on_note(server, hub, note))
  assign(id, hub, envir = server$hubs)
  edit_url(server, id)
}

#' Stop a server started with serve(): the blocking loop returns.
#' @export
stop_server <- function(server) { server$stopped <- TRUE; invisible(NULL) }

# ---- The server value --------------------------------------------------------

#' The server: an environment.
#'
#' * `secret`, `port`, `http` (httpuv handle or NULL in tests),
#'   `stopped` (logical), `frontend` (the vendored frontend folder).
#' * `hubs`: environment, notebook id -> hub (environment: `nb`, `proj`
#'   (`ember_pluto_state` or NULL), `owned`, `due` (a flush is scheduled),
#'   `last_flush` (time), `unsubscribe`).
#' * `clients`: environment, client id -> client (environment: `id`, `ws`
#'   (anything with `$send(raw)`), `notebook_id` (set by connect), `sent`
#'   (the frontend object as this client has it, or NULL before its first
#'   sync)).
#' * `counter`: integer, +1 per flush (the frontend checks it increases).
#' * `throttle`: seconds between engine-triggered flushes of one notebook
#'   (default 0.03). 0 flushes inside the notification, for tests.
#'
#' Tests build one with no httpuv and drive handle_message() with fake
#' sockets; serve() is new_server() plus httpuv plus the loop.
new_server <- function(secret, frontend = system.file("frontend", package = "ember"),
                       throttle = 0.03) {
  server <- new.env(parent = emptyenv())
  server$secret <- secret
  server$frontend <- frontend
  server$throttle <- throttle
  server$port <- NULL
  server$http <- NULL
  server$stopped <- FALSE
  server$hubs <- new.env(parent = emptyenv())
  server$clients <- new.env(parent = emptyenv())
  server$counter <- 0L
  class(server) <- "ember_server"
  server
}

#' @export
print.ember_server <- function(x, ...) {
  cat(sprintf("<ember_server> %s\n", server_url(x)))
  invisible(x)
}

server_url <- function(server) sprintf("http://127.0.0.1:%d/?secret=%s", server$port, server$secret)
edit_url <- function(server, id) {
  sprintf("http://127.0.0.1:%d/edit?id=%s&secret=%s", server$port, id, server$secret)
}

#' A free TCP port on 127.0.0.1, found by opening and immediately closing a
#' listening socket (the same approach the worker harness's
#' open_server_socket() uses). Needed because httpuv::startServer()'s own
#' `port = 0` doesn't report which port the OS actually gave it: its
#' `getPort()` just echoes the port argument back, measured against httpuv
#' 1.6.17, so the port has to be chosen before starting the server rather
#' than read back afterward. A race remains between closing the probe
#' socket and handing the port to httpuv; the retry loop is the mitigation
#' already accepted elsewhere in this codebase for the same OS-level gap.
pick_free_port <- function(tries = 30L) {
  for (i in seq_len(tries)) {
    port <- sample(20000:59999, 1)
    ok <- tryCatch({ close(serverSocket(port)); TRUE }, error = function(e) FALSE)
    if (ok) return(port)
  }
  stop("ember: could not find a free port after ", tries, " tries")
}

# ---- Syncing -----------------------------------------------------------------

#' Bring every client of `hub` up to the engine's current state.
#'
#' Recomputes the projection (free when the engine state is the same
#' object), then per client: `patches <- fb_diff(client$sent, js)` (a
#' single `replace` at `[]` when `sent` is NULL), `client$sent <- js` (no
#' copy: R shares it), and sends a notebook_diff when there are patches or
#' when this client made the request `req` (then with `response`, which is
#' what resolves the frontend's promise). Idempotent: a second call with no
#' engine change and no request sends nothing.
flush_clients <- function(server, hub, req = NULL, response = NULL) {
  hub$due <- FALSE
  hub$last_flush <- Sys.time()
  hub$proj <- pluto_state(notebook_state(hub$nb), hub$proj)
  js <- hub$proj$js
  server$counter <- server$counter + 1L

  for (cl in clients_of(server, hub)) {
    patches <- if (is.null(cl$sent)) list(list(op = "replace", path = list(), value = js))
               else fb_diff(cl$sent, js)
    cl$sent <- js
    mine <- !is.null(req) && identical(req$client_id, cl$id)
    if (length(patches) > 0 || mine) {
      send(cl, diff_message(js$notebook_id, server$counter, patches,
                            if (mine) req else NULL, if (mine) response else NULL))
    }
  }
  invisible(NULL)
}

#' Every client environment currently attached to `hub`'s notebook.
clients_of <- function(server, hub) {
  ids <- ls(server$clients)
  if (length(ids) == 0) return(list())
  all <- mget(ids, envir = server$clients)
  Filter(function(cl) identical(cl$notebook_id, hub$id), all)
}

#' Get or make the client record for `client_id`, updating its socket (a
#' reconnect sends the same client_id on a new websocket).
client_for <- function(server, client_id, ws) {
  cl <- mget(client_id, envir = server$clients, ifnotfound = list(NULL))[[1]]
  if (is.null(cl)) {
    cl <- new.env(parent = emptyenv())
    cl$id <- client_id
    cl$ws <- ws
    cl$notebook_id <- NULL
    cl$sent <- NULL
    assign(client_id, cl, envir = server$clients)
  } else {
    cl$ws <- ws
  }
  cl
}

#' Drop every client record whose socket is `ws` (onClose).
drop_clients_of_ws <- function(server, ws) {
  for (id in ls(server$clients)) {
    cl <- mget(id, envir = server$clients, ifnotfound = list(NULL))[[1]]
    if (!is.null(cl) && identical(cl$ws, ws)) rm(list = id, envir = server$clients)
  }
  invisible(NULL)
}

#' Remove a hub (notebook_shut_down, or a page that asked to shut down):
#' unsubscribe from the engine and drop it from `server$hubs`. Clients still
#' pointed at it simply stop receiving anything further.
drop_hub <- function(server, hub) {
  if (!is.null(hub$unsubscribe)) hub$unsubscribe()
  if (exists(hub$id, envir = server$hubs, inherits = FALSE)) rm(list = hub$id, envir = server$hubs)
  invisible(NULL)
}

#' The engine listener, one per hub. Runs after a dispatch completes, so the
#' engine is consistent. With `throttle > 0`, schedules one flush at most
#' every `throttle` seconds (`later::later`), so a burst of runs costs one
#' projection per window rather than one per worker message; a request
#' handler's own flush clears `due` and the scheduled one finds nothing.
#' `notebook_shut_down` flushes once more (process_status "no_process") and
#' removes the hub.
on_note <- function(server, hub, note) {
  if (identical(note$kind, "notebook_shut_down")) {
    flush_clients(server, hub)
    drop_hub(server, hub)
    return(invisible(NULL))
  }
  if (server$throttle <= 0) {
    flush_clients(server, hub)
    return(invisible(NULL))
  }
  if (isTRUE(hub$due)) return(invisible(NULL))
  hub$due <- TRUE
  elapsed <- as.numeric(Sys.time() - hub$last_flush, units = "secs")
  delay <- max(0, server$throttle - elapsed)
  later::later(function() if (isTRUE(hub$due)) flush_clients(server, hub), delay)
  invisible(NULL)
}

#' Send one message. A socket that fails to send is closed and its client
#' dropped; the page reconnects and sends reset_shared_state.
send <- function(client, msg) {
  ok <- tryCatch({ client$ws$send(mp_encode(msg)); TRUE }, error = function(e) FALSE)
  if (!ok) {
    tryCatch(client$ws$close(), error = function(e) NULL)
    if (!is.null(client$.server)) drop_clients_of_ws(client$.server, client$ws)
  }
  invisible(ok)
}

# ---- Requests ----------------------------------------------------------------

#' Handle one websocket message from `ws`. Every request type the v1.0.3
#' editor sends is in `handlers`; an unknown type is logged and dropped.
#' A handler that fails is logged and, for update_notebook, answered 👎.
handle_message <- function(server, ws, raw) {
  req <- tryCatch(parse_request(raw), ember_bad_request = function(e) {
    message("ember: dropping malformed request: ", conditionMessage(e))
    NULL
  })
  if (is.null(req)) return(invisible(NULL))

  cl <- client_for(server, req$client_id, ws)
  cl$.server <- server
  hub <- if (!is.null(req$notebook_id)) {
    mget(req$notebook_id, envir = server$hubs, ifnotfound = list(NULL))[[1]]
  } else NULL

  h <- handlers[[req$type]]
  if (is.null(h)) {
    message("ember: unhandled request type: ", req$type)
    return(invisible(NULL))
  }
  tryCatch(h(server, cl, hub, req), error = function(e) {
    message("ember: ", req$type, " failed: ", conditionMessage(e))
    if (identical(req$type, "update_notebook") && !is.null(hub)) {
      flush_clients(server, hub, req, list(update_went_well = THUMBS_DOWN,
                                           why_not = conditionMessage(e),
                                           should_i_tell_the_user = TRUE))
    }
  })
  invisible(NULL)
}

#' `list(update_went_well = "👎", why_not = why, should_i_tell_the_user = TRUE)`.
thumbs_down <- function(why) {
  list(update_went_well = THUMBS_DOWN, why_not = why, should_i_tell_the_user = TRUE)
}

#' update_notebook: the only way a page changes a notebook.
#'
#' An empty `updates` (the first sync after connect): flush(req, NULL).
#' Otherwise the client's patches are translated by pluto_edits() and
#' applied through one atomic edit_notebook() call; see pluto-edits.R.
on_update_notebook <- function(server, cl, hub, req) {
  if (is.null(hub)) {
    send(cl, diff_message(req$notebook_id, server$counter, list(), req,
                          thumbs_down("no such notebook")))
    return(invisible(NULL))
  }
  updates <- req$body$updates
  if (length(updates) == 0) {
    flush_clients(server, hub, req, NULL)
    return(invisible(NULL))
  }
  if (is.null(cl$sent)) {
    flush_clients(server, hub, req, thumbs_down("no state yet"))
    return(invisible(NULL))
  }

  ed <- pluto_edits(cl$sent, updates)
  cl$sent <- ed$after
  response <- if (!is.null(ed$refusal)) {
    thumbs_down(ed$refusal)
  } else {
    tryCatch({
      if (length(ed$ops) > 0) do.call(edit_notebook, c(list(hub$nb), ed$ops))
      if (!is.null(ed$move_to)) move_notebook(hub$nb, ed$move_to)
      list(update_went_well = THUMBS_UP)
    }, ember_refused = function(e) thumbs_down(conditionMessage(e)))
  }
  flush_clients(server, hub, req, response)
}

#' run_multiple_cells. Reply "run_feedback" {disabled_cells = {}} first (the
#' frontend awaits it), then run.
#'
#' Two traps the frontend sets, both tested:
#' * `cells = []` arrives after every delete (Pluto uses it to save). It
#'   must stay empty: run_cells(nb, NULL) means "run all".
#' * Adding a cell sends run_multiple_cells for the new, empty cell. In safe
#'   preview that would allow execution, start R and install packages just
#'   because a cell was added. Cells whose code is blank are dropped first.
#' Ids not in the notebook (a race with a delete) are dropped too. Then
#' run_cells(nb, ids) when any remain; the engine marks them queued in the
#' same dispatch, and the listener's flush shows it.
on_run <- function(server, cl, hub, req) {
  send(cl, reply_message(req, "run_feedback", list(disabled_cells = emptymap())))
  if (is.null(hub)) return(invisible(NULL))

  requested <- unlist(req$body$cells, use.names = FALSE)
  if (is.null(requested)) requested <- character()
  if (length(requested) > 0) {
    cells <- notebook_state(hub$nb)$cells
    ids <- requested[requested %in% names(cells)]
    ids <- ids[vapply(ids, function(id) nzchar(trimws(cells[[id]]$code %||% "")), logical(1))]
    if (length(ids) > 0) run_cells(hub$nb, ids)
  }
  flush_clients(server, hub)
}

#' The request table. Every row the frontend sends (Editor.js, Cell.js,
#' CellInput.js, PlutoConnection.js, LiveDocsTab.js, ...), what it does here:
#'
#' | type                          | here                                                            |
#' |-------------------------------|-----------------------------------------------------------------|
#' | connect                       | cl$notebook_id <- id if hosted; reply "👋" {notebook_exists, session_options, version_info} |
#' | ping                          | reply "pong"                                                    |
#' | current_time                  | reply "current_time" {time}                                    |
#' | update_notebook               | see on_update_notebook()                                        |
#' | run_multiple_cells            | see on_run()                                                    |
#' | interrupt_all                 | interrupt_notebook(nb); no reply (the frontend sends without waiting) |
#' | restart_process               | preview: run_cells(nb) (the banner's "run notebook code"); else restart_notebook(nb). Then flush |
#' | shutdown_notebook             | keep_in_session FALSE and the hub is owned: close_notebook(nb), drop hub. A host's notebook: refused (log) |
#' | reset_shared_state            | cl$sent <- NULL; flush(req, list(from_reset = TRUE))            |
#' | complete                      | reply {start = 0, stop = 0, results = [], too_long = FALSE}: no editor services yet; answering keeps the page from waiting out its 5 s timeout |
#' | complete_symbols              | reply {latex = {}, emoji = {}} (Julia's symbol tables; none for R) |
#' | docs                          | reply {status = "not_found"}: LiveDocsTab shows docs only for "👍" |
#' | all_registered_package_names  | reply {results = []}                                            |
#' | completepath                  | reply {start = 0, stop = 0, results = []}                      |
#' | get_all_notebooks             | reply "notebook_list" {notebooks = hosted notebooks}           |
#' | reshow_cell, request_js_link_response, nbpkg_available_versions, nbpkg_get_project_toml, nbpkg_set_project_toml, pkg_update | Julia-only; their UI is disabled in the frontend. Logged, no reply |
#'
#' Replies use the reply type Pluto uses for each (connect "👋", ping
#' "pong", ...); the frontend matches replies by request_id, not type.
handlers <- list(
  connect = function(server, cl, hub, req) {
    if (!is.null(req$notebook_id)) cl$notebook_id <- req$notebook_id
    send(cl, reply_message(req, WAVE, list(
      notebook_exists = !is.null(hub),
      session_options = list(
        server = list(injected_javascript_data_url = "data:text/javascript;base64,",
                      notebook_path_suggestion = "", dismiss_update_notification = TRUE),
        security = list(warn_about_untrusted_code = FALSE),
        evaluation = emptymap()),
      version_info = list(pluto = PLUTO_VERSION, julia = paste("R", getRversion()),
                          dismiss_update_notification = TRUE))))
  },

  ping = function(server, cl, hub, req) send(cl, reply_message(req, "pong")),

  current_time = function(server, cl, hub, req) {
    send(cl, reply_message(req, "current_time", list(time = as.numeric(Sys.time()))))
  },

  update_notebook = on_update_notebook,
  run_multiple_cells = on_run,

  interrupt_all = function(server, cl, hub, req) {
    if (!is.null(hub)) interrupt_notebook(hub$nb)
    invisible(NULL)
  },

  restart_process = function(server, cl, hub, req) {
    if (is.null(hub)) return(invisible(NULL))
    snap <- notebook_snapshot(hub$nb)
    if (identical(snap$process, "preview")) run_cells(hub$nb, NULL) else restart_notebook(hub$nb)
    flush_clients(server, hub)
  },

  shutdown_notebook = function(server, cl, hub, req) {
    keep <- isTRUE(req$body$keep_in_session)
    if (is.null(hub)) return(invisible(NULL))
    if (!keep && isTRUE(hub$owned)) {
      close_notebook(hub$nb)
      drop_hub(server, hub)
    } else {
      message("ember: refused shutdown_notebook for a host-owned notebook")
    }
    invisible(NULL)
  },

  reset_shared_state = function(server, cl, hub, req) {
    cl$sent <- NULL
    if (!is.null(hub)) flush_clients(server, hub, req, list(from_reset = TRUE))
  },

  complete = function(server, cl, hub, req) {
    send(cl, reply_message(req, "complete_result",
                           list(start = 0L, stop = 0L, results = list(), too_long = FALSE)))
  },

  complete_symbols = function(server, cl, hub, req) {
    send(cl, reply_message(req, "complete_symbols_result", list(latex = emptymap(), emoji = emptymap())))
  },

  docs = function(server, cl, hub, req) send(cl, reply_message(req, "docs", list(status = "not_found"))),

  all_registered_package_names = function(server, cl, hub, req) {
    send(cl, reply_message(req, "all_registered_package_names", list(results = list())))
  },

  completepath = function(server, cl, hub, req) {
    send(cl, reply_message(req, "completepath_result",
                           list(start = 0L, stop = 0L, results = list())))
  },

  get_all_notebooks = function(server, cl, hub, req) {
    ids <- ls(server$hubs)
    entries <- lapply(ids, function(id) {
      hub <- get(id, envir = server$hubs)
      st <- notebook_state(hub$nb)
      list(notebook_id = st$id, path = st$path, shortpath = basename(st$path), in_temp_dir = FALSE)
    })
    send(cl, reply_message(req, "notebook_list", list(notebooks = entries)))
  }
)

#' Julia-only requests the frontend still sends in some flows; Ember has no
#' answer and none is needed (their UI is disabled). Logged, no reply so the
#' frontend never mistakes silence for a hang on a promise nothing awaits.
for (julia_only in c("reshow_cell", "request_js_link_response", "nbpkg_available_versions",
                     "nbpkg_get_project_toml", "nbpkg_set_project_toml", "pkg_update")) {
  handlers[[julia_only]] <- local({
    type <- julia_only
    function(server, cl, hub, req) { message("ember: ignoring ", type); invisible(NULL) }
  })
}

# ---- HTTP --------------------------------------------------------------------

#' `key=value` pairs from a URL query string or a `Cookie:` header,
#' URL-decoded. No dependency beyond `utils::URLdecode()`.
parse_query_string <- function(qs) {
  if (is.null(qs) || !nzchar(qs)) return(list())
  if (startsWith(qs, "?")) qs <- substring(qs, 2L)   # Rook's QUERY_STRING keeps the leading "?"
  if (!nzchar(qs)) return(list())
  out <- list()
  for (pair in strsplit(qs, "&", fixed = TRUE)[[1]]) {
    kv <- strsplit(pair, "=", fixed = TRUE)[[1]]
    if (length(kv) == 0 || !nzchar(kv[1])) next
    key <- utils::URLdecode(kv[1])
    val <- if (length(kv) >= 2) utils::URLdecode(paste(kv[-1], collapse = "=")) else ""
    out[[key]] <- val
  }
  out
}

parse_cookie_header <- function(h) {
  if (is.null(h) || !nzchar(h)) return(list())
  out <- list()
  for (pair in strsplit(h, ";\\s*")[[1]]) {
    kv <- strsplit(pair, "=", fixed = TRUE)[[1]]
    if (length(kv) == 2) out[[trimws(kv[1])]] <- trimws(kv[2])
  }
  out
}

#' Does this request carry the server's secret, in the query string or the
#' cookie `/edit` sets? Checked on every route that reaches R and on the
#' websocket; static files are exempt (design.md, Synthesis decision).
secret_ok <- function(server, req) {
  q <- parse_query_string(req$QUERY_STRING)
  if (!is.null(q$secret) && identical(q$secret, server$secret)) return(TRUE)
  cookies <- parse_cookie_header(req$HTTP_COOKIE)
  !is.null(cookies$ember_secret) && identical(cookies$ember_secret, server$secret)
}

http_text <- function(status, body, content_type = "text/plain; charset=utf-8", headers = list()) {
  list(status = status, headers = utils::modifyList(list("Content-Type" = content_type), headers),
      body = body)
}

#' `GET /edit?id=` -> editor.html, with the secret cookie set (so the page's
#' own websocket and later requests can rely on the cookie alone).
http_edit <- function(server, req) {
  q <- parse_query_string(req$QUERY_STRING)
  hub <- if (!is.null(q$id)) mget(q$id, envir = server$hubs, ifnotfound = list(NULL))[[1]] else NULL
  if (is.null(hub)) return(http_text(404L, "no such notebook"))
  body <- read_file_utf8(file.path(server$frontend, "editor.html"))
  http_text(200L, body, "text/html; charset=utf-8",
           list("Set-Cookie" = sprintf("ember_secret=%s; SameSite=Strict; HttpOnly; Path=/", server$secret)))
}

#' `GET /open?path=` -> open (or find) the notebook, host it owned, redirect
#' to its edit URL: the route a bookmark or start_server()$open() uses.
http_open <- function(server, req) {
  q <- parse_query_string(req$QUERY_STRING)
  if (is.null(q$path) || !nzchar(q$path)) return(http_text(400L, "missing path"))
  norm <- normalizePath(q$path, mustWork = FALSE)

  existing_id <- NULL
  for (id in ls(server$hubs)) {
    hub <- get(id, envir = server$hubs)
    if (identical(normalizePath(notebook_state(hub$nb)$path, mustWork = FALSE), norm)) {
      existing_id <- id
      break
    }
  }
  id <- if (!is.null(existing_id)) existing_id else {
    nb <- tryCatch(open_notebook(q$path), error = function(e) e)
    if (inherits(nb, "error")) return(http_text(400L, paste("could not open:", conditionMessage(nb))))
    host_notebook(server, nb, owned = TRUE)
    notebook_state(nb)$id
  }
  list(status = 302L,
      headers = list("Location" = sprintf("/edit?id=%s&secret=%s", id, server$secret)),
      body = "")
}

#' `GET /notebookfile?id=` -> the notebook file's text, as Pluto serves it
#' for download.
http_notebookfile <- function(server, req) {
  q <- parse_query_string(req$QUERY_STRING)
  hub <- if (!is.null(q$id)) mget(q$id, envir = server$hubs, ifnotfound = list(NULL))[[1]] else NULL
  if (is.null(hub)) return(http_text(404L, "no such notebook"))
  state <- notebook_state(hub$nb)
  text <- format_notebook(notebook_file_of(state))
  http_text(200L, text, "text/plain; charset=utf-8",
           list("Content-Disposition" = sprintf('inline; filename="%s"', basename(state$path))))
}

#' `GET /notebookexport?id=` -> a static HTML export (export_html()).
http_notebookexport <- function(server, req) {
  q <- parse_query_string(req$QUERY_STRING)
  hub <- if (!is.null(q$id)) mget(q$id, envir = server$hubs, ifnotfound = list(NULL))[[1]] else NULL
  if (is.null(hub)) return(http_text(404L, "no such notebook"))
  http_text(200L, export_html(notebook_state(hub$nb)), "text/html; charset=utf-8")
}

#' `GET /` -> a plain list of hosted notebooks with their edit links.
http_index <- function(server, req) {
  ids <- ls(server$hubs)
  items <- vapply(ids, function(id) {
    hub <- get(id, envir = server$hubs)
    st <- notebook_state(hub$nb)
    sprintf('<li><a href="/edit?id=%s&secret=%s">%s</a></li>', st$id, server$secret, st$path)
  }, character(1))
  body <- paste0("<html><body><h1>ember</h1><ul>", paste(items, collapse = ""), "</ul></body></html>")
  http_text(200L, body, "text/html; charset=utf-8")
}

http_call <- function(server, req) {
  if (!secret_ok(server, req)) return(http_text(403L, "forbidden"))
  switch(req$PATH_INFO,
    "/edit" = http_edit(server, req),
    "/open" = http_open(server, req),
    "/notebookfile" = http_notebookfile(server, req),
    "/notebookexport" = http_notebookexport(server, req),
    "/" = http_index(server, req),
    http_text(404L, "not found"))
}

#' The httpuv app.
#'
#' * Static files (`staticPaths`, served on httpuv's thread without R):
#'   everything under the frontend folder except editor.html (excluded so it
#'   always reaches `call`, which checks the secret). No secret elsewhere:
#'   the frontend's code is not private (Pluto exempts .js/.css too).
#' * `call` (R): checks the secret (query `secret=` or cookie
#'   `ember_secret`) and answers 403 otherwise, then routes `/edit`,
#'   `/open`, `/notebookfile`, `/notebookexport` and `/`.
#' * `onWSOpen`: check the secret in `ws$request`; without it, `ws$close()`
#'   before any handler is set. Otherwise `ws$onMessage(...)` inside
#'   tryCatch (log, never throw into httpuv), and `ws$onClose` drops the
#'   clients on that socket.
http_app <- function(server) {
  list(
    call = function(req) {
      tryCatch(http_call(server, req), error = function(e) {
        message("ember: http error: ", conditionMessage(e))
        http_text(500L, "internal error")
      })
    },
    staticPaths = list(
      "/" = httpuv::staticPath(server$frontend, fallthrough = TRUE),
      "/editor.html" = httpuv::excludeStaticPath()
    ),
    onWSOpen = function(ws) {
      if (!secret_ok(server, ws$request)) {
        ws$close()
        return(invisible(NULL))
      }
      ws$onMessage(function(binary, message) {
        tryCatch(handle_message(server, ws, message),
                 error = function(e) message("ember: error handling message: ", conditionMessage(e)))
      })
      ws$onClose(function() drop_clients_of_ws(server, ws))
    }
  )
}

# ---- Static export -------------------------------------------------------------

#' A small base64 encoder (no package dependency: base R has none in
#' base/utils). Used only for export_html()'s data URLs.
base64_encode <- function(bytes) {
  if (length(bytes) == 0) return("")
  alphabet <- c(LETTERS, letters, as.character(0:9), "+", "/")
  pad <- (3L - length(bytes) %% 3L) %% 3L
  padded <- c(bytes, raw(pad))
  v <- as.integer(padded)
  n <- length(v) %/% 3L
  idx <- integer(4L * n)
  for (i in seq_len(n)) {
    b1 <- v[3L * i - 2L]; b2 <- v[3L * i - 1L]; b3 <- v[3L * i]
    word <- bitwShiftL(b1, 16L) + bitwShiftL(b2, 8L) + b3
    base <- 4L * (i - 1L)
    idx[base + 1L] <- bitwAnd(bitwShiftR(word, 18L), 63L)
    idx[base + 2L] <- bitwAnd(bitwShiftR(word, 12L), 63L)
    idx[base + 3L] <- bitwAnd(bitwShiftR(word, 6L), 63L)
    idx[base + 4L] <- bitwAnd(word, 63L)
  }
  out <- paste(alphabet[idx + 1L], collapse = "")
  if (pad > 0) {
    out <- paste0(substr(out, 1, nchar(out) - pad), strrep("=", pad))
  }
  out
}

js_string_literal <- function(x) paste0('"', gsub('"', '\\\\"', x, fixed = TRUE), '"')

#' Static HTML export, as Pluto's generate_html(): editor.html with a
#' launch-parameters script (`pluto_notebook_id`, `pluto_disable_ui = true`,
#' `pluto_statefile` = data URL of mp_encode(pluto_state(state)$js),
#' `pluto_notebookfile` = data URL of the file text), inserted at the
#' `pluto-insertion-spot-parameters` meta. Its `pluto-cdn-root` points at
#' Pluto v1.0.3 on jsdelivr in increment 1, because the fork's files are not
#' on any CDN; the export shows outputs but highlights code as Julia.
#' Increment 2's offline bundle replaces that.
export_html <- function(state) {
  template <- read_file_utf8(file.path(system.file("frontend", package = "ember"), "editor.html"))
  js <- pluto_state(state)$js
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
  sub('<meta name="pluto-insertion-spot-parameters"[^>]*/?>', params, template)
}

# ---- The child process --------------------------------------------------------

#' A small raw HTTP/1.1 client (GET, `Connection: close`), used only by
#' start_server()$open() to read the `Location` header from `/open`'s
#' redirect without adding an HTTP client dependency.
http_get_raw <- function(host, port, path) {
  con <- socketConnection(host = host, port = port, open = "r+b", blocking = TRUE, timeout = 10)
  on.exit(close(con), add = TRUE)
  request <- paste0("GET ", path, " HTTP/1.1\r\nHost: ", host, "\r\nConnection: close\r\n\r\n")
  writeBin(charToRaw(request), con)
  resp <- raw(0)
  repeat {
    chunk <- readBin(con, "raw", n = 65536L)
    if (length(chunk) == 0) break
    resp <- c(resp, chunk)
  }
  text <- rawToChar(resp, multiple = FALSE)
  Encoding(text) <- "UTF-8"
  split_at <- regexpr("\r\n\r\n", text, fixed = TRUE)
  header_text <- if (split_at > 0) substr(text, 1, split_at - 1) else text
  lines <- strsplit(header_text, "\r\n", fixed = TRUE)[[1]]
  status <- suppressWarnings(as.integer(regmatches(lines[1], regexpr("[0-9]{3}", lines[1]))))
  headers <- list()
  for (ln in lines[-1]) {
    m <- regmatches(ln, regexec("^([^:]+):\\s*(.*)$", ln))[[1]]
    if (length(m) == 3) headers[[tolower(m[2])]] <- m[3]
  }
  list(status = status, headers = headers)
}

#' The child's entry point for start_server(): reads EMBER_SECRET,
#' EMBER_PORT, EMBER_PATHS and calls serve().
serve_child <- function() {
  secret <- Sys.getenv("EMBER_SECRET")
  port <- suppressWarnings(as.integer(Sys.getenv("EMBER_PORT", "0")))
  if (is.na(port)) port <- 0L
  paths_env <- Sys.getenv("EMBER_PATHS", "")
  paths <- if (nzchar(paths_env)) strsplit(paths_env, .Platform$path.sep, fixed = TRUE)[[1]] else character()
  serve(paths = paths, port = port, secret = secret)
}
