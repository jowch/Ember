\name{inputs}
\alias{inputs}
\alias{input_slider}
\alias{input_number}
\alias{input_checkbox}
\alias{input_text}
\alias{input_select}
\alias{input_radio}
\alias{input_list}
\title{Interactive inputs}
\description{
Each function returns a plain value: a number, \code{TRUE}/\code{FALSE}, a
string, an element of \code{choices}, or for \code{input_list()} a named
list of its inputs' values. In an Ember notebook, an input
assigned to a name at the top of a cell (\code{n <- input_slider(1, 10)}) is
shown as a widget, and moving it sets \code{n} and reruns the cells that read
\code{n}. Anywhere else (\code{Rscript}, the R console, knitr), and for any
other call, the function checks its arguments and returns its default.
}
\usage{
input_slider(min, max, value = min, step = NULL, label = NULL)
input_number(value = 0, min = NA, max = NA, step = NA, label = NULL)
input_checkbox(value = FALSE, label = NULL)
input_text(value = "", label = NULL)
input_select(choices, selected = choices[[1]], multiple = FALSE, label = NULL)
input_radio(choices, selected = choices[[1]], label = NULL)
input_list(...)
}
\arguments{
\item{min, max}{The range of the input. For \code{input_number()}, \code{NA}
  means no limit.}
\item{value}{The default value. A number keeps its type:
  \code{input_slider(1L, 10L)} returns an integer.}
\item{step}{The step between the widget's values, or \code{NULL} or
  \code{NA} for none. It shapes the widget only: a value between steps is
  allowed.}
\item{label}{The text shown with the widget. By default, the name the input
  is assigned to.}
\item{choices}{A vector or list. The value is an element itself, not its
  position. Names, if present, are what the widget shows. Numbers match
  by value, as with \code{\%in\%}: \code{selected = 5} picks the choice
  \code{5L}.}
\item{selected}{The default choice: an element of \code{choices}, or with
  \code{multiple = TRUE}, a vector (or list) of them.}
\item{multiple}{Whether several choices can be picked.}
\item{...}{For \code{input_list()}: named input calls, such as
  \code{n = input_slider(1, 10)}. Each must be an input call itself.}
}
\value{
The input's value. Outside Ember, the default.
}
\details{
Inside Ember, the input is bound to a name only when the call is the whole
right-hand side of a top-level assignment and nothing else in the cell
reads or redefines that name. Only the input on the cell's last line is
shown as a widget, as the cell's output; any other input shows as a line
below the cell with its value, saying how to fix it. Moving an input
doesn't rerun its own cell.

To move several inputs from one cell, combine them with \code{input_list()}:
\code{p <- input_list(n = input_slider(1, 10), method = input_select(c("a", "b")))}
shows both widgets together, and other cells read \code{p$n} and
\code{p$method}. Moving either sets \code{p}.

Input values aren't saved with the notebook: it opens with every input at
its default, the value \code{Rscript} uses. To keep a value, change the
default in the code.
}
\examples{
n <- input_slider(10, 500, value = 100, step = 10)
method <- input_select(c(Pearson = "pearson", Spearman = "spearman"))
show <- input_checkbox(TRUE, label = "Show points")
title <- input_text("Results")
p <- input_list(n = input_slider(1, 10), method = input_select(c("a", "b")))
n
method
p$n
}
