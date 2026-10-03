\name{packages}
\alias{packages}
\alias{package_status}
\alias{add_extra_package}
\alias{remove_extra_package}
\alias{preview_date}
\alias{set_date}
\alias{run}
\alias{clean}
\alias{ember_repos}
\alias{cache_dir}
\title{A notebook's packages: status, the date move and running outside the engine}
\description{
A notebook detects the packages its code uses, resolves and locks their
versions at its snapshot date, and installs a library with renv. Nothing
about packages appears in the ordinary calls (\code{edit_notebook()},
\code{run_cells()}): the lock fills in as soon as an edit is applied, and the
install starts on the first run. These functions are for reading that
status, changing the package set directly, moving the snapshot date, and
running or cleaning up outside a session.
}
\usage{
package_status(nb)

add_extra_package(name)

remove_extra_package(name)

preview_date(nb, date = Sys.Date(), wait = TRUE, apply = FALSE, timeout = 60)

set_date(nb, date)

run(path, repos = ember_repos(), cache = cache_dir(), echo = TRUE)

clean(max_age = 60, cache = TRUE, dry_run = FALSE, dir = cache_dir(),
      now = Sys.time())

ember_repos(cran = "https://packagemanager.posit.co/cran",
            bioc = "https://packagemanager.posit.co/bioconductor")

cache_dir()
}
\arguments{
\item{nb}{An \code{ember_notebook} handle.}
\item{name}{A package name, for \code{add_extra_package()}/\code{remove_extra_package()}.}
\item{date}{A date (anything \code{as.Date()} accepts). \code{preview_date(nb,
Sys.Date())} is "update all".}
\item{wait}{\code{TRUE} blocks until the preview is ready (or failed) or
\code{timeout} passes, servicing pending work meanwhile, as \code{run_cells()}'s
\code{wait} does. Only for the console and tests; code running inside an event
callback must use \code{wait = FALSE} and \code{on_notebook_event()} instead.}
\item{apply}{\code{TRUE} applies the preview itself once it is ready, the
same change \code{set_date()} would make, unless doing so would restart a
package the worker has already loaded; the Packages tab's Update button
uses this. \code{FALSE} (the default) only ever previews: applying is
always a separate, explicit \code{set_date()} call.}
\item{timeout}{Seconds to wait before giving up.}
\item{path}{Path to a notebook's \code{.R} file, for \code{run()}.}
\item{repos}{An \code{ember_repos()} value: where indexes and packages come
from. Passed to \code{open_notebook()}/\code{new_notebook()} and to \code{run()}.}
\item{cache}{A \code{cache_dir()}-shaped path: where libraries, indexes and
renv's cache live. Passed to \code{open_notebook()}/\code{new_notebook()}, \code{run()}
and \code{clean()}.}
\item{echo}{\code{TRUE} to stream the install's and the file's own output to
the console, for \code{run()}.}
\item{max_age}{Days since last use after which an unused library or a
cached index is deleted by \code{clean()}.}
\item{dry_run}{\code{TRUE} lists what \code{clean()} would delete without deleting
anything.}
\item{dir}{The cache directory \code{clean()} operates on.}
\item{now}{The time \code{clean()} measures ages against; a parameter mainly
for tests.}
\item{cran, bioc}{Base repository URLs (no date), for \code{ember_repos()}. The
defaults are the public Posit Package Manager; an institution's own
Package Manager, or a \code{file://} folder laid out the same way, can
replace them.}
}
\value{
\code{package_status()} returns a plain list, the same value as
\code{notebook_snapshot(nb)$packages}: \code{list(snapshot, r_version,
bioc_version, library = list(status, path, progress, message, log, failures),
packages = data.frame(name, version, source, direct, status, message),
problems, proposal, plan)}. Per package, \code{status} is one of
\code{"installed"}, \code{"installing"}, \code{"missing"}, \code{"failed"} (named by
\code{library$failures}, or a direct package that needs one of them),
\code{"not_installed"} (every other package in a library that failed: its
staging folder is never renamed into place, so nothing in that install
actually landed), \code{"not_found"}. \code{plan} is \code{NULL} or
\code{list(install = <n packages>, restart = <names>)}, what running would do
(a \code{"not_installed"} package counts toward it exactly as \code{"missing"}
does).

\code{library$log} is the installer's last 200 lines from the most recent
failed install, whatever \code{status} is now: it isn't cleared by a later
successful install, so it can be stale (describing an earlier failure)
once \code{status} has moved past \code{"failed"}. \code{character()} before any
install has ever failed. \code{library$failures} is a data frame
\code{package}, \code{kind} (\code{"compile"}, \code{"configure"}, \code{"dependency"},
\code{"download"}, \code{"other"}), \code{detail} (the missing dependency's name for
\code{"dependency"}, the first \code{ERROR} line for \code{"other"}, \code{NA} otherwise),
\code{needed_by} (a list column: the direct packages whose dependency closure
reaches this one). Empty (0 rows) unless \code{status} is \code{"failed"}.

\code{add_extra_package()}/\code{remove_extra_package()} return an \code{ember_op}, a
plain list, for use with \code{edit_notebook()}; they do nothing on their own.
\code{remove_extra_package()} is refused through \code{edit_notebook()} when the
name is also named directly in code (removing it from the header would do
nothing): edit the code instead.

\code{preview_date()} returns \code{list(date, status, changes, problems, restart)},
where \code{status} is \code{"fetching"}, \code{"ready"} or \code{"failed"}, and \code{changes} is
\code{NULL} or a data frame \code{name}, \code{from}, \code{to}, \code{change} (\code{"added"},
\code{"removed"}, \code{"upgraded"}, \code{"downgraded"}, \code{"source"}). \code{restart} is
\code{character()} unless \code{apply = TRUE} left the proposal waiting rather than
applying it on its own: then it names the loaded packages applying would
restart.

\code{set_date()} returns, invisibly, the applied \code{changes} (the same shape
as \code{preview_date()}'s). It is refused (an \code{ember_refused} condition) unless
\code{preview_date()} for that date is ready and current: the caller must have
seen what would change.

\code{run()} returns, invisibly, the file's exit status.

\code{clean()} returns, invisibly, a data frame \code{path}, \code{kind} (\code{"library"},
\code{"staging"}, \code{"cache"}, \code{"index"}), \code{bytes}, \code{last_used} of what was (or
with \code{dry_run}, would be) deleted.

\code{ember_repos()} returns an \code{ember_repos} value. \code{cache_dir()} returns a
path: the \code{ember.cache_dir} option if set, otherwise
\code{tools::R_user_dir("ember", "cache")}.
}
\details{
\code{set_date()} changes the header's \code{snapshot} and the lock in one step and
saves the file; the library installs once execution is allowed, and if a
package the worker has already loaded changed version, the worker
restarts once the new library is ready, leaving every cell not run.
\code{set_date()} and an \code{apply = TRUE} preview that needs no restart both
apply the proposal the same way internally: neither is allowed to apply
anything but the current, ready proposal.

A page connected to the notebook sees an \code{apply = TRUE} preview as
\code{ember$packages$update}:
\code{list(date, status, restart, changes, message)}, present only while such
a preview exists. A plain \code{preview_date()} call (no \code{apply}) is never
shown there: it is this function's own, R-side preview, not the Packages
tab's.

\code{run()} does not resolve: the file's lock is the authority. If the code
names a package the lock lacks, \code{run()} says so and runs anyway (R
reports the missing package), since resolving would change the file.
Building the library blocks the caller, the same installer and layout a
session uses.

\code{clean()} never deletes a library an open session in this process is using,
and never touches a user's own renv projects: Ember keeps its own renv
cache under \code{cache_dir()}.
}
\examples{
\dontrun{
nb <- open_notebook("growth.R")
edit_notebook(nb, insert_cell(2, "library(dplyr)\n curves |> filter(od > 0.1)"))
package_status(nb)$plan
run_cells(nb, 2, wait = TRUE)
package_status(nb)$library$status

p <- preview_date(nb, Sys.Date())
p$changes
set_date(nb, Sys.Date())

ember::run("growth.R")
ember::clean(dry_run = TRUE)
}
}
