# Worker harness tests (docs/engine-tests.md, "Worker harness"): the real
# inst/worker.R under processx, talked to directly over a socket. No
# server, no `later`. Every wait is a blocking read with a timeout
# (worker_harness()'s $receive()), never Sys.sleep polling.

run_msg <- function(cell, token, code, role = "cell", order = character(), formulas = list(),
                    library = NULL, fig = NULL, settings = character()) {
  list(type = "run", cell = cell, token = token, code = code, role = role,
       order = order, settings = settings, formulas = formulas, library = library, fig = fig)
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
  h <- worker_harness()
  on.exit(h$close())
  r <- run_and_wait(h, "t", 1L, "library(ggplot2); theme_set(theme_minimal(base_size = 21))", timeout = 30)
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
  h <- worker_harness()
  on.exit(h$close())
  run_and_wait(h, "l", 1L, "loadNamespace('ggplot2')", timeout = 30)
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
  rendered <- h$receive(5)
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
  m <- h$receive(5)
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
    sep = "\n"), timeout = 10)

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
  t0 <- Sys.time()
  r <- run_and_wait(h, "a", 1L, paste(
    "slow <- Sys.Date()",
    "format.Date <- function(x, ...) { t0 <- Sys.time(); repeat if (as.numeric(Sys.time() - t0) > 30) break; 'slow' }",
    sep = "\n"), timeout = 35)
  elapsed <- as.numeric(Sys.time() - t0, units = "secs")
  # A busy R loop, not Sys.sleep(): setTimeLimit() is checked while R code
  # runs and does not cut a sleep short. The budget is 0.25 s; the method
  # runs 30 s unless it is cut short, so 10 s tells the two apart however
  # slow the runner, where 4 s against a 5 s method did not leave room.
  expect_lt(elapsed, 10)
  expect_equal(r$globals$slow$kind, "none")

  r2 <- run_and_wait(h, "b", 2L, "1 + 1", timeout = 3)
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
    sep = "\n"), timeout = 10)

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
  deadline <- Sys.time() + 10
  while (!file.exists(started) && Sys.time() < deadline) Sys.sleep(0.05)
  expect_true(file.exists(started))
  t0 <- Sys.time()
  h$process$interrupt()
  r <- wait_for_done(h, timeout = 5)
  elapsed <- as.numeric(Sys.time() - t0, units = "secs")
  expect_identical(r$status, "interrupted")
  # An unheeded interrupt runs the loop its full 10 s (and times out
  # above), so 3 s still tells them apart with room for a slow runner.
  expect_lt(elapsed, 3)

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

  # the option b changed doesn't apply where b isn't in effect
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

  h$send(run_msg("a", 1L, 'source(tempfile(fileext = ".R"))'))
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
