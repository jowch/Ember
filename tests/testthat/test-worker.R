# Worker harness tests (docs/engine-tests.md, "Worker harness"): the real
# inst/worker.R under processx, talked to directly over a socket. No
# server, no `later`. Every wait is a read with no time limit
# (worker_harness()'s $receive(), next_frame()), never Sys.sleep polling.

run_msg <- function(cell, token, code, role = "cell", order = character(), formulas = list(),
                    library = NULL, fig = NULL, settings = character(), data = NULL) {
  list(type = "run", cell = cell, token = token, code = code, role = role,
       order = order, settings = settings, formulas = formulas, library = library, fig = fig,
       data = data)
}

#' Run code in a fresh harness and return the `done` report. Fails the
#' test if the worker exits or hangs before replying (next_frame()).
run_and_wait <- function(h, cell, token, code, ...) {
  h$send(run_msg(cell, token, code, ...))
  wait_for_done(h)
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

  # nor does any frame on the stack while the cell runs (main()'s own
  # frame stays there for the worker's whole life)
  r <- run_and_wait(h, "b", 2L, 'unlist(lapply(sys.frames(), function(e) get0("secret", e, inherits = FALSE)))')
  expect_identical(r$status, "ok")
  expect_identical(r$output$text, "NULL")
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

test_that("what a running cell prints is sent while it runs, a whole line at a time (#470)", {
  # The cell prints, then waits on a file the test writes only once the
  # printed text has arrived: before #470 nothing came until the run ended,
  # and before #482 on Windows. The unfinished line comes as a partial item
  # (#483), which the finished line replaces.
  h <- worker_harness()
  on.exit(h$close())
  go <- tempfile("ember-go-")
  on.exit(unlink(go), add = TRUE)
  code <- sprintf('cat("inside the loop\\n"); cat("half"); while (!file.exists(%s)) NULL; cat(" line\\n"); message("m")', deparse(go))
  h$send(run_msg("a", 1L, code))
  sent <- list()
  repeat {
    m <- next_frame(h)
    expect_false(identical(m$type, "done"))
    if (identical(m$type, "console")) sent[[length(sent) + 1]] <- m$item
    if (isTRUE(m$item$partial)) break
  }
  expect_identical(sent, list(list(kind = "stdout", text = "inside the loop\n"),
                              list(kind = "stdout", text = "half", partial = TRUE)))
  writeLines("", go)
  r <- wait_for_done(h)
  expect_identical(r$status, "ok")
  # The partial line was replaced by the whole one, before the message.
  expect_identical(r$console, list(list(kind = "stdout", text = "inside the loop\n"),
                                   list(kind = "stdout", text = "half line\n"),
                                   list(kind = "message", text = "m\n")))
})

test_that("a progress bar redrawn with \\r shows each drawing while the cell runs (#483)", {
  # The cell draws, then waits for the test to see that drawing before the
  # next. Each drawing replaces the last; the finished line replaces them
  # all.
  h <- worker_harness()
  on.exit(h$close())
  go <- c(tempfile("ember-go-"), tempfile("ember-go-"))
  on.exit(unlink(go), add = TRUE)
  wait <- function(f) sprintf("while (!file.exists(%s)) NULL", deparse(f))
  code <- paste('cat("\\r 10%")', wait(go[1]), 'cat("\\r 20%")', wait(go[2]),
                'cat("\\r100%\\n"); message("m")', sep = "; ")
  h$send(run_msg("a", 1L, code))
  sent <- list()
  r <- wait_for_done(h, on_frame = function(m) if (identical(m$type, "console")) {
    sent[[length(sent) + 1]] <<- m$item
    if (identical(m$item$text, " 10%")) writeLines("", go[1])
    if (identical(m$item$text, " 20%")) writeLines("", go[2])
  })
  expect_identical(r$status, "ok")
  expect_identical(sent, list(list(kind = "stdout", text = " 10%", partial = TRUE),
                              list(kind = "stdout", text = " 20%", partial = TRUE),
                              list(kind = "stdout", text = "100%\n"),
                              list(kind = "message", text = "m\n")))
  expect_identical(r$console, sent[3:4])
})

test_that("an unfinished line cut inside a character is sent up to that character (#483)", {
  # The cell writes "a" and the first byte of "\u00e9", then the rest once the
  # test has seen the partial line: sent while cut, it wouldn't be UTF-8.
  h <- worker_harness()
  on.exit(h$close())
  go <- tempfile("ember-go-")
  on.exit(unlink(go), add = TRUE)
  code <- sprintf('cat(rawToChar(as.raw(c(0x61, 0xc3)))); while (!file.exists(%s)) NULL; cat(rawToChar(as.raw(c(0xa9, 0x0a))))', deparse(go))
  h$send(run_msg("a", 1L, code))
  sent <- list()
  r <- wait_for_done(h, on_frame = function(m) if (identical(m$type, "console")) {
    sent[[length(sent) + 1]] <<- m$item
    writeLines("", go)
  })
  expect_identical(r$status, "ok")
  expect_identical(sent, list(list(kind = "stdout", text = "a", partial = TRUE),
                              list(kind = "stdout", text = "a\u00e9\n")))
})

test_that("a forked child doesn't send its parent's printed text again (#470)", {
  # mclapply()'s children inherit the hook, the console file and the
  # socket; only the worker may send. Unix only: Windows has no fork. Each
  # child runs until the parent has sent the line.
  skip_on_os("windows")
  h <- worker_harness()
  on.exit(h$close())
  go <- tempfile("ember-go-")
  on.exit(unlink(go), add = TRUE)
  code <- sprintf('cat("before\\n"); invisible(parallel::mclapply(1:4, function(i) { while (!file.exists(%s)) NULL; i }, mc.cores = 2))', deparse(go))
  h$send(run_msg("a", 1L, code))
  sent <- list()
  r <- wait_for_done(h, on_frame = function(m) if (identical(m$type, "console")) {
    sent[[length(sent) + 1]] <<- m$item
    writeLines("", go)
  })
  expect_identical(r$status, "ok", info = r$error$message)
  # The children's copies would come as console frames of their own.
  expect_identical(sent, list(list(kind = "stdout", text = "before\n")))
  expect_identical(r$console, sent)
})

test_that("a line printed before a long Sys.sleep() is sent during the sleep (#470)", {
  # On Unix R sleeps a wait in one go unless R_wait_usec is set, so the hook
  # would run only when the sleep ends; Windows wakes every 0.5 s (#482).
  # The test stops the sleep once the line has arrived.
  h <- worker_harness()
  on.exit(h$close())
  h$send(run_msg("a", 1L, 'cat("before the sleep\\n"); Sys.sleep(3600)'))
  sent <- list()
  r <- wait_for_done(h, on_frame = function(m) if (identical(m$type, "console")) {
    sent[[length(sent) + 1]] <<- m$item
    h$interrupt()
  })
  expect_identical(r$status, "interrupted")
  expect_identical(sent, list(list(kind = "stdout", text = "before the sleep\n")))
})

test_that("an interrupt that lands while printed text is sent still stops a Sys.sleep() (#482)", {
  # On Windows the tick's send runs R's event processing with interrupts
  # held off, which turns one that just arrived into a pending interrupt
  # that Sys.sleep() never takes there. C_console_test_break() holds ticks
  # off while the line is printed, then lets the next one start with an
  # interrupt arrived, so that tick is the one that sends the line. Nothing
  # else interrupts.
  skip_if_not(.Platform$OS.type == "windows", "the tick's interrupt hand-back is Windows' own")
  h <- worker_harness()
  on.exit(h$close())
  code <- paste('tb <- getNativeSymbolInfo("C_console_test_break", "ember")',
                'invisible(.Call(tb, 1L)); cat("1\\n"); invisible(.Call(tb, 2L)); Sys.sleep(3600)', sep = "\n")
  h$send(run_msg("a", 1L, code))
  sent <- list()
  r <- wait_for_done(h, on_frame = function(m) if (identical(m$type, "console")) sent[[length(sent) + 1]] <<- m$item)
  expect_identical(r$status, "interrupted")
  expect_identical(sent, list(list(kind = "stdout", text = "1\n")))
})

test_that("a progress bar's redraws end as one line, as in the R console (#358)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, paste(
    "pb <- txtProgressBar(min = 0, max = 300, style = 3)",
    "for (i in 1:300) setTxtProgressBar(pb, i)",
    "close(pb)",
    'cat("abcdef\\rXY\\n")',
    'cat("\\033[32m100%\\033[39m\\r\\033[32m5%\\033[39m\\n")',
    'cat("\\u65e5\\u672c\\u8a9e\\rab\\n")',
    'cat("loading...\\r\\033[KDone\\n")',
    'cat("ab\\033]8;;https://x.org\\aLINK\\033]8;;\\a\\rZ\\n")',
    'cat(strrep("\\033[32mrow\\033[39m\\n", 1000), "a\\rb\\n", sep = "")', sep = "\n"))
  expect_identical(r$status, "ok")
  out <- paste(vapply(Filter(function(i) identical(i$kind, "stdout"), r$console), `[[`, "", "text"), collapse = "")
  expect_false(grepl("\r", out, fixed = TRUE))
  lines <- strsplit(out, "\n", fixed = TRUE)[[1]]
  visible <- gsub("\033\\[[0-9;]*m", "", lines)
  # A redraw overwrites the line it returns to, so a shorter one keeps its
  # tail. Colors take no columns, and each column keeps the color it was
  # written in; a wide character takes two columns; ESC[K clears the rest.
  # A hyperlink's escape is dropped, not shown.
  expect_identical(visible, c(sprintf("  |%s| 100%%", strrep("=", 70)), "XYcdef", "5%0%",
                              "ab\u672c\u8a9e", "Done", "ZbLINK", rep("row", 1000), "b"))
  expect_match(lines[[3]], "\033[32m5%0%", fixed = TRUE)  # 0% keeps its green
  # The colors in force stay a few fields, however many escapes came
  # before: 1000 green rows, each closed with 39, leave none.
  expect_identical(lines[[length(lines)]], "b")
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

test_that("a last-line assignment is the output; other invisible last lines show nothing (design.md, Which values a cell shows)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "x <- 2")
  expect_identical(r$output$text, "[1] 2")
  r <- run_and_wait(h, "b", 2L, "3 -> y", order = c("a", "b"))
  expect_identical(r$output$text, "[1] 3")
  r <- run_and_wait(h, "c", 3L, "z = 4", order = c("a", "b", "c"))
  expect_identical(r$output$text, "[1] 4")
  # A data frame assignment shows the table.
  r <- run_and_wait(h, "d", 4L, "cars <- head(mtcars, 2)", order = c("a", "b", "c", "d"))
  expect_identical(r$output$mime, "application/vnd.ember.table")
  # invisible(), an assigned function and <<- show nothing.
  r <- run_and_wait(h, "e", 5L, "invisible(w <- 5)", order = c("a", "b", "c", "d", "e"))
  expect_null(r$output)
  r <- run_and_wait(h, "f", 6L, "f <- function(x) x", order = c("a", "b", "c", "d", "e", "f"))
  expect_null(r$output)
  r <- run_and_wait(h, "g", 7L, "g <<- 6", order = c("a", "b", "c", "d", "e", "f", "g"))
  expect_null(r$output)
  r <- run_and_wait(h, "i", 8L, "v <- w <- 7", order = c("a", "b", "c", "d", "e", "f", "g", "i"))
  expect_identical(r$output$text, "[1] 7")
  r <- run_and_wait(h, "j", 9L, "n <- NULL", order = c("a", "b", "c", "d", "e", "f", "g", "i", "j"))
  expect_identical(r$output$text, "NULL")
  r <- run_and_wait(h, "k", 10L, "en <- new.env()", order = c("a", "b", "c", "d", "e", "f", "g", "i", "j", "k"))
  expect_null(r$output)
  r <- run_and_wait(h, "l", 11L, 'ce <- structure(new.env(), class = "thing")', order = c("a", "b", "c", "d", "e", "f", "g", "i", "j", "k", "l"))
  expect_false(is.null(r$output))
})

test_that("a plot drawn before a last-line assignment is the output, not the assigned value", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "hh <- hist(c(1, 2, 2, 3))")
  expect_identical(r$output$kind, "plot")
  r <- run_and_wait(h, "b", 2L, "plot(1:10)\nn <- 5", order = c("a", "b"))
  expect_identical(r$output$kind, "plot")
})

test_that("an earlier visible value goes to the console when the last line is invisible", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "1\ninvisible(2)")
  expect_null(r$output)
  expect_length(r$console, 1)
  expect_identical(r$console[[1]]$text, "[1] 1")
  r <- run_and_wait(h, "b", 2L, "1\nx <- 2", order = c("a", "b"))
  expect_identical(r$output$text, "[1] 2")
  expect_identical(r$console[[1]]$text, "[1] 1")
})

test_that("a warning raised inside a function carries its call; a message carries none (ui-3-tests 130)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "g <- function() warning('careful')\ng()\nmessage('m')")
  expect_identical(r$console[[1]]$kind, "warning")
  expect_identical(r$console[[1]]$call, "g()")
  expect_identical(r$console[[2]]$kind, "message")
  expect_null(r$console[[2]][["call", exact = TRUE]])

  r2 <- run_and_wait(h, "b", 2L, "warning('top-level')")
  expect_null(r2$console[[1]][["call", exact = TRUE]])
})

test_that("error_with_traceback", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, 'f <- function() stop("boom")\nf()')
  expect_identical(r$status, "error")
  expect_identical(r$error$message, "boom")
  expect_identical(r$error$traceback, c("f()", 'stop("boom")'))
  expect_false(any(grepl("handleSimpleError|run_cell|eval\\(e, globalenv|eval\\(exprs", r$error$traceback)))
})

test_that("run_cell() on a bare top-level stop(): call/line/deep/frames (ui-3-tests 127)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "TOP", 1L, "1\nstop('boom')")
  expect_identical(r$status, "error")
  expect_null(r$error$call)
  expect_identical(r$error$line, 2L)
  expect_identical(r$error$deep, FALSE)
  expect_identical(r$error$frames, list())
})

test_that("run_cell(): stop(call. = FALSE) through nested calls still gets frames (item 1)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L,
    "f <- function() stop('x', call. = FALSE)\ng <- function() f()\ng()")
  expect_identical(r$status, "error")
  expect_null(r$error$call)
  expect_identical(length(r$error$frames), length(r$error$traceback))
  expect_true(length(r$error$frames) >= 2)
  expect_identical(vapply(r$error$frames, `[[`, character(1), "call"),
                   r$error$traceback)
})

test_that("run_cell(): an assignment to a failing call's result isn't deep (item 2)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "f <- function(x) stop('boom')\ny <- f(1)")
  expect_identical(r$status, "error")
  expect_identical(r$error$call, "f(1)")
  expect_identical(r$error$deep, FALSE)
})

test_that("run_cell(): rlang's check_installed() error names its packages, as a packageNotFoundError does (#184)", {
  h <- worker_harness()
  on.exit(h$close())
  # The worker's library has no rlang, so the cell raises the condition the way
  # check_installed() does: class rlib_error_package_not_found, with `pkg`.
  r <- run_and_wait(h, "a", 1L, paste0('stop(structure(class = c("rlib_error_package_not_found", "rlib_error", ',
                                       '"error", "condition"), list(message = "The packages are required.", ',
                                       'call = NULL, pkg = c("emberabsent1", "emberabsent2"), version = NULL)))'))
  expect_identical(r$status, "error")
  expect_identical(r$error$package, c("emberabsent1", "emberabsent2"))

  # One with a version may be installed and only too old: none is named, so the
  # whole message stays (check_installed("rlang (>= 99.0)")).
  r <- run_and_wait(h, "a", 2L, paste0('stop(structure(class = c("rlib_error_package_not_found", "rlib_error", ',
                                       '"error", "condition"), list(message = "The package \\"stats\\" (>= 99.0) is required.", ',
                                       'call = NULL, pkg = c("stats", "emberabsent1"), version = c("99.0", NA))))'))
  expect_null(r$error$package)
  r <- run_and_wait(h, "a", 3L, paste0('stop(structure(class = c("rlib_error_package_not_found", "rlib_error", ',
                                       '"error", "condition"), list(message = "The package \\"stats\\" (>= 99.0) is required.", ',
                                       'call = NULL, pkg = "stats", version = "99.0")))'))
  expect_null(r$error$package)
})

