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
#' `ember_repos(cran, bioc, bioc_config)`. The default is the public Posit
#' Package Manager; an institution's own Package Manager, or a `file://`
#' folder laid out the same way, can replace it. The `file://` form is the
#' test seam: `fixtures/repos/cran/2026-09-01/src/contrib/PACKAGES` is read
#' by exactly the code that reads PPM, so tests exercise the real path with
#' no network and no mock (R's own `available.packages()` and renv both
#' accept `file://` repositories).
#'
#' `bioc_config` is where Bioconductor's list of releases comes from
#' (`parse_bioc_config()`): bioconductor.org's own `config.yaml`, or a
#' `file://` copy. `NA` turns the lookup off, and with it Bioconductor.
#'
#' `github` is the GitHub API that `[sources]` GitHub packages come from
#' (`github_api_url()`): GitHub's own, a GitHub Enterprise server's
#' (`https://github.example.org/api/v3`), or a `file://` folder laid out
#' the same way (`repos/<user>/<repo>/commits/<ref>` holding the commit,
#' `repos/<user>/<repo>/tarball/<sha>` the package), which is the test seam.
#'
#' `universe` is where `[sources]` r-universe packages come from
#' (`universe_url()`): a URL with `%s` where the universe's name goes,
#' r-universe's own `https://%s.r-universe.dev` by default, or a `file://`
#' folder with one subfolder per universe laid out as r-universe is
#' (`api/packages/<package>` holding the package's JSON, `src/contrib` its
#' tarball), which is the test seam.
#'
#' `cran_meta` is where CRAN's own index of its files is: `archive.rds` and
#' `current.rds`, which give every version's release date for
#' `preview_update()` (`cran_release_table()`). Any CRAN mirror's
#' `src/contrib/Meta`, or a `file://` folder holding the two files.
#' @export
ember_repos <- function(cran = "https://packagemanager.posit.co/cran",
                        bioc = "https://packagemanager.posit.co/bioconductor",
                        bioc_config = "https://bioconductor.org/config.yaml",
                        github = "https://api.github.com",
                        universe = "https://%s.r-universe.dev",
                        cran_meta = "https://cloud.r-project.org/src/contrib/Meta") {
  structure(list(cran = sub("/+$", "", cran), bioc = sub("/+$", "", bioc),
                 bioc_config = bioc_config, github = sub("/+$", "", github),
                 universe = sub("/+$", "", universe), cran_meta = sub("/+$", "", cran_meta)),
            class = "ember_repos")
}

#' The dated repository a notebook resolves and installs from.
#'
#' `repo_key("cran", date)` is the string that identifies an index
#' everywhere (state, disk cache, job table): `"cran/2026-09-01"`.
#' `repo_url(repos, key)` turns it into `<repos$cran>/2026-09-01`.
#' Bioconductor has three repositories per release, one key kind each
#' (`bioc_kinds`): `"bioc/2026-09-01/3.23"` ->
#' `<repos$bioc>/2026-09-01/packages/3.23/bioc` (software),
#' `"bioc-ann/..."` -> `.../data/annotation` (GO.db, org.Hs.eg.db,
#' BSgenome.*), `"bioc-exp/..."` -> `.../data/experiment`.
#' The path below the dated root (src/contrib, bin/macosx/contrib/4.6, ...)
#' is left to R and renv: R 4.6 moved macOS binaries and both found them
#' (spikes/packages, section 1). Linux binaries live elsewhere, under a
#' `__linux__/<platform>` segment; the installer puts Bioconductor's there
#' itself (`ppm_binary_repos()`).
repo_key <- function(kind, date, bioc_version = NULL) {
  date <- format(as.Date(date), "%Y-%m-%d")
  if (kind %in% names(bioc_kinds)) {
    paste0(kind, "/", date, "/", bioc_version)
  } else {
    paste0(kind, "/", date)
  }
}

#' Bioconductor's repositories, key kind -> path below
#' `<repos$bioc>/<date>/packages/<release>/`, in lookup order. The names
#' renv and `ember::run()` give them (`repo_urls()`) are BiocManager's.
bioc_kinds <- c(bioc = "bioc", "bioc-ann" = "data/annotation", "bioc-exp" = "data/experiment")
bioc_repo_names <- c(bioc = "BioCsoft", "bioc-ann" = "BioCann", "bioc-exp" = "BioCexp")

repo_url <- function(repos, key) {
  parts <- strsplit(key, "/", fixed = TRUE)[[1]]
  kind <- parts[[1]]
  if (identical(kind, "github")) {
    src <- parse_github_key(key)
    paste0(github_api_url(repos), "/repos/", src$user, "/", src$repo)
  } else if (identical(kind, "universe")) {
    universe_url(repos, parts[[2]])
  } else if (identical(kind, "universe-commit")) {
    # A commit the universe built: read from GitHub when that is where the
    # code lives, since the universe keeps only its latest build.
    src <- parse_universe_source(universe_source_of_key(key))
    gh <- universe_github_repo(src)
    if (is.null(gh)) universe_url(repos, src$universe)
    else paste0(github_com_api_url(repos), "/repos/", gh$user, "/", gh$repo)
  } else if (kind %in% names(bioc_kinds)) {
    date <- parts[[2]]
    bioc_version <- parts[[3]]
    paste0(repos$bioc, "/", date, "/packages/", bioc_version, "/", bioc_kinds[[kind]])
  } else {
    date <- parts[[2]]
    paste0(repos$cran, "/", date)
  }
}

