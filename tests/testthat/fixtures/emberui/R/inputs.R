# The hook protocol as inst/worker.R describes it: `.state$hook`, set by
# the worker when the package loads, is called with the input's spec and
# the function's own call, and returns the value to use.

.state <- new.env(parent = emptyenv())

report <- function(spec, call) {
  hook <- .state$hook
  if (is.function(hook)) hook(spec, call) else spec$value
}

input_slider <- function(min, max, value = min, step = NULL, label = NULL) {
  call <- sys.call()
  check <- function(x) {
    if (!is.numeric(x) || length(x) != 1 || is.na(x) || x < min || x > max) {
      stop(sprintf("The value must be a number from %s to %s.", min, max), call. = FALSE)
    }
    if (is.integer(value)) as.integer(round(x)) else as.numeric(x)
  }
  check(value)
  report(list(type = "slider", value = value, min = min, max = max, step = step,
              label = label, check = check), call)
}

input_select <- function(choices, selected = choices[[1]], label = NULL) {
  call <- sys.call()
  check <- function(x) {
    for (ch in as.list(choices)) if (identical(ch, x)) return(x)
    stop("The value must be one of the choices.", call. = FALSE)
  }
  check(selected)
  report(list(type = "select", value = selected, choices = choices,
              label = label, check = check), call)
}