test_that("run_cell(): a notebook function calling lm() with bad data (ui-3-tests 128)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "ERR", 1L, "g <- function(d) lm(y ~ x, data = d); g(1)")
  expect_identical(r$status, "error")
  expect_true(startsWith(r$error$call, "model.frame.default("))
  expect_identical(r$error$deep, TRUE)
  expect_identical(r$error$line, 1L)
  expect_identical(r$error$frames[[1]]$cell, "ERR")
  packages <- vapply(r$error$frames, function(f) f$package %||% "", character(1))
  expect_true("stats" %in% packages)
  expect_identical(length(r$error$frames), length(r$error$traceback))
})

test_that("run_cell(): every frame of lm()'s deep traceback has a package or a cell, the builtin eval() frame included", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "ERR", 1L, "g <- function(d) lm(y ~ x, data = d); g(1)")
  evals <- Filter(function(f) identical(f$call, "eval(mf, parent.frame())"), r$error$frames)
  expect_length(evals, 2)
  expect_identical(vapply(evals, function(f) f$package %||% "", character(1)), c("base", "base"))
  unlabelled <- Filter(function(f) is.null(f$package) && is.null(f$cell), r$error$frames)
  expect_identical(unlabelled, list())
})

test_that("run_cell(): a function defined in cell F, called from cell ERR, keeps its own cell in a frame (ui-3-tests 129)", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "F", 1L, "f <- function(x) stop('bad: ', x)")
  r <- run_and_wait(h, "ERR", 2L, "f(1)")
  expect_identical(r$status, "error")
  frame <- Find(function(f) identical(f$call, "f(1)"), r$error$frames)
  expect_identical(frame$cell, "F")
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

test_that("a global holding the empty symbol is compared, not read as a missing argument (#387)", {
  # `get()` on such a binding fails with "argument is missing", which ended
  # the worker on the next cell; plain R keeps going.
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "x <- quote(expr = )")
  expect_identical(r$status, "ok")
  expect_identical(r$created, "x")
  r <- run_and_wait(h, "b", 2L, "y <- 1")
  expect_identical(r$status, "ok")
  expect_identical(r$changed, character())
  r <- run_and_wait(h, "c", 3L, "x <- 2")
  expect_identical(r$changed, "x")
})

test_that("an options change is reported, and applies only where its cell is in effect", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "options(digits = 3)")
  expect_identical(r$status, "ok")
  expect_length(r$settings, 1)
  expect_identical(r$settings[[1]]$kind, "option")
  expect_identical(r$settings[[1]]$name, "digits")
  expect_identical(r$settings[[1]]$before, 7L)
  expect_identical(r$settings[[1]]$after, 3L)
  # In effect: the server lists "a" before "b".
  with_a <- run_and_wait(h, "b", 2L, 'getOption("digits")', settings = "a")
  expect_identical(with_a$output$text, "[1] 3")
  expect_length(with_a$settings, 0)
  # Not in effect (b runs before a, or a is disabled): back to the baseline.
  without <- run_and_wait(h, "b", 3L, 'getOption("digits")')
  expect_identical(without$output$text, "[1] 7")
})

test_that("an environment variable change is reported each run, and applies only where its cell is in effect (#369)", {
  # The worker keeps the parsed environment while it is unchanged, so check
  # the change is seen on a rerun too, and that the reset before the next
  # cell undoes it.
  h <- worker_harness()
  on.exit(h$close())
  for (gen in 1:2) {
    r <- run_and_wait(h, "a", gen, 'Sys.setenv(EMBER_TEST_369 = "on")')
    expect_length(r$settings, 1)
    expect_identical(r$settings[[1]]$kind, "env")
    expect_identical(r$settings[[1]]$name, "EMBER_TEST_369")
    expect_null(r$settings[[1]]$before)
    expect_identical(r$settings[[1]]$after, "on")
  }
  with_a <- run_and_wait(h, "b", 3L, 'Sys.getenv("EMBER_TEST_369")', settings = "a")
  expect_identical(with_a$output$text, '[1] "on"')
  expect_length(with_a$settings, 0)
  without <- run_and_wait(h, "b", 4L, 'Sys.getenv("EMBER_TEST_369")')
  expect_identical(without$output$text, '[1] ""')
})

test_that("a settings cell rerun starts from the baseline, and a deleted one stops applying", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "s", 1L, "options(foo = 1)")
  run_and_wait(h, "s", 2L, "1")
  r <- run_and_wait(h, "b", 3L, 'getOption("foo")', settings = "s")
  expect_identical(r$output$text, "NULL")

  sub <- tempfile("ember-wd-")
  dir.create(file.path(sub, "data"), recursive = TRUE)
  # After creating it, so macOS resolves /var to /private/var like getwd() does.
  sub <- normalizePath(sub, winslash = "/")
  run_and_wait(h, "w", 4L, sprintf("setwd(%s)", deparse(sub)))
  run_and_wait(h, "w2", 5L, 'setwd("data")', settings = "w")
  # Rerun with the same context: lands in data again, not data/data.
  r2 <- run_and_wait(h, "w2", 6L, 'setwd("data"); getwd()', settings = "w")
  expect_identical(r2$output$text, sprintf('[1] "%s/data"', sub))

  run_and_wait(h, "o", 7L, "options(bar = 2)")
  h$send(list(type = "remove_cell", cell = "o", order = character()))
  r3 <- run_and_wait(h, "c", 8L, 'getOption("bar")', settings = "o")
  expect_identical(r3$output$text, "NULL")
})

test_that("an option a package sets when it loads survives the reset before each run", {
  h <- worker_harness(extra_libs = fixture_lib())
  on.exit(h$close())
  run_and_wait(h, "s", 1L, "options(digits = 3)")
  run_and_wait(h, "l", 2L, "library(emberfix1)", settings = "s")
  r <- run_and_wait(h, "c", 3L, 'getOption("emberfix_load_opt")', settings = "l")
  expect_identical(r$output$text, '[1] "fix1-load"')
  r2 <- run_and_wait(h, "c", 4L, 'getOption("digits")', settings = "l")
  expect_identical(r2$output$text, "[1] 7")
})

test_that("library(ggplot2) and theme_set() in one cell: the theme is that cell's setting (review)", {
  skip_if_not_installed("ggplot2")
  h <- worker_harness(extra_libs = .libPaths())
  on.exit(h$close())
  r <- run_and_wait(h, "t", 1L, "library(ggplot2); theme_set(theme_minimal(base_size = 21))")
  expect_identical(r$status, "ok")
  kinds <- vapply(r$settings, function(d) d$kind, character(1))
  expect_true("theme" %in% kinds)
  # Theme values stay in the worker; the server gets only the key.
  theme_diff <- r$settings[[match("theme", kinds)]]
  expect_null(theme_diff$after)
  on <- run_and_wait(h, "c", 2L, "ggplot2::theme_get()$text$size", settings = "t")
  expect_identical(on$output$text, "[1] 21")
  off <- run_and_wait(h, "c", 3L, "ggplot2::theme_get()$text$size")
  expect_identical(off$output$text, "[1] 11")
  # A later change to the cell keeps ggplot2's default as the baseline.
  run_and_wait(h, "t", 4L, "library(ggplot2); theme_set(theme_bw(base_size = 15))", settings = character())
  off2 <- run_and_wait(h, "c", 5L, "ggplot2::theme_get()$text$size")
  expect_identical(off2$output$text, "[1] 11")
  on2 <- run_and_wait(h, "c", 6L, "ggplot2::theme_get()$text$size", settings = "t")
  expect_identical(on2$output$text, "[1] 15")
  # A cell that only loads ggplot2 sets nothing.
  r2 <- run_and_wait(h, "l", 7L, "library(ggplot2)")
  expect_false("theme" %in% vapply(r2$settings, function(d) d$kind, character(1)))
})

test_that("ggplot2's theme is a setting the worker resets and reapplies", {
  skip_if_not_installed("ggplot2")
  h <- worker_harness(extra_libs = .libPaths())
  on.exit(h$close())
  run_and_wait(h, "l", 1L, "loadNamespace('ggplot2')")
  r <- run_and_wait(h, "t", 2L, "ggplot2::theme_set(ggplot2::theme_minimal(base_size = 21))")
  expect_true(any(vapply(r$settings, function(d) identical(d$kind, "theme"), logical(1))))
  on <- run_and_wait(h, "c", 3L, "ggplot2::theme_get()$text$size", settings = "t")
  expect_identical(on$output$text, "[1] 21")
  off <- run_and_wait(h, "c", 4L, "ggplot2::theme_get()$text$size")
  expect_identical(off$output$text, "[1] 11")
})

test_that("chdir moves getwd() and the baseline; a settings cell's setwd() survives it (89)", {
  h <- worker_harness()
  on.exit(h$close())
  new_dir <- function(prefix) {
    p <- tempfile(prefix)
    dir.create(p)
    normalizePath(p, winslash = "/", mustWork = TRUE)
  }
  f0 <- normalizePath(getwd(), winslash = "/")
  f1 <- new_dir("ember-chdir-f1-")

  h$send(list(type = "chdir", from = f0, to = f1))
  r <- run_and_wait(h, "x", 1L, "getwd()")
  expect_identical(r$output$text, sprintf('[1] "%s"', f1))

  elsewhere <- new_dir("ember-chdir-elsewhere-")
  run_and_wait(h, "s", 2L, sprintf("setwd(%s)", deparse(elsewhere)))
  dir.create(file.path(f1, "data"))
  run_and_wait(h, "d", 3L, sprintf("setwd(%s)", deparse(file.path(f1, "data"))))

  # The notebook moves: a settings cell's setwd() outside the notebook's
  # folder is kept as it is, one inside it moves with the notebook, and the
  # baseline moves to the new folder.
  f2 <- new_dir("ember-chdir-f2-")
  dir.create(file.path(f2, "data"))
  h$send(list(type = "chdir", from = f1, to = f2))
  r2 <- run_and_wait(h, "y", 4L, "getwd()", settings = "s")
  expect_identical(r2$output$text, sprintf('[1] "%s"', elsewhere))
  r3 <- run_and_wait(h, "y", 5L, "getwd()", settings = "d")
  expect_identical(r3$output$text, sprintf('[1] "%s/data"', f2))
  r4 <- run_and_wait(h, "y", 6L, "getwd()")
  expect_identical(r4$output$text, sprintf('[1] "%s"', f2))
})

test_that("chdir to a folder that no longer exists doesn't kill the worker", {
  h <- worker_harness()
  on.exit(h$close())
  f0 <- normalizePath(getwd(), winslash = "/")
  gone <- tempfile("ember-chdir-gone-")  # never created

  # setwd() would throw here (the target doesn't exist); handle_next()
  # has no catch of its own, so an uncaught error escaping from inside
  # the chdir case used to be fatal to the worker.
  h$send(list(type = "chdir", from = f0, to = gone))
  r <- run_and_wait(h, "x", 1L, "1 + 1")
  expect_identical(r$status, "ok")
  expect_identical(r$output$text, "[1] 2")

  # The live wd is unchanged (setwd() never ran, the folder still
  # doesn't exist): a notebook that didn't call setwd() itself keeps
  # working from where it already was.
  r2 <- run_and_wait(h, "y", 2L, "getwd()")
  expect_identical(r2$output$text, sprintf('[1] "%s"', f0))
})

test_that("a package load that resets a setting a settings cell set leaves a note naming the package (#61)", {
  h <- worker_harness(extra_libs = fixture_lib())
  on.exit(h$close())
  run_and_wait(h, "s", 1L, 'options(emberfix_load_opt = "user")')
  # library() loads through an inner loadNamespace(package): the note names
  # the package, not the loader's argument.
  r <- run_and_wait(h, "l", 2L, "library(emberfix1)", settings = "s")
  expect_identical(r$status, "ok")
  expect_identical(r$settings, list())
  expect_identical(r$load_notes, list(list(package = "emberfix1", kind = "option", name = "emberfix_load_opt")))
  # The settings cell is applied again before the next run, as before.
  r2 <- run_and_wait(h, "c", 3L, 'getOption("emberfix_load_opt")', settings = "s")
  expect_identical(r2$output$text, '[1] "user"')
  # Already loaded: nothing resets it, so no note.
  r3 <- run_and_wait(h, "l", 4L, "library(emberfix1)", settings = "s")
  expect_identical(r3$load_notes, list())
})

test_that("the note's advice: the setting moved into the loading cell, after the load, keeps it and gives no note (#61)", {
  h <- worker_harness(extra_libs = fixture_lib())
  on.exit(h$close())
  r <- run_and_wait(h, "l", 1L, 'library(emberfix1); options(emberfix_load_opt = "user")')
  expect_identical(r$load_notes, list())
  expect_identical(r$settings[[1]]$name, "emberfix_load_opt")
  r2 <- run_and_wait(h, "c", 2L, 'getOption("emberfix_load_opt")', settings = "l")
  expect_identical(r2$output$text, '[1] "user"')
})

test_that("a load through requireNamespace() names the package in its note (#61)", {
  h <- worker_harness(extra_libs = fixture_lib())
  on.exit(h$close())
  run_and_wait(h, "s", 1L, 'options(emberfix_load_opt = "user")')
  r <- run_and_wait(h, "l", 2L, 'requireNamespace("emberfix1", quietly = TRUE)', settings = "s")
  expect_identical(r$load_notes, list(list(package = "emberfix1", kind = "option", name = "emberfix_load_opt")))
})

