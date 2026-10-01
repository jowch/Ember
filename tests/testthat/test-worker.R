# Worker harness tests (docs/engine-tests.md, "Worker harness"): the real
# inst/worker.R under processx, talked to directly over a socket. No
# server, no `later`. Every wait is a blocking read with a timeout
# (worker_harness()'s $receive()), never Sys.sleep polling.

run_msg <- function(cell, token, code, role = "cell", order = character(), formulas = list(),
                    library = NULL) {
  list(type = "run", cell = cell, token = token, code = code, role = role,
       order = order, formulas = formulas, library = library)
}

#' Run code in a fresh harness and return the `done` report. Fails the
#' test (via a timeout error) if the worker never replies.
run_and_wait <- function(h, cell, token, code, ..., timeout = 5) {
  h$send(run_msg(cell, token, code, ...))
  repeat {
    m <- h$receive(timeout)
    if (is.null(m)) no_reply(h, timeout)
    if (identical(m$type, "done")) return(m$report)
  }
}

png_dims <- function(bytes) {
  list(width = sum(as.integer(bytes[17:20]) * 256^(3:0)),
       height = sum(as.integer(bytes[21:24]) * 256^(3:0)))
}

test_that("hello_and_secret", {
  h <- worker_harness(secret = "a-specific-secret")
  on.exit(h$close())
  expect_identical(h$hello$type, "hello")
  expect_identical(h$hello$secret, "a-specific-secret")
  expect_identical(h$hello$pid, h$process$get_pid())
  expect_true(is.character(h$hello$r_version) && nzchar(h$hello$r_version))
  expect_true(is.character(h$hello$lib_paths) && length(h$hello$lib_paths) >= 1)

  # the worker unsets EMBER_SECRET right after sending hello
  r <- run_and_wait(h, "a", 1L, 'Sys.getenv("EMBER_SECRET")')
  expect_identical(r$status, "ok")
  expect_identical(r$output$text, '[1] ""')
})

test_that("run_value_and_console_order", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, 'cat("a"); message("b"); warning("c"); 1 + 1')
  expect_identical(r$status, "ok")
  kinds <- vapply(r$console, `[[`, character(1), "kind")
  expect_identical(kinds, c("stdout", "message", "warning"))
  expect_identical(r$console[[1]]$text, "a")
  expect_identical(r$console[[2]]$text, "b\n")
  expect_identical(r$console[[3]]$text, "c")
  expect_identical(r$output$text, "[1] 2")
})

test_that("earlier_visible_values_to_console", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "1; 2")
  expect_identical(r$output$text, "[1] 2")
  expect_length(r$console, 1)
  expect_identical(r$console[[1]]$kind, "stdout")
  expect_identical(r$console[[1]]$text, "[1] 1")
})

test_that("error_with_traceback", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, 'f <- function() stop("boom")\nf()')
  expect_identical(r$status, "error")
  expect_identical(r$error$message, "boom")
  expect_identical(r$error$traceback, c("f()", 'stop("boom")'))
  expect_false(any(grepl("handleSimpleError|run_cell|eval\\(e, globalenv", r$error$traceback)))
})

test_that("rerun_removes_previous_globals", {
  h <- worker_harness()
  on.exit(h$close())
  r1 <- run_and_wait(h, "a", 1L, "x <- 1; y <- 2")
  expect_identical(sort(r1$created), c("x", "y"))
  r2 <- run_and_wait(h, "a", 2L, "y <- 2")
  expect_identical(r2$created, "y")
  check <- run_and_wait(h, "b", 3L, 'exists("x", envir = globalenv(), inherits = FALSE)')
  expect_identical(check$output$text, "[1] FALSE")
})

test_that("created_changed_removed", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, "x <- 1; y <- 2; z <- 3")
  r <- run_and_wait(h, "b", 2L, "sample(1:5, 1); x <- 99; rm(y); w <- 1")
  expect_identical(r$created, "w")
  expect_identical(r$changed, "x")
  expect_identical(r$removed, "y")
  expect_false(".Random.seed" %in% c(r$created, r$changed, r$removed))
})

