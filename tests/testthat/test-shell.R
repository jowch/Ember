# Shell pieces (R/shell.R): framing, the wire-to-event boundary, atomic
# writes, and drain's non-reentrancy. No worker process.
#
# Covers engine-tests.md items 76-82 ("Shell pieces").

#' One wire frame's bytes: 4-byte big-endian length, then `serialize()`.
make_frame <- function(msg) {
  payload <- serialize(msg, NULL)
  c(writeBin(length(payload), raw(0), endian = "big"), payload)
}

test_that("a frame split across 1-byte chunks comes out once, whole (76)", {
  msg <- list(type = "hello", secret = "s", pid = 1L)
  bytes <- make_frame(msg)
  chunks <- lapply(seq_along(bytes), function(i) bytes[i])
  rx <- list(chunks = chunks, n = length(bytes))

  result <- take_frames(rx)

  expect_length(result$messages, 1)
  expect_equal(result$messages[[1]], msg)
  expect_equal(result$rx$n, 0)
  expect_length(result$rx$chunks, 0)
})

test_that("take_frames leaves a trailing partial frame buffered", {
  msg1 <- list(type = "a")
  msg2 <- list(type = "b")
  frame1 <- make_frame(msg1)
  frame2 <- make_frame(msg2)
  cut <- length(frame1) + length(frame2) - 3L  # cut partway through the second frame
  rx <- list(chunks = list(c(frame1, frame2)[1:cut]), n = cut)

  result <- take_frames(rx)

  expect_length(result$messages, 1)
  expect_equal(result$messages[[1]], msg1)
  expect_equal(result$rx$n, cut - length(frame1))
})

test_that("three frames in one chunk give three messages in order (77)", {
  msgs <- list(list(type = "a"), list(type = "b"), list(type = "c"))
  bytes <- do.call(c, lapply(msgs, make_frame))
  rx <- list(chunks = list(bytes), n = length(bytes))

  result <- take_frames(rx)

  expect_equal(result$messages, msgs)
  expect_equal(result$rx$n, 0)
})

test_that("a 20 MB frame in 64 KB chunks is joined once (78)", {
  make_rx <- function(payload_size) {
    msg <- list(type = "x", data = as.raw(rep(1:250, length.out = payload_size)))
    bytes <- make_frame(msg)
    chunk_size <- 65536L
    starts <- seq(1, length(bytes), by = chunk_size)
    chunks <- lapply(starts, function(s) bytes[s:min(s + chunk_size - 1, length(bytes))])
    list(chunks = chunks, n = length(bytes))
  }

  small <- make_rx(2e6)
  big <- make_rx(16e6)

  t_small <- system.time(r_small <- take_frames(small))[["elapsed"]]
  t_big <- system.time(r_big <- take_frames(big))[["elapsed"]]

  expect_length(r_small$messages, 1)
  expect_length(r_big$messages, 1)
  expect_equal(r_small$messages[[1]]$type, "x")
  # Linear, not quadratic: a floor keeps this from being flaky on a noisy
  # machine where both times are tiny.
  expect_lt(t_big, t_small * 20 + 0.5)
})

test_that("a message with a missing field becomes wk_failed (79)", {
  ev <- worker_event(list(type = "done", cell = "a"), gen = 1L, at = 0)
  expect_equal(ev$type, "wk_failed")
  expect_match(ev$message, "protocol error")

  ev2 <- worker_event(list(type = "sometype_nonsense"), gen = 1L, at = 0)
  expect_equal(ev2$type, "wk_failed")
})

test_that("a hello with the wrong secret is rejected (80)", {
  ev <- worker_event(list(type = "hello", secret = "wrong", pid = 1L),
                     gen = 1L, at = 0, secret = "right")
  expect_equal(ev$type, "wk_failed")
  expect_match(ev$message, "secret")

  ok <- worker_event(list(type = "hello", secret = "right", pid = 1L),
                     gen = 1L, at = 0, secret = "right")
  expect_equal(ok$type, "wk_hello")
})

test_that("the old file is intact if the write fails midway (81)", {
  dir <- tempfile("ember-write-")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  path <- file.path(dir, "nb.R")
  writeLines("original", path)

  Sys.chmod(dir, "0555")
  on.exit(Sys.chmod(dir, "0755"), add = TRUE)
  if (file.access(dir, 2) == 0) {
    skip("cannot make a directory unwritable in this environment (likely running as root)")
  }

  ok <- write_atomic(path, "new text\n")

  expect_false(ok)
  expect_equal(readLines(path), "original")
})

test_that("write_atomic replaces the file when it succeeds", {
  dir <- tempfile("ember-write-ok-")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  path <- file.path(dir, "nb.R")
  writeLines("original", path)

  ok <- write_atomic(path, "replacement text")

  expect_true(ok)
  expect_equal(read_file_utf8(path), "replacement text")
  # No leftover temp files.
  expect_equal(list.files(dir), "nb.R")
})

test_that("an effect that enqueues an event is handled in the same drain (82)", {
  nb <- new.env()
  nb$inbox <- list()
  nb$draining <- FALSE
  nb$state <- structure(list(closed = FALSE, seq = 0L), class = "ember_state")
  nb$saved <- FALSE
  nb$listeners <- list()
  nb$closing <- FALSE
  nb$watch <- list()

  seen <- character()
  testthat::local_mocked_bindings(
    step = function(state, event) {
      seen <<- c(seen, event$type)
      if (identical(event$type, "first")) {
        list(state = state, effects = list(list(type = "trigger")), reply = "first-reply")
      } else {
        list(state = state, effects = list(), reply = "second-reply")
      }
    },
    save_if_changed = function(nb) invisible(NULL),
    notifications = function(old, new) list(),
    watched_files = function(state) character(),
    sync_watch = function(nb, paths) invisible(NULL),
    run_effect = function(nb, fx) {
      if (identical(fx$type, "trigger")) enqueue(nb, list(type = "second"))
    },
    .package = "ember"
  )

  reply <- dispatch(nb, list(type = "first"))

  expect_equal(seen, c("first", "second"))
  expect_equal(reply, "first-reply")
})

test_that("an install failure names what failed to build", {
  lines <- c("Installing cli ...", "cleancall.c:39:28: error: ...",
             "ERROR: compilation failed for package 'cli'",
             "Error: failed to install \"cli\", \"dplyr\"", "Execution halted")
  msg <- install_failure_message(lines, 1L)
  expect_match(msg, "compilation failed for package 'cli'", fixed = TRUE)
  expect_match(msg, "failed to install \"cli\", \"dplyr\"", fixed = TRUE)
  expect_identical(install_failure_message("no reason given", 2L), "install failed, status 2")
})