test_that("a package load gets no note when no settings cell set what it changes (#61)", {
  h <- worker_harness(extra_libs = fixture_lib())
  on.exit(h$close())
  # attach() in a settings cell makes the search path differ from the
  # start; library() attaching a package is not a reset of it.
  run_and_wait(h, "s", 1L, "attach(data.frame(emberfix_col = 1))")
  r <- run_and_wait(h, "l", 2L, "library(emberfix1)", settings = "s")
  expect_identical(r$status, "ok")
  expect_identical(r$load_notes, list())
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

test_that("library_stays_invisible", {
  flib <- fixture_lib()
  h <- worker_harness(extra_libs = flib)
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "library(emberfix1)\n1", order = "a")
  expect_identical(r$status, "ok")
  expect_length(r$console, 0)
  expect_identical(r$output$text, "[1] 1")
  r2 <- run_and_wait(h, "b", 2L, "require(emberfix1)", order = c("a", "b"))
  expect_null(r2$output)
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

test_that("a file under the worker's own tempdir() isn't reported as a source: the session generated it (Rcpp's cppFunction()) and it is gone next session (#165)", {
  h <- worker_harness()
  on.exit(h$close())
  code <- 'f <- tempfile(fileext = ".R"); writeLines("tv <- 7", f); source(f); tv'
  h$send(run_msg("a", 1L, code))
  seen_source <- FALSE
  r <- wait_for_done(h, on_frame = function(m) {
    if (identical(m$type, "source")) {
      seen_source <<- TRUE
      h$send(list(type = "source_reply", allow = TRUE))
    }
  })
  expect_false(seen_source)
  expect_identical(r$status, "ok")
  expect_identical(r$output$text, "[1] 7")
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

test_that("the formula check reads a data call's columns without running it (#42)", {
  h <- worker_harness()
  on.exit(h$close())
  site <- function(data, columns) {
    list(index = 1L, line = 1L, col = NA_integer_, end_col = NA_integer_,
         fn = "lm", data = data, columns = columns)
  }
  code <- paste("z <- 1:2; df <- data.frame(x = 1:4, y = c(2, 4, 6, 9))",
                "fit <- lm(y ~ x + z, data = subset(df, x > 2))", sep = "\n")
  r <- run_and_wait(h, "a", 1L, code,
                    formulas = list(site("subset(df, x > 2)", c("x", "z"))))
  expect_identical(r$status, "ok")
  expect_identical(r$formula_misses, "z")

  # Nested calls, an empty argument, pkg::, %>%, and the names
  # transform() adds.
  r2 <- run_and_wait(h, "b", 2L, "1", formulas = list(
    site("head(df[df$x > 1, ], n = 2)", c("x", "w")),
    site("base::subset(df, x > 1)", c("x", "v")),
    site("df %>% head(2)", c("x", "u")),
    site("transform(head(df), w = x * 2)", c("x", "w")),
    site("transform(df, w = x * 2, cbind(t = x))", "t")))
  expect_setequal(r2$formula_misses, c("w", "v", "u"))

  # A call the check can't read, or a notebook's own function of a listed
  # name, leaves the formula unchecked.
  r3 <- run_and_wait(h, "c", 3L, paste(
    "keep <- function(d) d",
    "tail <- function(d, ...) d", sep = "\n"),
    formulas = list(site("keep(df)", "w"), site("head(keep(df))", "w"),
                    site("tail(df)", "w"), site("merge(df, df)", "w")))
  expect_identical(r3$formula_misses, character())
})

test_that("dplyr calls that name columns are read by their named arguments, or not at all (#42)", {
  # Written as dplyr::f(), which the check resolves by name alone, so this
  # runs without dplyr installed: the check never calls the function.
  h <- worker_harness()
  on.exit(h$close())
  site <- function(data, columns) {
    list(index = 1L, line = 1L, col = NA_integer_, end_col = NA_integer_,
         fn = "lm", data = data, columns = columns)
  }
  r <- run_and_wait(h, "a", 1L, "df <- data.frame(year = c(1990, 2001), y = 1:2)",
    formulas = list(
      site("dplyr::group_by(df, decade = year %/% 10)", "decade"),
      site("dplyr::distinct(df, k = year %% 2)", "k"),
      site("dplyr::select(df, yr = year)", "yr"),
      site("dplyr::mutate(df, across(year, log, .names = '{.col}_log'))", "year_log"),
      site("dplyr::filter(df, year > 1995)", c("year", "z"))))
  expect_identical(r$status, "ok")
  expect_identical(r$formula_misses, "z")
})

test_that("the formula check never runs a notebook's method on its data again (#42)", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, paste(
    "calls <- 0",
    "head.logged <- function(x, ...) { calls <<- calls + 1; NextMethod() }",
    "`[.logged` <- function(x, ...) { calls <<- calls + 1; NextMethod() }",
    "obj <- structure(data.frame(x = 1:3, y = c(1, 3, 2)), class = c('logged', 'data.frame'))",
    sep = "\n"))
  sites <- list(
    list(index = 1L, line = 1L, col = NA_integer_, end_col = NA_integer_,
         fn = "lm", data = "head(obj)", columns = c("x", "w")),
    list(index = 2L, line = 1L, col = NA_integer_, end_col = NA_integer_,
         fn = "lm", data = "obj[obj$x > 1, ]", columns = "x"))
  r <- run_and_wait(h, "b", 2L, "before <- calls; fit <- lm(y ~ x, data = head(obj)); calls - before",
                    formulas = sites)
  expect_identical(r$status, "ok")
  expect_identical(r$formula_misses, "w")
  # The cell's own run called the methods (head.data.frame indexes with
  # `[`); the check after it called neither.
  r2 <- run_and_wait(h, "c", 3L, "calls")
  expect_identical(r2$output$text, r$output$text)
  expect_false(identical(r2$output$text, "[1] 0"))
})

test_that("fresh_device_per_cell", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, "par(mfrow = c(2, 2)); plot(1)")
  r <- run_and_wait(h, "b", 2L, 'par("mfrow")')
  expect_identical(r$output$text, "[1] 1 1")
})

test_that("display_plot_value() doesn't open a new default device (no Rplots.pdf) for a visible plot value", {
  h <- worker_harness()
  on.exit(h$close())
  wd <- tempfile("ember-plot-wd-")
  dir.create(wd)
  run_and_wait(h, "a", 1L, sprintf("setwd(%s)", deparse(wd)))
  # lattice ships with every R install, and a trellis object (like ggplot)
  # is a *visible value* display_plot_value() handles, as opposed to
  # base graphics' side-effect plotting (display_plot(), base_plot_output
  # below).
  r <- run_and_wait(h, "b", 2L, "library(lattice); xyplot(1 ~ 1)")
  expect_identical(r$status, "ok")
  expect_identical(r$output$kind, "plot")
  expect_false(file.exists(file.path(wd, "Rplots.pdf")))
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
  rendered <- h$receive()
  expect_identical(rendered$type, "rendered")
  dims <- png_dims(rendered$display$data)
  expect_identical(dims, list(width = 200, height = 150))
})

test_that("run_cell() opens the device at the cell's figure size and a 2x density (ui-3 64)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "plot(1:10)")
  expect_identical(png_dims(r$output$data), list(width = 1440, height = 960))
  expect_identical(r$output$size, list(width = 1440, height = 960, res = 192))

  r2 <- run_and_wait(h, "b", 2L, "plot(1:10)", fig = list(width = 8, height = 4))
  expect_identical(png_dims(r2$output$data), list(width = 1536, height = 768))
  expect_identical(r2$output$size, list(width = 1536, height = 768, res = 192))

  # A 40 in side would draw at 7680 px at 192 dpi, over the 6000 px limit
  # (unreachable through cell_figure_size()'s own 0.5-30 range, but this
  # message is built by hand, as the worker must still defend against it).
  r3 <- run_and_wait(h, "c", 3L, "plot(1:10)", fig = list(width = 40, height = 40))
  expect_identical(png_dims(r3$output$data), list(width = 6000, height = 6000))
  expect_identical(r3$output$size, list(width = 6000, height = 6000, res = 150))
})

test_that("a bad #| value's problem is reported as a console warning (ui-3 64)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "plot(1:10)",
                    fig = list(width = 7.5, height = 5,
                              problems = "#| fig-width: wide is not a number of inches; using 7.5."))
  warnings <- Filter(function(it) identical(it$kind, "warning"), r$console)
  expect_length(warnings, 1)
  expect_match(warnings[[1]]$text, "fig-width: wide is not a number of inches")
})

test_that("render_plot() caps a redraw at MAX_FIGURE_PX, even at the server's top res (review: render_plot size cap)", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, "plot(1:10)", fig = list(width = 30, height = 30))

  h$send(list(type = "render", cell = "a", res = 384L))
  m <- wait_for_done_or_rendered(h)
  expect_identical(m$type, "rendered")
  dims <- png_dims(m$display$data)
  expect_lte(dims$width, 6000)
  expect_lte(dims$height, 6000)
  expect_lte(m$display$size$width, 6000)
  expect_lte(m$display$size$height, 6000)
})

test_that("render_plot() and open_device() don't crash the worker on a hand-built, malformed fig", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "plot(1:10)", fig = list(width = NULL, height = 5))
  expect_identical(r$status, "ok")
  expect_identical(r$output$kind, "plot")

  # render_plot() with no recorded display (an unreplayable or missing
  # record) reports display = NULL rather than erroring.
  h$send(list(type = "render", cell = "nonexistent", res = 96L))
  m <- h$receive()
  expect_identical(m$type, "rendered")
  expect_null(m$display)

  # the worker is still alive and answering afterwards
  r2 <- run_and_wait(h, "b", 2L, "1 + 1")
  expect_identical(r2$status, "ok")
})

test_that("summarise_globals(): a data frame, a number, a character vector cut at 80 chars (ui-3 68)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "cars <- mtcars[1:21, 1:3]\ncutoff <- 4\nlabels <- rownames(mtcars)")

  expect_equal(r$globals$cars$type, "data.frame")
  expect_equal(r$globals$cars$kind, "shape")
  expect_equal(r$globals$cars$value, "21 rows \u00d7 3 columns")

  expect_equal(r$globals$cutoff$type, "numeric")
  expect_equal(r$globals$cutoff$kind, "value")
  expect_equal(r$globals$cutoff$value, "4")

  expect_equal(r$globals$labels$kind, "value")
  expect_true(startsWith(r$globals$labels$value, "\"Mazda RX4\" \"Mazda RX4 Wag\""))
  expect_true(endsWith(r$globals$labels$value, "\u2026"))
  expect_lte(nchar(r$globals$labels$value), 80)
})

test_that("summarise_globals(): a model fit (str), a function, NULL, character(0), a Date and a matrix (ui-3 68)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, paste(
    "fit <- lm(mpg ~ wt, mtcars)",
    "stat <- function(d, i) 1",
    "nothing <- NULL",
    "empty <- character(0)",
    "today <- Sys.Date()",
    "m <- matrix(1:12, nrow = 3, ncol = 4)",
    sep = "\n"))

  expect_equal(r$globals$fit$type, "lm")
  expect_equal(r$globals$fit$kind, "str")
  expect_equal(r$globals$fit$value, "List of 12")

  expect_equal(r$globals$stat$kind, "value")
  expect_equal(r$globals$stat$value, "function(d, i)")

  expect_equal(r$globals$nothing$kind, "value")
  expect_equal(r$globals$nothing$value, "NULL")

  expect_equal(r$globals$empty$kind, "value")
  expect_equal(r$globals$empty$value, "character(0)")

  expect_equal(r$globals$today$type, "Date")
  expect_equal(r$globals$today$kind, "value")

  expect_equal(r$globals$m$kind, "shape")
  expect_equal(r$globals$m$value, "3 rows \u00d7 4 columns")
})

test_that("summarise_globals(): an active binding is never called; a failing str() gives kind none (ui-3 68)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, paste(
    "n_calls <- 0",
    "makeActiveBinding('counter', function() { n_calls <<- n_calls + 1; n_calls }, environment())",
    "bad <- structure(list(), class = 'breaks_str')",
    "str.breaks_str <- function(object, ...) stop('nope')",
    sep = "\n"))

  expect_equal(r$globals$counter$type, "active binding")
  expect_equal(r$globals$counter$kind, "none")
  expect_null(r$globals$counter$value)
  # the binding was never invoked by the summary: still at its initial 0
  expect_equal(r$globals$n_calls$value, "0")

  expect_equal(r$globals$bad$kind, "none")
  expect_null(r$globals$bad$value)
})

test_that("summarise_globals(): the over-budget path doesn't call an active binding either (review: active binding budget)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, paste(
    "aaa_slow <- Sys.Date()",
    "format.Date <- function(x, ...) { Sys.sleep(1); 'slow' }",
    "n_calls <- 0",
    "makeActiveBinding('zzz_counter', function() { n_calls <<- n_calls + 1; n_calls }, environment())",
    sep = "\n"))

  expect_equal(r$globals$zzz_counter$type, "active binding")
  expect_equal(r$globals$zzz_counter$kind, "none")
  expect_null(r$globals$zzz_counter$value)

  # read n_calls for real, outside summarise_globals() entirely, so the
  # proof the binding was never invoked doesn't depend on n_calls's own
  # summary landing before or after the budget runs out.
  r2 <- run_and_wait(h, "b", 2L, "n_calls")
  expect_identical(r2$output$text, "[1] 0")
})

test_that("summarise_globals(): a slow method is bounded by its own time limit rather than holding up the whole report, and never leaks into a later run (review: setTimeLimit)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, paste(
    "slow <- Sys.Date()",
    "format.Date <- function(x, ...) { t0 <- Sys.time(); repeat if (as.numeric(Sys.time() - t0) > 30) break; 'slow' }",
    sep = "\n"))
  # A busy R loop, not Sys.sleep(): setTimeLimit() is checked while R code
  # runs and does not cut a sleep short. The budget is 0.25 s; a method
  # that ran its 30 s would have returned 'slow' and been summarised, so
  # "none" is the method cut short.
  expect_equal(r$globals$slow$kind, "none")

  r2 <- run_and_wait(h, "b", 2L, "1 + 1")
  expect_identical(r2$status, "ok")
  expect_identical(r2$output$text, "[1] 2")
})

test_that("summarise_globals(): a slow format() leaves later names (alphabetically) with kind none (ui-3 68)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, paste(
    "slow <- Sys.Date()",
    "format.Date <- function(x, ...) { Sys.sleep(1); 'slow' }",
    "zzz_after <- 1",
    sep = "\n"))

  expect_equal(r$globals$zzz_after$kind, "none")
})

test_that("run_cell() of a <- 1; .b <- 2 reports globals for both names; a rerun that drops a no longer reports it (ui-3 69)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "a <- 1; .b <- 2")
  expect_setequal(names(r$globals), c("a", ".b"))

  r2 <- run_and_wait(h, "a", 2L, ".b <- 2")
  expect_setequal(names(r2$globals), ".b")
})

test_that("summarise_globals(): a dot-name's value is never computed, type only (review: dot-name budget)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, ".b <- 1")
  expect_equal(r$globals$.b$type, "numeric")
  expect_equal(r$globals$.b$kind, "none")
  expect_null(r$globals$.b$value)
})

test_that("a failed run's globals are empty: the worker skips summarising them entirely (review: skip globals on failure)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "a <- 1; stop('boom')")
  expect_identical(r$status, "error")
  expect_equal(r$globals, list())
})

test_that("summarise_value(): a character NA shows unquoted, not \"NA\" in quotes (review)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, 'x <- c("a", NA, "b")')
  expect_equal(r$globals$x$value, '"a" NA "b"')
})

test_that("data_frame_table_view", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "data.frame(a = 1:3, b = letters[1:3])")
  expect_identical(r$output$kind, "table")
  expect_identical(r$output$mime, "application/vnd.ember.table")
  expect_identical(r$output$nrow, 3L)
  expect_identical(r$output$ncol, 2L)
  expect_identical(r$output$names, c("a", "b"))
  expect_identical(r$output$row_labels, c("1", "2", "3"))
  expect_identical(r$output$rows[[1]], c("1", "a"))
  expect_identical(r$output$rows[[3]], c("3", "c"))
  expect_identical(r$output$types, c("<int>", "<chr>"))
  expect_identical(r$output$more_rows, 0L)
  expect_identical(r$output$more_cols, 0L)
  expect_match(r$output$text, "^  a b")
})

test_that("build_table() reads columns by position: duplicate column names don't repeat the first one", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L,
                    "df <- data.frame(a = 1:3, b = 4:6); names(df) <- c('x', 'x'); df")
  expect_identical(r$output$names, c("x", "x"))
  expect_identical(r$output$rows[[1]], c("1", "4"))
  expect_identical(r$output$rows[[2]], c("2", "5"))
  expect_identical(r$output$rows[[3]], c("3", "6"))
})

test_that("build_table() formats a matrix column one value per row, with no NA on the wire", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L,
                    "data.frame(id = 1:3, m = I(matrix(1:6, nrow = 3)))")
  expect_identical(r$output$nrow, 3L)
  expect_length(r$output$rows, 3L)
  for (row in r$output$rows) expect_length(row, 2L)
  expect_identical(r$output$rows[[1]][2], "1, 4")
  expect_identical(r$output$rows[[2]][2], "2, 5")
  expect_identical(r$output$rows[[3]][2], "3, 6")
  expect_false(anyNA(unlist(r$output$rows)))
})

test_that("build_table() formats a nested data frame column one value per row, with no NA on the wire", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L,
                    "d <- data.frame(id = 1:2); d$nested <- data.frame(a = 1:2, b = 3:4); d")
  expect_identical(r$output$nrow, 2L)
  expect_length(r$output$rows, 2L)
  for (row in r$output$rows) expect_length(row, 2L)
  expect_identical(r$output$rows[[1]][2], "1, 3")
  expect_identical(r$output$rows[[2]][2], "2, 4")
  expect_false(anyNA(unlist(r$output$rows)))
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

