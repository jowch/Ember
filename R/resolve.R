# Resolution: which packages the notebook wants, and which versions the
# lock should hold for them at the notebook's date. Pure.
#
# Knowledge owned here: what counts as a package the notebook uses, the
# repository index as a domain type, dated repository URLs, and the
# closure walk. The session (packages-core.R) decides *when* to resolve;
# this file decides *what* the answer is.

# ---- Repositories ------------------------------------------------------------

#' Where indexes and packages come from: base URLs, without dates.
#'
#' `ember_repos(cran, bioc)`. The default is the public Posit Package
#' Manager; an institution's own Package Manager, or a `file://` folder laid
#' out the same way, can replace it. The `file://` form is the test seam:
#' `fixtures/repos/cran/2026-09-01/src/contrib/PACKAGES` is read by exactly
#' the code that reads PPM, so tests exercise the real path with no network
#' and no mock (R's own `available.packages()` and renv both accept
#' `file://` repositories).
#' @export
ember_repos <- function(cran = "https://packagemanager.posit.co/cran",
                        bioc = "https://packagemanager.posit.co/bioconductor") {
  structure(list(cran = sub("/+$", "", cran), bioc = sub("/+$", "", bioc)),
            class = "ember_repos")
}

#' The dated repository a notebook resolves and installs from.
#'
#' `repo_key("cran", date)` is the string that identifies an index
#' everywhere (state, disk cache, job table): `"cran/2026-09-01"`.
#' `repo_url(repos, key)` turns it into `<repos$cran>/2026-09-01`.
#' Bioconductor (increment 2): `"bioc/2026-09-01/3.23"` ->
#' `<repos$bioc>/2026-09-01/packages/3.23/bioc`.
#' The path below the dated root (src/contrib, bin/macosx/contrib/4.6, ...)
#' is left to R and renv: R 4.6 moved macOS binaries and both found them
#' (spikes/packages, section 1).
repo_key <- function(kind, date, bioc_version = NULL) {
  date <- format(as.Date(date), "%Y-%m-%d")
  if (identical(kind, "bioc")) {
    paste0("bioc/", date, "/", bioc_version)
  } else {
    paste0(kind, "/", date)
  }
}

repo_url <- function(repos, key) {
  parts <- strsplit(key, "/", fixed = TRUE)[[1]]
  kind <- parts[[1]]
  if (identical(kind, "bioc")) {
    date <- parts[[2]]
    bioc_version <- parts[[3]]
    paste0(repos$bioc, "/", date, "/packages/", bioc_version, "/bioc")
  } else {
    date <- parts[[2]]
    paste0(repos$cran, "/", date)
  }
}

#' Named character, repository name -> URL, for renv and `ember::run()`:
#' `c(CRAN = ...)`, plus `BioCsoft = ...` when the header has a
#' `bioc_version`.
repo_urls <- function(repos, header) {
  out <- c(CRAN = repo_url(repos, repo_key("cran", header$snapshot)))
  if (!is.na(header$bioc_version)) {
    out <- c(out, BioCsoft = repo_url(repos, repo_key("bioc", header$snapshot, header$bioc_version)))
  }
  out
}

# ---- The index ---------------------------------------------------------------

#' One repository's index at one date: what was current, and what each
#' version needs.
#'
#' `key` (`repo_key()`), `label` (`"CRAN"` or `"Bioc"`, the lock source it
#' yields), and per package, in vectors aligned by position and sorted by
#' name for `match()`:
#' * `name`, `version`;
#' * `deps`: list of character, the package names in Depends, Imports and
#'   LinkingTo, with version constraints and `R` dropped. Not Suggests.
#' * `needs_compilation`: logical (increment 2 uses it for the compiler
#'   check).
#'
#' Built only by `read_repo_index()`, at the boundary, so no other code
#' sees DCF field names. A dated index never changes, so a parsed copy is
#' cached on disk forever (library.R) and shared in memory across sessions:
#' every state holding the index for one key holds the same R object, so
#' it is stored once and `identical()` on it returns at once.
#'
#' A GitHub source (increment 2) becomes a one-row index whose `label` is
#' its `github:` source string; resolution needs no special case for it.
new_repo_index <- function(key, label, name, version, deps, needs_compilation) {
  ord <- order(name, method = "radix")
  structure(list(key = key, label = label, name = name[ord], version = version[ord],
                 deps = deps[ord], needs_compilation = needs_compilation[ord]),
            class = "ember_repo_index")
}

