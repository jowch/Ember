\name{ember-package}
\alias{ember-package}
\alias{ember}
\docType{package}
\title{Reactive Notebooks for R}
\description{
Ember is a reactive notebook engine for R in the style of Pluto.jl. Cells
are read statically into a dependency graph, so editing a cell reruns (or
marks stale) the cells that depend on it. A notebook is a plain \code{.R}
file; a background worker process runs the code while the main session
stays responsive.
}
\details{
The public surface is grouped onto a few pages:

\itemize{
  \item \link{notebooks}: open, run and inspect a notebook (\code{open_notebook},
    \code{run_cells}, \code{notebook_snapshot}, and the rest of the session API).
  \item \link{edit_notebook}: stage edits to a notebook's cells.
  \item \link{read_cell}: read one cell's code, without a notebook.
  \item \link{notebook_graph}: build and update the dependency graph for a
    whole notebook.
  \item \link{graph_queries}: read-only queries over a graph (upstream,
    downstream, run order, errors, summaries).
}
}
\author{
Jonathan Chen
}
\keyword{internal}
