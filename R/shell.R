# The shell: the only impure part of the server side. It owns the mutable
# things the core can't hold (the processx handle, the sockets, the read
# buffer, timers, listeners, the last text written) and does three jobs:
#
# 1. `dispatch()`: feed one event to `step()`, carry out its effects, and
#    keep going until no event is waiting (effects can produce events).
# 2. After each dispatch: write the file if its text changed, tell
#    listeners what changed, adjust the watched files.
# 3. A `later` poll that turns bytes from the worker, process exits and
#    file changes into events.
#
# Everything runs on R's one thread. The only rule needed for safety is
# that a drain doesn't re-enter: an event raised by an effect joins the
# inbox and is handled by the drain already running. Listeners are called
# after the drain has finished, so an API call from a listener starts a
# fresh dispatch and gets its reply.

# ---- The handle --------------------------------------------------------------

#' Make the session handle for a state. Starts the poll loop.
#'
#' An `ember_notebook` environment with:
#' `state` (the current `ember_state`), `inbox` (list of events),
#' `draining` (logical), `written` (the file text last written or read:
#' the save comparison's baseline), `listeners` (named list of functions),
#' `proc` (processx process or `NULL`), `proc_gen` (its generation),
#' `listen` (server socket for the worker to connect to), `port`,
#' `secret` (random string the worker must send in its hello; any process
#' on the machine can reach a loopback port), `con` (the worker socket or
#' `NULL`), `rx` (`list(chunks, n)`: raw chunks not yet framed, and their
#' total length), `watch` (path -> mtime), `poll_cancel` (the `later`
#' cancel function), `closing` (listeners are cleared only after the
#' closing dispatch's notifications are delivered).
#' The poll runs on `later`'s global loop, so an interactive console
#' services it whenever R is at the prompt.
session_start <- function(state) {
  nb <- new.env(parent = emptyenv())
  nb$state <- state
  nb$inbox <- list()
  nb$draining <- FALSE
  nb$written <- format_notebook(notebook_file_of(state))
  nb$saved <- FALSE
  nb$listeners <- list()
  nb$proc <- NULL
  nb$proc_gen <- 0L
  nb$listen <- NULL
  nb$port <- NULL
  nb$secret <- random_secret()
  nb$con <- NULL
  nb$rx <- list(chunks = list(), n = 0L)
  nb$out_tail <- ""
  nb$watch <- list()
  nb$last_watch_check <- NULL
  nb$poll_cancel <- NULL
  nb$closing <- FALSE
  class(nb) <- "ember_notebook"

  reset_sigint()
  schedule_poll(nb)
  nb
}

#' A random string for the worker's hello to carry back.
random_secret <- function(n = 40) {
  paste(sample(c(letters, LETTERS, 0:9), n, replace = TRUE), collapse = "")
}

#' Append an event to the inbox. Effects call this to raise a new event
#' inside the drain already running; the poll calls it once per frame
#' before draining.
enqueue <- function(nb, event) {
  nb$inbox[[length(nb$inbox) + 1]] <- event
  invisible(NULL)
}

schedule_poll <- function(nb, interval = 0.005) {
  nb$poll_cancel <- later::later(function() poll(nb), interval)
  invisible(NULL)
}

cancel_poll <- function(nb) {
  if (!is.null(nb$poll_cancel)) {
    try(nb$poll_cancel(), silent = TRUE)
    nb$poll_cancel <- NULL
  }
  invisible(NULL)
}

#' Is `p` an absolute path (unix `/...` or a Windows drive/UNC path)?
is_absolute_path <- function(p) grepl("^(/|~|[A-Za-z]:[\\/]|\\\\\\\\)", p)

#' A sourced-file path as given by the graph or `computed_sources`,
#' resolved against the notebook's folder when it isn't already absolute.
resolve_source_path <- function(nb, p) {
  if (is_absolute_path(p)) p else file.path(dirname(nb$state$path), p)
}

# ---- Dispatch ----------------------------------------------------------------

#' Feed an event to the core and carry out everything that follows.
#'
#' Returns the reply of `event` itself (not of events it caused).
#' `dispatch(nb, e)` is `enqueue(nb, e); drain(nb)`; the poll enqueues
#' several events and drains once.
dispatch <- function(nb, event) {
  enqueue(nb, event)
  drain(nb)
}

