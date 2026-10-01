\name{read_cell}
\alias{read_cell}
\title{Read one cell's code, without a notebook}
\description{
Statically reads one cell's code: what it defines, what it reads, which
packages it attaches or uses, any global settings it changes, and the
formulas it builds. Pure: it never runs the code. This is the same reader
\code{notebook_graph()} uses for every cell.
}
\usage{
read_cell(code, read_file = NULL)
}
\arguments{
\item{code}{A single string of R code.}
\item{read_file}{Function of one path argument, used to follow a literal
\code{source()} call: it should return the sourced file's text, or \code{NULL} if
the file can't be read. \code{NULL} means \code{source()} calls are not followed
(their target is recorded as a note instead).}
}
\value{
An \code{ember_cell_analysis}: a list with \code{code}, \code{parse_error} (\code{NULL}
unless the code fails to parse), and data frames \code{definitions},
\code{references}, \code{packages}, \code{settings}, \code{sourced}, \code{notes}, plus a list of
\code{formula_site} in \code{formulas}. When \code{parse_error} is set, every other
field is empty.
}
\examples{
a <- read_cell("fit <- lm(y ~ poly(x, deg), data = df)")
a$definitions$name
a$references$name
a$formulas[[1]]$columns
}
