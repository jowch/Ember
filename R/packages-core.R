# Packages inside the session core.
#
# The lock, the resolution and the install status are fields of the
# notebook's `ember_state`. `step()` (step.R) calls `schedule_packages()`
# after `reduce()` and before `schedule()`, the same way `schedule()` moves
# the worker forward: no event handler resolves, fetches or installs
# itself. Whichever event changes what the notebook wants (an edit, a
# sourced file, a learned definition, a date move, an index arriving, an
# install finishing), the same function decides what happens next.
#
# Index fetches, library checks and installs are effects the shell carries
# out in subprocesses; their progress and results come back as events.
# Everything here is pure.

# ---- The record --------------------------------------------------------------

#' `state$packages`: what the session knows about the notebook's packages
#' beyond the lock and header (which stay in `state$file`, so the derived
#' save writes them with no extra code).
#'
#' * `resolved_for`: sorted character, the `wanted_packages()` the current
#'   lock answers. History, like a result's `stale`: it cannot be derived,
#'   because the lock alone doesn't say which of its entries were roots.
#'   Set at open to `wanted` when every wanted name is in the lock (an
#'   Ember-written file: nothing to do, no network, no write), else to
#'   `character()` so the first `schedule_packages()` resolves.
#' * `indexes`: named list, repo key -> `ember_index_slot`.
#' * `problems`: data frame (`empty_package_problems()`), from the last
#'   resolution plus install failures. Replaced, never appended, by each
#'   resolution, so a fixed typo clears its row.
#' * `target`: `ember_library_slot` for the current lock's library.
#' * `active`: `ember_library_slot`, the last library seen ready: the one
#'   the worker runs with. Equal to `target` once `target` is ready and the
#'   switch is made (see `switch_library()`). Starts as the empty library
#'   (status `"ready"`, nothing installed): before a worker has ever run,
#'   that is exactly what it has loaded, and it keeps the "`active$status`
#'   is always `"ready"`" invariant true from the moment the state exists.
#' * `install`: `NULL` or `list(token, key)`: the one install job this
#'   session has running. At most one at a time, so two renv processes never
#'   build libraries for the same notebook at once.
#' * `proposal`: `NULL` or `ember_proposal` (a date move being previewed,
#'   or a pinned notebook moving to the Bioconductor release for the
#'   running R).
#' * `bioc_releases`: `ember_releases_slot`, Bioconductor's release list
#'   as this session knows it.
#' * `bioc_move_tried`: `TRUE` once this session has proposed moving the
#'   pin to the running R's release (`propose_bioc_move()`), so a move that
#'   can't be made isn't proposed again on every event.
#' * `next_token`: integer, install job tokens.
#'
#' Invariants (added to `check_state()`):
#' * `target$key == library_for(state$file$lock, r, cache)$key`: `target`
#'   is reset by every change to the lock (`set_lock()` is the only writer
#'   of `state$file$lock` after open).
#' * `active$status == "ready"`.
#' * `install` is not `NULL` iff some slot with `install$key` has status
#'   `"installing"`, or the target changed while it ran (then the job
#'   finishes, its result is ignored, and the next install starts).
#' * `!allowed` implies `install` is `NULL`: nothing installs in safe
#'   preview (design.md, Decisions).
new_packages_state <- function(lock, wanted, r, cache, header = NULL, releases = new_releases_slot()) {
  empty <- empty_library(r, cache)
  info <- library_for(lock, r, cache)
  target <- if (identical(info$key, empty$key)) {
    new_library_slot(info$key, info$path, status = "ready",
                     installed = character(), exports = list())
  } else {
    new_library_slot(info$key, info$path)
  }
  active <- new_library_slot(empty$key, empty$path, status = "ready",
                             installed = character(), exports = list())
  locked_names <- if (is.null(lock$entries) || nrow(lock$entries) == 0) character() else lock$entries$name
  resolved_for <- if (all(wanted %in% locked_names)) wanted else character()
  # A pin built for another R is said at open, in safe preview, before
  # running the notebook moves it (design.md, "R itself"); resolution
  # doesn't run at open for a file Ember wrote, so nothing else would. With
  # the release list still to fetch, `reduce_bioc_releases_fetched()` says it.
  problems <- if (is.null(header)) empty_package_problems() else bioc_problems(header, r, releases$table)
  structure(list(
    resolved_for = resolved_for,
    indexes = list(),
    problems = problems,
    target = target,
    active = active,
    install = NULL,
    proposal = NULL,
    bioc_releases = releases,
    bioc_move_tried = FALSE,
    next_token = 1L,
    # Seeded with `wanted` itself (not `NULL`), computed by `new_state()`
    # from the same graph and header passed in here: an uninitialised `NULL`
    # would make the first `schedule_packages()` call after open look like a
    # state change even for an event `reduce()` refuses outright (the
    # NULL -> character() transition bumps `seq` and breaks the
    # `identical(new, old)` no-op checks step-2's tests rely on).
    wanted_cache = wanted
  ), class = "ember_packages_state")
}

#' An index the session has asked for.
#' `status`: `"fetching"`, `"ready"` (`index` set) or `"failed"`
#' (`message`; `wanted` records the wanted set at failure, and the fetch is
#' retried only once `wanted` differs or `ev_run` asks: no retry loop when
#' offline).
new_index_slot <- function(status, index = NULL, message = NULL, wanted = NULL) {
  structure(list(status = status, index = index, message = message, wanted = wanted),
            class = "ember_index_slot")
}

#' Bioconductor's release list as the session knows it.
#' `status`: `"unknown"` (not fetched), `"fetching"`, `"ready"` (`table`,
#' from `parse_bioc_config()`, as it was on the day `fetched`) or
#' `"failed"` (`message`; `table` empty, so only a pinned notebook still
#' resolves Bioconductor packages). `asked`: the latest snapshot date a
#' fetch was asked to cover.
#'
#' A list fetched on day F speaks only for snapshot dates up to F: a
#' release out by a later date may be missing from it (`releases_at()`).
#' So it is fetched when the session first meets Bioconductor, again when a
#' later date needs it (`releases_unsettled()`), and after a failure only
#' when asked to run (`reduce_run()`). `new_state()` starts it `"ready"`
#' from `options$bioc_releases` when given (tests; it then covers every
#' date), and `"failed"` when the lookup is off (`ember_repos(bioc_config
#' = NA)`).
new_releases_slot <- function(status = "unknown", table = empty_bioc_releases(), message = NULL,
                              fetched = as.Date(NA), asked = as.Date(NA)) {
  structure(list(status = status, table = table, message = message, fetched = fetched, asked = asked),
            class = "ember_releases_slot")
}

#' A library as the session sees it. The folder is the shell's; the core
#' knows only this.
#'
#' * `key`, `path`: from `library_for()`.
#' * `status`: `"unknown"` (not looked at), `"checking"`, `"missing"`
#'   (looked at: no complete library there), `"installing"`, `"ready"`,
#'   `"failed"`.
#' * `installed`: named character, package -> version, from the library's
#'   manifest; empty unless `"ready"`.
#' * `exports`: named list, package -> exported names, from the manifest:
#'   computed once, by the installer, from each package's NAMESPACE and
#'   lazy-load index (no package is loaded in the server).
#' * `progress`: `NULL` or `list(done, total, current)` while installing.
#' * `message`, `log`: why it failed, and the installer's last lines.
#'
#' Readiness is one fact on disk: the manifest exists. The installer writes
#' it last, into a staging folder that is then renamed into place (library.R).
new_library_slot <- function(key, path, status = "unknown", installed = character(),
                             exports = list(), progress = NULL, message = NULL,
                             log = character(), failures = empty_install_failures()) {
  structure(list(key = key, path = path, status = status, installed = installed,
                 exports = exports, progress = progress, message = message, log = log,
                 failures = failures),
            class = "ember_library_slot")
}

#' Empty, correctly typed `install_failures()` result: no package, no row.
empty_install_failures <- function() {
  data.frame(package = character(), kind = character(), detail = character(),
            stringsAsFactors = FALSE)
}

#' Why an install failed, from the installer's output: R's own "ERROR:"
#' lines name each package that didn't build, and renv's last "Error" line
#' lists every package it gave up on. The full output is in the log.
install_failure_message <- function(lines, status) {
  # renv colours its output with terminal escape codes.
  lines <- gsub("\033\\[[0-9;?]*[A-Za-z]", "", lines)
  lines <- sub("^\\s+", "", lines)
  why <- unique(c(grep("^ERROR:", lines, value = TRUE),
                  utils::tail(grep("^Error", lines, value = TRUE), 1)))
  if (length(why) == 0) return(paste("install failed, status", status))
  paste(c("install failed:", why), collapse = "\n")
}

