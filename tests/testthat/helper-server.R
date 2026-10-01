# Test-only helpers for test-server.R: a fake websocket (fake_socket()),
# wire() to build one encoded request the way the frontend's PlutoConnection
# would, patch() for a raw Firebasey patch by hand, and fake_req() for a
# hand-built Rook request. No httpuv anywhere: tests drive handle_message()
# and http_call() directly (docs/ui-tests.md, sections 2-3's "request
# handling" layer).

.ember_test_request_id <- local({
  n <- 0L
  function() { n <<- n + 1L; sprintf("req-%d", n) }
})

#' One encoded websocket message, as parse_request() expects to decode it.
#' Extra named arguments become the request's `body`.
wire <- function(type, client_id = "c1", request_id = .ember_test_request_id(),
                 notebook_id = NULL, ...) {
  body <- list(...)
  if (length(body) == 0) body <- emptymap()
  mp_encode(list(type = type, client_id = client_id, request_id = request_id,
                notebook_id = notebook_id, body = body))
}

#' One Firebasey patch, as immer would produce for one frontend edit.
patch <- function(op, path, value = NULL) list(op = op, path = as.list(path), value = value)

#' A fake websocket. `send(raw)` decodes and keeps every message sent to it;
#' `page()` applies every notebook_diff's patches to `{}` in order, which is
#' what the browser's own notebook object would be after receiving the same
#' messages. Set `sock$fail <- TRUE` to make `send()` throw, as a dead
#' socket would, for the "a failing send drops the client" case.
fake_socket <- function() {
  sock <- new.env(parent = emptyenv())
  sock$messages <- list()
  sock$fail <- FALSE
  sock$send <- function(raw) {
    if (isTRUE(sock$fail)) stop("socket closed")
    sock$messages[[length(sock$messages) + 1L]] <- mp_decode(raw)
  }
  sock$close <- function() invisible(NULL)
  sock$last <- function() sock$messages[[length(sock$messages)]]
  sock$page <- function() {
    page <- emptymap()
    for (m in sock$messages) {
      if (identical(m$type, "notebook_diff")) page <- fb_apply_all(page, m$message$patches)
    }
    page
  }
  sock
}

#' A hand-built Rook request, enough for http_call() and onWSOpen()'s
#' secret checks.
#' `query` is given without its leading "?" (e.g. "id=abc&secret=s"); Rook's
#' own QUERY_STRING keeps that "?" when non-empty and is "" when there is
#' none (verified against a real httpuv request), so this adds it here the
#' way a real request would carry it. `origin`/`host` set HTTP_ORIGIN/
#' HTTP_HOST (e.g. "http://127.0.0.1:9999" / "127.0.0.1:9999") for
#' origin_ok() tests.
fake_req <- function(path, query = "", cookie = NULL, origin = NULL, host = NULL) {
  req <- list(PATH_INFO = path, QUERY_STRING = if (nzchar(query)) paste0("?", query) else "")
  if (!is.null(cookie)) req$HTTP_COOKIE <- cookie
  if (!is.null(origin)) req$HTTP_ORIGIN <- origin
  if (!is.null(host)) req$HTTP_HOST <- host
  req
}