test_that("a run says it began before its done", {
  h <- worker_harness()
  on.exit(h$close())
  h$send(run_msg("a", 7L, "1 + 1"))
  frames <- list()
  r <- wait_for_done(h, on_frame = function(m) frames[[length(frames) + 1]] <<- m)
  expect_identical(r$status, "ok")
  types <- vapply(frames, function(m) m$type, character(1))
  expect_identical(types[[1]], "running")
  expect_identical(frames[[1]]$token, 7L)
})

test_that("an interrupt sent on the running frame stops that run", {
  # The server sends SIGINT once it has a run's "running" frame
  # (reduce_wk_running(), step.R), so from that frame on an interrupt must
  # stop the cell. A "running" sent before run_cell()'s guarded block would
  # let this one be swallowed: the sleep would then finish "ok". The
  # timeout only catches a hang.
  h <- worker_harness()
  on.exit(h$close())
  for (i in 1:10) {
    h$send(run_msg(paste0("c", i), i, "Sys.sleep(5)"))
    r <- wait_for_done(h, on_frame = function(m) {
      if (identical(m$type, "running")) h$interrupt()
    })
    expect_identical(r$status, "interrupted")
  }
})

test_that("interrupt_r_code", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, "x <- 1; y <- 2")

  # An interrupt that arrives before the loop starts is swallowed between
  # runs (slow Windows runners), so wait for the loop to say it has begun.
  started <- tempfile()
  h$send(run_msg("b", 2L, sprintf(
    "writeLines('go', %s); t0 <- Sys.time(); repeat { if (as.numeric(Sys.time() - t0) > 10) break }",
    deparse(started))))
  waiting_for("the cell to start", while (!file.exists(started)) {
    if (!h$process$is_alive()) stop("the worker exited before the cell started")
    later::run_now(timeout = 0.05)
  })
  expect_true(file.exists(started))
  h$interrupt()
  r <- wait_for_done(h)
  # An unheeded interrupt runs the loop its full 10 s and ends "ok".
  expect_identical(r$status, "interrupted")

  check <- run_and_wait(h, "c", 3L, 'c(x, y)')
  expect_identical(check$output$text, "[1] 1 2")
})

test_that("on Windows a worker with no console is interrupted all the same (#48)", {
  # processx's interrupt() needs the worker to have a console, and one
  # started by a server without a console has none: every interrupt was
  # lost, while interrupt() said it was sent. The interrupt event needs no
  # console.
  skip_on_os(c("mac", "linux", "solaris"))
  h <- worker_harness(detached = TRUE)
  expect_true(isTRUE(h$hello$interrupts))
  on.exit(h$close())
  for (code in c("Sys.sleep(20)", "t0 <- Sys.time(); repeat if (Sys.time() - t0 > 20) break")) {
    h$send(run_msg("a", 1L, code))
    r <- wait_for_done(h, on_frame = function(m) {
      if (identical(m$type, "running")) expect_true(h$interrupt())
    })
    expect_identical(r$status, "interrupted")
  }
})

test_that("on Windows interrupting a process with no interrupt event says it wasn't delivered (#48)", {
  skip_on_os(c("mac", "linux", "solaris"))
  p <- processx::process$new(file.path(R.home("bin"), "Rscript"), c("--vanilla", "-e", "Sys.sleep(30)"))
  on.exit(p$kill())
  expect_false(interrupt_worker(p))
  expect_true(p$is_alive())
})

test_that("an interrupt just after a run's done doesn't stop the next run (#48)", {
  # The server sends the next run as soon as it has "done", so a late
  # interrupt and the next run can reach the worker together. One still
  # pending when the run starts is late, and must not stop it.
  h <- worker_harness()
  on.exit(h$close())
  for (i in 1:50) {
    h$send(run_msg(paste0("c", i), i, "1 + 1"))
    r <- wait_for_done(h)
    expect_identical(r$status, "ok")
    h$interrupt()
  }
  r <- run_and_wait(h, "last", 51L, "1 + 1")
  expect_identical(r$status, "ok")
})

test_that("on Windows a late interrupt the listener took but hasn't applied doesn't stop the next run (#238)", {
  # The window between the listener taking an interrupt and setting
  # UserBreak is a thread switch long; a test-only delay widens it to
  # 20 ms, so a drain that doesn't wait for the listener fails almost
  # every round.
  skip_on_os(c("mac", "linux", "solaris"))
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "delay", 1L, '.Call(getNativeSymbolInfo("C_interrupt_test_delay", "ember"), 20L)')
  expect_identical(r$status, "ok")
  for (i in 1:10) {
    h$send(run_msg(paste0("c", i), i + 1L, "1 + 1"))
    r <- wait_for_done(h)
    expect_identical(r$status, "ok")
    h$interrupt()
  }
  r <- run_and_wait(h, "last", 12L, "1 + 1")
  expect_identical(r$status, "ok")
})

test_that("interrupt_between_runs_swallowed", {
  h <- worker_harness()
  on.exit(h$close())
  h$interrupt()
  # Nothing to wait for. A worker waiting for a message holds the interrupt
  # while it reads (uninterrupted()) and passes it on once the next message
  # is read, so the top level takes it before this run starts.
  r <- run_and_wait(h, "a", 1L, "1 + 1")
  expect_identical(r$status, "ok")
  expect_identical(r$output$text, "[1] 2")
  # The trace names how the top level took it, so a worker that does die
  # of one can be told apart in a test's failure (#407). On Windows the
  # next run drains it instead (drain_late_interrupt()), so no line.
  if (.Platform$OS.type != "windows") {
    trace <- readLines(h$err_file, warn = FALSE)
    expect_true(any(grepl("interrupt at top level: (resumed|passed on)", trace)))
    expect_false(any(grepl("not resumable", trace)))
  }
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
    'repeat {',
    '  if (isTRUE(socketSelect(list(srv), timeout = 1))) {',
    '    con <- socketAccept(srv, blocking = TRUE, open = "a+b", timeout = 60 * 60 * 24)',
    '    break',
    '  }',
    '  if (!p$is_alive()) { cat("WORKER_EXITED\\n"); quit(status = 1) }',
    '}',
    'close(srv)',
    'write_frame <- function(con, msg) {',
    '  payload <- serialize(msg, NULL)',
    '  writeBin(length(payload), con, endian = "big"); writeBin(payload, con); flush(con)',
    '}',
    '# No time limit: a worker that exits closes the socket, and the read',
    '# then returns NULL.',
    'read_frame <- function(con) {',
    '  wait <- function() { while (!isTRUE(socketSelect(list(con), timeout = 1))) NULL; TRUE }',
    '  wait()',
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
    'hello <- read_frame(con)',
    'if (is.null(hello) || !identical(hello$type, "hello")) { cat("NO_HELLO\\n"); quit(status = 1) }',
    'write_frame(con, list(type = "run", cell = "a", token = 1L,',
    '  code = "t0<-Sys.time(); repeat { if (as.numeric(Sys.time()-t0) > 10) break }",',
    '  role = "cell", order = character(), formulas = list()))',
    '# Interrupt once the worker says the cell runs, as the server does.',
    'repeat {',
    '  m <- read_frame(con)',
    '  if (is.null(m)) { cat("NO_RUNNING\\n"); quit(status = 1) }',
    '  if (identical(m$type, "running")) break',
    '}',
    'p$interrupt()',
    'report <- NULL',
    'repeat {',
    '  m <- read_frame(con)',
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
  res <- run_guarded("sh", c("-c", shell_cmd), error_on_status = FALSE)
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
  h <- worker_harness()
  on.exit(h$close())
  started <- tempfile()
  run_and_wait(h, "a", 1L, sprintf(
    'registerS3method("print", "slowprint", function(x, ...) { writeLines("go", %s); Sys.sleep(3); cat("slow\\n") })',
    deparse(started)))
  h$send(run_msg("b", 2L, 'options(digits = 3); orphan <- 42; structure(1, class = "slowprint")'))
  # Interrupted while it prints, which it says it has begun.
  waiting_for("the cell to start", while (!file.exists(started)) {
    if (!h$process$is_alive()) stop("the worker exited before the cell started")
    later::run_now(timeout = 0.05)
  })
  expect_true(file.exists(started))
  h$interrupt()
  r <- wait_for_done(h)
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

  # the option b changed doesn't apply where b isn't in effect
  check2 <- run_and_wait(h, "d", 4L, 'getOption("digits")')
  expect_identical(check2$output$text, "[1] 7")
})

test_that("sigint_during_remove_cell_does_not_crash_worker", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, "x <- 1")
  h$send(list(type = "remove_cell", cell = "a", order = character()))
  h$interrupt()
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

test_that("format_generic_dispatches_from_notebook_globalenv_for_table_columns", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, paste(
    'format.weird <- function(x, ...) rep("formatted-weird", length(unclass(x)))',
    '"[.weird" <- function(x, i) structure(unclass(x)[i], class = "weird")',
    sep = "\n"))
  r <- run_and_wait(h, "b", 2L,
    'd <- data.frame(a = 1); d$a <- structure(d$a, class = "weird"); d')
  expect_identical(r$output$kind, "table")
  expect_identical(r$output$rows[[1]], "formatted-weird")
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

test_that("a package that attaches others keeps plain R's search order after a rebuild (#180)", {
  # emberfix4 attaches emberfix2 (Depends) before itself and emberfix1
  # (.onAttach) after, so plain R has emberfix1 above emberfix4 above
  # emberfix2. Rebuilding in the order the library() calls returned put
  # emberfix4 on top.
  flib <- fixture_lib()
  h <- worker_harness(extra_libs = flib)
  on.exit(h$close())
  run_and_wait(h, "a", 1L, "library(emberfix4)", order = c("a", "b"))
  run_and_wait(h, "b", 2L, "library(tools)", order = c("a", "b"))
  h$send(list(type = "remove_cell", cell = "b", order = "a"))
  r <- run_and_wait(h, "chk", 3L, 'grep("emberfix|tools", search(), value = TRUE)', order = c("a", "chk"))
  expect_identical(r$output$text, '[1] "package:emberfix1" "package:emberfix4" "package:emberfix2"')
})

test_that("a library() wrapper on the search path is used, missing arguments and all (#180)", {
  # emberfix3 is conflicted's case: `.emberfix3` at position 2, with a
  # library() that passes its missing arguments on, and a name that fails
  # when base library() reads it. Through Ember's own library() the
  # missing `exclude` arrived as given ("only one of 'include.only' and
  # 'exclude' can be used"), and the rebuild's base library() failed on
  # the name, so every package it attached again was lost.
  flib <- fixture_lib()
  h <- worker_harness(extra_libs = flib)
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "library(emberfix1); library(emberfix2); emberfix3::shield()",
                    order = c("a", "b", "chk"))
  expect_identical(r$status, "ok")
  r <- run_and_wait(h, "b", 2L, "library(tools)", order = c("a", "b", "chk"), settings = "a")
  expect_identical(r$status, "ok")
  h$send(list(type = "remove_cell", cell = "b", order = c("a", "chk")))
  r <- run_and_wait(h, "chk", 3L, 'grep("emberfix|tools", search(), value = TRUE)',
                    order = c("a", "chk"), settings = "a")
  expect_identical(r$output$text, '[1] ".emberfix3"        "package:emberfix2" "package:emberfix1"')
})

test_that("a caller's own default passed on to library() or require() is kept (#180 review)", {
  # Only a formal with no default is left out of the call; `lr` and `q`
  # have defaults, which base's must not replace.
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L,
    'ld <- function(p, lr = TRUE) library(p, character.only = TRUE, logical.return = lr); ld("tools")')
  expect_identical(r$output$text, "[1] TRUE")
  r <- run_and_wait(h, "b", 2L,
    'rq <- function(p, q = TRUE) require(p, character.only = TRUE, quietly = q); print(rq("stats4"))')
  expect_true(any(grepl("[1] TRUE", unlist(r$console), fixed = TRUE)))
  expect_false(any(grepl("Loading required package", unlist(r$console), fixed = TRUE)))
})

test_that("a search entry a package attaches for itself and that hides nothing is the package's (#181)", {
  flib <- fixture_lib()
  h <- worker_harness(extra_libs = flib)
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "emberfix5::stash(1)", order = c("a", "b"))
  expect_identical(r$status, "ok")
  expect_length(r$settings, 0)
  # It stays: the next cell's reset keeps it, as a package load's change.
  r <- run_and_wait(h, "b", 2L, '"org:emberfix5" %in% search()', order = c("a", "b"))
  expect_identical(r$output$text, "[1] TRUE")
})

test_that("a search entry that hides a name, or that the notebook attached, is still a setting (#181)", {
  flib <- fixture_lib()
  h <- worker_harness(extra_libs = flib)
  on.exit(h$close())
  # Package code attached it, but its nchar() wins over base's.
  r <- run_and_wait(h, "a", 1L, "emberfix5::prefer()", order = c("a", "b", "c"))
  expect_identical(r$settings[[1]]$kind, "search")
  expect_true(".emberfix5" %in% r$settings[[1]]$after)
  # Hides nothing, but a function a cell defined attached it.
  r <- run_and_wait(h, "b", 2L,
    'keep <- function() attach(list(.emberfix_kept = 1), name = "kept", pos = length(search())); keep()',
    order = c("a", "b", "c"))
  expect_true("kept" %in% r$settings[[1]]$after)
  # Not in effect for this run, so the reset takes both off again.
  r <- run_and_wait(h, "c", 3L, 'c(".emberfix5", "kept") %in% search()', order = c("a", "b", "c"))
  expect_identical(r$output$text, "[1] FALSE FALSE")
})

test_that("drop_globals removes a cell's globals but keeps its attached packages (ui-3 12)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "x <- 1; library(tools); 2", order = c("a", "chk"))
  expect_identical(r$status, "ok")
  expect_true("x" %in% r$created)

  h$send(list(type = "drop_globals", cell = "a"))
  r2 <- run_and_wait(h, "chk", 2L,
    'c(has_x = exists("x", envir = globalenv(), inherits = FALSE), has_tools = "package:tools" %in% search())',
    order = c("a", "chk"))
  expect_identical(r2$output$text,
    paste(utils::capture.output(print(c(has_x = FALSE, has_tools = TRUE))), collapse = "\n"))

  r3 <- run_and_wait(h, "a", 3L, "x <- 2", order = c("a", "chk"))
  expect_identical(r3$status, "ok")
  expect_true("x" %in% r3$created)
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
  expect_identical(r$error$call, "library(notapkg)")
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

  # Changing LC_MESSAGES in a settings cell applies to the cells it is in
  # effect for; if the locale isn't installed on this machine, skip rather
  # than fail on an environment difference.
  set_locale <- run_and_wait(h, "setup", 1L, 'Sys.setlocale("LC_MESSAGES", "fr_FR.UTF-8")')
  if (identical(set_locale$status, "error") ||
      !identical(set_locale$output$text, '[1] "fr_FR.UTF-8"')) {
    skip("fr_FR.UTF-8 locale not available on this machine")
  }

  r <- run_and_wait(h, "a", 2L, "library(notapkg)", settings = "setup")
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

# ---- Rich outputs (ui-2-tests.md 22-28) --------------------------------------

test_that("classed list objects print instead of becoming a tree (3a, 22)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "lm(mpg ~ wt, mtcars)")
  expect_identical(r$output$kind, "text")
  expect_match(r$output$text, "Coefficients")

  r2 <- run_and_wait(h, "b", 2L, "t.test(1:10, 2:11)")
  expect_identical(r2$output$kind, "text")
  expect_match(r2$output$text, "t = ")

  r3 <- run_and_wait(h, "c", 3L, "list(a = 1)")
  expect_identical(r3$output$kind, "tree")

  r4 <- run_and_wait(h, "d", 4L, "mtcars")
  expect_identical(r4$output$kind, "table")
})

