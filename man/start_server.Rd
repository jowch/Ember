\name{start_server}
\alias{start_server}
\alias{print.ember_server_handle}
\title{Start Ember and open it in your browser}
\description{
Starts Ember in a background process and opens its start page (or the
notebook \code{path}) in your browser. The R console stays free while
notebooks run. Stop Ember with \code{srv$stop()}, or by quitting R.
}
\usage{
start_server(path = NULL, port = 0L, open = interactive(), timeout = 15,
             allowed_hosts = character())

\method{print}{ember_server_handle}(x, ...)
}
\arguments{
\item{path}{A notebook file to open, or \code{NULL} to open the start page,
where \strong{New notebook} makes a notebook. New notebooks default to the
folder this R session started in.}
\item{port}{Port on \code{127.0.0.1}. \code{0} tries \code{4321} and the next few
ports upward, then any free port, so a bookmark or an SSH tunnel
(\verb{ssh -L 4321:localhost:4321}) keeps working across restarts.}
\item{open}{Open the page in the browser once Ember is listening.}
\item{timeout}{Seconds to wait for Ember to start listening.}
\item{allowed_hosts}{Host names to accept besides \code{127.0.0.1} and
\code{localhost}, for a proxy such as Posit Workbench or JupyterHub
(\code{"workbench.example.org"}, or with a port,
\code{"ember.example.org:8443"}). Default: none.}
\item{x}{The value \code{start_server()} returns, for \code{print()}.}
\item{...}{Unused.}
}
\value{
\code{start_server()} prints the link to open, and returns, invisibly, a
handle with \code{url} (the link, including its key), \code{open(path)}
(opens another notebook and returns its link), \code{stop()} (stops Ember
and every notebook's R), \code{output} (Ember's recent output lines) and
\code{process} (the \pkg{processx} handle).
}
\details{
The link carries a key that changes each time Ember starts. A browser tab
opened with an old key asks for the current one, and Ember prints the link
again in this console.

The start page lists the notebooks open now and the ones you opened
recently, with \strong{New notebook} and \strong{Open a file}. Notebooks
save themselves as you edit. A notebook opened from a file starts in safe
preview, with nothing run until you click \strong{Run this notebook}.

To serve notebooks from your own R process instead, as a program that
hosts Ember does, see \code{\link{serve}()}.
}
\seealso{
\code{\link{run}()} runs a saved notebook outside the browser.
}
\examples{
\dontrun{
srv <- start_server()
srv <- start_server("growth.R")
srv$open("other.R")
srv$stop()
}
}
