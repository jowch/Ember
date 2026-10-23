\name{notebooks}
\alias{notebooks}
\alias{open_notebook}
\alias{new_notebook}
\alias{close_notebook}
\alias{move_notebook}
\alias{set_cell_change_mode}
\alias{set_input}
\alias{allow_execution}
\alias{run_cells}
\alias{interrupt_notebook}
\alias{answer_input}
\alias{restart_notebook}
\alias{notebook_snapshot}
\alias{dependency_graph}
\alias{notebook_state}
\alias{render_png}
\alias{on_notebook_event}
\alias{wait_for}
\alias{print.ember_notebook}
\title{Open, run and inspect a notebook}
\description{
The session API: open or create a notebook file, stage runs, and read back
its state. A notebook handle (\code{ember_notebook}) is an opaque
environment owned by a background shell; callers never touch its fields
directly, they read it through \code{notebook_snapshot()},
\code{dependency_graph()} and \code{notebook_state()}.
}
\usage{
open_notebook(path, repos = ember_repos(), cache = cache_dir())

new_notebook(path, repos = ember_repos(), cache = cache_dir())

close_notebook(nb)

move_notebook(nb, path)

set_cell_change_mode(nb, on_cell_change = c("autorun", "lazy"))

allow_execution(nb)

run_cells(nb, ids = NULL, wait = FALSE, timeout = 60)

set_input(nb, name, value, wait = FALSE, timeout = 60)

interrupt_notebook(nb)

answer_input(nb, text, cell = NULL, id = NULL)

restart_notebook(nb)

notebook_snapshot(nb)

dependency_graph(nb)

notebook_state(nb)

render_png(nb, cell, width = NULL, height = NULL, res = 96, timeout = 5)

on_notebook_event(nb, fn)

wait_for(nb, predicate = is_idle, timeout = 10)

\method{print}{ember_notebook}(x, ...)
}
\arguments{
\item{path}{Path to the notebook's \code{.R} file. For \code{open_notebook()}, an
existing file (one without Ember's header opens too). For \code{new_notebook()},
a path that does not yet exist. For \code{move_notebook()}, the new path.}
\item{repos}{\code{ember_repos()}: where indexes and packages come from. See
\link{packages}.}
\item{cache}{\code{cache_dir()}: where libraries, indexes and renv's cache live.
See \link{packages}.}
\item{nb}{An \code{ember_notebook} handle, as returned by \code{open_notebook()} or
\code{new_notebook()}.}
\item{on_cell_change}{\code{"autorun"} (edit-then-run reruns dependents
automatically) or \code{"lazy"} (dependents are marked stale but don't rerun
until asked). Stored in the file's header.}
\item{ids}{Cell ids or 1-based display indexes to run, or \code{NULL} to run
every code cell.}
\item{wait}{\code{TRUE} blocks until the run queue is empty or \code{timeout}
passes, servicing pending work meanwhile. Only for the console and tests;
code already running inside an event callback must use \code{wait = FALSE}
and \code{on_notebook_event()} instead.}
\item{timeout}{Seconds to wait before giving up (\code{run_cells()},
\code{render_png()}) or before \code{wait_for()} returns \code{FALSE}.}
\item{name}{For \code{set_input()}, the variable an input is bound to
(\code{n} for \code{n <- input_slider(10, 500)}).}
\item{value}{For \code{set_input()}, the input's new value, as the input
would return it.}
\item{cell}{A cell id or 1-based display index. For \code{answer_input()}, the
cell the answer is for, or \code{NULL} for whichever cell runs.}
\item{text}{For \code{answer_input()}, the answer to the running cell's
prompt, one string, as typed at the prompt.}
\item{id}{For \code{answer_input()}, the prompt's \code{id} from the snapshot,
or \code{NULL} for whichever question waits. Given, an answer to a question
already answered (and asked again, as \code{menu()} does after a bad
answer) is an error.}
\item{width, height}{Requested pixel size for \code{render_png()}. \code{NULL} for
both returns the output's stored image unchanged.}
\item{res}{Pixel density (dots per inch) for \code{render_png()}'s re-render,
e.g. \code{96 * devicePixelRatio}. Ignored when \code{width} and \code{height} are
both \code{NULL}.}
\item{fn}{Function called as \code{fn(note)} for every notification; see Details.}
\item{predicate}{Function of a snapshot (as returned by \code{notebook_snapshot()})
used by \code{wait_for()}; it returns \code{TRUE} once the wait is satisfied.
Defaults to "nothing queued or running".}
\item{x}{An \code{ember_notebook}, for \code{print()}.}
\item{...}{Unused; present for consistency with \code{print()} generics.}
}
\value{
\code{open_notebook()} and \code{new_notebook()} return an \code{ember_notebook} handle.

\code{close_notebook()} returns \code{TRUE} if the notebook was still in safe
preview (no worker running).

\code{move_notebook()} returns the new path. A running R process's working
directory follows the file, unless the notebook changed it.

\code{allow_execution()} returns \code{TRUE} if execution was already allowed.

\code{run_cells()} returns, invisibly, \code{list(accepted, queued, skipped,
finished, timed_out)}.

\code{set_input()} returns, invisibly, \code{list(accepted, cell, value,
cells, timed_out)}; \code{value} (as assigned) and \code{cells} (the
readers rerun or marked stale) are filled in only with \code{wait = TRUE},
which also makes a value the input refuses an error. The input's own cell
doesn't rerun, and the value isn't saved. A change Ember can't make (no
such input, or its cell not run since its last edit) is an error.

\code{notebook_snapshot()} returns a plain list describing the notebook's
current, safe-to-keep state: \code{list(id, path, seq, read_only, allowed,
process, restart_offered, worker_message, worker_memory, problems, order,
cells, packages)}, where \code{process} is one of \code{"preview"},
\code{"starting"}, \code{"ready"}, \code{"busy"}, \code{"stopped"},
each cell's \code{inputs} lists the input calls its last run made (name,
whether bound, spec, default and current value), each cell's
\code{variables} is a list of \code{list(name, type)} for the
globals it owns (no \code{value} or \code{kind}: a value the notebook
never printed stays out of this API), \code{worker_memory} is the worker's
last-reported memory in bytes (\code{NULL} until sampled for the current
worker), and \code{packages} is \code{package_status(nb)}'s value (see
\link{packages}).

\code{dependency_graph()} returns the notebook's current \code{ember_graph} (see
\link{notebook_graph}), reflecting staged edits.