test_that("display_table shape and tricky frames (23)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "mtcars")
  expect_identical(length(r$output$names), 8L)
  expect_true(all(r$output$types == "<dbl>"))
  expect_identical(r$output$nrow, 32L)
  expect_identical(r$output$ncol, 11L)
  expect_identical(length(r$output$rows), 10L)
  expect_identical(r$output$row_labels[1], "Mazda RX4")
  expect_identical(r$output$more_rows, 22L)
  expect_identical(r$output$more_cols, 3L)

  r2 <- run_and_wait(h, "b", 2L,
    'data.frame(ok = 1:2, bad = I(list(1, 2)))')
  # a column whose format() errors (a list-column via I()) shows <error>,
  # the rest of the table intact
  expect_identical(r2$output$rows[[1]][1], "1")

  r3 <- run_and_wait(h, "c", 3L, "data.frame(a = integer())")
  expect_identical(r3$output$names, "a")
  expect_identical(length(r3$output$rows), 0L)

  r4 <- run_and_wait(h, "d", 4L, "data.frame()[, FALSE]")
  expect_identical(r4$output$names, character())
})

test_that("display_tree depth, width and leaf text (24)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L,
    "list(l1 = list(l2 = list(l3 = list(l4 = 1:10))))")
  # at depth 4 (the 5th level), a longer vector is still its own "vector"
  # leaf, not str()'s text: the depth limit stops list recursion, not
  # vector formatting.
  find <- function(node, keys) if (length(keys) == 0) node else find(
    Find(function(it) it$key == keys[1], node$items)$value, keys[-1])
  leaf <- find(r$output$tree, c("l1", "l2", "l3", "l4"))
  expect_identical(leaf$type, "vector")

  r2 <- run_and_wait(h, "b", 2L, "as.list(1:100)")
  expect_identical(length(r2$output$tree$items), 20L)
  expect_identical(r2$output$tree$more, 80L)
  expect_identical(r2$output$tree$items[[1]]$key, "")

  # A length-1 value stays plain text; a longer plain vector becomes its
  # own "vector" leaf (ui-3-tests 132), not str()'s one-line summary.
  r3 <- run_and_wait(h, "c", 3L, "list(x = 1, y = 1:10)")
  expect_identical(r3$output$tree$items[[1]]$value$text, "1")
  expect_identical(r3$output$tree$items[[2]]$value$type, "vector")
  expect_identical(r3$output$tree$items[[2]]$value$values, format(1:10, trim = TRUE))
  expect_identical(r3$output$tree$items[[2]]$value$type_sum, "int")
  expect_identical(r3$output$tree$items[[2]]$value$length, 10L)
})

test_that("display_tree treats an NA list name as unnamed text, not a nil key", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, 'l <- list(1, 2); names(l) <- c("a", NA); l')
  expect_identical(r$output$tree$items[[1]]$key, "a")
  expect_identical(r$output$tree$items[[2]]$key, "<NA>")
  expect_false(anyNA(vapply(r$output$tree$items, `[[`, character(1), "key")))
})

test_that("build_table() reports na, per row, atomic columns only (ui-3-tests 131)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "data.frame(a = c(1, NA), b = c('x', NA))")
  expect_identical(r$output$na, list(integer(), c(1L, 2L)))

  r2 <- run_and_wait(h, "b", 2L, "data.frame(a = 1:2, bad = I(list(1, NA)))")
  expect_identical(r2$output$na, list(integer(), integer()))
})

test_that("display_tree_node() on a long vector gives type vector; length 1 and a factor stay text (ui-3-tests 132)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "list(long = 1:100)")
  item <- r$output$tree$items[[1]]$value
  expect_identical(item$type, "vector")
  expect_identical(item$values, format(1:10, trim = TRUE))
  expect_identical(item$type_sum, "int")
  expect_identical(item$length, 100L)

  r2 <- run_and_wait(h, "b", 2L, "list(one = 1L, f = factor(c('a', 'b')))")
  expect_identical(r2$output$tree$items[[1]]$value$type, "text")
  expect_identical(r2$output$tree$items[[2]]$value$type, "text")
})

test_that("display_tree_node(): a matrix stays text, character values are quoted, a named vector keeps its names (item 3)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L,
    "list(m = matrix(1:4, 2), s = letters[1:3], n = c(x = 1, y = 2, z = 3))")
  items <- r$output$tree$items
  # A matrix has no class attribute but has dim(): it must stay a text
  # leaf, not become a vector leaf that drops its shape.
  expect_identical(items[[1]]$value$type, "text")
  # Character values are quoted the way print() shows them, not left bare
  # by format().
  expect_identical(items[[2]]$value$type, "vector")
  expect_identical(items[[2]]$value$values, c('"a"', '"b"', '"c"'))
  # A named vector must not silently lose its names by becoming an
  # anonymous vector leaf.
  expect_identical(items[[3]]$value$type, "text")
})

test_that("more pages a table and a tree, reset on rerun (25)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, "mtcars")
  h$send(list(type = "more", cell = "a", path = "", dim = 1L))
  m1 <- wait_for_done_or_rendered(h)
  expect_identical(m1$type, "rendered")
  expect_identical(m1$token, 1L)
  expect_identical(length(m1$display$rows), 32L)

  h$send(list(type = "more", cell = "a", path = "", dim = 2L))
  m2 <- wait_for_done_or_rendered(h)
  expect_identical(m2$display$ncol - m2$display$more_cols, 11L)

  r2 <- run_and_wait(h, "b", 2L, "as.list(1:100)")
  h$send(list(type = "more", cell = "b", path = "", dim = 1L))
  m3 <- wait_for_done_or_rendered(h)
  expect_identical(length(m3$display$tree$items), 80L)
  expect_identical(m3$token, 2L)

  r3 <- run_and_wait(h, "a", 3L, "mtcars")   # rerun: limits start over
  expect_identical(length(r3$output$rows), 10L)
})

test_that("display_html resolves and dedupes dependencies, skipped without htmltools (26)", {
  skip_if_not_installed("htmltools")
  h <- worker_harness(extra_libs = dirname(find.package("htmltools")))
  on.exit(h$close())
  td <- tempfile()
  dir.create(td)
  writeLines("x", file.path(td, "a.js"))
  writeLines("y", file.path(td, "a.css"))
  code <- sprintf(paste(
    'd1 <- htmltools::htmlDependency("mylib", "1.0", src = c(file = %s), script = "a.js", stylesheet = "a.css")',
    'd2 <- htmltools::htmlDependency("mylib", "2.0", src = c(file = %s), script = "a.js")',
    'htmltools::attachDependencies(htmltools::tags$div("hi"), list(d1, d2))',
    sep = "\n"), deparse(td), deparse(td))
  r <- run_and_wait(h, "a", 1L, code)
  expect_identical(r$output$kind, "html")
  expect_length(r$output$deps, 1)
  expect_identical(r$output$deps[[1]]$version, "2.0")
  expect_identical(normalizePath(r$output$deps[[1]]$dir), normalizePath(td))
  expect_identical(r$output$deps[[1]]$script, "a.js")
})

test_that("a cell that changes another cell's environment in place reports it; reading it, rebinding it or changing its own doesn't (#167)", {
  h <- worker_harness()
  on.exit(h$close())

  # An R6-like object: public fields in one environment, private ones two
  # levels down, as R6 keeps them.
  run_and_wait(h, "a", 1L, paste(
    "cnt <- new.env()",
    "cnt$n <- 0",
    "cnt$.__enclos_env__ <- new.env()",
    "cnt$.__enclos_env__$self <- cnt",
    "cnt$.__enclos_env__$private <- new.env()",
    "cnt$.__enclos_env__$private$hits <- 0",
    "cnt$add <- function() cnt$n <- cnt$n + 1",
    "cnt$hit <- function() cnt$.__enclos_env__$private$hits <- 1",
    "x <- 1", sep = "\n"))
  r <- run_and_wait(h, "b", 2L, "cnt$add()")
  expect_identical(r$status, "ok")
  expect_identical(r$changed_in_place, "cnt")
  r <- run_and_wait(h, "c", 3L, "cnt$hit()")
  expect_identical(r$changed_in_place, "cnt")
  r <- run_and_wait(h, "d", 4L, "assign('m', 1, envir = cnt)")
  expect_identical(r$changed_in_place, "cnt")

  # Reading it, or setting a binding to the value it already has, isn't a change.
  r <- run_and_wait(h, "e", 5L, "cnt$n\nls(cnt)")
  expect_length(r$changed_in_place, 0)
  # A cell's own environment is its own to change.
  r <- run_and_wait(h, "f", 6L, "mine <- new.env()\nmine$v <- 1")
  expect_length(r$changed_in_place, 0)
  r <- run_and_wait(h, "f", 7L, "mine <- new.env()\nmine$v <- 2")
  expect_length(r$changed_in_place, 0)
  # Rebinding the name is a change of the name (the server's "Multiple
  # definitions"), not of its contents.
  r <- run_and_wait(h, "g", 8L, "cnt <- new.env()")
  expect_length(r$changed_in_place, 0)
  # A reference class object copies a method into itself on its first
  # call, which isn't a change; setting a field is.
  run_and_wait(h, "r", 9L, paste(
    'A <- setRefClass("A", fields = list(n = "numeric"), methods = list(get = function() n, inc = function() n <<- n + 1))',
    "a <- A$new(n = 0)", sep = "\n"))
  r <- run_and_wait(h, "s", 10L, "a$get()")
  expect_length(r$changed_in_place, 0)
  r <- run_and_wait(h, "t", 11L, "a$inc()")
  expect_identical(r$changed_in_place, "a")
  # A reticulate object caches `simple` in its environment on its first
  # py_to_r(), which isn't a change (#259). Shaped like one, so the test
  # needs no Python; held inside another environment too.
  run_and_wait(h, "p", 14L, paste(
    "py <- structure(new.env(), class = c('pandas.DataFrame', 'python.builtin.object'))",
    "py$pyobj <- 1\npy$convert <- TRUE",
    "holder <- new.env()\nholder$py <- py", sep = "\n"))
  r <- run_and_wait(h, "q", 15L, "assign('simple', TRUE, envir = py)")
  expect_length(r$changed_in_place, 0)
  r <- run_and_wait(h, "q", 16L, "assign('simple2', TRUE, envir = holder$py)")
  expect_length(r$changed_in_place, 0)
  # A namespace held in a global isn't read.
  run_and_wait(h, "h", 12L, "ns <- asNamespace('stats')")
  r <- run_and_wait(h, "i", 13L, "1")
  expect_identical(r$status, "ok")
  expect_length(r$changed_in_place, 0)
})

test_that("a call that changes a closure's environment reports the closure; calling a top-level function, an S4 generic or a package's doesn't (#333)", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, paste(
    "counter <- local({ n <- 0L; function() { n <<- n + 1L; n } })",
    "memo <- (function(f) { cache <- new.env(); function(x) { k <- as.character(x); if (is.null(cache[[k]])) cache[[k]] <- f(x); cache[[k]] } })(sqrt)",
    "shown <- (function(x) function() x)(42)",
    "top <- function() 1",
    "setGeneric('area', function(s) standardGeneric('area'))",
    "setClass('Sq', representation(w = 'numeric'))",
    "setMethod('area', 'Sq', function(s) s@w^2)",
    "setClass('Sq2', contains = 'Sq')",
    "sd_of <- stats::sd", sep = "\n"))
  r <- run_and_wait(h, "b", 2L, "counter()")
  expect_identical(r$status, "ok")
  expect_identical(r$changed_in_place, "counter")
  r <- run_and_wait(h, "c", 3L, "memo(4)")
  expect_identical(r$changed_in_place, "memo")
  # A second call finds it in the cache, which changes nothing.
  r <- run_and_wait(h, "c", 4L, "memo(4)")
  expect_length(r$changed_in_place, 0)
  # Forcing the promise a factory's argument is kept in isn't a change.
  r <- run_and_wait(h, "d", 5L, "shown()")
  expect_length(r$changed_in_place, 0)
  # Dispatch on a subclass caches the inherited method in the generic's
  # environment, which isn't a change.
  r <- run_and_wait(h, "e", 6L, "top()\narea(new('Sq2', w = 2))\nsd_of(1:3)")
  expect_identical(r$status, "ok")
  expect_length(r$changed_in_place, 0)
})

test_that("taking the in-place fingerprint forces no promise, and a big environment is skipped without turning the check off for the others (#167)", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, paste(
    "forced <- 0",
    "le <- new.env()",
    "delayedAssign('x', { forced <<- forced + 1; 42 }, assign.env = le)",
    "delayedAssign('bad', stop('never read'), assign.env = le)",
    "d <- new.env(hash = TRUE)",
    "for (i in seq_len(20000)) assign(paste0('k', i), i, envir = d)",
    "cnt <- new.env()",
    "cnt$n <- 0", sep = "\n"))
  r <- run_and_wait(h, "b", 2L, "1")
  expect_length(r$changed_in_place, 0)
  r <- run_and_wait(h, "c", 3L, "forced")
  expect_identical(r$output$text, "[1] 0")
  # After the skipped dictionary and the environment holding a promise that
  # errors, a change to the next object is still reported.
  r <- run_and_wait(h, "e", 4L, "cnt$n <- 1")
  expect_identical(r$changed_in_place, "cnt")
  # Forcing a promise isn't a change; assigning over it is.
  r <- run_and_wait(h, "f", 5L, "le$x")
  expect_length(r$changed_in_place, 0)
  r <- run_and_wait(h, "g", 6L, "assign('x', 1, envir = le)")
  expect_identical(r$changed_in_place, "le")
})

console_kinds <- function(r) vapply(r$console, `[[`, character(1), "kind")
console_texts <- function(r) vapply(r$console, `[[`, character(1), "text")

test_that("a value's print method's warnings and messages go to the console once, after the cell's own (#183)", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "m", 1L, paste(
    'print.noisy <- function(x, ...) {',
    '  warning("from print"); message("said by print"); cat("noisy\\n"); invisible(x)',
    '}', sep = "\n"))
  r <- run_and_wait(h, "a", 2L, 'warning("own"); structure(1, class = "noisy")', order = c("m", "a"))
  expect_identical(r$status, "ok")
  expect_identical(r$output$text, "noisy")
  expect_identical(console_kinds(r), c("warning", "warning", "message"))
  expect_identical(console_texts(r), c("own", "from print", "said by print\n"))
  # A list with a class prints too, through the same one call.
  r <- run_and_wait(h, "b", 3L, 'structure(list(a = 1), class = "noisy")', order = c("m", "b"))
  expect_identical(console_texts(r), c("from print", "said by print\n"))
})

test_that("a plot's warnings come from its one draw, not again from its text form (#183)", {
  h <- worker_harness()
  on.exit(h$close())
  # As ggplot2's print method: it builds the plot, and warns, when it draws.
  run_and_wait(h, "m", 1L, paste(
    'print.gg <- function(x, ...) { warning("Removed 2 rows"); plot(1:3); invisible(x) }', sep = "\n"))
  r <- run_and_wait(h, "a", 2L, 'structure(list(), class = "gg")', order = c("m", "a"))
  expect_identical(r$status, "ok")
  expect_identical(r$output$kind, "plot")
  expect_identical(console_kinds(r), "warning")
  expect_identical(console_texts(r), "Removed 2 rows")
  # So does an assigned one.
  r <- run_and_wait(h, "b", 3L, 'p <- structure(list(), class = "gg")', order = c("m", "b"))
  expect_identical(r$output$kind, "plot")
  expect_identical(console_texts(r), "Removed 2 rows")
})

test_that("a table's warnings come from its print, not again from its cells (#183)", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "m", 1L, 'format.loud <- function(x, ...) { warning("formatting"); rep("L", length(x)) }')
  r <- run_and_wait(h, "a", 2L, 'data.frame(a = structure(1:2, class = "loud"))', order = c("m", "a"))
  expect_identical(r$output$kind, "table")
  expect_identical(console_texts(r), "formatting")
})

