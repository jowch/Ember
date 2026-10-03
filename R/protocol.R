# The wire: msgpack encoding, Firebasey-style diff and apply, and parsing a
# websocket message into a request. Pure; no sockets here.
#
# The frontend object convention (spike README section 3), which every
# builder in pluto-state.R follows and `check_wire()` enforces in tests:
#
# * JS object  <-> named list; an empty one is `emptymap()`.
# * JS array   <-> unnamed list, always, even of length one (`arr()`).
# * scalar     <-> length-one atomic vector (character, logical, integer or
#                  double; one type per field, never flipping).
# * bytes      <-> raw vector (msgpack bin, a Uint8Array in the browser).
# * null       <-> NULL element (`x[k] <- list(NULL)`); Firebasey treats a
#                  null value as a missing key, so fb_diff() does too.
#
# No factors, no NA, no Date/POSIXct (times are doubles of seconds).

emptymap <- function() setNames(list(), character())
arr <- function(...) unname(list(...))
as_arr <- function(x) unname(as.list(x))          # character(0) -> list()
is_map <- function(x) is.list(x) && !is.null(names(x))

#' The one reuse rule the projection is built on: keep the previous object
#' when the new one is equal, so the next diff meets the same R object and
#' `identical()` returns at its first pointer comparison.
reuse <- function(new, old) if (!is.null(old) && identical(new, old)) old else new

#' `reuse()` applied field by field: every top-level entry of `new` that
#' equals the same entry of `old` keeps `old`'s object, so `fb_diff()` finds
#' only the fields that actually changed instead of replacing the whole map
#' (pluto-state.R's `project_ember()`, where a worker-memory tick must not
#' touch `not_run`, `plan` or `packages`).
reuse_fields <- function(new, old) {
  nm <- names(new)
  out <- stats::setNames(vector("list", length(nm)), nm)
  for (n in nm) out[[n]] <- reuse(new[[n]], if (!is.null(old)) old[[n]] else NULL)
  out
}

# ---- msgpack -----------------------------------------------------------------

mp_encode <- function(x) RcppMsgPack::msgpack_pack(x)

#' `msgpack_unpack(simplify = TRUE)` would collapse `["a"]` to `"a"` and
#' arrays to atomic vectors, losing the array/scalar distinction a patch
#' needs to apply. `simplify = FALSE` returns maps as a "map" data frame of
#' parallel `key`/`value` lists (an empty map is a 0-row one); this converts
#' those to named lists by hand. Arrays stay plain (unnamed) lists already.
mp_decode <- function(raw) from_msgpack(RcppMsgPack::msgpack_unpack(raw, simplify = FALSE))

from_msgpack <- function(x) {
  if (inherits(x, "map")) {
    if (nrow(x) == 0) return(emptymap())
    setNames(lapply(x$value, from_msgpack), vapply(x$key, as.character, ""))
  } else if (is.list(x)) {
    lapply(x, from_msgpack)
  } else x
}

# ---- Firebasey ---------------------------------------------------------------

