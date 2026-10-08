# The lock: what the notebook's `/// lock` block says, as a value.
#
# Knowledge owned here: the one-line lock format, how two locks differ, how
# a lock names its library on disk, and how a lock becomes renv's lockfile.
# Everything is pure. Nothing else in Ember parses or formats lock lines.

# ---- The type ----------------------------------------------------------------

#' A lock: one entry per package the notebook uses, directly or as a
#' dependency.
#'
#' `entries`: data frame `name`, `version`, `source`, `extra`, one row per
#' package, sorted by `name` (C locale), names unique.
#' * `source` is `"CRAN"`, `"Bioc"`, or `"github:<user>/<repo>@<sha>"`.
#' * `extra` is the text after the source on the line, verbatim (`""` when
#'   none). Older Embers ignore it; this one keeps it so a field a newer
#'   Ember wrote (a SHA-256, say) survives a save.
#' `unparsed`: character, lock lines this Ember could not read, kept and
#'   written back unchanged after the parsed ones. Each also becomes a
#'   `problems` row when the file is opened.
#'
#' Invariants (encoded by `new_lock()`, the only constructor):
#' * sorted by name, so the formatted block is canonical and two people
#'   adding different packages on two branches produce line-wise mergeable
#'   diffs;
#' * no base package (`base_packages`) ever appears: those ship with R;
#' * recommended packages (Matrix, MASS, ...) DO appear when the notebook
#'   needs them: they are ordinary CRAN packages whose bundled copy changes
#'   with the R release, so locking them is what keeps `ember::run()` on
#'   another R giving the same Matrix.
new_lock <- function(name = character(), version = character(),
                     source = character(), extra = character(length(name)),
                     unparsed = character()) {
  dupes <- unique(name[duplicated(name)])
  if (length(dupes) > 0) {
    stop("new_lock: duplicate package name(s): ", paste(dupes, collapse = ", "))
  }
  based <- intersect(name, base_packages)
  if (length(based) > 0) {
    stop("new_lock: base package(s) cannot be locked: ", paste(based, collapse = ", "))
  }
  ord <- order(name, method = "radix")
  entries <- data.frame(name = name[ord], version = version[ord],
                        source = source[ord], extra = extra[ord],
                        stringsAsFactors = FALSE)
  structure(list(entries = entries, unparsed = unparsed), class = "ember_lock")
}

empty_lock <- function() new_lock()

#' Packages that ship with every R and are never locked. Fixed across R 4.x.
base_packages <- c("base", "compiler", "datasets", "graphics", "grDevices",
                   "grid", "methods", "parallel", "splines", "stats",
                   "stats4", "tcltk", "tools", "utils")

#' Whether `x` is a syntactically valid R package name: a letter, then
#' letters, digits or dots, not ending in a dot, at least two characters
#' (CRAN's own rule). Used by `parse_lock_lines()` to repair a hand-edited
#' line rather than mis-split it.
is_valid_package_name <- function(x) {
  grepl("^[A-Za-z][A-Za-z0-9.]*[A-Za-z0-9]$", x)
}

#' Whether `x` parses as an R package version (`package_version()`). Used by
#' `parse_lock_lines()` to catch a version field that isn't one at all (a
#' hand-edited "latest", say): such a line used to pass through as an
#' ordinary entry, and later crashed `resolve_lock()`/`lock_diff()`'s own
#' `package_version()` comparisons -- not a problem row shown to the user,
#' a hard stop deep in `step()` over one hand-edited character.
is_valid_version <- function(x) {
  isTRUE(tryCatch({ package_version(x); TRUE }, error = function(e) FALSE))
}

#' Whether a lock line's version field is valid for its source: a GitHub
#' entry's "version" is a commit SHA (`"3f2a1c9"`), which is never a valid
#' `package_version()` and isn't compared as one anywhere; any non-empty
#' field is accepted there. A CRAN or Bioc entry's version must parse as
#' one (`is_valid_version()`), since `resolve_lock()` and `lock_diff()`
#' both call `package_version()` on it.
valid_version_field <- function(version, source) {
  if (startsWith(source, "github:")) nzchar(version) else is_valid_version(version)
}

# ---- The file block ----------------------------------------------------------