test_that("a knit_print() result's warnings show once; one that isn't used shows its print's warnings only when the next step doesn't raise them again, and its own never (#183, #193)", {
  skip_if_not_installed("knitr")
  h <- worker_harness(extra_libs = dirname(find.package("knitr")))
  on.exit(h$close())
  run_and_wait(h, "m", 1L, paste(
    'registerS3method("knit_print", "ember_kept", function(x, ...) {',
    '  warning("from knit_print"); knitr::asis_output("<b>shown</b>")',
    '}, envir = asNamespace("knitr"))',
    # As rmarkdown's knit_print() for data frames: it prints the value and
    # returns no knit_asis, so the value goes on to the next step.
    'registerS3method("knit_print", "ember_passed", function(x, ...) { print(x); invisible(NULL) },',
    '  envir = asNamespace("knitr"))',
    'print.ember_passed <- function(x, ...) { warning("from print"); print(unclass(x)) }',
    # A warning that fires once a session, as lifecycle's deprecate_warn().
    'print.ember_once <- function(x, ...) {',
    '  if (is.null(getOption("ember_warned"))) { options(ember_warned = TRUE); warning("only once") }',
    '  print(unclass(x))',
    '}',
    'registerS3method("knit_print", "ember_once", function(x, ...) { print(x); invisible(NULL) },',
    '  envir = asNamespace("knitr"))',
    'registerS3method("knit_print", "ember_own", function(x, ...) { warning("from a passed knit_print"); invisible(NULL) },',
    '  envir = asNamespace("knitr"))', sep = "\n"))
  r <- run_and_wait(h, "a", 2L, 'structure(1, class = "ember_kept")', order = c("m", "a"))
  expect_identical(r$output$html, "<b>shown</b>")
  expect_identical(console_texts(r), "from knit_print")
  # The next step's print raises it again: once.
  r <- run_and_wait(h, "b", 3L, 'structure(1, class = "ember_passed")', order = c("m", "b"))
  expect_identical(r$output$kind, "text")
  expect_identical(console_texts(r), "from print")
  # Raised only by the knit_print() that wasn't used: still shown.
  r <- run_and_wait(h, "c", 4L, 'structure(1, class = "ember_once")', order = c("m", "c"))
  expect_identical(r$output$kind, "text")
  expect_identical(console_texts(r), "only once")
  # One that printed nothing is only Ember trying it; plain R never calls it.
  r <- run_and_wait(h, "d", 5L, 'structure(1, class = "ember_own")', order = c("m", "d"))
  expect_identical(console_texts(r), character())
})

test_that("ggplot2's \"Removed n rows\" warning and geom_smooth()'s message show (#183)", {
  skip_if_not_installed("ggplot2")
  h <- worker_harness(extra_libs = .libPaths())
  on.exit(h$close())
  run_and_wait(h, "l", 1L, "library(ggplot2)", order = c("l", "a", "b"))
  r <- run_and_wait(h, "a", 2L, paste(
    'd <- data.frame(x = c(1, 2, NA), y = c(1, NA, 3))',
    'ggplot(d, aes(x, y)) + geom_point()', sep = "\n"), order = c("l", "a", "b"))
  expect_identical(r$output$kind, "plot")
  expect_identical(console_kinds(r), "warning")
  expect_match(console_texts(r), "Removed 2 rows")
  r <- run_and_wait(h, "b", 3L, "ggplot(mtcars, aes(wt, mpg)) + geom_smooth()", order = c("l", "a", "b"))
  expect_identical(r$output$kind, "plot")
  expect_identical(console_kinds(r), "message")
  expect_match(console_texts(r), "geom_smooth()", fixed = TRUE)
})

test_that("a cell that changes another cell's data.table in place with := or set*() reports it; reading it or rebinding it doesn't (#172)", {
  skip_if_not_installed("data.table")
  h <- worker_harness(extra_libs = dirname(find.package("data.table")))
  on.exit(h$close())
  ord <- c("l", letters[1:6])
  run_and_wait(h, "l", 1L, "library(data.table)", order = ord)
  run_and_wait(h, "a", 2L, "dt <- data.table(a = 1:3, x = c(1, 2, 3))", order = ord)
  for (code in c("dt[, b := a * 2]", "dt[, a := a * 10L]", "set(dt, j = 'c', value = 0)",
                 "setnames(dt, 'x', 'y')", "setkey(dt, a)", "setorder(dt, -a)", "dt[, b := NULL]")) {
    r <- run_and_wait(h, "c", 3L, code, order = ord)
    expect_identical(r$status, "ok", info = code)
    expect_identical(r$changed_in_place, "dt", info = code)
  }
  r <- run_and_wait(h, "d", 4L, "dt[a > 10L, .N]\nnames(dt)", order = ord)
  expect_length(r$changed_in_place, 0)
  # A rebinding is a change of the name, not of its contents.
  r <- run_and_wait(h, "e", 5L, "dt <- copy(dt)", order = ord)
  expect_length(r$changed_in_place, 0)
  # A cell's own table is its own to change.
  r <- run_and_wait(h, "f", 6L, "mine <- data.table(v = 1)\nmine[, w := 2]", order = ord)
  expect_length(r$changed_in_place, 0)
})

test_that("a cell ending in a data.table := shows nothing, as at the R console, and a later print() of the table still prints (#185)", {
  skip_if_not_installed("data.table")
  h <- worker_harness(extra_libs = dirname(find.package("data.table")))
  on.exit(h$close())
  ord <- c("l", letters[1:6])
  run_and_wait(h, "l", 1L, "library(data.table)\ndt <- data.table(a = 1:3)", order = ord)
  r <- run_and_wait(h, "a", 2L, "dt[, b := a * 2]", order = ord)
  expect_identical(r$status, "ok")
  expect_null(r$output)
  # Not the last expression: nothing goes to the console either.
  r <- run_and_wait(h, "a", 3L, "dt[, c := 1]\nncol(dt)", order = ord)
  expect_identical(r$output$text, "[1] 3")
  expect_length(r$console, 0)
  # `[]` after it shows the table, as at the console.
  r <- run_and_wait(h, "a", 4L, "dt[, d := 1][]", order = ord)
  expect_false(is.null(r$output))
  # The mark is cleared, so the table shows in the next cell.
  run_and_wait(h, "a", 5L, "dt[, e := 1]", order = ord)
  r <- run_and_wait(h, "b", 6L, "dt", order = ord)
  expect_false(is.null(r$output))
  # A mark left by a := that wasn't shown (inside invisible(), or in a
  # helper) doesn't blank the next cell that shows the table (review).
  run_and_wait(h, "a", 7L, "invisible(dt[, f := 1])", order = ord)
  r <- run_and_wait(h, "b", 8L, "dt", order = ord)
  expect_false(is.null(r$output))
  run_and_wait(h, "c", 9L, "add_g <- function(d) { d[, g := 1]; invisible(NULL) }", order = ord)
  run_and_wait(h, "a", 10L, "add_g(dt)", order = ord)
  r <- run_and_wait(h, "b", 11L, "dt", order = ord)
  expect_false(is.null(r$output))
  # Nor the same cell's last value.
  r <- run_and_wait(h, "a", 12L, "invisible(dt[, h := 1])\ndt", order = ord)
  expect_false(is.null(r$output))
})

test_that("a cell that writes some rows of another cell's data.table reports it, and one that only reads it doesn't (#201)", {
  skip_if_not_installed("data.table")
  h <- worker_harness(extra_libs = dirname(find.package("data.table")))
  on.exit(h$close())
  ord <- c("l", letters[1:6])
  run_and_wait(h, "l", 1L, "library(data.table)", order = ord)
  run_and_wait(h, "a", 2L, "dt <- data.table(a = 1:3, x = c(1, 2, 3), s = c('p', 'q', NA))", order = ord)
  run_and_wait(h, "b", 3L, "bump <- function(d) { d[1L, x := x + 1]; invisible() }", order = ord)
  for (code in c("dt[a > 1L, x := 0]", "set(dt, 1L, 'x', 99)", "data.table::set(dt, 2L, 'x', 1)",
                 "dt[2L, let(x = 5)]", "bump(dt)", "dt[3L, s := 'r']", "dt |> bump()")) {
    r <- run_and_wait(h, "c", 4L, code, order = ord)
    expect_identical(r$status, "ok", info = code)
    expect_identical(r$changed_in_place, "dt", info = code)
    expect_null(r$output)
    expect_length(r$console, 0)
  }
  # Writing the same value again changes nothing.
  r <- run_and_wait(h, "c", 5L, "dt[1L, a := 1L]", order = ord)
  expect_length(r$changed_in_place, 0)
  r <- run_and_wait(h, "c", 6L, "dt[a > 1L, .N]\nnrow(dt)\nsum(dt$x)", order = ord)
  expect_length(r$changed_in_place, 0)
  # A cell's own table is its own to change.
  r <- run_and_wait(h, "d", 7L, "mine <- data.table(v = 1:2)\nmine[1L, v := 5L]\nset(mine, 2L, 'v', 6L)", order = ord)
  expect_length(r$changed_in_place, 0)
  # Its writes are seen by the next cell that writes it.
  r <- run_and_wait(h, "e", 8L, "set(mine, 1L, 'v', 7L)", order = ord)
  expect_identical(r$changed_in_place, "mine")
  # A helper that writes the global itself, without being passed it (#216).
  run_and_wait(h, "b", 9L, "zero_dt <- function() { dt[1L, x := -1]; invisible() }", order = ord)
  r <- run_and_wait(h, "c", 10L, "zero_dt()", order = ord)
  expect_identical(r$changed_in_place, "dt")
  # A cell that passes the table to a function and changes nothing isn't
  # reported (review).
  run_and_wait(h, "b", 11L, "show_n <- function(d) nrow(d)", order = ord)
  r <- run_and_wait(h, "c", 12L, "show_n(dt)", order = ord)
  expect_identical(r$output$text, "[1] 3")
  expect_length(r$changed_in_place, 0)
  # data.table's set() through do.call() or under another name.
  for (code in c("do.call(set, list(dt, 1L, 'x', 41))", "upd <- data.table::set\nupd(dt, 1L, 'x', 42)")) {
    r <- run_and_wait(h, "c", 13L, code, order = ord)
    expect_identical(r$changed_in_place, "dt", info = code)
  }
  # Code run from text (#216).
  r <- run_and_wait(h, "c", 14L, "eval(parse(text = 'dt[1L, x := 43]'))", order = ord)
  expect_identical(r$changed_in_place, "dt")
})

test_that("a row write to a table held in another cell's list or environment, or bound to a second name, is reported under each name (#216)", {
  skip_if_not_installed("data.table")
  h <- worker_harness(extra_libs = dirname(find.package("data.table")))
  on.exit(h$close())
  ord <- c("l", letters[1:6])
  run_and_wait(h, "l", 1L, "library(data.table)", order = ord)
  run_and_wait(h, "a", 2L, paste("dt <- data.table(a = 1:3, x = c(1, 2, 3))",
                                 "tabs <- list(flights = data.table(x = 1:3), other = 1)",
                                 "box <- new.env()\nbox$t <- data.table(x = 1:3)", sep = "\n"), order = ord)
  for (code in c("tabs$flights[1L, x := 0L]", "tabs[['flights']][2L, x := 0L]", "set(box$t, 1L, 'x', 0L)",
                 "box$t[2L, x := 0L]")) {
    r <- run_and_wait(h, "c", 3L, code, order = ord)
    expect_identical(r$status, "ok", info = code)
    expect_identical(r$changed_in_place, if (startsWith(code, "tabs")) "tabs" else "box", info = code)
  }
  r <- run_and_wait(h, "c", 4L, "tabs$flights[x > 1L, .N]\nnrow(box$t)", order = ord)
  expect_length(r$changed_in_place, 0)
  r <- run_and_wait(h, "c", 5L, "with(tabs, flights[3L, x := 0L])", order = ord)
  expect_identical(r$changed_in_place, "tabs")
  # A second name for the same table, and a list holding it: all are named
  # (review).
  run_and_wait(h, "b", 6L, "alias <- dt\nheld <- list(t = dt)", order = ord)
  for (code in c("alias[1L, x := 0]", "dt[2L, x := 0]", "alias[, z := 1]", "held$t[3L, x := 0]")) {
    r <- run_and_wait(h, "c", 7L, code, order = ord)
    expect_setequal(r$changed_in_place, c("dt", "alias", "held"))
  }
})

test_that("which tables a cell's code could write: a write in a [, set*(), or a notebook function it's passed to (#201)", {
  skip_if_not_installed("data.table")
  e <- new.env(parent = baseenv())
  sys.source(worker_script_path(), e)
  loadNamespace("data.table")
  nb <- new.env(parent = globalenv())
  nb$f <- function(d) d
  environment(nb$f) <- globalenv()   # as a cell's function's is
  nb$set <- nb$upd <- getExportedValue("data.table", "set")
  cw <- function(code) e$datatable_could_write(as.list(parse(text = code)), c("dt", "other"), env = nb)
  for (code in c("dt", "dt[x > 1]", "dt[, .N, by = g]", "dt$x", "dt[['x']]", "nrow(dt)", "print(dt)",
                 "head(dt, 3)", "summary(dt)", "y <- data.table::copy(dt)", "dt2 <- dt[x > 1, .(x)]",
                 "mean(dt$x)", "lm(y ~ x, dt)", "merge(dt, other, by = 'a')", "lapply(list(dt), nrow)",
                 "x <- dt", "stats::lm(y ~ x, data = dt)", "dt[a %in% setdiff(p, q)]", "dt[, setNames(.SD, nm)]"))
    expect_identical(cw(code), character(), info = code)
  for (code in c("dt[i, x := 0]", "dt[, let(x = 1)]", "set(dt, 1L, 'x', 0)", "data.table::setkey(dt, a)",
                 "f(dt)", "dt |> f()", "not_defined_yet(dt)", "lapply(list(dt), f)", "do.call(f, list(dt))",
                 "Map(function(d) d[1L, x := 0], list(dt))", "dt[, f(dt)]", "g <- function() dt[1L, x := 0]",
                 "local(dt[1L, x := 0])", "do.call(set, list(dt, 1L, 'x', 0))",
                 "do.call(data.table::set, list(dt, 1L, 'x', 0))", "upd(dt, 1L, 'x', 0)"))
    expect_true("dt" %in% cw(code), info = code)
  expect_identical(cw("print(other)\nf(dt)"), "dt")
  # A table in a list or an environment, written through it (#216).
  for (code in c("other$t[1L, x := 0]", "other[['t']][1L, x := 0]", "set(other$t, 1L, 'x', 0)"))
    expect_identical(cw(code), "other", info = code)
  for (code in c("other$t[x > 1]", "nrow(other$t)", "other$t$x"))
    expect_identical(cw(code), character(), info = code)
  # A notebook function's body is read: one that writes a global counts
  # where it's called, one that doesn't, doesn't (#216).
  nb$zero <- function() dt[1L, x := 0]
  nb$zero2 <- function() zero()
  nb$count <- function() nrow(dt)
  environment(nb$zero) <- environment(nb$zero2) <- environment(nb$count) <- nb
  expect_true("dt" %in% cw("zero()"))
  expect_true("dt" %in% cw("zero2()"))
  expect_true("dt" %in% cw("lapply(1:2, function(i) zero())"))
  expect_true("dt" %in% cw("do.call('zero', list())"))
  expect_identical(cw("count()"), character())
  expect_identical(cw("with(other, t[1L, x := 0])"), "other")
  expect_identical(cw("with(other, sum(t$x))"), character())
  # Code run from text could write any table.
  expect_setequal(cw("eval(parse(text = s))"), c("dt", "other"))
})