#' Patches turning `old` into `new`: `list(op, path, value)` with `path` an
#' unnamed list of keys (character) and array indexes (integer, 0-based).
#'
#' Maps recurse; anything else is replaced whole when not identical, with one
#' exception: an unnamed list whose first `length(old)` elements are
#' identical to `old` gives one `add` per new element at its index. That is
#' Pluto's AppendonlyMarker for `logs`, so a cell printing for a minute sends
#' each line once instead of the whole log on every flush.
#'
#' Cost: `identical()` on each pair before walking it, and names matched once
#' per map (spike: 0.95 ms for one changed cell at 2000 cells). Unchanged
#' subtrees shared with the previous projection return at once.
fb_diff <- function(old, new) {
  out <- vector("list", 16L); n <- 0L
  push <- function(p) {
    n <<- n + 1L
    if (n > length(out)) length(out) <<- 2L * length(out)
    out[[n]] <<- p
  }
  walk <- function(old, new, path) {
    if (identical(old, new)) return()
    if (is_map(old) && is_map(new)) {
      old_names <- names(old); new_names <- names(new)
      at <- match(old_names, new_names)
      for (i in seq_along(old)) {
        nv <- if (is.na(at[i])) NULL else new[[at[i]]]
        if (is.null(nv)) {
          if (!is.null(old[[i]])) push(list(op = "remove", path = c(path, old_names[i])))
        } else {
          walk(old[[i]], nv, c(path, old_names[i]))
        }
      }
      for (j in which(!new_names %in% old_names)) {
        if (!is.null(new[[j]])) push(list(op = "add", path = c(path, new_names[j]), value = new[[j]]))
      }
    } else if (is.list(old) && is.list(new) && is.null(names(old)) && is.null(names(new)) &&
               length(new) > length(old) && identical(old, new[seq_along(old)])) {
      for (i in seq.int(length(old) + 1L, length(new))) {
        push(list(op = "add", path = c(path, as.integer(i - 1L)), value = new[[i]]))
      }
    } else {
      push(list(op = "replace", path = path, value = new))
    }
  }
  walk(old, new, list())
  out[seq_len(n)]
}

#' Apply one patch. `x[k] <- list(value)` for add/replace (so a NULL value is
#' kept as a null field, not a deletion), `x[[k]] <- NULL` for remove, and
#' an integer path element indexes an unnamed list (0-based on the wire).
#' Missing intermediate maps are created, which is why pluto_edits()
#' validates paths before applying.
fb_apply <- function(x, patch) {
  key <- function(k) if (is.numeric(k)) as.integer(k) + 1L else k
  set_in <- function(x, path, op, value) {
    k <- key(path[[1]])
    if (length(path) == 1L) {
      if (op == "remove") x[[k]] <- NULL else x[k] <- list(value)
      return(x)
    }
    if (is.null(x[[k]])) x[[k]] <- if (is.numeric(path[[2]])) list() else emptymap()
    x[[k]] <- set_in(x[[k]], path[-1], op, value)
    x
  }
  if (length(patch$path) == 0L) return(patch$value)
  set_in(x, patch$path, patch$op, patch$value)
}

fb_apply_all <- function(x, patches) Reduce(fb_apply, patches, x)

# ---- Requests ----------------------------------------------------------------

#' A decoded websocket message, validated at the boundary.
#'
#' `list(type, client_id, request_id, notebook_id, body)`: `type`, ids are
#' single strings (`notebook_id` may be NULL), `body` a named list
#' (`emptymap()` when absent). Anything else is an `ember_bad_request`
#' condition, logged by the server and never answered: the frontend only
#' sends well-formed messages, so a bad one is a bug or a stranger.
bad_request <- function(why) {
  stop(structure(class = c("ember_bad_request", "error", "condition"),
                 list(message = why, call = NULL)))
}

is_string <- function(x) is.character(x) && length(x) == 1

parse_request <- function(raw) {
  msg <- tryCatch(mp_decode(raw), error = function(e) {
    bad_request(paste("msgpack decode failed:", conditionMessage(e)))
  })
  if (!is_map(msg)) bad_request("message is not a map")
  if (!is_string(msg$type)) bad_request("type is not a single string")
  if (!is_string(msg$client_id)) bad_request("client_id is not a single string")
  if (!is_string(msg$request_id)) bad_request("request_id is not a single string")
  notebook_id <- msg$notebook_id
  if (!is.null(notebook_id) && !is_string(notebook_id)) {
    bad_request("notebook_id is not a single string")
  }
  body <- msg$body
  if (is.null(body)) body <- emptymap()
  if (!is_map(body)) bad_request("body is not a map")
  list(type = msg$type, client_id = msg$client_id, request_id = msg$request_id,
       notebook_id = notebook_id, body = body)
}

#' The reply to one request (it resolves the frontend's promise for
#' `request_id`).
reply_message <- function(req, type, message = emptymap()) {
  list(type = type, message = message, initiator_id = req$client_id,
       request_id = req$request_id)
}