#' Named character, repository name -> URL, for renv and `ember::run()`:
#' `c(CRAN = ...)`, plus `BioCsoft`, `BioCann` and `BioCexp` when the
#' header has a `bioc_version`. A lock entry says only `Bioc`, not which of
#' the three it came from; renv looks a package up in every repository
#' listed here, so that is enough (lock.R, `renv_lockfile_of()`).
#'
#' With `lock`, each universe its r-universe packages came from is listed
#' too, as `universe-<name>` (`universe_repo_name()`): the installer
#' installs from it while it still serves the locked commit
#' (`universe_served()`).
repo_urls <- function(repos, header, lock = NULL) {
  out <- c(CRAN = repo_url(repos, repo_key("cran", header$snapshot)))
  if (!is.na(header$bioc_version)) {
    for (kind in names(bioc_kinds)) {
      out[[bioc_repo_names[[kind]]]] <-
        repo_url(repos, repo_key(kind, header$snapshot, header$bioc_version))
    }
  }
  sources <- if (is.null(lock$entries)) character() else lock$entries$source
  for (src in Filter(Negate(is.null), lapply(sources, parse_universe_source))) {
    out[[universe_repo_name(src$universe)]] <- universe_url(repos, src$universe)
  }
  out
}

#' `repo_urls()` as the installer hands them to renv on Linux, where
#' Package Manager serves binaries under `__linux__/<platform>/` placed
#' right after the repository's root: `<cran>/__linux__/noble/<date>` and
#' `<bioc>/__linux__/noble/<date>/packages/3.23/bioc`.
#'
#' renv makes that rewrite itself (`RENV_CONFIG_PPM_ENABLED`), but it
#' inserts the segment before the URL's last path component, which is
#' right for CRAN's `<cran>/<date>` and wrong for Bioconductor's
#' `<bioc>/<date>/packages/3.23/bioc`: it asks for
#' `.../packages/3.23/__linux__/noble/bioc`, which Package Manager answers
#' with a 404, so every Bioconductor package "can't be found" and the
#' whole install fails. renv leaves a URL that already has a `__x__`
#' segment alone, so rewriting the Bioconductor ones here is enough.
#'
#' `cran_binary` is what renv's own rewrite made of `urls[["CRAN"]]`
#' (`renv_ppm_transform()`, in the installer). Bioconductor follows it:
#' only when renv rewrote CRAN (Linux, Package Manager, binaries for this
#' platform), only with the platform renv chose, and only for a
#' Bioconductor URL on the same host as CRAN. Anything else (macOS,
#' `file://` repositories, an on-prem server without Linux binaries)
#' changes nothing, and renv changes nothing either.
ppm_binary_repos <- function(urls, cran_binary) {
  if (is.null(cran_binary) || length(cran_binary) != 1 || is.na(cran_binary) ||
      !"CRAN" %in% names(urls)) return(urls)
  platform <- regmatches(cran_binary, regexec("/__linux__/([^/]+)/", cran_binary))[[1]]
  if (length(platform) < 2) return(urls)
  platform <- platform[[2]]
  host_of <- function(u) sub("^(https?://[^/]+).*$", "\\1", u)
  cran_host <- host_of(urls[["CRAN"]])
  bioc <- names(urls) %in% bioc_repo_names &
    grepl("^https?://", urls) &
    host_of(urls) == cran_host &
    !grepl("/__[^_/]+__/", urls)
  urls[bioc] <- sub("/([0-9]{4}-[0-9]{2}-[0-9]{2}/packages/)",
                    paste0("/__linux__/", platform, "/\\1"), urls[bioc])
  urls
}

#' Bioconductor's own repositories, one per release
#' (`<bioconductor_url>/3.23/bioc`). Not dated: each holds only the
#' latest version of a package in that release.
bioconductor_url <- "https://bioconductor.org/packages"

#' `urls` with Bioconductor's own software repository for the pinned
#' release added after Package Manager's, on macOS and Windows (#22).
#'
#' Package Manager doesn't build every Bioconductor binary that
#' Bioconductor does: for 3.23 on macOS arm64 it lacks 123 packages that
#' have code to compile and that Bioconductor has as binaries
#' (preprocessCore, affy, flowCore, ...). Those then build from source,
#' which on a Mac often needs a Fortran compiler it doesn't have
#' (`ld: library 'emutls_w' not found`). renv takes a binary only at the
#' locked version, so a package whose version has moved on since the
#' snapshot date still builds from source, as before.
#'
#' The name mustn't start with "BioC": renv reads no binaries from such a
#' repository unless it is BioCsoft. Only a dated Package Manager-style
#' `BioCsoft` URL over http(s) gets the addition, so `file://`
#' repositories (tests) never reach the network.
bioc_binary_repos <- function(urls, os = os_kind()) {
  if (identical(os, "linux") || !"BioCsoft" %in% names(urls)) return(urls)
  release <- regmatches(urls[["BioCsoft"]],
                        regexec("^https?://.*/[0-9]{4}-[0-9]{2}-[0-9]{2}/packages/([^/]+)/bioc$", urls[["BioCsoft"]]))[[1]]
  if (length(release) < 2) return(urls)
  c(urls, Bioconductor = paste0(bioconductor_url, "/", release[[2]], "/bioc"))
}