#' Which packages an install failed on, and why, from the installer's
#' output. R's quotes are curly (left/right single quotation marks) or
#' ASCII depending on locale; both are matched.
#' -> data.frame(package, kind, detail): kind "compile" ("ERROR:
#'    compilation failed for package"), "configure" ("ERROR: configuration
#'    failed"), "dependency" ("ERROR: dependency 'x' is not available",
#'    detail = x), "download" (a summary line, or renv's own "error
#'    downloading"/"failed to retrieve", naming the package),
#'    "unavailable" (renv's summary line saying "failed to find source"
#'    or "binary for 'pkg version' in package repositories"; detail = that
#'    reason), "other"
#'    (renv's summary line, `- [pkg]: <reason>` or `- pkg: <reason>`,
#'    with none of the above; detail = the reason, or the first `ERROR`
#'    line when the reason itself says only "install failed"). One row
#'    per package: a package matching more than one pattern (its own
#'    "ERROR:" line earlier in the log, then renv's summary line at the
#'    end) keeps the most specific kind, in the order above.
#'
#' Best effort, not a contract (design-gaps.md): renv's and R's own text
#' can change between versions, so an unrecognised failure still shows up
#' as "other" with whatever its own reason says, rather than being
#' dropped silently. Captured against real renv 1.3.0/R 4.6.1 output
#' (fixtures/install-output): the summary line's package name can be
#' bracketed (`- [pkg]: ...`, seen with `renv::restore()`) or not, and
#' `renv_record_format_remote()`'s `"pkg@version"` form appears both
#' there and in "failed to retrieve package '...'" -- stripped here, not
#' matched into the name.
install_failures <- function(lines) {
  lines <- gsub("\033\\[[0-9;?]*[A-Za-z]", "", lines)
  lines <- gsub("[\u2018\u2019]", "'", lines)
  lines <- trimws(lines)

  first_error <- utils::head(grep("^(ERROR|Error)", lines, value = TRUE), 1L)
  first_error <- if (length(first_error) == 0L) NA_character_ else first_error

  capture <- function(pattern, x, ignore.case = FALSE) {
    m <- regmatches(x, regexec(pattern, x, ignore.case = ignore.case))[[1]]
    if (length(m) < 2L) NA_character_ else m[[2]]
  }
  strip_version <- function(name) sub("@.*$", "", name)

  pkg <- character(); kind <- character(); detail <- character()
  add <- function(p, k, d) {
    pkg[length(pkg) + 1L] <<- strip_version(p)
    kind[length(kind) + 1L] <<- k
    detail[length(detail) + 1L] <<- d
  }

  for (line in lines) {
    if (grepl("^ERROR: compilation failed for package '[^']+'", line)) {
      add(capture("^ERROR: compilation failed for package '([^']+)'", line), "compile", NA_character_)
    } else if (grepl("^ERROR: configuration failed for package '[^']+'", line)) {
      add(capture("^ERROR: configuration failed for package '([^']+)'", line), "configure", NA_character_)
    } else if (grepl("^ERROR: dependenc[a-z]+ '[^']+' (is|are) not available.*for package '[^']+'", line)) {
      dep <- capture("^ERROR: dependenc[a-z]+ '([^']+)'", line)
      pk <- capture(".*for package '([^']+)'", line)
      add(pk, "dependency", dep)
    } else if (grepl("error downloading.*package '[^']+'", line, ignore.case = TRUE)) {
      add(capture(".*error downloading.*package '([^']+)'", line, ignore.case = TRUE),
         "download", NA_character_)
    } else if (grepl("failed to retrieve.*package '[^']+'", line, ignore.case = TRUE)) {
      add(capture(".*failed to retrieve.*package '([^']+)'", line, ignore.case = TRUE),
         "download", NA_character_)
    } else if (grepl("^- \\[?[A-Za-z.][A-Za-z0-9._@-]*\\]?:", line)) {
      # renv's one-line-per-failed-package summary ("The following
      # package(s) were not installed successfully:"), real wording seen
      # across versions: "install failed", "error downloading '<url>'
      # [error code N]" (no "package" before the quote, so the regexes
      # above never match it), "failed to find binary for 'pkg version'
      # in package repositories". Whatever it says, this still gets the
      # package name and a usable reason. The name is restricted to R's
      # own package-name characters (not just "anything but ']'/':'"),
      # so it never matches an unrelated "- # <url> --------" line from
      # renv's "unable to query available packages" listing, which also
      # starts with "- " and contains a ":" (from "file://").
      name_pattern <- "^- \\[?([A-Za-z.][A-Za-z0-9._@-]*)\\]?:"
      name <- capture(name_pattern, line)
      reason <- trimws(sub(name_pattern, "", line))
      if (grepl("retriev|download", reason, ignore.case = TRUE)) {
        add(name, "download", NA_character_)
      } else if (grepl("^failed to find (source|binary) for ", reason, ignore.case = TRUE)) {
        # renv found no such version in any repository it could read: the
        # version isn't there, or (more often) the repository's own index
        # couldn't be read at all ("renv was unable to query available
        # packages", earlier in the log). Either way not a download or a
        # build problem, and nothing the package itself needs.
        add(name, "unavailable", reason)
      } else {
        # Not `detail <-`: that name is already the accumulator vector
        # `add()` appends to, and a plain `<-` inside this loop (no new
        # scope) would overwrite the whole vector instead of shadowing it.
        row_detail <- if (grepl("^install failed$", reason, ignore.case = TRUE)) first_error else reason
        add(name, "other", row_detail)
      }
    }
  }

  if (length(pkg) == 0L) return(empty_install_failures())

  # One row per package: keep the first (most specific) kind a package
  # was seen with, in the order the loop above checks patterns in
  # (compile/configure/dependency before the catch-all summary line).
  kind_rank <- c(compile = 1L, configure = 2L, dependency = 3L, download = 4L,
                 unavailable = 5L, other = 6L)
  df <- data.frame(package = pkg, kind = kind, detail = detail, stringsAsFactors = FALSE)
  df <- df[order(kind_rank[df$kind]), ]
  df <- df[!duplicated(df$package), ]
  df[order(df$package), ]
}

#' A date move being previewed: `date`, `status` (`"fetching"`, `"ready"`,
#' `"failed"`), and once ready `lock` (the fresh resolution at `date`),
#' `changes` (`lock_diff(current, lock)`), `problems`, `for_wanted` (the
#' wanted set it was computed for; recomputed when that changes, so a
#' preview never goes stale under an edit).
#'
#' * `apply`: set by `ev_preview_date(..., apply = TRUE)` (the Packages
#'   tab's Update button, through `ember_update_packages`): once the
#'   resolution is `"ready"`, `schedule_packages()`'s Proposal stage
#'   applies it itself unless doing so would restart a loaded package, in
#'   which case the page is asked first. A plain `preview_date()` call
#'   leaves this `FALSE` and is never applied automatically.
#' * `restart`: character, set only when an `apply = TRUE` proposal is
#'   `"ready"` but waiting on the page's answer: the loaded packages
#'   (`state$worker$loaded`) that `changes` would affect.
#' * `message`: why the fetch failed (`status == "failed"`), the index
#'   slot's own message; `NULL` otherwise.
#' * `kind`: `"date"` (the above), or `"bioc"`: a pinned notebook moving to
#'   the Bioconductor release for the running R at its own date
#'   (`propose_bioc_move()`). A `"bioc"` move re-resolves only the
#'   Bioconductor packages (`resolve_lock(mode = "bioc")`), is applied
#'   even when it restarts R (running the notebook was the consent), holds
#'   the install of the old pin's library while it is pending, and isn't
#'   the page's update question (`project_ember()`).
new_proposal <- function(date, status = "fetching", lock = NULL, changes = NULL,
                         problems = NULL, for_wanted = NULL, apply = FALSE,
                         restart = character(), message = NULL,
                         bioc_version = NA_character_, kind = "date") {
  structure(list(date = date, status = status, lock = lock, changes = changes,
                 problems = problems, for_wanted = for_wanted, apply = apply,
                 restart = restart, message = message, bioc_version = bioc_version,
                 kind = kind),
            class = "ember_proposal")
}

# ---- Events and effects ------------------------------------------------------