test_that("active_binding_not_forced", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, paste(
    'counter_env <- new.env(); counter_env$i <- 0',
    'makeActiveBinding("ab", function() { counter_env$i <- counter_env$i + 1; counter_env$i }, globalenv())',
    sep = "\n"))
  r <- run_and_wait(h, "b", 2L, "1")
  expect_identical(r$changed, character())
  check <- run_and_wait(h, "c", 3L, "counter_env$i")
  expect_identical(check$output$text, "[1] 0")
})

test_that("options_change_reported_and_reverted", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "options(digits = 3)")
  expect_identical(r$status, "ok")
  expect_length(r$settings, 1)
  expect_identical(r$settings[[1]]$kind, "option")
  expect_identical(r$settings[[1]]$name, "digits")
  expect_identical(r$settings[[1]]$before, 7L)
  expect_identical(r$settings[[1]]$after, 3L)
  check <- run_and_wait(h, "b", 2L, 'getOption("digits")')
  expect_identical(check$output$text, "[1] 7")
})

test_that("setup_settings_reset_on_rerun", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "setup", 1L, "options(foo = 1)", role = "setup")
  run_and_wait(h, "setup", 2L, "1", role = "setup")
  r <- run_and_wait(h, "b", 3L, 'getOption("foo")')
  expect_identical(r$output$text, "NULL")
})

test_that("package_load_changes_allowed", {
  flib <- fixture_lib()
  h <- worker_harness(extra_libs = flib)
  on.exit(h$close())

  r <- run_and_wait(h, "a", 1L, 'loadNamespace("emberfix1")', order = "a")
  expect_identical(r$status, "ok")
  expect_identical(r$settings, list())

  r2 <- run_and_wait(h, "b", 2L, 'options(emberfix_load_opt = "cell-set")', order = c("a", "b"))
  expect_length(r2$settings, 1)
  expect_identical(r2$settings[[1]]$name, "emberfix_load_opt")
  expect_identical(r2$settings[[1]]$after, "cell-set")
})

test_that("onattach_changes_allowed", {
  flib <- fixture_lib()
  h <- worker_harness(extra_libs = flib)
  on.exit(h$close())

  r <- run_and_wait(h, "a", 1L, "library(emberfix1)", order = "a")
  expect_identical(r$status, "ok")
  expect_identical(r$settings, list())
  check <- run_and_wait(h, "b", 2L, 'getOption("emberfix_attach_opt")', order = c("a", "b"))
  expect_identical(check$output$text, '[1] "fix1-attach"')
})

test_that("search_path_rebuilt_in_file_order", {
  flib <- fixture_lib()
  h <- worker_harness(extra_libs = flib)
  on.exit(h$close())

  run_and_wait(h, "a", 1L, "library(emberfix1)", order = c("a", "b"))
  r1 <- run_and_wait(h, "b", 2L, "library(emberfix2); shared_fun()", order = c("a", "b"))
  expect_identical(r1$output$text, '[1] "fix2"')

  run_and_wait(h, "b", 3L, "library(emberfix2); shared_fun()", order = c("b", "a"))
  r2 <- run_and_wait(h, "a", 4L, "library(emberfix1); shared_fun()", order = c("b", "a"))
  expect_identical(r2$output$text, '[1] "fix1"')
})

test_that("delete_attaching_cell_detaches", {
  flib <- fixture_lib()
  h <- worker_harness(extra_libs = flib)
  on.exit(h$close())

  run_and_wait(h, "a", 1L, "library(emberfix1)", order = "a")
  h$send(list(type = "remove_cell", cell = "a", order = character()))
  r <- run_and_wait(h, "chk", 2L,
    'c(on_search = "package:emberfix1" %in% search(), loaded = "emberfix1" %in% loadedNamespaces())')
  expect_identical(r$output$text,
    paste(utils::capture.output(print(c(on_search = FALSE, loaded = TRUE))), collapse = "\n"))
})

