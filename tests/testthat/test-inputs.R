# Interactive inputs (docs/inputs.md), first increment: the binding rules,
# the worker's hook, and set_input() through the core. The worker tests
# load emberui from inst/emberui, installed by fixture_lib().

# ---- Rules 1 and 3, from the parse --------------------------------------------

bound_names <- function(b, slot = "bind") vapply(b[[slot]], function(x) x$name, character(1))

test_that("a top-level assignment of an input call binds its name, written either way", {
  b <- input_bindings(paste(
    "n <- input_slider(10, 500, value = 100)",
    "m = emberui::input_select(c('a', 'b'))",
    "p <- input_list(k = input_slider(1, 3))",
    "x <- df[, 1]",
    "y <- z$n2",
    sep = "\n"))
  expect_identical(bound_names(b), c("n", "m", "p"))
  expect_identical(vapply(b$bind, function(x) x$index, integer(1)), c(1L, 2L, 3L))
  expect_length(b$blocked, 0)
})

test_that("an input inside another call, a function or another package's namespace binds nothing", {
  b <- input_bindings(paste(
    "n <- round(input_slider(1, 10))",
    "f <- function() input_slider(1, 10)",
    "x <- other::input_slider(1, 2)",
    "input_slider(1, 2)",
    "y <<- input_slider(1, 2)",
    sep = "\n"))
  expect_length(b$bind, 0)
  expect_length(b$blocked, 0)
})

test_that("a name the rest of the cell reads or redefines is blocked, not bound (rule 3)", {
  expect_identical(bound_names(input_bindings("n <- input_slider(1, 10)\nm <- n * 2"), "blocked"), "n")
  expect_identical(bound_names(input_bindings("n <- input_slider(1, n)"), "blocked"), "n")
  expect_identical(bound_names(input_bindings("n <- input_slider(1, 10)\nn <- 3"), "blocked"), "n")
  # A field named `n` isn't the variable.
  expect_identical(bound_names(input_bindings("n <- input_slider(1, 10)\nm <- x$n")), "n")
  # Reads the graph finds without a bare symbol count too (review).
  expect_identical(bound_names(input_bindings("n <- input_slider(1, 10)\nv <- get(\"n\")"), "blocked"), "n")
  expect_identical(bound_names(input_bindings("n <- input_slider(1, 10)\nglue::glue(\"n is {n}\")"), "blocked"), "n")
  # Two inputs in a cell, one read by the other's arguments.
  b <- input_bindings("a <- input_slider(1, 10)\nb <- input_slider(a, 20)")
  expect_identical(bound_names(b), "b")
  expect_identical(bound_names(b, "blocked"), "a")
})

test_that("code that doesn't parse or names no input binds nothing", {
  expect_identical(input_bindings("x <- 1"), list(bind = list(), blocked = list()))
  expect_identical(input_bindings("n <- input_slider(1,"), list(bind = list(), blocked = list()))
})

# ---- The core -------------------------------------------------------------------

#' A bound slider report entry, as the worker's input_hook() makes it.
slider_entry <- function(name, value = 5, default = 5, bound = TRUE) {
  list(name = name, bound = bound, reason = if (!bound) "read_elsewhere",
       spec = list(type = "slider", value = default, min = 1, max = 10),
       default = default, value = value)
}

#' S (setup), I binds `n` and `bins`, B reads `n`, C reads `bins`, D reads
#' what B defines. Everything run once, the worker ready.
inputs_ran <- function(mode = "autorun") {
  s <- fake_state(list(S = cell(""),
                       I = cell("n <- input_slider(1, 10, 5)\nbins <- input_slider(1, 10, 5)"),
                       B = cell("b <- n + 1"), C = cell("cc <- bins"), D = cell("d <- b")),
                  on_cell_change = mode)
  r <- boot(s, c("I", "B", "C", "D"))
  inputs <- list(slider_entry("n"), slider_entry("bins"))
  r <- drive(r$state, wk_done(1, last_token(r), report(created = c("n", "bins"), inputs = inputs), at(10)))
  for (n in c("b", "cc", "d")) r <- drive(r$state, wk_done(1, last_token(r), report(created = n), at(11)))
  expect_identical(r$state$worker$status, "ready")
  r
}

