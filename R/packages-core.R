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
#' * `sources_for`: the header's readable `[sources]` (`readable_sources()`)
#'   the current lock answers, as `resolved_for` is for the wanted set:
#'   resolution runs again when they differ, and a package whose spec
#'   changed is resolved again from its new spec (`lock_for_sources()`).
#'   Set at open to the header's own.
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
#' * `cran_releases`: `list(status, table, message)`, every CRAN version's
#'   release date (`cran_release_table()`), fetched when a per-package
#'   update first needs it. `status`: `"unknown"`, `"fetching"`, `"ready"`
#'   or `"failed"`.
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
  # A lock that disagrees with the header's `[sources]` (a source added,
  # changed or removed by hand) is resolved again, as one missing a name is.
  sources_for <- if (is.null(header)) character() else readable_sources(header)
  agrees <- is.null(header) || identical(lock_for_sources(lock, header, sources_for)$entries, lock$entries)
  resolved_for <- if (all(wanted %in% locked_names) && agrees) wanted else character()
  # A pin built for another R is said at open, in safe preview, before
  # running the notebook moves it (design.md, "R itself"); resolution
  # doesn't run at open for a file Ember wrote, so nothing else would. With
  # the release list still to fetch, `reduce_bioc_releases_fetched()` says it.
  problems <- if (is.null(header)) empty_package_problems() else {
    rbind(bioc_problems(header, r, releases$table), source_problems(header))
  }
  structure(list(
    resolved_for = resolved_for,
    sources_for = sources_for,
    indexes = list(),
    problems = problems,
    target = target,
    active = active,
    install = NULL,
    proposal = NULL,
    bioc_releases = releases,
    cran_releases = new_cran_releases_slot(),
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
#' offline). `provisional`: a ready index of a date so recent that
#' Package Manager may still add to it (`index_may_change()`, library.R),
#' fetched again by a date preview (#39).
new_index_slot <- function(status, index = NULL, message = NULL, wanted = NULL, provisional = FALSE) {
  structure(list(status = status, index = index, message = message, wanted = wanted,
                 provisional = provisional),
            class = "ember_index_slot")
}

#' CRAN's release dates as the session knows them (`cran_release_table()`).
new_cran_releases_slot <- function(status = "unknown", table = NULL, message = NULL) {
  list(status = status, table = table, message = message)
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
  data.frame(package = character(), kind = character(), detail = character(), libraries = character(),
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
#' -> data.frame(package, kind, detail, libraries): `libraries` is the
#'    system libraries not found (", "-separated) on the rows the installer's
#'    system-library check made (for "newer_system", those that are too
#'    old), `NA` otherwise; kind "missing_compiler" (the
#'    installer's own compiler check, an `EMBER-MISSING compiler` line, or
#'    while a package builds from source a line saying the compiler itself
#'    isn't there: `compiler_patterns` below; detail = what to install,
#'    `compiler_instructions()`), "missing_system" (the installer's
#'    system-library check, `EMBER-MISSING system`; detail = the command
#'    that installs every package's, the same on each row),
#'    "library_version" (`EMBER-MISSING soname`, #76: a library it was
#'    built against is here only as another version; libraries = the ones
#'    it wants, detail = the versions this system has), "newer_system"
#'    (`EMBER-MISSING newer`, #76: built for a newer system; detail = the
#'    symbol versions it needs, `GLIBC_2.38`, libraries = the libraries
#'    here that lack them), "symbol_version" (`EMBER-MISSING symbols`,
#'    #76: a library's own symbol versions, `CURL_OPENSSL_4`, that the
#'    copy here lacks; detail and libraries as for "newer_system"),
#'    "system" (an
#'    `EMBER-MISSING library` line, detail = the libraries not found; or,
#'    while a package
#'    builds from source, a line saying a system library or header is
#'    missing: `system_patterns` below; detail = that line), "compile" ("ERROR:
#'    compilation failed for package", or "ERROR: loading failed" after a
#'    source build), "configure" ("ERROR: configuration
#'    failed"), "dependency" ("ERROR: dependency 'x' is not available",
#'    detail = x; or renv's summary line "dependency failed (x, y)",
#'    detail = x), "download" (a summary line, or renv's own "error
#'    downloading"/"failed to retrieve", naming the package),
#'    "no_binary" (a "compile", "configure" or "other" row whose package
#'    the installer's `EMBER-MISSING binary` line says had no binary for
#'    this R, so it was built from source: most often a snapshot date from
#'    before this R, #19; detail = the locked version),
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
#' Best effort, not a contract: renv's and R's own text
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

  pkg <- character(); kind <- character(); detail <- character(); libs <- character()
  add <- function(p, k, d, l = NA_character_) {
    libs[length(libs) + 1L] <<- l
    pkg[length(pkg) + 1L] <<- strip_version(p)
    kind[length(kind) + 1L] <<- k
    detail[length(detail) + 1L] <<- d
  }

  # A missing system library shows up between a package's "* installing
  # *source* package" line and its own ERROR line, in a few unmistakable
  # shapes: an anticonf message (xml2, curl, openssl), configure's own
  # "not found", a missing shared object, or gcc's missing header.
  system_patterns <- c("Configuration failed because .* was not found",
                       "^configure: error: .*(not found|cannot find)",
                       "cannot open shared object file",
                       "fatal error: [^ ]+\\.h: No such file or directory")
  # The compiler itself missing, while a package builds: make or the shell
  # can't run it, configure finds none, or (macOS) the command line tools
  # aren't installed.
  compiler_patterns <- c("(^|[ /])(gcc|g\\+\\+|cc|c\\+\\+|clang|clang\\+\\+|gfortran|f95)(-[0-9.]+)?: (No such file or directory|command not found|not found)$",
                         "^configure: error: no acceptable C compiler found",
                         # A compiler is named (often a stub or a broken
                         # toolchain) but can't link anything.
                         "compiler cannot create executables",
                         "^xcrun: error: invalid active developer path")
  building <- NA_character_

  no_binary <- character()
  for (line in lines) {
    if (grepl("^EMBER-MISSING binary [A-Za-z0-9.]+ ", line)) {
      m <- regmatches(line, regexec("^EMBER-MISSING binary ([A-Za-z0-9.]+) (\\S+)", line))[[1]]
      no_binary[[m[[2]]]] <- m[[3]]
      next
    }
    if (grepl("^EMBER-MISSING (newer|symbols) [A-Za-z0-9.]+ ", line)) {
      m <- regmatches(line, regexec("^EMBER-MISSING (newer|symbols) ([A-Za-z0-9.]+) (\\S+) (.*)$", line))[[1]]
      if (length(m) == 5) {
        add(m[[3]], if (m[[2]] == "newer") "newer_system" else "symbol_version",
            gsub(",", ", ", m[[4]]), gsub(",", ", ", m[[5]]))
      }
      next
    }
    if (grepl("^EMBER-MISSING soname [A-Za-z0-9.]+ ", line)) {
      m <- regmatches(line, regexec("^EMBER-MISSING soname ([A-Za-z0-9.]+) (\\S+)$", line))[[1]]
      if (length(m) == 3) {
        pairs <- strsplit(strsplit(m[[3]], ";", fixed = TRUE)[[1]], "=", fixed = TRUE)
        add(m[[2]], "library_version",
            paste(gsub(",", ", ", vapply(pairs, function(p) p[[2]] %||% "", "")), collapse = ", "),
            paste(vapply(pairs, `[[`, "", 1L), collapse = ", "))
      }
      next
    }
    if (grepl("^EMBER-MISSING (compiler|system|library) [A-Za-z0-9.]+ ", line)) {
      m <- regmatches(line, regexec("^EMBER-MISSING (compiler|system|library) ([A-Za-z0-9.]+) (.*)$", line))[[1]]
      k <- switch(m[[2]], compiler = "missing_compiler", system = "missing_system", library = "system")
      if (identical(m[[2]], "compiler")) {
        add(m[[3]], k, m[[4]])
      } else {
        # `<libs>` or `<libs> <command>`, the libraries comma-separated.
        l <- sub(" .*$", "", m[[4]])
        rest <- if (grepl(" ", m[[4]])) sub("^\\S+ ", "", m[[4]]) else NA_character_
        add(m[[3]], k, if (identical(m[[2]], "library")) paste(gsub(",", ", ", l), "not found") else rest,
            gsub(",", ", ", l))
      }
      next
    }
    if (grepl("^\\* installing \\*source\\* package '[^']+'", line)) {
      building <- capture("^\\* installing \\*source\\* package '([^']+)'", line)
      next
    }
    if (!is.na(building) && any(vapply(compiler_patterns, grepl, logical(1), x = line, ignore.case = TRUE))) {
      add(building, "missing_compiler",
          compiler_instructions(fortran = grepl("fortran|f95", line, ignore.case = TRUE)))
      next
    }
    if (!is.na(building) && any(vapply(system_patterns, grepl, logical(1), x = line, ignore.case = TRUE))) {
      add(building, "system", line)
      next
    }
    if (grepl("^ERROR: [a-z]+ failed for package '[^']+'", line) || grepl("^\\* DONE \\(", line)) {
      building <- NA_character_
    }
    if (!is.na(building) && grepl("^ERROR: loading failed", line)) {
      # Built, but the result doesn't load: a C API this R removed
      # (`undefined symbol`). A failed build like the ones below.
      add(building, "compile", NA_character_)
      building <- NA_character_
    } else if (grepl("^ERROR: compilation failed for package '[^']+'", line)) {
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
      if (grepl("^dependency failed \\(", reason)) {
        # A package renv never built because one it needs failed:
        # "dependency failed (cli, rlang)". Named by the first.
        add(name, "dependency", trimws(sub(",.*$", "", sub("^dependency failed \\(([^)]*)\\).*$", "\\1", reason))))
      } else if (grepl("retriev|download", reason, ignore.case = TRUE)) {
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
  # (a missing compiler or system library, then compile/configure/
  # dependency, before the catch-all summary line).
  kind_rank <- c(missing_compiler = 0L, missing_system = 0L, library_version = 1L, newer_system = 1L, symbol_version = 1L,
                 system = 1L, compile = 2L,
                 configure = 3L, dependency = 4L, download = 5L, unavailable = 6L, other = 7L)
  df <- data.frame(package = pkg, kind = kind, detail = detail, libraries = libs, stringsAsFactors = FALSE)
  df <- df[order(kind_rank[df$kind]), ]
  df <- df[!duplicated(df$package), ]
  # A package that failed to build and had no binary for this R (the
  # installer's `EMBER-MISSING binary` line, after renv): the build's own
  # reason is a symptom, so the row says why it was built at all. A
  # missing compiler or system library, a dependency or a download stay
  # what they are.
  upgrade <- df$package %in% names(no_binary) & df$kind %in% c("compile", "configure", "other")
  df$kind[upgrade] <- "no_binary"
  df$detail[upgrade] <- unname(no_binary[df$package[upgrade]])
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
#' * `asked`: the date the preview was asked for. It differs from `date`
#'   only when that day wasn't published yet and the preview moved back to
#'   the newest one that is (`reduce_index_failed()`, #162), so
#'   `preview_date()` can find its own preview.
new_proposal <- function(date, status = "fetching", lock = NULL, changes = NULL,
                         problems = NULL, for_wanted = NULL, apply = FALSE,
                         restart = character(), message = NULL,
                         bioc_version = NA_character_, kind = "date", update = NULL, asked = date) {
  structure(list(date = date, status = status, lock = lock, changes = changes,
                 problems = problems, for_wanted = for_wanted, apply = apply,
                 restart = restart, message = message, bioc_version = bioc_version,
                 kind = kind, update = update, asked = asked),
            class = "ember_proposal")
}

# ---- Events and effects ------------------------------------------------------

# From the API
#' `apply = TRUE`: `reduce_preview_date()` stores it on the proposal, and
#' `schedule_packages()`'s Proposal stage applies the result itself once
#' it is ready, unless doing so would restart a loaded package.
ev_preview_date <- function(date, at, apply = FALSE) event("preview_date", at, date = date, apply = apply)
ev_set_date     <- function(date, at) event("set_date", at, date = date)
#' Preview moving the date so that `name` is at `version` (`NULL`: CRAN's
#' newest), `preview_update()`. `today`: the caller's date, since the core
#' has no clock; no snapshot is later.
ev_preview_update <- function(name, version, today, at)
  event("preview_update", at, name = name, version = version, today = as.Date(today))
#' Drop the current preview without applying it (the page's Cancel on the
#' in-tab update question).
ev_cancel_preview <- function(at) event("cancel_preview", at)
# `edit_notebook()` ops, applied by reduce_apply() with the others:
#   add_extra_package(name), remove_extra_package(name)

# From the shell's jobs
#' `provisional`: the shell's word that the index's date is recent enough
#' to change (`index_may_change()`); the core has no clock to judge it.
ev_index_fetched <- function(key, index, at, provisional = FALSE)
  event("index_fetched", at, key = key, index = index, provisional = isTRUE(provisional))
#' `unpublished`: the shell's word that the repository answered 404 for a
#' date recent enough to be one it hasn't published yet (#162); the core
#' has no clock to judge either.
ev_index_failed  <- function(key, message, at, unpublished = FALSE)
  event("index_failed", at, key = key, message = message, unpublished = isTRUE(unpublished))
#' `table`: `parse_bioc_config()`'s result, as fetched (or cached).
#' `fetched`: the day that list was fetched, a `Date` (a cached copy's own
#' day, not today's).
ev_bioc_releases_fetched <- function(table, fetched, at)
  event("bioc_releases_fetched", at, table = table, fetched = fetched)
ev_bioc_releases_failed  <- function(message, at) event("bioc_releases_failed", at, message = message)
ev_cran_releases_fetched <- function(table, at) event("cran_releases_fetched", at, table = table)
ev_cran_releases_failed  <- function(message, at) event("cran_releases_failed", at, message = message)
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

#' `fresh`: asked for by a date preview, so the shell fetches again when the
#' saved copy may have changed since (`index_may_change()`, #39).
fx_fetch_index    <- function(key, url, fresh = FALSE) effect("fetch_index", key = key, url = url, fresh = fresh)
#' Fetch Bioconductor's release list from `url` (`ember_repos(bioc_config)`),
#' or read it from the disk cache when it is less than a day old and was
#' fetched no earlier than `date` (the snapshot date it must cover).
fx_fetch_bioc_config <- function(url, date) effect("fetch_bioc_config", url = url, date = date)
fx_fetch_cran_releases <- function(url) effect("fetch_cran_releases", url = url)
fx_check_library  <- function(key, path) effect("check_library", key = key, path = path)
#' `lock` and `repos` are everything the installer needs; it writes the
#' renv lockfile itself (lock.R, `renv_lockfile_of()`). `repos` is the
#' dated mapping `repo_urls()` builds (name -> dated URL), not the raw
#' `ember_repos` value: `renv_lockfile_of()` writes it straight into the
#' lockfile's `Repositories`, which `Source = "Repository"` entries resolve
#' against by name ("CRAN", "BioCsoft").
#' `github` is the GitHub API the lock's GitHub packages install from
#' (`github_api_url()`).
fx_install        <- function(token, key, path, lock, repos, github = "https://api.github.com")
  effect("install", token = token, key = key, path = path, lock = lock, repos = repos, github = github)
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
    sources <- readable_sources(state$file$header)
    if (!setequal(wanted, p$resolved_for) || !identical(sources, p$sources_for %||% character())) {
      if (length(wanted) > 0 && (is.null(state$file$header$snapshot) || is.na(state$file$header$snapshot))) {
        # `format()` on a POSIXct uses the local time zone directly; routing
        # through `as.Date()` first would convert to UTC (its default `tz`)
        # before taking the date, giving the wrong day for anyone not on
        # UTC near midnight. `state$clock` may also already be a bare
        # `Date` (tests, `ev_open(as.Date(...))`), for which `format()`
        # behaves the same either way.
        state$file$header$snapshot <- format(state$clock, "%Y-%m-%d")
      }
      repos_needed <- needed_repos(state$file$header, state$options$r,
                                   releases_at(p, state$file$header$snapshot))
      # The `[sources]` GitHub keys come first, so a package with a source
      # comes from it, never from CRAN; they and CRAN's index are fetched up
      # front. The Bioconductor keys after CRAN are fetched when
      # `resolve_lock()` asks for them (a name CRAN lacks). A later key that
      # failed is retried once the wanted set changes; until then it is left
      # out of `needed`, so its names resolve as not found instead of
      # waiting on it forever.
      gh <- source_keys(state$file$header, state$file$lock, p$sources_for %||% character())
      upfront <- c(unname(gh), repos_needed[1])
      later <- repos_needed[-1]
      needed <- c(unname(gh), repos_needed)
      refetch <- function(k) {
        slot <- p$indexes[[k]]
        identical(slot$status, "failed") && !setequal(slot$wanted %||% character(), wanted)
      }
      # A later key's failed slot is dropped rather than refetched, so it is
      # fetched again only if `resolve_lock()` still asks for it.
      for (k in Filter(refetch, later)) p$indexes[[k]] <- NULL
      to_fetch <- Filter(function(k) is.null(p$indexes[[k]]) || refetch(k), upfront)
      for (k in to_fetch) {
        p$indexes[[k]] <- new_index_slot("fetching")
        effects <- c(effects, list(fx_fetch_index(k, repo_url(state$options$repos, k))))
      }
      if (length(to_fetch) == 0 && length(needed) > 0) {
        first <- p$indexes[[repos_needed[[1]]]]
        up_status <- vapply(upfront, function(k) p$indexes[[k]]$status %||% "missing", character(1))
        loaded_gh <- lapply(p$indexes[unname(gh)], function(s) s$index)
        mismatch <- source_problems(state$file$header, gh, loaded_gh)
        mismatch <- mismatch[mismatch$package %in% names(gh), , drop = FALSE]
        if (all(up_status == "ready") && nrow(mismatch) > 0) {
          # A source holding another package than the one it was written
          # for: resolving would silently take that name from CRAN instead.
          p$problems <- mismatch
        } else if (all(up_status == "ready")) {
          failed <- Filter(function(k) identical(p$indexes[[k]]$status, "failed"), later)
          usable <- setdiff(needed, failed)
          loaded_idx <- Filter(Negate(is.null), lapply(p$indexes[usable], function(s) s$index))
          res <- resolve_lock(wanted, lock_for_sources(state$file$lock, state$file$header,
                                                       p$sources_for %||% character()),
                              loaded_idx, needed = usable, mode = "keep")
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
            p$sources_for <- sources
            p$problems <- rbind(res$problems, source_problems(state$file$header),
                                failed_index_problems(p$indexes[failed]),
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
        } else if (!any(up_status == "fetching") && any(up_status == "failed")) {
          p$problems <- empty_package_problems()
          if (!is.null(first) && identical(first$status, "failed")) {
            p$problems <- data.frame(kind = "index_unavailable", package = NA_character_,
                                     message = first$message %||% "no package index available",
                                     fixes = NA_character_, stringsAsFactors = FALSE)
          }
          p$problems <- rbind(p$problems, source_failed_problems(state$file$header, gh, p$indexes))
        }
      }
    }
  }
  state$packages <- p

  # ---- 2. Proposal --------------------------------------------------------
  state <- propose_bioc_move(state)
  # An update that moves to the next day (`step_update()`) goes round
  # again, so a snapshot already fetched is resolved at once.
  repeat {
    stepped <- FALSE
    # A proposal waiting on CRAN's release dates has no date yet.
    if (!is.null(state$packages$proposal) && !identical(state$packages$proposal$status, "dates") &&
        !is.na(state$packages$proposal$date)) {
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
      # GitHub packages have no date: moving it back keeps the commits the
      # lock holds, and moving it forward asks branches again
      # (`source_keys()`, `refreshes_sources()`).
      sources_for <- state$packages$sources_for %||% character()
      gh <- unname(source_keys(state$file$header, state$file$lock, sources_for,
                               refresh = refreshes_sources(state$file$header, prop$date, prop$kind)))
      repos_needed <- needed_repos(date_header, state$options$r, releases)
      needed <- c(gh, repos_needed)
      key <- repos_needed[[1]]
      upfront <- c(gh, key)
      unfetched <- Filter(function(k) is.null(state$packages$indexes[[k]]), upfront)
      # The up-front keys as one slot: missing (`NULL`) until each has been
      # asked for, then failed if any failed, ready once all are.
      slot <- if (length(unfetched) > 0) NULL else {
        statuses <- vapply(upfront, function(k) state$packages$indexes[[k]]$status, character(1))
        bad <- upfront[statuses == "failed"]
        if (length(bad) > 0) {
          state$packages$indexes[[bad[[1]]]]
        } else if (all(statuses == "ready")) {
          state$packages$indexes[[key]]
        } else {
          new_index_slot("fetching")
        }
      }
      failed <- Filter(function(k) identical(state$packages$indexes[[k]]$status, "failed"), repos_needed[-1])
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
        for (k in unfetched) {
          state$packages$indexes[[k]] <- new_index_slot("fetching")
          effects <- c(effects, list(fx_fetch_index(k, repo_url(state$options$repos, k), fresh = TRUE)))
        }
      } else if (identical(slot$status, "ready") && !is.null(drop_message)) {
        state$packages$proposal <- new_proposal(prop$date, status = "failed", apply = prop$apply,
                                                message = drop_message, kind = prop$kind,
                                                asked = prop$asked %||% prop$date)
      } else if (identical(slot$status, "ready") &&
                (identical(prop$status, "fetching") || !setequal(prop$for_wanted %||% character(), wanted))) {
        indexes_loaded <- Filter(Negate(is.null), lapply(state$packages$indexes[needed], function(s) s$index))
        res <- resolve_lock(wanted, lock_for_sources(state$file$lock, state$file$header, sources_for),
                            indexes_loaded, needed = needed, mode = if (is_move) "bioc" else "fresh")
        if (needs_bioc(res) && releases_unsettled(state$packages, prop$date)) {
          fr <- fetch_releases(state$packages, state$options, prop$date)
          state$packages <- fr$p
          effects <- c(effects, fr$effects)
        } else if (isTRUE(res$complete) && !is.null(prop$update) &&
                   !identical(got <- unname(lock_versions(res$lock)[prop$update$name]), prop$update$version)) {
          # An update whose date's snapshot doesn't have the version asked
          # for (taken before the release reached it): the next day.
          nxt <- step_update(state, prop, got)
          if (is.null(nxt)) {
            state$packages$proposal <- new_proposal(prop$date, status = "failed", message = update_failed_message(prop, got),
                                                    kind = prop$kind, update = prop$update, asked = prop$asked %||% prop$date)
          } else {
            state <- nxt
            stepped <- TRUE
          }
        } else if (isTRUE(res$complete)) {
          changes <- lock_diff(state$file$lock, res$lock)
          new_prop <- new_proposal(prop$date, status = "ready", lock = res$lock, changes = changes,
                                   problems = res$problems, for_wanted = wanted, apply = prop$apply,
                                   bioc_version = bioc_pin(res$lock, bioc_release_in(needed)),
                                   kind = prop$kind, update = prop$update, asked = prop$asked %||% prop$date)
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
              effects <- c(effects, list(fx_fetch_index(k, repo_url(state$options$repos, k), fresh = TRUE)))
            }
          }
        }
      } else if (identical(slot$status, "failed")) {
        state$packages$proposal <- new_proposal(prop$date, status = "failed", apply = prop$apply,
                                                message = slot$message, kind = prop$kind,
                                                asked = prop$asked %||% prop$date)
      }
    }
    if (!stepped) break
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
                                          repo_urls(state$options$repos, state$file$header, state$file$lock),
                                          github_api_url(state$options$repos))))
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

#' One `index_unavailable` row per `[sources]` package whose GitHub index
#' (`keys`: package -> key, `source_keys()`) failed, naming the source.
source_failed_problems <- function(header, keys, indexes) {
  out <- empty_package_problems()
  for (name in names(keys)) {
    slot <- indexes[[keys[[name]]]]
    if (!identical(slot$status, "failed")) next
    out <- rbind(out, package_problem("index_unavailable", name, sprintf(
      "couldn't look up %s for %s: %s", header$sources[[name]], name,
      slot$message %||% "no answer")))
  }
  out
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
#' A cell can also wait without naming a package (#67). Edges to a
#' package's exports come from the installed package, so before
#' `library(dplyr)` is installed, a cell calling `summarise()` has no edge
#' to it and would run, fail with "could not find function", and rerun
#' once the install brings the edge. So while a waiting cell attaches a
#' package whose exports aren't known yet, any other cell with a reference
#' that resolves to nothing (no edge, not a base R name) waits for those
#' packages too, with its downstream. A cell whose references all resolve
#' still runs. A typo or a column name read through non-standard
#' evaluation also holds its cell until the install ends: too long a wait
#' rather than a false error. The hold lasts as long as the attaching cell's
#' own wait, which is almost always an install; the rare exception is a
#' Bioconductor move held for an answer (`bioc_move_pending()`).
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

  # Packages that waiting cells attach and whose exports the graph doesn't
  # have yet: until they install, a reference with no edge may be theirs.
  unknown <- unique(unlist(lapply(names(direct), function(id) {
    intersect(direct[[id]], state$graph$cells[[id]]$attaches)
  }), use.names = FALSE))
  unknown <- setdiff(unknown, names(state$graph$exports))
  if (length(unknown) > 0) {
    edges <- state$graph$edges
    known <- base_names()
    for (id in setdiff(runnable_ids, names(direct))) {
      refs <- state$graph$cells[[id]]$references
      if (length(refs) == 0) next
      unresolved <- setdiff(refs, c(edges$name[edges$from == id], known))
      if (length(unresolved) > 0) direct[[id]] <- unknown
    }
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
  state$packages$indexes[[event$key]] <- new_index_slot("ready", index = event$index,
                                                        provisional = isTRUE(event$provisional))
  # A failed install waiting on this index to say which direct packages
  # need each failed one (#17).
  state <- fill_needed_by(state)$state
  list(state = state, effects = list(), reply = NULL)
}

reduce_index_failed <- function(state, event) {
  slot <- state$packages$indexes[[event$key]]
  if (is.null(slot) || !identical(slot$status, "fetching")) {
    return(list(state = state, effects = list(), reply = NULL))
  }
  header <- state$file$header
  # The notebook's own date isn't published yet (a new notebook dated
  # today, before Package Manager has that day's snapshot, #162). While
  # nothing is locked, no package came from that date, so the date moves
  # back a day and resolution fetches that one. The shell says
  # `unpublished` only from yesterday to tomorrow in UTC
  # (`may_be_unpublished()`), so this stops by the day before yesterday,
  # and then the failure shows; a date further ahead fails at once.
  if (isTRUE(event$unpublished) && nrow(state$file$lock$entries) == 0 &&
      !is.null(header$snapshot) && !is.na(header$snapshot) &&
      identical(event$key, repo_key("cran", header$snapshot))) {
    state$packages$indexes[[event$key]] <- NULL
    state$file$header$snapshot <- format(as.Date(header$snapshot) - 1, "%Y-%m-%d")
    return(list(state = state, effects = list(), reply = NULL))
  }
  # A date preview of a day that isn't published yet ("Update all" is a
  # preview of today) moves back a day the same way, so it offers the
  # newest published date instead of failing with no changes. The same
  # bound applies. Not for one package's update (`prop$update`): its date
  # is where that version is, and the day before doesn't have it.
  prop <- state$packages$proposal
  if (isTRUE(event$unpublished) && !is.null(prop) && identical(prop$kind, "date") && is.null(prop$update) &&
      identical(prop$status, "fetching") && identical(event$key, repo_key("cran", prop$date))) {
    state$packages$indexes[[event$key]] <- NULL
    earlier <- format(as.Date(prop$date) - 1, "%Y-%m-%d")
    # The earlier day may still be gaining packages too: a copy this
    # session holds from before is fetched again, as reduce_preview_date()
    # does for the date asked.
    held <- state$packages$indexes[[repo_key("cran", earlier)]]
    if (isTRUE(held$provisional) && identical(held$status, "ready")) {
      state$packages$indexes[[repo_key("cran", earlier)]] <- NULL
    }
    state$packages$proposal <- new_proposal(earlier,
                                            apply = prop$apply, kind = prop$kind,
                                            asked = prop$asked %||% prop$date)
    return(list(state = state, effects = list(), reply = NULL))
  }
  wanted <- wanted_packages(state$graph, header)
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
#' naming its `package`, and `failures$needed_by` (`fill_needed_by()`,
#' which may fetch indexes to walk); falls back to today's single `NA`-package row
#' only when `event$failures` has none (the installer's output didn't
#' parse). An old key's result is dropped: the library exists on disk and
#' costs nothing until cleanup.
reduce_install_done <- function(state, event) {
  inst <- state$packages$install
  if (is.null(inst) || !eq(inst$token, event$token)) return(list(state = state, effects = list(), reply = NULL))
  state$packages$install <- NULL
  effects <- list()
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
      tgt$progress <- NULL
      state$packages$target <- tgt
      walked <- fill_needed_by(state, fetch = TRUE)
      state <- walked$state
      effects <- walked$effects
      tgt <- state$packages$target
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
  list(state = state, effects = effects, reply = NULL)
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
  keys <- c(unname(source_keys(state$file$header, state$file$lock,
                               state$packages$sources_for %||% character(),
                               refresh = refreshes_sources(state$file$header, event$date))),
            needed_repos(date_header, state$options$r, releases_at(state$packages, event$date)))
  for (key in keys) {
    slot <- state$packages$indexes[[key]]
    # A branch's index read earlier in this session is dropped too, so the
    # preview asks GitHub where the branch is now; so is a provisional one
    # (today's), for what Package Manager has added since (#39). The
    # proposal stage asks for every index it fetches `fresh`, so the shell
    # skips a saved copy that may have changed since, such as one another
    # notebook saved this morning; the core has no clock to tell which.
    moving <- is_moving_source_key(key)
    provisional <- isTRUE(slot$provisional) && identical(slot$status, "ready")
    if (!is.null(slot) && (identical(slot$status, "failed") || moving && identical(slot$status, "ready") || provisional)) {
      state$packages$indexes[[key]] <- NULL
    }

  }
  state$packages$proposal <- new_proposal(event$date, apply = isTRUE(event$apply))
  list(state = state, effects = list(), reply = TRUE)
}

#' The date that puts `name` at `version` (`NULL`: the newest), from
#' `cran_release_table()`'s rows, for a notebook whose lock has `name` at
#' `from`. Each version was current from its release to the day before the
#' next one (design.md, "Updating one package"):
#' * a newer version takes the first day it was current, so the other
#'   packages move only as far as they must;
#' * an older one (a pin) takes the last day it was current, so they move
#'   back as little as they can.
#' Package Manager takes its snapshots at a set time, so a day's snapshot
#' can lack a release from that day: `step` is the way to try the next
#' snapshot (+1 or -1 day), up to `last`, the other end of the span (`NA`:
#' none, the newest version). Pure. Returns `list(version, date, step,
#' last)`, or `list(message)` when there is no such date.
update_date <- function(table, name, version, from) {
  rows <- if (is.null(table)) NULL else table[table$package == name, , drop = FALSE]
  if (is.null(rows) || nrow(rows) == 0) {
    return(list(message = sprintf("CRAN has no record of a package called '%s'", name)))
  }
  version <- version %||% rows$version[[nrow(rows)]]
  i <- match(version, rows$version)
  if (is.na(i)) return(list(message = sprintf("CRAN never released %s %s", name, version)))
  if (identical(version, from)) return(list(message = sprintf("%s is already at %s", name, version)))
  first <- rows$date[[i]]
  end <- if (i < nrow(rows)) rows$date[[i + 1L]] - 1 else as.Date(NA)
  if (!is.na(end) && end < first) {
    return(list(message = sprintf("%s %s was replaced by %s the day it came out, so no snapshot has it",
                                  name, version, rows$version[[i + 1L]])))
  }
  newer <- is.na(from) || package_version(version) > package_version(from)
  if (newer) list(version = version, date = first, step = 1L, last = end)
  else list(version = version, date = end, step = -1L, last = first)
}

#' How many snapshots an update tries past the first date `update_date()`
#' gives before it gives up: a release reaches Package Manager the same day
#' or the next.
update_tries <- 3L

#' Preview moving the date so that `event$name` is at `event$version`.
#' Refused unless the lock has `name` from CRAN: Bioconductor and GitHub
#' packages have no CRAN dates. With CRAN's release dates not yet known,
#' fetches them first (the proposal waits with status `"dates"`); then
#' `start_update()` turns the version into a date and previews that date
#' as `preview_date()` does. Reply: `TRUE`.
reduce_preview_update <- function(state, event) {
  entries <- state$file$lock$entries
  row <- if (is.null(entries)) integer() else which(entries$name == event$name)
  if (length(row) == 0) {
    return(list(state = state, effects = list(),
                reply = refused(sprintf("%s is not in this notebook's packages", event$name))))
  }
  if (!identical(entries$source[[row]], "CRAN")) {
    return(list(state = state, effects = list(),
                reply = refused(sprintf("%s comes from %s, not CRAN", event$name, entries$source[[row]]))))
  }
  update <- list(name = event$name, version = event$version, from = entries$version[[row]],
                 today = event$today)
  effects <- list()
  rel <- state$packages$cran_releases
  if (identical(rel$status, "ready")) {
    state <- start_update(state, update)
  } else {
    state$packages$proposal <- new_proposal(NA_character_, status = "dates", update = update)
    if (!identical(rel$status, "fetching")) {
      state$packages$cran_releases <- new_cran_releases_slot("fetching")
      effects <- list(fx_fetch_cran_releases(state$options$repos$cran_meta))
    }
  }
  list(state = state, effects = effects, reply = TRUE)
}

#' With CRAN's release dates known: the date for `update`, previewed as
#' `preview_date()` previews one, with `update` on the proposal so the
#' Proposal stage of `schedule_packages()` can check the version it gets
#' (`step_update()`). A version with no date fails the proposal.
start_update <- function(state, update) {
  d <- update_date(state$packages$cran_releases$table, update$name, update$version, update$from)
  if (!is.null(d$message)) {
    state$packages$proposal <- new_proposal(NA_character_, status = "failed", message = d$message,
                                            update = update)
    return(state)
  }
  update$version <- d$version
  update$step <- d$step
  update$last <- d$last
  update$tries <- 0L
  # A date past today has no snapshot yet; a release from today may not.
  date <- min(d$date, update$today)
  preview_update_at(state, date, update)
}

preview_update_at <- function(state, date, update) {
  state <- reduce_preview_date(state, list(date = format(date, "%Y-%m-%d"), apply = FALSE))$state
  state$packages$proposal$update <- update
  state
}

#' The proposal for an update resolved `got` for its package. When that is
#' not the version asked for, the snapshot was taken before the release
#' reached it (or, for a pin, after the next one did): try the next day in
#' `update$step`'s direction, within the version's span, today and
#' `update_tries`. Returns the state with the next date's proposal, or
#' `NULL` when the proposal stands (`got` is right) or there is no day left
#' (the caller fails it with `update_failed_message()`).
step_update <- function(state, prop, got) {
  u <- prop$update
  if (identical(got, u$version)) return(NULL)
  date <- as.Date(prop$date) + u$step
  past <- if (u$step > 0) date > u$today || (!is.na(u$last) && date > u$last) else date < u$last
  if (past || u$tries >= update_tries) return(NULL)
  u$tries <- u$tries + 1L
  preview_update_at(state, date, u)
}

update_failed_message <- function(prop, got) {
  u <- prop$update
  has <- if (is.na(got)) sprintf("no %s", u$name) else sprintf("%s %s", u$name, got)
  sprintf("Package Manager's snapshot of %s has %s, and no snapshot near it has %s %s",
          prop$date, has, u$name, u$version)
}

#' CRAN's release dates arrived: a waiting update goes on.
reduce_cran_releases_fetched <- function(state, event) {
  if (!identical(state$packages$cran_releases$status, "fetching")) {
    return(list(state = state, effects = list(), reply = NULL))
  }
  state$packages$cran_releases <- new_cran_releases_slot("ready", event$table)
  prop <- state$packages$proposal
  if (!is.null(prop) && identical(prop$status, "dates")) state <- start_update(state, prop$update)
  list(state = state, effects = list(), reply = NULL)
}

#' CRAN's release dates couldn't be fetched: a waiting update fails, and
#' the next one fetches again.
reduce_cran_releases_failed <- function(state, event) {
  if (!identical(state$packages$cran_releases$status, "fetching")) {
    return(list(state = state, effects = list(), reply = NULL))
  }
  state$packages$cran_releases <- new_cran_releases_slot("failed", message = event$message)
  prop <- state$packages$proposal
  if (!is.null(prop) && identical(prop$status, "dates")) {
    state$packages$proposal <- new_proposal(NA_character_, status = "failed", message = event$message,
                                            update = prop$update)
  }
  list(state = state, effects = list(), reply = NULL)
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

  # The install failed: say why, as package_status() does (#182). A missing system
  # library's message names it and the command that installs it. It is
  # install_failure_message()'s, which begins "install failed".
  why <- if (identical(state$packages$target$status, "failed")) state$packages$target$message
  msg <- if (!is.null(why) && nzchar(why)) {
    sprintf("there is no package called '%s': %s", pkg, why)
  } else {
    sprintf("there is no package called '%s'; its install may have failed", pkg)
  }
  err <- new_run_error("missing_package", message = msg, names = pkg, fixes = character())
  list(state = state, error = err)
}

#' The packages a run error's message names as needed, for the fix "Add pkg
#' to [extra_packages]" (#184): tidymodels names its engines only as strings
#' (`set_engine("glmnet")`, "Package install is required for glmnet."), and
#' tidytext its lexicons' packages ("The textdata package is required ...").
#' A text match, so kept narrow. The message has the word "package", and a
#' name counts only where the message marks it as one: quoted ('glmnet'),
#' styled by cli (parsnip colours it), or just before "package" ("the
#' textdata package", only when nothing is quoted or styled). Ordinary words
#' that are also CRAN packages ("not", "here", "optional") are never marked so. Each name must also be in one of the
#' notebook's loaded indexes, and not installed (the notebook's library or
#' R's own), in the lock, or already wanted. A message R or a package
#' translated doesn't match, and gets no fix.
packages_named_in <- function(state, msg) {
  name <- "([A-Za-z][A-Za-z0-9.]*[A-Za-z0-9])"
  # The name each match of `pattern` (whose one group is `name`) marks.
  marked <- function(pattern, text) {
    m <- regmatches(text, gregexpr(pattern, text, perl = TRUE))[[1]]
    sub(pattern, "\\1", m, perl = TRUE)
  }
  styled <- marked(paste0("\033\\[[0-9;]*m", name, "\033\\["), msg)
  msg <- gsub("\033\\[[0-9;?]*[A-Za-z]", "", msg)
  if (!grepl("\\bpackages?\\b", msg, ignore.case = TRUE, perl = TRUE)) return(character())
  words <- unique(c(styled, marked(paste0("(?:'|\"|`|\u2018|\u201c)", name, "(?:'|\"|`|\u2019|\u201d)"), msg)))
  # Only when nothing is quoted or styled: in "The optional package "ranger"", the
  # quotes already say which word is the package ("optional" is one on CRAN too).
  if (length(words) == 0) words <- marked(paste0("(?<![A-Za-z0-9._])", name, "(?=\\s+(?i:packages?)\\b)"), msg)
  p <- state$packages
  indexed <- unlist(lapply(p$indexes, function(s) if (identical(s$status, "ready")) s$index$name), use.names = FALSE)
  words <- intersect(words, indexed)
  lock <- state$file$lock$entries
  words <- setdiff(words, c(names(p$active$installed), names(p$target$installed),
                            if (!is.null(lock) && nrow(lock) > 0) lock$name,
                            wanted_packages(state$graph, state$file$header)))
  if (length(words) == 0) return(character())
  setdiff(words, rownames(utils::installed.packages(c(.Library, .Library.site), noCache = TRUE)))
}

# ---- Projection --------------------------------------------------------------

#' The packages part of the snapshot (and `package_status()`): plain data.
#'
#' `list(snapshot, r_version, bioc_version,
#'      library = list(status, path, progress, message, log, failures),
#'      packages = data.frame(name, version, source, direct, status, message, spec),
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
#' `NA`), and for a package with a `[sources]` entry, `"looking_up"` and
#' `"source_failed"` (`source_rows()`, which also adds `spec`). `direct` is
#' `TRUE` for wanted names. `plan` is what running would
#' do; the banner's "installs 3 packages" (a `"not_installed"` row counts
#' toward it exactly as `"missing"` does: running retries it).
#'
#' `library$log` is `target$log` (the installer's last lines) and
#' `library$failures` is `target$failures` (`install_failures()`'s
#' result) with a `needed_by` column added: for each failed package, the
#' wanted (direct) packages whose dependency closure reaches it, walked
#' through whatever indexes are loaded (`find_in_indexes()`, resolve.R) --
#' `character()` for a package when none are. A failure with none loaded
#' fetches them, and the walk is redone as each arrives (`fill_needed_by()`).
#' Empty, correctly typed `packages` data.frame: the shape both halves of
#' `packages_view()` build their rows into. `spec` is added by
#' `source_rows()`.
empty_packages_df <- function() {
  data.frame(name = character(), version = character(), source = character(),
            direct = logical(), status = character(), message = character(),
            stringsAsFactors = FALSE)
}

#' `packages_view()`'s rows as the header's `[sources]` sees them (#78):
#'
#' * every row gets `spec`, the header's entry for its name as written
#'   (`"github:user/repo[@ref]"`), `NA` without one, so the Packages tab
#'   can offer to change or remove it;
#' * a row whose source failed (a failed lookup, `source_failed_problems()`;
#'   a source holding another package, or one that can't be read,
#'   `source_problems()`) carries that problem's message;
#' * a wanted package with a readable spec, its GitHub lookup still
#'   running, is `"looking_up"`, even while the last resolution's stale
#'   `not_found` row for it is still in `problems`;
#' * a wanted package with a spec that is neither locked nor `not_found`
#'   would have no row at all: it gets one, `"looking_up"` while its
#'   lookup (or, with no problem naming it yet, any index) is being
#'   fetched (the Bioconductor release list counts), else
#'   `"source_failed"` with the problem naming it, or the notebook-wide
#'   one (CRAN's index failed); never `"source_failed"` without a
#'   message. A failed
#'   lookup leaves the lock alone (no CRAN fallback), so without this row a
#'   typo in the repository would make the package vanish from the tab.
source_rows <- function(state, wanted, rows) {
  p <- state$packages
  header <- state$file$header
  specs <- header$sources %||% character()
  rows$spec <- if (nrow(rows) == 0) character() else unname(specs[rows$name])
  if (length(specs) == 0) return(rows)

  probs <- p$problems %||% empty_package_problems()
  probs <- probs[!is.na(probs$package) & probs$kind %in% c("index_unavailable", "source"), , drop = FALSE]
  probs <- probs[probs$package %in% names(specs), , drop = FALSE]
  keys <- source_keys(header, state$file$lock, p$sources_for %||% character())
  fetching <- function(k) identical(p$indexes[[k]]$status, "fetching")
  looking_up <- names(keys)[vapply(keys, fetching, logical(1))]

  hit <- match(rows$name, probs$package)
  rows$message[!is.na(hit)] <- probs$message[hit[!is.na(hit)]]
  now_looking <- rows$status == "not_found" & rows$name %in% looking_up
  rows$status[now_looking] <- "looking_up"
  rows$message[now_looking] <- NA_character_

  extra <- setdiff(intersect(wanted, names(specs)), rows$name)
  if (length(extra) == 0) return(rows)
  # Nothing named this package, but nothing is being fetched either (CRAN's
  # index failed while GitHub answered): the notebook-wide problem says why.
  general <- (p$problems %||% empty_package_problems())
  general <- general$message[is.na(general$package)]
  # The Bioconductor release list isn't an index slot, but resolution waits
  # on it all the same (`fetch_releases()`).
  any_fetching <- any(vapply(names(p$indexes), fetching, logical(1))) ||
    identical(p$bioc_releases$status, "fetching")
  msg <- probs$message[match(extra, probs$package)]
  waiting <- extra %in% looking_up | (is.na(msg) & any_fetching)
  msg[is.na(msg)] <- if (length(general) > 0) general[[1]] else NA_character_
  # A failure always says why; with no problem at all, resolution hasn't
  # settled yet.
  status <- ifelse(waiting | is.na(msg), "looking_up", "source_failed")
  rbind(rows, data.frame(name = extra, version = NA_character_, source = NA_character_,
                         direct = TRUE, status = status,
                         message = ifelse(status == "looking_up", NA_character_, msg),
                         spec = unname(specs[extra]), stringsAsFactors = FALSE))
}

#' Fill a failed target's `failures$needed_by` (`failure_needed_by()`)
#' from whatever indexes are loaded:
#' `list(state, effects)`. Computed here, when the failure or an index
#' arrives, rather than by every `packages_view()` call: the walk was
#' ~35ms per failed package per call at a CRAN-sized index, and
#' `packages_view()` runs on every dispatch that might have changed
#' anything package-related (`notifications()`).
#'
#' A notebook opened with a lock never resolves, so it usually has no
#' index loaded when its install fails (#17), and without one a failed
#' dependency can't point back to the package the notebook loads. With
#' `fetch = TRUE` (the failure itself), each index the walk would read
#' that the session hasn't asked for yet is fetched: the GitHub keys and
#' CRAN's, and Bioconductor's when the lock has a Bioconductor package.
#' Each one's arrival walks again (`reduce_index_fetched()`). A slot that
#' failed is left alone, as resolving leaves it: `reduce_run()` drops it
#' when the user tries again, so an offline machine doesn't loop. Until
#' the indexes arrive, or if they can't, the walk uses what it has.
fill_needed_by <- function(state, fetch = FALSE) {
  tgt <- state$packages$target
  effects <- list()
  if (!identical(tgt$status, "failed") || is.null(tgt$failures)) {
    return(list(state = state, effects = effects))
  }
  if (nrow(tgt$failures) == 0) {
    tgt$failures$needed_by <- list()
    state$packages$target <- tgt
    return(list(state = state, effects = effects))
  }
  wanted <- wanted_packages(state$graph, state$file$header)
  gh <- unname(source_keys(state$file$header, state$file$lock,
                           state$packages$sources_for %||% character()))
  repos <- needed_repos(state$file$header, state$options$r,
                        releases_at(state$packages, state$file$header$snapshot))
  needed <- c(gh, repos)
  if (fetch) {
    wanted_keys <- c(gh, repos[[1]], if (lock_has_bioc(state$file$lock)) repos[-1])
    for (k in Filter(function(k) is.null(state$packages$indexes[[k]]), wanted_keys)) {
      state$packages$indexes[[k]] <- new_index_slot("fetching")
      effects <- c(effects, list(fx_fetch_index(k, repo_url(state$options$repos, k))))
    }
  }
  indexes <- lapply(state$packages$indexes, function(s) s$index)
  tgt$failures$needed_by <- failure_needed_by(tgt$failures$package, wanted, indexes, needed)
  state$packages$target <- tgt
  list(state = state, effects = effects)
}

#' For each failed package in `pkgs`, the wanted (direct) packages whose
#' dependency closure reaches it, walking from each root through
#' `find_in_indexes()` (resolve.R) with whatever indexes are loaded: a list
#' parallel to `pkgs`. A root is included when the package is the root
#' itself (a direct package that failed names itself here too) or appears
#' anywhere in what it transitively depends on. No loaded index at all
#' means no closure can be walked, so each answer is the roots that failed
#' themselves: still correct, just less informative (install_failures()'s
#' own finding is unaffected). Each root's closure is walked once, not
#' once per failed package, since a dependency chain that fails usually
#' fails many packages at once and this runs again as each index arrives.
failure_needed_by <- function(pkgs, wanted, indexes, needed) {
  closures <- lapply(wanted, function(root) {
    seen <- new.env(hash = TRUE, parent = emptyenv())
    queue <- root
    while (length(queue) > 0) {
      cur <- queue[[1]]
      queue <- queue[-1]
      if (!nzchar(cur) || !is.null(seen[[cur]])) next
      seen[[cur]] <- TRUE
      hit <- find_in_indexes(cur, indexes, needed)
      if (!is.null(hit)) queue <- c(queue, hit$deps)
    }
    seen
  })
  lapply(pkgs, function(pkg) {
    wanted[vapply(closures, function(seen) !is.null(seen[[pkg]]), logical(1))]
  })
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
  packages_df <- source_rows(state, wanted, rbind(locked_df, not_found_df))

  proposal <- NULL
  if (!is.null(p$proposal)) {
    proposal <- list(date = p$proposal$date, status = p$proposal$status,
                     changes = p$proposal$changes, problems = p$proposal$problems,
                     apply = isTRUE(p$proposal$apply), restart = p$proposal$restart %||% character(),
                     message = p$proposal$message, kind = p$proposal$kind %||% "date",
                     asked = p$proposal$asked %||% p$proposal$date,
                     update = if (!is.null(p$proposal$update)) p$proposal$update[c("name", "version")])
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