\code{notebook_state()} returns the session's immutable internal state, for
advanced callers (the step-4 UI).

\code{render_png()} returns \code{list(png = <raw> | NULL, mime = <mime type>)}.

\code{on_notebook_event()} returns a function that unsubscribes when called.

\code{wait_for()} returns \code{TRUE} if the predicate held, \code{FALSE} on timeout.

\code{answer_input()} returns \code{TRUE}, invisibly. A cell that asks a
question (\code{readline()}, \code{menu()}, \code{askYesNo()},
\code{select.list()}, so a package's "Do you want to download...?") waits for
an answer, as in an R console: the snapshot shows it as the running cell's
\code{prompt}, \code{list(id, text, choices)}, \code{choices} being
\code{menu()}'s (answered by number or by the choice itself). With no prompt
waiting, or another cell's, the answer is an error. Interrupting the cell
stops the wait.

\code{set_cell_change_mode()}, \code{interrupt_notebook()} return \code{NULL},
invisibly. \code{restart_notebook()} returns the dispatch reply, invisibly.
}
\details{
Opening a notebook (\code{open_notebook()}) only parses the file and builds its
graph; no worker starts and nothing runs until \code{run_cells()} or
\code{allow_execution()} is called. \code{run_cells()} runs the requested cells and
any unrun, stale or failed ancestors first, in dependency order, one at a
time. A cell with a graph error of its own, or a text cell passed by id,
is returned in \code{skipped} rather than queued; a dependent of a failed or
graph-broken cell still runs, and fails on its own if it needs what that
cell would have provided.

The worker always starts from the notebook's own package library: its lock
is resolved and installed as needed (see \link{packages}), so there is no
separate \code{library} argument to hand it a different one.

\code{on_notebook_event()}'s \code{note} is \code{list(kind, seq, ...)} with \code{kind} one
of \code{"notebook_opened"}, \code{"cell_state"}, \code{"topology_changed"},
\code{"file_saved"}, \code{"execution_done"}, \code{"notebook_shut_down"}.
}
\examples{
\dontrun{
nb <- open_notebook("growth.R")
nb
run_cells(nb, 4, wait = TRUE)
snap <- notebook_snapshot(nb)
snap$cells[[4]]$output$text
interrupt_notebook(nb)
restart_notebook(nb)
close_notebook(nb)
}
}