#' Answer every run the worker is sent until it is idle.
finish_runs <- function(r, at0 = 50) {
  effects <- r$effects
  for (k in 1:20) {
    running <- r$state$worker$running
    if (is.null(running)) {
      r$effects <- effects
      return(r)
    }
    r <- drive(r$state, wk_done(1, running$token, report(), at(at0 + k)))
    effects <- c(effects, r$effects)
  }
  stop("still running")
}

test_that("the run message carries the cell's bindings, and none for a cell without inputs", {
  s <- fake_state(list(S = cell(""), I = cell("n <- input_slider(1, 10)\nm <- n"), B = cell("b <- 1")))
  r <- boot(s, "I")
  msg <- last_sent(r)
  expect_identical(msg$inputs$blocked, list(list(name = "n", index = 1L)))
  expect_length(msg$inputs$values, 0)
  r <- drive(r$state, wk_done(1, last_token(r), report(created = "n"), at(10)), ev_run("B", at(11)))
  expect_null(last_sent(r)$inputs)
})

test_that("set_input sends the value to the worker, and holds new runs until it answers", {
  r <- inputs_ran()
  r <- drive(r$state, ev_set_input("n", 8, at(20)))
  expect_identical(r$reply$cell, "I")
  msg <- last_sent(r)
  expect_identical(msg[c("type", "cell", "name", "value")], list(type = "set_input", cell = "I", name = "n", value = 8))
  # A run asked for meanwhile waits for the answer.
  r <- drive(r$state, ev_run("D", at(21)))
  expect_length(sent_cells(r), 0)
  expect_true("D" %in% r$state$pending)
})

test_that("an accepted value reruns the cells that read its name, not the input's cell or another input's readers", {
  r <- inputs_ran()
  r <- drive(r$state, ev_set_input("n", 8, at(20)),
             wk_input_set(1, "I", "n", TRUE, 8, NULL,
                          list(n = list(type = "numeric", value = "8", kind = "text")), at(21)))
  expect_identical(sent_cells(r), "B")
  expect_setequal(r$state$pending, "D")
  expect_false(isTRUE(r$state$results$C$stale))
  expect_false(isTRUE(r$state$results$I$stale))
  expect_setequal(r$state$input_outcome$cells, c("B", "D"))
  # The cell's result shows the new value, and keeps it for the session.
  i <- r$state$results$I$inputs[[1]]
  expect_identical(c(i$value, i$default), c(8, 5))
  expect_identical(r$state$results$I$variables$n$value, "8")
  expect_identical(r$state$input_values$n$value, 8)
})

test_that("in lazy mode an accepted value marks the readers stale and runs nothing", {
  r <- inputs_ran("lazy")
  r <- drive(r$state, ev_set_input("n", 8, at(20)), wk_input_set(1, "I", "n", TRUE, 8, NULL, list(), at(21)))
  expect_length(sent_cells(r), 0)
  expect_length(r$state$pending, 0)
  expect_true(r$state$results$B$stale)
  expect_true(r$state$results$D$stale)
  expect_false(isTRUE(r$state$results$C$stale))
})

test_that("a refused value changes nothing but the outcome", {
  r <- inputs_ran()
  r1 <- drive(r$state, ev_set_input("n", 80, at(20)))
  r2 <- drive(r1$state, wk_input_set(1, "I", "n", FALSE, NULL, "The value must be a number from 1 to 10.", NULL, at(21)))
  expect_identical(r2$state$input_outcome$error, "The value must be a number from 1 to 10.")
  expect_null(r2$state$worker$input)
  expect_identical(r2$state$results, r$state$results)
  expect_length(r2$state$input_values, 0)
})

test_that("set_input is refused for an unknown name, an unbound input, a stale or edited cell, and while a value is pending", {
  r <- inputs_ran()
  refused_for <- function(state, name) {
    rr <- drive(state, ev_set_input(name, 1, at(30)))
    expect_true(inherits(rr$reply, "ember_refused"))
    expect_length(rr$effects, 0)
  }
  refused_for(r$state, "nope")
  # An input whose binding is blocked (rule 3) can't be set.
  s <- r$state
  s$results$I$inputs[[1]]$bound <- FALSE
  refused_for(s, "n")
  s <- r$state
  s$results$I$stale <- TRUE
  refused_for(s, "n")
  edited <- drive(r$state, ev_apply(list(op_set_code("I", "n <- input_slider(1, 20, 5)\nbins <- input_slider(1, 10, 5)")), at(25)))
  refused_for(edited$state, "n")
  busy <- drive(r$state, ev_set_input("n", 2, at(25)))
  refused_for(busy$state, "bins")
})

