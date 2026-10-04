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
#' the save comparison's baseline), `save_failed_text` (the text a write
#' last failed on, or `NULL`: skips retrying it until it changes, so a
#' write that can never succeed -- e.g. a move to a folder that doesn't
#' exist -- doesn't spin the drain forever), `listeners` (named list of functions),
#' `proc` (processx process or `NULL`), `proc_gen` (its generation),
#' `listen` (server socket for the worker to connect to), `port`,
#' `secret` (random string the worker must send in its hello; any process
#' on the machine can reach a loopback port), `con` (the worker socket or
#' `NULL`), `rx` (`list(chunks, n)`: raw chunks not yet framed, and their
#' total length), `watch` (path -> mtime), `last_mem_check`/
#' `worker_rss_reported` (the worker memory sampler's own timer and
#' last-reported value, below), `poll_cancel` (the `later`
#' cancel function), `closing` (listeners are cleared only after the
#' closing dispatch's notifications are delivered), `queries` (environment,
#' id (character) -> callback, for `worker_query()`'s pending completion/
#' help/signature questions -- outside `ember_state` and the event log, see
#' `worker_query()`), `next_query_id` (integer, last id handed out).
#' The poll runs on `later`'s global loop, so an interactive console
#' services it whenever R is at the prompt.
session_start <- function(state) {
  nb <- new.env(parent = emptyenv())
  nb$state <- state
  nb$inbox <- list()
  nb$draining <- FALSE
  nb$written <- format_notebook(notebook_file_of(state))
  nb$saved <- FALSE
  nb$save_failed_text <- NULL
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
  nb$last_mem_check <- NULL
  nb$worker_rss_reported <- NULL
  nb$poll_cancel <- NULL
  nb$closing <- FALSE
  nb$queries <- new.env(parent = emptyenv())
  nb$next_query_id <- 0L
  class(nb) <- "ember_notebook"

  reset_sigint()
  register_session(nb)
  sync_active_libraries()
  maybe_start_cleanup()
  schedule_poll(nb)
  nb
}

# ---- Open-session registry (packages-core.R's `clean()` wiring) --------------

#' Every currently open `ember_notebook` in this process, keyed by its
#' state's `id` (a UUID, stable for the notebook's whole life even across a
#' `move`). Used only to keep `active_libraries` (library.R) accurate, so
#' `clean()` never deletes a library an open session holds as `target` or
#' `active`. Mutated only by `session_start()` and the `close` effect.
open_sessions <- new.env(parent = emptyenv())

register_session <- function(nb) {
  assign(nb$state$id, nb, envir = open_sessions)
  invisible(NULL)
}

unregister_session <- function(nb) {
  id <- nb$state$id
  if (exists(id, envir = open_sessions, inherits = FALSE)) rm(list = id, envir = open_sessions)
  invisible(NULL)
}

#' Recompute `active_libraries` (library.R) from every open session's
#' current `target`/`active` library path and hand the whole set to
#' `set_active_libraries()`. Called after `register_session()`/
#' `unregister_session()` and from `after_dispatch()`, so the set is never
#' more than one dispatch stale. Cheap regardless of how big any notebook
#' is: one pass over however many notebooks are open, reading two fields
#' already computed on each, never a notebook's cells or graph.
sync_active_libraries <- function() {
  ids <- ls(open_sessions, all.names = TRUE)
  paths <- unlist(lapply(ids, function(id) {
    p <- open_sessions[[id]]$state$packages
    c(p$target$path, p$active$path)
  }), use.names = FALSE)
  set_active_libraries(unique(paths))
  invisible(NULL)
}

#' Whether the once-per-process startup `clean()` (design.md: "when the
#' server starts") has already been scheduled.
startup_clean <- local({
  env <- new.env(parent = emptyenv())
  env$scheduled <- FALSE
  env
})