#' Drain the inbox: `step()` each event, carry out its effects (which may
#' enqueue more events), and save/notify once the inbox is empty. Not
#' reentrant: a drain already running keeps the event and returns `NULL`
#' to this call; the running drain will reach it.
drain <- function(nb) {
  if (isTRUE(nb$draining)) return(NULL)
  nb$draining <- TRUE
  on.exit(nb$draining <- FALSE)

  before <- nb$state
  reply <- NULL
  first <- TRUE
  while (length(nb$inbox) > 0) {
    e <- nb$inbox[[1]]
    nb$inbox <- nb$inbox[-1]
    r <- step(nb$state, e)
    nb$state <- r$state
    if (first) {
      reply <- r$reply
      first <- FALSE
    }
    for (fx in r$effects) run_effect(nb, fx)
    if (length(nb$inbox) == 0) save_if_changed(nb)
  }

  nb$draining <- FALSE
  after_dispatch(nb, before)
  reply
}

#' Save the file if its text changed. Called inside the drain, after the
#' inbox empties.
#'
#' Formatting the whole file per drain is cheap only because
#' `notebook_file_of()` is skipped when `cells`, `graph$order`,
#' `graph$learned`, `files` and `file` are identical to the previous
#' drain's (handled by `notebook_graph()`'s analysis cache and R's
#' `identical()` short cuts on unchanged parts).
save_if_changed <- function(nb) {
  s <- nb$state
  if (isTRUE(s$read_only)) return(invisible(NULL))
  text <- format_notebook(notebook_file_of(s))
  if (!identical(text, nb$written)) {
    ok <- write_atomic(s$path, text)
    if (ok) {
      nb$written <- text
      nb$saved <- TRUE
    } else {
      enqueue(nb, ev_save_failed("could not write the notebook file", at = Sys.time()))
    }
  }
  invisible(NULL)
}

#' Notify and re-watch: derived from the state change over a dispatch.
after_dispatch <- function(nb, before) {
  notes <- notifications(before, nb$state)
  if (isTRUE(nb$saved)) {
    notes <- c(notes, list(list(kind = "file_saved")))
    nb$saved <- FALSE
  }
  notes <- lapply(notes, function(n) {
    n$seq <- nb$state$seq
    n
  })
  for (fn in nb$listeners) {
    for (n in notes) {
      tryCatch(fn(n), error = function(e) {
        message("ember: notebook event listener failed: ", conditionMessage(e))
      })
    }
  }
  sync_watch(nb, watched_files(nb$state))
  if (isTRUE(nb$closing)) nb$listeners <- list()
  invisible(NULL)
}

#' Carry out one effect. Errors become events, never escape.
run_effect <- function(nb, fx) {
  switch(fx$type,
    start_worker = {
      tryCatch(
        start_worker_process(nb, fx),
        error = function(e) enqueue(nb, wk_failed(fx$gen, conditionMessage(e), at = Sys.time()))
      )
    },
    kill_worker = {
      if (identical(nb$proc_gen, fx$gen)) {
        if (!is.null(nb$proc) && isTRUE(tryCatch(nb$proc$is_alive(), error = function(e) FALSE))) {
          tryCatch(nb$proc$kill(), error = function(e) NULL)
        }
        if (!is.null(nb$con)) {
          tryCatch(close(nb$con), error = function(e) NULL)
          nb$con <- NULL
        }
        nb$proc <- NULL
        nb$rx <- list(chunks = list(), n = 0L)
      }
    },
    interrupt = {
      if (identical(nb$proc_gen, fx$gen) && !is.null(nb$proc)) {
        tryCatch(nb$proc$interrupt(), error = function(e) NULL)
      }
    },
    send = {
      if (identical(nb$proc_gen, fx$gen) && !is.null(nb$con)) {
        tryCatch(write_frame(nb$con, fx$msg), error = function(e) NULL)
      }
    },
    timer = {
      later::later(function() dispatch(nb, stamp(fx$event)), fx$delay)
    },
    read_files = {
      files <- list()
      for (p in fx$paths) {
        full <- resolve_source_path(nb, p)
        files[[p]] <- read_sourced_file(full)
      }
      enqueue(nb, ev_files_read(files, at = Sys.time()))
    },
    move_file = {
      tryCatch(file.rename(fx$from, fx$to), error = function(e) NULL)
    },
    close = {
      nb$closing <- TRUE
      cancel_poll(nb)
      if (!is.null(nb$con)) {
        tryCatch(close(nb$con), error = function(e) NULL)
        nb$con <- NULL
      }
      if (!is.null(nb$listen)) {
        tryCatch(close(nb$listen), error = function(e) NULL)
        nb$listen <- NULL
      }
    },
    stop("ember: unknown effect type: ", fx$type)
  )
  invisible(NULL)
}

