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
#' cancel function), `output_watch` (`list(proc, cancel)` while the poll
#' waits on that worker's stdout pipe, `watch_worker_output()`), `closing` (listeners are cleared only after the
#' closing dispatch's notifications are delivered), `queries` (environment,
#' id (character) -> callback, for `worker_query()`'s pending completion/
#' help/signature questions and one-off renders -- outside `ember_state`
#' and the event log, see `worker_query()`), `late_queries` (the same, for
#' replies that timed out but are still wanted: `worker_query()`'s `late`),
#' `help_lookups` (environment, help query key -> `list(reply)`: a lookup
#' still running in the worker, `reply` NULL, or one that finished after its
#' docs reply timed out, kept for the next ask; server.R's `docs`, #356),
#' `next_query_id` (integer, last id handed out),
#' `file_inputs`/`watch_inputs` (what the last saved file text and the
#' last watched paths were made from: `save_if_changed()` and
#' `after_dispatch()` skip the work when these are unchanged; `NULL` until
#' the first drain).
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
  nb$reaper <- NULL
  nb$proc_gen <- 0L
  nb$listen <- NULL
  nb$port <- NULL
  nb$secret <- random_secret()
  nb$con <- NULL
  nb$rx <- list(chunks = list(), n = 0L)
  nb$out_tail <- ""
  nb$watch <- list()
  nb$data_watch <- list()
  nb$last_watch_check <- NULL
  nb$last_mem_check <- NULL
  nb$worker_rss_reported <- NULL
  nb$poll_cancel <- NULL
  nb$output_watch <- NULL
  nb$closing <- FALSE
  nb$queries <- new.env(parent = emptyenv())
  nb$late_queries <- new.env(parent = emptyenv())
  nb$help_lookups <- new.env(parent = emptyenv())
  nb$next_query_id <- 0L
  class(nb) <- "ember_notebook"

  reset_sigint()
  register_session(nb)
  sync_active_libraries()
  maybe_start_cleanup()
  ready_worker_image(dir = nb$state$options$cache %||% cache_dir())
  maybe_start_heartbeat()
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

#' Whether the library heartbeat is running in this process.
library_heartbeat <- local({
  env <- new.env(parent = emptyenv())
  env$scheduled <- FALSE
  env
})

#' Touch every library an open session holds, so `ember-last-used`
#' means "in use", not only "a worker started on it": a notebook left
#' open for days in one Ember process keeps a fresh marker, and another
#' process's clean-up (`clean_up()`, which skips libraries used in the
#' last 30 days, #128) never takes it.
touch_active_libraries <- function() {
  for (p in active_libraries$paths) touch_library(p)
  invisible(NULL)
}

#' Start the heartbeat the first time a notebook opens: every
#' `ember.library_heartbeat` seconds (default an hour) it touches the
#' open sessions' libraries, and it stops once no session is open (the
#' next `session_start()` starts it again).
maybe_start_heartbeat <- function() {
  if (isTRUE(library_heartbeat$scheduled)) return(invisible(NULL))
  library_heartbeat$scheduled <- TRUE
  later::later(heartbeat_tick, getOption("ember.library_heartbeat", 3600))
  invisible(NULL)
}

heartbeat_tick <- function() {
  if (length(ls(open_sessions, all.names = TRUE)) == 0L) {
    library_heartbeat$scheduled <- FALSE
    return(invisible(NULL))
  }
  tryCatch(touch_active_libraries(), error = function(e) NULL)
  later::later(heartbeat_tick, getOption("ember.library_heartbeat", 3600))
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
  nb$poll_interval <- interval
  invisible(NULL)
}

#' Seconds until the next poll: fast while the shell is waiting on the
#' worker (connecting, starting, running, a pending cell or query, bytes
#' half-read, or anything sent or received in the last second); 250 ms while
#' an install or index job is running, so its progress and its end are read
#' promptly; otherwise 2 s. An idle worker sends nothing (it speaks only in
#' reply, or during a run), so the slow poll only notices a watched file that
#' changed, and a worker that died while idle on Windows or while a
#' `system()` child still holds its stdout pipe (otherwise the pipe wakes the
#' poll at once, `watch_worker_output()`, #209): each
#' poll costs about 1.7 ms of the server's time, so 4 a second cost 0.7% of
#' a core per open notebook (#46).
poll_interval <- function(nb, now = Sys.time()) {
  jobs_running <- length(ls(jobs, all.names = TRUE)) > 0
  if (is.null(nb$proc)) return(if (jobs_running) 0.25 else 2)
  st <- nb$state
  waiting <- is.null(nb$con) ||
    !identical(st$worker$status, "ready") ||
    !is.null(st$worker$running) ||
    length(st$pending) > 0 ||
    length(ls(nb$queries, all.names = TRUE)) > 0 ||
    nb$rx$n > 0 ||
    (!is.null(nb$last_io) && as.numeric(now - nb$last_io, units = "secs") < 1)
  if (waiting) 0.005 else if (jobs_running) 0.25 else 2
}

#' Bring a poll due later than `interval` forward to `interval`. Inside
#' `poll()` the poll reschedules itself on the way out, so it is left alone
#' there.
hurry_poll <- function(nb, interval) {
  if (!isTRUE(nb$in_poll) && !is.null(nb$poll_cancel) &&
      isTRUE(nb$poll_interval > interval)) {
    cancel_poll(nb)
    schedule_poll(nb, interval)
  }
  invisible(NULL)
}

#' Note worker traffic, and bring a slow poll forward so the reply is read
#' within one fast tick.
note_worker_io <- function(nb) {
  nb$last_io <- Sys.time()
  hurry_poll(nb, 0.005)
}

cancel_poll <- function(nb) {
  if (!is.null(nb$poll_cancel)) {
    try(nb$poll_cancel(), silent = TRUE)
    nb$poll_cancel <- NULL
  }
  invisible(NULL)
}

#' On macOS and Linux, wake the poll when the worker's stdout pipe is
#' readable: R or native code wrote something, or the worker ended and the
#' pipe closed. So a worker that dies while idle is noticed at once rather
#' than at the next 2 s poll (#209). An idle worker sends no frames (it
#' speaks only in reply, or during a run, when the poll is fast anyway), so
#' the socket needs no wake of its own. The slow poll stays: watched files
#' need it, and a process a cell started with `system()` inherits the pipe
#' and keeps it open after the worker has gone.
#'
#' Armed once per readable spell: the poll reads what is there and arms it
#' again on its way out, since a pipe at its end is always readable and
#' waiting on it again at once would spin. Not armed once the output is
#' complete, or on Windows, whose pipes can't be waited on this way (as
#' `watch_child()`, server.R). Returns whether it is armed, invisibly.
watch_worker_output <- function(nb) {
  proc <- nb$proc
  if (is.null(proc) || isTRUE(nb$closing) || .Platform$OS.type == "windows") return(invisible(FALSE))
  if (identical(nb$output_watch$proc, proc)) return(invisible(TRUE))
  cancel_output_watch(nb)
  fd <- tryCatch(processx::conn_get_fileno(proc$get_output_connection()), error = function(e) NULL)
  if (is.null(fd) || !isTRUE(tryCatch(proc$is_incomplete_output(), error = function(e) FALSE))) return(invisible(FALSE))
  cancel <- later::later_fd(function(ready) {
    nb$output_watch <- NULL
    if (identical(nb$proc, proc)) hurry_poll(nb, 0.005)
  }, readfds = fd)
  nb$output_watch <- list(proc = proc, cancel = cancel)
  invisible(TRUE)
}