test_that("attached_reports_exports", {
  flib <- fixture_lib()
  h <- worker_harness(extra_libs = flib)
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "library(emberfix1)", order = "a")
  expect_identical(names(r$attached), "emberfix1")
  expect_setequal(r$attached$emberfix1, c("shared_fun", "fix1_fun"))
})

test_that("computed_source_request", {
  h <- worker_harness()
  on.exit(h$close())
  d <- withr_tempdir <- tempfile("ember-source-")
  dir.create(d)
  writeLines("helper_val <- 42", file.path(d, "h.R"))

  code <- sprintf('source(file.path(%s, "h.R")); helper_val', deparse(d))
  h$send(run_msg("a", 1L, code))
  seen_source <- FALSE
  r <- wait_for_done(h, on_frame = function(m) {
    if (identical(m$type, "source")) {
      seen_source <<- TRUE
      expect_identical(m$text, "helper_val <- 42")
      h$send(list(type = "source_reply", allow = TRUE))
    }
  })
  expect_true(seen_source)
  expect_identical(r$status, "ok")
  expect_identical(r$output$text, "[1] 42")

  # a denied source() errors the cell
  code2 <- sprintf('source(file.path(%s, "h.R")); 1', deparse(d))
  h$send(run_msg("b", 2L, code2))
  r2 <- wait_for_done(h, on_frame = function(m) {
    if (identical(m$type, "source")) h$send(list(type = "source_reply", allow = FALSE, message = "no"))
  })
  expect_identical(r2$status, "error")
  expect_identical(r2$error$message, "no")

  # remove_cell sent while the worker waits for source_reply is deferred,
  # not mistaken for the reply, and handled after the run finishes
  code3 <- sprintf('source(file.path(%s, "h.R")); helper_val', deparse(d))
  h$send(run_msg("c", 3L, code3))
  r3 <- wait_for_done(h, on_frame = function(m) {
    if (identical(m$type, "source")) {
      h$send(list(type = "remove_cell", cell = "irrelevant", order = character()))
      h$send(list(type = "source_reply", allow = TRUE))
    }
  })
  expect_identical(r3$status, "ok")
  expect_identical(r3$output$text, "[1] 42")
})

test_that("formula_check_symbol_data", {
  h <- worker_harness()
  on.exit(h$close())
  fsite <- list(index = 1L, line = 1L, col = NA_integer_, end_col = NA_integer_,
                fn = "lm", data = "df", columns = c("x", "z"))
  code <- "z <- 1:3; df <- data.frame(x = 1:3, y = c(2, 4, 6)); fit <- lm(y ~ x + z, data = df)"
  r <- run_and_wait(h, "a", 1L, code, formulas = list(fsite))
  expect_identical(r$status, "ok")
  expect_identical(r$formula_misses, "z")

  fsite_call <- list(index = 1L, line = 1L, col = NA_integer_, end_col = NA_integer_,
                      fn = "lm", data = "get(\"df\")", columns = c("x", "z"))
  r2 <- run_and_wait(h, "b", 2L, "1", formulas = list(fsite_call))
  expect_identical(r2$formula_misses, character())
})

test_that("fresh_device_per_cell", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, "par(mfrow = c(2, 2)); plot(1)")
  r <- run_and_wait(h, "b", 2L, 'par("mfrow")')
  expect_identical(r$output$text, "[1] 1 1")
})

test_that("base_plot_output", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "plot(1:10)")
  expect_identical(r$status, "ok")
  expect_identical(r$output$kind, "plot")
  expect_identical(r$output$mime, "image/png")
  expect_identical(as.integer(r$output$data[1:8]), c(137L, 80L, 78L, 71L, 13L, 10L, 26L, 10L))

  h$send(list(type = "render", cell = "a", width = 200, height = 150))
  rendered <- h$receive(5)
  expect_identical(rendered$type, "rendered")
  dims <- png_dims(rendered$display$data)
  expect_identical(dims, list(width = 200, height = 150))
})

