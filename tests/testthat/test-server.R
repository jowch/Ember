# Tests for R/server.R: request handling with fake sockets and a real
# engine (no httpuv), plus the HTTP routes and a start_server() smoke test.
# Covers docs/ui-tests.md section 2, items 26-36, and the test-server-http.R
# / test-start-server.R cases described there.
#
# Notebooks are opened with write_session_notebook()/open_notebook()
# (helper-session.R), base R only so no package install ever runs.

# start_server() launches a child `Rscript -e "ember:::serve_child()"`, which
# needs a real installed ember on its library path; under devtools::load_all()
# there is no such install, so this makes one (cached) the way the
# subprocess tests in test-packages-session.R already do.
use_installed_ember()

# ---- 26. connect, then an empty update_notebook syncs the page --------------

test_that("connect then an empty update_notebook syncs the page (26)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1 + 1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  ws <- fake_socket()

  handle_message(server, ws, wire("connect", notebook_id = id))
  hello <- ws$messages[[1]]
  expect_equal(hello$type, "\U0001F44B")
  expect_true(hello$message$notebook_exists)

  req_id <- "sync-req"
  handle_message(server, ws, wire("update_notebook", request_id = req_id,
                                  notebook_id = id, updates = list()))
  diff <- ws$messages[[2]]
  expect_equal(diff$type, "notebook_diff")
  expect_equal(diff$request_id, req_id)
  expect_equal(length(diff$message$patches), 1)
  expect_equal(diff$message$patches[[1]]$op, "replace")
  expect_equal(diff$message$patches[[1]]$path, list())
  expect_equal(ws$page(), pluto_state(notebook_state(nb))$js)
})

# ---- 27. Editing a cell's code -----------------------------------------------

test_that("editing a cell's code updates the engine and the file, and broadcasts (27)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1 + 1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  a <- names(notebook_state(nb)$cells)[2]

  ws1 <- fake_socket(); ws2 <- fake_socket()
  handle_message(server, ws1, wire("connect", client_id = "c1", notebook_id = id))
  handle_message(server, ws1, wire("update_notebook", client_id = "c1", notebook_id = id, updates = list()))
  handle_message(server, ws2, wire("connect", client_id = "c2", notebook_id = id))
  handle_message(server, ws2, wire("update_notebook", client_id = "c2", notebook_id = id, updates = list()))

  handle_message(server, ws1, wire("update_notebook", client_id = "c1", notebook_id = id,
    updates = list(patch("replace", list("cell_inputs", a, "code"), "2 + 2"))))

  expect_equal(notebook_state(nb)$cells[[a]]$code, "2 + 2")
  expect_equal(read_file_utf8(path), format_notebook(notebook_file_of(notebook_state(nb))))

  reply1 <- ws1$last()
  expect_equal(reply1$message$response$update_went_well, "\U0001F44D")

  reply2 <- ws2$last()
  expect_equal(reply2$type, "notebook_diff")
  touched <- vapply(reply2$message$patches, function(p) p$path[[1]], "")
  expect_true("cell_inputs" %in% touched)
  expect_equal(ws2$page()$cell_inputs[[a]]$code, "2 + 2")
})

# ---- 28. A refused edit (stale `expected`) -----------------------------------

test_that("a stale expected is refused with the engine's reason; the client rolls back (28)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  a <- names(notebook_state(nb)$cells)[2]

  ws <- fake_socket()
  handle_message(server, ws, wire("connect", notebook_id = id))
  handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))

  cl <- get("c1", envir = server$clients)
  stale <- cl$sent   # what this tab has seen so far: code "1"

  edit_notebook(nb, set_code(a, "99"))   # another writer; throttle 0 flushed cl$sent already
  cl$sent <- stale                       # ...but this tab hasn't received that flush yet

  # `ws$page()` only replays messages the *server* sent; it says nothing
  # about what the browser already shows at the moment it sends this
  # request. A real browser applies its own patch to its local document
  # optimistically, before any reply arrives (review4 item 8: a test that
  # skips this step still passes even if the server's refusal carries no
  # reversal at all, because an earlier, unrelated flush already happened
  # to show the right value). `outgoing` is applied to the tab's view here,
  # the same way the browser's own `send()` would.
  outgoing <- list(patch("replace", list("cell_inputs", a, "code"), "client's code"))
  n0 <- length(ws$messages)
  browser_page <- fb_apply_all(ws$page(), outgoing)
  expect_equal(browser_page$cell_inputs[[a]]$code, "client's code")

  handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = outgoing))

  reply <- ws$last()
  expect_equal(reply$message$response$update_went_well, "\U0001F44E")
  expect_true(nzchar(reply$message$response$why_not))
  expect_equal(notebook_state(nb)$cells[[a]]$code, "99")

  # The refusal's own reply must carry the reverting patch: applying every
  # message from this request onward (there is exactly one: the reply
  # itself, since throttle = 0 and nothing else changed) to the browser's
  # optimistic view must bring it back to the engine's real code.
  expect_true(length(reply$message$patches) > 0)
  for (m in ws$messages[-seq_len(n0)]) {
    if (identical(m$type, "notebook_diff")) browser_page <- fb_apply_all(browser_page, m$message$patches)
  }
  expect_equal(browser_page$cell_inputs[[a]]$code, "99")
})

# ---- 29. run_multiple_cells: feedback, then queued/running/output -----------

test_that("run_multiple_cells answers run_feedback first, then the cell runs (29)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("sum(1:10)")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  a <- names(notebook_state(nb)$cells)[2]

  ws <- fake_socket()
  handle_message(server, ws, wire("connect", notebook_id = id))
  handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))

  handle_message(server, ws, wire("run_multiple_cells", notebook_id = id, cells = list(a)))

  fb <- Filter(function(m) identical(m$type, "run_feedback"), ws$messages)
  expect_equal(length(fb), 1)
  expect_equal(fb[[1]]$message$disabled_cells, emptymap())

  queued_or_running <- isTRUE(ws$page()$cell_results[[a]]$queued) ||
    isTRUE(ws$page()$cell_results[[a]]$running)
  expect_true(queued_or_running)

  ok <- wait_for(nb, timeout = 20)
  expect_true(ok)
  expect_match(ws$page()$cell_results[[a]]$output$body, "55")
})