#' A state update. `response` non-NULL only for the client whose request
#' caused this flush (Pluto: `is_response`), with the request's ids.
diff_message <- function(notebook_id, counter, patches, req = NULL, response = NULL) {
  msg <- list(type = "notebook_diff", notebook_id = notebook_id,
              message = list(counter = counter, patches = patches, response = response))
  if (!is.null(req)) {
    msg$initiator_id <- req$client_id
    msg$request_id <- req$request_id
  }
  msg
}

#' Which paths of the frontend object are maps (`{}` when empty) and which
#' are arrays (`[]`), from NotebookData in Editor.js. Used by check_wire()
#' only; the builders encode it by construction. A cell id in a path is
#' written as `*`.
#'
#' Needed because an empty map and an empty array differ only by name
#' (`emptymap()` vs `list()`): a builder that sends the wrong empty value for
#' a field (e.g. `bonds = list()` where the frontend expects `{}`) is
#' otherwise invisible to check_wire(), which can only see the shape, not
#' the field's meaning.
pluto_schema <- function() {
  list(
    maps = c(
      "", "cell_inputs", "cell_inputs/*", "cell_inputs/*/metadata",
      "cell_results", "cell_results/*", "cell_results/*/output",
      "published_objects", "bonds", "metadata", "nbpkg", "status_tree",
      "cell_dependencies", "cell_dependencies/*",
      "cell_dependencies/*/downstream_cells_map",
      "cell_dependencies/*/upstream_cells_map",
      "ember", "ember/packages", "ember/packages/library", "ember/plan",
      "cell_results/*/ember", "cell_results/*/ember/figure"
    ),
    arrays = c(
      "cell_order", "cell_execution_order",
      "cell_results/*/published_object_keys", "cell_results/*/logs",
      "ember/packages/rows", "ember/plan/restart",
      "cell_results/*/ember/variables"
    )
  )
}

#' Test helper: stop naming every place where `x` breaks the convention
#' above (an atomic of length != 1 that isn't raw, a factor, an NA, a
#' Date/POSIXct, an unnamed empty `list()` where the schema says object).
#' Run over every projection the tests build.
check_wire <- function(x, schema = pluto_schema()) {
  problems <- character(0)
  note <- function(path, msg) {
    where <- if (length(path) == 0) "<root>" else paste(path, collapse = "/")
    problems[[length(problems) + 1L]] <<- paste0(where, ": ", msg)
  }
  schema_key <- function(path) {
    paste(ifelse(grepl("^[0-9]+$", path), "*", path), collapse = "/")
  }
  walk <- function(x, path) {
    key <- schema_key(path)
    if (key %in% schema$maps && !is_map(x)) {
      note(path, "schema says map ({}) but value is not a named list")
    }
    if (key %in% schema$arrays && (is_map(x) || is.data.frame(x))) {
      note(path, "schema says array ([]) but value is a map")
    }
    if (is.raw(x)) {
      # bytes: fine as-is (msgpack bin)
    } else if (is.factor(x)) {
      note(path, "is a factor; convert to character before sending")
    } else if (inherits(x, "Date") || inherits(x, "POSIXct")) {
      note(path, "is a Date/POSIXct; encode as a double (seconds)")
    } else if (is.list(x)) {
      if (is_map(x)) {
        for (nm in names(x)) walk(x[[nm]], c(path, nm))
      } else {
        for (i in seq_along(x)) walk(x[[i]], c(path, as.character(i - 1L)))
      }
    } else if (is.atomic(x)) {
      if (length(x) != 1) {
        note(path, sprintf("atomic vector of length %d, not 1 (wrap in a list for an array)", length(x)))
      } else if (anyNA(x)) {
        note(path, "is NA; the wire has no NA, use NULL instead")
      }
    }
  }
  walk(x, character(0))
  if (length(problems) > 0) {
    stop("check_wire() found problems:\n", paste(problems, collapse = "\n"), call. = FALSE)
  }
  invisible(TRUE)
}
