# End to end: the R API with a real worker, through the shell. No package
# installs: every notebook cell here is base R only, so `open_notebook()`'s
# default `repos`/`cache` never resolve anything (an empty lock's library is
# the empty one, no network, no install).
# Waits use `wait_for()`/`run_cells(wait = TRUE)`, never `Sys.sleep`.
#
# Covers engine-tests.md items 106-117 ("End to end").

test_that("open_notebook starts no process; the snapshot is preview (106)", {
  path <- write_session_notebook(list(S = cell("")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  expect_null(nb$proc)
  snap <- notebook_snapshot(nb)
  expect_equal(snap$process, "preview")
  expect_false(snap$allowed)
})

test_that("run_cells(wait = TRUE) runs every cell with the expected outputs (107)", {
  cells <- list(S = cell(""), A = cell("x <- 21"), B = cell("y <- x * 2"), C = cell("y + 1"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  res <- run_cells(nb, wait = TRUE, timeout = 20)

  expect_true(res$accepted)
  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  code_views <- Filter(function(v) identical(v$kind, "code"), snap$cells)
  for (v in code_views) expect_equal(v$status, "ok")
  expect_equal(snap_view(snap, "C")$output$text, "[1] 43")
})

test_that("editing an upstream cell reruns dependents in autorun (108)", {
  cells <- list(S = cell(""), A = cell("x <- 1"), B = cell("x * 10"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_cells(nb, wait = TRUE, timeout = 20)

  edit_notebook(nb, set_code("A", "x <- 5"))
  res <- run_cells(nb, "A", wait = TRUE, timeout = 20)

  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, "B")$output$text, "[1] 50")
})

test_that("lazy mode marks dependents stale, then runs them on request (109)", {
  cells <- list(S = cell(""), A = cell("x <- 1"), B = cell("x * 10"))
  path <- write_session_notebook(cells, on_cell_change = "lazy")
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_cells(nb, wait = TRUE, timeout = 20)

  edit_notebook(nb, set_code("A", "x <- 5"))
  run_cells(nb, "A", wait = TRUE, timeout = 20)

  snap <- notebook_snapshot(nb)
  expect_true(snap_view(snap, "B")$stale)
  expect_equal(snap_view(snap, "B")$status, "ok")  # the old result, shown stale

  run_cells(nb, "B", wait = TRUE, timeout = 20)

  snap2 <- notebook_snapshot(nb)
  expect_false(snap_view(snap2, "B")$stale)
  expect_equal(snap_view(snap2, "B")$output$text, "[1] 50")
})

test_that("the file on disk matches the state after an edit, and file_saved fires (110)", {
  cells <- list(S = cell(""), A = cell("1"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  saved <- FALSE
  unsub <- on_notebook_event(nb, function(note) {
    if (identical(note$kind, "file_saved")) saved <<- TRUE
  })
  edit_notebook(nb, set_code("A", "2"))
  unsub()

  expect_true(saved)
  on_disk <- read_file_utf8(path)
  expected <- format_notebook(notebook_file_of(notebook_state(nb)))
  expect_equal(on_disk, expected)
})

# ---- review4 item 2: move_notebook() validates before changing state ---------

test_that("move_notebook() refuses to overwrite an existing file (review4 2)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  victim <- file.path(dirname(path), "important.R")
  writeLines("precious data", victim)

  expect_error(move_notebook(nb, victim), class = "ember_refused")
  expect_equal(readLines(victim), "precious data")
  expect_true(file.exists(path))
  expect_equal(notebook_state(nb)$path, path)
})

test_that("move_notebook() refuses a target in a folder that doesn't exist (review4 2)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  bad <- file.path(dirname(path), "no_such_dir", "nb.R")
  expect_error(move_notebook(nb, bad), class = "ember_refused")
  expect_false(file.exists(bad))
  expect_true(file.exists(path))
  expect_equal(notebook_state(nb)$path, path)

  # The state is never left pointing at the bad path, so an unrelated edit
  # afterwards still saves normally (no save_failed problem, no loop).
  edit_notebook(nb, set_code("A", "2"))
  expect_equal(nrow(notebook_state(nb)$problems %||% data.frame()), 0)
})

test_that("move_notebook() refuses a relative path (review4 2)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  expect_error(move_notebook(nb, "relative.R"), class = "ember_refused")
  expect_true(file.exists(path))
})

test_that("move_notebook() to the notebook's own current path is a no-op, not an 'already exists' refusal", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  result <- move_notebook(nb, path)
  expect_equal(result, normalizePath(path, mustWork = FALSE, winslash = "/"))
  expect_equal(notebook_state(nb)$path, path)
  expect_true(file.exists(path))
})

test_that("move_notebook() allows a case-only rename in the same folder (case-insensitive filesystems)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  dir <- dirname(path)
  cased_target <- file.path(dir, toupper(basename(path)))
  skip_if(identical(basename(path), toupper(basename(path))),
         "the fixture's name has no letters to case-swap")

  # The folder is normalised (tempdir()'s own "/var" -> "/private/var"
  # symlink on macOS, say); the file name is kept exactly as given, which
  # is the whole point of this test (move_notebook()'s doc).
  expected <- file.path(normalizePath(dir, mustWork = FALSE, winslash = "/"), basename(cased_target))

  if (file.exists(cased_target) && !identical(cased_target, path)) {
    # Case-insensitive filesystem (macOS, Windows): file.exists() already
    # says the differently-cased target exists -- it's this same file --
    # and the rename must be let through rather than refused.
    result <- move_notebook(nb, cased_target)
    expect_equal(notebook_state(nb)$path, expected)
    expect_true(file.exists(cased_target))
  } else {
    # Case-sensitive filesystem (most Linux): the differently-cased target
    # is a genuinely different, nonexistent path, and the move is an
    # ordinary rename.
    result <- move_notebook(nb, cased_target)
    expect_equal(notebook_state(nb)$path, expected)
    expect_true(file.exists(cased_target))
    expect_false(file.exists(path))
  }
})

test_that("move_notebook() while R is running keeps the worker and getwd() follows it (ui-3 91)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_cells(nb, wait = TRUE, timeout = 20)
  pid0 <- notebook_state(nb)$worker$info$pid
  expect_true(is.numeric(pid0))

  new_dir <- tempfile("ember-move-")
  dir.create(new_dir)
  new_path <- file.path(new_dir, basename(path))
  move_notebook(nb, new_path)
  # The folder is normalised (symlinks resolved); the name is kept as
  # given.
  expected <- file.path(normalizePath(new_dir, mustWork = FALSE, winslash = "/"), basename(path))
  expect_equal(notebook_state(nb)$path, expected)

  res <- edit_notebook(nb, insert_cell(2, "getwd()"))
  new_id <- res$inserted[[1]]
  run_cells(nb, new_id, wait = TRUE, timeout = 20)

  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, new_id)$output$text,
              sprintf('[1] "%s"', normalizePath(new_dir, winslash = "/")))
  expect_equal(notebook_state(nb)$worker$info$pid, pid0)
})