# ---- 30. run_multiple_cells with cells = [] runs nothing --------------------

test_that("run_multiple_cells {cells: []} runs nothing; a blank new cell doesn't start the worker (30)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id

  ws <- fake_socket()
  handle_message(server, ws, wire("connect", notebook_id = id))
  handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))

  handle_message(server, ws, wire("run_multiple_cells", notebook_id = id, cells = list()))
  expect_equal(notebook_snapshot(nb)$process, "preview")

  new_id <- "11111111-1111-4111-8111-111111111111"
  edit_notebook(nb, insert_cell(3, code = "", id = new_id))
  handle_message(server, ws, wire("run_multiple_cells", notebook_id = id, cells = list(new_id)))
  expect_equal(notebook_snapshot(nb)$process, "preview")
})

# ---- 31. interrupt_all and restart_process -----------------------------------

test_that("interrupt_all sends SIGINT to the running cell (31)", {
  # stuck.c (the same fixture test-session.R's own interrupt test (113)
  # uses) never calls R_CheckUserInterrupt(), so interrupting it reliably
  # exercises the "cell hasn't stopped" path (restart_offered) rather than
  # racing a plain R loop's own, less deterministic, interrupt timing.
  so <- compile_stuck_lib()
  skip_if(is.null(so), "could not compile the stuck.c fixture (no compiler available)")

  cells <- list(S = cell(sprintf("dyn.load(%s)", deparse(so))), A = cell('.Call("stuck", 6L)'))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id

  ws <- fake_socket()
  handle_message(server, ws, wire("connect", notebook_id = id))
  handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))
  handle_message(server, ws, wire("run_multiple_cells", notebook_id = id, cells = list("A")))

  busy <- wait_for(nb, function(s) identical(s$process, "busy"), timeout = 15)
  expect_true(busy)
  busy_at <- Sys.time()
  wait_for(nb, function(s) as.numeric(Sys.time() - busy_at, units = "secs") > 1, timeout = 10)

  handle_message(server, ws, wire("interrupt_all", notebook_id = id))
  offered <- wait_for(nb, function(s) isTRUE(s$restart_offered), timeout = 15)
  expect_true(offered)

  # restart_offered has no per-cell view, so it carries no `cell_state`/
  # `topology_changed` notification for the listener to flush on; the
  # banner reaches a page on the next flush of any kind (every request
  # handler ends with one; here, done by hand as flush_clients() is always
  # safe to call).
  flush_clients(server, get(id, envir = server$hubs))
  expect_true(is.character(ws$page()$nbpkg$restart_recommended_msg))
  expect_true(nzchar(ws$page()$nbpkg$restart_recommended_msg))
})

test_that("restart_process runs all in preview, and restarts (leaving cells not run) otherwise (31)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1 + 1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  a <- names(notebook_state(nb)$cells)[2]

  ws <- fake_socket()
  handle_message(server, ws, wire("connect", notebook_id = id))
  handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))

  expect_equal(notebook_snapshot(nb)$process, "preview")
  handle_message(server, ws, wire("restart_process", notebook_id = id))
  ok <- wait_for(nb, timeout = 20)
  expect_true(ok)
  expect_equal(snap_view(notebook_snapshot(nb), a)$status, "ok")

  handle_message(server, ws, wire("restart_process", notebook_id = id))
  wait_for(nb, function(snap) identical(snap$process, "preview") || snap$process == "starting" ||
             identical(snap_view(snap, a)$status, "not_run"), timeout = 10)
  expect_equal(snap_view(notebook_snapshot(nb), a)$status, "not_run")
})

# ---- 32. reset_shared_state ---------------------------------------------------

test_that("reset_shared_state clears the client's copy; the next message is a full replace (32)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id

  ws <- fake_socket()
  handle_message(server, ws, wire("connect", notebook_id = id))
  handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))

  handle_message(server, ws, wire("reset_shared_state", notebook_id = id))
  reply <- ws$last()
  expect_equal(reply$type, "notebook_diff")
  expect_true(isTRUE(reply$message$response$from_reset))
  expect_equal(reply$message$patches[[1]]$op, "replace")
  expect_equal(reply$message$patches[[1]]$path, list())
})

# ---- 33. Two notebooks on one server -----------------------------------------

test_that("a client connected to one notebook never receives another's diffs (33)", {
  path1 <- write_session_notebook(list(S = cell(""), A = cell("1")))
  path2 <- write_session_notebook(list(S = cell(""), B = cell("2")))
  nb1 <- open_notebook(path1); nb2 <- open_notebook(path2)
  on.exit({ close_notebook(nb1); close_notebook(nb2) }, add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb1); host_notebook(server, nb2)
  id1 <- notebook_state(nb1)$id

  ws1 <- fake_socket()
  handle_message(server, ws1, wire("connect", notebook_id = id1))
  handle_message(server, ws1, wire("update_notebook", notebook_id = id1, updates = list()))
  n_before <- length(ws1$messages)

  b <- names(notebook_state(nb2)$cells)[2]
  edit_notebook(nb2, set_code(b, "22"))

  expect_equal(length(ws1$messages), n_before)
})

# ---- 34. A failing send drops its client, others keep receiving -------------

test_that("a socket whose send() errors is dropped; others keep receiving (34)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  a <- names(notebook_state(nb)$cells)[2]

  ws1 <- fake_socket(); ws2 <- fake_socket()
  handle_message(server, ws1, wire("connect", client_id = "c1", notebook_id = id))
  handle_message(server, ws1, wire("update_notebook", client_id = "c1", notebook_id = id, updates = list()))
  handle_message(server, ws2, wire("connect", client_id = "c2", notebook_id = id))
  handle_message(server, ws2, wire("update_notebook", client_id = "c2", notebook_id = id, updates = list()))

  ws1$fail <- TRUE
  edit_notebook(nb, set_code(a, "2"))

  expect_false("c1" %in% ls(server$clients))
  expect_true("c2" %in% ls(server$clients))
  expect_equal(get("c2", envir = server$clients)$sent$cell_inputs[[a]]$code, "2")
})

