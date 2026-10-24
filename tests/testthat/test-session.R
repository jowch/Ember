# End to end: the R API with a real worker, through the shell. No package
# installs: every notebook cell here is base R only, so `open_notebook()`'s
# default `repos`/`cache` never resolve anything (an empty lock's library is
# the empty one, no network, no install).
# Waits use `settle()`/`run_settled()` (helper-wait.R): no time limit,
# never `Sys.sleep`.
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

  res <- run_settled(nb)

  expect_true(res$accepted)
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
  run_settled(nb)

  edit_notebook(nb, set_code("A", "x <- 5"))
  res <- run_settled(nb, "A")

  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, "B")$output$text, "[1] 50")
})

test_that("lazy mode marks dependents stale, then runs them on request (109)", {
  cells <- list(S = cell(""), A = cell("x <- 1"), B = cell("x * 10"))
  path <- write_session_notebook(cells, on_cell_change = "lazy")
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_settled(nb)

  edit_notebook(nb, set_code("A", "x <- 5"))
  run_settled(nb, "A")

  snap <- notebook_snapshot(nb)
  expect_true(snap_view(snap, "B")$stale)
  expect_equal(snap_view(snap, "B")$status, "ok")  # the old result, shown stale

  run_settled(nb, "B")

  snap2 <- notebook_snapshot(nb)
  expect_false(snap_view(snap2, "B")$stale)
  expect_equal(snap_view(snap2, "B")$output$text, "[1] 50")
})

test_that("lazy mode: running a cell runs every ancestor between an edited one and it, at any depth, and only those; nothing shown is wrong and unmarked (#169)", {
  cells <- list(S = cell(""), A = cell("x <- 1"), B = cell("y <- x * 10"), C = cell("z <- y + 1"),
                D = cell("z * 2"), E = cell("x + 100"))
  path <- write_session_notebook(cells, on_cell_change = "lazy")
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_settled(nb)

  # Every cell's text, and whether it is shown stale: one with no stale mark
  # must show what its current code gives.
  views <- function() {
    snap <- notebook_snapshot(nb)
    lapply(stats::setNames(nm = c("A", "B", "C", "D", "E")), function(id) {
      v <- snap_view(snap, id)
      list(text = v$output$text, stale = isTRUE(v$stale))
    })
  }
  shown <- function(v) vapply(v, function(x) x$text, character(1))
  stale <- function(v) vapply(v, function(x) x$stale, logical(1))

  # Edit three steps up from D: A, B and C all run before it.
  edit_notebook(nb, set_code("A", "x <- 2"))
  r <- run_settled(nb, "D")
  expect_identical(r$queued, c("A", "B", "C", "D"))
  v <- views()
  expect_identical(shown(v)[c("A", "B", "C", "D")], c(A = "[1] 2", B = "[1] 20", C = "[1] 21", D = "[1] 42"))
  # E isn't on the way to D: it isn't run, and shows its old result stale.
  expect_identical(c(shown(v)[["E"]], stale(v)[["E"]]), c("[1] 101", "TRUE"))
  expect_false(any(stale(v)[c("A", "B", "C", "D")]))

  # Edit two steps up: B and C run, A doesn't.
  edit_notebook(nb, set_code("B", "y <- x * 100"))
  r <- run_settled(nb, "D")
  expect_identical(r$queued, c("B", "C", "D"))
  expect_identical(shown(views())[c("B", "C", "D")], c(B = "[1] 200", C = "[1] 201", D = "[1] 402"))

  # The cell run is in the middle of the chain: D isn't run, and is stale.
  edit_notebook(nb, set_code("A", "x <- 3"))
  r <- run_settled(nb, "C")
  expect_identical(r$queued, c("A", "B", "C"))
  v <- views()
  expect_identical(shown(v)[c("A", "B", "C")], c(A = "[1] 3", B = "[1] 300", C = "[1] 301"))
  expect_identical(stale(v)[c("A", "B", "C", "D")], c(A = FALSE, B = FALSE, C = FALSE, D = TRUE))
})