# ---- Bioconductor releases ---------------------------------------------------

#' Bioconductor's releases come from bioconductor.org's own list
#' (`ember_repos(bioc_config)`, `parse_bioc_config()`): each is built for
#' one R minor version, and each R minor version gets two (spring and
#' autumn). Ember ships no copy; a session fetches it when it first meets
#' Bioconductor, and the shell keeps the last one fetched on disk
#' (library.R), so a notebook that has resolved before still does while
#' bioconductor.org is down. `releases` below is that list, a data frame
#' `version`, `r`, `released` (the announcement date) in release order;
#' `empty_bioc_releases()` before it arrives.
empty_bioc_releases <- function() {
  data.frame(version = character(), r = character(), released = as.Date(character()),
             stringsAsFactors = FALSE)
}

#' Bioconductor's release list from the lines of its site's `config.yaml`
#' (https://bioconductor.org/config.yaml, the file BiocManager reads for
#' the same purpose): a data frame like `empty_bioc_releases()`, one row per
#' version that has both an R version (`r_ver_for_bioc_ver`) and a release
#' date (`release_dates`). The devel version has the former but not yet
#' the latter, so it is left out until it is released.
#'
#' Only those two flat maps are read, line by line, as BiocManager does,
#' so this needs no YAML parser. A line that doesn't parse is skipped; a
#' file with neither map gives no rows.
parse_bioc_config <- function(lines) {
  section <- function(name) {
    start <- grep(paste0("^", name, ":"), lines)
    if (length(start) == 0) return(character())
    rest <- lines[-seq_len(start[[1]])]
    # The map ends at the next line that is neither indented, blank nor a
    # comment: the next top-level key.
    end <- grep("^[^[:space:]#]", rest)
    if (length(end) > 0) rest <- rest[seq_len(end[[1]] - 1)]
    m <- regmatches(rest, regexec(
      "^[[:space:]]+[\"']?([0-9]+\\.[0-9]+)[\"']?[[:space:]]*:[[:space:]]*[\"']?([^\"'#[:space:]]+)", rest))
    m <- Filter(function(x) length(x) == 3, m)
    stats::setNames(vapply(m, `[[`, character(1), 3), vapply(m, `[[`, character(1), 2))
  }
  r <- section("r_ver_for_bioc_ver")
  dates <- section("release_dates")
  version <- intersect(names(r), names(dates))
  released <- as.Date(dates[version], format = "%m/%d/%Y")
  ok <- !is.na(released) & grepl("^[0-9]+\\.[0-9]+$", r[version])
  out <- data.frame(version = version[ok], r = unname(r[version][ok]), released = unname(released[ok]),
                    stringsAsFactors = FALSE)
  out <- out[order(out$released), , drop = FALSE]
  rownames(out) <- NULL
  out
}

#' The Bioconductor release a notebook on R `minor` resolves from at
#' `date`: the latest release for that R that was out by then. `NA` when
#' `releases` has no release for that R, or none was out yet at `date` (its
#' dated repository wouldn't exist); `bioc_unavailable_problem()` says so.
bioc_release_for <- function(minor, date, releases) {
  rows <- releases[releases$r == minor, , drop = FALSE]
  if (nrow(rows) == 0 || is.na(date)) return(NA_character_)
  out <- rows[rows$released <= as.Date(date), , drop = FALSE]
  if (nrow(out) == 0) NA_character_ else out$version[[nrow(out)]]
}

#' A `bioc_unavailable` row for a notebook with no Bioconductor release to
#' look in (`needed` holds no Bioconductor key) and a name not found
#' elsewhere, so "not found in any repository" isn't the only explanation.
#' None otherwise.
bioc_unavailable_problem <- function(needed, problems, header, r) {
  if (!is.na(bioc_release_in(needed)) || !any(problems$kind == "not_found")) {
    return(empty_package_problems())
  }
  package_problem("bioc_unavailable", NA_character_, sprintf(
    "Bioconductor has no release for R %s at %s, so Bioconductor packages can't be found",
    r$minor, header$snapshot))
}

#' The Bioconductor release a notebook uses: the header's pin when it has
#' one, otherwise the one for the running R at the snapshot date.
bioc_release_of <- function(header, r, releases) {
  if (!is.na(header$bioc_version)) return(header$bioc_version)
  bioc_release_for(r$minor, header$snapshot, releases)
}