test_that("a setting the display step changes isn't the cell's: only its code's changes make it a settings cell, and the display's change stays as a package load's would (#156)", {
  skip_if_not_installed("knitr")
  h <- worker_harness(extra_libs = dirname(find.package("knitr")))
  on.exit(h$close())

  # As flextable's knit_print() sets an option through gdtools; this one
  # changes it on every call, so each cell below changes it.
  run_and_wait(h, "m", 1L, paste(
    'registerS3method("knit_print", "ember_sets_opt", function(x, ...) {',
    '  n <- getOption("ember_display_opt")',
    '  options(ember_display_opt = if (is.null(n)) 1 else n + 1)',
    '  knitr::asis_output("<b>shown</b>")',
    '}, envir = asNamespace("knitr"))', sep = "\n"))
  r <- run_and_wait(h, "a", 2L, paste(
    'options(ember_code_opt = 1)',
    'structure(1, class = "ember_sets_opt")', sep = "\n"))
  expect_identical(r$output$html, "<b>shown</b>")
  expect_identical(vapply(r$settings, function(d) d$name, character(1)), "ember_code_opt")

  # A cell that only shows such a value sets nothing.
  r <- run_and_wait(h, "b", 3L, 'structure(2, class = "ember_sets_opt")')
  expect_identical(r$output$html, "<b>shown</b>")
  expect_length(r$settings, 0)

  # The display's change is part of the starting values: putting a settings
  # cell's change back (cell s not in effect) returns to b's display's 2,
  # not to unset.
  run_and_wait(h, "s", 4L, "options(ember_display_opt = 5)")
  r <- run_and_wait(h, "c", 5L, 'getOption("ember_display_opt")')
  expect_identical(r$output$text, "[1] 2")
})

test_that("an option a package's code creates for itself on first use is the package's; one the notebook's code sets, directly or in a helper, makes a settings cell (#164)", {
  h <- worker_harness()
  on.exit(h$close())

  # As readr caches `readr.num_threads` on its first read: a function that
  # lives in a package namespace (stats here) creates an option.
  run_and_wait(h, "f", 1L, paste(
    'cache <- function() if (is.null(getOption("stats.ember_cache"))) options(stats.ember_cache = 4L)',
    'environment(cache) <- asNamespace("stats")',
    'unprefixed <- function() options(ember_pkg_cache = TRUE)',
    'environment(unprefixed) <- asNamespace("stats")',
    'setter <- function(v) options(stats.ember_cache = v)',
    'environment(setter) <- asNamespace("stats")', sep = "\n"))
  r <- run_and_wait(h, "a", 2L, "cache()\n1")
  expect_identical(r$status, "ok")
  expect_length(r$settings, 0)
  # It is part of the starting values: putting settings back before the
  # next run doesn't remove it.
  r <- run_and_wait(h, "b", 3L, 'getOption("stats.ember_cache")')
  expect_identical(r$output$text, "[1] 4")
  # The name doesn't matter, only who set it (evaluate caches
  # `rlang_trace_top_env`).
  r <- run_and_wait(h, "u", 4L, "unprefixed()")
  expect_length(r$settings, 0)

  names_of <- function(r) vapply(r$settings, function(d) d$name, character(1))
  # The notebook's own code: a direct call, a computed name, and a helper a
  # cell defines (settings-cells.md, "A setting inside a helper"), even for
  # a package's option name.
  r <- run_and_wait(h, "c", 5L, "options(stats.ember_own = 1)")
  expect_identical(names_of(r), "stats.ember_own")
  r <- run_and_wait(h, "d", 6L, "op <- list(stats.ember_computed = 1); options(op)")
  expect_identical(names_of(r), "stats.ember_computed")
  run_and_wait(h, "q", 7L, "quiet <- function() options(readr.show_col_types = FALSE)")
  r <- run_and_wait(h, "g", 8L, "quiet()")
  expect_identical(names_of(r), "readr.show_col_types")
  # A package's code changing an option that already exists is the cell's.
  r <- run_and_wait(h, "e", 9L, "setter(5L)")
  expect_identical(names_of(r), "stats.ember_cache")
})

test_that("the options() wrapper doesn't show in an error or change a query's visibility (#164)", {
  h <- worker_harness()
  on.exit(h$close())
  # As on main: the caller's call, and no frames of the wrapper's own.
  r <- run_and_wait(h, "a", 1L, "options(digits = 0)")
  expect_identical(r$status, "error")
  expect_identical(r$error$call, "options(digits = 0)")
  expect_identical(r$error$traceback, "options(digits = 0)")
  expect_false(r$error$deep)
  run_and_wait(h, "f", 2L, "f <- function() options(digits = 0)")
  r <- run_and_wait(h, "b", 3L, "f()")
  expect_identical(r$error$traceback, c("f()", "options(digits = 0)"))
  expect_identical(vapply(r$error$frames, function(f) f$call, character(1)), c("f()", "options(digits = 0)"))
  # A query still prints.
  r <- run_and_wait(h, "c", 4L, 'options("digits")')
  expect_identical(r$output$text, "$digits\n[1] 7\n")
  expect_length(r$settings, 0)
})

test_that("a package the display step loads still gets its load note when it resets a setting a settings cell set (#156, #61)", {
  skip_if_not_installed("knitr")
  h <- worker_harness(extra_libs = c(fixture_lib(), dirname(find.package("knitr"))))
  on.exit(h$close())

  # knitr is loaded here, so the display step below loads only emberfix1.
  run_and_wait(h, "m", 1L, paste(
    'registerS3method("knit_print", "ember_loads", function(x, ...) {',
    '  loadNamespace("emberfix1")',
    '  knitr::asis_output("<b>shown</b>")',
    '}, envir = asNamespace("knitr"))', sep = "\n"))
  run_and_wait(h, "s", 2L, 'options(emberfix_load_opt = "user")')
  r <- run_and_wait(h, "b", 3L, 'structure(1, class = "ember_loads")', settings = "s")
  expect_identical(r$output$html, "<b>shown</b>")
  expect_length(r$settings, 0)
  expect_identical(r$load_notes, list(list(package = "emberfix1", kind = "option", name = "emberfix_load_opt")))
  # The settings cell is applied again before the next run, as for a load
  # in the cell's code.
  r2 <- run_and_wait(h, "c", 4L, 'getOption("emberfix_load_opt")', settings = "s")
  expect_identical(r2$output$text, '[1] "user"')
})

test_that("a value with a knit_print() method shows as its HTML: registered by a package, defined in the notebook, an HTML kable; a markdown kable keeps its text (#154)", {
  skip_if_not_installed("knitr")
  h <- worker_harness(extra_libs = dirname(find.package("knitr")))
  on.exit(h$close())

  # As gt registers knit_print.gt_tbl: in knitr's S3 table, out of sight
  # of the search path.
  r <- run_and_wait(h, "a", 1L, paste(
    'registerS3method("knit_print", "ember_registered", function(x, ...) knitr::asis_output("<b>registered</b>"), envir = asNamespace("knitr"))',
    'structure(1, class = "ember_registered")', sep = "\n"))
  expect_identical(r$output$kind, "html")
  expect_identical(r$output$html, "<b>registered</b>")
  expect_match(r$output$text, "ember_registered")

  r <- run_and_wait(h, "b", 2L, paste(
    'knit_print.ember_own <- function(x, ...) knitr::asis_output("<i>own</i>")',
    'structure(1, class = "ember_own")', sep = "\n"))
  expect_identical(r$output$kind, "html")
  expect_identical(r$output$html, "<i>own</i>")

  r <- run_and_wait(h, "c", 3L, 'knitr::kable(data.frame(x = 1:2), format = "html")')
  expect_identical(r$output$kind, "html")
  expect_match(r$output$html, "<table")

  r <- run_and_wait(h, "d", 4L, 'knitr::kable(data.frame(x = 1:2))')
  expect_false(identical(r$output$kind, "html"))
  expect_match(r$output$text, "|", fixed = TRUE)

  # As huxtable's: the format comes from knitr::is_html_output().
  r <- run_and_wait(h, "e", 5L, paste(
    'knit_print.ember_fmt <- function(x, ...) knitr::asis_output(if (knitr::is_html_output()) "<p>html</p>" else "screen")',
    'structure(1, class = "ember_fmt")', sep = "\n"))
  expect_identical(r$output$html, "<p>html</p>")

  # As flextable's for pandoc: the HTML in a raw-HTML fence.
  r <- run_and_wait(h, "g", 7L, paste(
    'knit_print.ember_fenced <- function(x, ...) knitr::asis_output("\\n```{=html}\\n<p>fenced</p>\\n```\\n")',
    'structure(1, class = "ember_fenced")', sep = "\n"))
  expect_identical(r$output$html, "<p>fenced</p>")

  # As rmarkdown's knit_print.data.frame outside a report: it prints the
  # value and returns it, which isn't knit_asis. The data frame stays
  # Ember's table, and nothing is printed to the console.
  r <- run_and_wait(h, "f", 6L, paste(
    'registerS3method("knit_print", "data.frame", function(x, ...) { print(x); x }, envir = asNamespace("knitr"))',
    'data.frame(x = 1:3)', sep = "\n"))
  expect_identical(r$output$kind, "table")
  expect_false(any(vapply(r$console, function(e) identical(e$kind, "stdout"), logical(1))))
})

test_that("an HTML output whose print() text is its source or empty gets the HTML's text as its text form (#157)", {
  skip_if_not_installed("knitr")
  skip_if_not_installed("htmltools")
  h <- worker_harness(extra_libs = unique(dirname(c(find.package("knitr"), find.package("htmltools")))))
  on.exit(h$close())

  # As gt: print() gives the HTML source, CSS first. The text form is the
  # table's text, a row per line and its cells split by tabs.
  src <- paste0('<div id="t"><style>#t .x { color: red; }</style><table><caption>Fits &amp; tests</caption>',
                '<tr><th>term</th><th>p</th></tr>\n<tr>\n  <td>wt</td>\n  <td>&lt;0.001</td>\n</tr>',
                '<tr><td>hp&#39;s</td><td>0.01</td></tr></table><script>var x = 1;</script></div>')
  r <- run_and_wait(h, "a", 1L, paste(
    sprintf('src <- %s', deparse(src)),
    'print.ember_src <- function(x, ...) cat(src, "\\n")',
    'knit_print.ember_src <- function(x, ...) knitr::asis_output(src)',
    'structure(1, class = "ember_src")', sep = "\n"))
  expect_identical(r$output$kind, "html")
  expect_identical(r$output$text, "Fits & tests\nterm\tp\nwt\t<0.001\nhp's\t0.01")

  # print() text that isn't HTML stays, as flextable's summary does.
  r <- run_and_wait(h, "b", 2L, paste(
    'print.ember_sum <- function(x, ...) cat("a table of 2 rows\\n")',
    'knit_print.ember_sum <- function(x, ...) knitr::asis_output("<table><tr><td>1</td></tr></table>")',
    'structure(1, class = "ember_sum")', sep = "\n"))
  expect_identical(r$output$text, "a table of 2 rows")

  # A code point UTF-8 can't hold is U+FFFD; the HTML view stays.
  r <- run_and_wait(h, "d", 4L, 'htmltools::HTML("<p>a &#xD800; b &#1114112; c</p>")')
  expect_identical(r$output$kind, "html")
  expect_identical(r$output$text, "a \uFFFD b \uFFFD c")

  # A long table is read only to its 60th row: the text form keeps 50 lines.
  r <- run_and_wait(h, "e", 5L, paste0('htmltools::HTML(paste0("<table>", strrep("<tr><td>x</td><td>1</td></tr>", 1e5), "</table>"))'))
  expect_identical(r$output$kind, "html")
  expect_identical(r$output$text, paste(rep("x\t1", 50), collapse = "\n"))
  expect_true(r$output$truncated)

  # HTML with no text at all, as a widget whose data is in a script: the
  # text form says what it is rather than being empty.
  r <- run_and_wait(h, "c", 6L, 'htmltools::tags$div(htmltools::tags$script("var data = [1, 2];"))')
  expect_identical(r$output$kind, "html")
  expect_identical(r$output$text, "<HTML output: no text form; it shows in the notebook's page>")
})

test_that("render_plot() redraws at the cell's own figure size and a new res; width/height pixels override (ui-3 65)", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L, "plot(1:10)", fig = list(width = 8, height = 4))

  h$send(list(type = "render", cell = "a", res = 288L))
  m <- wait_for_done_or_rendered(h)
  expect_identical(m$type, "rendered")
  expect_identical(m$token, 1L)
  dims <- png_dims(m$display$data)
  expect_identical(dims, list(width = 2304, height = 1152))
  expect_identical(m$display$size, list(width = 2304, height = 1152, res = 288L))

  # width/height given: used directly, in pixels (render_png()'s API).
  h$send(list(type = "render", cell = "a", width = 1400L, height = 933L, res = 192L))
  m2 <- wait_for_done_or_rendered(h)
  expect_identical(m2$type, "rendered")
  dims2 <- png_dims(m2$display$data)
  expect_identical(dims2, list(width = 1400, height = 933))
  expect_identical(m2$display$size, list(width = 1400L, height = 933L, res = 192L))
})

test_that("colours are on at boot and text_form never ends in a partial escape (28)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "a", 1L, 'getOption("cli.num_colors")')
  expect_identical(r$output$text, "[1] 256")
  expect_identical(r$settings, list())

  r2 <- run_and_wait(h, "b", 2L,
    'paste(rep("\\033[31mx\\033[39m", 2000), collapse = "")')
  expect_true(r2$output$truncated)
  expect_match(r2$output$text, "\033\\[0m$")
})

test_that("a value that prints many lines shows at once, and print() keeps every line (#160)", {
  h <- worker_harness()
  on.exit(h$close())
  # capture.output() is quadratic in the lines printed: 20,000 took 16.5 s,
  # so 150,000 would take many minutes; the temp-file capture takes well
  # under a second.
  run_and_wait(h, "a", 1L, paste(
    'print.many_lines <- function(x, ...) { cat(sprintf("line %d\\n", seq_len(attr(x, "n"))), sep = ""); invisible(x) }',
    'x <- structure(list(), class = "many_lines", n = 150000)',
    'y <- structure(list(), class = "many_lines", n = 50000)', "invisible()", sep = "\n"))
  r <- run_and_wait(h, "b", 2L, "x")
  expect_identical(r$status, "ok")
  expect_true(r$output$truncated)
  expect_identical(strsplit(r$output$text, "\n")[[1]][c(1, 50)], c("line 1", "line 50\033[0m"))

  r2 <- run_and_wait(h, "c", 3L, "print(y); invisible()")
  printed <- Filter(function(i) identical(i$kind, "stdout"), r2$console)
  # The page joins consecutive stdout items as they are; a long print can
  # come in several, each ending at a line (#470).
  lines <- strsplit(paste(vapply(printed, `[[`, "", "text"), collapse = ""), "\n")[[1]]
  expect_identical(length(lines), 50000L)
  expect_identical(lines[c(1, 50000)], c("line 1", "line 50000"))
})

# ---- Editor services (ui-2.md, 4) ---------------------------------------------

test_that("complete_line() (44)", {
  h <- worker_harness()
  on.exit(h$close())

  run_and_wait(h, "a", 1L, "mtcars <- mtcars; my_var <- 1")

  h$send(list(type = "complete", id = 1L, line = "me", cursor = 2L))
  m <- h$receive()
  expect_identical(m$type, "completions")
  expect_identical(m$id, 1L)
  expect_true("mean" %in% vapply(m$items, `[[`, character(1), "name"))

  h$send(list(type = "complete", id = 2L, line = "mtcars$m", cursor = 8L))
  m2 <- h$receive()
  names2 <- vapply(m2$items, `[[`, character(1), "name")
  expect_true("mtcars$mpg" %in% names2)

  h$send(list(type = "complete", id = 3L, line = "library(sta", cursor = 11L))
  m3 <- h$receive()
  names3 <- vapply(m3$items, `[[`, character(1), "name")
  expect_true("stats" %in% names3)

  h$send(list(type = "complete", id = 4L, line = "lm(fo", cursor = 5L))
  m4 <- h$receive()
  formula_item <- Filter(function(it) grepl("^formula\\s*=", it$name), m4$items)
  expect_length(formula_item, 1)
  expect_identical(formula_item[[1]]$kind, "argument")

  myvar_item <- Filter(function(it) identical(it$name, "my_var"), m$items)
  if (length(myvar_item) == 0) {
    h$send(list(type = "complete", id = 5L, line = "my_", cursor = 3L))
    m5 <- h$receive()
    myvar_item <- Filter(function(it) identical(it$name, "my_var"), m5$items)
  }
  expect_length(myvar_item, 1)
  expect_true(isTRUE(myvar_item[[1]]$notebook))

  run_and_wait(h, "b", 2L, 'makeActiveBinding("counted", local({n <- 0; function() { n <<- n + 1; n }}), globalenv())')
  # Peek at the binding's internal counter without reading through it
  # (reading it, directly or via `exists(..., mode = "function")`, is
  # itself an evaluation): the test must tell "complete_line() evaluated
  # it" apart from "evaluating it in the test evaluated it".
  peek <- 'environment(activeBindingFunction("counted", globalenv()))$n'
  before <- run_and_wait(h, "c", 3L, peek)$output$text
  h$send(list(type = "complete", id = 6L, line = "count", cursor = 5L))
  h$receive()
  after <- run_and_wait(h, "d", 4L, peek)$output$text
  expect_identical(before, after)
})

