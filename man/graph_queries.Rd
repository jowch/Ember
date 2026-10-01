\name{graph_queries}
\alias{graph_queries}
\alias{upstream}
\alias{downstream}
\alias{run_order}
\alias{affected}
\alias{cell_errors}
\alias{blocked_cells}
\alias{cell_summary}
\alias{changed_cells}
\alias{print.ember_graph}
\alias{format.ember_graph_error}
\title{Read-only queries over a notebook graph}
\description{
Queries over an \code{ember_graph} (see \link{notebook_graph}): neighbours, run
order, per-cell summaries, which cells an edit or a worker report affects,
and what changed between two graph builds.
}
\usage{
upstream(graph, id, transitive = FALSE)

downstream(graph, id, transitive = FALSE)

run_order(graph, ids = NULL)

affected(old, new, changed)

cell_errors(graph, id)

blocked_cells(graph)

cell_summary(graph, id)

changed_cells(old, new)

\method{print}{ember_graph}(x, ...)

\method{format}{ember_graph_error}(x, ...)
}
\arguments{
\item{graph}{An \code{ember_graph}.}
\item{id}{A cell id.}
\item{transitive}{\code{FALSE} (the default) returns direct neighbours only;
\code{TRUE} returns every ancestor (\code{upstream()}) or descendant
(\code{downstream()}), in run order.}
\item{ids}{Character vector of cell ids, or \code{NULL} for the whole notebook's
run order.}
\item{old, new}{Two \code{ember_graph} values built for the same notebook, \code{old}
before an edit and \code{new} after.}
\item{changed}{Character vector of ids that were just edited.}
\item{x}{An \code{ember_graph}, for \code{print()}, or an \code{ember_graph_error}, for
\code{format()}.}
\item{...}{Unused; present for consistency with the generics.}
}
\value{
\code{upstream()}, \code{downstream()} return a character vector of cell ids.

\code{run_order()} returns \code{graph$order} filtered to \code{ids} (or all of it when
\code{ids} is \code{NULL}), in run order.

\code{affected()} returns, in run order, the cells to rerun or mark stale after
editing \code{changed}: \code{changed} itself, plus everything downstream of it in
\code{new}, plus anything downstream of it in \code{old} that still exists in \code{new}.

\code{cell_errors()} returns a list of \code{ember_graph_error} reported on \code{id}.

\code{blocked_cells()} returns a character vector of ids that can't run (named
in any graph error).

\code{cell_summary()} returns a list for one cell:
\code{list(definitions, learned, references, packages, attaches, upstream,
downstream, errors, notes, formulas)}. \code{definitions} is static definitions
only (learned ones subtracted out, since \code{learned} reports them
separately).

\code{changed_cells()} returns a character vector of ids whose resolved view
(definitions, references, packages, upstream set, or errors) differs
between \code{old} and \code{new}, including ids added or deleted; present ids come
first in \code{new}'s run order, followed by deleted ids in \code{old}'s run order.

\code{print.ember_graph()} prints one line per cell (id, definitions, upstream
ids) followed by its errors, and returns \code{x} invisibly.

\code{format.ember_graph_error()} returns a one-line string, \code{"[<kind>]
<message>"}.
}
\examples{
g <- notebook_graph(
  cells = c(a = "x <- 1", b = "y <- x + 1"),
  setup = "a"
)
upstream(g, "b")
downstream(g, "a", transitive = TRUE)
run_order(g)
cell_summary(g, "b")$references
blocked_cells(g)
}
