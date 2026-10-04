# Test-only helpers for test-worker.R: a harness that starts the real
# inst/worker.R with processx and exchanges wire frames with it over a
# real socket. No server and no `later`; every wait has a deadline (see
# wait_socket()).

#' The package root, from testthat's working directory
#' (tests/testthat while tests run).
ember_package_root <- function() {
  normalizePath(file.path(testthat::test_path(), "..", ".."), mustWork = TRUE)
}

worker_script_path <- function() {
  installed <- system.file("worker.R", package = "ember")
  if (nzchar(installed)) return(installed)
  normalizePath(file.path(ember_package_root(), "inst", "worker.R"), mustWork = TRUE)
}

#' A free TCP port. serverSocket(0) doesn't report the port it got (the
#' spike's README notes this), so a port is picked first and retried if
#' it's taken.
open_server_socket <- function(tries = 30) {
  for (i in seq_len(tries)) {
    port <- sample(20000:59999, 1)
    s <- tryCatch(serverSocket(port), error = function(e) NULL)
    if (!is.null(s)) return(list(socket = s, port = port))
  }
  stop("could not find a free port after ", tries, " tries")
}

# ---- Fixture packages (tests/testthat/fixtures/*) -----------------------------
#
# emberfix1 exports shared_fun()/fix1_fun(), and sets an option in both
# .onLoad and .onAttach. emberfix2 exports shared_fun()/fix2_fun() (same
# name as emberfix1's, for masking-order tests) and sets nothing. Built
# once per test session into a cached temp library.

fixture_lib_cache <- new.env()

#' Path to a library containing the built & installed fixture packages.
#' Cached: the install (an R CMD INSTALL subprocess) runs once.
fixture_lib <- function() {
  if (!is.null(fixture_lib_cache$path) && dir.exists(fixture_lib_cache$path)) {
    return(fixture_lib_cache$path)
  }
  lib <- file.path(tempdir(), "ember-fixture-lib")
  dir.create(lib, showWarnings = FALSE, recursive = TRUE)
  fixtures_dir <- normalizePath(testthat::test_path("fixtures"), mustWork = TRUE)
  pkgs <- list.dirs(fixtures_dir, recursive = FALSE)
  r_bin <- file.path(R.home("bin"), "R")
  res <- processx::run(r_bin,
    c("CMD", "INSTALL", "--no-byte-compile", "--no-help", "--no-docs",
      "--no-test-load", paste0("--library=", lib), pkgs),
    error_on_status = FALSE, timeout = 180)
  if (res$status != 0) {
    stop("failed to install worker test fixtures:\n", res$stdout, "\n", res$stderr)
  }
  fixture_lib_cache$path <- lib
  lib
}

# ---- The harness ----------------------------------------------------------------

#' Wait until `sock` is readable or `deadline` passes.
#'
#' Polls with `timeout = 0`: once `later` has run callbacks in this
#' process (the session tests do), `socketSelect()` with a positive
#' timeout returns FALSE at once instead of waiting (R 4.6.1, later
#' 1.4.8), while a zero timeout still reports readiness correctly.
wait_socket <- function(sock, deadline) {
  repeat {
    if (isTRUE(socketSelect(list(sock), timeout = 0))) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(0.002)
  }
}

#' Read one wire frame (4-byte big-endian length, then a serialized R
#' value) off `con`, waiting at most `timeout` seconds in total.
#' Returns NULL on timeout or if the connection closed.
read_frame <- function(con, timeout) {
  deadline <- Sys.time() + timeout
  wait_readable <- function() wait_socket(con, deadline)
  if (!wait_readable()) return(NULL)
  n <- readBin(con, "integer", n = 1, endian = "big")
  if (length(n) == 0) return(NULL)
  got <- raw(0)
  while (length(got) < n) {
    if (!wait_readable()) return(NULL)
    more <- readBin(con, "raw", n = n - length(got))
    if (length(more) == 0) {
      # the select said readable but nothing came through (EOF race): give
      # the deadline one more chance before giving up.
      if (!wait_readable()) return(NULL)
      next
    }
    got <- c(got, more)
  }
  unserialize(got)
}

#' Write one wire frame to `con`.
write_frame <- function(con, msg) {
  payload <- serialize(msg, NULL)
  writeBin(length(payload), con, endian = "big")
  writeBin(payload, con)
  flush(con)
}