#' Where a pinned notebook moves on the running R (design.md, "R itself"):
#' the release for `r` at the snapshot date when the pin was built for
#' another R minor version, since Package Manager builds a release's
#' binaries only for its own R. `NA` when there is nothing to move (no pin,
#' a pin `releases` doesn't know, or one built for this R) or nowhere to
#' move to (no release for this R at that date).
bioc_move_target <- function(header, r, releases) {
  pin <- header$bioc_version
  if (is.na(pin)) return(NA_character_)
  row <- match(pin, releases$version)
  if (is.na(row) || identical(releases$r[[row]], r$minor)) return(NA_character_)
  bioc_release_for(r$minor, header$snapshot, releases)
}

#' Problems with the header's Bioconductor pin, as `package_problem()`
#' rows: `"bioc_r_version"` when the release was built for another R than
#' the running one (and where running the notebook moves it, if anywhere:
#' `bioc_move_target()`), `"bioc_off_date"` when the snapshot date falls
#' outside the release's window (from its release to the next one), since
#' those CRAN and Bioconductor versions were never tested together. None
#' without a pin, or for a release `releases` doesn't know.
bioc_problems <- function(header, r, releases) {
  out <- empty_package_problems()
  v <- header$bioc_version
  if (is.na(v)) return(out)
  row <- match(v, releases$version)
  if (is.na(row)) return(out)
  if (!identical(releases$r[[row]], r$minor)) {
    target <- bioc_move_target(header, r, releases)
    then <- if (is.na(target)) {
      sprintf(paste0("; Bioconductor has no release for R %s at %s, so it stays on %s, ",
                     "and its packages build from source"), r$minor, header$snapshot, v)
    } else {
      sprintf("; running the notebook moves it to Bioconductor %s, which updates every Bioconductor package",
              target)
    }
    out <- rbind(out, package_problem("bioc_r_version", NA_character_, paste0(sprintf(
      "Bioconductor %s is built for R %s; this is R %s", v, releases$r[[row]], r$minor), then)))
  }
  if (!is.na(header$snapshot)) {
    date <- as.Date(header$snapshot)
    from <- releases$released[[row]]
    to <- if (row < nrow(releases)) releases$released[[row + 1]] else as.Date(Inf)
    if (date < from || date >= to) {
      out <- rbind(out, package_problem("bioc_off_date", NA_character_, sprintf(
        "the snapshot date %s is outside Bioconductor %s's release (%s to %s)", header$snapshot,
        v, format(from), if (is.finite(to)) format(to - 1) else "now")))
    }
  }
  out
}

# ---- GitHub sources ----------------------------------------------------------

#' A package can't come from GitHub by inference: the user names it in the
#' header's `[sources]`, `mypkg = "github:lab/mypkg"`, optionally with a
#' ref after `@` (a branch, a tag, or a commit). Each such entry becomes a
#' one-row index (`fetch_github_main()`, library.R) whose label is the
#' commit it resolved to, `"github:lab/mypkg@<40-character sha>"`, and that
#' label is the lock's source, so resolution needs no special case: the
#' GitHub keys go first in `needed`, and the first index that has a name
#' wins (design.md, "Package environments"). GitHub packages have no date,
#' so a date move keeps their commit (`source_keys()`).
#'
#' The GitHub API base, from `ember_repos(github)`.
github_api_url <- function(repos) sub("/+$", "", repos$github %||% "https://api.github.com")

#' A `github:` source string (a header spec, or a lock source) ->
#' `list(user, repo, ref)`, `ref` `NA` when there is no `@`. `NULL` when
#' `x` isn't one: any other scheme, or a malformed user or repository.
parse_github_source <- function(x) {
  if (length(x) != 1 || is.na(x)) return(NULL)
  m <- regmatches(x, regexec("^github:([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)(@([^[:space:]@]+))?$", x))[[1]]
  if (length(m) == 0) return(NULL)
  list(user = m[[2]], repo = m[[3]], ref = if (nzchar(m[[5]])) m[[5]] else NA_character_)
}

#' A `[sources]` spec as the user gave it, normalised: `"github:user/repo"`
#' as is, `"user/repo"` read as the same, and a link copied from the
#' browser read as what it names (`github_link_spec()`); `NULL` when it is
#' none of these.
github_spec <- function(x) {
  if (!is.character(x) || length(x) != 1 || is.na(x)) return(NULL)
  x <- trimws(x)
  if (is_github_link(x)) {
    x <- github_link_spec(x)
    if (is.null(x)) return(NULL)
  } else if (!grepl(":", x, fixed = TRUE)) {
    x <- paste0("github:", x)
  }
  if (is.null(parse_github_source(x))) NULL else x
}

#' `TRUE` for a string that starts as a github.com link does.
is_github_link <- function(x) grepl("^(https?://)?(www\\.)?github\\.com/", trimws(x), ignore.case = TRUE)