test_that("data_frame_table_view", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "data.frame(a = 1:3, b = letters[1:3])")
  expect_identical(r$output$kind, "table")
  expect_identical(r$output$mime, "application/vnd.ember.table")
  expect_identical(r$output$nrow, 3L)
  expect_identical(r$output$columns$a, c("1", "2", "3"))
  expect_identical(r$output$columns$b, c("a", "b", "c"))
  expect_identical(unname(r$output$types["a"]), "integer")
  expect_match(r$output$text, "^  a b")
})

test_that("user_globals_cannot_shadow_worker", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "send <- 1; receive <- 2; run_cell <- 3; 99")
  expect_identical(r$status, "ok")
  expect_identical(r$output$text, "[1] 99")
  r2 <- run_and_wait(h, "b", 2L, "1 + 1")
  expect_identical(r2$status, "ok")
  expect_identical(r2$output$text, "[1] 2")
})

test_that("interrupt_r_code", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, "x <- 1; y <- 2")

  h$send(run_msg("b", 2L, "t0 <- Sys.time(); repeat { if (as.numeric(Sys.time() - t0) > 10) break }"))
  Sys.sleep(0.3)
  t0 <- Sys.time()
  h$process$interrupt()
  r <- wait_for_done(h, timeout = 5)
  elapsed <- as.numeric(Sys.time() - t0, units = "secs")
  expect_identical(r$status, "interrupted")
  expect_lt(elapsed, 1)

  check <- run_and_wait(h, "c", 3L, 'c(x, y)')
  expect_identical(check$output$text, "[1] 1 2")
})

test_that("interrupt_between_runs_swallowed", {
  # On Windows the interrupt arrives later than the 0.2 s this test waits,
  # so it lands in the next cell; tracked in docs/design-gaps.md.
  skip_on_os("windows")
  h <- worker_harness()
  on.exit(h$close())
  h$process$interrupt()
  Sys.sleep(0.2)
  r <- run_and_wait(h, "a", 1L, "1 + 1")
  expect_identical(r$status, "ok")
  expect_identical(r$output$text, "[1] 2")
})