#' Parse a `PACKAGES` file (plain or .gz) into an `ember_repo_index`.
#' Runs in the index-fetch subprocess, not the server: `read.dcf()` on
#' CRAN's 22k-entry index takes about a second (estimate; measure), too long
#' for the server thread. The subprocess saves the result with `saveRDS()`;
#' the server only `readRDS()`s it.
read_repo_index <- function(path, key, label) {
  dcf <- read.dcf(path, fields = c("Package", "Version", "Depends",
                                   "Imports", "LinkingTo", "NeedsCompilation"))
  name <- unname(dcf[, "Package"])
  version <- unname(dcf[, "Version"])
  depends <- unname(dcf[, "Depends"])
  imports <- unname(dcf[, "Imports"])
  linkingto <- unname(dcf[, "LinkingTo"])
  needs_compilation <- toupper(trimws(unname(dcf[, "NeedsCompilation"]))) %in% "YES"
  deps <- unname(Map(dep_field_union, depends, imports, linkingto))

  # PPM can list one row per build of a version, or an index can repeat a
  # name across a yanked and replacement release: keep the row with the
  # highest package_version() per name.
  groups <- split(seq_along(name), name)
  keep <- sort(vapply(groups, function(ix) ix[which.max(package_version(version[ix]))],
                      integer(1)))

  new_repo_index(key, label, name[keep], version[keep], deps[keep], needs_compilation[keep])
}

#' One DCF dependency field (`Depends`, `Imports` or `LinkingTo`) split into
#' package names: comma-separated, version constraints and whitespace
#' dropped, `"R"` and empty entries dropped. `NA` (the field absent) is an
#' empty dependency list.
split_dep_field <- function(field) {
  if (is.na(field) || !nzchar(trimws(field))) return(character())
  parts <- trimws(strsplit(field, ",", fixed = TRUE)[[1]])
  parts <- trimws(sub("\\(.*\\)", "", parts))
  parts <- parts[nzchar(parts)]
  parts[parts != "R"]
}

#' The union of a row's Depends, Imports and LinkingTo package names.
#' Suggests is never looked at: it names packages used in examples and
#' tests, not to run the code.
dep_field_union <- function(depends, imports, linkingto) {
  unique(c(split_dep_field(depends), split_dep_field(imports), split_dep_field(linkingto)))
}

# ---- What the notebook wants -------------------------------------------------

#' The notebook's package set: every package a cell's analysis names
#' (library, require, requireNamespace, `::`, box, pacman; sourced files
#' included, since step 1 merges them into the cell's analysis), plus the
#' header's `[extra_packages]`, minus `base_packages`. Sorted, unique.
#'
#' Conditional use (`if (requireNamespace("x"))`) still counts: the
#' engine assumes too many dependencies rather than too few. A
#' `computed_package` note (a non-literal `library(pkg)`) yields nothing;
#' the "no package called" fix covers it at run time.
wanted_packages <- function(graph, header) {
  used <- unlist(lapply(graph$cells, function(c) c$packages), use.names = FALSE)
  wanted <- c(used, header$extra_packages)
  wanted <- setdiff(unique(wanted), base_packages)
  sort(wanted, method = "radix")
}

#' The packages one cell needs installed before it can run: its analysis's
#' package names minus base packages. Used by the waiting rule.
cell_packages <- function(graph, id) {
  setdiff(graph$cells[[id]]$packages, base_packages)
}