# ---- 35. Unknown type and malformed bytes ------------------------------------

test_that("an unknown request type and malformed bytes are logged and dropped, nothing sent (35)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  ws <- fake_socket()

  expect_message(handle_message(server, ws, wire("made_up_type", notebook_id = id)), "unhandled")
  expect_equal(length(ws$messages), 0)

  expect_message(handle_message(server, ws, as.raw(c(1, 2, 3))), "dropping")
  expect_equal(length(ws$messages), 0)
})

# ---- 36. Every request type gets the documented treatment -------------------

test_that("every request type in the handler table is answered as documented (36)", {
  answered <- c("connect", "ping", "current_time", "update_notebook", "run_multiple_cells",
               "restart_process", "reset_shared_state", "complete", "complete_symbols", "docs",
               "all_registered_package_names", "completepath", "get_all_notebooks", "ember_signature")
  silent <- c("interrupt_all", "shutdown_notebook", "reshow_cell", "ember_render_plot",
             "ember_run_all", "request_js_link_response", "nbpkg_available_versions",
             "nbpkg_get_project_toml", "nbpkg_set_project_toml", "pkg_update")
  expect_setequal(names(handlers), c(answered, silent))

  # A fresh notebook and server per type: some requests change engine state
  # (run_multiple_cells, restart_process), which would otherwise leak into
  # later iterations sharing the same worker.
  one_request <- function(type) {
    path <- write_session_notebook(list(S = cell(""), A = cell("1")))
    nb <- open_notebook(path)
    on.exit(close_notebook(nb), add = TRUE)
    server <- new_server("s", throttle = 0)
    host_notebook(server, nb)
    id <- notebook_state(nb)$id
    ws <- fake_socket()
    handle_message(server, ws, wire("connect", notebook_id = id))
    handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))
    baseline <- length(ws$messages)
    body <- switch(type,
      update_notebook = list(updates = list()),
      run_multiple_cells = list(cells = list()),
      list())
    handle_message(server, ws, do.call(wire, c(list(type = type, notebook_id = id), body)))
    length(ws$messages) - baseline
  }

  for (type in answered) expect_gt(one_request(type), 0, label = type)
  for (type in silent) expect_equal(one_request(type), 0, label = type)   # idempotent: nothing changed
})

# ---- HTTP: secret, cookie, redirect, file download, websocket gate ----------

test_that("http_call() answers 403 without the secret on every route that reaches R (http)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id

  routes <- list(c("/edit", sprintf("id=%s", id)), c("/open", sprintf("path=%s", path)),
                 c("/notebookfile", sprintf("id=%s", id)), c("/notebookexport", sprintf("id=%s", id)))
  for (r in routes) {
    resp <- http_call(server, fake_req(r[1], r[2]))
    expect_equal(resp$status, 403L, label = r[1])
  }
})

test_that("the secret cookie is set on /edit, and the file's content matches the engine (http)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id

  resp <- http_call(server, fake_req("/edit", sprintf("id=%s&secret=s", id)))
  expect_equal(resp$status, 200L)
  expect_match(resp$headers[["Set-Cookie"]], "ember_secret=s")

  file_resp <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id)))
  expect_equal(file_resp$status, 200L)
  expect_equal(file_resp$body, format_notebook(notebook_file_of(notebook_state(nb))))

  # the cookie alone (no query secret) is also accepted
  resp2 <- http_call(server, fake_req("/notebookfile", sprintf("id=%s", id), cookie = "ember_secret=s"))
  expect_equal(resp2$status, 200L)
})

test_that("/open opens (or reuses) the notebook and redirects to its edit URL (http)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  server <- new_server("s", throttle = 0)

  resp1 <- http_call(server, fake_req("/open", sprintf("path=%s&secret=s", utils::URLencode(path, reserved = TRUE))))
  expect_equal(resp1$status, 302L)
  # Relative, not "/edit?...": see http_open()'s doc (a proxy under a path
  # prefix forwards this request's path unprefixed, so the browser must
  # resolve the redirect against its own, prefixed URL).
  expect_match(resp1$headers[["Location"]], "^edit\\?id=.+&secret=s$")

  resp2 <- http_call(server, fake_req("/open", sprintf("path=%s&secret=s", utils::URLencode(path, reserved = TRUE))))
  expect_equal(resp1$headers[["Location"]], resp2$headers[["Location"]])   # reused, not reopened
  expect_equal(length(ls(server$hubs)), 1)

  for (hub in mget(ls(server$hubs), envir = server$hubs)) close_notebook(hub$nb)
})

test_that("/open and / refuse the cookie alone; /notebookfile still accepts it (review)", {
  # A page on another port of 127.0.0.1 gets the cookie attached to any
  # request automatically (cookie_name()'s doc) but can't read or set the
  # query string; without this, such a page could make this server open any
  # file on disk as a notebook (/open), or list every hosted notebook's
  # path (/), using nothing else. /notebookfile and /notebookexport keep
  # accepting the cookie alone: Editor.js's export_url() links to them with
  # no secret= of their own, by design.
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id

  resp_open_cookie <- http_call(server, fake_req("/open", sprintf("path=%s", utils::URLencode(path, reserved = TRUE)),
                                                 cookie = "ember_secret=s"))
  expect_equal(resp_open_cookie$status, 403L)

  resp_index_cookie <- http_call(server, fake_req("/", "", cookie = "ember_secret=s"))
  expect_equal(resp_index_cookie$status, 403L)

  resp_open_query <- http_call(server, fake_req("/open", sprintf("path=%s&secret=s", utils::URLencode(path, reserved = TRUE))))
  expect_equal(resp_open_query$status, 302L)
  for (hub in mget(ls(server$hubs), envir = server$hubs)) if (!identical(hub$id, id)) close_notebook(hub$nb)

  resp_index_query <- http_call(server, fake_req("/", "secret=s"))
  expect_equal(resp_index_query$status, 200L)

  resp_file_cookie <- http_call(server, fake_req("/notebookfile", sprintf("id=%s", id), cookie = "ember_secret=s"))
  expect_equal(resp_file_cookie$status, 200L)
})

