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

# ---- review4 item 3: secrets and ports from the OS random source -------------

test_that("random_secret() reads the OS random source, not R's generator (review4 3)", {
  seed_before <- { set.seed(42); get(".Random.seed", envir = .GlobalEnv) }
  s1 <- random_secret(32)
  seed_after <- get(".Random.seed", envir = .GlobalEnv)
  expect_identical(seed_before, seed_after)

  # Two secrets drawn right after the same set.seed() must differ: a
  # sample()-based secret would be identical both times, which is exactly
  # what makes it guessable once an attacker knows the seed.
  set.seed(42); s2 <- random_secret(32)
  set.seed(42); s3 <- random_secret(32)
  expect_false(identical(s2, s3))
  expect_equal(nchar(s1), 32)
})

test_that("random_port() doesn't touch .Random.seed either (review4 3)", {
  set.seed(1)
  seed_before <- get(".Random.seed", envir = .GlobalEnv)
  p <- random_port()
  expect_identical(get(".Random.seed", envir = .GlobalEnv), seed_before)
  expect_true(p >= 20000L && p <= 59999L)
})