cancel_output_watch <- function(nb) {
  if (!is.null(nb$output_watch)) {
    try(nb$output_watch$cancel(), silent = TRUE)
    nb$output_watch <- NULL
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
    if (e$type %in% c("wk_running", "wk_done", "install_done")) forget_finished_help(nb)
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
#' The file is formatted again only when something it is made from
#' (`file_inputs()`) differs from the last drain's. Most drains during Run
#' all change only results, and formatting a 2000-cell file costs about
#' 0.17 s (#44).
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
  inputs <- file_inputs(s)
  if (identical(inputs, nb$file_inputs)) return(invisible(NULL))
  nb$file_inputs <- inputs
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

#' What `notebook_file_of()` reads from a state. Equal inputs give the same
#' text, so `save_if_changed()` skips formatting the file when they are
#' identical to the last drain's: the previous text was then either written
#' already or failed to write.
file_inputs <- function(state) {
  list(state$cells, state$graph, state$file, state$files, state$computed_sources,
       state$footer_sources, state$problems, state$read_only)
}

#' What `watched_files()` reads from a state, for the same skip in
#' `after_dispatch()`.
watch_inputs <- function(state) {
  list(state$graph$analyses, state$computed_sources, state$footer_sources, results_data_read(state))
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
  # Gathering the watched paths walks every cell's analysis (about 24 ms at
  # 2000 cells), so it is skipped when nothing it reads changed (#44).
  inputs <- watch_inputs(nb$state)
  if (!identical(inputs, nb$watch_inputs)) {
    nb$watch_inputs <- inputs
    sync_watch(nb, watched_files(nb$state))
    sync_data_watch(nb, watched_data_files(nb$state))
  }
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
        end_reaper(nb)
        remove_worker_tempdir(nb)
        nb$rx <- list(chunks = list(), n = 0L)
        fail_pending_queries(nb)
      }
    },
    interrupt = {
      if (identical(nb$proc_gen, fx$gen) && !is.null(nb$proc)) {
        sent <- interrupt_worker(nb$proc)
        note_worker_io(nb)
        if (!sent && isTRUE(tryCatch(nb$proc$is_alive(), error = function(e) FALSE))) {
          enqueue(nb, wk_interrupt_failed(fx$gen, at = Sys.time()))
        }
      }
    },
    send = {
      if (identical(nb$proc_gen, fx$gen) && !is.null(nb$con)) {
        tryCatch(write_frame(nb$con, fx$msg), error = function(e) NULL)
        note_worker_io(nb)
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
      cancel_output_watch(nb)
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
      # A GitHub key at a moving ref (a branch, a tag, HEAD), or a
      # universe's latest build, is fetched afresh: the cache could hold an
      # older commit (`github_key()`, `universe_key()`).
      # A dated key as recent as today (#39) is read from the cache like
      # any other, since fetching it on every open costs seconds, but its
      # slot is marked provisional: Package Manager may still add to that
      # day's snapshot, so when a date preview asks for it (`fresh`) it is
      # fetched again. If that fetch fails (offline), the saved copy
      # stands in.
      provisional <- index_may_change(fx$key)
      moving <- is_moving_source_key(fx$key)
      cache <- nb$state$options$cache
      read_index <- function() {
        if (moving) fresh_index(fx$key, cache)
        else if (provisional) reload_index(fx$key, cache, url = fx$url)
        else cached_index(fx$key, cache, url = fx$url)
      }
      idx <- if (moving || isTRUE(fx$fresh) && provisional) NULL else tryCatch(cached_index(fx$key, cache, url = fx$url), error = function(e) NULL)
      if (!is.null(idx)) {
        enqueue(nb, ev_index_fetched(fx$key, idx, at = Sys.time(), provisional = provisional))
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
            idx2 <- if (identical(status, 0L) || provisional) tryCatch(read_index(), error = function(e) NULL)
            if (!is.null(idx2)) {
              ev_index_fetched(fx$key, idx2, at = Sys.time(), provisional = provisional)
            } else if (identical(status, 0L)) {
              ev_index_failed(fx$key, "index fetch produced no index", at = Sys.time())
            } else {
              msg <- fetch_error_message(output)
              ev_index_failed(fx$key, msg, at = Sys.time(),
                              unpublished = may_be_unpublished(fx$key) && grepl("has no index for that date (404)", msg, fixed = TRUE))
            }
          })
      }
    },
    fetch_bioc_config = {
      cache <- nb$state$options$cache
      hit <- tryCatch(cached_bioc_config(fx$url, cache), error = function(e) NULL)
      # A copy fetched before the date the core needs may lack a release
      # out by then: fetch again.
      if (!is.null(hit) && !is.na(fx$date) && fetched_day(hit) < as.Date(fx$date)) hit <- NULL
      if (!is.null(hit)) {
        enqueue(nb, ev_bioc_releases_fetched(hit$table, fetched_day(hit), at = Sys.time()))
      } else {
        job_start(bioc_config_job_key(fx$url, cache), bioc_config_fetch_command(fx$url, cache), nb,
          make_progress = function(line) NULL,
          make_done = function(status, output) {
            # A failed fetch falls back to the last list fetched, however
            # old: the core uses it only for dates up to the day it was
            # fetched (`releases_at()`), which it still speaks for.
            max_age <- if (identical(status, 0L)) bioc_config_max_age else Inf
            hit <- tryCatch(cached_bioc_config(fx$url, cache, max_age = max_age), error = function(e) NULL)
            if (!is.null(hit)) {
              ev_bioc_releases_fetched(hit$table, fetched_day(hit), at = Sys.time())
            } else {
              ev_bioc_releases_failed(sprintf(paste(
                "couldn't fetch Bioconductor's release list from %s,",
                "and there is no copy from an earlier fetch"), fx$url), at = Sys.time())
            }
          })
      }
    },
    fetch_cran_releases = {
      cache <- nb$state$options$cache
      hit <- tryCatch(cached_cran_releases(fx$url, cache), error = function(e) NULL)
      if (!is.null(hit)) {
        enqueue(nb, ev_cran_releases_fetched(hit$table, at = Sys.time()))
      } else {
        job_start(cran_releases_job_key(fx$url, cache), cran_releases_fetch_command(fx$url, cache), nb,
          make_progress = function(line) NULL,
          make_done = function(status, output) {
            # A failed fetch falls back to the last table fetched, however
            # old: it lacks only the releases since.
            max_age <- if (identical(status, 0L)) cran_releases_max_age else Inf
            hit <- tryCatch(cached_cran_releases(fx$url, cache, max_age = max_age), error = function(e) NULL)
            if (!is.null(hit)) {
              ev_cran_releases_fetched(hit$table, at = Sys.time())
            } else {
              ev_cran_releases_failed(sprintf("couldn't fetch CRAN's release dates from %s", fx$url),
                                      at = Sys.time())
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
      cmd <- installer_command(fx$lock, fx$repos, fx$path, nb$state$options$cache,
                               github = fx$github %||% "https://api.github.com",
                               ask_above = fx$ask_above %||% Inf)
      # Keyed by `path`, not `key`: `key` is a hash of the lock text alone
      # (library_for(), lock.R), the same for two sessions with the same
      # lock but different library paths (different caches, or -- in tests
      # -- the same process pointed at two cache directories). Two such
      # installs are not the same job and must not share one subprocess or
      # one `job$subs` list.
      job_start(fx$path, cmd, nb,
        make_progress = function(line) {
          no_binary <- parse_no_binary_notice(line)
          if (!is.null(no_binary)) return(ev_install_no_binary(fx$token, no_binary, at = Sys.time()))
          item <- parse_install_progress_line(line)
          if (is.null(item)) NULL else ev_install_progress(fx$token, item, at = Sys.time())
        },
        make_done = function(status, output) {
          manifest <- tryCatch(read_library_manifest(fx$path), error = function(e) NULL)
          lines <- strsplit(output, "\n", fixed = TRUE)[[1]]
          failed <- !identical(status, 0L)
          # Status 3: stopped before a large download, to ask (#37).
          download <- if (identical(status, 3L)) download_lines(lines) else NULL
          if (!is.null(download)) {
            return(ev_install_done(fx$token, fx$key, NULL, message = NULL, log = character(),
                                   download = download, at = Sys.time()))
          }
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
    cancel_fetch_bioc_config = {
      job_leave(bioc_config_job_key(fx$url, nb$state$options$cache), nb)
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

#' A free TCP port to listen on, as a server socket, that the worker's
#' connection to 127.0.0.1 will actually reach (`loopback_reaches()`).
pick_listen_socket <- function(tries = 50) {
  for (i in seq_len(tries)) {
    port <- random_port()
    s <- tryCatch(serverSocket(port), error = function(e) NULL)
    if (is.null(s)) next
    if (loopback_reaches(s, port)) return(list(socket = s, port = port))
    tryCatch(close(s), error = function(e) NULL)
  }
  stop("ember: could not find a free port after ", tries, " tries")
}

#' Does a connection to 127.0.0.1:`port` reach the listening socket `s`?
#' `serverSocket()` has no host argument and binds 0.0.0.0. On macOS that
#' bind succeeds even while another process listens on 127.0.0.1 at the
#' same port, and a connection to 127.0.0.1 then goes to the other process,
#' the more specific bind. The worker connects to 127.0.0.1 and sends the
#' secret first thing, so such a port must not be used. This connects once,
#' sends a random nonce, and checks that the first connection `s` accepts
#' carries it: any other connection (the process holding 127.0.0.1 could
#' learn the port from the probe and connect back by another address) fails
#' the check, and the caller tries another port.
#'
#' Waits with zero-timeout `socketSelect()` calls, not a positive timeout,
#' which returns `FALSE` at once in a process where `later` has run
#' (engine.md, Measured). On loopback the connection and the nonce are
#' queued before the write returns, so the first check normally succeeds.
loopback_reaches <- function(s, port, wait = 1) {
  probe <- tryCatch(suppressWarnings(socketConnection(
    "127.0.0.1", port, blocking = TRUE, open = "r+b", timeout = 2)),
    error = function(e) NULL)
  if (is.null(probe)) return(FALSE)
  on.exit(tryCatch(close(probe), error = function(e) NULL), add = TRUE)
  nonce <- os_random_bytes(16)
  sent <- tryCatch({ writeBin(nonce, probe); flush(probe); TRUE }, error = function(e) FALSE)
  if (!sent) return(FALSE)
  deadline <- Sys.time() + wait
  ready <- function(con) isTRUE(tryCatch(socketSelect(list(con), timeout = 0), error = function(e) FALSE))
  repeat {
    if (ready(s)) break
    if (Sys.time() > deadline) return(FALSE)
    Sys.sleep(0.005)
  }
  got <- tryCatch(socketAccept(s, blocking = FALSE, open = "a+b"), error = function(e) NULL)
  if (is.null(got)) return(FALSE)
  on.exit(tryCatch(close(got), error = function(e) NULL), add = TRUE)
  heard <- raw(0)
  repeat {
    if (ready(got)) {
      chunk <- tryCatch(readBin(got, "raw", length(nonce) - length(heard)), error = function(e) raw(0))
      heard <- c(heard, chunk)
      if (length(heard) >= length(nonce)) break
    }
    if (Sys.time() > deadline) return(FALSE)
    Sys.sleep(0.005)
  }
  identical(heard, nonce)
}

# ---- The worker's compiled image (#229) ---------------------------------------
# R's JIT compiles a closure the second time it is called. A worker that
# sys.source()s worker.R runs its own functions uncompiled, so its second
# run pays for compiling run_cell() and everything it calls: about 0.4 s
# on Linux, and over 5 s on a slow Windows runner. compiler::cmpfile()
# compiles the whole file once (about 1.5 s) into the cache, and a worker
# that loadcmp()s it runs compiled code from its first cell. The compile
# runs in an Rscript of its own, so nothing waits for it: a worker started
# before it finishes sys.source()s worker.R, as before.

#' Where the image of `src` lives: one per worker.R content and R version
#' (bytecode is R's own format), under `cache_dir()`/worker. The content
#' hash, not Ember's version: a development build keeps its version
#' across changes to worker.R.
worker_image_path <- function(src = system.file("worker.R", package = "ember"), dir = cache_dir()) {
  key <- paste0("R-", R.version$major, ".", R.version$minor, "-", unname(tools::md5sum(src)))
  file.path(dir, "worker", paste0(key, ".Rc"))
}

#' The compile this process started, if any: at most one per image path.
worker_image_build <- local({
  env <- new.env(parent = emptyenv())
  env$path <- NULL
  env$proc <- NULL
  env
})

#' The image's path when it exists. Otherwise start compiling it, once per
#' process, and return `NULL`. The compile writes a private name and
#' renames it into place, so a worker never loads half a file and two
#' processes compiling at once both end with the same image (library.R's
#' concurrency rule). It then deletes other images and leftovers more than
#' a day old: images of earlier worker.R versions, and a compile that was
#' killed with its server.
ready_worker_image <- function(src = system.file("worker.R", package = "ember"), dir = cache_dir()) {
  if (!nzchar(src) || !file.exists(src)) return(NULL)
  path <- tryCatch(worker_image_path(src, dir), error = function(e) NULL)
  if (is.null(path)) return(NULL)
  if (file.exists(path)) return(path)
  if (identical(worker_image_build$path, path)) return(NULL)
  worker_image_build$path <- path
  code <- paste(
    "args <- commandArgs(TRUE)",
    "dir.create(dirname(args[2]), recursive = TRUE, showWarnings = FALSE)",
    "tmp <- tempfile('build-', dirname(args[2]), '.tmp')",
    "compiler::cmpfile(args[1], tmp, verbose = FALSE)",
    "if (!file.rename(tmp, args[2])) unlink(tmp)",
    "old <- setdiff(list.files(dirname(args[2]), full.names = TRUE), args[2])",
    "unlink(old[difftime(Sys.time(), file.info(old)$mtime, units = 'days') > 1])",
    sep = "; ")
  cmd <- rscript_command(file.path(R.home("bin"), "Rscript"), code, args = c(src, path))
  worker_image_build$proc <- tryCatch(
    processx::process$new(cmd$command, cmd$args, env = cmd$env),
    error = function(e) NULL)
  NULL
}

#' How Ember starts an `Rscript` of its own that runs `code`:
#' `list(command, args, env)`, for processx. The code goes in
#' `EMBER_RUN_CODE`, and Rscript runs the script the package ships for it
#' (inst/run-code.R), not `Rscript -e code`. On Windows `-e` writes the code
#' to an `Rscript<hex>` file in the temp folder and removes it only when
#' Rscript returns, so each child Ember ends (a stopped server, a cancelled
#' job) left one there (#512). `args` follow the script, for
#' `commandArgs(TRUE)`; `env` is processx's, `"current"` and the rest. Unlike
#' `-e`, a visible value the code returns isn't printed: every caller's
#' code prints what it means to, and returns `invisible(NULL)`.
rscript_command <- function(rscript, code, env = "current", args = character()) {
  list(command = rscript,
       args = c("--vanilla", system.file("run-code.R", package = "ember"), args),
       env = c(env, EMBER_RUN_CODE = code))
}

#' The line a worker boots with (`send_worker_boot()`): load the compiled image named by
#' EMBER_WORKER_IMAGE into a private environment whose parent is
#' baseenv(), or, with no image or one that fails to load, source
#' worker.R there (worker.R's header), then call main().
worker_boot <- function() {
  paste0(
    "local({e <- new.env(parent = baseenv()); img <- Sys.getenv('EMBER_WORKER_IMAGE'); ",
    "if (!nzchar(img) || inherits(tryCatch(compiler::loadcmp(img, e), error = identity), 'error')) ",
    "sys.source(Sys.getenv('EMBER_WORKER'), e); e$main()})")
}

#' The command a worker starts with (#186): an interactive R, so
#' `interactive()` is `TRUE` and a package's prompt asks, as in an R
#' console (worker.R's "Prompts"). It reads its boot line from stdin
#' (`send_worker_boot()`): R reading its code from a file, as `Rscript -e`
#' does, is never interactive, whatever the flags. On Windows Rterm's
#' `--ess` asserts interactive use, as `--interactive` does elsewhere.
#' `--no-echo` keeps R's prompt off the worker's output.
worker_command <- function(port) {
  args <- c("--no-echo", "--vanilla", "--args", as.character(port))
  if (.Platform$OS.type == "windows") {
    list(command = file.path(R.home("bin"), "Rterm.exe"), args = c("--ess", args))
  } else {
    list(command = file.path(R.home("bin"), "R"), args = c("--interactive", args))
  }
}

#' Write the boot line to a worker just started with `stdin = "|"`, then
#' close its stdin, so R's own console reads in a cell (`scan("")`,
#' `readLines(stdin())`) get no input, as under `Rscript`, and the worker
#' ends when its loop does.
send_worker_boot <- function(proc) {
  rest <- charToRaw(paste0(worker_boot(), "\n"))
  while (length(rest)) rest <- proc$write_input(rest)
  close(proc$get_input_connection())
  invisible(NULL)
}

#' Spawn a worker. Never waits for it: the connection is accepted by the
#' poll once the listening socket is readable.
start_worker_process <- function(nb, fx) {
  # A fresh, checked port for every worker: another process may have
  # taken 127.0.0.1 at the old port since it was checked
  # (`loopback_reaches()`), and a connection a dead worker left unaccepted
  # goes with the old socket. A process that binds 127.0.0.1 at the new
  # port between the check and the worker's connect still wins; that
  # window is the worker's startup, and is accepted (Ember #25).
  if (!is.null(nb$listen)) tryCatch(close(nb$listen), error = function(e) NULL)
  picked <- pick_listen_socket()
  nb$listen <- picked$socket
  nb$port <- picked$port
  lib <- fx$library
  if (is.null(lib)) lib <- file.path(tempdir(), "ember-empty-lib")
  if (!dir.exists(lib)) dir.create(lib, recursive = TRUE, showWarnings = FALSE)
  tryCatch(touch_library(lib), error = function(e) NULL)

  cmd <- worker_command(nb$port)
  env <- c("current",
           R_LIBS_USER = lib, R_LIBS = "", R_LIBS_SITE = "",
           EMBER_WORKER = system.file("worker.R", package = "ember"),
           EMBER_DLL = ember_dll_path(),
           EMBER_WORKER_IMAGE = ready_worker_image(dir = nb$state$options$cache %||% cache_dir()) %||% "",
           EMBER_SECRET = nb$secret)
  wd <- fx$wd
  if (is.null(wd) || !nzchar(wd)) wd <- getwd()

  # `supervise = TRUE`: processx's supervisor sends the worker SIGTERM once
  # the server has gone, however it went, so a worker busy in a long cell
  # doesn't outlive a killed server (#147; the jobs' `job_process()` does
  # the same, #141). Not under `job_process()`'s `sh`: the server
  # interrupts a cell with SIGINT to this process (`interrupt`), which must
  # reach the worker itself. Processes a cell started go with the worker's
  # process group, through `start_reaper()` (#150).
  proc <- processx::process$new(
    cmd$command, cmd$args,
    env = env, wd = wd, stdin = "|", stdout = "|", stderr = "2>&1", cleanup_tree = TRUE,
    supervise = TRUE)
  send_worker_boot(proc)
  end_reaper(nb)
  nb$reaper <- start_reaper(proc)

  if (!is.null(nb$con)) tryCatch(close(nb$con), error = function(e) NULL)
  nb$proc <- proc
  nb$proc_gen <- fx$gen
  watch_worker_output(nb)
  nb$out_tail <- ""
  nb$con <- NULL
  nb$rx <- list(chunks = list(), n = 0L)
  note_worker_io(nb)
  # A new generation's memory starts from nothing known: comparing its first
  # sample against the old worker's last-reported RSS would compare two
  # different processes' numbers against each other, and could skip
  # reporting the new worker's actual first value.
  nb$last_mem_check <- NULL
  nb$worker_rss_reported <- NULL
  enqueue(nb, wk_started(fx$gen, proc$get_pid(), at = Sys.time()))
  invisible(NULL)
}

#' On Unix, a small `sh` (the reaper) outside the worker's process group
#' that ends the group once the server has gone (#150). The supervisor (`supervise =
#' TRUE` above) ends only the worker's own R process, and what a cell
#' started with `system()`, a pipe or a fork (`parallel::mclapply()`) is in
#' the worker's group and would carry on. The reaper waits on a pipe from
#' the server: its read returns only when the server's end closes, which
#' happens however the server ends, SIGKILL included. Then it sends the
#' group SIGTERM, and SIGKILL 5 s later, as the supervisor does. This is
#' what stopping a worker already does while the server lives (`kill()`
#' ends the group). A process a cell put in a session of its own (processx,
#' callr) is outside the group and stays, as it does when the notebook
#' restarts. `NULL` on Windows, or if the reaper can't start.
start_reaper <- function(proc) {
  if (.Platform$OS.type != "unix") return(NULL)
  tryCatch(processx::process$new("/bin/sh", c("-c", WORKER_REAPER_SH, as.character(proc$get_pid())),
                                 stdin = "|", stdout = NULL, stderr = NULL),
           error = function(e) NULL)
}

#' The `sh -c` script `start_reaper()` runs, with the worker's pid (its
#' process group, since processx made it a session leader) as `$0`.
WORKER_REAPER_SH <- 'read _; kill -TERM -"$0" 2>/dev/null; sleep 5; kill -KILL -"$0" 2>/dev/null'

#' Stop the reaper of a worker that has ended or is being replaced, so it
#' can never signal a process group whose number has been reused.
end_reaper <- function(nb) {
  if (!is.null(nb$reaper)) tryCatch(nb$reaper$kill(), error = function(e) NULL)
  nb$reaper <- NULL
  invisible(NULL)
}

#' The worker's `tempdir()` from its hello, kept to remove once the worker
#' has stopped (#166): a killed R never runs its exit cleanup, so its temp
#' folder (an Rcpp build, plot files) would stay. Only a folder R itself
#' would make (`Rtmp` then letters and digits) that exists and isn't this
#' process's own is kept; anything else is `NULL`.
worker_tempdir <- function(path) {
  if (!is.character(path) || length(path) != 1 || is.na(path) || !nzchar(path)) return(NULL)
  if (!grepl("^Rtmp[A-Za-z0-9]+$", basename(path)) || !dir.exists(path)) return(NULL)
  norm <- function(p) normalizePath(p, winslash = "/", mustWork = FALSE)
  if (identical(norm(path), norm(tempdir()))) return(NULL)
  path
}

#' Remove the stopped worker's temp folder, if its hello named one. Called
#' wherever the shell lets go of a worker process: stopped, failed or
#' exited on its own (an R that quits cleans up its own folder, so then
#' there is nothing left to remove).
remove_worker_tempdir <- function(nb) {
  if (!is.null(nb$worker_tmp)) tryCatch(unlink(nb$worker_tmp, recursive = TRUE, force = TRUE), error = function(e) NULL)
  nb$worker_tmp <- NULL
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

#' Ask the worker a question (`complete`, `help` or `signature`, or a
#' `render` at a one-off size for `render_png()`) outside `step()` and the
#' event log: these never change the notebook, so they don't belong in the
#' engine's history. `callback(reply)` runs once, with the worker's reply,
#' or with `NULL` at once if the worker isn't idle (with `busy_ok`, if it
#' isn't ready or busy: a `render` may arrive mid-run, and the worker
#' answers it once the run ends, inst/worker.R), or
#' with `NULL` after `timeout` seconds, or when the worker exits
#' (`fail_pending_queries()`). A reply that arrives after the timeout goes
#' to `late(reply)` when one is given, kept in `nb$late_queries` (which,
#' unlike `nb$queries`, doesn't keep the shell polling fast); otherwise, or
#' after the worker that was asked is gone, it is dropped. `late` is called
#' with `NULL` if the worker exits first. Whether the question was sent
#' (`FALSE` when the callback already ran with `NULL`).
worker_query <- function(nb, msg, callback, timeout = 0.8, busy_ok = FALSE, late = NULL) {
  st <- nb$state
  can_ask <- if (busy_ok) {
    isTRUE(st$allowed) && st$worker$status %in% c("ready", "busy") && !is.null(nb$con)
  } else {
    worker_is_idle(nb)
  }
  if (!can_ask) {
    callback(NULL)
    return(invisible(FALSE))
  }
  id <- nb$next_query_id <- nb$next_query_id + 1L
  key <- as.character(id)
  msg$id <- id
  assign(key, callback, envir = nb$queries)
  ok <- tryCatch({ write_frame(nb$con, msg); TRUE }, error = function(e) FALSE)
  if (ok) note_worker_io(nb)
  if (!ok) {
    rm(list = key, envir = nb$queries)
    callback(NULL)
    return(invisible(FALSE))
  }
  later::later(function() {
    if (exists(key, envir = nb$queries, inherits = FALSE)) {
      cb <- get(key, envir = nb$queries, inherits = FALSE)
      rm(list = key, envir = nb$queries)
      if (!is.null(late)) assign(key, late, envir = nb$late_queries)
      cb(NULL)
    }
  }, timeout)
  invisible(TRUE)
}

#' A `completions`/`help_page`/`signature` reply, or a `rendered` one with
#' an `id`: find its callback by
#' `msg$id` and call it, or drop the message (its query already timed out).
answer_query <- function(nb, msg) {
  key <- as.character(msg$id)
  for (waiting in list(nb$queries, nb$late_queries)) {
    if (exists(key, envir = waiting, inherits = FALSE)) {
      cb <- get(key, envir = waiting, inherits = FALSE)
      rm(list = key, envir = waiting)
      cb(msg)
      break
    }
  }
  invisible(NULL)
}

#' Drop the help pages kept from lookups that finished after the docs
#' timeout (`nb$help_lookups`, server.R's `docs`) once a run starts or ends
#' or an install finishes: what the session can see may have changed since,
#' and a kept "no help page" must not show hours later for a package
#' installed in between. Lookups still running stay; they answer the next
#' ask with what they find.
forget_finished_help <- function(nb) {
  lookups <- nb$help_lookups
  if (!is.environment(lookups)) return(invisible(NULL))
  for (key in ls(lookups, all.names = TRUE)) {
    if (!is.null(get(key, envir = lookups, inherits = FALSE)$reply)) rm(list = key, envir = lookups)
  }
  invisible(NULL)
}

#' Every pending `worker_query()` callback, and every `late` one waiting on
#' a reply that timed out, called with `NULL`: the worker that was asked is
#' gone (exited, or killed for a protocol error) and will never answer. The
#' help lookups it was running or had finished late (`nb$help_lookups`,
#' server.R's `docs`) go with it.
fail_pending_queries <- function(nb) {
  for (waiting in list(nb$queries, nb$late_queries)) {
    for (key in ls(waiting, all.names = TRUE)) {
      cb <- get(key, envir = waiting, inherits = FALSE)
      rm(list = key, envir = waiting)
      cb(NULL)
    }
  }
  rm(list = ls(nb$help_lookups, all.names = TRUE), envir = nb$help_lookups)
  invisible(NULL)
}

#' The poll, at the interval `poll_interval()` picks: 5 ms while the shell
#' waits on the worker, 250 ms while a job runs, 2 s otherwise. File
#' watching is checked at most every 500 ms regardless of the poll
#' interval, so a busy worker doesn't make it noisier.
poll <- function(nb) {
  nb$in_poll <- TRUE
  on.exit(nb$in_poll <- FALSE)
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
      # No-delay: see write_frame().
      nb$con <- tryCatch(socketAccept(nb$listen, blocking = FALSE, open = "a+b", options = "no-delay"),
                         error = function(e) NULL)
    }
  }

  if (!is.null(nb$con)) {
    repeat {
      chunk <- tryCatch(readBin(nb$con, "raw", 65536), error = function(e) raw(0))
      if (length(chunk) == 0) break
      nb$last_io <- Sys.time()
      nb$rx$chunks[[length(nb$rx$chunks) + 1]] <- chunk
      nb$rx$n <- nb$rx$n + length(chunk)
    }
    framed <- take_frames(nb$rx)
    nb$rx <- framed$rx
    if (length(framed$messages) > 0) {
      broke <- FALSE
      for (msg in framed$messages) {
        if (!is.null(msg$type) && (msg$type %in% c("completions", "help_page", "signature") ||
                                   (identical(msg$type, "rendered") && !is.null(msg$id)))) {
          answer_query(nb, msg)
          next
        }
        ev <- worker_event(msg, nb$proc_gen, Sys.time(), secret = nb$secret)
        if (identical(ev$type, "wk_hello")) nb$worker_tmp <- worker_tempdir(msg$tempdir)
        if (identical(ev$type, "wk_done")) check_data_files(nb, enqueue)
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
          end_reaper(nb)
          remove_worker_tempdir(nb)
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
    end_reaper(nb)
    remove_worker_tempdir(nb)
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
    check_data_files(nb, dispatch, skip = running_writes(nb$state))
  }

  watch_worker_output(nb)
  schedule_poll(nb, poll_interval(nb))
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
#' worker are small (code, ids); a blocking write is fine. Both ends set
#' TCP no-delay: otherwise a frame sent while the last one is unanswered
#' (a split length and payload, or the worker's `running` then `done`)
#' waits for the peer's delayed ACK, about 40 ms each time (#316). One
#' write per frame also saves a packet.
write_frame <- function(con, msg) {
  payload <- serialize(msg, NULL)
  writeBin(c(writeBin(length(payload), raw(), endian = "big"), payload), con)
  flush(con)
  invisible(NULL)
}

#' Compare the watched data files with what the shell last saw (#276) and
#' send `data_changed` for those whose contents changed, through `send`
#' (`dispatch` from the poll, `enqueue` ahead of a run's result). Checked
#' before a run's result is queued, too, so that a cell that wrote one of
#' them has its readers queued or stale before the notebook goes idle: the
#' poll alone would find the change only after `run_cells(wait = TRUE)`
#' had returned with the readers' old results.
#'
#' `skip` is the files the running cell writes (`running_writes()`; `NA`
#' for all of them), which the poll leaves to the check at the run's end:
#' a look in the middle of the write can find the file cut short (#405).
#' A size that differs counts even when the modified time doesn't, since
#' a write can finish within the clock tick of such a look.
check_data_files <- function(nb, send, skip = character()) {
  # Only a change of contents counts, so a file rewritten with the same
  # bytes reruns nothing. A new size is a change without reading the file;
  # the same size is told apart by its hash, which a file has only after
  # its first such rewrite (hashing every data file when the notebook
  # opens would read them all). The record keeps the last hash with the
  # size it was taken at (`hash_size`), so a look that found the file cut
  # short, by a writer the skip can't see, doesn't cost the next same-bytes
  # rewrite a rerun.
  skip_full <- if (anyNA(skip)) NA_character_ else canonical_path(vapply(skip, function(s) resolve_source_path(nb, s), character(1)))
  data_changed <- list()
  keys <- names(nb$data_watch)
  listings <- keys[is_listing_key(keys)]
  if (length(listings)) data_changed <- check_data_listings(nb, listings)
  paths <- setdiff(keys, listings)
  if (length(paths) == 0) {
    if (length(data_changed) > 0) send(nb, ev_data_changed(data_changed, at = Sys.time()))
    return(invisible(NULL))
  }
  fulls <- vapply(paths, function(p) resolve_source_path(nb, p), character(1), USE.NAMES = FALSE)
  # One file.info() for all of them: a run that reads a folder of files
  # has the shell watch thousands, every half second.
  infos <- tryCatch(file.info(fulls, extra_cols = FALSE), error = function(e) NULL)
  for (k in seq_along(paths)) {
    p <- paths[[k]]
    full <- fulls[[k]]
    if (anyNA(skip_full) || (length(skip_full) && canonical_path(full) %in% skip_full)) next
    info <- if (is.null(infos)) data_file_info(full) else list(mtime = infos$mtime[[k]], size = infos$size[[k]])
    w <- nb$data_watch[[p]]
    if (!isTRUE(identical(info$mtime, w$mtime)) || !isTRUE(identical(info$size, w$size))) {
      same_size <- isTRUE(identical(info$size, w$size)) && !is.na(info$size)
      hashed <- !is.na(info$size) && isTRUE(identical(info$size, w$hash_size))
      hash <- if (same_size || hashed) data_file_hash(full) else NA_character_
      kept <- !is.na(hash)
      nb$data_watch[[p]] <- list(mtime = info$mtime, size = info$size, hash = if (kept) hash else w$hash,
                                 hash_size = if (kept) info$size else w$hash_size)
      if (!same_size || is.na(hash) || !identical(hash, w$hash)) {
        data_changed[[p]] <- data_signature(info)
      }
    }
  }
  if (length(data_changed) > 0) send(nb, ev_data_changed(data_changed, at = Sys.time()))
  invisible(NULL)
}

#' A path with its folder resolved (`d.txt` and `./d.txt` alike), so two
#' spellings of one data file compare equal. The file itself may not exist.
canonical_path <- function(full) {
  if (length(full) == 0) return(character())
  file.path(normalizePath(dirname(full), winslash = "/", mustWork = FALSE), basename(full))
}

#' The data files the running cell writes by a literal path, from its
#' analysis's `data_touch`; `NA` when it writes to a computed path, which
#' may be any of them. `character()` when nothing runs.
running_writes <- function(state) {
  id <- state$worker$running$cell
  if (is.null(id)) return(character())
  touch <- state$graph$analyses[[id]]$data_touch
  if (is.null(touch)) return(character())
  written <- touch$path[!touch$read]
  if (anyNA(written)) NA_character_ else unique(written)
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
    running  = c("token"),
    console  = c("token", "item"),
    source   = c("token", "path", "text"),
    input    = c("token", "id", "prompt"),
    input_closed = c("token", "id"),
    done     = c("token", "report"),
    rendered = c("cell", "token"),
    input_set = c("cell", "name", "ok"),
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
    running  = wk_running(gen, msg$token, at),
    console  = wk_console(gen, msg$token, msg$item, at),
    source   = wk_source(gen, msg$token, msg$path, msg$text, at),
    input    = wk_input(gen, msg$token, msg$id, msg$prompt, msg$choices, at),
    input_closed = wk_input_closed(gen, msg$token, msg$id, at),
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
    },
    input_set = wk_input_set(gen, msg$cell, msg$name, isTRUE(msg$ok), msg$value,
                             msg$error, msg$globals, at)
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

#' Interrupt a worker's running cell. `TRUE` if the interrupt was
#' delivered, as far as this process can tell. On Unix that's SIGINT to the
#' worker's own process. On Windows it's the worker's interrupt event
#' (src/interrupt.c, #48), not processx's `interrupt()`: that one needs a
#' console the worker may not have, and says it sent an interrupt it lost.
interrupt_worker <- function(proc) {
  if (.Platform$OS.type == "windows") {
    return(isTRUE(tryCatch(.Call(C_interrupt_send, proc$get_pid()), error = function(e) FALSE)))
  }
  isTRUE(tryCatch(proc$interrupt(), error = function(e) FALSE))
}

#' The path of this package's DLL, which a worker on Windows loads for its
#' interrupt event (worker.R's `listen_for_interrupts()`). The worker doesn't
#' load the package itself: only this DLL, by path.
ember_dll_path <- function() {
  dll <- getLoadedDLLs()[["ember"]]
  if (is.null(dll)) "" else dll[["path"]]
}

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

#' The same for data files (#276), keeping each one's modified time and
#' size; the poll adds a hash once a rewrite keeps the size. A folder
#' listing's key (#514) keeps what `data_listing_watch()` takes.
sync_data_watch <- function(nb, paths) {
  old <- names(nb$data_watch)
  for (p in setdiff(paths, old)) {
    if (is_listing_key(p)) {
      w <- data_listing_watch(p)
      # The version the run ended with: a change since it ended counts,
      # found by the next poll, which lists again while the watch is new.
      seen <- listing_seen(nb$state, p)
      if (!is.null(seen)) w$sig <- seen
      nb$data_watch[[p]] <- w
      next
    }
    info <- data_file_info(resolve_source_path(nb, p))
    nb$data_watch[[p]] <- list(mtime = info$mtime, size = info$size, hash = NA_character_)
  }
  for (p in setdiff(old, paths)) {
    nb$data_watch[[p]] <- NULL
  }
  invisible(NULL)
}

#' A data file's modified time and size, both `NA` when it is missing.
data_file_info <- function(full) {
  tryCatch(as.list(file.info(full)[, c("mtime", "size")]),
           error = function(e) list(mtime = NA, size = NA))
}

#' What step.R compares to tell whether a reader saw a data file's current
#' version (#276): its modified time and size as text, or `"missing"`.
data_signature <- function(info) {
  # inst/worker.R's data_signature() must write the same text.
  if (is.na(info$mtime)) "missing" else sprintf("%.6f %.0f", as.numeric(info$mtime), as.numeric(info$size))
}

#' Whether data-watch key `p` is a folder listing's (#514, #595), made by
#' one of inst/worker.R's listing hooks, rather than a file's path.
is_listing_key <- function(p) grepl("^(list\\.files|Sys\\.glob|list\\.dirs|dir_ls)\n", as.character(p))

#' What a listing's key lists now, as text a watcher compares: the number
#' of names and their MD5, sorted in C order, or "missing" for a folder
#' that isn't there. inst/worker.R's copy must be the same, as must
#' `data_listing_names()`'s (a test checks).
data_listing_signature <- function(key) {
  names <- data_listing_names(key)
  if (is.null(names)) return("missing")
  names <- sort(enc2utf8(names), method = "radix")
  bytes <- charToRaw(paste(names, collapse = "\n"))
  md5 <- if (getRversion() >= "4.5.0") tools::md5sum(bytes = bytes) else {
    tmp <- tempfile()
    on.exit(unlink(tmp))
    writeBin(bytes, tmp)
    tools::md5sum(tmp)
  }
  paste(length(names), unname(md5))
}

#' The names a listing's key lists now, or `NULL` when its folder isn't
#' there, by the listing's kind, its key's first line (#514, #595):
#' `list.files()` (and `dir()`), `Sys.glob()`, `list.dirs()` and
#' `fs::dir_ls()`. `dir_ls()` is listed with `list.files()` and filtered
#' as fs filters it, so the engine needs no fs; its glob and regexp match
#' the paths it returns, which start with the path as the cell wrote it.
data_listing_names <- function(key) {
  f <- strsplit(key, "\n", fixed = TRUE)[[1]]
  flags <- function(i) strsplit(f[[i]], " ", fixed = TRUE)[[1]] == "1"
  switch(f[[1]],
    list.files = {
      if (!dir.exists(f[[2]])) return(NULL)
      x <- flags(3)
      pattern <- paste(f[-(1:3)], collapse = "\n")
      args <- list(f[[2]], pattern = if (nzchar(pattern)) pattern, all.files = x[[1]], recursive = x[[2]],
                   ignore.case = x[[3]], include.dirs = x[[4]], no.. = x[[5]])
      if ("fixed" %in% names(formals(list.files))) args$fixed <- x[[6]]
      tryCatch(do.call(list.files, args), error = function(e) NULL)
    },
    Sys.glob = tryCatch(Sys.glob(paste(f[-(1:2)], collapse = "\n"), dirmark = f[[2]] == "1"), error = function(e) NULL),
    list.dirs = {
      if (!dir.exists(f[[2]])) return(NULL)
      x <- flags(3)
      tryCatch(list.dirs(f[[2]], full.names = x[[1]], recursive = x[[2]]), error = function(e) NULL)
    },
    dir_ls = {
      # The folder, the path as written, then: all, recurse (-1 for any
      # depth), invert, ignore.case, perl, fixed; the type mask; the glob; the
      # regexp (last, as it may hold a newline).
      if (!dir.exists(f[[2]])) return(NULL)
      shown <- f[[3]]
      x <- strsplit(f[[4]], " ", fixed = TRUE)[[1]]
      all <- x[[1]] == "1"
      depth <- as.integer(x[[2]])
      lgl <- x[3:6] == "1"
      types <- as.integer(f[[5]])
      glob <- f[[6]]
      regexp <- paste(f[-(1:6)], collapse = "\n")
      # fs walks the tree itself: hidden names only with `all`, and it
      # doesn't descend into a symlinked folder, where list.files() does.
      walk <- function(rel, depth) {
        names <- list.files(if (nzchar(rel)) file.path(f[[2]], rel) else f[[2]], all.files = all, no.. = TRUE)
        if (nzchar(rel)) names <- file.path(rel, names)
        if (depth == 0) return(names)
        full <- file.path(f[[2]], names)
        down <- names[dir.exists(full) & !nzchar(Sys.readlink(full))]
        c(names, unlist(lapply(down, walk, depth = depth - 1)))
      }
      rel <- tryCatch(walk("", depth), error = function(e) NULL)
      if (is.null(rel)) return(NULL)
      # `types` is fs's own mask: 2 files, 4 folders, 8 links, -1 any. A
      # type this doesn't tell apart (a FIFO, a socket, "unknown") keeps
      # every name, so the listing never misses a change fs would see.
      if (types != -1 && bitwAnd(types, bitwNot(14L)) == 0) {
        full <- file.path(f[[2]], rel)
        dir <- dir.exists(full)
        link <- nzchar(Sys.readlink(full))
        keep <- (bitwAnd(types, 2L) > 0 & !dir & !link) | (bitwAnd(types, 4L) > 0 & dir & !link) | (bitwAnd(types, 8L) > 0 & link)
        rel <- rel[keep]
      }
      shown <- sub("(.)/+$", "\\1", shown)
      paths <- if (shown == ".") rel else if (shown == "/") paste0("/", rel) else paste0(shown, "/", rel)
      if (nzchar(glob)) regexp <- utils::glob2rx(glob)
      if (nzchar(regexp)) paths <- suppressWarnings(grep(regexp, paths, ignore.case = lgl[[2]], perl = lgl[[3]], fixed = lgl[[4]],
                                                         value = TRUE, invert = lgl[[1]]))
      paths
    },
    NULL)
}

#' The folders listing `key` looks in, whose modified times move when
#' what it lists may have changed: its folder, and the ones under it it
#' descends into. For `Sys.glob()`, the folder before the pattern's first
#' wildcard and each folder part matches (`data/*/x.csv` looks in `data`
#' and each of its folders). A folder that isn't there is kept: its time
#' appears when it does.
data_listing_dirs <- function(key) {
  f <- strsplit(key, "\n", fixed = TRUE)[[1]]
  under <- function(path, depth = -1L) {
    if (depth == 0 || !dir.exists(path)) return(path)
    sub <- list.dirs(path, full.names = FALSE)
    sub <- sub[nzchar(sub)]
    if (depth > 0) sub <- sub[lengths(regmatches(sub, gregexpr("/", sub, fixed = TRUE))) < depth]
    unique(c(path, file.path(path, sub)))
  }
  switch(f[[1]],
    list.files = under(f[[2]], if (strsplit(f[[3]], " ", fixed = TRUE)[[1]][[2]] == "1") -1L else 0L),
    list.dirs = under(f[[2]], if (strsplit(f[[3]], " ", fixed = TRUE)[[1]][[2]] == "1") -1L else 0L),
    dir_ls = under(f[[2]], as.integer(strsplit(f[[4]], " ", fixed = TRUE)[[1]][[2]])),
    Sys.glob = {
      pattern <- paste(f[-(1:2)], collapse = "\n")
      at <- regexpr("[*?[]", pattern)
      if (at < 0) return(dirname(pattern))
      base <- sub("/[^/]*$", "", substr(pattern, 1, at - 1))
      if (!nzchar(base)) base <- "/"
      parts <- strsplit(substring(pattern, nchar(base) + 2), "/", fixed = TRUE)[[1]]
      dirs <- base
      for (i in seq_len(length(parts) - 1)) {
        found <- Sys.glob(paste0(sub("/+$", "", base), "/", paste(parts[seq_len(i)], collapse = "/")))
        dirs <- c(dirs, found[dir.exists(found)])
      }
      unique(dirs)
    })
}

#' A listing's watch record: the folders it looks in
#' (`data_listing_dirs()`) with their modified times, and its
#' signature. Adding, removing or renaming a file changes its folder's
#' time, so the poll lists again only when one moved: listing 20,000
#' files takes about 140 ms, checking one folder's time well under 1 ms.
#'
#' Times are this machine's clock (`Sys.time()`), never compared with a
#' folder's, which on a network drive is the server's. `seen_at` is when
#' the poll first saw the folders' current times: for 2 s after it, a
#' second change in the same tick of a coarse clock (FAT's 2 s, HFS+'s
#' 1 s) would leave them as they are, so the poll lists again until a
#' listing starts after then (`listed_from`), as git does for its index. And it lists again every `every` seconds
#' whatever the times say (10 s, or 100 times the listing's own time,
#' whichever is longer): a file system that doesn't move a folder's time
#' when its entries change still has its change found.
data_listing_watch <- function(key, seen_at = as.numeric(Sys.time())) {
  start <- as.numeric(Sys.time())
  dirs <- data_listing_dirs(key)
  mtimes <- folder_mtimes(dirs)
  sig <- data_listing_signature(key)
  listed_at <- as.numeric(Sys.time())
  list(dirs = dirs, mtimes = mtimes, sig = sig, seen_at = seen_at, listed_from = start,
       listed_at = listed_at, every = max(10, 100 * (listed_at - start)))
}

#' The signature a result's run saw for listing `key` (its `data_seen`),
#' or `NULL` when none did.
listing_seen <- function(state, key) {
  for (r in state$results) {
    s <- .subset2(.subset2(r, "data_seen"), key)
    if (is.character(s) && length(s) == 1) return(s)
  }
  NULL
}

#' Folders' modified times as numbers, `NA` for one that isn't there: one
#' `file.info()` call for all of them.
folder_mtimes <- function(dirs) {
  if (length(dirs) == 0) return(numeric())
  tryCatch(as.numeric(file.info(dirs, extra_cols = FALSE)$mtime), error = function(e) rep(NA_real_, length(dirs)))
}

#' The listings among the watched keys whose names changed (#514), by key
#' to their new signature, for `check_data_files()`. A listing whose
#' folders' times moved is listed again, as is one whose last listing
#' began within 2 s of its `seen_at`, or past its `every`
#' (`data_listing_watch()`); only a new
#' signature is a change, so a file the listing wouldn't return (an Excel
#' lock file beside the CSVs) reruns nothing.
check_data_listings <- function(nb, listings) {
  changed <- list()
  dirs <- lapply(listings, function(k) nb$data_watch[[k]]$dirs)
  now <- folder_mtimes(unlist(dirs, use.names = FALSE))
  at <- 0L
  for (i in seq_along(listings)) {
    k <- listings[[i]]
    w <- nb$data_watch[[k]]
    n <- length(dirs[[i]])
    m <- now[at + seq_len(n)]
    at <- at + n
    same <- identical(m, w$mtimes)
    t <- as.numeric(Sys.time())
    if (same && w$listed_from > w$seen_at + 2 && t <= w$listed_at + w$every) next
    fresh <- data_listing_watch(k, seen_at = if (same) w$seen_at else t)
    nb$data_watch[[k]] <- fresh
    if (!identical(fresh$sig, w$sig)) changed[[k]] <- fresh$sig
  }
  changed
}

#' A data file's md5, or `NA` when it is missing or can't be read.
data_file_hash <- function(path) {
  tryCatch(unname(tools::md5sum(path)), error = function(e) NA_character_)
}

#' What a failed index fetch said, for a problem row: the child's `stop()`
#' message without R's wrapping ("Error: ", "Execution halted") or the
#' "ember: " every such message starts with, since the row already says
#' which fetch failed. Without an error line, the output's last 20 lines.
#' `output` is the job's output, one string (`job_start()`).
fetch_error_message <- function(output) {
  output <- unlist(strsplit(paste(output, collapse = "\n"), "\r?\n"))
  output <- output[!grepl("^Execution halted\\s*$", output)]
  # "Error: msg", or "Error in <call> : msg" (R's separator is " : ", and
  # the call may hold colons of its own, as pkg::f() does).
  error_re <- "^Error(: | in .*? : ?)"
  at <- grep(error_re, output, perl = TRUE)
  if (length(at) == 0) return(paste(utils::tail(output, 20), collapse = "\n"))
  lines <- output[at[[length(at)]]:length(output)]
  lines[[1]] <- sub(paste0(error_re, "(ember: )?"), "", lines[[1]], perl = TRUE)
  trimws(paste(trimws(lines), collapse = " "))
}