test_that("a websocket opened without the secret is closed before any handler is set (http)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)

  app <- http_app(server)
  closed <- FALSE
  ws <- list(request = fake_req("/", ""), close = function() closed <<- TRUE,
            onMessage = function(f) stop("should not be reached without the secret"),
            onClose = function(f) stop("should not be reached without the secret"))
  app$onWSOpen(ws)
  expect_true(closed)
})

# ---- review4 item 1: the secret cookie must not open a websocket; Origin/Host --

test_that("a websocket opened with only the ember_secret cookie (no ?secret=) is refused (review4 1)", {
  # The reproduction: a page from another origin on 127.0.0.1 can't read an
  # HttpOnly cookie, but the browser attaches it anyway to any request to
  # this host -- including a WebSocket handshake it opens. If the cookie
  # alone were enough, that page could connect and run code (attacker.html).
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  server$port <- 40001L
  host_notebook(server, nb)

  app <- http_app(server)
  closed <- FALSE
  ws <- list(request = fake_req("/", "", cookie = "ember_secret_40001=s"),
            close = function() closed <<- TRUE,
            onMessage = function(f) stop("should not be reached"),
            onClose = function(f) stop("should not be reached"))
  app$onWSOpen(ws)
  expect_true(closed)
})

test_that("a websocket opened with the secret in the query string connects normally (review4 1)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  server$port <- 40001L
  host_notebook(server, nb)

  app <- http_app(server)
  opened <- FALSE
  ws <- list(request = fake_req("/", "secret=s"), close = function() stop("should not be closed"),
            onMessage = function(f) opened <<- TRUE, onClose = function(f) NULL)
  app$onWSOpen(ws)
  expect_true(opened)
})

test_that("http_call() and onWSOpen() refuse a mismatched Origin (review4 1)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  server$port <- 40002L
  host_notebook(server, nb)
  id <- notebook_state(nb)$id

  # Origin with no Host at all can't be checked against anything, so it's
  # refused outright.
  resp <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                     origin = "http://127.0.0.1:9999"))
  expect_equal(resp$status, 403L)

  # Host on its own, a loopback name on a port that isn't this server's own,
  # is accepted (the SSH-tunnel/reverse-proxy case; see the "remote use"
  # tests below): only an Origin that disagrees with Host is refused.
  resp2 <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                      origin = "http://127.0.0.1:9999", host = "127.0.0.1:40002"))
  expect_equal(resp2$status, 403L)

  # Its own origin, in either spelling, is accepted.
  resp3 <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                      origin = "http://127.0.0.1:40002", host = "127.0.0.1:40002"))
  expect_equal(resp3$status, 200L)
  resp4 <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                      host = "localhost:40002"))
  expect_equal(resp4$status, 200L)

  app <- http_app(server)
  closed <- FALSE
  ws <- list(request = fake_req("/", "secret=s", origin = "http://127.0.0.1:9999"),
            close = function() closed <<- TRUE, onMessage = function(f) NULL, onClose = function(f) NULL)
  app$onWSOpen(ws)
  expect_true(closed)
})

# ---- Remote use: loopback on any port, allowed_hosts, DNS rebinding --------

test_that("a loopback Host on a different port (an SSH tunnel or local proxy) is accepted (remote use)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  server$port <- 40003L
  host_notebook(server, nb)
  id <- notebook_state(nb)$id

  # `ssh -L 8080:localhost:40003` makes the browser's Host "localhost:8080"
  # (or "127.0.0.1:8080"), unrelated to the server's own port; no Origin
  # (a plain navigation): this must now work, which is the bug being fixed.
  for (host in c("localhost:8080", "127.0.0.1:8080", "[::1]:8080")) {
    resp <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id), host = host))
    expect_equal(resp$status, 200L, label = host)
  }

  # Matching Origin and Host, both on the tunnel's port, is also accepted.
  resp2 <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                      origin = "http://localhost:8080", host = "localhost:8080"))
  expect_equal(resp2$status, 200L)
})

test_that("a mismatched Origin is refused even when Host is an accepted loopback tunnel port (remote use)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  server$port <- 40004L
  host_notebook(server, nb)
  id <- notebook_state(nb)$id

  # Host alone would be accepted (it's loopback), but an Origin naming a
  # *different* port -- another page on this machine -- must still be
  # refused: accepting any loopback Host can't mean trusting any origin.
  resp <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                     origin = "http://127.0.0.1:9999", host = "localhost:8080"))
  expect_equal(resp$status, 403L)
})

test_that("a non-loopback Host is refused by default and accepted once listed in allowed_hosts (remote use)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  server$port <- 40005L
  host_notebook(server, nb)
  id <- notebook_state(nb)$id

  resp <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                     host = "ember.example.org"))
  expect_equal(resp$status, 403L)

  server$allowed_hosts <- "ember.example.org"
  resp2 <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                      host = "ember.example.org"))
  expect_equal(resp2$status, 200L)

  # Listed bare, any port on that name is accepted too (a proxy in front of
  # a load balancer that varies its own port).
  resp3 <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                      host = "ember.example.org:8443"))
  expect_equal(resp3$status, 200L)

  # A *different* non-loopback name, not listed, is still refused.
  resp4 <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                      host = "other.example.org"))
  expect_equal(resp4$status, 403L)
})

test_that("EMBER_ALLOWED_HOSTS round-trips a host with an explicit port (review)", {
  # A Unix path.sep ":" join would chop "hub.example.com:8443"'s port off
  # (and, with more than one entry, glue two names into one wrong one) on
  # the way through start_server()'s child process.
  hosts <- c("hub.example.com:8443", "other.example.org")
  env_value <- join_allowed_hosts_env(hosts)
  expect_false(grepl(":", env_value, fixed = TRUE) && !grepl("8443", env_value, fixed = TRUE))
  expect_equal(split_allowed_hosts_env(env_value), hosts)
  expect_equal(split_allowed_hosts_env(""), character())
})