# From the API
#' `apply = TRUE`: `reduce_preview_date()` stores it on the proposal, and
#' `schedule_packages()`'s Proposal stage applies the result itself once
#' it is ready, unless doing so would restart a loaded package.
ev_preview_date <- function(date, at, apply = FALSE) event("preview_date", at, date = date, apply = apply)
ev_set_date     <- function(date, at) event("set_date", at, date = date)
#' Drop the current preview without applying it (the page's Cancel on the
#' in-tab update question).
ev_cancel_preview <- function(at) event("cancel_preview", at)
# `edit_notebook()` ops, applied by reduce_apply() with the others:
#   add_extra_package(name), remove_extra_package(name)

# From the shell's jobs
ev_index_fetched <- function(key, index, at) event("index_fetched", at, key = key, index = index)
ev_index_failed  <- function(key, message, at) event("index_failed", at, key = key, message = message)
#' `table`: `parse_bioc_config()`'s result, as fetched (or cached).
#' `fetched`: the day that list was fetched, a `Date` (a cached copy's own
#' day, not today's).
ev_bioc_releases_fetched <- function(table, fetched, at)
  event("bioc_releases_fetched", at, table = table, fetched = fetched)
ev_bioc_releases_failed  <- function(message, at) event("bioc_releases_failed", at, message = message)
ev_library_checked <- function(key, manifest, at)            # manifest: NULL when absent
  event("library_checked", at, key = key, manifest = manifest)
ev_install_progress <- function(token, item, at)             # item: list(package, step, done, total)
  event("install_progress", at, token = token, item = item)
#' `failures` is `install_failures()`'s result (empty when the install
#' succeeded, or when the caller doesn't have one -- tests that build this
#' event directly don't need to).
ev_install_done <- function(token, key, manifest, message, log, at, failures = empty_install_failures())
  event("install_done", at, token = token, key = key, manifest = manifest,
        message = message, log = log, failures = failures)

fx_fetch_index    <- function(key, url) effect("fetch_index", key = key, url = url)
#' Fetch Bioconductor's release list from `url` (`ember_repos(bioc_config)`),
#' or read it from the disk cache when it is less than a day old and was
#' fetched no earlier than `date` (the snapshot date it must cover).
fx_fetch_bioc_config <- function(url, date) effect("fetch_bioc_config", url = url, date = date)
fx_check_library  <- function(key, path) effect("check_library", key = key, path = path)
#' `lock` and `repos` are everything the installer needs; it writes the
#' renv lockfile itself (lock.R, `renv_lockfile_of()`). `repos` is the
#' dated mapping `repo_urls()` builds (name -> dated URL), not the raw
#' `ember_repos` value: `renv_lockfile_of()` writes it straight into the
#' lockfile's `Repositories`, which `Source = "Repository"` entries resolve
#' against by name ("CRAN", "BioCsoft").
fx_install        <- function(token, key, path, lock, repos)
  effect("install", token = token, key = key, path = path, lock = lock, repos = repos)
#' Deviation from the sketch: `fx_cancel_install()` also carries `key` and
#' `path`, not just `token`. The shell's job table (library.R) is keyed by
#' the install's library path, not the token (two notebooks installing the
#' *same* library share one job, and `path` -- unlike `key`, a hash of the
#' lock text alone -- also tells apart two sessions whose lock hashes to the
#' same text but whose library lives under a different cache);
#' `reduce_shutdown()` still has `state$packages$install$key`/`$path` at
#' hand when it builds this effect, so passing them along costs nothing and
#' saves the shell from having to reverse-map a token to a job key.
fx_cancel_install <- function(token, key, path) effect("cancel_install", token = token, key = key, path = path)
#' Like `fx_cancel_install()` but for an index fetch still "fetching" when
#' the session shuts down: this session's own subscription to the job must
#' leave (`job_leave()`, library.R), or the job's subscriber list keeps a
#' reference to a closed session forever and the subprocess is never killed
#' even after every other subscriber has gone. `url` is carried along the
#' same way `fx_install()` carries `repos`: the shell's job key
#' (`index_job_key()`) needs it and `reduce_shutdown()` can compute it
#' purely from `state$options$repos`, so the shell doesn't have to.
fx_cancel_fetch_index <- function(key, url) effect("cancel_fetch_index", key = key, url = url)
fx_cancel_fetch_bioc_config <- function(url) effect("cancel_fetch_bioc_config", url = url)

# ---- The stage step() runs ---------------------------------------------------

#' `%||%` is defined in state.R, loaded before this file.

