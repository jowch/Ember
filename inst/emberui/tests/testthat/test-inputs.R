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
  expect_error(select$check(1), "one of the choices")  # double, not the integer 1L
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