test_that("a kept value goes back to the input's cell when it reruns with the same code, not after an edit", {
  r <- inputs_ran()
  r <- drive(r$state, ev_set_input("n", 8, at(20)), wk_input_set(1, "I", "n", TRUE, 8, NULL, list(), at(21)))
  r <- finish_runs(r)
  r <- drive(r$state, ev_run("I", at(24)))
  expect_identical(last_sent(r)$inputs$values, list(n = 8))
  # The worker reports the kept value it used: it stays kept.
  r <- drive(r$state, wk_done(1, last_token(r),
                              report(created = c("n", "bins"), inputs = list(slider_entry("n", 8), slider_entry("bins"))),
                              at(25)))
  expect_identical(r$state$input_values$n$value, 8)

  # Edited: the value resets. The cells that read `n` may run first.
  r2 <- drive(r$state, ev_apply(list(op_set_code("I", "n <- input_slider(1, 20, 5)\nbins <- input_slider(1, 10, 5)")), at(30)))
  r2 <- finish_runs(drive(r2$state, ev_run("I", at(31))))
  sent <- Filter(function(e) identical(e$msg$type, "run") && identical(e$msg$cell, "I"), r2$effects)
  expect_length(sent, 1)
  expect_length(sent[[1]]$msg$inputs$values, 0)
})

test_that("an answer for a cell deleted meanwhile keeps nothing", {
  r <- inputs_ran()
  r <- drive(r$state, ev_set_input("n", 8, at(20)), ev_apply(list(op_delete("I")), at(21)),
             wk_input_set(1, "I", "n", TRUE, 8, NULL, list(), at(22)))
  expect_length(r$state$input_values, 0)
  expect_false(r$state$input_outcome$ok)
})

test_that("an input back at its default is forgotten", {
  r <- inputs_ran()
  r <- drive(r$state, ev_set_input("n", 8, at(20)), wk_input_set(1, "I", "n", TRUE, 8, NULL, list(), at(21)))
  r <- finish_runs(r)
  r <- drive(r$state, ev_set_input("n", 5, at(24)), wk_input_set(1, "I", "n", TRUE, 5, NULL, list(), at(25)))
  expect_null(r$state$input_values$n)
})

test_that("an answer from an old worker, or after the worker exited, is ignored", {
  r <- inputs_ran()
  r <- drive(r$state, ev_set_input("n", 8, at(20)))
  stale <- drive(r$state, wk_input_set(0, "I", "n", TRUE, 8, NULL, list(), at(21)))
  expect_identical(stale$state$worker$input$name, "n")
  gone <- drive(r$state, wk_exited(1, 1L, "killed", at(21)))
  expect_null(gone$state$worker$input)
  late <- drive(gone$state, wk_input_set(1, "I", "n", TRUE, 8, NULL, list(), at(22)))
  expect_null(late$state$input_values$n)
})

test_that("the snapshot lists a cell's inputs", {
  r <- inputs_ran()
  v <- snapshot_of(r$state)$cells$I
  expect_identical(vapply(v$inputs, function(i) i$name, character(1)), c("n", "bins"))
  expect_length(snapshot_of(r$state)$cells$B$inputs, 0)
})

# ---- The page ---------------------------------------------------------------------

test_that("a page value arriving while one is with the worker waits, the latest for each name, and goes when it answers", {
  r <- inputs_ran()
  r <- drive(r$state, ev_set_input("n", 6, at(20), latest = TRUE))
  r <- drive(r$state, ev_set_input("n", 7, at(21), latest = TRUE), ev_set_input("bins", 3, at(21), latest = TRUE),
             ev_set_input("n", 9, at(22), latest = TRUE))
  expect_true(isTRUE(r$reply$accepted))
  expect_length(Filter(function(e) identical(e$msg$type, "set_input"), r$effects), 0)
  expect_identical(lapply(r$state$worker$next_inputs, `[[`, "value"), list(n = 9, bins = 3))
  # The R API's value is still refused meanwhile: its caller is told.
  api <- drive(r$state, ev_set_input("n", 2, at(23)))
  expect_true(inherits(api$reply, "ember_refused"))
  # The answer sends the next one waiting: no run starts in between.
  r <- drive(r$state, wk_input_set(1, "I", "n", TRUE, 6, NULL, list(), at(24)))
  expect_identical(last_sent(r)[c("type", "name", "value")], list(type = "set_input", name = "n", value = 9))
  expect_length(sent_cells(r), 0)
  expect_identical(names(r$state$worker$next_inputs), "bins")
  r <- drive(r$state, wk_input_set(1, "I", "n", TRUE, 9, NULL, list(), at(25)))
  expect_identical(last_sent(r)$name, "bins")
  expect_null(r$state$worker$next_inputs)
  r <- drive(r$state, wk_input_set(1, "I", "bins", TRUE, 3, NULL, list(), at(26)))
  # Only now do the readers run, once, with the latest values.
  expect_identical(sent_cells(r), "B")
  expect_identical(r$state$input_values$n$value, 9)
  expect_identical(r$state$input_values$bins$value, 3)
})