#' Run `clean()` once per process, the first time any notebook opens.
#' Deferred to a `later` callback (delay 0, so it runs on the next tick of
#' the same event loop everything else here already uses) rather than run
#' inline: `open_notebook()` must never block on a filesystem walk over the
#' whole cache. `cache = FALSE`: the default 60-day sweep of libraries,
#' staging folders and indexes, not the slower renv-cache reconciliation
#' (design.md's own split for this call). Safe to call as often as
#' `session_start()` likes; only the first call after process start does
#' anything.
maybe_start_cleanup <- function() {
  if (isTRUE(startup_clean$scheduled)) return(invisible(NULL))
  startup_clean$scheduled <- TRUE
  later::later(function() tryCatch(clean(cache = FALSE), error = function(e) NULL), 0)
  invisible(NULL)
}

#' `n` raw bytes from the OS random source (src/random.c): never
#' sample()/runif(), which are predictable after set.seed() and would
#' advance the caller's .Random.seed just by starting a server.
os_random_bytes <- function(n) .Call(C_random_bytes, as.integer(n))

#' A random string for the worker's hello to carry back, and (serve()'s
#' default) the URL secret. Drawn from the OS random source, not R's own
#' generator: design.md, Processes -- "any process on the machine can reach
#' a loopback port", so this must not be guessable from set.seed(), and
#' starting a server must not change the caller's random stream.
random_secret <- function(n = 40) {
  alphabet <- c(letters, LETTERS, as.character(0:9))
  idx <- as.integer(os_random_bytes(n)) %% length(alphabet) + 1L
  paste(alphabet[idx], collapse = "")
}