#' Lock block lines (without the `# ` prefix) -> `list(lock, problems)`.
#'
#' A line is `<name> <version> <source>[ <extra>...]`, split on single
#' spaces. A line with fewer than three fields, an invalid package name, or
#' a duplicate name goes to `unparsed` with a problem row
#' (`kind = "lock_line"`). Never fails: any file opens.
parse_lock_lines <- function(lines) {
  name <- character(); version <- character(); source <- character()
  extra <- character()
  unparsed <- character()
  problems <- empty_package_problems()
  seen <- character()

  for (line in lines) {
    fields <- strsplit(line, " ", fixed = TRUE)[[1]]
    pkg <- if (length(fields) >= 1) fields[[1]] else NA_character_
    ok <- length(fields) >= 3 && is_valid_package_name(pkg) &&
      valid_version_field(fields[[2]], fields[[3]])
    if (ok && pkg %in% seen) {
      unparsed <- c(unparsed, line)
      problems <- rbind(problems, package_problem(
        "lock_line", pkg, sprintf("duplicate lock line for %s", pkg)))
      next
    }
    if (!ok) {
      unparsed <- c(unparsed, line)
      problems <- rbind(problems, package_problem(
        "lock_line", pkg, sprintf("could not read lock line: %s", line)))
      next
    }
    seen <- c(seen, pkg)
    name <- c(name, pkg)
    version <- c(version, fields[[2]])
    source <- c(source, fields[[3]])
    extra <- c(extra, if (length(fields) > 3) paste(fields[-(1:3)], collapse = " ") else "")
  }

  list(lock = new_lock(name, version, source, extra, unparsed = unparsed),
      problems = problems)
}

#' A package-problem row, the shape `resolve_lock()` and `parse_lock_lines()`
#' both produce (see `empty_package_problems()` in resolve.R).
package_problem <- function(kind, package, message, fixes = NA_character_) {
  data.frame(kind = kind, package = package, message = message, fixes = fixes,
            stringsAsFactors = FALSE)
}

#' `ember_lock` -> lock block lines: `name version source[ extra]`, then
#' `unparsed` verbatim. `parse_lock_lines(format_lock_lines(l))$lock` is
#' `identical()` to `l`.
format_lock_lines <- function(lock) {
  e <- lock$entries
  if (nrow(e) == 0) {
    parsed <- character()
  } else {
    base <- paste(e$name, e$version, e$source)
    parsed <- ifelse(nzchar(e$extra), paste(base, e$extra), base)
  }
  c(parsed, lock$unparsed)
}

# ---- Comparing ---------------------------------------------------------------

#' What changes going from `old` to `new`: data frame `name`, `from`
#' (version or `NA`), `to` (version or `NA`), `change` (`"added"`,
#' `"removed"`, `"upgraded"`, `"downgraded"`, `"source"`), sorted by name.
#' Shown before a date move is applied, and used by the restart decision.
#' Versions are compared with `utils::compareVersion()` semantics
#' (`package_version()`), never as strings.
lock_diff <- function(old, new) {
  old_e <- old$entries
  new_e <- new$entries
  empty <- data.frame(name = character(), from = character(), to = character(),
                      change = character(), stringsAsFactors = FALSE)

  added <- setdiff(new_e$name, old_e$name)
  removed <- setdiff(old_e$name, new_e$name)
  common <- intersect(old_e$name, new_e$name)

  rows <- list(empty)
  if (length(added) > 0) {
    to <- new_e$version[match(added, new_e$name)]
    rows <- c(rows, list(data.frame(name = added, from = NA_character_, to = to,
                                    change = "added", stringsAsFactors = FALSE)))
  }
  if (length(removed) > 0) {
    from <- old_e$version[match(removed, old_e$name)]
    rows <- c(rows, list(data.frame(name = removed, from = from, to = NA_character_,
                                    change = "removed", stringsAsFactors = FALSE)))
  }
  if (length(common) > 0) {
    from <- old_e$version[match(common, old_e$name)]
    to <- new_e$version[match(common, new_e$name)]
    from_src <- old_e$source[match(common, old_e$name)]
    to_src <- new_e$source[match(common, new_e$name)]
    cmp <- mapply(function(a, b) {
      if (identical(a, b)) 0L
      else if (package_version(a) < package_version(b)) -1L
      else 1L
    }, from, to)
    change <- ifelse(cmp < 0, "upgraded",
                     ifelse(cmp > 0, "downgraded",
                            ifelse(from_src != to_src, "source", NA_character_)))
    keep <- !is.na(change)
    if (any(keep)) {
      rows <- c(rows, list(data.frame(name = common[keep], from = from[keep], to = to[keep],
                                      change = change[keep], stringsAsFactors = FALSE)))
    }
  }
  out <- do.call(rbind, rows)
  out[order(out$name, method = "radix"), , drop = FALSE]
}