test_that("sigint_reset_when_inherited_ignored", {
  skip_on_os("windows")
  script <- tempfile(fileext = ".R")
  writeLines(c(
    'args <- commandArgs(trailingOnly = TRUE)',
    'dyn.load(args[[1]])',
    'was_ignored <- .Call("C_reset_sigint")',
    'library(processx)',
    'srv <- NULL; port <- NULL',
    'for (i in 1:30) {',
    '  port <- sample(20000:59999, 1)',
    '  srv <- tryCatch(serverSocket(port), error = function(e) NULL)',
    '  if (!is.null(srv)) break',
    '}',
    'boot <- "local({e <- new.env(parent = baseenv()); sys.source(Sys.getenv(\'EMBER_WORKER\'), e); e$main()})"',
    'p <- process$new(file.path(R.home("bin"), "Rscript"),',
    '  c("--vanilla", "-e", boot, as.character(port)),',
    '  env = c("current", R_LIBS_USER = args[[3]], R_LIBS = "", R_LIBS_SITE = "",',
    '          EMBER_WORKER = args[[2]], EMBER_SECRET = args[[4]]),',
    '  stdout = "|", stderr = "|")',
    'con <- NULL',
    'deadline <- Sys.time() + 10',
    'repeat {',
    '  remaining <- as.numeric(deadline - Sys.time(), units = "secs")',
    '  if (remaining <= 0) { cat("CONNECT_TIMEOUT\\n"); quit(status = 1) }',
    '  if (isTRUE(socketSelect(list(srv), timeout = remaining))) {',
    '    con <- socketAccept(srv, blocking = TRUE, open = "a+b", timeout = 60 * 60 * 24)',
    '    break',
    '  }',
    '}',
    'close(srv)',
    'write_frame <- function(con, msg) {',
    '  payload <- serialize(msg, NULL)',
    '  writeBin(length(payload), con, endian = "big"); writeBin(payload, con); flush(con)',
    '}',
    'read_frame <- function(con, timeout) {',
    '  deadline <- Sys.time() + timeout',
    '  wait <- function() {',
    '    remaining <- as.numeric(deadline - Sys.time(), units = "secs")',
    '    if (remaining <= 0) return(FALSE)',
    '    isTRUE(socketSelect(list(con), timeout = remaining))',
    '  }',
    '  if (!wait()) return(NULL)',
    '  n <- readBin(con, "integer", n = 1, endian = "big")',
    '  if (length(n) == 0) return(NULL)',
    '  got <- raw(0)',
    '  while (length(got) < n) {',
    '    if (!wait()) return(NULL)',
    '    more <- readBin(con, "raw", n = n - length(got))',
    '    if (length(more) == 0) next',
    '    got <- c(got, more)',
    '  }',
    '  unserialize(got)',
    '}',
    'hello <- read_frame(con, 10)',
    'if (is.null(hello) || !identical(hello$type, "hello")) { cat("NO_HELLO\\n"); quit(status = 1) }',
    'write_frame(con, list(type = "run", cell = "a", token = 1L,',
    '  code = "t0<-Sys.time(); repeat { if (as.numeric(Sys.time()-t0) > 10) break }",',
    '  role = "cell", order = character(), formulas = list()))',
    'Sys.sleep(0.3)',
    'p$interrupt()',
    'report <- NULL',
    'repeat {',
    '  m <- read_frame(con, 5)',
    '  if (is.null(m)) { cat("NO_DONE\\n"); quit(status = 1) }',
    '  if (identical(m$type, "done")) { report <- m$report; break }',
    '}',
    'cat("WAS_IGNORED:", was_ignored, "STATUS:", report$status, "\\n")',
    'p$kill()'
  ), script)

  ember_so <- getLoadedDLLs()[["ember"]][["path"]]
  skip_if_not(file.exists(ember_so), "ember's compiled code not loaded")
  user_lib <- tempfile("ember-worker-lib-")
  dir.create(user_lib, recursive = TRUE)
  r_bin <- file.path(R.home("bin"), "Rscript")
  shell_cmd <- sprintf("trap '' INT; exec %s --vanilla %s %s %s %s %s",
    shQuote(r_bin), shQuote(script), shQuote(ember_so), shQuote(worker_script_path()),
    shQuote(user_lib), shQuote("sigint-test-secret"))
  res <- processx::run("sh", c("-c", shell_cmd), timeout = 30, error_on_status = FALSE)
  expect_match(res$stdout, "WAS_IGNORED: TRUE")
  expect_match(res$stdout, "STATUS: interrupted")
})

# ---- Review fixes -------------------------------------------------------------

test_that("known_attached_packages_never_shrink", {
  # Regression for rebuild_search_path(): `known` used to be recomputed
  # from `attached` after remove_cell() had already dropped the edited
  # cell's own entry, so a package a cell once attached was never
  # detached once that cell stopped attaching it (it fell out of both
  # `desired` and `known` at once, so the no-op check passed wrongly).
  flib <- fixture_lib()
  h <- worker_harness(extra_libs = flib)
  on.exit(h$close())
  run_and_wait(h, "a", 1L, "library(emberfix1)", order = "a")
  run_and_wait(h, "a", 2L, "1", order = "a")  # edited to drop the library() call
  r <- run_and_wait(h, "chk", 3L, '"package:emberfix1" %in% search()', order = c("a", "chk"))
  expect_identical(r$output$text, "[1] FALSE")
})