test_that("autorun: running a cell after editing its grandparent runs each cell once and ends right (#169)", {
  log <- normalizePath(tempfile("ember-runs-"), winslash = "/", mustWork = FALSE)
  logged <- function(id, code) cell(sprintf('cat("%s\\n", file = "%s", append = TRUE); %s', id, log, code))
  cells <- list(S = cell(""), A = logged("A", "x <- 1"), B = logged("B", "y <- x * 10"), C = logged("C", "y + 1"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_settled(nb)
  unlink(log)

  edit_notebook(nb, set_code("A", sprintf('cat("A\\n", file = "%s", append = TRUE); x <- 2', log)))
  run_settled(nb, "C")
  settle(nb, is_idle)
  snap <- notebook_snapshot(nb)
  expect_identical(vapply(c("B", "C"), function(id) snap_view(snap, id)$output$text, character(1)),
                   c(B = "[1] 20", C = "[1] 21"))
  expect_identical(sort(readLines(log)), c("A", "B", "C"))
})

test_that("autorun: a cell that reads a file another cell writes reruns when the contents change, not on the same bytes (#276)", {
  log <- normalizePath(tempfile("ember-runs-"), winslash = "/", mustWork = FALSE)
  cells <- list(S = cell(""), W = cell("k <- 1; writeLines(as.character(k), 'd.txt')"),
                R = cell(sprintf("cat('R\\n', file = '%s', append = TRUE); d <- readLines('d.txt')", log)),
                U = cell("paste(d, '!')"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_settled(nb)
  data <- file.path(dirname(path), "d.txt")
  # The shell has seen the file W wrote: R ran after it, so it stays as is.
  seen <- function(...) identical(nb$data_watch[["d.txt"]]$mtime, file.info(data)$mtime)
  settle(nb, function(snap) seen() && is_idle(snap))
  expect_identical(readLines(log), "R")
  shown_u <- function(snap) snap_view(snap, "U")$output$text

  # New contents: R and U rerun, though neither reads a variable W defines.
  # Already there when the wait returns: the writer's result doesn't wait
  # for the poll, which is held off here so only that path can see it.
  edit_notebook(nb, set_code("W", "k <- 2; writeLines(as.character(k), 'd.txt')"))
  nb$last_watch_check <- Sys.time() + 3600
  run_settled(nb, "W")
  expect_identical(shown_u(notebook_snapshot(nb)), '[1] "2 !"')
  nb$last_watch_check <- NULL
  settle(nb, function(snap) identical(shown_u(snap), '[1] "2 !"') && is_idle(snap))
  expect_identical(readLines(log), c("R", "R"))

  # The same bytes again: the shell sees the write and reruns nothing.
  edit_notebook(nb, set_code("W", "k <- 2; writeLines(as.character(k), 'd.txt'); NULL"))
  run_settled(nb, "W")
  settle(nb, function(snap) seen() && is_idle(snap))
  expect_identical(readLines(log), c("R", "R"))
})

test_that("a cell that reads a file and appends to it runs once, as in plain R (#276)", {
  cells <- list(S = cell(""), L = cell("d <- readLines('log.txt')\ncat('entry\\n', file = 'log.txt', append = TRUE)"))
  path <- write_session_notebook(cells)
  log <- file.path(dirname(path), "log.txt")
  writeLines("start", log)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_settled(nb)
  # The shell's poll has seen the append, and nothing ran after it.
  seen <- function(...) identical(nb$data_watch[["log.txt"]]$mtime, file.info(log)$mtime)
  settle(nb, function(snap) seen() && is_idle(snap))
  expect_identical(readLines(log), c("start", "entry"))
  expect_false(isTRUE(snap_view(notebook_snapshot(nb), "L")$stale))
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

test_that("running cells formats the file and gathers watched paths only when they can change (#44)", {
  cells <- c(list(S = cell("")),
             stats::setNames(lapply(1:20, function(i) cell(sprintf("x%d <- %d", i, i))), sprintf("c%d", 1:20)))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  edit_notebook(nb, set_code("c1", "x1 <- 0"))  # the first save after open

  formatted <- 0L; synced <- 0L
  real_format <- format_notebook; real_sync <- sync_watch
  local_mocked_bindings(
    format_notebook = function(...) { formatted <<- formatted + 1L; real_format(...) },
    sync_watch = function(...) { synced <<- synced + 1L; real_sync(...) })
  res <- run_settled(nb)
  # Twenty cells finishing are dozens of worker messages, none of which
  # changes the file or what it sources.
  expect_lt(formatted, 5L)
  expect_lt(synced, 5L)

  # An edit still saves, and a new source() is still watched.
  writeLines("y <- 1", file.path(dirname(path), "helper.R"))
  edit_notebook(nb, set_code("c2", "source('helper.R')"))
  expect_equal(read_file_utf8(path), real_format(notebook_file_of(notebook_state(nb))))
  expect_true("helper.R" %in% names(nb$watch))
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
  run_settled(nb)
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
  run_settled(nb, new_id)

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
  # must return and record the failure exactly once. The broken version
  # never returned; returning at all is the check, so no time limit.
  edit_notebook(nb, set_code("A", "2"))
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

  res <- run_settled(nb)
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
  marker <- tempfile("ember-stuck-")
  cells <- list(S = cell(sprintf("lib <- dyn.load(%s)", deparse(so))),
               A = cell(sprintf('invisible(lib)\n.Call("stuck", 6L, %s)', deparse(marker))))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  run_cells(nb, "A", wait = FALSE)
  # Wait for A itself to run: "busy" is already true while S runs, and an
  # interrupt then would clear the queue before A starts (#149).
  settle(nb, function(s) isTRUE(snap_view(s, "A")$running), "A to start")
  # Interrupt only once A is inside the C loop, not still starting up.
  wait_until(function() file.exists(marker), "the stuck C loop to begin", nb)

  interrupt_notebook(nb)
  # A hang here shows whether A stopped cleanly or the worker died (#149).
  settle(nb, function(s) isTRUE(s$restart_offered), "the restart to be offered")

  restart_notebook(nb)
  settle(nb, function(s) identical(s$process, "ready"), "R to be ready again")

  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, "A")$status, "not_run")
})

test_that("an interrupt sent as a run is dispatched stops that run", {
  # The interrupt here is dispatched before the worker can have read the
  # run. A worker swallows an interrupt that lands before it began a run,
  # so the server holds SIGINT until the worker says it began.
  cells <- list(S = cell(""), A = cell("x <- 1"), B = cell("Sys.sleep(8)"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_settled(nb, "A")   # the worker is up

  run_cells(nb, "B", wait = FALSE)
  interrupt_notebook(nb)
  # A lost interrupt lets the sleep run to the end and report "ok".
  settle(nb, function(s) identical(s$process, "ready"), "B to end")
  expect_equal(snap_view(notebook_snapshot(nb), "B")$status, "interrupted")
})

test_that("on Windows an interrupt that can't reach the worker offers the restart at once (#48)", {
  skip_on_os(c("mac", "linux", "solaris"))
  # A worker without the package's DLL has no interrupt event to set.
  local_mocked_bindings(ember_dll_path = function() "")
  cells <- list(S = cell(""), A = cell("x <- 1"), B = cell("Sys.sleep(20)"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_settled(nb, "A")
  run_cells(nb, "B", wait = FALSE)
  settle(nb, function(s) isTRUE(nb$state$worker$running$begun))
  interrupt_notebook(nb)
  # Only the failure path sets interrupt_failed: the grace timer sets
  # restart_offered alone.
  settle(nb, function(s) isTRUE(s$interrupt_failed))
  expect_true(notebook_snapshot(nb)$restart_offered)
})

test_that("a crashed worker reports worker_exited, and the next run starts a new one (114)", {
  cells <- list(S = cell(""), A = cell("tools::pskill(Sys.getpid())"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  run_settled(nb, "A")
  snap <- notebook_snapshot(nb)
  view <- snap_view(snap, "A")
  expect_equal(view$status, "error")
  expect_equal(view$errors[[length(view$errors)]]$kind, "worker_exited")

  # Rerunning the same self-killing code would just crash the new worker
  # again; edit it first to prove a fresh worker actually starts and runs.
  edit_notebook(nb, set_code("A", "1 + 1"))
  run_settled(nb, "A")
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
  settle(nb, function(s) done, "the execution_done event")
  unsub()
  expect_gte(notebook_snapshot(nb)$seq, seq_before)

  cells2 <- list(S = cell(""), P = cell("plot(1:10)"))
  path2 <- write_session_notebook(cells2)
  nb2 <- open_notebook(path2)
  on.exit(close_notebook(nb2), add = TRUE)
  run_settled(nb2)
  png <- waiting_for("P's redraw", render_png(nb2, "P", timeout = HANG_GUARD), nb2)
  expect_equal(png$mime, "image/png")
  expect_true(is.raw(png$png))
})

test_that("render_png() at a pixel size returns that image and leaves the stored one, also while busy (#28)", {
  path <- write_session_notebook(list(S = cell(""), P = cell("plot(1:10)"), B = cell("Sys.sleep(1)")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  allow_execution(nb)
  run_settled(nb)
  # PNG width and height: big-endian integers at bytes 17-24 (IHDR).
  png_px <- function(b) c(sum(as.integer(b[17:20]) * 256^(3:0)), sum(as.integer(b[21:24]) * 256^(3:0)))

  stored <- nb$state$results$P$output
  seen <- character()
  unsub <- on_notebook_event(nb, function(note) {
    if (identical(note$kind, "cell_state")) seen <<- c(seen, unlist(note$cells))
  })
  r <- waiting_for("P's redraw at 200 x 100", render_png(nb, "P", width = 200, height = 100, timeout = HANG_GUARD), nb)
  expect_equal(r$mime, "image/png")
  expect_equal(png_px(r$png), c(200, 100))
  expect_identical(nb$state$results$P$output, stored)
  expect_identical(waiting_for("P's redraw at its stored size", render_png(nb, "P", timeout = HANG_GUARD), nb)$png, stored$data)

  # A busy worker answers once its run ends.
  run_cells(nb, "B", wait = FALSE)
  settle(nb, function(s) identical(s$process, "busy"))
  r2 <- waiting_for("P's redraw at 300 x 150",
                    render_png(nb, "P", width = 300, height = 150, timeout = HANG_GUARD), nb)
  expect_equal(png_px(r2$png), c(300, 150))
  settle(nb)
  unsub()
  expect_identical(nb$state$results$P$output, stored)
  expect_false("P" %in% seen)
})

test_that("two consecutive notebook_state() values share unchanged cells (116)", {
  cells <- list(S = cell(""), A = cell("1"), B = cell("2"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_settled(nb)

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
  # The worker starts on the first run, and starting it holds the server's
  # loop while the process spawns (up to 1.4 s measured, #499). That isn't
  # the busy cell this test is about (#490): start it first.
  run_cells(nb, "S", wait = TRUE, timeout = 20)

  # What the server did, so a long gap can say what fell inside it (#490):
  # each poll's start and length, and each event step() handled.
  t0 <- as.numeric(Sys.time())
  polls <- list()
  steps <- list()
  real_poll <- poll
  real_step <- step
  local_mocked_bindings(
    poll = function(nb) {
      start <- as.numeric(Sys.time())
      on.exit(polls[[length(polls) + 1]] <<- c(start, as.numeric(Sys.time())))
      real_poll(nb)
    },
    step = function(state, event) {
      start <- as.numeric(Sys.time())
      on.exit(steps[[length(steps) + 1]] <<- list(start = start, end = as.numeric(Sys.time()), type = event$type))
      real_step(state, event)
    }
  )

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
  settle(nb, is_idle, "A to finish")
  stop_ticking <- TRUE

  expect_gt(length(ticks), 10)
  times <- vapply(ticks, as.numeric, numeric(1))
  gaps <- diff(times)
  # Where the longest gap fell: its start and end, from when the test
  # began ticking, the run's own events, and the polls and steps inside it.
  i <- which.max(gaps)
  from <- times[i]
  to <- times[i + 1]
  at <- function(x) sprintf("%.3f", x - t0)
  step_lines <- vapply(steps, function(s) sprintf("  %s at %s, %.3f s", s$type, at(s$start), s$end - s$start), "")
  inside <- function(start, end) end >= from & start <= to
  run_events <- step_lines[vapply(steps, function(s) s$type %in% c("wk_running", "wk_done"), NA)]
  in_gap <- c(
    step_lines[vapply(steps, function(s) inside(s$start, s$end), NA)],
    vapply(Filter(function(p) inside(p[1], p[2]), polls), function(p) sprintf("  poll at %s, %.3f s", at(p[1]), p[2] - p[1]), "")
  )
  where <- paste(c(
    sprintf("longest gap %.3f s, from %s to %s s", gaps[i], at(from), at(to)),
    "the run:", run_events,
    "inside the gap:", if (length(in_gap)) in_gap else "  nothing the server recorded",
    "max(gaps)"
  ), collapse = "\n")
  # A blocked server would show a gap near the cell's 2 s; shared CI
  # machines show occasional pauses of a few hundred ms.
  expect_lt(max(gaps), 0.5, label = where)
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
  run_settled(nb)
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

test_that("insert_cell() of #' code leaves the cell unfolded in the snapshot and the written file (ui-2 3)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("1"), B = cell("2")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  res <- edit_notebook(nb, insert_cell(2, "#' Hi"))
  md_id <- res$inserted[[1]]
  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, md_id)$kind, "markdown")
  expect_false(snap_view(snap, md_id)$folded)
  expect_true(any(grepl(paste0("^# ", md_id, "$"), strsplit(nb$written, "\n")[[1]])))

  edit_notebook(nb, fold_cell(md_id))
  expect_true(snap_view(notebook_snapshot(nb), md_id)$folded)
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
  run_settled(nb)

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
  run_settled(nb)

  # Idle: a real reply.
  got_idle <- "unset"
  worker_query(nb, list(type = "signature", name = "lm", package = NULL), function(r) got_idle <<- r, timeout = HANG_GUARD)
  settle(nb, function(s) !identical(got_idle, "unset"))
  expect_match(got_idle$text, "^lm\\(formula, data")

  # Busy: NULL at once, not after waiting out the cell. The callback has
  # run by the time worker_query() returns, so no clock is needed.
  run_cells(nb, "A", wait = FALSE)
  settle(nb, function(s) identical(s$process, "busy"))
  got_busy <- "unset"
  worker_query(nb, list(type = "signature", name = "lm", package = NULL), function(r) got_busy <<- r)
  expect_null(got_busy)

  # A late reply (the busy cell finishes and the worker is asked again,
  # with a very short timeout) is dropped, not delivered twice, and
  # doesn't kill the worker. The poll is stopped while the 0 s timeout
  # fires: a poll already due (on a slow runner, or with no pipe watch, as
  # on Windows) would otherwise run first and could read the real reply
  # before the timeout (#402). Then the poll resumes and reads the reply,
  # whose query has timed out.
  settle(nb)
  late_calls <- 0L
  late_reply <- "unset"
  cancel_poll(nb)
  worker_query(nb, list(type = "signature", name = "lm", package = NULL),
              function(r) { late_calls <<- late_calls + 1L; late_reply <<- r }, timeout = 0)
  later::run_now(timeout = 0)
  expect_identical(late_calls, 1L)
  expect_null(late_reply)
  schedule_poll(nb)
  settle(nb)
  expect_false(is.null(nb$proc))

  # The worker is still alive and answers again: a fresh query, with no
  # short timeout this time, gets a real reply. The worker answers in
  # order on one socket, so the late reply has been read by then, and was
  # dropped.
  got_again <- "unset"
  worker_query(nb, list(type = "signature", name = "lm", package = NULL), function(r) got_again <<- r, timeout = HANG_GUARD)
  settle(nb, function(s) !identical(got_again, "unset"))
  expect_match(got_again$text, "^lm\\(formula, data")
  expect_identical(late_calls, 1L)

  # A worker exit fails every pending query. A real query's reply can beat
  # a kill() by a wide enough margin on a fast loopback that this can't be
  # driven through a real round trip deterministically (the bytes are
  # already on the socket before the process dies), so this registers
  # callbacks directly, the way `worker_query()` itself would, and checks
  # that an actual exit (not a manual call) clears them.
  settle(nb)
  got_a <- "unset"
  got_b <- "unset"
  assign("9001", function(r) got_a <<- r, envir = nb$queries)
  assign("9002", function(r) got_b <<- r, envir = nb$queries)
  nb$proc$kill()
  settle(nb, function(s) identical(s$process, "stopped"))
  expect_null(got_a)
  expect_null(got_b)
  expect_identical(length(ls(nb$queries)), 0L)
})

test_that("a worker that dies while idle is noticed at once, not at the next slow poll (#209)", {
  # The wake is the worker's stdout pipe closing; Windows pipes can't be
  # waited on, so there the poll still notices it.
  skip_on_os("windows")
  path <- write_session_notebook(list(S = cell(""), A = cell("x <- 1")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_settled(nb, NULL)
  expect_true(watch_worker_output(nb))

  # Nothing would poll for an hour: only the pipe can bring it forward.
  cancel_poll(nb)
  schedule_poll(nb, 3600)
  nb$proc$kill()
  settle(nb, function(s) identical(s$process, "stopped"))
  expect_null(nb$proc)
  expect_null(nb$output_watch)
})

test_that("a dependent of a failed cell runs on its own and reruns once the ancestor is fixed (ui-3 13)", {
  cells <- list(S = cell(""), A = cell('a <- 1; stop("boom")'), B = cell("a + 1"), C = cell('exists("a")'))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)

  run_settled(nb, NULL)
  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, "B")$status, "error")
  expect_equal(snap_view(snap, "B")$errors[[length(snap_view(snap, "B")$errors)]]$kind, "upstream")
  expect_equal(snap_view(snap, "C")$output$text, "[1] FALSE")

  edit_notebook(nb, set_code("A", "a <- 1"))
  run_settled(nb, "A")
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

  run_settled(nb, NULL)
  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, "B")$status, "ok")

  edit_notebook(nb, disable_cell("A"))
  on_disk <- read_file_utf8(path)
  expect_match(on_disk, "## x <- 1; library(tools)", fixed = TRUE)
  expect_match(on_disk, "## x \\+ 1")
  expect_match(on_disk, "# B commented", fixed = TRUE)

  run_settled(nb, "H")
  snap2 <- notebook_snapshot(nb)
  expect_equal(snap_view(snap2, "H")$output$text, "[1] FALSE FALSE")

  res <- system2(file.path(R.home("bin"), "Rscript"), shQuote(path), stdout = TRUE, stderr = TRUE)
  expect_equal(attr(res, "status") %||% 0, 0)

  b_before <- snap_view(snap2, "B")
  edit_notebook(nb, disable_cell("A", FALSE))
  run_settled(nb, "A")
  snap3 <- notebook_snapshot(nb)
  b_after <- snap_view(snap3, "B")
  expect_equal(b_after$status, "ok")
  # Not just "still ok" (it was never cleared): B actually reran, so its
  # stale flag is down and its run time has moved on.
  expect_false(isTRUE(b_after$stale))
  expect_true(b_after$last_run > b_before$last_run)
})

test_that("a worker busy in a long cell ends when the server that started it is killed (#147)", {
  use_installed_ember()
  pidfile <- tempfile("worker-pid-")
  path <- write_session_notebook(list(S = cell(""), A = cell(sprintf(
    "writeLines(as.character(Sys.getpid()), %s); Sys.sleep(300)", deparse(pidfile)))))
  code <- paste0("library(ember); nb <- open_notebook(", deparse(path), "); run_cells(nb, 'A'); ",
                 "repeat later::run_now(1)")
  server <- processx::process$new(file.path(R.home("bin"), "Rscript"), c("--vanilla", "-e", code),
                                  env = c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)),
                                  stdout = "|", stderr = "2>&1")
  on.exit(if (server$is_alive()) server$kill(), add = TRUE)
  # Until the cell is running, or the server has died.
  waiting_for("the cell to write its pid file", while (!file.exists(pidfile) && server$is_alive()) later::run_now(timeout = 0.05))
  # read_all_output() waits for the server to end, so a server still
  # running without the file is ended first.
  if (!file.exists(pidfile) && server$is_alive()) server$kill()
  expect_true(file.exists(pidfile), info = server$read_all_output())
  worker <- as.integer(readLines(pidfile))
  on.exit(tools::pskill(worker, tools::SIGKILL), add = TRUE)
  expect_true(pid_running(worker))

  # SIGKILL: no handler, no finalizer, nothing in the server runs.
  server$kill()

  expect_true(wait_pid_gone(worker))
})

#' A cell `name <- eval(parse(text = code))`: Ember's package scan can't
#' read inside the string, so `code` may name processx or callr without
#' the notebook resolving and installing them (helper-session.R's note).
#' The cell still defines `name`, for a later cell to depend on.
unscanned_cell <- function(name, code) {
  cell(sprintf("%s <- eval(parse(text = %s))", name, paste(deparse(code), collapse = "")))
}

test_that("a cell's processx child outlives a restart, also once the server collects the old worker (#232)", {
  # The old worker's process object ends its marked tree when collected;
  # the worker drops processx's marker so its cell's children aren't in it.
  pidfile <- tempfile("cell-pid-")
  libs <- paste(deparse(normalizePath(.libPaths(), winslash = "/")), collapse = "")
  rscript <- normalizePath(file.path(R.home("bin"), "Rscript"), winslash = "/", mustWork = FALSE)
  path <- write_session_notebook(list(S = cell(""), A = unscanned_cell("p", sprintf(paste0(
    ".libPaths(c(%s, .libPaths())); ",
    "p <- processx::process$new('%s', c('-e', 'Sys.sleep(300)')); ",
    "writeLines(as.character(c(Sys.getpid(), p$get_pid())), '%s'); p"),
    libs, rscript, normalizePath(pidfile, winslash = "/", mustWork = FALSE)))))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  # Nothing to resolve or install: the default cache stays untouched.
  expect_identical(nrow(notebook_snapshot(nb)$packages$packages), 0L)
  run_settled(nb, "A")
  expect_identical(snap_view(notebook_snapshot(nb), "A")$status, "ok")
  pids <- as.integer(readLines(pidfile))
  on.exit(tools::pskill(pids[2]), add = TRUE)
  expect_true(pid_running(pids[2]))

  restart_notebook(nb)
  invisible(gc())

  expect_true(wait_pid_gone(pids[1]))  # the old worker
  expect_true(pid_running(pids[2]))    # the cell's processx child
})

#' On Windows, a cell that starts three children, each `Sys.sleep(300)`: one
#' with `processx::process$new()`, one with `callr::r_bg()` (both with their
#' default `cleanup = TRUE`) and one with `system2(wait = FALSE)`, which
#' writes its own pid. The cell writes the worker's pid and the three
#' children's to `pidfile`, and finishes, defining `a` as the two process
#' objects (`unscanned_cell()`). The worker's library doesn't have
#' processx and callr, so the cell uses this R's.
windows_children_cell <- function(pidfile) {
  rscript <- normalizePath(file.path(R.home("bin"), "Rscript.exe"), winslash = "/")
  sys_pidfile <- normalizePath(paste0(pidfile, ".sys"), winslash = "/", mustWork = FALSE)
  libs <- paste(deparse(normalizePath(.libPaths(), winslash = "/")), collapse = "")
  unscanned_cell("a", sprintf(paste0(
    ".libPaths(c(%1$s, .libPaths())); ",
    "a <- processx::process$new('%2$s', c('-e', 'Sys.sleep(300)')); ",
    "b <- callr::r_bg(function() Sys.sleep(300)); ",
    "system2('%2$s', c('-e', shQuote(\"writeLines(as.character(Sys.getpid()), '%3$s.tmp'); file.rename('%3$s.tmp', '%3$s'); Sys.sleep(300)\")), wait = FALSE); ",
    "while (!file.exists('%3$s')) Sys.sleep(0.05); ",
    "writeLines(as.character(c(Sys.getpid(), a$get_pid(), b$get_pid(), readLines('%3$s'))), '%4$s.tmp'); ",
    "file.rename('%4$s.tmp', '%4$s'); list(a, b)"),
    libs, rscript, sys_pidfile, normalizePath(pidfile, winslash = "/", mustWork = FALSE)))
}

test_that("on Windows a cell's processx and callr children outlive a restart; its system() child doesn't (#208)", {
  skip_on_os(c("mac", "linux", "solaris"))
  pidfile <- tempfile("cell-pids-")
  path <- write_session_notebook(list(S = cell(""), A = windows_children_cell(pidfile)))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  # The worker releases processx's job before it says a run is done.
  run_settled(nb, "A")
  expect_identical(snap_view(notebook_snapshot(nb), "A")$status, "ok")
  pids <- as.integer(readLines(pidfile))
  on.exit(for (p in pids[-1]) tools::pskill(p), add = TRUE)
  expect_true(all(vapply(pids, pid_running, logical(1))))

  restart_notebook(nb)
  # Collecting the old worker's process object runs its finalizer, which
  # ends the tree processx marked as the worker's (#232).
  invisible(gc())

  expect_true(wait_pid_gone(pids[1]))  # the old worker
  expect_true(wait_pid_gone(pids[4]))  # system2()'s child
  expect_true(pid_running(pids[2]))    # processx's
  expect_true(pid_running(pids[3]))    # callr's
})

test_that("on Windows a busy worker's processx and callr children outlive a killed server; its system() child doesn't (#208)", {
  skip_on_os(c("mac", "linux", "solaris"))
  use_installed_ember()
  pidfile <- tempfile("cell-pids-")
  marker <- normalizePath(tempfile("busy-"), winslash = "/", mustWork = FALSE)
  # A starts the children and finishes. B uses A's `a`, so it runs after
  # A, and is busy when the server is killed. Once B has begun, A's
  # children have been released.
  path <- write_session_notebook(list(S = cell(""), A = windows_children_cell(pidfile),
                                      B = cell(sprintf("a; writeLines('x', '%s'); Sys.sleep(300)", marker))))
  code <- paste0("library(ember); nb <- open_notebook(", deparse(path), "); run_cells(nb, c('A', 'B')); ",
                 "repeat later::run_now(1)")
  server <- processx::process$new(file.path(R.home("bin"), "Rscript"), c("--vanilla", "-e", code),
                                  env = c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)),
                                  stdout = "|", stderr = "2>&1")
  on.exit(if (server$is_alive()) server$kill(), add = TRUE)
  waiting_for("the cell to write its marker", while (!file.exists(marker) && server$is_alive()) later::run_now(timeout = 0.05))
  # read_all_output() waits for the server to end, so a server still
  # running without the file is ended first.
  if (!file.exists(marker) && server$is_alive()) server$kill()
  expect_true(file.exists(marker), info = server$read_all_output())
  pids <- as.integer(readLines(pidfile))
  on.exit(for (p in pids) tools::pskill(p), add = TRUE)
  expect_true(all(vapply(pids, pid_running, logical(1))))

  server$kill()

  expect_true(wait_pid_gone(pids[1]))  # the worker
  expect_true(wait_pid_gone(pids[4]))  # system2()'s child
  expect_true(pid_running(pids[2]))    # processx's
  expect_true(pid_running(pids[3]))    # callr's
})

test_that("on Windows a busy cell's own processx and callr children outlive a killed server (#274)", {
  # Released by the worker's thread while the cell still runs, not by the
  # release after a run: the cell waits until that has happened
  # (`C_cell_children_released()`, test-only) and only then says it's busy.
  skip_on_os(c("mac", "linux", "solaris"))
  use_installed_ember()
  pidfile <- normalizePath(tempfile("cell-pids-"), winslash = "/", mustWork = FALSE)
  rscript <- normalizePath(file.path(R.home("bin"), "Rscript.exe"), winslash = "/")
  libs <- paste(deparse(normalizePath(.libPaths(), winslash = "/")), collapse = "")
  path <- write_session_notebook(list(S = cell(""), A = unscanned_cell("a", sprintf(paste0(
    ".libPaths(c(%1$s, .libPaths())); ",
    "a <- processx::process$new('%2$s', c('-e', 'Sys.sleep(300)')); ",
    "b <- callr::r_bg(function() Sys.sleep(300)); ",
    "while (!.Call(getNativeSymbolInfo('C_cell_children_released', 'ember'))) Sys.sleep(0.05); ",
    "writeLines(as.character(c(Sys.getpid(), a$get_pid(), b$get_pid())), '%3$s.tmp'); ",
    "file.rename('%3$s.tmp', '%3$s'); Sys.sleep(300); list(a, b)"),
    libs, rscript, pidfile))))
  code <- paste0("library(ember); nb <- open_notebook(", deparse(path), "); run_cells(nb, 'A'); ",
                 "repeat later::run_now(1)")
  server <- processx::process$new(file.path(R.home("bin"), "Rscript"), c("--vanilla", "-e", code),
                                  env = c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)),
                                  stdout = "|", stderr = "2>&1")
  on.exit(if (server$is_alive()) server$kill(), add = TRUE)
  waiting_for("the cell to write its pid file", while (!file.exists(pidfile) && server$is_alive()) later::run_now(timeout = 0.05))
  # read_all_output() waits for the server to end, so a server still
  # running without the file is ended first.
  if (!file.exists(pidfile) && server$is_alive()) server$kill()
  expect_true(file.exists(pidfile), info = server$read_all_output())
  pids <- as.integer(readLines(pidfile))
  on.exit(for (p in pids) tools::pskill(p), add = TRUE)
  expect_true(all(vapply(pids, pid_running, logical(1))))

  server$kill()

  expect_true(wait_pid_gone(pids[1]))  # the worker
  expect_true(pid_running(pids[2]))    # processx's
  expect_true(pid_running(pids[3]))    # callr's
})

test_that("on Windows a cell's first processx child outlives a server killed right after it starts (#235)", {
  skip_on_os(c("mac", "linux", "solaris"))
  use_installed_ember()
  pidfile <- normalizePath(tempfile("cell-pids-"), winslash = "/", mustWork = FALSE)
  rscript <- normalizePath(file.path(R.home("bin"), "Rscript.exe"), winslash = "/")
  libs <- paste(deparse(normalizePath(.libPaths(), winslash = "/")), collapse = "")
  # The worker's first processx child, and the cell stays busy: the server
  # is killed as soon as the pids are written, well inside the half second
  # the worker's thread takes to find a job made only now.
  path <- write_session_notebook(list(S = cell(""), A = unscanned_cell("a", sprintf(paste0(
    ".libPaths(c(%1$s, .libPaths())); ",
    "a <- processx::process$new('%2$s', c('-e', 'Sys.sleep(300)')); ",
    "writeLines(as.character(c(Sys.getpid(), a$get_pid())), '%3$s.tmp'); ",
    "file.rename('%3$s.tmp', '%3$s'); Sys.sleep(300)"),
    libs, rscript, pidfile))))
  code <- paste0("library(ember); nb <- open_notebook(", deparse(path), "); run_cells(nb, 'A'); ",
                 "repeat later::run_now(1)")
  server <- processx::process$new(file.path(R.home("bin"), "Rscript"), c("--vanilla", "-e", code),
                                  env = c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)),
                                  stdout = "|", stderr = "2>&1")
  on.exit(if (server$is_alive()) server$kill(), add = TRUE)
  waiting_for("the cell to write its pid file", while (!file.exists(pidfile) && server$is_alive()) later::run_now(timeout = 0.01))
  # read_all_output() waits for the server to end, so a server still
  # running without the file is ended first.
  if (!file.exists(pidfile) && server$is_alive()) server$kill()
  expect_true(file.exists(pidfile), info = server$read_all_output())
  server$kill()
  pids <- as.integer(readLines(pidfile))
  on.exit(for (p in pids) tools::pskill(p), add = TRUE)

  expect_true(wait_pid_gone(pids[1]))  # the worker
  expect_true(pid_running(pids[2]))    # processx's
})

test_that("what a busy cell started with system() ends when the server is killed (#150)", {
  # `sleep &` and `$!` need sh; the Windows tests above cover Windows.
  skip_on_os("windows")
  use_installed_ember()
  pidfile <- tempfile("cell-pids-")
  # The child's pid and the worker's, written to a temporary name and
  # renamed, so the test never reads half a file.
  path <- write_session_notebook(list(S = cell(""), A = cell(sprintf(paste0(
    "child <- system('sleep 300 > /dev/null 2>&1 & echo $!', intern = TRUE); ",
    "writeLines(c(Sys.getpid(), child), %1$s); file.rename(%1$s, %2$s); Sys.sleep(300)"),
    deparse(paste0(pidfile, ".tmp")), deparse(pidfile)))))
  code <- paste0("library(ember); nb <- open_notebook(", deparse(path), "); run_cells(nb, 'A'); ",
                 "repeat later::run_now(1)")
  server <- processx::process$new(file.path(R.home("bin"), "Rscript"), c("--vanilla", "-e", code),
                                  env = c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)),
                                  stdout = "|", stderr = "2>&1")
  on.exit(if (server$is_alive()) server$kill(), add = TRUE)
  # Until the cell is running, or the server has died.
  waiting_for("the cell to write its pid file", while (!file.exists(pidfile) && server$is_alive()) later::run_now(timeout = 0.05))
  # read_all_output() waits for the server to end, so a server still
  # running without the file is ended first.
  if (!file.exists(pidfile) && server$is_alive()) server$kill()
  expect_true(file.exists(pidfile), info = server$read_all_output())
  pids <- as.integer(readLines(pidfile))
  on.exit(for (p in pids) tools::pskill(p, tools::SIGKILL), add = TRUE)
  expect_true(all(vapply(pids, pid_running, logical(1))))

  # SIGKILL: no handler, no finalizer, nothing in the server runs.
  server$kill()

  expect_true(wait_pid_gone(pids[1]))  # the worker
  expect_true(wait_pid_gone(pids[2]))  # what its cell started
})