test_that("a failing save is not retried within one drain, and is retried on the next change (review4 2)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1")))
  dir <- dirname(path)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  Sys.chmod(dir, "0555")
  on.exit(Sys.chmod(dir, "0755"), add = TRUE)
  if (file.access(dir, 2) == 0) {
    skip("cannot make a directory unwritable in this environment (likely running as root)")
  }

  # Before the fix, `save_if_changed()` re-enqueued `ev_save_failed` forever
  # within this one drain (the text never changes, so the write is retried
  # every time the event is processed), pinning a core at 100% CPU. This
  # must return promptly and record the failure exactly once.
  t <- system.time(edit_notebook(nb, set_code("A", "2")))
  expect_lt(t[["elapsed"]], 2)
  problems <- notebook_state(nb)$problems
  expect_equal(sum(problems$kind == "save_failed"), 1)

  # A further edit while still unwritable is a *new* change (different
  # text), so it is retried and fails again -- one more row, not a flood.
  edit_notebook(nb, set_code("A", "3"))
  problems2 <- notebook_state(nb)$problems
  expect_equal(sum(problems2$kind == "save_failed"), 2)
})

test_that("a learned definition from load() is saved in the footer and orders cells on reopen (111)", {
  dir <- tempfile("ember-nb-")
  dir.create(dir, recursive = TRUE)
  rdata_path <- file.path(dir, "fits.RData")
  fits <- 42
  save(fits, file = rdata_path)

  cells <- list(S = cell(""), A = cell(sprintf("load(%s)", deparse(rdata_path))),
               B = cell("fits + 1"))
  path <- write_session_notebook(cells, dir = dir)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  res <- run_cells(nb, wait = TRUE, timeout = 20)
  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, "B")$output$text, "[1] 43")

  file_text <- read_file_utf8(path)
  expect_match(file_text, "learned definitions")
  expect_match(file_text, "fits")

  close_notebook(nb)
  nb2 <- open_notebook(path)
  on.exit(close_notebook(nb2), add = TRUE)
  g <- dependency_graph(nb2)
  expect_true("fits" %in% g$cells[["A"]]$definitions)
  expect_true("A" %in% g$upstream[["B"]])
})