test_that("a waiting page value is dropped when the worker exits, or when its cell is edited meanwhile", {
  r <- inputs_ran()
  r <- drive(r$state, ev_set_input("n", 6, at(20), latest = TRUE), ev_set_input("n", 7, at(21), latest = TRUE))
  gone <- drive(r$state, wk_exited(1, 1L, "killed", at(22)))
  expect_null(gone$state$worker$next_inputs)
  edited <- drive(r$state, ev_apply(list(op_set_code("I", "n <- input_slider(1, 20, 5)\nbins <- input_slider(1, 10, 5)")), at(22)),
                  wk_input_set(1, "I", "n", TRUE, 6, NULL, list(), at(23)))
  expect_null(edited$state$worker$input)
  expect_null(edited$state$worker$next_inputs)
})

test_that("a refused page value is the note under its widget until the next value; an R API value's outcome is its own", {
  r <- inputs_ran()
  r <- drive(r$state, ev_set_input("n", 80, at(20), latest = TRUE),
             wk_input_set(1, "I", "n", FALSE, NULL, "The value must be a number from 1 to 10.", NULL, at(21)))
  expect_null(r$state$input_outcome)
  expect_identical(project_bonds(r$state)$n, list(value = 5, error = "The value must be a number from 1 to 10."))
  # A new value from the page clears it at once.
  r2 <- drive(r$state, ev_set_input("n", 6, at(22), latest = TRUE))
  expect_null(project_bonds(r2$state)$n$error)
  # So does the input's cell running again.
  r3 <- drive(r$state, ev_run("I", at(22)))
  r3 <- drive(r3$state, wk_done(1, last_token(r3), report(created = c("n", "bins"),
                                                          inputs = list(slider_entry("n"), slider_entry("bins"))), at(23)))
  expect_length(r3$state$input_errors, 0)
})

test_that("a page value answered after an R API value can't stand in for its outcome", {
  for (queued in c("n", "bins")) {
    r <- inputs_ran()
    api <- drive(r$state, ev_set_input("n", 80, at(20)))
    token <- api$reply$token
    r <- drive(api$state, ev_set_input(queued, 7, at(21), latest = TRUE),
               wk_input_set(1, "I", "n", FALSE, NULL, "The value must be a number from 1 to 10.", NULL, at(22)))
    r <- drive(r$state, wk_input_set(1, "I", queued, TRUE, 7, NULL, list(), at(23)))
    out <- r$state$input_outcome
    expect_identical(out$token, token, info = queued)
    expect_false(out$ok, info = queued)
    expect_identical(out$error, "The value must be a number from 1 to 10.", info = queued)
  }
})

test_that("bonds show the page's latest value: one waiting, else the one with the worker, else the cell's", {
  r <- inputs_ran()
  expect_identical(project_bonds(r$state), list(n = list(value = 5), bins = list(value = 5)))
  r <- drive(r$state, ev_set_input("n", 6, at(20), latest = TRUE))
  expect_identical(project_bonds(r$state)$n$value, 6)
  r <- drive(r$state, ev_set_input("n", 7, at(21), latest = TRUE))
  expect_identical(project_bonds(r$state)$n$value, 7)
  # An unbound input has no bond.
  s <- r$state
  s$results$I$inputs[[2]]$bound <- FALSE
  expect_null(project_bonds(s)$bins)
})