#' Move packages forward. Called by `step()` after `reduce()`, before
#' `schedule()`; returns `list(state, effects)`.
#'
#' In order, each part reading the state the previous part left: resolve,
#' then the date-move proposal, then look at the target library, then
#' install it, then switch the worker onto it. See the stage comments below
#' for what each one does; the module doc at the top of this file and
#' design.md ("One more stage in step()") give the rationale.
schedule_packages <- function(state, old) {
  effects <- list()
  p <- state$packages

  # ---- 0. Bioconductor's release list -------------------------------------
  # A lock holding Bioconductor packages fetches the list at open: its pin's
  # window, and whether the pin moves on this R, come from it. Resolution
  # asks for it below when it first meets Bioconductor.
  if (lock_has_bioc(state$file$lock) && releases_unsettled(p, state$file$header$snapshot)) {
    fr <- fetch_releases(p, state$options, state$file$header$snapshot)
    p <- fr$p
    effects <- c(effects, fr$effects)
  }

  # ---- 1. Resolve --------------------------------------------------------
  # Deviation from the sketch's "cheap check first: skip when graph and
  # header are identical() to old's": skipping the whole stage on that check
  # would also skip it on every `index_fetched`/`index_failed` event, since
  # those change `packages$indexes`, not `graph` or `header` -- and resolving
  # in response to an index arriving is the whole point of the stage (test
  # "index_fetched resolves ..."). The real gate is `!setequal(wanted,
  # resolved_for)`, checked every call. What the cheap check *can* still
  # skip is recomputing `wanted` itself: it is a pure function of `graph` and
  # `header`, so when neither changed since `old`, the previous call's result
  # (cached in `wanted_cache`, not part of the documented invariants) is
  # still correct. Measured: without this, a 2000-cell notebook with no
  # packages regressed step()'s per-event cost past the engine's 50ms budget
  # (test-projections.R), since `wanted_packages()` walks every cell.
  {
    wanted <- if (identical(state$graph, old$graph) && identical(state$file$header, old$file$header) &&
                 !is.null(p$wanted_cache)) {
      p$wanted_cache
    } else {
      wanted_packages(state$graph, state$file$header)
    }
    p$wanted_cache <- wanted
    if (!setequal(wanted, p$resolved_for)) {
      if (length(wanted) > 0 && (is.null(state$file$header$snapshot) || is.na(state$file$header$snapshot))) {
        # `format()` on a POSIXct uses the local time zone directly; routing
        # through `as.Date()` first would convert to UTC (its default `tz`)
        # before taking the date, giving the wrong day for anyone not on
        # UTC near midnight. `state$clock` may also already be a bare
        # `Date` (tests, `ev_open(as.Date(...))`), for which `format()`
        # behaves the same either way.
        state$file$header$snapshot <- format(state$clock, "%Y-%m-%d")
      }
      needed <- needed_repos(state$file$header, state$options$r,
                             releases_at(p, state$file$header$snapshot))
      # Only CRAN's index is fetched up front; the Bioconductor keys after
      # it are fetched when `resolve_lock()` asks for them (a name CRAN
      # lacks). A later key that failed is retried once the wanted set
      # changes; until then it is left out of `needed`, so its names
      # resolve as not found instead of waiting on it forever.
      refetch <- function(k) {
        slot <- p$indexes[[k]]
        identical(slot$status, "failed") && !setequal(slot$wanted %||% character(), wanted)
      }
      # A later key's failed slot is dropped rather than refetched, so it is
      # fetched again only if `resolve_lock()` still asks for it.
      for (k in Filter(refetch, needed[-1])) p$indexes[[k]] <- NULL
      to_fetch <- Filter(function(k) is.null(p$indexes[[k]]) || refetch(k), needed[1])
      for (k in to_fetch) {
        p$indexes[[k]] <- new_index_slot("fetching")
        effects <- c(effects, list(fx_fetch_index(k, repo_url(state$options$repos, k))))
      }
      if (length(to_fetch) == 0 && length(needed) > 0) {
        first <- p$indexes[[needed[[1]]]]
        if (!is.null(first) && identical(first$status, "ready")) {
          failed <- Filter(function(k) identical(p$indexes[[k]]$status, "failed"), needed[-1])
          usable <- setdiff(needed, failed)
          loaded_idx <- Filter(Negate(is.null), lapply(p$indexes[usable], function(s) s$index))
          res <- resolve_lock(wanted, state$file$lock, loaded_idx, needed = usable, mode = "keep")
          # Which release `needed` names comes from Bioconductor's list:
          # fetch it when resolution first meets Bioconductor (a name CRAN
          # lacks, which without the list has no Bioconductor key to look
          # in, or a Bioc entry), then resolve again with it.
          meets_bioc <- needs_bioc(res)
          if (meets_bioc && releases_unsettled(p, state$file$header$snapshot)) {
            fr <- fetch_releases(p, state$options, state$file$header$snapshot)
            p <- fr$p
            effects <- c(effects, fr$effects)
          } else if (isTRUE(res$complete)) {
            state$packages <- p
            state <- set_lock(state, res$lock)
            state$file$header$bioc_version <- bioc_pin(res$lock, bioc_release_in(needed))
            p <- state$packages
            p$resolved_for <- wanted
            p$problems <- rbind(res$problems, failed_index_problems(p$indexes[failed]),
                                bioc_problems(state$file$header, state$options$r, p$bioc_releases$table),
                                bioc_unavailable_problem(needed, res$problems, state$file$header,
                                                         state$options$r))
          } else {
            for (k in res$fetch) {
              if (is.null(p$indexes[[k]]) || !identical(p$indexes[[k]]$status, "fetching")) {
                p$indexes[[k]] <- new_index_slot("fetching")
                effects <- c(effects, list(fx_fetch_index(k, repo_url(state$options$repos, k))))
              }
            }
          }
        } else if (!is.null(first) && identical(first$status, "failed")) {
          p$problems <- data.frame(kind = "index_unavailable", package = NA_character_,
                                   message = first$message %||% "no package index available",
                                   fixes = NA_character_, stringsAsFactors = FALSE)
        }
      }
    }
  }
  state$packages <- p

  # ---- 2. Proposal --------------------------------------------------------
  state <- propose_bioc_move(state)
  if (!is.null(state$packages$proposal)) {
    prop <- state$packages$proposal
    is_move <- identical(prop$kind, "bioc")
    releases <- releases_at(state$packages, prop$date)
    wanted <- wanted_packages(state$graph, state$file$header)
    # The new date's CRAN key first, then Bioconductor's at the release for
    # the running R at that date: moving the date moves the release too.
    # Its indexes are fetched only if CRAN lacks a name, as when resolving.
    date_header <- state$file$header
    date_header$snapshot <- prop$date
    date_header$bioc_version <- NA_character_
    needed <- needed_repos(date_header, state$options$r, releases)
    key <- needed[[1]]
    slot <- state$packages$indexes[[key]]
    failed <- Filter(function(k) identical(state$packages$indexes[[k]]$status, "failed"), needed[-1])
    has_bioc <- any(state$file$lock$entries$source == "Bioc")
    # Without a Bioconductor index (none fetched, or no release for this R
    # at that date), the lock's Bioconductor packages would resolve as not
    # found and silently drop out of the new lock: fail instead. A notebook
    # with none just resolves without the failed index.
    drop_message <- if (!has_bioc || identical(prop$status, "failed")) {
      NULL
    } else if (is.na(bioc_release_in(needed))) {
      releases_gap_message(state$packages, prop$date) %||% sprintf(paste("Bioconductor has no release for R %s at %s; moving there would",
                    "drop this notebook's Bioconductor packages"), state$options$r$minor, prop$date)
    } else if (length(failed) > 0) {
      failed_index_problems(state$packages$indexes[failed])$message[[1]]
    }
    needed <- setdiff(needed, failed)
    if (has_bioc && !identical(prop$status, "failed") &&
        releases_unsettled(state$packages, prop$date)) {
      # The release at the new date comes from Bioconductor's list.
      fr <- fetch_releases(state$packages, state$options, prop$date)
      state$packages <- fr$p
      effects <- c(effects, fr$effects)
    } else if (is.null(slot)) {
      state$packages$indexes[[key]] <- new_index_slot("fetching")
      effects <- c(effects, list(fx_fetch_index(key, repo_url(state$options$repos, key))))
    } else if (identical(slot$status, "ready") && !is.null(drop_message)) {
      state$packages$proposal <- new_proposal(prop$date, status = "failed", apply = prop$apply,
                                              message = drop_message, kind = prop$kind)
    } else if (identical(slot$status, "ready") &&
              (identical(prop$status, "fetching") || !setequal(prop$for_wanted %||% character(), wanted))) {
      indexes_loaded <- Filter(Negate(is.null), lapply(state$packages$indexes[needed], function(s) s$index))
      res <- resolve_lock(wanted, state$file$lock, indexes_loaded, needed = needed,
                          mode = if (is_move) "bioc" else "fresh")
      if (needs_bioc(res) && releases_unsettled(state$packages, prop$date)) {
        fr <- fetch_releases(state$packages, state$options, prop$date)
        state$packages <- fr$p
        effects <- c(effects, fr$effects)
      } else if (isTRUE(res$complete)) {
        changes <- lock_diff(state$file$lock, res$lock)
        new_prop <- new_proposal(prop$date, status = "ready", lock = res$lock, changes = changes,
                                 problems = res$problems, for_wanted = wanted, apply = prop$apply,
                                 bioc_version = bioc_pin(res$lock, bioc_release_in(needed)),
                                 kind = prop$kind)
        if (isTRUE(prop$apply)) {
          loaded <- state$worker$loaded %||% character()
          restart_names <- intersect(changes$name, names(loaded))
          # A Bioconductor move doesn't wait on the page: running the
          # notebook on this R was the consent, and the page's update
          # question is about dates. `switch_library()` restarts R once the
          # new library is ready, as for any other change to a loaded package.
          if (length(restart_names) == 0 || is_move) {
            state$packages$proposal <- new_prop
            ap <- apply_proposal(state)
            state <- ap$state
            effects <- c(effects, ap$effects)
          } else {
            new_prop$restart <- restart_names
            state$packages$proposal <- new_prop
          }
        } else {
          state$packages$proposal <- new_prop
        }
      } else {
        for (k in res$fetch) {
          if (is.null(state$packages$indexes[[k]])) {
            state$packages$indexes[[k]] <- new_index_slot("fetching")
            effects <- c(effects, list(fx_fetch_index(k, repo_url(state$options$repos, k))))
          }
        }
      }
    } else if (identical(slot$status, "failed")) {
      state$packages$proposal <- new_proposal(prop$date, status = "failed", apply = prop$apply,
                                              message = slot$message, kind = prop$kind)
    }
  }

  # ---- 3. Look -------------------------------------------------------------
  tgt <- state$packages$target
  if (identical(tgt$status, "unknown")) {
    lock_entries <- state$file$lock$entries
    if (is.null(lock_entries) || nrow(lock_entries) == 0) {
      tgt$status <- "ready"
      tgt$installed <- character()
      tgt$exports <- list()
      state$packages$target <- tgt
    } else {
      tgt$status <- "checking"
      state$packages$target <- tgt
      effects <- c(effects, list(fx_check_library(tgt$key, tgt$path)))
    }
  }

  # ---- 4. Install ------------------------------------------------------------
  tgt <- state$packages$target
  if (isTRUE(state$allowed) && !isTRUE(state$read_only) &&
      identical(tgt$status, "missing") && is.null(state$packages$install) &&
      !bioc_move_pending(state)) {
    token <- state$packages$next_token
    state$packages$next_token <- token + 1L
    state$packages$install <- list(token = token, key = tgt$key, path = tgt$path)
    tgt$status <- "installing"
    tgt$progress <- NULL
    state$packages$target <- tgt
    effects <- c(effects, list(fx_install(token, tgt$key, tgt$path, state$file$lock,
                                          repo_urls(state$options$repos, state$file$header))))
  }

  # ---- 5. Switch -------------------------------------------------------------
  sw <- switch_library(state)
  state <- sw$state
  effects <- c(effects, sw$effects)

  list(state = state, effects = effects)
}

#' `TRUE` when a resolution reached for Bioconductor: it asks for a
#' Bioconductor index, found a name nowhere it looked, or locked a Bioc entry.
needs_bioc <- function(res) {
  any(is_bioc_key(res$fetch)) || any(res$problems$kind == "not_found") ||
    (isTRUE(res$complete) && lock_has_bioc(res$lock))
}

#' `TRUE` when `lock` holds a Bioconductor package.
lock_has_bioc <- function(lock) {
  !is.null(lock$entries) && any(lock$entries$source == "Bioc")
}