#' A port in 20000:59999 from the OS random source, not sample(): used
#' wherever a port is picked opportunistically (pick_free_port(),
#' pick_listen_socket()) so probing for a free port never touches the
#' caller's .Random.seed.
random_port <- function() {
  b <- as.integer(os_random_bytes(2))
  20000L + ((b[1] * 256L + b[2]) %% 40000L)
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
#'
#' A failed write (the file's new folder is gone, permissions changed, the
#' disk is full) is not retried with the same text: `ev_save_failed()` joins
#' the inbox and is processed by this same drain, which calls this function
#' again with `text` unchanged, so without `nb$save_failed_text` the write
#' would fail, re-enqueue, and fail again forever (every poll tick), pinning
#' a core at 100% CPU. The failure is recorded once in `problems`; the next
#' change (any dispatch that makes `text` differ, e.g. a successful
#' move_notebook() to a folder that does exist) tries again.
save_if_changed <- function(nb) {
  s <- nb$state
  if (isTRUE(s$read_only)) return(invisible(NULL))
  text <- format_notebook(notebook_file_of(s))
  if (identical(text, nb$written)) return(invisible(NULL))
  if (!is.null(nb$save_failed_text) && identical(text, nb$save_failed_text)) return(invisible(NULL))
  ok <- write_atomic(s$path, text)
  if (ok) {
    nb$written <- text
    nb$saved <- TRUE
    nb$save_failed_text <- NULL
  } else {
    nb$save_failed_text <- text
    enqueue(nb, ev_save_failed("could not write the notebook file", at = Sys.time()))
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
  # Any dispatch can have changed `target`/`active` (an install finished, a
  # switch happened, a close unregistered this session already): keep
  # `clean()`'s view of what's in use current.
  sync_active_libraries()
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
        fail_pending_queries(nb)
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
    # `file.rename()` fails across filesystems (a different volume, a
    # bind-mounted folder) without throwing -- it just returns `FALSE`,
    # which the previous version of this effect never checked, silently
    # leaving the file at `fx$from` while `state$path` had already moved
    # on to `fx$to`. Falling back to copy + unlink covers that case; if
    # the copy fails too (the target is read-only, out of space), the
    # move is reported as a problem rather than leaving the mismatch
    # between `state$path` and the file's real location unexplained.
    move_file = {
      moved <- tryCatch(suppressWarnings(file.rename(fx$from, fx$to)), error = function(e) FALSE)
      if (!isTRUE(moved)) {
        copied <- tryCatch(suppressWarnings(file.copy(fx$from, fx$to, overwrite = FALSE)), error = function(e) FALSE)
        if (isTRUE(copied)) {
          tryCatch(unlink(fx$from), error = function(e) NULL)
        } else {
          enqueue(nb, ev_save_failed("could not move the notebook file", at = Sys.time()))
        }
      }
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
      unregister_session(nb)
    },
    fetch_index = {
      idx <- tryCatch(cached_index(fx$key, nb$state$options$cache, url = fx$url), error = function(e) NULL)
      if (!is.null(idx)) {
        enqueue(nb, ev_index_fetched(fx$key, idx, at = Sys.time()))
      } else {
        cmd <- index_fetch_command(fx$key, fx$url, nb$state$options$cache)
        # The process-wide job table (library.R) is keyed on more than `key`:
        # a date string, the job key on its own would let two sessions with
        # the same key but different repositories or cache directories join
        # the same download/parse job and each get an index that doesn't
        # match their own `url`/`cache`.
        job_start(index_job_key(fx$key, fx$url, nb$state$options$cache), cmd, nb,
          make_progress = function(line) NULL,
          make_done = function(status, output) {
            if (identical(status, 0L)) {
              idx2 <- tryCatch(cached_index(fx$key, nb$state$options$cache, url = fx$url),
                               error = function(e) NULL)
              if (!is.null(idx2)) ev_index_fetched(fx$key, idx2, at = Sys.time())
              else ev_index_failed(fx$key, "index fetch produced no index", at = Sys.time())
            } else {
              ev_index_failed(fx$key, paste(utils::tail(output, 20), collapse = "\n"), at = Sys.time())
            }
          })
      }
    },
    check_library = {
      touch_library(fx$path)
      manifest <- tryCatch(read_library_manifest(fx$path), error = function(e) NULL)
      enqueue(nb, ev_library_checked(fx$key, manifest, at = Sys.time()))
    },
    install = {
      cmd <- installer_command(fx$lock, fx$repos, fx$path, nb$state$options$cache)
      # Keyed by `path`, not `key`: `key` is a hash of the lock text alone
      # (library_for(), lock.R), the same for two sessions with the same
      # lock but different library paths (different caches, or -- in tests
      # -- the same process pointed at two cache directories). Two such
      # installs are not the same job and must not share one subprocess or
      # one `job$subs` list.
      job_start(fx$path, cmd, nb,
        make_progress = function(line) {
          item <- parse_install_progress_line(line)
          if (is.null(item)) NULL else ev_install_progress(fx$token, item, at = Sys.time())
        },
        make_done = function(status, output) {
          manifest <- tryCatch(read_library_manifest(fx$path), error = function(e) NULL)
          lines <- strsplit(output, "\n", fixed = TRUE)[[1]]
          failed <- !identical(status, 0L)
          ev_install_done(fx$token, fx$key, manifest,
                          message = if (failed) install_failure_message(lines, status) else NULL,
                          log = utils::tail(lines, 200),
                          failures = if (failed) install_failures(lines) else empty_install_failures(),
                          at = Sys.time())
        })
    },
    cancel_install = {
      job_leave(fx$path, nb)
    },
    cancel_fetch_index = {
      job_leave(index_job_key(fx$key, fx$url, nb$state$options$cache), nb)
    },
    stop("ember: unknown effect type: ", fx$type)
  )
  invisible(NULL)
}

#' Best-effort parse of one line of the installer's output into a progress
#' item, or `NULL` when the line isn't progress. (design.md, Tradeoffs
#' accepted: "best-effort install progress, parsed from renv's output,
#' ... the manifest, not the progress, says what was installed.") renv's own
#' console format isn't contracted, so increment 1 ships with no parser
#' rather than one tuned to a format that can change under it; `fx_install`
#' effects still carry progress events end to end once one is written here.
parse_install_progress_line <- function(line) NULL

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
    port <- random_port()
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
  tryCatch(touch_library(lib), error = function(e) NULL)

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
  # A new generation's memory starts from nothing known: comparing its first
  # sample against the old worker's last-reported RSS would compare two
  # different processes' numbers against each other, and could skip
  # reporting the new worker's actual first value.
  nb$last_mem_check <- NULL
  nb$worker_rss_reported <- NULL
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

#' Whether a freshly sampled RSS (bytes) differs enough from the last one
#' reported to be worth another event: no report yet, or moved by more than
#' 16 MB or 5%, whichever is larger in absolute terms for a big process
#' (ui-2.md, Worker memory). Pure, so it's tested directly against a
#' sequence of samples without a real worker.
should_report_memory <- function(reported, rss) {
  if (is.null(reported)) return(TRUE)
  diff <- abs(rss - reported)
  diff > 16 * 1024^2 || diff > 0.05 * reported
}

#' Sample `nb$proc`'s memory once and, if it moved enough, dispatch
#' `ev_worker_usage()`. Takes `at` rather than calling `Sys.time()` itself so
#' a test can drive it with a fake `nb$proc` and a fixed clock.
#'
#' `get_memory_info()` (processx, backed by the ps package) can fail --
#' unsupported platform, or the process exiting between the liveness check
#' and the call; either way memory is just left out, never a crash that
#' would take the whole poll down with it (ui-2.md's Windows/CI risk).
sample_worker_memory <- function(nb, at) {
  info <- tryCatch(nb$proc$get_memory_info(), error = function(e) NULL)
  rss <- if (!is.null(info)) unname(info[["rss"]]) else NULL
  if (is.null(rss) || is.na(rss)) return(invisible(NULL))
  rss <- as.double(rss)
  if (should_report_memory(nb$worker_rss_reported, rss)) {
    nb$worker_rss_reported <- rss
    dispatch(nb, ev_worker_usage(nb$proc_gen, rss, at))
  }
  invisible(NULL)
}

#' The 2s gate around `sample_worker_memory()`, called from `poll()`.
#' `last_mem_check` is reset whenever a worker (re)spawns
#' (`start_worker_process()`), so a fresh worker's first sample isn't
#' delayed by up to 2s of a stopped predecessor's old timer.
maybe_sample_worker_memory <- function(nb, now) {
  # Before the worker connects, the process is still starting R and its
  # size (a few MB) would read as the session's memory.
  if (is.null(nb$proc) || is.null(nb$con)) return(invisible(NULL))
  if (!is.null(nb$last_mem_check) && as.numeric(now - nb$last_mem_check, units = "secs") < 2) {
    return(invisible(NULL))
  }
  nb$last_mem_check <- now
  sample_worker_memory(nb, now)
}

#' `TRUE` when `nb`'s worker can take a query right now: execution allowed,
#' status "ready" (so not starting, stopped or off), nothing running or
#' queued to run, and the socket open. ui-2.md, "4a. Queries to the
#' worker".
worker_is_idle <- function(nb) {
  st <- nb$state
  isTRUE(st$allowed) && identical(st$worker$status, "ready") &&
    is.null(st$worker$running) && length(st$pending) == 0 && !is.null(nb$con)
}

#' Ask the worker a question (`complete`, `help` or `signature`) outside
#' `step()` and the event log: these never change the notebook, so they
#' don't belong in the engine's history. `callback(reply)` runs once, with
#' the worker's reply, or with `NULL` at once if the worker isn't idle, or
#' with `NULL` after `timeout` seconds, or when the worker exits
#' (`fail_pending_queries()`). A reply that arrives after the timeout (or
#' after the worker that was asked is gone) finds no entry in `nb$queries`
#' and is dropped.
worker_query <- function(nb, msg, callback, timeout = 0.8) {
  if (!worker_is_idle(nb)) {
    callback(NULL)
    return(invisible(NULL))
  }
  id <- nb$next_query_id <- nb$next_query_id + 1L
  key <- as.character(id)
  msg$id <- id
  assign(key, callback, envir = nb$queries)
  ok <- tryCatch({ write_frame(nb$con, msg); TRUE }, error = function(e) FALSE)
  if (!ok) {
    rm(list = key, envir = nb$queries)
    callback(NULL)
    return(invisible(NULL))
  }
  later::later(function() {
    if (exists(key, envir = nb$queries, inherits = FALSE)) {
      cb <- get(key, envir = nb$queries, inherits = FALSE)
      rm(list = key, envir = nb$queries)
      cb(NULL)
    }
  }, timeout)
  invisible(NULL)
}

#' A `completions`/`help_page`/`signature` reply: find its callback by
#' `msg$id` and call it, or drop the message (its query already timed out).
answer_query <- function(nb, msg) {
  key <- as.character(msg$id)
  if (!exists(key, envir = nb$queries, inherits = FALSE)) return(invisible(NULL))
  cb <- get(key, envir = nb$queries, inherits = FALSE)
  rm(list = key, envir = nb$queries)
  cb(msg)
  invisible(NULL)
}

#' Every pending `worker_query()` callback, called with `NULL`: the worker
#' that was asked is gone (exited, or killed for a protocol error) and will
#' never answer.
fail_pending_queries <- function(nb) {
  for (key in ls(nb$queries, all.names = TRUE)) {
    cb <- get(key, envir = nb$queries, inherits = FALSE)
    rm(list = key, envir = nb$queries)
    cb(NULL)
  }
  invisible(NULL)
}

#' The poll, every 5 ms while a worker exists, every 500 ms otherwise.
#' File watching is checked at most every 500 ms regardless of the poll
#' interval, so a busy worker doesn't make it noisier.
poll <- function(nb) {
  tryCatch(poll_jobs(nb), error = function(e) NULL)
  # `poll_jobs()` only enqueues (an index fetch or an install may finish with
  # no worker involved at all, e.g. safe preview): without a worker message
  # arriving in the same tick, nothing below would otherwise drain the
  # inbox, and an index_fetched/install_done event would sit unprocessed
  # until some unrelated dispatch happened to drain it. `drain()` is a
  # cheap no-op when the inbox is already empty (the common case).
  if (length(nb$inbox) > 0) drain(nb)

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
        if (!is.null(msg$type) && msg$type %in% c("completions", "help_page", "signature")) {
          answer_query(nb, msg)
          next
        }
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
          fail_pending_queries(nb)
          broke <- TRUE
          break
        }
      }
      drain(nb)
      if (broke) { schedule_poll(nb); return(invisible(NULL)) }
    }
  }

  if (!is.null(nb$proc)) keep_output_tail(nb, read_output_now(nb$proc))
  maybe_sample_worker_memory(nb, Sys.time())

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
    fail_pending_queries(nb)
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
    rendered = c("cell", "token"),
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
      wk_hello(gen, list(pid = msg$pid, r_version = msg$r_version, lib_paths = msg$lib_paths,
                        loaded = msg$loaded %||% character()), at)
    },
    console  = wk_console(gen, msg$token, msg$item, at),
    source   = wk_source(gen, msg$token, msg$path, msg$text, at),
    done     = {
      report <- msg$report
      report$output <- as_display(report$output)
      if (!is.null(report$output)) report$output$token <- msg$token
      wk_done(gen, msg$token, report, at)
    },
    rendered = {
      display <- as_display(msg$display)
      if (!is.null(display)) display$token <- msg$token
      wk_rendered(gen, msg$cell, display, at)
    }
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
    table = list(names = b$names, types = b$types, nrow = b$nrow, ncol = b$ncol,
                row_labels = b$row_labels, rows = b$rows,
                more_rows = b$more_rows, more_cols = b$more_cols, na = b[["na", exact = TRUE]]),
    tree  = b$tree,
    b[!(names(b) %in% c("kind", "mime", "text", "truncated"))]
  )
  new_display(mime = b$mime, data = data, text = b$text %||% "", deps = b$deps %||% list(),
             size = b$size)
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
    tryCatch(writeBin(charToRaw(enc2utf8(text)), con), finally = close(con))
    TRUE
  }), error = function(e) FALSE)
  if (!isTRUE(wrote)) {
    unlink(tmp)
    return(FALSE)
  }
  # The temp file must be closed before this: Windows won't rename an open file.
  moved <- isTRUE(tryCatch(suppressWarnings(file.rename(tmp, path)), error = function(e) FALSE))
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
