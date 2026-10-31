\name{server}
\alias{server}
\alias{serve}
\alias{host_notebook}
\alias{stop_server}
\alias{print.ember_server}
\title{Serve notebooks from your own R process}
\description{
For a program that hosts Ember, such as Endeavor. At the console, use
\code{\link{start_server}()} instead. \code{serve()} hosts Pluto's frontend
over HTTP and one websocket per browser tab, backed by any number of
\code{ember_notebook}s. It blocks its R process; \code{start_server()} runs
it in a background process.
}
\usage{
serve(paths = character(), port = 0L, secret = random_secret(32),
      on_ready = NULL, launch_browser = FALSE, allowed_hosts = character())

host_notebook(server, nb, owned = FALSE, remember = FALSE)

stop_server(server)

\method{print}{ember_server}(x, ...)
}
\arguments{
\item{paths}{Notebook files to open in safe preview when \code{serve()} starts.}
\item{port}{Port on \code{127.0.0.1}; \code{0} tries the stable default, \code{4321},
and the next few ports upward before falling back to a free one at random,
so a browser bookmark, an SSH tunnel command (\verb{ssh -L 4321:localhost:4321})
or a reverse proxy's saved config keeps working across restarts.}
\item{secret}{The URL secret. Every page, static file request to
\verb{/edit}, and websocket connection needs it (as \code{?secret=} or the
cookie \verb{/edit} sets); files served directly from the frontend folder do
not.}
\item{on_ready}{\code{function(server)}, called once the port is listening, or
\code{NULL}. Its \code{server$port} is the port on 127.0.0.1 the server listens on
(the one \code{port = 0} picked), which a host reads to reach the server. A host opens notebooks with the R API here (or later, from its own
callbacks) and hands them to the server with \code{host_notebook()}.}
\item{launch_browser}{Open the first notebook's edit URL (or the server's
own URL if none was given) once the server is ready.}
\item{allowed_hosts}{\code{Host} names to accept besides loopback
(\code{127.0.0.1}, \code{localhost}, \code{[::1]}, any port), for a reverse proxy
that isn't loopback from this R process's point of view -- Posit Workbench,
JupyterHub's server proxy, a container's exposed port. Each entry can
include a port (\code{"ember.example.org:8443"}, accepted only on that port)
or be bare (\code{"ember.example.org"}, accepted on any port). A request's
\code{Origin}, when present, must still equal its \code{Host} exactly; listing a
host here never allows a \emph{different} origin to connect. Default: none.}
\item{server}{The \code{ember_server} value passed to \code{on_ready()}.}
\item{nb}{An \code{ember_notebook}, as returned by \code{open_notebook()}.}
\item{owned}{\code{TRUE} when the server itself opened \code{nb} and should close it
when the server stops or the page sends "shut down"; a host's own
notebooks are the host's to close, so its calls to \code{host_notebook()}
leave this \code{FALSE}.}
\item{remember}{Internal: \code{TRUE} adds the notebook's path to the start
page's recent notebooks. Only Ember's own pages set it (the start page,
\verb{/open}, the paths given to \code{serve()} or \code{start_server()}); a
host leaves it \code{FALSE}, so notebooks it drives never show up there as
ones the user opened.}
\item{x}{An \code{ember_server}, for \code{print()}.}
\item{...}{Unused; present for consistency with \code{print()} generics.}
}
\value{
\code{serve()} returns, invisibly, once \code{stop_server()} has been called from a
callback; it never returns on its own.

\code{host_notebook()} returns the notebook's edit URL (with the secret). If
the server already hosts that notebook, nothing changes and the same URL
is returned.

\code{stop_server()} returns \code{NULL}, invisibly.
}
\details{
\code{serve()} runs entirely on R's one thread: \pkg{httpuv} and the notebook
engine both use \pkg{later}, so nothing here blocks it. A browser tab's view
of a notebook is kept in sync by diffing the engine's current state against
what that tab was last sent, after every change and at the end of every
request; a page that changes nothing receives nothing.

A server's base URL (\code{/}) is its own start page: hosted and recently
opened notebooks, "New notebook" and "Open a file". New notebooks default
to the folder the server was started in. The recent list is a single file
per user under \code{tools::R_user_dir("ember", "data")}, shared by every
Ember server that user runs, whatever the port.

\code{start_server()} is for interactive use: running \pkg{httpuv} in the current
R session would freeze it whenever that session is busy running cells, so
the server runs in a child process instead, and the secret reaches it
through an environment variable rather than a command-line argument other
users on the machine could read.
}
\examples{
\dontrun{
# A host, blocking its own process.
serve(port = 0L, secret = Sys.getenv("ENDEAVOR_EMBER_SECRET"),
      on_ready = function(server) {
        nb <- open_notebook("growth.R")
        url <- host_notebook(server, nb)
        message("edit at: ", url)
      })
}
}
