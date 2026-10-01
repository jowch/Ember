\name{edit_notebook}
\alias{edit_notebook}
\alias{set_code}
\alias{insert_cell}
\alias{delete_cell}
\alias{move_cell}
\alias{fold_cell}
\title{Stage edits to a notebook}
\description{
\code{edit_notebook()} applies a batch of edit ops to a notebook at once.
Edits are staged: they change the code, the graph and the file, but never
run anything. \code{set_code()}, \code{insert_cell()}, \code{delete_cell()},
\code{move_cell()} and \code{fold_cell()} build the ops; they are plain data until
passed to \code{edit_notebook()}.
}
\usage{
edit_notebook(nb, ...)

set_code(cell, code, expected = NULL)

insert_cell(index, code = "", kind = c("code", "markdown"), id = NULL)

delete_cell(cell)

move_cell(cell, index)

fold_cell(cell, folded = TRUE)
}
\arguments{
\item{nb}{An \code{ember_notebook} handle.}
\item{...}{One or more ops made by \code{set_code()}, \code{insert_cell()},
\code{delete_cell()}, \code{move_cell()}, \code{fold_cell()}, applied in order.
Indexes are display positions after the previous ops in the same call.}
\item{cell}{A cell id or 1-based display index.}
\item{code}{The cell's new code (a single string).}
\item{expected}{The code the caller believes the cell currently has, as a
check before applying (Endeavor's optimistic-concurrency check). \code{NULL}
skips the check.}
\item{index}{1-based display position: where to insert (\code{insert_cell()}) or
move to (\code{move_cell()}).}
\item{kind}{\code{"code"} or \code{"markdown"}.}
\item{id}{The new cell's id (a 36-character UUID), for a caller that names the
cell itself, as the browser does. \code{NULL} generates one.}
\item{folded}{\code{TRUE} to fold the cell's code away in a view, \code{FALSE} to
show it.}
}
\value{
\code{edit_notebook()} returns, invisibly, a list with \code{inserted} (ids of
inserted cells, in op order) and \code{seq} (the state's seq after the batch).
If any op
in the batch cannot apply (an unknown id, a mismatched \code{expected}, an
attempt to delete the setup cell, or code containing a line Ember reserves
as a cell or footer marker), the whole batch is refused and an
\code{ember_refused} condition is signalled; none of the ops take effect.

\code{set_code()}, \code{insert_cell()}, \code{delete_cell()}, \code{move_cell()} and
\code{fold_cell()} each return an \code{ember_op}, a plain list describing the
edit; they do nothing on their own.
}
\examples{
\dontrun{
nb <- open_notebook("growth.R")
edit_notebook(nb, set_code(2, "deg <- 3"))
edit_notebook(nb, insert_cell(3, "summary(fit)"), fold_cell(1))
}
}