#' A github.com link -> its `github:` spec (#85): the repository's page,
#' `https://github.com/user/repo`, with or without a trailing `/` or
#' `.git`, is `"github:user/repo"`, and the page of a branch, tag or
#' commit (`.../tree/<ref>`, `.../commit/<sha>`, `.../releases/tag/<tag>`)
#' is `"github:user/repo@<ref>"`, the ref percent-decoded. A `?query` or
#' `#fragment` (`#readme`) is dropped. A folder's page,
#' `.../tree/main/R`, reads as the ref `main/R`: a link can't tell a ref
#' with a `/` from a ref and a path, so the lookup says there is no such
#' ref. Any other page of the repository (a file, an issue) is `NULL`: it
#' doesn't say which code to use. Only
#' github.com: a GitHub Enterprise host (`ember_repos(github)`) has its own
#' API base, which a link's host can't be matched to.
github_link_spec <- function(x) {
  x <- sub("/+$", "", sub("[?#].*$", "", x))
  m <- regmatches(x, regexec("^(https?://)?(www\\.)?github\\.com/([^/]+)/([^/]+)(/(tree|commit|releases/tag)/(.+))?$",
                             x, ignore.case = TRUE))[[1]]
  if (length(m) == 0) return(NULL)
  repo <- sub("\\.git$", "", m[[5]], ignore.case = TRUE)
  ref <- utils::URLdecode(m[[8]])
  if (startsWith(ref, "/")) return(NULL)
  paste0("github:", m[[4]], "/", repo, if (nzchar(ref)) paste0("@", ref))
}

#' The lock source for a commit: `"github:<user>/<repo>@<sha>"`.
github_source <- function(user, repo, sha) paste0("github:", user, "/", repo, "@", sha)

#' The repo key of a GitHub source at `ref` (`"HEAD"`: the default branch):
#' `"github/<user>/<repo>@<ref>"`. Like a dated key it names one index; a
#' key whose ref is a full commit (`is_commit()`) never changes, so its
#' index is cached on disk for good, as a dated one is. Any other ref (a
#' branch, a tag) moves, so its index is fetched again by each session that
#' needs it (shell.R).
github_key <- function(user, repo, ref) paste0("github/", user, "/", repo, "@", ref)

#' `github_key()`'s inverse: `list(user, repo, ref)`.
parse_github_key <- function(key) parse_github_source(sub("^github/", "github:", key))

is_github_key <- function(keys) startsWith(keys, "github/")

#' `TRUE` for a full, 40-character commit SHA.
is_commit <- function(x) grepl("^[0-9a-fA-F]{40}$", x)

# ---- r-universe sources ------------------------------------------------------

#' A package from an r-universe (#203) is named the same way:
#' `emberui = "universe:jowch"`, for `https://jowch.r-universe.dev`. A
#' universe serves only the latest build of each package, so the entry has
#' no ref, and the snapshot date doesn't apply: like a GitHub package, it
#' sits outside the one-date rule. Its one-row index
#' (`fetch_universe_main()`, library.R) is read from the universe's API,
#' which also says which git commit the build came from, and the lock
#' records that commit (`universe_source()`), so the lock still fixes the
#' code once the universe has moved on.
#'
#' The universe's URL, from `ember_repos(universe)`: `%s` is its name.
universe_url <- function(repos, universe) {
  sprintf(repos$universe %||% "https://%s.r-universe.dev", universe)
}

#' The repository name the installer gives a universe (`repo_urls()`).
universe_repo_name <- function(universe) paste0("universe-", universe)

#' A `universe:` header spec -> `list(universe)`, or `NULL` when `x`
#' isn't one. Names are r-universe's, which are lower case (a GitHub
#' account's name, as its subdomain).
parse_universe_spec <- function(x) {
  if (length(x) != 1 || is.na(x)) return(NULL)
  m <- regmatches(x, regexec("^universe:([a-z0-9][a-z0-9-]*)$", x))[[1]]
  if (length(m) == 0) NULL else list(universe = m[[2]])
}

#' `TRUE` for a string that starts as an r-universe link does.
is_universe_link <- function(x) {
  grepl("^(https?://)?[A-Za-z0-9][A-Za-z0-9-]*\\.r-universe\\.dev(/|$)", trimws(x), ignore.case = TRUE)
}

#' An r-universe link -> its `universe:` spec: the universe's page,
#' `https://jowch.r-universe.dev`, or any page in it (a package's,
#' `.../emberui`), is `"universe:jowch"`.
universe_link_spec <- function(x) {
  x <- sub("[?#].*$", "", trimws(x))
  m <- regmatches(x, regexec("^(https?://)?([A-Za-z0-9][A-Za-z0-9-]*)\\.r-universe\\.dev(/.*)?$",
                             x, ignore.case = TRUE))[[1]]
  if (length(m) == 0) NULL else paste0("universe:", tolower(m[[3]]))
}