test_that("interrupt_during_display_still_completes_bookkeeping", {
  # Windows delivers the interrupt through processx's CTRL+C helper, too late
  # for this test's timing; tracked in docs/design-gaps.md.
  skip_on_os("windows")
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L,
    'registerS3method("print", "slowprint", function(x, ...) { Sys.sleep(3); cat("slow\\n") })')
  h$send(run_msg("b", 2L, 'options(digits = 3); orphan <- 42; structure(1, class = "slowprint")'))
  Sys.sleep(1)
  h$process$interrupt()
  r <- wait_for_done(h, timeout = 10)
  expect_identical(r$status, "interrupted")
  expect_true("orphan" %in% r$created)
  expect_length(r$settings, 1)
  expect_identical(r$settings[[1]]$name, "digits")

  # the sink and the device from the interrupted run were closed (not
  # leaked): the next cell sees exactly its own single sink and device
  check <- run_and_wait(h, "c", 3L,
    'c(sinks = sink.number(), devices = length(grDevices::dev.list()))')
  expect_identical(check$output$text,
    paste(utils::capture.output(print(c(sinks = 1L, devices = 1L))), collapse = "\n"))

  # the option b changed was reverted (b wasn't the setup cell)
  check2 <- run_and_wait(h, "d", 4L, 'getOption("digits")')
  expect_identical(check2$output$text, "[1] 7")
})

test_that("sigint_during_remove_cell_does_not_crash_worker", {
  # On Windows a late interrupt between cells can still stop the worker;
  # tracked in docs/design-gaps.md.
  skip_on_os("windows")
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, "x <- 1")
  h$send(list(type = "remove_cell", cell = "a", order = character()))
  h$process$interrupt()
  # a SIGINT landing in the remove_cell/rebuild_search_path bookkeeping (or
  # anywhere else between runs) has nothing to interrupt there and must be
  # swallowed, not reach top level and kill the worker.
  r <- run_and_wait(h, "b", 2L, "1 + 1")
  expect_identical(r$status, "ok")
  expect_identical(r$output$text, "[1] 2")
  expect_true(h$process$is_alive())
})

test_that("print_generic_dispatches_from_notebook_globalenv", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, 'print.frobnicated <- function(x, ...) cat("custom frobnicated\\n")')
  r <- run_and_wait(h, "b", 2L, 'structure(1, class = "frobnicated")')
  expect_match(r$output$text, "custom frobnicated")
})

test_that("head_generic_dispatches_from_notebook_globalenv", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L,
    'head.weird <- function(x, ...) data.frame(got = "custom-head")')
  r <- run_and_wait(h, "b", 2L,
    'd <- data.frame(a = 1); class(d) <- c("weird", class(d)); d')
  expect_identical(r$output$columns$got, "custom-head")
})

test_that("locale_change_reported_and_reverted_per_category", {
  h <- worker_harness()
  on.exit(h$close())
  start <- run_and_wait(h, "z", 1L, 'Sys.getlocale("LC_COLLATE")')
  # testthat::test_local() sets LC_COLLATE=C in the environment (for
  # reproducible sorting), which the worker inherits; picking "C" as the
  # target unconditionally would then be a no-op and assert nothing. Pick
  # whichever of "C"/the host's LANG the worker *isn't* already at, so
  # the change is real under both a plain run and test_local().
  baseline <- sub('^\\[1\\] "(.*)"$', "\\1", start$output$text)
  target <- if (identical(baseline, "C")) Sys.getenv("LANG", "en_US.UTF-8") else "C"
  r <- run_and_wait(h, "a", 2L, sprintf('invisible(Sys.setlocale("LC_COLLATE", %s))', deparse(target)))
  expect_identical(r$status, "ok")
  expect_length(r$settings, 1)
  expect_identical(r$settings[[1]]$kind, "locale")
  expect_identical(r$settings[[1]]$name, "LC_COLLATE")
  expect_identical(r$settings[[1]]$after, target)
  after <- run_and_wait(h, "b", 3L, 'Sys.getlocale("LC_COLLATE")')
  expect_identical(after$output$text, start$output$text)
})

test_that("require_and_character_only_library_tracked_for_search_path", {
  flib <- fixture_lib()
  h <- worker_harness(extra_libs = flib)
  on.exit(h$close())
  run_and_wait(h, "a", 1L, "require(emberfix1)", order = c("a", "b"))
  run_and_wait(h, "b", 2L, "p <- 'emberfix2'; library(p, character.only = TRUE)", order = c("a", "b"))

  h$send(list(type = "remove_cell", cell = "a", order = "b"))
  h$send(list(type = "remove_cell", cell = "b", order = character()))
  r <- run_and_wait(h, "chk", 3L, 'search()', order = character())
  expect_false(grepl("package:emberfix1", r$output$text, fixed = TRUE))
  expect_false(grepl("package:emberfix2", r$output$text, fixed = TRUE))
})