test_that("new_server()'s allowed_hosts argument is what host_allowed()/origin_ok() read (remote use)", {
  server <- new_server("s", allowed_hosts = "ember.example.org")
  expect_equal(server$allowed_hosts, "ember.example.org")
  expect_true(host_allowed(server, "ember.example.org"))
  expect_false(host_allowed(server, "other.example.org"))
})

test_that("a DNS-rebinding-style Host is refused: a non-loopback name is never trusted on its say-so (remote use)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  server$port <- 40006L
  host_notebook(server, nb)
  id <- notebook_state(nb)$id

  # attacker.example can resolve to 127.0.0.1 (DNS rebinding) and the TCP
  # connection really does land on this loopback server, but the Host header
  # the browser sends is still the attacker's own name -- not a loopback
  # name -- so it must be refused like any other unlisted host.
  resp <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                     host = "attacker.example"))
  expect_equal(resp$status, 403L)
})

test_that("a Host-rewriting reverse proxy is accepted when Origin's host is in allowed_hosts (review)", {
  # nginx's default `proxy_pass http://127.0.0.1:<port>;` rewrites Host to
  # the upstream address before forwarding, so this process sees
  # "Host: 127.0.0.1:<port>" even though the browser's own Origin is still
  # the public name the operator put in allowed_hosts. Host alone is
  # already accepted (it's loopback); the fix is that Origin disagreeing
  # with Host no longer refuses the request on its own when Origin's host
  # is explicitly trusted.
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0, allowed_hosts = "hub.example.com")
  server$port <- 40007L
  host_notebook(server, nb)
  id <- notebook_state(nb)$id

  resp <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                     origin = "https://hub.example.com", host = "127.0.0.1:40007"))
  expect_equal(resp$status, 200L)

  # Case-insensitive, and an explicit default port (:443 for https) is the
  # same as none.
  resp2 <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                      origin = "https://HUB.EXAMPLE.COM:443", host = "127.0.0.1:40007"))
  expect_equal(resp2$status, 200L)

  # An Origin naming a host NOT in allowed_hosts still can't ride a
  # loopback-rewritten Host in: this is exactly DNS rebinding's shape
  # (Host accepted as loopback, Origin disagreeing) and must stay refused.
  resp3 <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                      origin = "https://attacker.example", host = "127.0.0.1:40007"))
  expect_equal(resp3$status, 403L)

  # allowed_hosts listed WITH an exact port only trusts that port: an
  # Origin on a different port of the same name is still refused, the same
  # cross-port protection host_allowed() already gives Host itself.
  server$allowed_hosts <- "hub.example.com:8443"
  resp4 <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                      origin = "https://hub.example.com:9999",
                                      host = "127.0.0.1:40007"))
  expect_equal(resp4$status, 403L)
})

# ---- review4 item 5: the cookie is named per port -----------------------------

test_that("two servers on different ports don't share a cookie name (review4 5)", {
  pathA <- write_session_notebook(list(S = cell(""), A = cell("1")))
  pathB <- write_session_notebook(list(S = cell(""), A = cell("2")))
  nbA <- open_notebook(pathA); on.exit(close_notebook(nbA), add = TRUE)
  nbB <- open_notebook(pathB); on.exit(close_notebook(nbB), add = TRUE)
  serverA <- new_server("secretA", throttle = 0); serverA$port <- 50001L
  serverB <- new_server("secretB", throttle = 0); serverB$port <- 50002L
  host_notebook(serverA, nbA)
  host_notebook(serverB, nbB)
  idA <- notebook_state(nbA)$id

  respA <- http_call(serverA, fake_req("/edit", sprintf("id=%s&secret=secretA", idA)))
  expect_match(respA$headers[["Set-Cookie"]], "^ember_secret_50001=secretA")

  # A browser that holds both servers' cookies (they share a cookie jar on
  # 127.0.0.1, since cookies ignore port) still reaches server A using only
  # its own cookie: server B's, also present, is simply a different name.
  both_cookies <- "ember_secret_50001=secretA; ember_secret_50002=secretB"
  resp <- http_call(serverA, fake_req("/notebookfile", sprintf("id=%s", idA), cookie = both_cookies))
  expect_equal(resp$status, 200L)

  # Without server A's own cookie, B's doesn't substitute for it.
  resp2 <- http_call(serverA, fake_req("/notebookfile", sprintf("id=%s", idA),
                                       cookie = "ember_secret_50002=secretB"))
  expect_equal(resp2$status, 403L)
})

# ---- review4 item 10: "/" is Ember's own index, and it escapes its HTML ----

test_that("\"/\" serves Ember's own index, not Pluto's vendored welcome page (review4 10)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)

  # httpuv auto-serves a folder's index.html for "/" unless told not to;
  # frontend/index.html is Pluto's own welcome screen (vendored, unrelated
  # to Ember's `/`), so without `indexhtml = FALSE` it would win over
  # http_call()'s own "/" route below and a browser would never see it.
  app <- http_app(server)
  expect_false(app$staticPaths[["/"]]$options$indexhtml)

  resp <- http_call(server, fake_req("/", "secret=s"))
  expect_equal(resp$status, 200L)
  expect_match(resp$body, "<h1>ember</h1>")
})

# ---- Remote use: a stable default port -----------------------------------

test_that("pick_default_port() prefers 4321, then the next free port up (remote use: stable port)", {
  p <- pick_default_port()
  expect_true(p >= 4321L)

  occupied <- tryCatch(serverSocket(4321L), error = function(e) NULL)
  skip_if(is.null(occupied), "port 4321 not available to reserve for this test")
  on.exit(close(occupied), add = TRUE)
  p2 <- pick_default_port()
  expect_true(p2 != 4321L && p2 >= 4321L)
})