#' Read one sourced file for `ev_files_read`: `list(text, hash)`, with
#' `text = NA` when the file is missing.
read_sourced_file <- function(path) {
  if (!file.exists(path)) return(list(text = NA_character_, hash = NA_character_))
  text <- tryCatch({
    raw <- readBin(path, "raw", n = file.info(path)$size)
    t <- rawToChar(raw)
    Encoding(t) <- "UTF-8"
    t
  }, error = function(e) NA_character_)
  hash <- tryCatch(unname(tools::md5sum(path)), error = function(e) NA_character_)
  list(text = text, hash = hash)
}

#' Stamp the time on an event made ahead of time (timers).
stamp <- function(event) { event$at <- Sys.time(); event }

# ---- The worker process ------------------------------------------------------

#' A free TCP port to listen on, as a server socket.
pick_listen_socket <- function(tries = 50) {
  for (i in seq_len(tries)) {
    port <- sample(20000:59999, 1)
    s <- tryCatch(serverSocket(port), error = function(e) NULL)
    if (!is.null(s)) return(list(socket = s, port = port))
  }
  stop("ember: could not find a free port after ", tries, " tries")
}

#' Spawn a worker. Never waits for it: the connection is accepted by the
#' poll once the listening socket is readable.
start_worker_process <- function(nb, fx) {
  if (is.null(nb$listen)) {
    picked <- pick_listen_socket()
    nb$listen <- picked$socket
    nb$port <- picked$port
  }
  lib <- fx$library
  if (is.null(lib)) lib <- file.path(tempdir(), "ember-empty-lib")
  if (!dir.exists(lib)) dir.create(lib, recursive = TRUE, showWarnings = FALSE)

  rscript <- file.path(R.home("bin"), "Rscript")
  boot <- paste0(
    "local({e <- new.env(parent = baseenv()); ",
    "sys.source(Sys.getenv('EMBER_WORKER'), e); e$main()})")
  env <- c("current",
           R_LIBS_USER = lib, R_LIBS = "", R_LIBS_SITE = "",
           EMBER_WORKER = system.file("worker.R", package = "ember"),
           EMBER_SECRET = nb$secret)
  wd <- fx$wd
  if (is.null(wd) || !nzchar(wd)) wd <- getwd()

  proc <- processx::process$new(
    rscript, c("--vanilla", "-e", boot, as.character(nb$port)),
    env = env, wd = wd, stdout = "|", stderr = "2>&1", cleanup_tree = TRUE)

  if (!is.null(nb$con)) tryCatch(close(nb$con), error = function(e) NULL)
  nb$proc <- proc
  nb$proc_gen <- fx$gen
  nb$out_tail <- ""
  nb$con <- NULL
  nb$rx <- list(chunks = list(), n = 0L)
  enqueue(nb, wk_started(fx$gen, proc$get_pid(), at = Sys.time()))
  invisible(NULL)
}

#' Whatever the worker has written to stdout or stderr since the last poll.
#' Cell output is captured inside the worker; this is R's own and native
#' code's output, and the pipe must be drained or the worker blocks once
#' it fills.
read_output_now <- function(proc) {
  tryCatch(if (proc$is_alive()) proc$read_output() else "", error = function(e) "")
}

#' Keep the last few KB of the worker's own output, for the exit message.
keep_output_tail <- function(nb, text, keep = 4000L) {
  if (!nzchar(text)) return(invisible(NULL))
  all <- paste0(nb$out_tail, text)
  n <- nchar(all)
  nb$out_tail <- if (n > keep) substr(all, n - keep + 1L, n) else all
  invisible(NULL)
}