test_that("classed_condition_traceback_excludes_worker_frames", {
  h <- worker_harness()
  on.exit(h$close())
  code <- paste(
    'cnd <- structure(class = c("myError", "error", "condition"),',
    '                 list(message = "boom", call = NULL))',
    'f <- function() stop(cnd)',
    'f()', sep = "\n")
  r <- run_and_wait(h, "a", 1L, code)
  expect_identical(r$status, "error")
  expect_identical(r$error$message, "boom")
  expect_identical(r$error$traceback, c("f()", "stop(cnd)"))
  expect_false(any(grepl("function ?\\(e\\)|withCallingHandlers|run_cell", r$error$traceback)))
})

test_that("library_error_reports_notebook_call_not_wrapper", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "library(notapkg)")
  expect_identical(r$status, "error")
  expect_identical(deparse(r$error$call), "library(notapkg)")
  expect_false(any(grepl("^original\\(", r$error$traceback)))
})

test_that("user_sink_in_cell_does_not_break_worker_capture", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, 'sink(); cat("after user sink\\n"); 1')
  expect_identical(r$status, "ok")
  check <- run_and_wait(h, "b", 2L, 'cat("next cell\\n"); sink.number()')
  expect_identical(vapply(check$console, `[[`, "", "text"), "next cell\n")
  expect_identical(check$output$text, "[1] 1")
})

# ---- Packages (step 3) ----------------------------------------------------------

test_that("the hello and each done report loaded namespaces with versions (67)", {
  flib <- fixture_lib()
  h <- worker_harness(extra_libs = flib)
  on.exit(h$close())

  # Base packages never appear (they're never locked and would make every
  # hello's `loaded` nonempty regardless of the notebook).
  expect_true(is.character(h$hello$loaded))
  expect_false("base" %in% names(h$hello$loaded))
  expect_false("emberfix1" %in% names(h$hello$loaded))

  r <- run_and_wait(h, "a", 1L, "library(emberfix1)", order = "a")
  expect_identical(r$status, "ok")
  expect_true(is.character(r$loaded))
  expect_identical(unname(r$loaded["emberfix1"]), "0.0.1")
  expect_false("base" %in% names(r$loaded))
})

test_that("library(notapkg) reports error$package regardless of locale (68)", {
  h <- worker_harness()
  on.exit(h$close())

  # Changing LC_MESSAGES in the setup cell is kept (not reverted, unlike a
  # plain cell); if the locale isn't installed on this machine, skip rather
  # than fail on an environment difference.
  set_locale <- run_and_wait(h, "setup", 1L, 'Sys.setlocale("LC_MESSAGES", "fr_FR.UTF-8")', role = "setup")
  if (identical(set_locale$status, "error") ||
      !identical(set_locale$output$text, '[1] "fr_FR.UTF-8"')) {
    skip("fr_FR.UTF-8 locale not available on this machine")
  }

  r <- run_and_wait(h, "a", 2L, "library(notapkg)")
  expect_identical(r$status, "error")
  expect_identical(r$error$package, "notapkg")
})

test_that("a run message with a new library changes .libPaths() before the code runs (69)", {
  h <- worker_harness()
  on.exit(h$close())
  new_lib <- tempfile("ember-new-lib-")
  dir.create(new_lib)

  # Compared inside the worker process (normalizePath() on both sides, done
  # there) so the test doesn't depend on the test process and the worker
  # process resolving the same path string identically (e.g. symlinked temp
  # directories).
  code <- sprintf("identical(normalizePath(.libPaths()[1]), normalizePath(%s))", deparse(new_lib))
  r <- run_and_wait(h, "b", 1L, code, library = new_lib)
  expect_identical(r$status, "ok")
  expect_identical(r$output$text, "[1] TRUE")
})
