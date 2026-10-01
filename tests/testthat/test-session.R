# End to end: the R API with a real worker, through the shell. No package
# installs (`library = NULL`): every notebook cell here is base R only.
# Waits use `wait_for()`/`run_cells(wait = TRUE)`, never `Sys.sleep`.
#
# Covers engine-tests.md items 106-117 ("End to end").

test_that("open_notebook starts no process; the snapshot is preview (106)", {
  path <- write_session_notebook(list(S = cell("")))
  nb <- open_notebook(path, library = NULL)
  on.exit(close_notebook(nb), add = TRUE)

  expect_null(nb$proc)
  snap <- notebook_snapshot(nb)
  expect_equal(snap$process, "preview")
  expect_false(snap$allowed)
})

test_that("run_cells(wait = TRUE) runs every cell with the expected outputs (107)", {
  cells <- list(S = cell(""), A = cell("x <- 21"), B = cell("y <- x * 2"), C = cell("y + 1"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path, library = NULL)
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
  nb <- open_notebook(path, library = NULL)
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
  nb <- open_notebook(path, library = NULL)
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
  nb <- open_notebook(path, library = NULL)
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

test_that("a learned definition from load() is saved in the footer and orders cells on reopen (111)", {
  dir <- tempfile("ember-nb-")
  dir.create(dir, recursive = TRUE)
  rdata_path <- file.path(dir, "fits.RData")
  fits <- 42
  save(fits, file = rdata_path)

  cells <- list(S = cell(""), A = cell(sprintf("load(%s)", deparse(rdata_path))),
               B = cell("fits + 1"))
  path <- write_session_notebook(cells, dir = dir)
  nb <- open_notebook(path, library = NULL)
  on.exit(close_notebook(nb), add = TRUE)

  res <- run_cells(nb, wait = TRUE, timeout = 20)
  expect_false(res$timed_out)
  snap <- notebook_snapshot(nb)
  expect_equal(snap_view(snap, "B")$output$text, "[1] 43")

  file_text <- read_file_utf8(path)
  expect_match(file_text, "learned definitions")
  expect_match(file_text, "fits")

  close_notebook(nb)
  nb2 <- open_notebook(path, library = NULL)
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

  nb <- open_notebook(path, library = NULL)
  close_notebook(nb)

  after_bytes <- readBin(path, "raw", file.info(path)$size)
  after_mtime <- file.info(path)$mtime
  expect_identical(before_bytes, after_bytes)
  expect_equal(before_mtime, after_mtime)
})

test_that("interrupting a stuck cell offers a restart after the grace period (113)", {
  so <- compile_stuck_lib()
  skip_if(is.null(so), "could not compile the stuck.c fixture (no compiler available)")

  # dyn.load() happens in the setup cell, run before A: a top-level
  # statement next to the .Call() gives R a safe point to notice the
  # interrupt between the two, before the stuck C loop (which never calls
  # R_CheckUserInterrupt()) is even entered.
  cells <- list(S = cell(sprintf("dyn.load(%s)", deparse(so))),
               A = cell('.Call("stuck", 6L)'))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path, library = NULL)
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
  nb <- open_notebook(path, library = NULL)
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
  nb <- open_notebook(path, library = NULL)
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
  nb2 <- open_notebook(path2, library = NULL)
  on.exit(close_notebook(nb2), add = TRUE)
  run_cells(nb2, wait = TRUE, timeout = 20)
  png <- render_png(nb2, "P")
  expect_equal(png$mime, "image/png")
  expect_true(is.raw(png$png))
})

test_that("two consecutive notebook_state() values share unchanged cells (116)", {
  cells <- list(S = cell(""), A = cell("1"), B = cell("2"))
  path <- write_session_notebook(cells)
  nb <- open_notebook(path, library = NULL)
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
  nb <- open_notebook(path, library = NULL)
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
  expect_lt(max(gaps), 0.05)
})

test_that("worker_output_pipe_drained", {
  path <- tempfile(fileext = ".R")
  nb <- new_notebook(path)
  on.exit(close_notebook(nb))
  edit_notebook(nb, set_code(2, 'for (i in 1:2000) system2("echo", strrep("x", 100)); 1'))
  run_cells(nb, wait = TRUE, timeout = 30)
  expect_identical(notebook_snapshot(nb)$cells[[2]]$status, "ok")
})