#' The poll, every 5 ms while a worker exists, every 500 ms otherwise.
#' File watching is checked at most every 500 ms regardless of the poll
#' interval, so a busy worker doesn't make it noisier.
poll <- function(nb) {
  if (!is.null(nb$proc) && is.null(nb$con) && !is.null(nb$listen)) {
    if (isTRUE(tryCatch(socketSelect(list(nb$listen), timeout = 0), error = function(e) FALSE))) {
      nb$con <- tryCatch(socketAccept(nb$listen, blocking = FALSE, open = "a+b"),
                         error = function(e) NULL)
    }
  }

  if (!is.null(nb$con)) {
    repeat {
      chunk <- tryCatch(readBin(nb$con, "raw", 65536), error = function(e) raw(0))
      if (length(chunk) == 0) break
      nb$rx$chunks[[length(nb$rx$chunks) + 1]] <- chunk
      nb$rx$n <- nb$rx$n + length(chunk)
    }
    framed <- take_frames(nb$rx)
    nb$rx <- framed$rx
    if (length(framed$messages) > 0) {
      broke <- FALSE
      for (msg in framed$messages) {
        ev <- worker_event(msg, nb$proc_gen, Sys.time(), secret = nb$secret)
        enqueue(nb, ev)
        if (identical(ev$type, "wk_failed")) {
          # A worker that speaks nonsense, or gives the wrong secret, can't
          # be trusted to be running the notebook: stop listening to it.
          if (!is.null(nb$proc) && isTRUE(tryCatch(nb$proc$is_alive(), error = function(e) FALSE))) {
            tryCatch(nb$proc$kill(), error = function(e) NULL)
          }
          if (!is.null(nb$con)) {
            tryCatch(close(nb$con), error = function(e) NULL)
            nb$con <- NULL
          }
          nb$proc <- NULL
          broke <- TRUE
          break
        }
      }
      drain(nb)
      if (broke) { schedule_poll(nb); return(invisible(NULL)) }
    }
  }

  if (!is.null(nb$proc)) keep_output_tail(nb, read_output_now(nb$proc))

  if (!is.null(nb$proc) && !isTRUE(tryCatch(nb$proc$is_alive(), error = function(e) FALSE))) {
    status <- tryCatch(nb$proc$get_exit_status(), error = function(e) NA_integer_)
    keep_output_tail(nb, tryCatch(nb$proc$read_all_output(), error = function(e) ""))
    tail <- nb$out_tail
    gen <- nb$proc_gen
    nb$proc <- NULL
    nb$out_tail <- ""
    if (!is.null(nb$con)) {
      tryCatch(close(nb$con), error = function(e) NULL)
      nb$con <- NULL
    }
    nb$rx <- list(chunks = list(), n = 0L)
    dispatch(nb, wk_exited(gen, status, tail, at = Sys.time()))
  }

  now <- Sys.time()
  if (is.null(nb$last_watch_check) ||
      as.numeric(now - nb$last_watch_check, units = "secs") >= 0.5) {
    nb$last_watch_check <- now
    changed <- list()
    for (p in names(nb$watch)) {
      full <- resolve_source_path(nb, p)
      mt <- tryCatch(file.info(full)$mtime, error = function(e) NA)
      if (!isTRUE(identical(mt, nb$watch[[p]]))) {
        nb$watch[[p]] <- mt
        changed[[p]] <- read_sourced_file(full)
      }
    }
    if (length(changed) > 0) dispatch(nb, ev_files_read(changed, at = Sys.time()))
  }

  interval <- if (!is.null(nb$proc)) 0.005 else 0.5
  schedule_poll(nb, interval)
  invisible(NULL)
}

#' Split buffered bytes into complete frames.
#'
#' Frame: 4-byte big-endian length, then `serialize()` bytes. Pure. `rx` is
#' `list(chunks = <list of raw>, n = <total bytes>)`; chunks are joined
#' only once a whole frame is present, so a 50 MB message read in 64 KB
#' pieces costs one copy, not a quadratic series of them.
#' @return `list(messages = <list>, rx = <the rest>)`.
take_frames <- function(rx) {
  chunks <- rx$chunks
  n <- rx$n
  messages <- list()

  repeat {
    if (n < 4L) break

    header <- raw(0)
    i <- 1L
    while (length(header) < 4L) {
      header <- c(header, chunks[[i]])
      i <- i + 1L
    }
    header <- header[1:4]
    len <- readBin(header, "integer", n = 1, endian = "big")
    total <- 4L + len
    if (n < total) break

    joined <- raw(total)
    pos <- 0L
    consumed <- 0L
    leftover <- NULL
    for (j in seq_along(chunks)) {
      ch <- chunks[[j]]
      need <- total - pos
      if (length(ch) <= need) {
        joined[(pos + 1):(pos + length(ch))] <- ch
        pos <- pos + length(ch)
        consumed <- j
        if (pos == total) break
      } else {
        joined[(pos + 1):total] <- ch[1:need]
        leftover <- ch[(need + 1):length(ch)]
        consumed <- j
        pos <- total
        break
      }
    }
    payload <- joined[5:total]
    messages[[length(messages) + 1]] <- unserialize(payload)

    rest <- if (consumed < length(chunks)) chunks[(consumed + 1):length(chunks)] else list()
    chunks <- if (!is.null(leftover) && length(leftover) > 0) c(list(leftover), rest) else rest
    n <- n - total
  }

  list(messages = messages, rx = list(chunks = chunks, n = n))
}

