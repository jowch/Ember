# Without the hook each function returns its default; with it, the hook gets
# the spec and the call and its answer is the value.

with_hook <- function(hook, code) {
  state <- emberui:::.state
  old <- state$hook
  state$hook <- hook
  on.exit(state$hook <- old)
  code
}

test_that("without the hook each input returns its default, as under Rscript", {
  expect_identical(input_slider(10, 500, value = 100), 100)
  expect_identical(input_slider(10, 500), 10)
  expect_identical(input_slider(1L, 10L), 1L)
  expect_identical(input_number(), 0)
  expect_identical(input_number(5L), 5L)
  expect_identical(input_checkbox(), FALSE)
  expect_identical(input_checkbox(TRUE, label = "Show"), TRUE)
  expect_identical(input_text(), "")
  expect_identical(input_text("Results"), "Results")
  expect_identical(input_select(c("a", "b")), "a")
  expect_identical(input_select(c(Pearson = "pearson", Spearman = "spearman")), "pearson")
  expect_identical(input_select(c("a", "b", "c"), selected = c("c", "a"), multiple = TRUE), c("c", "a"))
  expect_identical(input_radio(list(1, "x"), selected = "x"), "x")
  # Numbers match by value, as %in% does, and come back as the choice is.
  expect_identical(input_select(1:10, selected = 5), 5L)
  expect_identical(input_radio(c(10, 20, 50), selected = 20L), 20)
  # No step is NULL or NA in both.
  expect_identical(input_number(5, step = NULL), 5)
  expect_identical(input_slider(1, 10, step = NA), 1)
  # A returned value is plain: no class, no attributes.
  expect_null(attributes(input_slider(1, 10, value = 3)))
  expect_null(attributes(input_select(c(A = "a"))))
})

test_that("a bad argument or default is an error, in Ember and Rscript alike", {
  expect_error(input_slider(1, 10, value = 20), "from 1 to 10")
  expect_error(input_slider(10, 1), "`min` must not be larger")
  expect_error(input_slider(1, Inf), "`max` must be one finite number")
  expect_error(input_slider(1, 10, step = 0), "`step`")
  expect_error(input_number(-1, min = 0), "at least 0")
  expect_error(input_number(1, step = -1), "`step`")
  expect_error(input_checkbox(NA), "TRUE or FALSE")
  expect_error(input_checkbox("yes"), "TRUE or FALSE")
  expect_error(input_text(c("a", "b")), "one string")
  expect_error(input_select(c("a", "b"), selected = "z"), "one of the choices")
  expect_error(input_select(character()), "at least one element")
  expect_error(input_select(c("a", "b"), selected = c("a", "z"), multiple = TRUE), "Every value")
  expect_error(input_select(c("a", "b"), selected = c("a", "a"), multiple = TRUE), "only once")
  expect_error(input_radio(c("a", "b"), selected = "z"), "one of the choices")
  expect_error(input_text(label = 1), "`label`")
  # The error is the same with the hook set: the default is checked first.
  with_hook(function(spec, call) stop("not reached"),
            expect_error(input_slider(1, 10, value = 20), "from 1 to 10"))
})

test_that("with the hook, the hook gets the spec and the call, and its answer is the value", {
  seen <- NULL
  hook <- function(spec, call) {
    seen <<- list(spec = spec, call = call)
    42
  }
  value <- with_hook(hook, input_slider(10, 500, value = 100, step = 10))
  expect_identical(value, 42)
  expect_identical(seen$call, quote(input_slider(10, 500, value = 100, step = 10)))
  spec <- seen$spec
  expect_identical(spec$type, "slider")
  expect_identical(spec$value, 100)
  expect_identical(spec[c("min", "max", "step")], list(min = 10, max = 500, step = 10))
  expect_null(spec$label)
  expect_true(is.function(spec$check))

  with_hook(hook, input_select(c(Pearson = "pearson", Spearman = "spearman"), label = "Method"))
  expect_identical(seen$spec$type, "select")
  expect_identical(seen$spec$value, "pearson")
  expect_identical(seen$spec$labels, c("Pearson", "Spearman"))
  expect_identical(seen$spec$label, "Method")
  expect_false(seen$spec$multiple)

  # The call is the input function's own, written as the user wrote it.
  with_hook(hook, emberui::input_checkbox(TRUE))
  expect_identical(seen$call, quote(emberui::input_checkbox(TRUE)))
})

