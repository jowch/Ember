# Each input function checks its arguments, builds a spec, and hands it to
# report(). Outside Ember there is no hook and report() returns the default.
# In Ember the worker sets `.state$hook` when this package loads (Ember's
# docs/inputs.md, "Built so far"); the hook is called with the spec and the
# input function's own call, and returns the value to use.
#
# `spec` is `list(type, value, label, ...)`, `value` being the default, plus
# `check`: a function that takes a proposed value and returns it as the
# input would, or stops with a message saying what the input allows. The
# worker uses `check` for a value the page sends and for a kept value when
# the cell reruns. The default is checked the same way, so a bad default is
# an error in Ember and in Rscript alike.

# An environment in the namespace stays writable after the namespace is
# locked, so the worker can set the hook in it.
.state <- new.env(parent = emptyenv())

report <- function(spec, call) {
  spec$value <- spec$check(spec$value)
  hook <- .state$hook
  if (is.function(hook)) hook(spec, call) else spec$value
}

# The six input functions; man/inputs.Rd documents them.

input_slider <- function(min, max, value = min, step = NULL, label = NULL) {
  call <- sys.call()
  check_bound(min, "min", na = FALSE)
  check_bound(max, "max", na = FALSE)
  if (min > max) stop("`min` must not be larger than `max`.", call. = FALSE)
  if (!is.null(step)) check_step(step)
  check_label(label)
  report(list(type = "slider", value = value, min = min, max = max, step = step,
              label = label, check = number_check(value, min, max)), call)
}

input_number <- function(value = 0, min = NA, max = NA, step = NA, label = NULL) {
  call <- sys.call()
  check_bound(min, "min", na = TRUE)
  check_bound(max, "max", na = TRUE)
  if (!is.na(min) && !is.na(max) && min > max) {
    stop("`min` must not be larger than `max`.", call. = FALSE)
  }
  if (!(length(step) == 1 && is.na(step))) check_step(step)
  check_label(label)
  report(list(type = "number", value = value, min = min, max = max, step = step,
              label = label, check = number_check(value, min, max)), call)
}

input_checkbox <- function(value = FALSE, label = NULL) {
  call <- sys.call()
  check_label(label)
  check <- function(x) {
    if (!is.logical(x) || length(x) != 1 || is.na(x)) {
      stop("The value must be TRUE or FALSE.", call. = FALSE)
    }
    as.vector(x)
  }
  report(list(type = "checkbox", value = value, label = label, check = check), call)
}

input_text <- function(value = "", label = NULL) {
  call <- sys.call()
  check_label(label)
  check <- function(x) {
    if (!is.character(x) || length(x) != 1 || is.na(x)) {
      stop("The value must be one string.", call. = FALSE)
    }
    as.vector(x)
  }
  report(list(type = "text", value = value, label = label, check = check), call)
}

input_select <- function(choices, selected = choices[[1]], multiple = FALSE, label = NULL) {
  call <- sys.call()
  check_choices(choices)
  if (!isTRUE(multiple) && !isFALSE(multiple)) {
    stop("`multiple` must be TRUE or FALSE.", call. = FALSE)
  }
  check_label(label)
  check <- if (multiple) choices_check_many(choices) else choices_check(choices)
  report(list(type = "select", value = selected, choices = choices,
              labels = choice_labels(choices), multiple = multiple,
              label = label, check = check), call)
}

input_radio <- function(choices, selected = choices[[1]], label = NULL) {
  call <- sys.call()
  check_choices(choices)
  check_label(label)
  report(list(type = "radio", value = selected, choices = choices,
              labels = choice_labels(choices), label = label,
              check = choices_check(choices)), call)
}

# A number in [min, max] (`NA` is no limit), returned with `value`'s type:
# an integer input rounds.
number_check <- function(value, min, max) {
  integer <- is.integer(value)
  function(x) {
    if (!is.numeric(x) || length(x) != 1 || !is.finite(x) ||
        (!is.na(min) && x < min) || (!is.na(max) && x > max)) {
      stop(number_allowed(min, max, integer), call. = FALSE)
    }
    if (integer) {
      x <- round(x)
      if (abs(x) > .Machine$integer.max) stop(number_allowed(min, max, integer), call. = FALSE)
      as.integer(x)
    } else {
      as.numeric(x)
    }
  }
}

number_allowed <- function(min, max, integer) {
  what <- if (integer) "a whole number" else "a number"
  if (!is.na(min) && !is.na(max)) {
    sprintf("The value must be %s from %s to %s.", what, format(min), format(max))
  } else if (!is.na(min)) {
    sprintf("The value must be %s of at least %s.", what, format(min))
  } else if (!is.na(max)) {
    sprintf("The value must be %s of at most %s.", what, format(max))
  } else {
    sprintf("The value must be %s.", what)
  }
}

# One of `choices`, compared with identical() and ignoring names, so
# c(Pearson = "pearson") offers "pearson". Returns the element as it is in
# `choices` (without its name).
choices_check <- function(choices) {
  function(x) {
    i <- choice_index(choices, x)
    if (is.na(i)) stop("The value must be one of the choices.", call. = FALSE)
    choices[[i]]
  }
}

# Several of `choices`: a vector (or list, for list choices) whose every
# element is one of them. Returns them in the order given.
choices_check_many <- function(choices) {
  function(x) {
    items <- if (is.list(x)) x else as.list(x)
    idx <- vapply(items, function(item) choice_index(choices, item), integer(1))
    if (anyNA(idx)) stop("Every value must be one of the choices.", call. = FALSE)
    unname(choices[idx])
  }
}

choice_index <- function(choices, x) {
  x <- unname(x)
  for (i in seq_along(choices)) {
    if (identical(unname(choices[[i]]), x)) return(i)
  }
  NA_integer_
}

# What the widget shows for each choice: its name, or the element printed.
choice_labels <- function(choices) {
  shown <- vapply(choices, function(ch) paste(format(ch), collapse = " "), character(1),
                  USE.NAMES = FALSE)
  nms <- names(choices)
  if (is.null(nms)) return(shown)
  ifelse(is.na(nms) | nms == "", shown, nms)
}

check_choices <- function(choices) {
  if (!(is.atomic(choices) || is.list(choices)) || length(choices) == 0) {
    stop("`choices` must be a vector or list with at least one element.", call. = FALSE)
  }
}

check_bound <- function(x, what, na) {
  ok <- length(x) == 1 && ((is.numeric(x) && is.finite(x)) || (na && is.na(x)))
  if (!ok) {
    stop(sprintf("`%s` must be one finite number%s.", what, if (na) " or NA" else ""), call. = FALSE)
  }
}

check_step <- function(step) {
  if (!is.numeric(step) || length(step) != 1 || is.na(step) || !is.finite(step) || step <= 0) {
    stop("`step` must be one positive number.", call. = FALSE)
  }
}

check_label <- function(label) {
  if (!is.null(label) && !(is.character(label) && length(label) == 1 && !is.na(label))) {
    stop("`label` must be one string or NULL.", call. = FALSE)
  }
}