#' `serialize()` a message, prefix its length, write it. Messages to the
#' worker are small (code, ids); a blocking write is fine.
write_frame <- function(con, msg) {
  payload <- serialize(msg, NULL)
  writeBin(length(payload), con, endian = "big")
  writeBin(payload, con)
  flush(con)
  invisible(NULL)
}

#' Turn a wire message into a core event (the boundary: validate here,
#' trust inside). A malformed message, or a hello with the wrong secret,
#' becomes `wk_failed(gen, "protocol error: ...")`; the poll kills the
#' process when it sees one.
worker_event <- function(msg, gen, at, secret = NULL) {
  if (is.null(msg) || is.null(msg$type) || !is.character(msg$type)) {
    return(wk_failed(gen, "protocol error: message has no type", at))
  }

  required <- switch(msg$type,
    hello    = c("secret", "pid"),
    console  = c("token", "item"),
    source   = c("token", "path", "text"),
    done     = c("token", "report"),
    rendered = c("cell"),
    NULL
  )
  if (is.null(required)) {
    return(wk_failed(gen, paste0("protocol error: unknown message type ", msg$type), at))
  }
  if (!all(required %in% names(msg))) {
    return(wk_failed(gen, paste0("protocol error: malformed ", msg$type, " message"), at))
  }

  switch(msg$type,
    hello = {
      if (!is.null(secret) && !identical(msg$secret, secret)) {
        return(wk_failed(gen, "protocol error: wrong secret", at))
      }
      wk_hello(gen, list(pid = msg$pid, r_version = msg$r_version, lib_paths = msg$lib_paths), at)
    },
    console  = wk_console(gen, msg$token, msg$item, at),
    source   = wk_source(gen, msg$token, msg$path, msg$text, at),
    done     = {
      report <- msg$report
      report$output <- as_display(report$output)
      wk_done(gen, msg$token, report, at)
    },
    rendered = wk_rendered(gen, msg$cell, as_display(msg$display), at)
  )
}

#' The worker's display bundle (`list(kind, mime, text, truncated, ...)`,
#' see worker.R) as an `ember_display` (state.R). `data` is the kind's own
#' body: the html string, the PNG bytes, the table/tree structure; `NULL`
#' for the plain text form, whose `text` field already is the whole body.
as_display <- function(b) {
  if (is.null(b)) return(NULL)
  data <- switch(b$kind,
    text  = NULL,
    html  = b$html,
    plot  = b$data,
    table = list(columns = b$columns, types = b$types, nrow = b$nrow),
    tree  = b$tree,
    b[!(names(b) %in% c("kind", "mime", "text", "truncated"))]
  )
  new_display(mime = b$mime, data = data, text = b$text %||% "", deps = b$deps %||% list())
}

#' Before the first worker starts: if this process inherited SIGINT as
#' ignored (started with `&`, nohup, some launchers), set it back to the
#' default, so workers inherit a working interrupt. C code in src/
#' (the spike's sigreset.c). Harmless to call more than once.
reset_sigint <- function() invisible(.Call(C_reset_sigint))

#' Atomic write: write to a temp file in the same folder, then rename.
#' Returns `FALSE`, leaving `path` untouched, if either step fails (e.g.
#' the folder isn't writable).
write_atomic <- function(path, text) {
  dir <- dirname(path)
  tmp <- tempfile("ember-", tmpdir = dir, fileext = ".tmp")
  wrote <- tryCatch(suppressWarnings({
    con <- file(tmp, open = "wb")
    on.exit(close(con))
    writeBin(charToRaw(enc2utf8(text)), con)
    TRUE
  }), error = function(e) FALSE)
  if (!isTRUE(wrote)) {
    unlink(tmp)
    return(FALSE)
  }
  moved <- tryCatch({ file.rename(tmp, path); TRUE }, error = function(e) FALSE)
  if (!isTRUE(moved) || !file.exists(path)) {
    unlink(tmp)
    return(FALSE)
  }
  TRUE
}

#' Start/stop watching: keep mtimes for new paths, drop old ones.
sync_watch <- function(nb, paths) {
  old <- names(nb$watch)
  for (p in setdiff(paths, old)) {
    full <- resolve_source_path(nb, p)
    nb$watch[[p]] <- tryCatch(file.info(full)$mtime, error = function(e) NA)
  }
  for (p in setdiff(old, paths)) {
    nb$watch[[p]] <- NULL
  }
  invisible(NULL)
}