#' The lock source for a package a universe built from a git commit:
#' `"universe:<name>/<host>/<path>@<sha>"`, the git repository written
#' without its `https://` (`universe:jowch/github.com/jowch/emberui@<sha>`),
#' and, for a package in a subdirectory of the repository, `//<subdir>`
#' after it, as Terraform writes one. The lock alone then says where to get
#' the code again: from the universe while it still serves that commit, and
#' from the repository itself after (`renv_lockfile_of()`). `NULL` when
#' `git` isn't an https URL.
universe_source <- function(universe, git, sha, subdir = NA_character_) {
  if (!is.character(git) || length(git) != 1 || is.na(git) || !grepl("^https://", git)) return(NULL)
  where <- sub("\\.git$", "", sub("/+$", "", sub("^https://", "", git)))
  sub_part <- if (!is.na(subdir) && nzchar(subdir)) paste0("//", sub("^/+|/+$", "", subdir)) else ""
  out <- paste0("universe:", universe, "/", where, sub_part, "@", tolower(sha))
  if (is.null(parse_universe_source(out))) NULL else out
}

#' A `universe:` lock source -> `list(universe, git, subdir, sha)`, `git`
#' the repository's https URL, `subdir` `NA` when the package is at its
#' top. `NULL` when `x` isn't one.
parse_universe_source <- function(x) {
  if (length(x) != 1 || is.na(x)) return(NULL)
  m <- regmatches(x, regexec(paste0("^universe:([a-z0-9][a-z0-9-]*)/",
                                    "([A-Za-z0-9.-]+(/[A-Za-z0-9._~-]+)+)",
                                    "(//([A-Za-z0-9._~/-]+))?@([0-9a-f]{40})$"), x))[[1]]
  if (length(m) == 0) return(NULL)
  list(universe = m[[2]], git = paste0("https://", m[[3]]),
       subdir = if (nzchar(m[[6]])) m[[6]] else NA_character_, sha = m[[7]])
}

#' `list(user, repo)` when a universe source's repository is on
#' github.com, else `NULL`.
universe_github_repo <- function(src) {
  m <- regmatches(src$git, regexec("^https://github\\.com/([^/]+)/([^/]+)$", src$git, ignore.case = TRUE))[[1]]
  if (length(m) == 0) NULL else list(user = m[[2]], repo = m[[3]])
}

#' The GitHub API that github.com repositories are read from: GitHub's own,
#' unless `ember_repos(github)` is a `file://` fixture (the test seam). A
#' GitHub Enterprise server set there serves its own repositories, not
#' github.com's.
github_com_api_url <- function(repos) {
  api <- github_api_url(repos)
  if (startsWith(api, "file://")) api else "https://api.github.com"
}

#' The repo key of a universe's latest build of `package`:
#' `"universe/<name>/<package>"`. It always moves, so its index is fetched
#' again by each session that needs it, as a GitHub branch's is.
universe_key <- function(universe, package) paste0("universe/", universe, "/", package)

#' The repo key of one commit a universe built, from the package's name
#' and its lock source: `"universe-commit/<package>/<name>/<host>/<path>@<sha>"`.
#' It never changes, so its index is cached on disk for good, and fetching
#' it needs nothing but the key (`repo_url()`): from GitHub when the
#' repository is there, else from the universe while it still serves that
#' commit.
universe_commit_key <- function(source, package) {
  sub("^universe:", paste0("universe-commit/", package, "/"), source)
}

#' `universe_commit_key()`'s inverse: the lock source.
universe_source_of_key <- function(key) sub("^universe-commit/[^/]+/", "universe:", key)

is_universe_key <- function(keys) startsWith(keys, "universe/") | startsWith(keys, "universe-commit/")

# ---- Either kind ---------------------------------------------------------------

#' A `[sources]` spec as the user gave it, normalised (`github_spec()`,
#' `universe_link_spec()`): `"universe:name"` or an r-universe link as
#' `"universe:name"`, anything else as GitHub's. `NULL` when it is none.
source_spec <- function(x) {
  if (!is.character(x) || length(x) != 1 || is.na(x)) return(NULL)
  x <- trimws(x)
  if (is_universe_link(x)) return(universe_link_spec(x))
  if (grepl("^universe:", x, ignore.case = TRUE)) {
    x <- paste0("universe:", tolower(sub("^universe:", "", x, ignore.case = TRUE)))
    return(if (is.null(parse_universe_spec(x))) NULL else x)
  }
  github_spec(x)
}

#' `TRUE` for a link `source_spec()` reads (a github.com or r-universe one).
is_source_link <- function(x) is_github_link(x) || is_universe_link(x)

#' `TRUE` for a readable `[sources]` spec of either kind.
is_readable_spec <- function(x) !is.null(parse_github_source(x)) || !is.null(parse_universe_spec(x))

#' `TRUE` for each lock source that came from a `[sources]` entry.
is_source_entry <- function(sources) startsWith(sources, "github:") | startsWith(sources, "universe:")

#' `TRUE` for a key whose index may hold another commit next time: a
#' GitHub branch, tag or `HEAD`, or a universe's latest build.
is_moving_source_key <- function(key) {
  (is_github_key(key) && !is_commit(parse_github_key(key)$ref)) || startsWith(key, "universe/")
}