#' `TRUE` while Bioconductor's release list can still change what Ember
#' decides at `date`: it hasn't been fetched (or failed) yet, or the copy at
#' hand was fetched before `date` and no fetch has been asked to cover
#' `date` yet. Which release a notebook resolves from, its pin's window and
#' whether the pin moves on this R all come from it.
releases_unsettled <- function(p, date) {
  slot <- p$bioc_releases
  if (slot$status %in% c("unknown", "fetching")) return(TRUE)
  if (!identical(slot$status, "ready") || is.null(date) || is.na(date)) return(FALSE)
  date <- as.Date(date)
  date > slot$fetched && (is.na(slot$asked) || date > slot$asked)
}

#' The release list as it speaks for `date`: the table when it was fetched
#' on or after `date`, else no releases. A list fetched before `date` may
#' lack a release out by then, and resolving an unpinned notebook from it
#' would pin the older release for good, so it isn't used for that date
#' (`releases_gap_message()` says why). A pin needs no list to resolve
#' (`needed_repos()`).
releases_at <- function(p, date) {
  slot <- p$bioc_releases
  if (!identical(slot$status, "ready")) return(empty_bioc_releases())
  if (!is.null(date) && !is.na(date) && as.Date(date) > slot$fetched) return(empty_bioc_releases())
  slot$table
}

#' Why the release list doesn't speak for `date`, or `NULL` when it does.
releases_gap_message <- function(p, date) {
  slot <- p$bioc_releases
  if (identical(slot$status, "failed")) return(slot$message %||% "no release list")
  if (identical(slot$status, "ready") && !is.null(date) && !is.na(date) && as.Date(date) > slot$fetched) {
    return(sprintf(paste("Bioconductor's release list was last fetched on %s, before this notebook's",
                         "date %s, and couldn't be fetched again"), format(slot$fetched), date))
  }
  NULL
}

#' Ask the shell for the release list covering `date`, once per later date:
#' `list(p, effects)`. The table at hand stays until the new one arrives.
fetch_releases <- function(p, options, date) {
  if (identical(p$bioc_releases$status, "fetching")) return(list(p = p, effects = list()))
  p$bioc_releases$status <- "fetching"
  if (!is.null(date) && !is.na(date)) {
    p$bioc_releases$asked <- max(p$bioc_releases$asked, as.Date(date), na.rm = TRUE)
  }
  list(p = p, effects = list(fx_fetch_bioc_config(options$repos$bioc_config, date %||% NA_character_)))
}

#' Move a pinned notebook to the Bioconductor release for the running R
#' (design.md, "R itself"): once execution is allowed, which is also when
#' the new R is recorded (`record_r_version()`), and the pin was built for
#' another R, propose the move as an applying `"bioc"` proposal at the
#' notebook's own date. Safe preview has already said so
#' (`bioc_problems()`'s `bioc_r_version` row names the release it moves to).
#'
#' Once a session: a move that fails (an index fetch) isn't proposed again
#' until `reduce_run()` retries it. None while another proposal is open (a
#' date move moves the pin itself), while the release list is unsettled,
#' or when there is no release for this R at that date (the row says so).
propose_bioc_move <- function(state) {
  p <- state$packages
  header <- state$file$header
  if (!isTRUE(state$allowed) || isTRUE(state$read_only) || !is.null(p$proposal) ||
      isTRUE(p$bioc_move_tried) || is.na(header$bioc_version) || is.na(header$snapshot) ||
      !lock_has_bioc(state$file$lock) || releases_unsettled(p, header$snapshot)) {
    return(state)
  }
  if (is.na(bioc_move_target(header, state$options$r, releases_at(p, header$snapshot)))) return(state)
  p$proposal <- new_proposal(header$snapshot, apply = TRUE, kind = "bioc")
  p$bioc_move_tried <- TRUE
  state$packages <- p
  state
}

#' `TRUE` while a Bioconductor move is pending, or the release list that
#' decides one is being fetched for a notebook that holds Bioconductor
#' packages: the old pin's library is not installed meanwhile, since on
#' another R every one of its Bioconductor packages builds from source.
bioc_move_pending <- function(state) {
  prop <- state$packages$proposal
  if (!is.null(prop) && identical(prop$kind, "bioc") && !identical(prop$status, "failed")) return(TRUE)
  identical(state$packages$bioc_releases$status, "fetching") && lock_has_bioc(state$file$lock)
}

#' The only writer of `state$file$lock` after open. Resets `target` to the
#' new lock's library (status `"unknown"`, or `"ready"` with no look when it
#' equals `active`'s key) and leaves `active` alone, so the worker keeps
#' running on the old library until the new one is ready.
set_lock <- function(state, lock) {
  state$file$lock <- lock
  info <- library_for(lock, state$options$r, state$options$cache)
  active <- state$packages$active
  if (identical(info$key, active$key)) {
    state$packages$target <- active
  } else {
    state$packages$target <- new_library_slot(info$key, info$path)
  }
  state
}

#' The header's `bioc_version` for `lock`: `release` (the one it was
#' resolved with) while the lock holds a Bioconductor package, `NA` once it
#' holds none, so a CRAN-only notebook carries no pin and no tie to an R
#' version.
bioc_pin <- function(lock, release) {
  if (any(lock$entries$source == "Bioc")) release else NA_character_
}

#' One `index_unavailable` row per failed index slot (Bioconductor's,
#' fetched after CRAN's), naming the index and why it failed.
failed_index_problems <- function(slots) {
  out <- empty_package_problems()
  for (k in names(slots)) {
    out <- rbind(out, package_problem("index_unavailable", NA_character_, sprintf(
      "the package index %s could not be fetched: %s", k,
      slots[[k]]$message %||% "no package index available")))
  }
  out
}

#' Point the worker at the target library once it is ready.
#'
#' * The worker is busy: never switch. Deciding whether a switch conflicts
#'   needs `worker$loaded`, and that only reflects what was attached up to
#'   the *last* `wk_done`; the cell running right now can still attach the
#'   very package the switch would change, at a version `loaded` has never
#'   heard of. Switching mid-run risks exactly that: the running cell then
#'   loads the old version from the old library's files and nothing ever
#'   notices. So every switch, conflicting or not, waits for the worker to
#'   be idle; `schedule()` sends nothing new meanwhile (`switch_pending()`),
#'   so no further cell loads an old version either.
#' * Same key as `active`: nothing to switch, but see the mismatch check
#'   below.
#' * No conflict (`library_conflicts()` empty): `active <- target`. The
#'   worker picks up the new path from the next `run` message (it carries
#'   `library`, as it carries `order`), so a new package is just loaded:
#'   no restart. Namespaces already loaded keep their files, which are
#'   links to the same cache entries.
#' * A conflict, worker idle: `active <- target` and `restart_worker(state,
#'   reason)` (step.R, factored out of `reduce_restart()`): every cell is
#'   left not run, and `worker$exit$message` says why ("dplyr changed
#'   1.1.4 -> 1.2.1; R restarted").
#' * No switch pending (`target` already equals `active`), worker idle, but
#'   `worker$loaded` disagrees with `active$installed` anyway: the same
#'   restart. This is the net for the race above -- a cell that ran while a
#'   switch was blocked, and so loaded the version the library had *before*
#'   the switch, is caught the moment its `wk_done` updates `worker$loaded`,
#'   since that is the next time this runs (`schedule_packages()` calls it
#'   after every event, `wk_done` included).
#' @return `list(state, effects)` (not just `state`, since a restart emits
#'   `fx_kill_worker`/`fx_start_worker`).
switch_library <- function(state) {
  p <- state$packages
  busy <- identical(state$worker$status, "busy")
  loaded <- state$worker$loaded %||% character()
  pending_switch <- identical(p$target$status, "ready") && !identical(p$target$key, p$active$key)

  restart_for <- function(state, conflicts) {
    changes_txt <- paste(sprintf("%s changed %s -> %s", conflicts$name, conflicts$loaded, conflicts$new),
                         collapse = "; ")
    restart_worker(state, reason = paste0(changes_txt, "; R restarted"))
  }

  if (pending_switch) {
    if (busy) return(list(state = state, effects = list()))
    conflicts <- library_conflicts(loaded, p$target$installed)
    state$packages$active <- p$target
    # The active library's exports feed the graph (`exports_of()`, state.R);
    # rebuilding here, not just from `reduce_library_checked()`/
    # `reduce_install_done()`, is what makes a package's edges appear the
    # moment it becomes active even when no install was needed (a library
    # already complete on disk goes ready -> active in the same step()).
    state <- rebuild_graph(state)
    if (nrow(conflicts) > 0) return(restart_for(state, conflicts))
    return(list(state = state, effects = list()))
  }

  if (!busy) {
    conflicts <- library_conflicts(loaded, p$active$installed)
    if (nrow(conflicts) > 0) return(restart_for(state, conflicts))
  }
  list(state = state, effects = list())
}