test_that("a dropdown's value goes to the page as its choice's position, and comes back as the choice", {
  spec <- list(type = "select", choices = list(a = 1L, b = as.Date("2026-01-02"), c = "x"), multiple = FALSE)
  expect_identical(input_to_page(spec, as.Date("2026-01-02")), 1L)
  expect_identical(input_to_page(spec, 1), 0L)       # numbers compare by value, as emberui's check
  expect_null(input_to_page(spec, "nope"))
  expect_identical(input_from_page(spec, 1L), as.Date("2026-01-02"))
  expect_true(inherits(input_from_page(spec, 3L), "ember_page_refusal"))
  expect_true(inherits(input_from_page(spec, list(0L, 1L)), "ember_page_refusal"))
  many <- list(type = "select", choices = c("a", "b", "c"), multiple = TRUE)
  expect_identical(input_to_page(many, c("c", "a")), list(2L, 0L))
  expect_identical(input_from_page(many, list(2L, 0L)), c("c", "a"))
  expect_identical(input_from_page(many, list()), character())
  # Anything else passes through, for the worker's check.
  expect_identical(input_from_page(list(type = "slider"), 7L), 7L)
  expect_identical(input_to_page(list(type = "text"), "hi"), "hi")
})

test_that("input_list()'s value goes to the page part by part, and comes back the same way", {
  spec <- list(type = "list", parts = list(
    n = list(type = "slider", value = 5L, min = 1L, max = 10L),
    m = list(type = "select", choices = c(A = "a", B = "b"), labels = c("A", "B"), multiple = FALSE)))
  expect_identical(input_to_page(spec, list(n = 5L, m = "b")), list(n = 5L, m = 1L))
  expect_identical(input_from_page(spec, list(m = 0L, n = 7L)), list(n = 7L, m = "a"))
  expect_true(inherits(input_from_page(spec, list(n = 7L)), "ember_page_refusal"))
  expect_true(inherits(input_from_page(spec, list(n = 7L, m = 5L)), "ember_page_refusal"))
  expect_true(inherits(input_from_page(spec, 7L), "ember_page_refusal"))
  # Each part's widget fields, in order, under `parts`.
  f <- input_widget_fields(spec)
  expect_identical(f$parts[[1]][c("type", "name", "label", "min", "max", "integer")],
                   list(type = "slider", name = "n", label = "n", min = 1L, max = 10L, integer = TRUE))
  expect_identical(f$parts[[2]][c("type", "name", "label", "multiple")],
                   list(type = "select", name = "m", label = "m", multiple = FALSE))
})

test_that("the page gets each cell's inputs, disabled while the cell is stale, edited or queued, and greyed when unbound", {
  r <- inputs_ran()
  r$state$results$I$inputs[[2]] <- list(name = NULL, bound = FALSE, reason = "not_assigned",
                                       spec = list(type = "radio", value = "b", choices = c("a", "b"), labels = c("A", "B")),
                                       default = "b", value = "b")
  p <- pluto_state(r$state)
  check_wire(p$js)
  ins <- p$js$cell_results$I$ember$inputs
  expect_length(ins, 2)
  expect_identical(ins[[1]][c("type", "name", "label", "bound", "value", "default", "changed", "disabled", "min", "max")],
                   list(type = "slider", name = "n", label = "n", bound = TRUE, value = 5, default = 5,
                        changed = FALSE, disabled = FALSE, min = 1, max = 10))
  expect_identical(ins[[2]][c("type", "bound", "reason", "value", "disabled", "labels")],
                   list(type = "radio", bound = FALSE, reason = "not_assigned", value = 1L, disabled = TRUE,
                        labels = list("A", "B")))
  expect_null(p$js$cell_results$B$ember$inputs)
  expect_identical(p$js$bonds, list(n = list(value = 5)))
  # Only an input the worker reported as the cell's output is drawn as it.
  expect_false(ins[[1]]$output)
  s <- r$state
  s$results$I$inputs[[1]]$output <- TRUE
  expect_true(pluto_state(s, p)$js$cell_results$I$ember$inputs[[1]]$output)
  # An integer input says so: its box rounds before checking its limits, as R does.
  expect_false(ins[[1]]$integer)
  s <- r$state
  s$results$I$inputs[[1]]$spec$value <- 5L
  expect_true(pluto_state(s, p)$js$cell_results$I$ember$inputs[[1]]$integer)

  s <- r$state
  s$results$I$stale <- TRUE
  expect_true(pluto_state(s, p)$js$cell_results$I$ember$inputs[[1]]$disabled)
  edited <- drive(r$state, ev_apply(list(op_set_code("I", "n <- input_slider(1, 20, 5)")), at(30)))
  expect_true(pluto_state(edited$state, p)$js$cell_results$I$ember$inputs[[1]]$disabled)
  # A value off its default is marked.
  set <- drive(r$state, ev_set_input("n", 8, at(20)), wk_input_set(1, "I", "n", TRUE, 8, NULL, list(), at(21)))
  i <- pluto_state(set$state, p)$js$cell_results$I$ember$inputs[[1]]
  expect_identical(c(i$value, i$default), c(8, 5))
  expect_true(i$changed)
})

