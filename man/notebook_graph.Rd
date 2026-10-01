\name{notebook_graph}
\alias{notebook_graph}
\alias{graph_learn}
\title{Build and update the dependency graph}
\description{
\code{notebook_graph()} builds the whole-notebook dependency graph from the
cells' code, the setup cell, the installed packages' exports, and whatever
the worker has learned at run time. It is pure and deterministic: the same
inputs always give an identical graph. \code{graph_learn()} folds a new fact
reported by the worker (names it created, or formula columns it read) into
a graph, rebuilding only what that fact can change.
}
\usage{
notebook_graph(cells, setup = names(cells)[1], exports = list(),
  learned = NULL, previous = NULL, read_file = NULL)

graph_learn(graph, cell, definitions = NULL, references = NULL)
}
\arguments{
\item{cells}{Named character vector, cell id -> code, in display order.
Markdown cells are passed as empty strings (or left out); they take part
in the order and nothing else.}
\item{setup}{The setup cell's id. Defaults to the first cell. Every other
cell depends on it.}
\item{exports}{Named list, package name -> character vector of exported
names (as from \code{getNamespaceExports()}), for the packages that are
installed. A package not in the list contributes no edges.}
\item{learned}{\code{list(definitions = <id -> character>, references = <id ->
character>)} from the footer and from formula checks; \code{NULL} means none.
Ids not in \code{cells} are dropped.}
\item{previous}{An earlier \code{ember_graph} for the same notebook, or \code{NULL}.
Analyses are reused for cells whose code is identical and whose sourced
files still read the same; everything else is recomputed. Passing
\code{previous} never changes the result, only the work done.}
\item{read_file}{Reader for \code{source()} paths; see \link{read_cell}.}
\item{graph}{An \code{ember_graph}, as returned by \code{notebook_graph()} or
\code{graph_learn()}.}
\item{cell}{The id of the cell the worker ran.}
\item{definitions}{Character vector of names the cell defined at run time
(replaces, not adds to, any previously learned definitions for this cell),
or \code{NULL} to leave them unchanged.}
\item{references}{Character vector of names the cell's formulas or dynamic
code read at run time, or \code{NULL} to leave them unchanged.}
}
\value{
Both return an \code{ember_graph}: a list with \code{ids}, \code{setup}, \code{analyses},
\code{learned}, \code{exports}, \code{cells} (per-cell resolved view), \code{edges} (a data
frame of \code{from}, \code{to}, \code{name}, \code{via}), \code{upstream}, \code{downstream}, \code{order}
(every id in run order), \code{errors} (a list of \code{ember_graph_error}), and
\code{reread} (ids whose analysis was actually recomputed in this build).
}
\details{
\code{graph_learn()} rebuilds with \code{previous = graph}, so only the affected
cell's analysis changes and the rest of the graph is reused. Learned
definitions take part in the multiple-definitions rule and in edges
exactly like statically read ones; learned references go through the same
edge resolution as static references.
}