#' Loaded namespaces whose version the new library changes: data frame
#' `name`, `loaded`, `new`. A loaded package the new library doesn't have
#' is not a conflict: it stays loaded, as Pluto keeps a removed package.
#' @param loaded `state$worker$loaded`, package -> version (non-base).
library_conflicts <- function(loaded, installed) {
  common <- intersect(names(loaded), names(installed))
  changed <- Filter(function(n) !identical(unname(loaded[[n]]), unname(installed[[n]])), common)
  data.frame(name = changed, loaded = unname(loaded[changed]), new = unname(installed[changed]),
            stringsAsFactors = FALSE)
}

#' `TRUE` while a switch (conflicting or not: `switch_library()` never
#' switches mid-run) waits for the running cell.
switch_pending <- function(state) {
  p <- state$packages
  if (!identical(p$target$status, "ready") || identical(p$target$key, p$active$key)) return(FALSE)
  identical(state$worker$status, "busy")
}

# ---- Which cells wait --------------------------------------------------------

#' Map cell id -> character packages it waits for, for every code cell
#' that can't run yet, plus their transitive downstream, mapped to the
#' upstream cell's packages.
#'
#' Cell `c` waits for `p` when `p` is in `cell_packages(graph, c)`, `p` is
#' not in `active$installed`, and either `p` is in the lock (an install
#' will bring it) or resolution is still pending (`wanted != resolved_for`
#' and an index is fetching). A package that resolved to `not_found` does
#' not hold its cell: it runs, R says "there is no package called", and
#' the problem row explains why.
#'
#' `schedule()` skips waiting cells but keeps them in `pending`, so they run
#' the moment the library is ready. When the target library fails, they run
#' anyway: the worker raises `packageNotFoundError` and
#' `missing_package_error()`'s "in the lock, not installed" branch attaches
#' the error, so their view shows the failure too.
waiting_cells <- function(state) {
  p <- state$packages
  # Cheap check first: no cell in the notebook names any package at all
  # (the common case, and the one `schedule()` pays this cost on for every
  # notebook on every event) means nothing can be waiting. `wanted_cache`
  # (packages-core.R's `schedule_packages()`) is exactly `wanted_packages()`
  # for the current graph and header, kept current by the stage that always
  # runs just before `schedule()` calls this.
  if (length(p$wanted_cache %||% character()) == 0) return(list())
  installed <- p$active$installed
  lock_entries <- state$file$lock$entries
  lock_names <- if (is.null(lock_entries) || nrow(lock_entries) == 0) character() else lock_entries$name
  not_found <- if (is.null(p$problems) || nrow(p$problems) == 0) character() else {
    p$problems$package[p$problems$kind == "not_found" & !is.na(p$problems$package)]
  }
  wanted <- wanted_packages(state$graph, state$file$header)
  resolving <- !setequal(wanted, p$resolved_for)
  any_fetching <- any(vapply(p$indexes, function(s) identical(s$status, "fetching"), logical(1))) ||
    identical(p$bioc_releases$status, "fetching")

  runnable_ids <- names(state$cells)[vapply(state$cells, cell_runs, logical(1))]
  direct <- list()
  for (id in runnable_ids) {
    pkgs <- setdiff(cell_packages(state$graph, id), not_found)
    needed <- Filter(function(pk) {
      !(pk %in% names(installed)) && (pk %in% lock_names || (resolving && any_fetching))
    }, pkgs)
    if (length(needed) > 0) direct[[id]] <- needed
  }

  out <- direct
  for (id in names(direct)) {
    for (d in downstream(state$graph, id, transitive = TRUE)) {
      if (is.null(out[[d]])) out[[d]] <- direct[[id]]
    }
  }
  out
}

# ---- Reducers ----------------------------------------------------------------

#' Record the index (or the failure) under its key. A slot that is not
#' `"fetching"` ignores the event, so a duplicate is a no-op.
reduce_index_fetched <- function(state, event) {
  slot <- state$packages$indexes[[event$key]]
  if (is.null(slot) || !identical(slot$status, "fetching")) {
    return(list(state = state, effects = list(), reply = NULL))
  }
  state$packages$indexes[[event$key]] <- new_index_slot("ready", index = event$index)
  list(state = state, effects = list(), reply = NULL)
}

reduce_index_failed <- function(state, event) {
  slot <- state$packages$indexes[[event$key]]
  if (is.null(slot) || !identical(slot$status, "fetching")) {
    return(list(state = state, effects = list(), reply = NULL))
  }
  wanted <- wanted_packages(state$graph, state$file$header)
  state$packages$indexes[[event$key]] <- new_index_slot("failed", message = event$message, wanted = wanted)
  list(state = state, effects = list(), reply = NULL)
}

#' The release list arrived, and the pin's problem rows are recomputed
#' with it. A slot that is not `"fetching"` ignores the event.
reduce_bioc_releases_fetched <- function(state, event) {
  slot <- state$packages$bioc_releases
  if (!identical(slot$status, "fetching")) return(list(state = state, effects = list(), reply = NULL))
  state$packages$bioc_releases <- new_releases_slot("ready", event$table, fetched = as.Date(event$fetched),
                                                    asked = slot$asked)
  state <- refresh_bioc_problems(state)
  list(state = state, effects = list(), reply = NULL)
}

#' The release list couldn't be fetched, and the shell had no earlier copy:
#' Bioconductor packages can't be resolved (`packages_view()` says so)
#' until running asks again (`reduce_run()`). A list this session already
#' had stays, for the dates it covers.
reduce_bioc_releases_failed <- function(state, event) {
  slot <- state$packages$bioc_releases
  if (!identical(slot$status, "fetching")) return(list(state = state, effects = list(), reply = NULL))
  state$packages$bioc_releases <- if (!is.na(slot$fetched)) {
    new_releases_slot("ready", slot$table, fetched = slot$fetched, asked = slot$asked)
  } else {
    new_releases_slot("failed", message = event$message, asked = slot$asked)
  }
  list(state = state, effects = list(), reply = NULL)
}

#' Replace the `bioc_r_version`/`bioc_off_date` rows of `problems` with
#' `bioc_problems()` against the current release list.
refresh_bioc_problems <- function(state) {
  probs <- state$packages$problems
  keep <- probs[!(probs$kind %in% c("bioc_r_version", "bioc_off_date")), , drop = FALSE]
  state$packages$problems <- rbind(keep, bioc_problems(state$file$header, state$options$r,
                                                       state$packages$bioc_releases$table))
  state
}

#' For `target` only (an old key's answer is ignored): manifest present ->
#' `"ready"` with `installed` and `exports`; absent -> `"missing"`.
#' Exports join the graph through `exports_of()` (state.R), and the graph
#' is rebuilt.
reduce_library_checked <- function(state, event) {
  tgt <- state$packages$target
  if (!identical(event$key, tgt$key)) return(list(state = state, effects = list(), reply = NULL))
  if (is.null(event$manifest)) {
    tgt$status <- "missing"
  } else {
    tgt$status <- "ready"
    tgt$installed <- event$manifest$installed
    tgt$exports <- event$manifest$exports
  }
  state$packages$target <- tgt
  state <- rebuild_graph(state)
  list(state = state, effects = list(), reply = NULL)
}

#' Token check; `target$progress` updated.
reduce_install_progress <- function(state, event) {
  inst <- state$packages$install
  if (is.null(inst) || !eq(inst$token, event$token)) return(list(state = state, effects = list(), reply = NULL))
  state$packages$target$progress <- event$item
  list(state = state, effects = list(), reply = NULL)
}