test_that("each spec's check returns a value as the input would, or says what it allows", {
  spec_of <- function(code) {
    spec <- NULL
    with_hook(function(s, call) { spec <<- s; s$value }, code)
    spec
  }
  slider <- spec_of(input_slider(1L, 10L, value = 3L))
  expect_identical(slider$check(4.6), 5L)
  expect_error(slider$check(11), "whole number from 1 to 10")
  expect_error(slider$check("5"), "whole number")
  expect_error(slider$check(c(1, 2)), "whole number")

  # An integer input rounds before the range is checked.
  expect_error(spec_of(input_number(2L, max = 2.6))$check(2.55), "at most 2.6")
  expect_identical(spec_of(input_number(2L, max = 2.6))$check(2.45), 2L)

  # A slider's values are its steps, counted from `min` (#448). A decimal
  # step matches the page's decimals; an integer slider rounds first.
  stepped <- spec_of(input_slider(10, 500, value = 100, step = 10))
  expect_identical(stepped$check(250), 250)
  expect_identical(stepped$check(500), 500)
  expect_error(stepped$check(255), "The value must be a number from 10 to 500 in steps of 10.", fixed = TRUE)
  expect_error(stepped$check(600), "in steps of 10")
  from_one <- spec_of(input_slider(1L, 9L, step = 2))
  expect_identical(from_one$check(5), 5L)
  expect_identical(from_one$check(4.8), 5L)
  expect_error(from_one$check(4), "whole number from 1 to 9 in steps of 2")
  tenths <- spec_of(input_slider(0, 1, step = 0.1))
  expect_identical(tenths$check(0.3), 0.3)
  expect_identical(tenths$check(0.7), 0.7)
  expect_error(tenths$check(0.35), "in steps of 0.1")
  expect_identical(spec_of(input_slider(1, 10))$check(2.5), 2.5)
  # The message names the last step, where the slider stops.
  thirds <- spec_of(input_slider(0, 10, step = 3))
  expect_error(thirds$check(10), "The value must be a number from 0 to 9 in steps of 3.", fixed = TRUE)
  expect_error(spec_of(input_slider(0, 1, step = 0.1))$check(0.35), "from 0 to 1 in steps of 0.1", fixed = TRUE)
  # The tolerance doesn't grow to a whole step on a long slider (review).
  long <- spec_of(input_slider(0, 1e10, step = 1))
  expect_identical(long$check(5e9), 5e9)
  expect_error(long$check(5e9 + 0.5), "in steps of 1")
  # A default off its step is an error in Ember and in Rscript alike.
  expect_error(input_slider(10, 500, value = 105, step = 10), "in steps of 10")
  # A number box takes its step as a hint, as Pluto and Shiny do.
  expect_identical(spec_of(input_number(10, step = 10))$check(7.3), 7.3)
  expect_identical(input_number(7, min = 0, step = 5), 7)

  number <- spec_of(input_number(1.5, max = 2))
  expect_identical(number$check(-100), -100)
  expect_error(number$check(3), "at most 2")
  expect_error(number$check(NaN), "a number")

  expect_identical(spec_of(input_checkbox())$check(TRUE), TRUE)
  expect_error(spec_of(input_checkbox())$check(1), "TRUE or FALSE")
  expect_identical(spec_of(input_text())$check("x"), "x")
  expect_error(spec_of(input_text())$check(NA_character_), "one string")

  # A choice is matched with identical(), names ignored, and returned as it
  # is in `choices`.
  select <- spec_of(input_select(list(a = 1L, b = c(2, 3), c = "x")))
  expect_identical(select$check(c(2, 3)), c(2, 3))
  expect_identical(select$check(c(z = "x")), "x")
  expect_identical(select$check(1), 1L)  # 1 is the choice 1L, which comes back as it is
  expect_error(select$check("1"), "one of the choices")  # a string isn't a number
  expect_error(select$check(factor("x")), "one of the choices")
  many <- spec_of(input_select(c("a", "b", "c"), selected = "a", multiple = TRUE))
  expect_identical(many$check(c("c", "b")), c("c", "b"))
  expect_identical(many$check(character()), character())
  expect_error(many$check(c("a", "q")), "Every value")
  radio <- spec_of(input_radio(c("a", "b")))
  expect_identical(radio$check("b"), "b")
})