# ---- The closure walk --------------------------------------------------------

#' Resolve `roots` against `indexes`. The heart of step 3, and pure.
#'
#' @param roots `wanted_packages()`.
#' @param lock The current `ember_lock`.
#' @param indexes Named list, repo key -> `ember_repo_index`, in the order
#'   names are looked up: `[sources]` GitHub indexes, then CRAN, then Bioc.
#' @param needed Character, the repo keys that resolution may consult, in
#'   lookup order. A key in `needed` but absent from `indexes` is one not
#'   fetched yet.
#' @param mode `"keep"`: entries already in `lock` stay at exactly their
#'   version (adding a package never moves another one). `"fresh"`: every
#'   version comes from `indexes` (a date move).
#' @return `ember_resolution`:
#'   * `lock`: the new lock (`lock` itself, untouched, when not `complete`);
#'   * `complete`: `TRUE` when every name was settled with the indexes at
#'     hand;
#'   * `fetch`: repo keys to fetch before trying again (non-empty only
#'     when not complete);
#'   * `problems`: data frame `kind`, `package`, `message`, `fixes`.
#'     Kinds: `"not_found"` (in no repository at this date: a typo, a
#'     GitHub package, or archived before the date), `"off_date"` (a
#'     locked version differs from the index at the snapshot date: the
#'     lock was edited by hand or mixes dates; it is kept, and the problem
#'     says to move the date or update the package), `"not_in_index"` (`p`
#'     is locked but no loaded index has it at all, so its own deps can't be
#'     walked; it is kept at its locked version and the rest of the previous
#'     lock is kept reachable rather than silently pruned).
#'
#' Pseudocode (mode "keep"):
#'   locked <- lock entries by name
#'   out <- empty; queue <- roots; problems <- empty; fetch <- empty
#'   while queue not empty:
#'     p <- pop(queue); if p in base_packages or p in out: next
#'     hit <- first index (in `needed` order, loaded only) containing p
#'     if p in locked:
#'       e <- locked[p]
#'       if hit is NULL or hit's version != e$version:
#'         deps <- hit's deps if hit else character()
#'         if hit: problems += off_date(p, e$version, hit$version)
#'       else deps <- hit's deps
#'     else if hit is NULL:
#'       if any key in `needed` is not in `indexes`: fetch += those keys; next
#'       problems += not_found(p, date); next
#'     else e <- entry(p, hit$version, hit$label); deps <- hit's deps
#'     out[p] <- e; queue += deps
#'   if fetch non-empty: return(list(lock = lock, complete = FALSE, fetch, problems))
#'   new_lock(out) (+ lock$unparsed carried over)
#'
#' Removing a package drops it and the dependencies nothing else needs for
#' free: the walk starts from the current roots, and what it doesn't reach
#' isn't in `out`.
#'
#' Mode "fresh" is the same walk with `locked` empty.
#'
#' Cost: one `match()` per name against a sorted 22k vector; a closure of
#' 100 packages is a few ms (estimate).
resolve_lock <- function(roots, lock, indexes, needed, mode = c("keep", "fresh")) {
  mode <- match.arg(mode)
  locked <- if (identical(mode, "keep")) lock$entries else lock$entries[0, ]
  # Unlike `locked`, `orig` is the previous lock's entries in *every* mode,
  # including "fresh": a date move resolves every package as if it weren't
  # locked (so its version can move), but an entry whose resolved version
  # happens not to change still carried an `extra` field (lock.R: a SHA-256
  # or other field a newer Ember wrote, kept verbatim across saves). Reading
  # from `locked` alone, as the "keep" branch above does, would always see
  # an empty table in "fresh" mode and silently drop that field even for a
  # package whose version didn't move at all.
  orig <- lock$entries

  out_name <- character(); out_version <- character()
  out_source <- character(); out_extra <- character()
  seen <- character()
  queue <- unique(roots)
  problems <- empty_package_problems()
  fetch <- character()

  while (length(queue) > 0) {
    p <- queue[[1]]
    queue <- queue[-1]
    if (p %in% base_packages || p %in% seen) next
    seen <- c(seen, p)

    hit <- find_in_indexes(p, indexes, needed)
    row <- which(locked$name == p)

    if (length(row) == 1) {
      e_version <- locked$version[[row]]
      e_source <- locked$source[[row]]
      e_extra <- locked$extra[[row]]
      if (is.null(hit) || !identical(hit$version, e_version)) {
        if (is.null(hit)) {
          # `p` is still locked, but no loaded index has it at all (archived,
          # or hand-written with no repository Ember knows): there is no
          # entry to read its deps from. Falling back to `character()` here
          # used to drop every package `p` pulled in, silently, the moment
          # nothing else in `roots` still needed them. Re-queuing the rest of
          # the previous lock keeps them reachable instead; harmless when
          # they really are still needed (the common case), and at worst
          # keeps an unlocked leaf around one resolution longer than strictly
          # necessary when `p` itself is later removed too.
          deps <- setdiff(locked$name, p)
          problems <- rbind(problems, package_problem(
            "not_in_index", p,
            sprintf("%s is locked at %s but is not in the index at this date", p, e_version)))
        } else {
          deps <- hit$deps
          problems <- rbind(problems, package_problem(
            "off_date", p,
            sprintf("%s is locked at %s but %s is current at this date", p, e_version, hit$version)))
        }
      } else {
        deps <- hit$deps
      }
      out_name <- c(out_name, p); out_version <- c(out_version, e_version)
      out_source <- c(out_source, e_source); out_extra <- c(out_extra, e_extra)
      queue <- c(queue, deps)
    } else if (is.null(hit)) {
      missing <- setdiff(needed, names(indexes))
      if (length(missing) > 0) {
        fetch <- union(fetch, missing)
        next
      }
      problems <- rbind(problems, package_problem(
        "not_found", p, sprintf("%s was not found in any repository at this date", p)))
    } else {
      orig_row <- which(orig$name == p)
      extra <- if (length(orig_row) == 1 && identical(orig$version[[orig_row]], hit$version)) {
        orig$extra[[orig_row]]
      } else {
        ""
      }
      out_name <- c(out_name, p); out_version <- c(out_version, hit$version)
      out_source <- c(out_source, hit$label); out_extra <- c(out_extra, extra)
      queue <- c(queue, hit$deps)
    }
  }

  if (length(fetch) > 0) {
    return(new_resolution(lock, complete = FALSE, fetch = fetch, problems = problems))
  }

  new_resolution(new_lock(out_name, out_version, out_source, out_extra, unparsed = lock$unparsed),
                complete = TRUE, fetch = character(), problems = problems)
}

#' The first index (in `needed` order, loaded only) that has `p`, as
#' `list(version, deps, label)`, or `NULL`.
find_in_indexes <- function(p, indexes, needed) {
  for (key in needed) {
    idx <- indexes[[key]]
    if (is.null(idx)) next
    pos <- match(p, idx$name)
    if (!is.na(pos)) {
      return(list(version = idx$version[[pos]], deps = idx$deps[[pos]], label = idx$label))
    }
  }
  NULL
}

new_resolution <- function(lock, complete, fetch, problems) {
  structure(list(lock = lock, complete = complete, fetch = fetch,
                 problems = problems), class = "ember_resolution")
}

empty_package_problems <- function() {
  data.frame(kind = character(), package = character(), message = character(),
             fixes = character(), stringsAsFactors = FALSE)
}

#' The repo keys a notebook's resolution consults, in lookup order.
#' Increment 1: `repo_key("cran", header$snapshot)`. Increment 2 appends
#' the Bioconductor key (only fetched when a name is missing from CRAN:
#' `resolve_lock()` asks for it through `fetch`) and prepends one key per
#' `[sources]` entry.
needed_repos <- function(header) repo_key("cran", header$snapshot)
