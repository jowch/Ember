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
To write notebooks:

\itemize{
  \item \link{start_server}: start Ember and open it in your browser
    (\code{srv <- start_server()}). Write and run notebooks there.
  \item \code{\link{run}()}: run a saved notebook from start to finish
    outside the browser, with the package versions it records.
  \item Inputs: a slider, text box or dropdown whose value is a variable
    comes from the \pkg{emberui} package (\code{library(emberui)}), which
    Ember installs like any other package. See
    \code{?emberui::input_slider}.
}

For scripts and for programs that host Ember:

\itemize{
  \item \link{packages}: a notebook's packages (status, the date move,
    cleaning up the cache).
  \item \link{notebooks}: open, run and inspect a notebook from R
    (\code{open_notebook}, \code{run_cells}, \code{notebook_snapshot}).
  \item \link{edit_notebook}: stage edits to a notebook's cells.
  \item \link{serve}: serve notebooks from your own R process.
  \item \link{read_cell}, \link{notebook_graph} and \link{graph_queries}:
    the dependency graph Ember builds from the code.
}
}
\author{
Jonathan Chen
}
\keyword{internal}