test_that("serve() with no port given binds 4321 when it's free (remote use: stable port)", {
  skip_on_cran()
  probe <- tryCatch(httpuv::startServer("127.0.0.1", 4321L, list()), error = function(e) NULL)
  skip_if(is.null(probe), "port 4321 not available to test against")
  probe$stop()

  bound_port <- NULL
  serve(secret = "s", on_ready = function(server) {
    bound_port <<- server$port
    stop_server(server)
  })
  expect_equal(bound_port, 4321L)
})

test_that("http_index() escapes a notebook's path into its HTML (review4 10)", {
  # Windows forbids < and > in file names; a quote that breaks out of an
  # attribute is the same attack and is allowed everywhere.
  evil_dir <- file.path(tempdir(), "ember-nb-' onmouseover='alert(1)&x")
  dir.create(evil_dir, recursive = TRUE, showWarnings = FALSE)
  path <- write_session_notebook(list(S = cell(""), A = cell("1")), dir = evil_dir)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)

  resp <- http_call(server, fake_req("/", "secret=s"))
  expect_false(grepl("' onmouseover='alert(1)&x", resp$body, fixed = TRUE))
  expect_match(resp$body, "&#39; onmouseover=&#39;alert(1)&amp;x", fixed = TRUE)
})

# ---- Rich outputs: dependency files, reshow_cell, ember_render_plot (35-38) --

test_that("register_deps() registers inside the library once, refuses outside it, and drop_hub() unregisters per notebook (35)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)  # server$http is NULL: register_deps() only records
  host_notebook(server, nb)
  hub <- get(notebook_state(nb)$id, envir = server$hubs)
  lib <- notebook_state(nb)$packages$active$path

  inside <- file.path(lib, "somepkg", "htmlwidgets", "lib", "x-1.0")
  dir.create(inside, recursive = TRUE)
  dep <- list(name = "x", version = "1.0", dir = inside, href = NULL, script = "x.js", stylesheet = character())

  register_deps(server, hub, list(dep))
  expect_true(exists("x-1.0", envir = server$deps))
  register_deps(server, hub, list(dep))  # idempotent across two notes
  expect_equal(get("x-1.0", envir = server$deps)$notebooks, hub$id)

  outside <- list(name = "y", version = "1.0", dir = tempfile(), href = NULL, script = character(), stylesheet = character())
  expect_message(register_deps(server, hub, list(outside)), "refusing")
  expect_false(exists("y-1.0", envir = server$deps))

  dotdot <- list(name = "z", version = "1.0",
                 dir = file.path(lib, "..", "escaped"), href = NULL, script = character(), stylesheet = character())
  expect_message(register_deps(server, hub, list(dotdot)), "refusing")

  # a symlinked entry (as renv's shared cache makes) is accepted: the check
  # is on the path as given, not its resolved target
  if (.Platform$OS.type != "windows") {
    target <- tempfile()
    dir.create(target)
    link <- file.path(lib, "linked-pkg")
    ok <- tryCatch({ file.symlink(target, link); TRUE }, error = function(e) FALSE,
                   warning = function(w) FALSE)
    if (ok) {
      linked_dep <- list(name = "w", version = "1.0", dir = link, href = NULL,
                        script = character(), stylesheet = character())
      register_deps(server, hub, list(linked_dep))
      expect_true(exists("w-1.0", envir = server$deps))
    }
  }

  # a key two notebooks use stays until both are gone
  path2 <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb2 <- open_notebook(path2)
  on.exit(close_notebook(nb2), add = TRUE)
  host_notebook(server, nb2)
  hub2 <- get(notebook_state(nb2)$id, envir = server$hubs)
  lib2 <- notebook_state(nb2)$packages$active$path
  inside2 <- file.path(lib2, "somepkg", "htmlwidgets", "lib", "x-1.0")
  dir.create(inside2, recursive = TRUE, showWarnings = FALSE)
  register_deps(server, hub2, list(list(name = "x", version = "1.0", dir = inside2, href = NULL,
                                       script = "x.js", stylesheet = character())))
  expect_setequal(get("x-1.0", envir = server$deps)$notebooks, c(hub$id, hub2$id))

  drop_hub(server, hub)
  expect_true(exists("x-1.0", envir = server$deps))
  expect_equal(get("x-1.0", envir = server$deps)$notebooks, hub2$id)
  drop_hub(server, hub2)
  expect_false(exists("x-1.0", envir = server$deps))
})

test_that("reshow_cell pages a table through a real worker (36)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("mtcars")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  a <- names(notebook_state(nb)$cells)[2]

  ws <- fake_socket()
  handle_message(server, ws, wire("connect", notebook_id = id))
  handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))
  handle_message(server, ws, wire("run_multiple_cells", notebook_id = id, cells = list(a)))
  expect_true(wait_for(nb, timeout = 20))

  handle_message(server, ws, wire("reshow_cell", notebook_id = id, cell_id = a, objectid = "", dim = 1))
  got_more <- wait_for(nb, function(s) {
    v <- Find(function(c) identical(c$id, a), s$cells)
    !is.null(v$output) && length(v$output$data$rows) == 32
  }, timeout = 10)
  expect_true(got_more)
})

test_that("ember_render_plot clamps width/height/res and re-renders through a real worker (37)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1"), B = cell("plot(1:10)")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  cells <- names(notebook_state(nb)$cells)
  a <- cells[2]; b <- cells[3]

  ws <- fake_socket()
  handle_message(server, ws, wire("connect", notebook_id = id))
  handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))
  handle_message(server, ws, wire("run_multiple_cells", notebook_id = id, cells = list(a, b)))
  expect_true(wait_for(nb, timeout = 20))

  before <- Find(function(c) identical(c$id, b), notebook_snapshot(nb)$cells)$output$data
  handle_message(server, ws, wire("ember_render_plot", notebook_id = id, cell_id = b,
                                  width = 99999, height = 1, res = 1))
  changed <- wait_for(nb, function(s) {
    v <- Find(function(c) identical(c$id, b), s$cells)
    !is.null(v$output) && !identical(v$output$data, before)
  }, timeout = 10)
  expect_true(changed)

  # clamped to <= 4000 and >= 72 res
  final <- Find(function(c) identical(c$id, b), notebook_state(nb)$results)
  out <- notebook_state(nb)$results[[b]]$output
  expect_lte(out$size$width, 4000L)
  expect_gte(out$size$res, 72L)

  # a text cell: nothing happens
  before_a <- notebook_state(nb)$results[[a]]
  handle_message(server, ws, wire("ember_render_plot", notebook_id = id, cell_id = a,
                                  width = 500, height = 500, res = 96))
  Sys.sleep(0.2)
  later::run_now(timeout = 0.2)
  expect_identical(notebook_state(nb)$results[[a]], before_a)
})