# ---- The worker ------------------------------------------------------------------

inputs_run_msg <- function(cell, token, code, inputs = input_bindings(code), values = list()) {
  if (!is.null(inputs)) inputs$values <- values
  list(type = "run", cell = cell, token = token, code = code, role = "cell",
       order = unique(c("L", cell)), settings = character(), formulas = list(), library = NULL, fig = NULL,
       inputs = inputs)
}

inputs_run <- function(h, cell, token, code, ...) {
  h$send(inputs_run_msg(cell, token, code, ...))
  wait_for_done(h)
}

reply_of <- function(h, type) {
  repeat {
    m <- next_frame(h)
    if (identical(m$type, type)) return(m)
  }
}

test_that("the worker binds an input only when the assignment's own call reports it (rule 2)", {
  h <- worker_harness(extra_libs = fixture_lib())
  on.exit(h$close())
  r <- inputs_run(h, "L", 1L, "library(emberui)")
  expect_identical(r$status, "ok")
  r <- inputs_run(h, "I", 2L, paste(
    "n <- input_slider(10, 500, value = 100)",
    "w <- round(input_slider(1, 10, 3))",
    "s <- input_slider(1, input_slider(2, 9, 4))",
    "e <- emberui::input_select(c('a', 'b'), 'b')",
    sep = "\n"))
  expect_identical(r$status, "ok")
  got <- lapply(r$inputs, function(i) list(name = i$name, bound = i$bound, reason = i$reason, value = i$value))
  expect_identical(got, list(
    list(name = "n", bound = TRUE, reason = NULL, value = 100),
    list(name = NULL, bound = FALSE, reason = "not_assigned", value = 3),
    list(name = NULL, bound = FALSE, reason = "not_assigned", value = 4),
    list(name = "s", bound = TRUE, reason = NULL, value = 1),
    list(name = "e", bound = TRUE, reason = NULL, value = "b")))
  # Data only: the check function stays in the worker.
  expect_false("check" %in% names(r$inputs[[1]]$spec))
  expect_identical(r$inputs[[1]]$spec$max, 500)

  # A user's own function of the same name reports nothing.
  r <- inputs_run(h, "U", 3L, "input_slider <- function(...) 7\nk <- input_slider(1, 10)")
  expect_length(r$inputs, 0)
})

test_that("a bound input on the last line is the cell's output, as its widget; a blocked one shows its value (review)", {
  h <- worker_harness(extra_libs = fixture_lib())
  on.exit(h$close())
  inputs_run(h, "L", 1L, "library(emberui)")
  r <- inputs_run(h, "I", 2L, "d <- input_slider(1L, 7L, 3L)")
  expect_true(r$inputs[[1]]$bound)
  expect_true(r$inputs[[1]]$output)
  expect_null(r$output)
  r <- inputs_run(h, "J", 3L, "e <- input_slider(1L, 7L, 3L)\nf <- e")
  expect_identical(r$output$text, "[1] 3")
  expect_false(r$inputs[[1]]$output)
  # Not on the last line: not the output, and the last line's value is.
  r <- inputs_run(h, "K", 4L, "g <- input_slider(1L, 7L, 3L)\n2 + 2")
  expect_false(r$inputs[[1]]$output)
  expect_identical(r$output$text, "[1] 4")
})

test_that("a blocked binding is reported with its name and gets its default", {
  h <- worker_harness(extra_libs = fixture_lib())
  on.exit(h$close())
  inputs_run(h, "L", 1L, "library(emberui)")
  r <- inputs_run(h, "I", 2L, "n <- input_slider(1, 10, 5)\nm <- n * 2", values = list(n = 9))
  expect_identical(r$inputs[[1]][c("name", "bound", "reason", "value")],
                   list(name = "n", bound = FALSE, reason = "read_elsewhere", value = 5))
})