#' Start the real inst/worker.R under processx, accept its connection,
#' and return a harness object:
#'
#'   h$process   the processx handle (for h$process$interrupt(), etc.)
#'   h$send(msg) write a message to the worker
#'   h$receive(timeout = 5) read the next message, or NULL on timeout
#'   h$close()   close the socket and stop the worker
#'
#' `extra_libs` are prepended to R_LIBS_USER (ahead of the private temp
#' library), for tests that need a package installed (fixture_lib()).
worker_harness <- function(secret = "ember-test-secret", extra_libs = character(),
                            connect_timeout = 10, hello_timeout = 10) {
  srv <- open_server_socket()

  user_lib <- tempfile("ember-worker-lib-")
  dir.create(user_lib, recursive = TRUE)
  lib_path <- paste(c(extra_libs, user_lib), collapse = .Platform$path.sep)

  boot <- paste0(
    "local({e <- new.env(parent = baseenv()); ",
    "sys.source(Sys.getenv('EMBER_WORKER'), e); e$main()})")

  out_file <- tempfile("ember-worker-out-")
  err_file <- tempfile("ember-worker-err-")
  r_bin <- file.path(R.home("bin"), "Rscript")
  p <- processx::process$new(
    r_bin, c("--vanilla", "-e", boot, as.character(srv$port)),
    env = c("current",
            R_LIBS_USER = lib_path, R_LIBS = "", R_LIBS_SITE = "",
            EMBER_WORKER = worker_script_path(), EMBER_SECRET = secret,
            EMBER_WORKER_TRACE = "1"),
    # Files, not pipes: nothing reads a pipe until a test fails, and a
    # worker writing to a full pipe blocks.
    stdout = out_file, stderr = err_file)

  fail <- function(...) {
    tryCatch(if (p$is_alive()) p$kill(), error = function(e) NULL)
    tryCatch(close(srv$socket), error = function(e) NULL)
    stop(..., call. = FALSE)
  }

  deadline <- Sys.time() + connect_timeout
  con <- NULL
  repeat {
    remaining <- as.numeric(deadline - Sys.time(), units = "secs")
    if (remaining <= 0) {
      fail("worker did not connect within ", connect_timeout, "s:\n",
           paste(if (file.exists(err_file)) readLines(err_file, warn = FALSE), collapse = "\n"))
    }
    if (wait_socket(srv$socket, Sys.time() + min(remaining, 0.1))) {
      con <- socketAccept(srv$socket, blocking = TRUE, open = "a+b", timeout = 60 * 60 * 24)
      break
    }
    if (!p$is_alive()) {
      fail("worker exited before connecting:\n",
           paste(if (file.exists(err_file)) readLines(err_file, warn = FALSE), collapse = "\n"))
    }
  }
  close(srv$socket)  # the one connection is accepted; the listener isn't needed anymore

  h <- new.env()
  h$process <- p
  h$out_file <- out_file
  h$err_file <- err_file
  h$con <- con
  h$closed <- FALSE
  h$send <- function(msg) write_frame(con, msg)
  h$receive <- function(timeout = 5) read_frame(con, timeout)
  h$close <- function() {
    if (h$closed) return(invisible())
    h$closed <- TRUE
    tryCatch(close(con), error = function(e) NULL)
    if (p$is_alive()) {
      p$kill()
      p$wait(2000)
    }
  }

  hello <- h$receive(hello_timeout)
  if (is.null(hello) || !identical(hello$type, "hello")) {
    h$close()
    stop("worker did not say hello")
  }
  h$hello <- hello
  h
}

#' Read frames from `h` until a "done" (returning its report) or until
#' `timeout` seconds total have passed, whichever comes first.
#'
#' For tests that need to see or react to frames before "done" (a
#' "source" request, an interrupt's reply) and so can't use
#' run_and_wait()'s simple loop. A bare `repeat { m <- h$receive(5);
#' expect_false(is.null(m)); if (identical(m$type, "done")) break }`
#' looks bounded by the 5s read timeout but isn't: `expect_false()`, like
#' every `expect_*()` (and `testthat::fail()` itself -- both just signal a
#' continuable "expectation" condition), records a failure and keeps
#' going rather than stopping the test, so a worker that never replies
#' (dead, or an interrupt lost to the host shell's own SIGINT disposition
#' -- see sigint_reset_when_inherited_ignored) makes that loop call
#' h$receive() forever, hanging the whole test run instead of failing one
#' test (measured: confirmed `testthat::fail()` alone doesn't stop a
#' `repeat` either). `stop()` is what actually unwinds out of the test;
#' test_that() turns it into a normal recorded failure. `on_frame`, if
#' given, is called with every non-"done" frame as it's read, for tests
#' that need to answer a "source" request or otherwise react mid-run.
#' Fail a test whose worker went quiet, saying whether it is still running
#' and what it last wrote, so a failure on a CI machine can be diagnosed.
no_reply <- function(h, timeout) {
  alive <- h$process$is_alive()
  read <- function(f) if (file.exists(f)) readLines(f, warn = FALSE) else character()
  err <- read(h$err_file)
  out <- read(h$out_file)
  stop(sprintf("worker did not reply within %ss (alive: %s)\n%s", timeout, alive,
               paste(utils::tail(c(out, err), 20), collapse = "\n")), call. = FALSE)
}

#' Read frames until a "rendered" message arrives (a "more"/"render"
#' request's reply never comes as "done").
wait_for_done_or_rendered <- function(h, timeout = 5) {
  deadline <- Sys.time() + timeout
  repeat {
    remaining <- as.numeric(deadline - Sys.time(), units = "secs")
    if (remaining <= 0) no_reply(h, timeout)
    m <- h$receive(remaining)
    if (is.null(m)) no_reply(h, timeout)
    if (identical(m$type, "rendered")) return(m)
  }
}

wait_for_done <- function(h, timeout = 5, on_frame = NULL) {
  deadline <- Sys.time() + timeout
  repeat {
    remaining <- as.numeric(deadline - Sys.time(), units = "secs")
    if (remaining <= 0) no_reply(h, timeout)
    m <- h$receive(remaining)
    if (is.null(m)) no_reply(h, timeout)
    if (identical(m$type, "done")) return(m$report)
    if (!is.null(on_frame)) on_frame(m)
  }
}