#' Whether the lock's `source` still answers the header's `spec`: the same
#' repository (GitHub's names ignore case), and, when the spec names a
#' commit (7 to 40 hex digits), that commit. A branch or tag can't be
#' checked without the network, so any commit of the repository answers
#' it: the lock is what fixes the code, and a moving branch moves only when
#' the spec is changed (`source_keys()`).
source_satisfied <- function(spec, source) {
  u <- parse_universe_spec(spec)
  if (!is.null(u)) {
    l <- parse_universe_source(source)
    return(!is.null(l) && identical(l$universe, u$universe))
  }
  s <- parse_github_source(spec)
  l <- parse_github_source(source)
  if (is.null(s) || is.null(l) || is.na(l$ref)) return(FALSE)
  if (!identical(tolower(s$user), tolower(l$user)) || !identical(tolower(s$repo), tolower(l$repo))) {
    return(FALSE)
  }
  if (is.na(s$ref) || !grepl("^[0-9a-fA-F]{7,40}$", s$ref)) return(TRUE)
  startsWith(tolower(l$ref), tolower(s$ref))
}

#' The header's readable `[sources]`: named character, package -> spec,
#' sorted by name. Entries `is_readable_spec()` can't read are left out
#' (`source_problems()` reports them).
readable_sources <- function(header) {
  src <- header$sources %||% character()
  if (length(src) == 0) return(character())
  ok <- vapply(src, is_readable_spec, logical(1))
  src <- src[ok]
  src[order(names(src), method = "radix")]
}

#' Named character, package -> repo key, one per readable `[sources]`
#' entry. A package the lock already has from a commit that still answers
#' its spec (`source_satisfied()`), with the spec unchanged since that
#' resolution (`sources_for`), keeps that commit: its key names the commit,
#' so resolving again (or moving the date back) never moves it and its
#' index comes from the disk cache. Any other is looked up at its spec's
#' ref.
#'
#' `refresh`: moving the date forward ("update all", `refreshes_sources()`)
#' asks again for every entry whose ref can move (a branch, a tag, `HEAD`:
#' anything but a commit), so a branch comes forward with everything else.
#' A tag usually names the same commit again.
#'
#' A universe entry (`universe:name`) works the same way: a package locked
#' from that universe keeps its commit's key (`universe_commit_key()`), and
#' any other, or any at all on `refresh`, is looked up at the universe's
#' latest build (`universe_key()`).
source_keys <- function(header, lock, sources_for = character(), refresh = FALSE) {
  src <- readable_sources(header)
  if (length(src) == 0) return(character())
  e <- lock$entries
  keys <- vapply(names(src), function(name) {
    row <- match(name, e$name)
    universe <- parse_universe_spec(src[[name]])
    if (!is.null(universe)) {
      if (!refresh && !is.na(row) && source_unchanged(name, src, sources_for) &&
          source_satisfied(src[[name]], e$source[[row]])) {
        return(universe_commit_key(e$source[[row]], name))
      }
      return(universe_key(universe$universe, name))
    }
    spec <- parse_github_source(src[[name]])
    moving <- is.na(spec$ref) || !grepl("^[0-9a-fA-F]{7,40}$", spec$ref)
    if (!(refresh && moving) && !is.na(row) && source_unchanged(name, src, sources_for) &&
        source_satisfied(src[[name]], e$source[[row]])) {
      locked <- parse_github_source(e$source[[row]])
      if (is_commit(locked$ref)) return(github_key(spec$user, spec$repo, tolower(locked$ref)))
    }
    github_key(spec$user, spec$repo, if (is.na(spec$ref)) "HEAD" else spec$ref)
  }, character(1))
  stats::setNames(keys, names(src))
}

#' Whether a date move to `date` asks GitHub again for `[sources]` entries
#' at moving refs (`source_keys(refresh = TRUE)`): a move to the notebook's
#' date or later, which "update all" always is. A move back keeps the
#' locked commits: a branch has no date to go back to. A Bioconductor
#' move (`kind = "bioc"`) changes the release, not the date.
refreshes_sources <- function(header, date, kind = NULL) {
  if (identical(kind, "bioc")) return(FALSE)
  current <- header$snapshot %||% NA_character_
  if (is.na(current)) return(TRUE)
  isTRUE(as.Date(date) >= as.Date(current))
}

source_unchanged <- function(name, sources, sources_for) {
  name %in% names(sources_for) && identical(unname(sources_for[[name]]), unname(sources[[name]]))
}

#' The lock `resolve_lock()` keeps entries from, given the header's
#' `[sources]`: an entry stays only when its source still agrees with them.
#' A package with a spec keeps a GitHub or universe entry that answers the
#' unchanged spec; one whose spec changed, or that was locked from CRAN or
#' Bioconductor, is dropped so it resolves again from its own index. An
#' entry whose spec was removed is dropped too, so the package comes
#' from CRAN or Bioconductor again (or is `not_found`).
lock_for_sources <- function(lock, header, sources_for = character()) {
  e <- lock$entries
  if (is.null(e) || nrow(e) == 0) return(lock)
  src <- readable_sources(header)
  keep <- vapply(seq_len(nrow(e)), function(i) {
    name <- e$name[[i]]
    if (name %in% names(src)) {
      source_unchanged(name, src, sources_for) && source_satisfied(src[[name]], e$source[[i]])
    } else {
      !is_source_entry(e$source[[i]])
    }
  }, logical(1))
  if (all(keep)) return(lock)
  new_lock(e$name[keep], e$version[keep], e$source[keep], e$extra[keep], unparsed = lock$unparsed)
}