test_that("a kept value is used if the input still allows it, and the default otherwise", {
  h <- worker_harness(extra_libs = fixture_lib())
  on.exit(h$close())
  inputs_run(h, "L", 1L, "library(emberui)")
  r <- inputs_run(h, "I", 2L, "n <- input_slider(1, 10, 5)", values = list(n = 8))
  expect_identical(r$inputs[[1]]$value, 8)
  r <- inputs_run(h, "R", 3L, "n", inputs = NULL)
  expect_identical(r$output$text, "[1] 8")
  r <- inputs_run(h, "I", 4L, "n <- input_slider(1, 10, 5)", values = list(n = 80))
  expect_identical(r$inputs[[1]]$value, 5)
})

test_that("set_input checks the value against the input, assigns it, and answers", {
  h <- worker_harness(extra_libs = fixture_lib())
  on.exit(h$close())
  inputs_run(h, "L", 1L, "library(emberui)")
  inputs_run(h, "I", 2L, "n <- input_slider(1L, 10L, 5L)\ng <- input_select(list('x', 2))")
  h$send(list(type = "set_input", cell = "I", name = "n", value = 7.4))
  a <- reply_of(h, "input_set")
  expect_true(a$ok)
  expect_identical(a$value, 7L)
  expect_identical(a$globals$n$type, "integer")
  r <- inputs_run(h, "R", 3L, "n", inputs = NULL)
  expect_identical(r$output$text, "[1] 7")

  h$send(list(type = "set_input", cell = "I", name = "n", value = 70))
  a <- reply_of(h, "input_set")
  expect_false(a$ok)
  expect_identical(a$error, "The value must be a whole number from 1 to 10.")
  h$send(list(type = "set_input", cell = "I", name = "g", value = 2))
  expect_true(reply_of(h, "input_set")$ok)
  h$send(list(type = "set_input", cell = "I", name = "zz", value = 1))
  expect_false(reply_of(h, "input_set")$ok)
})

test_that("input_list() binds as one input: its parts' values in a named list, set together", {
  h <- worker_harness(extra_libs = fixture_lib())
  on.exit(h$close())
  inputs_run(h, "L", 1L, "library(emberui)")
  r <- inputs_run(h, "I", 2L, "p <- input_list(n = input_slider(1L, 10L, 5L), m = input_select(c(A = 'a', B = 'b')))")
  expect_length(r$inputs, 1)
  i <- r$inputs[[1]]
  expect_identical(i[c("name", "bound", "output")], list(name = "p", bound = TRUE, output = TRUE))
  expect_identical(i$value, list(n = 5L, m = "a"))
  expect_identical(i$spec$type, "list")
  expect_identical(names(i$spec$parts), c("n", "m"))
  expect_identical(i$spec$parts$m$labels, c("A", "B"))
  expect_null(r$output)

  h$send(list(type = "set_input", cell = "I", name = "p", value = list(n = 7.4, m = "b")))
  a <- reply_of(h, "input_set")
  expect_true(a$ok)
  expect_identical(a$value, list(n = 7L, m = "b"))
  r <- inputs_run(h, "R", 3L, "paste(p$n, p$m)", inputs = NULL)
  expect_identical(r$output$text, '[1] "7 b"')
  h$send(list(type = "set_input", cell = "I", name = "p", value = list(n = 70, m = "b")))
  a <- reply_of(h, "input_set")
  expect_false(a$ok)
  expect_identical(a$error, "`n`: The value must be a whole number from 1 to 10.")

  # A kept value goes back in when the cell reruns.
  r <- inputs_run(h, "I", 4L, "p <- input_list(n = input_slider(1L, 10L, 5L), m = input_select(c(A = 'a', B = 'b')))",
                  values = list(p = list(n = 9L, m = "b")))
  expect_identical(r$inputs[[1]]$value, list(n = 9L, m = "b"))
  # Part by part: a part that no longer allows its value gets its default, the others keep theirs.
  r <- inputs_run(h, "I", 5L, "p <- input_list(n = input_slider(1L, 10L, 5L), m = input_select(c(A = 'a', B = 'b')))",
                  values = list(p = list(n = 99L, m = "b")))
  expect_identical(r$inputs[[1]]$value, list(n = 5L, m = "b"))
})