test_that("argument completion inside a call gives utils' own names, methods' too, and leaves its table as it was (#288)", {
  h <- worker_harness()
  on.exit(h$close())
  arg_items <- function(id, line) {
    h$send(list(type = "complete", id = id, line = line, cursor = nchar(line)))
    m <- h$receive()
    sort(vapply(Filter(function(it) identical(it$kind, "argument"), m$items), `[[`, character(1), "name"), method = "radix")
  }
  # What plain R's completer gives, read in a cell, where nothing has been
  # put into the table: the argument names (`...` isn't one). Both sides
  # sort by bytes, since the worker and the cell may sort in other locales.
  utils_args <- function(label, n, fun, text) {
    out <- run_and_wait(h, label, n, sprintf('cat(sort(utils:::functionArgs("%s", "%s"), method = "radix"), sep = "\\n")', fun, text))
    printed <- Filter(function(i) identical(i$kind, "stdout"), out$console)
    all <- strsplit(paste(vapply(printed, `[[`, "", "text"), collapse = ""), "\n")[[1]]
    all[grepl("=$", all)]
  }
  table_size <- function(label, n) run_and_wait(h, label, n, 'length(ls(utils:::.FunArgEnv, all.names = TRUE))')$output$text

  before <- table_size("a", 1L)
  run_and_wait(h, "b", 2L, "print.ember_t <- function(x, gamma_ember, ...) invisible(x)")
  got <- arg_items(1L, "print(x, ")
  expect_identical(got, utils_args("c", 3L, "print", ""))
  # print.default's and the notebook's own method's arguments.
  expect_true(all(c("digits=", "gamma_ember=") %in% got))
  expect_identical(arg_items(2L, "summary(x, d"), utils_args("d", 4L, "summary", "d"))

  # A function the notebook redefines: its new arguments, not the old ones.
  run_and_wait(h, "e", 5L, "my_fun <- function(alpha_x) 1")
  expect_identical(arg_items(3L, "my_fun(al"), "alpha_x=")
  run_and_wait(h, "f", 6L, "my_fun <- function(alto_y) 1")
  expect_identical(arg_items(4L, "my_fun(al"), "alto_y=")

  expect_identical(table_size("g", 7L), before)
})

test_that("completion restores a locked active binding's lock (mask_active_bindings())", {
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "a", 1L,
              'makeActiveBinding("locked_ab", function() 1, globalenv()); lockBinding("locked_ab", globalenv())')
  before <- run_and_wait(h, "b", 2L, 'bindingIsLocked("locked_ab", globalenv())')$output$text
  expect_identical(before, "[1] TRUE")

  h$send(list(type = "complete", id = 7L, line = "locked_", cursor = 7L))
  h$receive()

  after <- run_and_wait(h, "c", 3L, 'bindingIsLocked("locked_ab", globalenv())')$output$text
  expect_identical(after, "[1] TRUE")
})

test_that("help() (45)", {
  h <- worker_harness()
  on.exit(h$close())

  h$send(list(type = "help", id = 1L, topic = "mean", package = NULL))
  m <- h$receive()
  expect_true(m$found)
  expect_match(m$html, "Arithmetic Mean")
  expect_no_match(m$html, "<html")
  expect_no_match(m$html, "<head")

  h$send(list(type = "help", id = 2L, topic = "no_such_topic_xyz", package = NULL))
  m2 <- h$receive()
  expect_false(m2$found)

  # "plot" names both base's generic help page and graphics::plot.default
  # -- both always attached, so this needs no library() call to set up --
  # and so must come back as more than one match for two distinct
  # packages, not a single resolved page.
  h$send(list(type = "help", id = 3L, topic = "plot", package = NULL))
  m3 <- h$receive()
  expect_null(m3$html)
  pkgs <- vapply(m3$matches, `[[`, character(1), "package")
  expect_setequal(pkgs, c("base", "graphics"))
})

test_that("help() searches installed but unattached packages only when all_packages is TRUE", {
  skip_if_not(nzchar(system.file(package = "codetools")), "codetools not installed")
  h <- worker_harness()
  on.exit(h$close())

  h$send(list(type = "help", id = 1L, topic = "findGlobals", package = NULL))
  m <- h$receive()
  expect_false(m$found)

  h$send(list(type = "help", id = 2L, topic = "findGlobals", package = NULL, all_packages = TRUE))
  m2 <- h$receive()
  expect_true(m2$found)
  expect_identical(m2$package, "codetools")

  # The reply says how far each lookup looked, found or not (#121).
  expect_false(m$tried_all_packages)
  expect_true(m2$tried_all_packages)
  h$send(list(type = "help", id = 3L, topic = "zzznotatopic", package = NULL, all_packages = TRUE))
  m3 <- h$receive()
  expect_false(m3$found)
  expect_true(m3$tried_all_packages)
})

test_that("signature() (46)", {
  h <- worker_harness()
  on.exit(h$close())

  h$send(list(type = "signature", id = 1L, name = "lm", package = NULL))
  m <- h$receive()
  expect_match(m$text, "^lm\\(formula, data")

  h$send(list(type = "signature", id = 2L, name = "pi", package = NULL))
  m2 <- h$receive()
  expect_null(m2$text)
})

test_that("signature() for an explicit, unloaded package never loads it in the worker", {
  skip_if_not(nzchar(system.file(package = "codetools")), "codetools not installed")
  h <- worker_harness()
  on.exit(h$close())

  before <- run_and_wait(h, "a", 1L, '"codetools" %in% loadedNamespaces()')$output$text
  expect_identical(before, "[1] FALSE")

  h$send(list(type = "signature", id = 1L, name = "findGlobals", package = "codetools"))
  m <- h$receive()
  expect_null(m$text)

  after <- run_and_wait(h, "b", 2L, '"codetools" %in% loadedNamespaces()')$output$text
  expect_identical(after, "[1] FALSE")
})

test_that("handle_next() answers complete/help/signature with the request's id, deferred not lost during a source wait (47)", {
  h <- worker_harness()
  on.exit(h$close())

  # The file is the test's, not the worker's: a file under the worker's
  # own tempdir() isn't reported as a source (#165), so it wouldn't wait.
  f <- tempfile(fileext = ".R")
  file.create(f)
  on.exit(unlink(f), add = TRUE)
  h$send(run_msg("a", 1L, sprintf("source(%s)", deparse(f))))
  src <- NULL
  repeat {
    m <- h$receive()
    if (identical(m$type, "source")) { src <- m; break }
  }

  h$send(list(type = "complete", id = 42L, line = "me", cursor = 2L))
  h$send(list(type = "signature", id = 43L, name = "lm", package = NULL))
  h$send(list(type = "source_reply", allow = TRUE, message = ""))

  # The source() call's deferred `complete`/`signature` are only handled
  # once the run itself is done (handle_next() drains `deferred` before
  # its next receive()), so they arrive just after "done", not before.
  seen <- list()
  repeat {
    m <- h$receive()
    if (is.null(m)) break
    seen[[length(seen) + 1]] <- m
    types_so_far <- vapply(seen, `[[`, character(1), "type")
    if (all(c("completions", "signature") %in% types_so_far)) break
  }
  types <- vapply(seen, `[[`, character(1), "type")
  expect_true("completions" %in% types)
  expect_true("signature" %in% types)
  expect_identical(seen[[which(types == "completions")]]$id, 42L)
  expect_identical(seen[[which(types == "signature")]]$id, 43L)
})

# ---- Inline values: role "text" (ui-3 47) -----------------------------------

test_that("run_cell(): role text gives one inline value per line, knitr-style formatting (ui-3 47)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "t", 1L, "1/3\nnrow(mtcars)\ninvisible(1)\nc(1.5, 2)\nletters[1:3]", role = "text")
  expect_identical(r$status, "ok")
  expect_identical(r$output$mime, "application/vnd.ember.inline")
  expect_identical(r$output$values, c("0.3333333", "32", "", "1.5, 2", "a, b, c"))
  expect_identical(r$output$text, paste(r$output$values, collapse = "\n"))

  if (requireNamespace("knitr", quietly = TRUE)) {
    hook <- getFromNamespace(".inline.hook", "knitr")
    expect_identical(r$output$values[[1]], hook(1 / 3))
    expect_identical(r$output$values[[2]], hook(nrow(mtcars)))
    expect_identical(r$output$values[[4]], hook(c(1.5, 2)))
    expect_identical(r$output$values[[5]], hook(letters[1:3]))
  }
})

test_that("run_cell(): role text evaluates every expression on a line, in order, and shows the last (review)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "t", 1L, "a <- 2; a * 3\ninvisible(1); 5", role = "text")
  expect_identical(r$status, "ok")
  expect_identical(r$output$values, c("6", "5"))
})

test_that("run_cell(): role text reports the failing line as error$span; earlier assignments stick (ui-3 47)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "t", 1L, "y <- 1\nstop('no')", role = "text")
  expect_identical(r$status, "error")
  expect_identical(r$error$span, 2L)

  # A different cell id, so remove_cell() for this run doesn't drop "t"'s
  # own globals before they can be checked.
  r2 <- run_and_wait(h, "check", 2L, "y")
  expect_identical(r2$status, "ok")
  expect_identical(r2$output$text, "[1] 1")
})

test_that("run_cell(): a bare top-level warning() in a text cell carries no call (item 5)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "t", 1L, "warning('x')", role = "text")
  expect_identical(r$status, "ok")
  expect_identical(r$console[[1]]$kind, "warning")
  expect_null(r$console[[1]][["call", exact = TRUE]])
})

test_that("run_cell(): a text cell's error traceback drops the worker's own eval() frames (item 5)", {
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "t", 1L, "f <- function() stop('boom')\nf()", role = "text")
  expect_identical(r$status, "error")
  expect_identical(r$error$traceback, c("f()", 'stop("boom")'))
  expect_false(any(grepl("line_e|handleSimpleError|eval\\(line_e", r$error$traceback)))
})

test_that("run_cell(): a top-level install call doesn't run, and the report names its packages (#79)", {
  h <- worker_harness()
  on.exit(h$close())
  m <- run_msg("a", 1L, 'x <- 1\nremotes::install_github("lab/toyD")\ninstall.packages(pkgs)')
  m$installs <- list(list(index = 2L, packages = "toyD"), list(index = 3L, packages = character()))
  h$send(m)
  r <- wait_for_done(h)
  # remotes isn't installed and `pkgs` doesn't exist: either would fail.
  expect_identical(r$status, "ok")
  expect_null(r$output)
  expect_identical(r$from_lock, c("toyD", ""))
  expect_identical(r$created, "x")

  r <- run_and_wait(h, "b", 2L, "y <- 2")
  expect_identical(r$from_lock, character())
})

test_that("a package the library doesn't have is looked up once, until a library changes (#316)", {
  e <- new.env(parent = baseenv())
  sys.source(worker_script_path(), e)
  lib <- withr::local_tempdir()
  withr::local_libpaths(lib, action = "prefix")
  asked <- 0L
  e$requireNamespace <- function(package, ..., quietly = TRUE) { asked <<- asked + 1L; FALSE }
  for (i in 1:5) expect_false(e$has_namespace("notapkg.ember316"))
  expect_equal(asked, 1L)
  # An install adds a folder to the library, which changes its time.
  Sys.setFileTime(lib, Sys.time() + 5)
  expect_false(e$has_namespace("notapkg.ember316"))
  expect_equal(asked, 2L)
  # A loaded namespace never asks.
  expect_true(e$has_namespace("stats"))
  expect_equal(asked, 2L)
})

test_that("diff_settings finds each changed, added and removed entry (#316)", {
  e <- new.env(parent = baseenv())
  sys.source(worker_script_path(), e)
  s <- list(options = list(a = 1, b = "x", f = mean), env = list(HOME = "/h", X = "1"),
            locale = list(LC_COLLATE = "C"), wd = "/w", search = character(), theme = NULL)
  expect_identical(e$diff_settings(s, s), list())
  t <- s
  t$options$b <- "y"; t$options$a <- NULL; t$options$c <- TRUE
  t$env$X <- "2"
  d <- e$diff_settings(s, t)
  got <- vapply(d, function(x) paste(x$kind, x$name), "")
  expect_setequal(got, c("option a", "option b", "option c", "env X"))
  b <- d[[match("option b", got)]]
  expect_identical(list(b$before, b$after), list("x", "y"))
  a <- d[[match("option a", got)]]
  expect_identical(list(a$before, a$after), list(1, NULL))
})

test_that("a run reports its data files' versions, and a change after the read by an expression that doesn't touch the file (#276)", {
  h <- worker_harness()
  on.exit(h$close())
  f <- normalizePath(tempfile("ember-data-", fileext = ".csv"), winslash = "/", mustWork = FALSE)
  writeLines("a", f)
  code <- sprintf('d <- readLines("%1$s")\nwriteLines("bb", "%1$s")\nn <- 1', f)
  # Expression 2 stands for someone else: it isn't in `touch`.
  r <- run_and_wait(h, "a", 1L, code, data = list(list(path = "d.csv", full = f, touch = 1L)))
  expect_identical(r$status, "ok")
  expect_identical(r$data_changed, "d.csv")
  info <- file.info(f)
  expect_identical(r$data_seen[["d.csv"]],
                   sprintf("%.6f %.0f", as.numeric(info$mtime), as.numeric(info$size)))

  # The cell's own write (expression 2 in `touch`) isn't a change, and
  # neither is one before the file is read.
  r2 <- run_and_wait(h, "b", 2L, sprintf('writeLines("ccc", "%1$s")\nd <- readLines("%1$s")\nwriteLines("dddd", "%1$s")', f),
                     data = list(list(path = "d.csv", full = f, touch = c(2L, 3L))))
  expect_identical(r2$status, "ok")
  expect_length(r2$data_changed, 0)
  expect_identical(r2$data_seen[["d.csv"]], ember:::data_signature(as.list(file.info(f)[, c("mtime", "size")])))
})

test_that("menu()'s answer is a number in range, 0, or a choice typed out (#186)", {
  e <- new.env(parent = baseenv())
  sys.source(worker_script_path(), e)
  ch <- c("red", "blue", "10")
  expect_equal(e$menu_choice("2", ch), 2L)
  expect_equal(e$menu_choice("0", ch), 0L)
  expect_true(is.na(e$menu_choice("4", ch)))
  expect_equal(e$menu_choice("blue", ch), 2L)
  # A number is a number first, as in R's menu().
  expect_equal(e$menu_choice("10", ch), NA_integer_)
  expect_true(is.na(e$menu_choice("", ch)))
  expect_true(is.na(e$menu_choice("green", ch)))
})

test_that("outside a run nothing can answer: readline() gives \"\" and menu() 0 (#186)", {
  e <- new.env(parent = baseenv())
  sys.source(worker_script_path(), e)
  expect_null(e$running)
  expect_identical(e$prompt_readline("Name? "), "")
  if (interactive()) expect_identical(e$prompt_menu(c("a", "b")), 0L)
  else expect_error(e$prompt_menu(c("a", "b")), "non-interactively")
})
