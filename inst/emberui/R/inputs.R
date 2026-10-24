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
  # With `keep.source` on (as in Ember's worker), `sys.call()` from inside a
  # promise can carry the enclosing line's srcref, which would make the
  # call differ from the code's own; only the call itself counts.
  attr(call, "srcref") <- NULL
  # One of input_list()'s parts: input_list() reports it as part of itself.
  if (any(vapply(.state$parts, identical, logical(1), call))) {
    return(structure(list(spec = spec), class = "emberui_part"))
  }
  hook <- .state$hook
  if (is.function(hook)) hook(spec, call) else spec$value
}

# The input functions; man/inputs.Rd documents them.

input_slider <- function(min, max, value = min, step = NULL, label = NULL) {
  call <- sys.call()
  check_bound(min, "min", na = FALSE)
  check_bound(max, "max", na = FALSE)
  if (min > max) stop("`min` must not be larger than `max`.", call. = FALSE)
  check_step(step)
  check_label(label)
  report(list(type = "slider", value = value, min = min, max = max, step = step,
              label = label, check = number_check(value, min, max, step)), call)
}

input_number <- function(value = 0, min = NA, max = NA, step = NA, label = NULL) {
  call <- sys.call()
  check_bound(min, "min", na = TRUE)
  check_bound(max, "max", na = TRUE)
  if (!is.na(min) && !is.na(max) && min > max) {
    stop("`min` must not be larger than `max`.", call. = FALSE)
  }
  check_step(step)
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

# Several inputs as one: a named list of their values. Each argument must be
# an input call itself (`n = input_slider(1, 10)`); while input_list()
# evaluates them, report() hands each back as a part instead of reporting
# it, by its call, so an input nested inside a part's own arguments still
# reports as usual. Only the list reports, as one input.
input_list <- function(...) {
  call <- sys.call()
  exprs <- match.call(expand.dots = FALSE)$...
  nms <- names(exprs)
  if (length(exprs) == 0) stop("`input_list()` needs at least one input.", call. = FALSE)
  if (is.null(nms) || any(is.na(nms) | nms == "")) {
    stop("Every input in `input_list()` needs a name, as in `input_list(n = input_slider(1, 10))`.", call. = FALSE)
  }
  if (anyDuplicated(nms)) {
    stop(sprintf("Each name in `input_list()` must be used once; `%s` is repeated.", nms[anyDuplicated(nms)]), call. = FALSE)
  }
  # One part at a time, with only that part's call listed: an input inside
  # its arguments identical to another part's call reports as usual.
  outer <- .state$parts
  values <- structure(vector("list", length(exprs)), names = nms)
  for (k in seq_along(exprs)) {
    .state$parts <- c(outer, list(exprs[[k]]))
    values[k] <- list(tryCatch(...elt(k), finally = .state$parts <- outer))
  }
  bad <- !vapply(values, inherits, logical(1), "emberui_part")
  if (any(bad)) {
    stop(sprintf("`%s` in `input_list()` must be an input call, such as `%s = input_slider(1, 10)`.",
                 nms[bad][1], nms[bad][1]), call. = FALSE)
  }
  specs <- lapply(values, `[[`, "spec")
  if (any(vapply(specs, function(s) identical(s$type, "list"), logical(1)))) {
    stop("`input_list()` can't hold another `input_list()`.", call. = FALSE)
  }
  checks <- lapply(specs, `[[`, "check")
  check <- function(x) {
    if (!is.list(x) || is.null(names(x)) || anyDuplicated(names(x)) || !setequal(names(x), nms)) {
      stop(sprintf("The value must be a list with the names %s.", paste(nms, collapse = ", ")), call. = FALSE)
    }
    out <- lapply(nms, function(nm) {
      tryCatch(checks[[nm]](x[[nm]]),
               error = function(e) stop(sprintf("`%s`: %s", nm, conditionMessage(e)), call. = FALSE))
    })
    names(out) <- nms
    out
  }
  # A kept value is kept part by part: a part that no longer allows its
  # value goes back to its default, and the others keep theirs.
  keep <- function(x) {
    out <- lapply(nms, function(nm) {
      v <- if (is.list(x)) x[[nm]]
      tryCatch(checks[[nm]](v), error = function(e) specs[[nm]]$value)
    })
    names(out) <- nms
    out
  }
  parts <- lapply(specs, function(s) s[names(s) != "check"])
  names(parts) <- nms
  report(list(type = "list", value = lapply(parts, `[[`, "value"), parts = parts,
              check = check, keep = keep), call)
}

# A number in [min, max] (`NA` is no limit), returned with `value`'s type:
# an integer input rounds.
number_check <- function(value, min, max, step = NULL) {
  integer <- is.integer(value)
  allowed <- number_allowed(min, max, integer, step)
  function(x) {
    if (!is.numeric(x) || length(x) != 1 || !is.finite(x)) {
      stop(allowed, call. = FALSE)
    }
    # An integer input rounds first, so the rounded value is the one in range.
    x <- if (integer) round(x) else as.numeric(x)
    if ((!is.na(min) && x < min) || (!is.na(max) && x > max) ||
        (integer && abs(x) > .Machine$integer.max) || !on_step(x, min, step)) {
      stop(allowed, call. = FALSE)
    }
    if (integer) as.integer(x) else x
  }
}

# Whether `x` is on a slider's steps, counted from `min`, as the browser's
# own slider counts them. Only a slider passes a step: a number box takes it
# as a hint, as Pluto's NumberField and Shiny's numericInput do (#448). The
# page sends decimals (0.3 from 0 in steps of 0.1), which differ from
# min + k * step by a rounding error, so a step is matched to within 1e-9 of
# one, plus the error that grows with k (a few ulps of k).
on_step <- function(x, min, step) {
  if (is.null(step) || is.na(step)) return(TRUE)
  k <- (x - min) / step
  abs(k - round(k)) <= 1e-9 + 8 * .Machine$double.eps * abs(k)
}

# A slider's last step, which is `max` only when `max` is on a step: the
# browser's slider stops at the last step (0, 3, 6, 9 for 0 to 10 by 3).
last_step <- function(min, max, step) {
  min + floor((max - min) / step + 1e-9) * step
}

number_allowed <- function(min, max, integer, step = NULL) {
  what <- if (integer) "a whole number" else "a number"
  if (!is.null(step) && !is.na(step)) {
    sprintf("The value must be %s from %s to %s in steps of %s.", what, format(min),
            format(last_step(min, max, step)), format(step))
  } else if (!is.na(min) && !is.na(max)) {
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
# element is one of them, each once. Returns them in the order given.
choices_check_many <- function(choices) {
  function(x) {
    items <- if (is.list(x)) x else as.list(x)
    idx <- vapply(items, function(item) choice_index(choices, item), integer(1))
    if (anyNA(idx)) stop("Every value must be one of the choices.", call. = FALSE)
    if (anyDuplicated(idx)) stop("Each choice can be picked only once.", call. = FALSE)
    unname(choices[idx])
  }
}

# Where `x` is in `choices`, or NA. Plain numbers compare by value, as `%in%`
# does, so 5 is the choice 5L (and JSON's 20 the choice 20); anything else
# (strings, factors, dates, lists) must be identical().
choice_index <- function(choices, x) {
  x <- unname(x)
  plain <- function(v) is.numeric(v) && is.null(attr(v, "class"))
  for (i in seq_along(choices)) {
    ch <- unname(choices[[i]])
    if (identical(ch, x)) return(i)
    if (plain(ch) && plain(x) && length(ch) == length(x) && length(x) > 0 && isTRUE(all(ch == x))) return(i)
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

# A step, or none: NULL or NA in both functions.
check_step <- function(step) {
  if (is.null(step) || (length(step) == 1 && is.na(step) && !is.nan(step))) return(invisible())
  if (!is.numeric(step) || length(step) != 1 || is.na(step) || !is.finite(step) || step <= 0) {
    stop("`step` must be one positive number.", call. = FALSE)
  }
}

check_label <- function(label) {
  if (!is.null(label) && !(is.character(label) && length(label) == 1 && !is.na(label))) {
    stop("`label` must be one string or NULL.", call. = FALSE)
  }
}