test_that("a failed run leaves no input to set", {
  h <- worker_harness(extra_libs = fixture_lib())
  on.exit(h$close())
  inputs_run(h, "L", 1L, "library(emberui)")
  r <- inputs_run(h, "I", 2L, "n <- input_slider(1, 10, 5)\nstop('no')")
  expect_identical(r$status, "error")
  h$send(list(type = "set_input", cell = "I", name = "n", value = 6))
  expect_false(reply_of(h, "input_set")$ok)
})

test_that("without the hook, an input returns its default", {
  lib <- fixture_lib()
  out <- processx::run(file.path(R.home("bin"), "Rscript"),
    c("--vanilla", "-e", "library(emberui); cat(input_slider(1, 10, 4), input_select(c('a', 'b')))"),
    env = c("current", R_LIBS_USER = lib, R_LIBS = "", R_LIBS_SITE = ""), error_on_status = FALSE)
  expect_identical(out$stdout, "4 a")
})

test_that("emberui's own tests pass", {
  lib <- fixture_lib()
  tests <- file.path(emberui_source(), "tests", "testthat")
  out <- processx::run(file.path(R.home("bin"), "Rscript"),
    c("--vanilla", "-e", sprintf(
      "testthat::test_dir(%s, package = 'emberui', load_package = 'installed', reporter = 'summary', stop_on_failure = TRUE)",
      deparse(tests))),
    env = c("current", R_LIBS = paste(c(lib, .libPaths()), collapse = .Platform$path.sep)),
    error_on_status = FALSE, stderr_to_stdout = TRUE)
  expect_identical(out$status, 0L, info = out$stdout)
})

# ---- End to end ------------------------------------------------------------------

#' A `file://` CRAN-like repository holding emberui, built from
#' inst/emberui, dated `date` (as the toy repo in
#' test-packages-session.R is laid out). Returns the root.
ui_repo <- function(date = "2026-09-01") {
  root <- tempfile("ember-ui-repo-")
  contrib <- file.path(root, date, "src", "contrib")
  dir.create(contrib, recursive = TRUE)
  src <- emberui_source()
  res <- run_guarded(file.path(R.home("bin"), "R"), c("CMD", "build", "--no-manual", "--no-build-vignettes", src),
                     wd = contrib, error_on_status = FALSE)
  if (res$status != 0) stop("could not build emberui:\n", res$stderr)
  tools::write_PACKAGES(contrib, type = "source")
  root
}

test_that("set_input through the API reruns the readers with the new value, and keeps it when the input's cell reruns", {
  use_installed_ember()
  root <- ui_repo()
  cache <- tempfile("ember-pkg-cache-")
  dir.create(cache)
  on.exit(unlink(c(root, cache), recursive = TRUE), add = TRUE)
  path <- write_session_notebook(list(
    L = cell("library(emberui)"),
    I = cell("n <- input_slider(1L, 10L, 5L)"),
    B = cell("n * 2")), snapshot = "2026-09-01")
  nb <- open_notebook(path, repos = ember_repos(cran = paste0("file://", root)), cache = cache)
  on.exit(close_notebook(nb), add = TRUE)
  res <- run_settled(nb)
  out_of <- function(id) snap_view(notebook_snapshot(nb), id)$output$text
  expect_identical(out_of("B"), "[1] 10")
  # The input's own cell shows no value that could go stale.
  expect_null(snap_view(notebook_snapshot(nb), "I")$output)

  out <- waiting_for("B to rerun with n = 7", set_input(nb, "n", 7, wait = TRUE, timeout = Inf), nb)
  expect_identical(out$cell, "I")
  expect_identical(out$value, 7L)
  expect_identical(out$cells, "B")
  expect_identical(out_of("B"), "[1] 14")
  expect_identical(snap_view(notebook_snapshot(nb), "I")$inputs[[1]]$value, 7L)

  expect_error(set_input(nb, "n", 70, wait = TRUE), "from 1 to 10")
  expect_error(set_input(nb, "m", 1), "No input is bound")

  # The input's cell reruns (as when something it reads changes): the value stays.
  run_settled(nb, "I")
  expect_identical(snap_view(notebook_snapshot(nb), "I")$inputs[[1]]$value, 7L)
  expect_identical(out_of("B"), "[1] 14")
})