test_that("opening and closing an untouched notebook writes nothing (112)", {
  cells <- list(S = cell(""), A = cell("1"))
  path <- write_session_notebook(cells)
  before_bytes <- readBin(path, "raw", file.info(path)$size)
  before_mtime <- file.info(path)$mtime

  nb <- open_notebook(path)
  close_notebook(nb)

  after_bytes <- readBin(path, "raw", file.info(path)$size)
  after_mtime <- file.info(path)$mtime
  expect_identical(before_bytes, after_bytes)
  expect_equal(before_mtime, after_mtime)
})

test_that("interrupting a stuck cell offers a restart after the grace period (113)", {
  so <- compile_stuck_lib()
  skip_if(is.null(so), "could not compile the stuck.c fixture (no compiler available)")

  # dyn.load() happens in S, which A reads `lib` from so S runs first: a
  # top-level statement next to the .Call() gives R a safe point to notice
  # the interrupt between the two, before the stuck C loop (which never
  # calls R_CheckUserInterrupt()) is even entered.
  cells <- list(S = cell(sprintf("lib <- dyn.load(%s)", deparse(so))),
               A = cell('invisible(lib)\n.Call("stuck", 6L)'))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  run_cells(nb, "A", wait = FALSE)
  busy <- wait_for(nb, function(s) identical(s$process, "busy"), timeout = 15)
  expect_true(busy)
  # Give the cell a moment to truly be inside the C loop (not still
  # starting up) before interrupting, via the later loop rather than a
  # sleep.
  busy_at <- Sys.time()
  wait_for(nb, function(s) as.numeric(Sys.time() - busy_at, units = "secs") > 1, timeout = 10)

  interrupt_notebook(nb)
  offered <- wait_for(nb, function(s) isTRUE(s$restart_offered), timeout = 15)
  expect_true(offered)

  restart_notebook(nb)
  ready <- wait_for(nb, function(s) identical(s$process, "ready"), timeout = 15)
  expect_true(ready)

  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, "A")$status, "not_run")
})