test_that("closing or restarting a notebook removes the stopped worker's temp folder (#166)", {
  cells <- list(S = cell(""), A = cell("writeLines('x', file.path(tempdir(), 'kept.txt')); tempdir()"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path)
  closed <- FALSE
  on.exit(if (!closed) close_notebook(nb), add = TRUE)
  worker_tmp <- function() {
    run_settled(nb, "A")
    eval(parse(text = sub("^\\[1\\] ", "", snap_view(notebook_snapshot(nb), "A")$output$text)))
  }

  first <- worker_tmp()
  expect_true(file.exists(file.path(first, "kept.txt")))
  restart_notebook(nb)
  expect_false(dir.exists(first))

  second <- worker_tmp()
  expect_false(identical(second, first))
  expect_true(dir.exists(second))
  close_notebook(nb)
  closed <- TRUE
  expect_false(dir.exists(second))
})

test_that("worker_tempdir() keeps only an existing R temp folder that isn't the server's own (#166)", {
  d <- file.path(tempfile("ember-"), "RtmpAbC123")
  dir.create(d, recursive = TRUE)
  on.exit(unlink(dirname(d), recursive = TRUE), add = TRUE)
  expect_identical(worker_tempdir(d), d)
  expect_null(worker_tempdir(tempdir()))
  expect_null(worker_tempdir(dirname(d)))
  expect_null(worker_tempdir(file.path(dirname(d), "RtmpMissing")))
  expect_null(worker_tempdir(NULL))
  expect_null(worker_tempdir(c(d, d)))
})

# check_data_files() on a stand-in notebook: its folder, the shell's record
# of d.csv, and the events it sends.
data_check_nb <- function(running = NULL, touch = NULL) {
  dir <- normalizePath(tempfile("ember-check-"), winslash = "/", mustWork = FALSE)
  dir.create(dir)
  nb <- new.env()
  nb$state <- list(path = file.path(dir, "nb.R"), worker = list(running = running),
                   graph = list(analyses = list(W = list(data_touch = touch))))
  nb$data_watch <- list("d.csv" = list(mtime = NA, size = NA, hash = NA_character_))
  nb$sent <- list()
  nb$send <- function(nb, ev) nb$sent[[length(nb$sent) + 1]] <- ev
  nb$file <- file.path(dir, "d.csv")
  nb
}

test_that("a data file whose size changes within one clock tick is still a change (#405)", {
  nb <- data_check_nb()
  writeLines("", nb$file, sep = "")
  t <- as.POSIXct("2026-01-01 00:00:00", tz = "UTC")
  Sys.setFileTime(nb$file, t)
  check_data_files(nb, nb$send)
  expect_length(nb$sent, 1)
  # The write finishes with the same modified time as the look that found it empty.
  writeLines("1,2", nb$file)
  Sys.setFileTime(nb$file, t)
  check_data_files(nb, nb$send)
  expect_length(nb$sent, 2)
  expect_identical(nb$data_watch[["d.csv"]]$size, file.info(nb$file)$size)
})

test_that("the poll leaves a file the running cell writes to the check at the run's end (#405)", {
  touch <- data.frame(path = "d.csv", index = 1L, read = FALSE, stringsAsFactors = FALSE)
  nb <- data_check_nb(running = list(cell = "W"), touch = touch)
  writeLines("1,2", nb$file)
  expect_identical(running_writes(nb$state), "d.csv")
  check_data_files(nb, nb$send, skip = running_writes(nb$state))
  expect_length(nb$sent, 0)
  check_data_files(nb, nb$send)
  expect_length(nb$sent, 1)
  # A write to a computed path may be any file.
  nb$state$graph$analyses$W$data_touch$path <- NA_character_
  expect_identical(running_writes(nb$state), NA_character_)
  nb$state$worker$running <- NULL
  expect_identical(running_writes(nb$state), character())
})

test_that("the poll's skip matches a running writer's file however its path is spelled (#405)", {
  touch <- data.frame(path = "./d.csv", index = 1L, read = FALSE, stringsAsFactors = FALSE)
  nb <- data_check_nb(running = list(cell = "W"), touch = touch)
  writeLines("1,2", nb$file)
  check_data_files(nb, nb$send, skip = running_writes(nb$state))
  expect_length(nb$sent, 0)
})

test_that("a look that found the file cut short doesn't cost the next same-bytes rewrite a rerun (#405)", {
  nb <- data_check_nb()
  at <- function(s) as.POSIXct("2026-01-01 00:00:00", tz = "UTC") + s
  put <- function(text, s) { writeLines(text, nb$file, sep = ""); Sys.setFileTime(nb$file, at(s)) }
  put("1,2\n", 1); check_data_files(nb, nb$send)
  put("1,2\n", 2); check_data_files(nb, nb$send)   # the first same-size rewrite has no hash to compare
  expect_length(nb$sent, 2)
  # A writer the skip can't see: one look mid-write, then the finished file
  # in the same clock tick. Both are changes (a reader may have read the
  # short file), and the hash is kept.
  put("", 3); check_data_files(nb, nb$send)
  put("1,2\n", 3); check_data_files(nb, nb$send)
  expect_length(nb$sent, 4)
  put("1,2\n", 4); check_data_files(nb, nb$send)
  expect_length(nb$sent, 4)
})

# ---- Prompts (#186) ------------------------------------------------------------

#' Run `id` and wait until its prompt shows; returns the prompt.
run_until_prompt <- function(nb, id) {
  run_cells(nb, id, wait = FALSE)
  settle(nb, function(s) !is.null(snap_view(s, id)$prompt), sprintf("%s's prompt to show", id))
  snap_view(notebook_snapshot(nb), id)$prompt
}

console_text <- function(view) paste(vapply(view$console, function(i) i$text, character(1)), collapse = "")

test_that("a cell runs with interactive() TRUE, as in an R console (#186)", {
  path <- write_session_notebook(list(S = cell(""), A = cell("interactive()")))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_settled(nb, "A")
  expect_match(snap_view(notebook_snapshot(nb), "A")$output$text, "TRUE", fixed = TRUE)
})

test_that("an interactive worker still draws to pdf and doesn't offer installs (#186)", {
  # With a display named, an interactive R's default device would be X11 (a
  # window, or an error without a server); Ember keeps Rscript's pdf.
  old <- Sys.getenv("DISPLAY", unset = NA)
  Sys.setenv(DISPLAY = ":99")
  on.exit(if (is.na(old)) Sys.unsetenv("DISPLAY") else Sys.setenv(DISPLAY = old), add = TRUE)
  code <- 'grDevices::dev.new(); plot(1); grDevices::dev.off()\nc(identical(getOption("device"), grDevices::pdf), isFALSE(getOption("rlib_restart_package_not_found")))'
  path <- write_session_notebook(list(S = cell(""), A = cell(code)))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_settled(nb, "A")
  view <- snap_view(notebook_snapshot(nb), "A")
  expect_equal(view$status, "ok")
  expect_match(view$output$text, "TRUE TRUE", fixed = TRUE)
})

test_that("readline() in a cell waits for the answer and the cell carries on with it (#186)", {
  path <- write_session_notebook(list(S = cell(""), A = cell('cat("Before\\n")\nname <- readline("Name? ")\ncat("Hello", name, "\\n")')))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  prompt <- run_until_prompt(nb, "A")
  expect_equal(prompt$text, "Name? ")
  expect_null(prompt$choices)
  view <- snap_view(notebook_snapshot(nb), "A")
  expect_true(view$running)
  # What the cell printed before it asked is shown above the question.
  expect_match(console_text(view), "Before", fixed = TRUE)

  answer_input(nb, "Ada", cell = "A")
  settle(nb, function(s) identical(s$process, "ready"))
  view <- snap_view(notebook_snapshot(nb), "A")
  expect_equal(view$status, "ok")
  expect_null(view$prompt)
  # The transcript reads as an R console's: the question, then the answer.
  expect_match(console_text(view), "Before\nName? Ada\nHello Ada", fixed = TRUE)
  # Nothing waits now.
  expect_error(answer_input(nb, "again"), "no prompt is waiting", class = "ember_refused")
})

test_that("menu() offers its choices and takes a number or a choice; askYesNo() asks too (#186)", {
  code <- 'pick <- menu(c("red", "blue"), title = "Colour")\nok <- askYesNo("Go on?")\nc(pick, ok)'
  path <- write_session_notebook(list(S = cell(""), A = cell(code)))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  prompt <- run_until_prompt(nb, "A")
  expect_equal(prompt$text, "Selection: ")
  expect_equal(unlist(prompt$choices), c("red", "blue"))
  # Not a choice: menu() asks again, as R's does.
  answer_input(nb, "green")
  settle(nb, function(s) {
    p <- snap_view(s, "A")$prompt
    !is.null(p) && grepl("Enter an item", console_text(snap_view(s, "A")), fixed = TRUE)
  })
  answer_input(nb, "blue")
  settle(nb, function(s) identical(snap_view(s, "A")$prompt$text, "Go on? (Yes/no/cancel) "))
  answer_input(nb, "no")
  settle(nb, function(s) identical(s$process, "ready"))
  view <- snap_view(notebook_snapshot(nb), "A")
  expect_equal(view$status, "ok")
  expect_match(view$output$text, "2 0", fixed = TRUE)
  expect_match(console_text(view), "Colour \n\n1: red\n2: blue\n\nSelection: green\n", fixed = TRUE)
})

test_that("interrupting a cell that waits on a prompt stops it, and the prompt goes (#186)", {
  path <- write_session_notebook(list(S = cell(""), A = cell('x <- readline("Wait? ")')))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_until_prompt(nb, "A")
  interrupt_notebook(nb)
  settle(nb, function(s) identical(s$process, "ready"))
  view <- snap_view(notebook_snapshot(nb), "A")
  expect_equal(view$status, "interrupted")
  expect_null(view$prompt)
  expect_error(answer_input(nb, "late"), class = "ember_refused")
})

test_that("a prompt whose interrupt the cell catches closes, and the cell's next prompt is answered (#186)", {
  skip_on_os("windows")
  code <- 'a <- tryCatch(readline("First? "), interrupt = function(i) "stopped")\nb <- readline("Second? ")\npaste(a, b)'
  path <- write_session_notebook(list(S = cell(""), A = cell(code)))
  nb <- open_notebook(path)
  on.exit(close_notebook(nb), add = TRUE)
  run_until_prompt(nb, "A")
  # SIGINT straight to the worker, as the server interrupts on Unix, but
  # without clearing the run: the cell catches it and asks again.
  tools::pskill(nb$proc$get_pid(), tools::SIGINT)
  settle(nb, function(s) identical(snap_view(s, "A")$prompt$text, "Second? "))
  answer_input(nb, "two")
  settle(nb, function(s) identical(s$process, "ready"))
  expect_match(snap_view(notebook_snapshot(nb), "A")$output$text, "stopped two", fixed = TRUE)
})