# ---- Editor services (ui-2.md, 4) -------------------------------------------

test_that("complete in safe preview replies from the fallback within handle_message(); with an idle worker, df$ completes to df$mpg (57)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("df <- mtcars")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  ws <- fake_socket()
  handle_message(server, ws, wire("connect", notebook_id = id))
  handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))

  handle_message(server, ws, wire("complete", notebook_id = id, query = "me", query_full = "me"))
  reply <- ws$last()
  expect_identical(reply$type, "complete_result")
  expect_identical(notebook_snapshot(nb)$process, "preview")

  a <- names(notebook_state(nb)$cells)[2]
  handle_message(server, ws, wire("run_multiple_cells", notebook_id = id, cells = list(a)))
  expect_true(wait_for(nb, timeout = 20))

  n_before <- length(ws$messages)
  handle_message(server, ws, wire("complete", notebook_id = id, query = "df$", query_full = "df$"))
  deadline <- Sys.time() + 10
  found <- FALSE
  while (!found && Sys.time() < deadline) {
    later::run_now(timeout = 1)
    results <- Filter(function(m) identical(m$type, "complete_result"), ws$messages)
    if (length(results) > 0) {
      names <- vapply(results[[length(results)]]$message$results, `[[`, character(1), 1)
      found <- "df$mpg" %in% names
    }
  }
  expect_true(found)
})

test_that("docs: preview mean needs R running, a notebook-defined f shows its code, and a worker shows the rewritten help page (58)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("f <- function(x) x + 1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  ws <- fake_socket()
  handle_message(server, ws, wire("connect", notebook_id = id))
  handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))

  handle_message(server, ws, wire("docs", notebook_id = id, query = "mean"))
  r1 <- ws$last()$message
  expect_identical(r1$status, "\U0001F44D")
  expect_match(r1$doc, "Run a cell")

  handle_message(server, ws, wire("docs", notebook_id = id, query = "f"))
  r2 <- ws$last()$message
  expect_match(r2$doc, "Defined in this notebook")
  expect_match(r2$doc, "function(x) x", fixed = TRUE)

  a <- names(notebook_state(nb)$cells)[2]
  handle_message(server, ws, wire("run_multiple_cells", notebook_id = id, cells = list(a)))
  expect_true(wait_for(nb, timeout = 20))
  n_before <- length(Filter(function(m) identical(m$type, "docs"), ws$messages))
  handle_message(server, ws, wire("docs", notebook_id = id, query = "mean"))
  deadline <- Sys.time() + 10
  docs_msgs <- list()
  while (length(docs_msgs) <= n_before && Sys.time() < deadline) {
    later::run_now(timeout = 1)
    docs_msgs <- Filter(function(m) identical(m$type, "docs"), ws$messages)
  }
  r3 <- docs_msgs[[length(docs_msgs)]]$message
  expect_identical(r3$status, "\U0001F44D")
  expect_match(r3$doc, "Arithmetic Mean")
  expect_no_match(r3$doc, "../../base/help", fixed = TRUE)
})

test_that("docs: an idle worker that doesn't answer in time says so, not 'needs R running' (review)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  allow_execution(nb)
  expect_true(run_cells(nb, wait = TRUE, timeout = 20)$accepted)

  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  ws <- fake_socket()
  handle_message(server, ws, wire("connect", notebook_id = id))
  handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))

  # The worker is idle (worker_is_idle(nb) is TRUE), but its connection is
  # broken right before asking, so worker_query()'s write fails and its
  # callback runs with NULL immediately -- the same shape a real answer
  # timing out would have, without waiting out the real 0.8s. The reply
  # must name a timeout, not "Help pages need R running": R *is* running.
  close(nb$con)
  handle_message(server, ws, wire("docs", notebook_id = id, query = "mean"))
  r <- ws$last()$message
  expect_identical(r$status, "\U0001F44D")
  expect_match(r$doc, "answer in time")
  expect_no_match(r$doc, "Run a cell")
})

test_that("ember_signature with a worker and without one (59)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  host_notebook(server, nb)
  id <- notebook_state(nb)$id
  ws <- fake_socket()
  handle_message(server, ws, wire("connect", notebook_id = id))
  handle_message(server, ws, wire("update_notebook", notebook_id = id, updates = list()))

  handle_message(server, ws, wire("ember_signature", notebook_id = id, name = "lm"))
  expect_match(ws$last()$message$text, "^lm\\(formula, data")

  a <- names(notebook_state(nb)$cells)[2]
  handle_message(server, ws, wire("run_multiple_cells", notebook_id = id, cells = list(a)))
  expect_true(wait_for(nb, timeout = 20))
  n_before <- length(Filter(function(m) identical(m$type, "ember_signature"), ws$messages))
  handle_message(server, ws, wire("ember_signature", notebook_id = id, name = "lm"))
  deadline <- Sys.time() + 10
  sig_msgs <- list()
  while (length(sig_msgs) <= n_before && Sys.time() < deadline) {
    later::run_now(timeout = 1)
    sig_msgs <- Filter(function(m) identical(m$type, "ember_signature"), ws$messages)
  }
  expect_match(sig_msgs[[length(sig_msgs)]]$message$text, "^lm\\(formula, data")
})

# ---- start_server(): a real child process, skipped on CRAN -----------------

