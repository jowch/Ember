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
               "all_registered_package_names", "completepath", "get_all_notebooks")
  silent <- c("interrupt_all", "shutdown_notebook", "reshow_cell", "request_js_link_response",
             "nbpkg_available_versions", "nbpkg_get_project_toml", "nbpkg_set_project_toml",
             "pkg_update")
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
  expect_match(resp1$headers[["Location"]], "^/edit\\?id=.+&secret=s$")

  resp2 <- http_call(server, fake_req("/open", sprintf("path=%s&secret=s", utils::URLencode(path, reserved = TRUE))))
  expect_equal(resp1$headers[["Location"]], resp2$headers[["Location"]])   # reused, not reopened
  expect_equal(length(ls(server$hubs)), 1)

  for (hub in mget(ls(server$hubs), envir = server$hubs)) close_notebook(hub$nb)
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

test_that("http_call() and onWSOpen() refuse a mismatched Origin or Host (review4 1)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  server <- new_server("s", throttle = 0)
  server$port <- 40002L
  host_notebook(server, nb)
  id <- notebook_state(nb)$id

  resp <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                     origin = "http://127.0.0.1:9999"))
  expect_equal(resp$status, 403L)
  resp2 <- http_call(server, fake_req("/notebookfile", sprintf("id=%s&secret=s", id),
                                      host = "127.0.0.1:9999"))
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