#' Token check; `install <- NULL`. If `key` is still the target: manifest ->
#' `"ready"` (as `reduce_library_checked`), else `"failed"` with `message`,
#' `log` and `failures` (`event$failures`, `install_failures()`'s result),
#' plus one `problems` row (`install_failed`) per failed package, each
#' naming its `package`; falls back to today's single `NA`-package row
#' only when `event$failures` has none (the installer's output didn't
#' parse). An old key's result is dropped: the library exists on disk and
#' costs nothing until cleanup.
reduce_install_done <- function(state, event) {
  inst <- state$packages$install
  if (is.null(inst) || !eq(inst$token, event$token)) return(list(state = state, effects = list(), reply = NULL))
  state$packages$install <- NULL
  if (identical(event$key, state$packages$target$key)) {
    tgt <- state$packages$target
    if (!is.null(event$manifest)) {
      tgt$status <- "ready"
      tgt$installed <- event$manifest$installed
      tgt$exports <- event$manifest$exports
      tgt$progress <- NULL
      state$packages$target <- tgt
      state <- rebuild_graph(state)
    } else {
      tgt$status <- "failed"
      tgt$message <- event$message
      tgt$log <- event$log
      tgt$failures <- event$failures %||% empty_install_failures()
      # `needed_by` is computed once, here, rather than by every
      # `packages_view()` call: `failure_needed_by()` walks the loaded
      # index's dependency graph from every wanted package, which was
      # showing up as ~35ms per failed package per call at a CRAN-sized
      # index (packages_view() runs on every dispatch that might have
      # changed anything package-related, notifications()), and nothing
      # about the answer changes between one call and the next -- the
      # failure, the wanted set and the indexes loaded when it happened
      # are all already fixed by the time this reducer runs.
      if (nrow(tgt$failures) > 0) {
        wanted <- wanted_packages(state$graph, state$file$header)
        needed <- needed_repos(state$file$header, state$options$r,
                               releases_at(state$packages, state$file$header$snapshot))
        indexes <- lapply(state$packages$indexes, function(s) s$index)
        tgt$failures$needed_by <- lapply(tgt$failures$package, function(pk) {
          failure_needed_by(pk, wanted, indexes, needed)
        })
      } else {
        tgt$failures$needed_by <- list()
      }
      tgt$progress <- NULL
      state$packages$target <- tgt
      rows <- if (nrow(tgt$failures) > 0) {
        data.frame(kind = "install_failed", package = tgt$failures$package,
                  message = event$message %||% "install failed", fixes = NA_character_,
                  stringsAsFactors = FALSE)
      } else {
        data.frame(kind = "install_failed", package = NA_character_,
                  message = event$message %||% "install failed", fixes = NA_character_,
                  stringsAsFactors = FALSE)
      }
      state$packages$problems <- if (is.null(state$packages$problems) || nrow(state$packages$problems) == 0) {
        rows
      } else {
        rbind(state$packages$problems, rows)
      }
    }
  }
  list(state = state, effects = list(), reply = NULL)
}

#' A preview of moving the date: `proposal <- new_proposal(date)`;
#' `schedule_packages()` fetches the index and computes it. Reply: `TRUE`.
#'
#' Also drops a `"failed"` index slot for that date's keys (CRAN's and
#' Bioconductor's), if one exists:
#' the Proposal stage of `schedule_packages()` only fetches a key with no
#' slot at all, so a failed fetch left in place would never be retried --
#' the user asking to preview again (the same "I want this to work now" as
#' `ev_run()` retrying a failed library or index, reduce_run()) is exactly
#' when a retry belongs.
reduce_preview_date <- function(state, event) {
  date_header <- state$file$header
  date_header$snapshot <- event$date
  date_header$bioc_version <- NA_character_
  for (key in needed_repos(date_header, state$options$r, releases_at(state$packages, event$date))) {
    slot <- state$packages$indexes[[key]]
    if (!is.null(slot) && identical(slot$status, "failed")) {
      state$packages$indexes[[key]] <- NULL
    }
  }
  state$packages$proposal <- new_proposal(event$date, apply = isTRUE(event$apply))
  list(state = state, effects = list(), reply = TRUE)
}

#' Drop the current preview without applying it (the in-tab question's
#' Cancel, `ember_cancel_update`). A no-op if there is none.
reduce_cancel_preview <- function(state, event) {
  state$packages$proposal <- NULL
  list(state = state, effects = list(), reply = NULL)
}

#' Apply the current proposal: `header$snapshot <- proposal$date`,
#' `set_lock(proposal$lock)`, `resolved_for <- wanted`, `proposal <-
#' NULL`. The restart, if a loaded package moved, follows from
#' `switch_library()` once the new library is ready. Pure; the caller
#' (`reduce_set_date()`, or `schedule_packages()`'s Proposal stage for an
#' `apply = TRUE` proposal that needs no restart) has already checked the
#' proposal is the one to apply.
#' @return `list(state, effects)`.
apply_proposal <- function(state) {
  p <- state$packages
  prop <- p$proposal
  wanted <- wanted_packages(state$graph, state$file$header)
  state$file$header$snapshot <- prop$date
  state$file$header$bioc_version <- prop$bioc_version %||% NA_character_
  state <- set_lock(state, prop$lock)
  state$packages$resolved_for <- wanted
  # The proposal's own resolution already computed `problems` for the new
  # date (`prop$lock`'s off_date/not_found/not_in_index rows); the old
  # date's `problems` describe a lock that no longer exists the moment this
  # applies, and leaving them in place showed stale complaints (a
  # since-fixed off_date row, say) next to the packages actually in effect.
  state$packages$problems <- rbind(prop$problems, bioc_problems(state$file$header, state$options$r,
                                                                 p$bioc_releases$table))
  state$packages$proposal <- NULL
  list(state = state, effects = list())
}

#' Apply a previewed date move. Refused unless `proposal` is ready, is for
#' `event$date`, and was computed for the current wanted set: the caller
#' must have seen exactly what changes. Reply: the applied `changes`.
reduce_set_date <- function(state, event) {
  p <- state$packages
  wanted <- wanted_packages(state$graph, state$file$header)
  prop <- p$proposal
  if (is.null(prop) || !identical(prop$date, event$date) || !identical(prop$status, "ready") ||
      !setequal(prop$for_wanted %||% character(), wanted)) {
    return(list(state = state, effects = list(),
               reply = refused("no ready, current preview for that date")))
  }
  changes <- prop$changes
  ap <- apply_proposal(state)
  list(state = ap$state, effects = ap$effects, reply = changes)
}

#' `wk_done` with `report$error$package` set (the worker saw R's
#' `packageNotFoundError`, which carries the name, so this is not a message
#' match and works in every locale):
#' * not in the lock, and not already wanted (not named in code or
#'   `[extra_packages]`): run error kind `"missing_package"`, `names = pkg`,
#'   fix "Add pkg to [extra_packages]" (the API op `add_extra_package()`);
#' * not in the lock, but already wanted: adding it to `[extra_packages]`
#'   again would do nothing (`schedule_packages()` already tried to resolve
#'   it and failed), so the fix would be a lie. The error points at the
#'   real reason instead: an unavailable index, or the resolver's own
#'   `not_found` problem for `pkg`.
#' * in the lock and `active` says it is installed: the library changed
#'   under us (cleaned by another process): `active$status <- "unknown"` and
#'   target likewise, so it is looked at again;
#' * in the lock, not installed: the install failed; the error points at the
#'   package status.
#' Called from `reduce_wk_done()`. Returns `list(state, error)` (the
#' sketch's signature only names the inputs; a reducer needs to update both
#' the state, for the "check again" case, and produce the run error).
missing_package_error <- function(state, pkg) {
  lock_entries <- state$file$lock$entries
  lock_names <- if (is.null(lock_entries) || nrow(lock_entries) == 0) character() else lock_entries$name

  if (!(pkg %in% lock_names)) {
    wanted <- wanted_packages(state$graph, state$file$header)
    if (!(pkg %in% wanted)) {
      err <- new_run_error("missing_package",
        message = sprintf("there is no package called '%s'", pkg),
        names = pkg,
        fixes = sprintf("Add %s to [extra_packages]", pkg))
      return(list(state = state, error = err))
    }
    probs <- state$packages$problems
    row <- if (!is.null(probs) && nrow(probs) > 0) {
      Find(function(i) identical(probs$kind[[i]], "index_unavailable") ||
             (identical(probs$kind[[i]], "not_found") && identical(probs$package[[i]], pkg)),
          seq_len(nrow(probs)))
    } else NULL
    msg <- if (!is.null(row)) {
      sprintf("there is no package called '%s': %s", pkg, probs$message[[row]])
    } else {
      sprintf("there is no package called '%s'", pkg)
    }
    err <- new_run_error("missing_package", message = msg, names = pkg, fixes = character())
    return(list(state = state, error = err))
  }

  if (pkg %in% names(state$packages$active$installed)) {
    # Only `target` goes back to "unknown" so `schedule_packages()`'s Look
    # stage checks the library again; `active` stays "ready" (check_state()'s
    # invariant) and the worker keeps running meanwhile. If the recheck finds
    # the package really is gone, `target` becomes "missing" and an install
    # follows the same way it would for a brand new package; until then the
    # worker is simply wrong about what it has, the same way any stale fact
    # on disk is (design.md, "Where the direction strains").
    if (identical(state$packages$target$key, state$packages$active$key)) {
      state$packages$target$status <- "unknown"
    }
    err <- new_run_error("missing_package",
      message = sprintf("there is no package called '%s'; the library will be checked again", pkg),
      names = pkg, fixes = character())
    return(list(state = state, error = err))
  }

  err <- new_run_error("missing_package",
    message = sprintf("there is no package called '%s'; its install may have failed", pkg),
    names = pkg, fixes = character())
  list(state = state, error = err)
}