test_that("a choice's label is its name, or the element printed", {
  expect_identical(emberui:::choice_labels(c(A = "a", "b")), c("A", "b"))
  expect_identical(emberui:::choice_labels(list(1:3, TRUE)), c("1 2 3", "TRUE"))
})

test_that("input_list() is a named list of its inputs' values, and reports once, as one input", {
  p <- input_list(n = input_slider(1L, 10L, 5L), method = input_select(c(A = "a", B = "b")))
  expect_identical(p, list(n = 5L, method = "a"))

  seen <- list()
  hook <- function(spec, call) {
    seen[[length(seen) + 1L]] <<- list(spec = spec, call = call)
    spec$value
  }
  value <- with_hook(hook, input_list(n = input_slider(1L, 10L, 5L), show = input_checkbox(TRUE)))
  expect_identical(value, list(n = 5L, show = TRUE))
  expect_length(seen, 1)
  expect_identical(seen[[1]]$call, quote(input_list(n = input_slider(1L, 10L, 5L), show = input_checkbox(TRUE))))
  spec <- seen[[1]]$spec
  expect_identical(spec$type, "list")
  expect_identical(names(spec$parts), c("n", "show"))
  expect_identical(spec$parts$n$type, "slider")
  expect_identical(spec$parts$n[c("min", "max", "value")], list(min = 1L, max = 10L, value = 5L))
  # The parts carry no function: their checks are in the list's own.
  expect_false(any(vapply(spec$parts$n, is.function, logical(1))))

  # The check takes a list with every name, checks each part, and says which failed.
  expect_identical(spec$check(list(show = FALSE, n = 7.4)), list(n = 7L, show = FALSE))
  expect_error(spec$check(list(n = 20L, show = TRUE)), "`n`: The value must be a whole number from 1 to 10.", fixed = TRUE)
  expect_error(spec$check(list(n = 2L)), "a list with the names n, show")
  expect_error(spec$check(c(n = 2L, show = 1L)), "a list with the names n, show")

  # An input inside a part's own arguments reports as usual.
  seen <- list()
  with_hook(hook, input_list(n = input_slider(1, input_number(10))))
  expect_identical(vapply(seen, function(s) s$spec$type, ""), c("number", "list"))
  # Even one identical to another part's call (review).
  seen <- list()
  value <- with_hook(hook, input_list(a = input_number(10), b = input_slider(1, input_number(10))))
  expect_identical(value, list(a = 10, b = 1))
  expect_identical(vapply(seen, function(s) s$spec$type, ""), c("number", "list"))

  # A kept value is kept part by part: a part that no longer fits gets its default.
  expect_identical(spec$keep(list(n = 99L, show = FALSE)), list(n = 5L, show = FALSE))
  expect_identical(spec$keep(list(show = FALSE)), list(n = 5L, show = FALSE))
  expect_identical(spec$keep("junk"), list(n = 5L, show = TRUE))
})

test_that("input_list() needs named input calls, each once, and no list inside", {
  expect_error(input_list(), "at least one input")
  expect_error(input_list(input_slider(1, 10)), "needs a name")
  expect_error(input_list(n = input_slider(1, 10), input_checkbox()), "needs a name")
  expect_error(input_list(n = input_slider(1, 10), n = input_checkbox()), "`n` is repeated")
  expect_error(input_list(n = 5), "`n` in `input_list()` must be an input call", fixed = TRUE)
  my_slider <- function() input_slider(1, 10)
  expect_error(input_list(n = my_slider()), "must be an input call")
  expect_error(input_list(p = input_list(n = input_slider(1, 10))), "can't hold another")
  # A bad part is the part's own error, in Ember and Rscript alike.
  expect_error(input_list(n = input_slider(1, 10, value = 20)), "from 1 to 10")
  # Nothing is left over to catch a later input as a part.
  expect_null(emberui:::.state$parts)
  expect_identical(input_slider(1, 10), 1)
})

test_that("the call reaches the hook without a srcref, so it compares equal to the code's own", {
  # With keep.source on, as in Ember's worker, sys.call() from inside a
  # promise can carry the enclosing line's srcref.
  call <- quote(input_slider(1, 3))
  attr(call, "srcref") <- srcref(srcfilecopy("<text>", "x <- f()"), c(1L, 1L, 1L, 8L))
  seen <- NULL
  with_hook(function(spec, call) { seen <<- call; spec$value },
            emberui:::report(list(type = "slider", value = 1, check = identity), call))
  expect_identical(seen, quote(input_slider(1, 3)))
})
