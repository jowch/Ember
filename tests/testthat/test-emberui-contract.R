# The interface between emberui and Ember's worker (docs/inputs.md, "Built
# so far"), pinned (#537). emberui reaches users from r-universe's build of
# main, so a released Ember meets newer emberuis, and a notebook's lock can
# pair a newer Ember with an older emberui. Each side must keep to what is
# pinned here. Adding a field is safe: Ember ignores what it doesn't read.
# Removing or renaming one, or changing how the hook is called, breaks
# notebooks on a released Ember, so a change to this file needs a plan for
# those (#537).

#' The fields every spec has, then each type's own. Each `type` is one of
#' these names.
contract_common <- c("type", "value", "label", "check")
contract_fields <- list(
  slider = c("min", "max", "step"),
  number = c("min", "max", "step"),
  checkbox = character(),
  text = character(),
  select = c("choices", "labels", "multiple"),
  radio = c("choices", "labels"),
  # input_list(): `parts` is each part's spec without `check`, by name;
  # `keep` keeps a value part by part. It has no `label`.
  list = c("parts", "keep"))

#' One call of each input, and a value its `check` must refuse.
contract_calls <- list(
  list(quote(input_slider(1, 10, 5, step = 1, label = "n")), bad = 11),
  list(quote(input_number(2, 0, 9, 1)), bad = "x"),
  list(quote(input_checkbox(TRUE)), bad = "yes"),
  list(quote(input_text("a")), bad = 1),
  list(quote(input_select(c(A = "a", B = "b"), "b")), bad = "c"),
  list(quote(input_select(c("a", "b"), c("a", "b"), multiple = TRUE)), bad = "c"),
  list(quote(input_radio(c("x", "y"))), bad = "z"),
  list(quote(input_list(n = input_slider(1, 10), m = input_select(c("a", "b")))), bad = list(n = 1)))

test_that("emberui hands the hook each input's spec and its own call, and returns what the hook returns (#537)", {
  loaded <- isNamespaceLoaded("emberui")
  ns <- loadNamespace("emberui", lib.loc = fixture_lib())
  on.exit(if (!loaded) unloadNamespace("emberui"), add = TRUE)

  # The worker finds `.state` in the namespace and puts the hook in it.
  st <- get0(".state", envir = ns, inherits = FALSE)
  expect_true(is.environment(st))
  old <- st$hook
  on.exit(st$hook <- old, add = TRUE)
  seen <- NULL
  st$hook <- function(spec, call) {
    seen <<- list(spec = spec, call = call)
    "from the hook"
  }

  for (k in contract_calls) {
    expr <- k[[1]]
    label <- deparse(expr)
    seen <- NULL
    expect_identical(eval(expr, new.env(parent = ns)), "from the hook", label = label)
    s <- seen$spec
    # The worker binds an input by comparing this call with the code's.
    expect_identical(seen$call, expr, label = label)
    expect_true(s$type %in% names(contract_fields), label = label)
    common <- if (s$type == "list") setdiff(contract_common, "label") else contract_common
    expect_true(all(c(common, contract_fields[[s$type]]) %in% names(s)), label = label)
    expect_true(is.function(s$check), label = label)
    expect_identical(s$check(s$value), s$value, label = label)
    expect_error(s$check(k$bad), label = label)
    if (s$type %in% c("select", "radio")) {
      expect_type(s$labels, "character")
      expect_length(s$labels, length(s$choices))
    }
    if (s$type == "select") expect_true(isTRUE(s$multiple) || isFALSE(s$multiple), label = label)
    if (s$type == "list") {
      expect_true(is.function(s$keep), label = label)
      for (nm in names(s$parts)) {
        p <- s$parts[[nm]]
        expect_true(all(c("type", "value", "label", contract_fields[[p$type]]) %in% names(p)), label = label)
        expect_false("check" %in% names(p), label = label)
      }
      expect_identical(names(s$value), names(s$parts), label = label)
    }
  }
})

test_that("Ember draws and sets an input whose spec has only the pinned fields, as an older emberui's (#537)", {
  check <- function(x) x
  specs <- list(
    slider = list(type = "slider", value = 5, label = NULL, check = check, min = 1, max = 10, step = 1),
    number = list(type = "number", value = 2, label = NULL, check = check, min = NA, max = NA, step = NA),
    checkbox = list(type = "checkbox", value = TRUE, label = "Show", check = check),
    text = list(type = "text", value = "a", label = NULL, check = check),
    select = list(type = "select", value = "b", label = NULL, check = check, choices = c(A = "a", B = "b"),
                  labels = c("A", "B"), multiple = FALSE),
    radio = list(type = "radio", value = "x", label = NULL, check = check, choices = c("x", "y"), labels = c("x", "y")),
    list = list(type = "list", value = list(n = 1, m = "a"), check = check, keep = check,
                parts = list(n = list(type = "slider", value = 1, label = NULL, min = 1, max = 10, step = NULL),
                             m = list(type = "select", value = "a", label = NULL, choices = c("a", "b"),
                                      labels = c("a", "b"), multiple = FALSE))))
  # The worker sends each spec without its functions (inst/worker.R, input_hook()).
  plain <- function(s) s[!vapply(s, is.function, logical(1))]
  view <- list(inputs = lapply(names(specs), function(nm) {
    s <- plain(specs[[nm]])
    list(name = nm, bound = TRUE, output = FALSE, spec = s, default = s$value, value = s$value)
  }))
  drawn <- project_inputs(view)
  expect_identical(vapply(drawn, `[[`, character(1), "type"), names(specs))
  by_type <- structure(drawn, names = names(specs))
  expect_identical(by_type$slider[c("min", "max", "step", "integer")], list(min = 1, max = 10, step = 1, integer = FALSE))
  expect_identical(by_type$select$value, 1L)
  expect_identical(by_type$select$labels, list("A", "B"))
  expect_identical(by_type$radio$value, 0L)
  expect_identical(vapply(by_type$list$parts, `[[`, character(1), "type"), c("slider", "select"))
  expect_identical(by_type$list$value, list(n = 1, m = 0L))
  # A value from the page goes back as the R value the worker's check gets.
  expect_identical(input_from_page(plain(specs$select), 0L), "a")
  expect_identical(input_from_page(plain(specs$radio), 1L), "y")
  expect_identical(input_from_page(plain(specs$list), list(n = 3, m = 1L)), list(n = 3, m = "b"))
  expect_identical(input_from_page(plain(specs$slider), 7), 7)
})