#' Lock entries as a named character vector name -> version (parsed rows
#' only). The shape the library manifest and the worker's `loaded` use too.
lock_versions <- function(lock) {
  stats::setNames(lock$entries$version, lock$entries$name)
}

# ---- The library a lock installs into ----------------------------------------

#' Where the library for `lock` lives, and its key.
#'
#' `list(key, path)`. `key` is the MD5 of the canonical lock lines without
#' `extra` (an extra field must not move the library) and without
#' `unparsed`. `path` is `<cache>/libraries/R-<minor>/<platform>/<key>`:
#' the R minor version and platform are in the path, not the key, because
#' an installed package only works on the R minor version and platform it
#' was built for, and having them visible makes `ember::clean()` output
#' readable.
#'
#' Named by the lock, not by the notebook: two notebooks with the same lock
#' share one library, moving a notebook orphans nothing, and Ember never
#' tracks notebook paths (design.md, Installs).
#'
#' Pure in effect: on R < 4.5 hashing text needs a temporary file
#' (`tools::md5sum(bytes =)` exists only from 4.5); the result depends only
#' on the arguments.
#'
#' @param r `r_info()`: `list(version, minor, platform)`, passed into the
#'   session at open, never read here.
library_for <- function(lock, r, cache) {
  e <- lock$entries
  canon <- paste(paste(e$name, e$version, e$source), collapse = "\n")
  key <- hash_text(canon)
  path <- file.path(cache, "libraries", paste0("R-", r$minor), r$platform, key)
  list(key = key, path = path)
}

#' The library a notebook with no packages uses: an empty folder with the
#' same layout, so the worker's `R_LIBS_USER` always names a real path.
empty_library <- function(r, cache) library_for(empty_lock(), r, cache)

hash_text <- function(text) {
  if (getRversion() >= "4.5") {
    return(unname(tools::md5sum(bytes = charToRaw(text))))
  }
  tmp <- tempfile()
  on.exit(unlink(tmp))
  writeBin(charToRaw(text), tmp)
  unname(tools::md5sum(tmp))
}

# ---- renv's form -------------------------------------------------------------

#' The renv lockfile for `lock`, as the R list `renv::lockfile_write()`
#' takes. Built inside the installer subprocess (inst/installer.R), which is
#' the only process with renv loaded; the server never loads renv.
#'
#' `list(R = list(Version = r$version, Repositories = repos_list),
#'      Packages = per entry list(Package, Version, Source, Repository))`:
#' CRAN entries -> `Source = "Repository", Repository = "CRAN"`; Bioc ->
#' `Repository = "BioCsoft"`; GitHub (increment 2) -> `Source = "GitHub",
#' RemoteUsername, RemoteRepo, RemoteSha`. No hash: measured, renv restores
#' exact versions from this minimal form (spikes/packages, section 2).
#'
#' @param repos named character, repository name -> dated URL
#'   (`repo_urls()` in resolve.R).
renv_lockfile_of <- function(lock, r, repos) {
  e <- lock$entries
  package_record <- function(name, version, source) {
    if (identical(source, "CRAN")) {
      list(Package = name, Version = version, Source = "Repository", Repository = "CRAN")
    } else if (identical(source, "Bioc")) {
      # A preference, not a constraint: renv also looks in the other
      # repositories listed (BioCann, BioCexp; repo_urls() in resolve.R).
      list(Package = name, Version = version, Source = "Repository", Repository = "BioCsoft")
    } else if (startsWith(source, "github:")) {
      rest <- sub("^github:", "", source)
      at <- regmatches(rest, regexec("^([^/]+)/([^@]+)@(.+)$", rest))[[1]]
      list(Package = name, Version = version, Source = "GitHub",
          RemoteUsername = at[[2]], RemoteRepo = at[[3]], RemoteSha = at[[4]])
    } else {
      stop("renv_lockfile_of: unknown source: ", source)
    }
  }
  packages <- Map(package_record, e$name, e$version, e$source)
  names(packages) <- e$name
  # A named list, name -> URL: the shape renv writes and reads back. A list
  # of list(Name, URL) records is serialised wrongly and breaks restore().
  repositories <- as.list(repos)
  list(R = list(Version = as.character(r$version), Repositories = repositories),
      Packages = packages)
}