test_that("a crashed worker reports worker_exited, and the next run starts a new one (114)", {
  cells <- list(S = cell(""), A = cell("tools::pskill(Sys.getpid())"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  run_cells(nb, "A", wait = TRUE, timeout = 15)
  snap <- notebook_snapshot(nb)
  view <- snap_view(snap, "A")
  expect_equal(view$status, "error")
  expect_equal(view$errors[[length(view$errors)]]$kind, "worker_exited")

  # Rerunning the same self-killing code would just crash the new worker
  # again; edit it first to prove a fresh worker actually starts and runs.
  edit_notebook(nb, set_code("A", "1 + 1"))
  run_cells(nb, "A", wait = TRUE, timeout = 15)
  snap2 <- notebook_snapshot(nb)
  expect_equal(snap2$process, "ready")
  expect_equal(snap_view(snap2, "A")$status, "ok")
})

test_that("Endeavor-shaped calls: apply with expected, run(wait = FALSE), seq, render_png (115)", {
  cells <- list(S = cell(""), A = cell("1"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  refused <- tryCatch({ edit_notebook(nb, set_code("A", "2", expected = "wrong")); NULL },
                      error = function(e) e)
  expect_s3_class(refused, "ember_refused")

  r <- edit_notebook(nb, set_code("A", "2", expected = "1"))
  expect_true(all(c("inserted", "seq") %in% names(r)))

  seq_before <- notebook_snapshot(nb)$seq
  done <- FALSE
  unsub <- on_notebook_event(nb, function(note) {
    if (identical(note$kind, "execution_done")) done <<- TRUE
  })
  res <- run_cells(nb, wait = FALSE)
  expect_true(res$accepted)
  ok <- wait_for(nb, function(s) done, timeout = 20)
  unsub()
  expect_true(ok)
  expect_gte(notebook_snapshot(nb)$seq, seq_before)

  cells2 <- list(S = cell(""), P = cell("plot(1:10)"))
  path2 <- write_session_notebook(cells2)
  nb2 <- open_notebook(path2)
  on.exit(close_notebook(nb2), add = TRUE)
  run_cells(nb2, wait = TRUE, timeout = 20)
  png <- render_png(nb2, "P")
  expect_equal(png$mime, "image/png")
  expect_true(is.raw(png$png))
})

test_that("two consecutive notebook_state() values share unchanged cells (116)", {
  cells <- list(S = cell(""), A = cell("1"), B = cell("2"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_cells(nb, wait = TRUE, timeout = 20)

  s1 <- notebook_state(nb)
  edit_notebook(nb, set_code("A", "11"))
  s2 <- notebook_state(nb)

  expect_identical(s1$cells[["B"]], s2$cells[["B"]])
  addr <- function(x) { a <- tracemem(x); untracemem(x); a }
  expect_equal(addr(s1$cells[["B"]]), addr(s2$cells[["B"]]))
})

test_that("a later callback keeps firing during a 2 s busy cell (117)", {
  cells <- list(S = cell(""), A = cell("Sys.sleep(2)"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  ticks <- list()
  stop_ticking <- FALSE
  tick <- function() {
    if (stop_ticking) return(invisible(NULL))
    ticks[[length(ticks) + 1]] <<- Sys.time()
    later::later(tick, 0.01)
  }
  tick()
  on.exit(stop_ticking <<- TRUE, add = TRUE)

  run_cells(nb, "A", wait = FALSE)
  ok <- wait_for(nb, is_idle, timeout = 15)
  stop_ticking <- TRUE

  expect_true(ok)
  expect_gt(length(ticks), 10)
  times <- vapply(ticks, as.numeric, numeric(1))
  gaps <- diff(times)
  # A blocked server would show a gap near the cell's 2 s; shared CI
  # machines show occasional pauses of a few hundred ms.
  expect_lt(max(gaps), 0.5)
})

test_that("worker_output_pipe_drained", {
  path <- tempfile(fileext = ".R")
  nb <- new_notebook(path)
  on.exit(close_notebook(nb))
  # A child process writes 200 KB straight to the worker's stdout, past
  # the pipe's buffer, bypassing the cell's capture.
  rscript <- deparse(file.path(R.home("bin"), "Rscript"))
  code <- paste0("system2(", rscript, ", c('-e', shQuote('cat(strrep(\"x\", 2e5))'))); 1")
  edit_notebook(nb, set_code(1, code))
  run_cells(nb, wait = TRUE, timeout = 30)
  expect_identical(notebook_snapshot(nb)$cells[[1]]$status, "ok")
})

test_that("clean() never deletes a library an open notebook holds active, through a real open_notebook() (10)", {
  cache <- tempfile("ember-cache-")
  dir.create(cache)
  path <- write_session_notebook(list(S = cell("")))
  nb <- open_notebook(path, cache = cache)

  info <- nb$state$packages$active
  dir.create(info$path, recursive = TRUE, showWarnings = FALSE)
  manifest <- list(lock_lines = character(), r = r_info(), installed = character(),
                   exports = list(), cache_entries = character(), created = Sys.time() - 1000)
  saveRDS(manifest, file.path(info$path, "ember-library.rds"))
  marker <- file.path(info$path, "ember-last-used")
  file.create(marker)
  Sys.setFileTime(marker, Sys.time() - 90 * 86400)

  # Old enough that clean() would otherwise take it; the open session holds
  # it as `active`, and `open_notebook()` wired that fact into
  # `active_libraries` (library.R) with no manual `set_active_libraries()`
  # call from this test.
  d <- clean(max_age = 60, cache = FALSE, dry_run = TRUE, dir = cache)
  expect_false(info$path %in% d$path)

  close_notebook(nb)
  d2 <- clean(max_age = 60, cache = FALSE, dry_run = TRUE, dir = cache)
  expect_true(info$path %in% d2$path)
})

test_that("insert_cell() of #' code folds the cell in the snapshot and the written file (ui-2 3)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1"), B = cell("2")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  res <- edit_notebook(nb, insert_cell(2, "#' Hi"))
  md_id <- res$inserted[[1]]
  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, md_id)$kind, "markdown")
  expect_true(snap_view(snap, md_id)$folded)
  expect_true(any(grepl(paste0("^# ", md_id, " folded$"), strsplit(nb$written, "\n")[[1]])))

  res2 <- edit_notebook(nb, insert_cell(2, "3"))
  code_id <- res2$inserted[[1]]
  snap2 <- notebook_snapshot(nb)
  expect_equal(snap_view(snap2, code_id)$kind, "code")
  expect_false(snap_view(snap2, code_id)$folded)
  expect_true(any(grepl(paste0("^# ", code_id, "$"), strsplit(nb$written, "\n")[[1]])))
})

test_that("notebook_snapshot() strips ANSI from output and console text; notebook_state() keeps it (ui-2 33)", {
  path <- write_session_notebook(list(S = cell(""),
    A = cell('cat("\\033[31mred\\033[39m\\n"); "\\033[32mgreen\\033[39m"')))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_cells(nb, wait = TRUE)

  snap <- notebook_snapshot(nb)
  a <- snap_view(snap, names(snap$cells)[2])
  expect_false(grepl("\033", a$output$text, fixed = TRUE))
  expect_false(grepl("\033", a$console[[1]]$text, fixed = TRUE))
  expect_match(a$output$text, "green")
  expect_match(a$console[[1]]$text, "red")

  raw_console <- notebook_state(nb)$results[[names(snap$cells)[2]]]$console
  expect_true(any(grepl("\033", vapply(raw_console, `[[`, character(1), "text"), fixed = TRUE)))
})

# ---- worker_query() (ui-2.md, 4a) --------------------------------------------

test_that("worker_query() answers when idle, NULL at once while busy, NULL in preview starting no worker, drops a late reply, and fails every pending query on exit (48)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("Sys.sleep(3)")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  # Safe preview: NULL at once, and no worker is started by asking.
  got_preview <- "unset"
  worker_query(nb, list(type = "signature", name = "lm", package = NULL), function(r) got_preview <<- r)
  expect_null(got_preview)
  expect_null(nb$proc)

  allow_execution(nb)
  run_cells(nb, wait = TRUE, timeout = 20)

  # Idle: a real reply.
  got_idle <- "unset"
  worker_query(nb, list(type = "signature", name = "lm", package = NULL), function(r) got_idle <<- r)
  expect_true(wait_for(nb, function(s) !identical(got_idle, "unset"), timeout = 10))
  expect_match(got_idle$text, "^lm\\(formula, data")

  # Busy: NULL at once, not after waiting out the cell.
  run_cells(nb, "A", wait = FALSE)
  expect_true(wait_for(nb, function(s) identical(s$process, "busy"), timeout = 15))
  got_busy <- "unset"
  before <- Sys.time()
  worker_query(nb, list(type = "signature", name = "lm", package = NULL), function(r) got_busy <<- r)
  expect_null(got_busy)
  expect_lt(as.numeric(Sys.time() - before, units = "secs"), 0.5)

  # A late reply (the busy cell finishes and the worker is asked again,
  # with a very short timeout) is dropped, not delivered twice, and
  # doesn't kill the worker.
  expect_true(wait_for(nb, timeout = 20))
  late_calls <- 0L
  late_reply <- "unset"
  worker_query(nb, list(type = "signature", name = "lm", package = NULL),
              function(r) { late_calls <<- late_calls + 1L; late_reply <<- r }, timeout = 0)
  later::run_now(timeout = 0)  # the 0s timeout fires before the worker's real reply can arrive
  for (i in 1:50) { later::run_now(timeout = 0.05); Sys.sleep(0.02) }
  expect_identical(late_calls, 1L)
  expect_null(late_reply)
  expect_true(wait_for(nb, timeout = 5))
  expect_false(is.null(nb$proc))

  # The worker is still alive and answers again: a fresh query, with no
  # short timeout this time, gets a real reply.
  got_again <- "unset"
  worker_query(nb, list(type = "signature", name = "lm", package = NULL), function(r) got_again <<- r)
  expect_true(wait_for(nb, function(s) !identical(got_again, "unset"), timeout = 10))
  expect_match(got_again$text, "^lm\\(formula, data")

  # A worker exit fails every pending query. A real query's reply can beat
  # a kill() by a wide enough margin on a fast loopback that this can't be
  # driven through a real round trip deterministically (the bytes are
  # already on the socket before the process dies), so this registers
  # callbacks directly, the way `worker_query()` itself would, and checks
  # that an actual exit (not a manual call) clears them.
  expect_true(wait_for(nb, timeout = 20))
  got_a <- "unset"
  got_b <- "unset"
  assign("9001", function(r) got_a <<- r, envir = nb$queries)
  assign("9002", function(r) got_b <<- r, envir = nb$queries)
  nb$proc$kill()
  expect_true(wait_for(nb, function(s) identical(s$process, "stopped"), timeout = 15))
  expect_null(got_a)
  expect_null(got_b)
  expect_identical(length(ls(nb$queries)), 0L)
})

test_that("a dependent of a failed cell runs on its own and reruns once the ancestor is fixed (ui-3 13)", {
  cells <- list(S = cell(""), A = cell('a <- 1; stop("boom")'), B = cell("a + 1"), C = cell('exists("a")'))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  run_cells(nb, NULL, wait = TRUE, timeout = 20)
  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, "B")$status, "error")
  expect_equal(snap_view(snap, "B")$errors[[length(snap_view(snap, "B")$errors)]]$kind, "upstream")
  expect_equal(snap_view(snap, "C")$output$text, "[1] FALSE")

  edit_notebook(nb, set_code("A", "a <- 1"))
  run_cells(nb, "A", wait = TRUE, timeout = 20)
  snap2 <- notebook_snapshot(nb)
  expect_equal(snap_view(snap2, "B")$status, "ok")
})

test_that("disabling a cell removes it from R; Rscript on the saved file still runs; enabling reruns its dependent (ui-3 35)", {
  # H's exists() passes envir = globalenv() so it stays untracked (reader
  # rule: a literal exists() name with an envir argument isn't resolved):
  # H must probe R's actual state after disabling A, not get marked off by
  # a dependency on A and skip running altogether.
  cells <- list(S = cell(""), A = cell("x <- 1; library(tools)"), B = cell("x + 1"),
               H = cell('c(exists("x", envir = globalenv()), "package:tools" %in% search())'))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  run_cells(nb, NULL, wait = TRUE, timeout = 20)
  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, "B")$status, "ok")

  edit_notebook(nb, disable_cell("A"))
  on_disk <- read_file_utf8(path)
  expect_match(on_disk, "## x <- 1; library(tools)", fixed = TRUE)
  expect_match(on_disk, "## x \\+ 1")
  expect_match(on_disk, "# B commented", fixed = TRUE)

  run_cells(nb, "H", wait = TRUE, timeout = 20)
  snap2 <- notebook_snapshot(nb)
  expect_equal(snap_view(snap2, "H")$output$text, "[1] FALSE FALSE")

  res <- system2(file.path(R.home("bin"), "Rscript"), shQuote(path), stdout = TRUE, stderr = TRUE)
  expect_equal(attr(res, "status") %||% 0, 0)

  b_before <- snap_view(snap2, "B")
  edit_notebook(nb, disable_cell("A", FALSE))
  run_cells(nb, "A", wait = TRUE, timeout = 20)
  snap3 <- notebook_snapshot(nb)
  b_after <- snap_view(snap3, "B")
  expect_equal(b_after$status, "ok")
  # Not just "still ok" (it was never cleared): B actually reran, so its
  # stale flag is down and its run time has moved on.
  expect_false(isTRUE(b_after$stale))
  expect_true(b_after$last_run > b_before$last_run)
})