#' Problem rows for `[sources]`: a `"source"` row per entry that isn't a
#' readable `github:user/repo[@ref]` or `universe:name` (it is ignored, so
#' its package resolves from CRAN or Bioconductor as if it had none), and
#' per GitHub or universe index whose
#' package isn't the one the spec was written for (`indexes`: named list,
#' key -> loaded `ember_repo_index`).
source_problems <- function(header, keys = character(), indexes = list()) {
  out <- empty_package_problems()
  src <- header$sources %||% character()
  for (name in names(src)) {
    if (!is_readable_spec(src[[name]])) {
      out <- rbind(out, package_problem("source", name, sprintf(
        "can't read the source %s for %s: write it as \"github:user/repo\", optionally with @ and a branch, tag or commit, or as \"universe:name\" for an r-universe",
        src[[name]], name)))
    }
  }
  for (name in names(keys)) {
    idx <- indexes[[keys[[name]]]]
    if (!is.null(idx) && !(name %in% idx$name)) {
      out <- rbind(out, package_problem("source", name, sprintf(
        "%s holds the package %s, not %s", src[[name]], paste(idx$name, collapse = ", "), name)))
    }
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
#'   check). `NA` for a GitHub package whose DESCRIPTION doesn't say
#'   (`read_description_index()`).
#'
#' Built only by `read_repo_index()` and `read_description_index()`, at the boundary, so no other code
#' sees DCF field names. A dated index never changes once its date is past
#' (`index_may_change()`, #39), so a parsed copy is
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
  # highest package_version() per name. `order()` rather than `which.max()`,
  # which only accepts a package_version from R 4.4.
  groups <- split(seq_along(name), name)
  keep <- sort(vapply(groups, function(ix) {
    ix[order(package_version(version[ix]), decreasing = TRUE)[[1]]]
  }, integer(1)))

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
#'   version comes from `indexes` (a date move). `"bioc"`: CRAN and other
#'   entries are kept as in `"keep"`, Bioconductor's come from `indexes`
#'   (a move to another Bioconductor release at the same date).
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
#'     if hit is NULL and any key in `needed` is not in `indexes`:
#'       fetch += those keys; next
#'     if p in locked:
#'       e <- locked[p]
#'       if hit is NULL or hit's version != e$version:
#'         deps <- hit's deps if hit else character()
#'         if hit: problems += off_date(p, e$version, hit$version)
#'       else deps <- hit's deps
#'     else if hit is NULL:
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
resolve_lock <- function(roots, lock, indexes, needed, mode = c("keep", "fresh", "bioc")) {
  mode <- match.arg(mode)
  locked <- switch(mode, keep = lock$entries, fresh = lock$entries[0, ],
                   bioc = lock$entries[lock$entries$source != "Bioc", , drop = FALSE])
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

    # A name no loaded index has may be in one not fetched yet (Bioconductor's
    # are fetched only when asked for here): ask for it before deciding,
    # locked or not.
    if (is.null(hit)) {
      missing <- setdiff(needed, names(indexes))
      if (length(missing) > 0) {
        fetch <- union(fetch, missing)
        next
      }
    }

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

#' The repo keys a notebook's resolution consults, in lookup order: CRAN
#' at the snapshot date, then Bioconductor's three repositories at the
#' release `bioc_release_of()` gives, when there is one. Only the first
#' key is fetched up front; the others only when a name is missing from
#' CRAN (`resolve_lock()` asks for them through `fetch`), so a CRAN-only
#' notebook never downloads a Bioconductor index. `[sources]` GitHub keys
#' (later) go first.
needed_repos <- function(header, r, releases) {
  cran <- repo_key("cran", header$snapshot)
  release <- bioc_release_of(header, r, releases)
  if (is.na(release)) return(cran)
  c(cran, vapply(names(bioc_kinds), function(k) repo_key(k, header$snapshot, release),
                 character(1), USE.NAMES = FALSE))
}

#' `TRUE` for each of `keys` that is one of Bioconductor's.
is_bioc_key <- function(keys) {
  vapply(keys, function(k) strsplit(k, "/", fixed = TRUE)[[1]][[1]] %in% names(bioc_kinds),
         logical(1), USE.NAMES = FALSE)
}

#' The Bioconductor release a list of repo keys names, or `NA`.
bioc_release_in <- function(keys) {
  hit <- Filter(function(k) strsplit(k, "/", fixed = TRUE)[[1]][[1]] %in% names(bioc_kinds), keys)
  if (length(hit) == 0) NA_character_ else strsplit(hit[[1]], "/", fixed = TRUE)[[1]][[3]]
}