# ---- Projection --------------------------------------------------------------

#' The packages part of the snapshot (and `package_status()`): plain data.
#'
#' `list(snapshot, r_version, bioc_version,
#'      library = list(status, path, progress, message, log, failures),
#'      packages = data.frame(name, version, source, direct, status, message),
#'      problems, proposal = NULL | list(date, status, changes, problems),
#'      plan = NULL | list(install = <n packages>, restart = <names>))`
#'
#' Per package `status`: `"installed"` (in `active$installed` at the locked
#' version), `"installing"`, `"missing"` (not installed; in safe preview
#' this is what the banner counts), `"failed"` (a package `install_failures()`
#' named, or a direct package that needs one of them), `"not_installed"`
#' (every other row of a library that failed: the staging folder is never
#' renamed into place, so nothing in that install actually landed, even
#' the packages that built fine), `"not_found"` (from `problems`, `version`
#' `NA`). `direct` is `TRUE` for wanted names. `plan` is what running would
#' do; the banner's "installs 3 packages" (a `"not_installed"` row counts
#' toward it exactly as `"missing"` does: running retries it).
#'
#' `library$log` is `target$log` (the installer's last lines) and
#' `library$failures` is `target$failures` (`install_failures()`'s
#' result) with a `needed_by` column added: for each failed package, the
#' wanted (direct) packages whose dependency closure reaches it, walked
#' through whatever indexes are loaded (`find_in_indexes()`, resolve.R) --
#' `character()` for a package when none are.
#' Empty, correctly typed `packages` data.frame: the shape both halves of
#' `packages_view()` build their rows into.
empty_packages_df <- function() {
  data.frame(name = character(), version = character(), source = character(),
            direct = logical(), status = character(), message = character(),
            stringsAsFactors = FALSE)
}

#' The wanted (direct) packages whose dependency closure reaches `pkg`,
#' walking from each root through `find_in_indexes()` (resolve.R) with
#' whatever indexes are loaded. A root is included when `pkg` is the root
#' itself (a direct package that failed names itself here too) or appears
#' anywhere in what it transitively depends on. No loaded index at all
#' means no closure can be walked, so the result is `character()`: still
#' correct, just less informative (install_failures()'s own finding is
#' unaffected).
failure_needed_by <- function(pkg, wanted, indexes, needed) {
  roots <- character()
  for (root in wanted) {
    seen <- character()
    queue <- root
    found <- FALSE
    while (length(queue) > 0) {
      cur <- queue[[1]]
      queue <- queue[-1]
      if (cur %in% seen) next
      seen <- c(seen, cur)
      if (identical(cur, pkg)) { found <- TRUE; break }
      hit <- find_in_indexes(cur, indexes, needed)
      if (!is.null(hit)) queue <- c(queue, hit$deps)
    }
    if (found) roots <- c(roots, root)
  }
  roots
}

packages_view <- function(state) {
  p <- state$packages
  wanted <- wanted_packages(state$graph, state$file$header)
  entries <- state$file$lock$entries
  installing <- !is.null(p$install) && identical(p$install$key, p$target$key)
  target_failed <- identical(p$target$status, "failed")

  # `needed_by` is already computed, once, by reduce_install_done(); a
  # hand-built `target$failures` with no such column (nothing in this
  # package's own code ever makes one that way, but a test might) reads
  # as empty rather than erroring on a missing `$needed_by`.
  failures <- p$target$failures %||% empty_install_failures()
  if (is.null(failures$needed_by)) failures$needed_by <- replicate(nrow(failures), character(), simplify = FALSE)
  needed_by_names <- if (target_failed) unique(unlist(failures$needed_by)) else character()
  failed_names <- if (target_failed) failures$package else character()

  # Built column-wise, not one `data.frame()` call per lock entry plus an
  # `rbind()` over all of them: that made `packages_view()` (and so
  # `notifications()`, which calls it on every dispatch that might have
  # changed anything package-related) quadratic-feeling in the number of
  # locked packages. Measured at 150 packages: 92 ms before, under the
  # engine's 30ms-for-`notifications()` budget after.
  locked_df <- if (is.null(entries) || nrow(entries) == 0) {
    empty_packages_df()
  } else {
    installed <- p$active$installed
    hit <- match(entries$name, names(installed))
    is_installed <- !is.na(hit) & entries$version == unname(installed)[hit]
    # Built with `status[...] <- ...` on a pre-sized vector, not nested
    # `ifelse()`: `installing`/`target_failed` are scalars, and nesting a
    # per-row vector as the "yes" branch of a scalar-tested `ifelse()`
    # collapses it to that one recycled element for every row (`ifelse()`'s
    # result length follows `test`, not the branch vectors).
    #
    # A failed library's staging folder is never renamed into place, so no
    # entry is actually installed: every row that isn't itself one of
    # `install_failures()`'s named packages, or a direct package that
    # needs one, reverts to "not_installed" rather than "failed" -- it
    # just never got as far as being attempted.
    status <- character(nrow(entries))
    pending <- !is_installed
    status[is_installed] <- "installed"
    status[pending & installing] <- "installing"
    if (target_failed) {
      failed_row <- entries$name %in% failed_names | entries$name %in% needed_by_names
      status[pending & !installing & failed_row] <- "failed"
      status[pending & !installing & !failed_row] <- "not_installed"
    } else {
      status[pending & !installing] <- "missing"
    }
    data.frame(name = entries$name, version = entries$version, source = entries$source,
              direct = entries$name %in% wanted, status = status,
              message = NA_character_, stringsAsFactors = FALSE)
  }

  not_found_df <- empty_packages_df()
  if (!is.null(p$problems) && nrow(p$problems) > 0) {
    nf <- p$problems[!is.na(p$problems$kind) & p$problems$kind == "not_found", , drop = FALSE]
    if (nrow(nf) > 0) {
      not_found_df <- data.frame(name = nf$package, version = NA_character_, source = NA_character_,
                                 direct = nf$package %in% wanted, status = "not_found",
                                 message = nf$message, stringsAsFactors = FALSE)
    }
  }
  packages_df <- rbind(locked_df, not_found_df)

  proposal <- NULL
  if (!is.null(p$proposal)) {
    proposal <- list(date = p$proposal$date, status = p$proposal$status,
                     changes = p$proposal$changes, problems = p$proposal$problems,
                     apply = isTRUE(p$proposal$apply), restart = p$proposal$restart %||% character(),
                     message = p$proposal$message, kind = p$proposal$kind %||% "date")
  }
  # A Bioconductor move that failed isn't the page's update question
  # (`project_ember()`), so it is said as a problem instead. Where an
  # unpinned notebook found no Bioconductor release (`bioc_unavailable`)
  # because the release list was missing or too old for its date, that is
  # the reason given; a CRAN-only or pinned notebook never gets the row.
  problems <- p$problems
  gap <- releases_gap_message(p, state$file$header$snapshot)
  if (!is.null(gap) && any(problems$kind == "bioc_unavailable")) {
    problems <- rbind(problems[problems$kind != "bioc_unavailable", , drop = FALSE],
                      package_problem("bioc_releases_unavailable", NA_character_,
                                      paste("Bioconductor packages can't be resolved:", gap)))
  }
  if (!is.null(p$proposal) && identical(p$proposal$kind, "bioc") && identical(p$proposal$status, "failed")) {
    problems <- rbind(problems, package_problem("bioc_move_failed", NA_character_, sprintf(
      "couldn't move to the Bioconductor release for R %s: %s", state$options$r$minor,
      p$proposal$message %||% "no package index available")))
  }

  missing_n <- sum(packages_df$status %in% c("missing", "not_installed"))
  restart_names <- character()
  if (identical(p$target$status, "ready") && !identical(p$target$key, p$active$key)) {
    conf <- library_conflicts(state$worker$loaded %||% character(), p$target$installed)
    restart_names <- conf$name
  }
  plan <- if (missing_n > 0 || length(restart_names) > 0) {
    list(install = missing_n, restart = restart_names)
  } else {
    NULL
  }

  list(snapshot = state$file$header$snapshot, r_version = state$file$header$r_version,
      bioc_version = state$file$header$bioc_version,
      library = list(status = p$target$status, path = p$target$path,
                    progress = p$target$progress, message = p$target$message,
                    log = p$target$log, failures = failures),
      packages = packages_df, problems = problems, proposal = proposal, plan = plan)
}