test_that("start_server() returns a working handle, and stop() ends the child (start_server)", {
  skip_on_cran()

  # use_installed_ember() put a real install on *this* session's
  # .libPaths(), which an Rscript child doesn't inherit; R_LIBS_USER does.
  # find.package("ember") isn't reliable here: under devtools::load_all()
  # it resolves to the source tree, not the temp install use_installed_ember()
  # made at tempdir()/ember-self-lib (its own, undocumented, convention).
  ember_lib <- file.path(tempdir(), "ember-self-lib")
  if (dir.exists(file.path(ember_lib, "ember"))) {
    old_r_libs_user <- Sys.getenv("R_LIBS_USER", unset = NA)
    Sys.setenv(R_LIBS_USER = paste(c(ember_lib, Sys.getenv("R_LIBS_USER")), collapse = .Platform$path.sep))
    on.exit({
      if (is.na(old_r_libs_user)) Sys.unsetenv("R_LIBS_USER") else Sys.setenv(R_LIBS_USER = old_r_libs_user)
    }, add = TRUE)
  }

  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  handle <- start_server(path, open = FALSE, timeout = 30)
  on.exit(try(handle$stop(), silent = TRUE), add = TRUE)

  # [1-9][0-9]* (not a bare "0"): port = 0 must resolve to a real port
  # (httpuv::startServer()'s own getPort() doesn't report it; see
  # pick_free_port() in R/server.R).
  expect_true(grepl("^http://127\\.0\\.0\\.1:[1-9][0-9]*/\\?secret=", handle$url))
  expect_true(handle$process$is_alive())

  handle$stop()
  handle$process$wait(5000)
  expect_false(handle$process$is_alive())
})

# ---- Cache headers: immutable for hashed vendor files, no-cache for the ----
# ---- rest (ui-2-tests.md 15a) ----------------------------------------------

test_that("serve() answers hashed vendor files immutable and everything else no-cache (15a)", {
  skip_on_cran()

  ember_lib <- file.path(tempdir(), "ember-self-lib")
  if (dir.exists(file.path(ember_lib, "ember"))) {
    old_r_libs_user <- Sys.getenv("R_LIBS_USER", unset = NA)
    Sys.setenv(R_LIBS_USER = paste(c(ember_lib, Sys.getenv("R_LIBS_USER")), collapse = .Platform$path.sep))
    on.exit({
      if (is.na(old_r_libs_user)) Sys.unsetenv("R_LIBS_USER") else Sys.setenv(R_LIBS_USER = old_r_libs_user)
    }, add = TRUE)
  }

  # An explicit free port, not the stable default: this file's own earlier
  # tests also bind port 4321, and immediately re-binding it here (right
  # after an on.exit `stop()`) has been flaky under the full suite's
  # timing, landing this test on a leftover process instead of its own.
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  handle <- start_server(path, port = pick_free_port(), open = FALSE, timeout = 30)
  on.exit(try(handle$stop(), silent = TRUE), add = TRUE)

  m <- regmatches(handle$url, regexec("^http://127\\.0\\.0\\.1:([0-9]+)/\\?secret=(.*)$", handle$url))[[1]]
  port <- as.integer(m[2])

  frontend_dir <- system.file("frontend", package = "ember")
  vendor_dir <- file.path(frontend_dir, "imports", "vendor")
  hashed <- list.files(vendor_dir, pattern = "-[0-9A-Za-z_-]+\\.js$")
  expect_true(length(hashed) > 0)

  resp <- http_get_raw("127.0.0.1", port, paste0("/imports/vendor/", hashed[[1]]))
  expect_equal(resp$status, 200L)
  expect_equal(resp$headers[["cache-control"]], "public, max-age=31536000, immutable")

  resp2 <- http_get_raw("127.0.0.1", port, "/editor.js")
  expect_equal(resp2$status, 200L)
  expect_equal(resp2$headers[["cache-control"]], "no-cache")

  edit_url <- handle$open(path)
  edit_path_and_query <- sub("^http://127\\.0\\.0\\.1:[0-9]+", "", edit_url)
  resp3 <- http_get_raw("127.0.0.1", port, edit_path_and_query)
  expect_equal(resp3$status, 200L)
  expect_equal(resp3$headers[["cache-control"]], "no-cache")
})

test_that("every hashed vendor file a shim or editor.html names exists, and no other hashed file does (15a)", {
  frontend_dir <- system.file("frontend", package = "ember")
  vendor_dir <- file.path(frontend_dir, "imports", "vendor")
  on_disk <- list.files(vendor_dir, pattern = "-[0-9A-Za-z_-]+\\.js$")

  shim_files <- list.files(file.path(frontend_dir, "imports"), pattern = "\\.js$", full.names = TRUE)
  named <- character(0)
  for (f in shim_files) {
    text <- readChar(f, file.info(f)$size)
    found <- regmatches(text, gregexpr('\\./vendor/([A-Za-z0-9_.-]+-[0-9A-Za-z_-]+\\.js)', text, perl = TRUE))[[1]]
    named <- c(named, sub('^\\./vendor/', "", found))
  }
  # The two iframe-resizer scripts aren't ES modules a shim imports: they're
  # loaded as plain <script src> tags straight from editor.html (classic
  # scripts, not imports -- see copy-assets.mjs's doc), so that file is
  # searched the same way for its own hashed names.
  html_text <- readChar(file.path(frontend_dir, "editor.html"),
                        file.info(file.path(frontend_dir, "editor.html"))$size)
  found_html <- regmatches(html_text, gregexpr(
    'imports/vendor/([A-Za-z0-9_.-]+-[0-9A-Za-z_-]+\\.js)', html_text, perl = TRUE))[[1]]
  named <- c(named, sub('^imports/vendor/', "", found_html))
  named <- unique(named)

  # Every named file exists...
  expect_equal(setdiff(named, on_disk), character(0))
  # ...and every entry chunk on disk is named by some shim or editor.html
  # (internal helper chunks, e.g. commonjs's, are reached only via another
  # chunk's own import, never a shim's or editor.html's, so they're excluded
  # from this direction).
  unreferenced <- setdiff(on_disk, named)
  unreferenced <- unreferenced[!grepl("^_", unreferenced)]
  expect_equal(unreferenced, character(0))
})
