# GitHub packages from the header's `[sources]` (#20): the spec helpers and
# lock conversion (resolve.R, lock.R), the one-row index fetch against the
# `file://` GitHub fixture (library.R), and the session core with `drive()`
# (packages-core.R), as test-packages-core.R does for CRAN and Bioconductor.
#
# The GitHub fixture (fixtures/github) is laid out as the GitHub API is:
# `repos/lab/toyC/commits/<ref>` holds the commit a ref names,
# `repos/lab/toyC/contents/<sha>/DESCRIPTION` that commit's DESCRIPTION, and
# `repos/lab/toyC/tarball/<sha>` the package renv installs. toyC imports toyB
# (from the toy CRAN fixture); it is 0.3.0 at C1 (tag v0.3.0, short sha
# 3f2a1c9) and 0.4.0 at C2 (main, HEAD).

C1 <- "3f2a1c90a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0"
C2 <- "8e4b7d2c1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c"

github_fixture <- function() {
  paste0("file://", normalizePath(testthat::test_path("fixtures", "github"), mustWork = TRUE))
}

#' A notebook file with `[sources]` and a lock.
src_file <- function(cells, sources = character(), lock = empty_lock(), snapshot = "2026-09-01") {
  new_notebook_file(
    header = new_header(ember_version = "0.1.0", r_version = "4.3.0", snapshot = snapshot,
                        sources = sources),
    cells = cells, run_order = names(cells), learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = lock, extra_blocks = list(), format = 1L, read_only = FALSE, problems = NULL)
}

r46 <- list(version = "4.6.1", minor = "4.6", platform = "x86_64-pc-linux-gnu")

src_state <- function(cells, ..., options = list()) {
  options$r <- options$r %||% r46
  options$bioc_releases <- options$bioc_releases %||%
    parse_bioc_config(readLines(testthat::test_path("fixtures", "bioc-config", "config.yaml"), warn = FALSE))
  new_state(src_file(cells, ...), path = "nb.R", id = "n1", options = options, at = 0)
}

cran_at <- function(date = "2026-09-01") {
  read_repo_index(testthat::test_path("fixtures", "repos", "cran", date, "src", "contrib", "PACKAGES"),
                  key = repo_key("cran", date), label = "CRAN")
}

#' The one-row index `fetch_github_main()` would save for `key`, built by
#' hand: package `name` at `version`, from commit `sha`, needing `deps`.
gh_index <- function(key, sha, name = "toyC", version = "0.4.0", deps = "cli", user = "lab", repo = "toyC") {
  new_repo_index(key, github_source(user, repo, sha), name, version, list(deps), FALSE)
}

effect_types_of <- function(r) vapply(r$effects, function(e) e$type, character(1))

effect_keys <- function(r) {
  vapply(Filter(function(e) identical(e$type, "fetch_index"), r$effects), function(e) e$key, character(1))
}

op_set_source <- function(name, source) list(op = "set_package_source", name = name, source = source)
op_remove_source <- function(name) list(op = "remove_package_source", name = name)

#' Open a notebook using toyC from `spec` and deliver both up-front indexes.
open_toyc <- function(spec = "github:lab/toyC", sha = C2, version = "0.4.0") {
  s <- src_state(list(S = cell(""), A = cell("library(toyC)")), sources = c(toyC = spec))
  r <- drive(s, ev_open(at(1)))
  key <- github_key("lab", "toyC", parse_github_source(spec)$ref %|NA|% "HEAD")
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_at(), at(2)))
  drive(r$state, ev_index_fetched(key, gh_index(key, sha, version = version), at(3)))
}
`%|NA|%` <- function(x, y) if (is.na(x)) y else x

# ---- Specs ------------------------------------------------------------------

test_that("a github: spec reads user, repo and an optional ref, and anything else reads as nothing", {
  expect_equal(parse_github_source("github:lab/mypkg"), list(user = "lab", repo = "mypkg", ref = NA_character_))
  expect_equal(parse_github_source("github:lab/my.pkg@feature/x")$ref, "feature/x")
  expect_equal(parse_github_source(paste0("github:lab/mypkg@", C1))$ref, C1)
  expect_null(parse_github_source("gitlab:lab/mypkg"))
  expect_null(parse_github_source("github:lab"))
  expect_null(parse_github_source("github:lab/mypkg@"))
  expect_null(parse_github_source(NA_character_))
  expect_equal(github_spec("lab/mypkg@v1"), "github:lab/mypkg@v1")
  expect_equal(github_spec(" github:lab/mypkg "), "github:lab/mypkg")
})

test_that("a github.com link reads as the source it names, and any other link as nothing (#85)", {
  expect_equal(github_spec("https://github.com/lab/mypkg"), "github:lab/mypkg")
  expect_equal(github_spec(" https://github.com/lab/my.pkg/ "), "github:lab/my.pkg")
  expect_equal(github_spec("https://github.com/lab/mypkg.git"), "github:lab/mypkg")
  expect_equal(github_spec("http://www.github.com/lab/mypkg#readme"), "github:lab/mypkg")
  expect_equal(github_spec("github.com/lab/mypkg?tab=readme-ov-file"), "github:lab/mypkg")
  expect_equal(github_spec("https://github.com/lab/mypkg/tree/v1.2"), "github:lab/mypkg@v1.2")
  expect_equal(github_spec("https://github.com/lab/mypkg/tree/feature/x/"), "github:lab/mypkg@feature/x")
  expect_equal(github_spec(paste0("https://github.com/lab/mypkg/tree/", C1)), paste0("github:lab/mypkg@", C1))
  expect_equal(github_spec(paste0("https://github.com/lab/mypkg/commit/", C1)), paste0("github:lab/mypkg@", C1))
  expect_equal(github_spec("https://github.com/lab/mypkg/releases/tag/v1.0"), "github:lab/mypkg@v1.0")
  expect_equal(github_spec("https://github.com/lab/mypkg/tree/fix%2312"), "github:lab/mypkg@fix#12")
  expect_equal(github_spec("HTTPS://GitHub.COM/Lab/MyPkg.GIT"), "github:Lab/MyPkg")
  # Pages that don't name the code to use, and other hosts.
  expect_null(github_spec("https://github.com/lab/mypkg/blob/main/R/a.R"))
  expect_null(github_spec("https://github.com/lab/mypkg/tree/"))
  expect_null(github_spec("https://github.com/lab/mypkg/tree//x"))
  expect_null(github_spec("https://github.com/lab/mypkg/releases"))
  expect_null(github_spec("https://github.com/lab"))
  expect_null(github_spec("https://github.example.com/lab/mypkg"))
  expect_null(github_spec("https://gitlab.com/lab/mypkg"))
  expect_null(github_spec("git@github.com:lab/mypkg.git"))
})

test_that("a locked commit answers a spec of the same repository, and a commit spec only when it is that commit", {
  locked <- github_source("lab", "toyC", C1)
  expect_true(source_satisfied("github:lab/toyC", locked))
  expect_true(source_satisfied("github:Lab/ToyC@main", locked))
  expect_true(source_satisfied("github:lab/toyC@3f2a1c9", locked))
  expect_true(source_satisfied(paste0("github:lab/toyC@", C1), locked))
  expect_false(source_satisfied("github:lab/toyC@8e4b7d2", locked))
  expect_false(source_satisfied("github:other/toyC", locked))
  expect_false(source_satisfied("github:lab/toyC", "CRAN"))
})

test_that("source_keys keeps a locked commit for an unchanged spec, and looks up the ref otherwise", {
  lock <- new_lock("toyC", "0.3.0", github_source("lab", "toyC", C1))
  header <- list(sources = c(toyC = "github:lab/toyC@main", other = "github:x/other", bad = "cran"))
  expect_equal(source_keys(header, lock, github_sources(header)),
               c(other = "github/x/other@HEAD", toyC = paste0("github/lab/toyC@", C1)))
  # The spec changed since the lock was resolved: look the new ref up.
  expect_equal(source_keys(header, lock, c(toyC = "github:lab/toyC@v0.3.0"))[["toyC"]],
               "github/lab/toyC@main")
  # A commit spec the lock doesn't hold.
  header$sources[["toyC"]] <- "github:lab/toyC@8e4b7d2"
  expect_equal(source_keys(header, lock, github_sources(header))[["toyC"]], "github/lab/toyC@8e4b7d2")
})

test_that("lock_for_sources drops entries that disagree with [sources] and keeps the rest", {
  lock <- new_lock(c("cli", "dplyr", "toyC"), c("3.6.5", "1.1.4", "0.3.0"),
                   c("CRAN", "CRAN", github_source("lab", "toyC", C1)))
  header <- list(sources = c(toyC = "github:lab/toyC"))
  expect_identical(lock_for_sources(lock, header, github_sources(header)), lock)
  # dplyr now has a source: its CRAN entry goes.
  header2 <- list(sources = c(toyC = "github:lab/toyC", dplyr = "github:tidy/dplyr"))
  expect_equal(lock_for_sources(lock, header2, github_sources(header2))$entries$name, c("cli", "toyC"))
  # toyC's source was removed: its GitHub entry goes.
  expect_equal(lock_for_sources(lock, list(sources = character()), character())$entries$name, c("cli", "dplyr"))
})

test_that("[sources] GitHub entry wins over a CRAN package of the same name (27)", {
  key <- github_key("tidy", "dplyr", "HEAD")
  gh <- gh_index(key, C2, name = "dplyr", version = "1.2.0.9000", deps = c("cli", "rlang"),
                 user = "tidy", repo = "dplyr")
  cran <- cran_at("2026-09-30")
  r <- resolve_lock("dplyr", empty_lock(), stats::setNames(list(gh, cran), c(key, cran$key)),
                    needed = c(key, cran$key))
  expect_true(r$complete)
  expect_equal(format_lock_lines(r$lock),
               c("cli 3.6.6 CRAN", paste("dplyr 1.2.0.9000", github_source("tidy", "dplyr", C2)),
                 "rlang 1.1.3 CRAN"))
})

# ---- The lock and renv -------------------------------------------------------

test_that("renv's record for a GitHub entry names the host, the commit and the dependencies", {
  lock <- new_lock(c("toyB", "toyC"), c("1.0", "0.3.0"), c("CRAN", github_source("lab", "toyC", C1)))
  r <- list(version = "4.6.1", minor = "4.6", platform = "x")
  lf <- renv_lockfile_of(lock, r, c(CRAN = "file:///toy/2026-09-01"), deps = list(toyC = "toyB"))
  rec <- lf$Packages$toyC
  expect_equal(rec[c("Source", "RemoteHost", "RemoteUsername", "RemoteRepo", "RemoteSha", "Imports")],
               list(Source = "GitHub", RemoteHost = "api.github.com", RemoteUsername = "lab",
                    RemoteRepo = "toyC", RemoteSha = C1, Imports = "toyB"))
  lf2 <- renv_lockfile_of(lock, r, c(CRAN = "x"), github = "file:///fixtures/github/")
  expect_equal(lf2$Packages$toyC$RemoteHost, "file:///fixtures/github")
  expect_null(lf2$Packages$toyC$Imports)
  expect_equal(renv_lockfile_of(lock, r, c(CRAN = "x"), github = "https://ghe.example.org/api/v3")$Packages$toyC$RemoteHost,
               "ghe.example.org/api/v3")
})

test_that("lock_diff calls a move to another commit a source change, even with a SHA for a version", {
  old <- new_lock("toyC", "0.4.0", github_source("lab", "toyC", C1))
  new <- new_lock("toyC", "0.4.0", github_source("lab", "toyC", C2))
  expect_equal(lock_diff(old, new)$change, "source")
  old <- new_lock("mypkg", "3f2a1c9", "github:lab/mypkg@3f2a1c9")
  new <- new_lock("mypkg", "8e4b7d2", "github:lab/mypkg@8e4b7d2")
  expect_equal(lock_diff(old, new)$change, "source")
  expect_equal(lock_diff(new_lock("toyC", "0.3.0", "CRAN"), new_lock("toyC", "0.4.0", "CRAN"))$change, "upgraded")
})

# ---- Fetching from the fixture ----------------------------------------------

test_that("fetch_github_main finds the ref's commit, reads its DESCRIPTION and saves it under both keys", {
  cache <- tempfile("ember-gh-cache-")
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  repos <- ember_repos(github = github_fixture())
  key <- github_key("lab", "toyC", "v0.3.0")
  fetch_github_main(key, repo_url(repos, key), index_rds_path(key, cache))
  idx <- fresh_index(key, cache)
  expect_equal(idx$name, "toyC")
  expect_equal(idx$version, "0.3.0")
  expect_equal(idx$label, github_source("lab", "toyC", C1))
  expect_equal(idx$deps, list("toyB"))
  pinned <- cached_index(github_key("lab", "toyC", C1), cache)
  expect_equal(pinned$label, idx$label)
  expect_equal(pinned$key, github_key("lab", "toyC", C1))

  short <- github_key("lab", "toyC", "3f2a1c9")
  fetch_github_main(short, repo_url(repos, short), index_rds_path(short, cache))
  expect_equal(fresh_index(short, cache)$label, github_source("lab", "toyC", C1))
})

test_that("fetch_github_main reads only the DESCRIPTION, and stops when a commit has none", {
  cache <- tempfile("ember-gh-cache-")
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  key <- github_key("lab", "toyC", "no-description")
  url <- repo_url(ember_repos(github = github_fixture()), key)
  expect_error(fetch_github_main(key, url, index_rds_path(key, cache)),
               "github:lab/toyC@no-description has no DESCRIPTION at its top level", fixed = TRUE)
  expect_equal(github_description_url("https://api.github.com/repos/lab/toyC", C1),
               paste0("https://api.github.com/repos/lab/toyC/contents/DESCRIPTION?ref=", C1))
  expect_equal(github_description_url("file:///f/repos/lab/toyC", C1),
               paste0("file:///f/repos/lab/toyC/contents/", C1, "/DESCRIPTION"))
})

test_that("a GitHub DESCRIPTION without NeedsCompilation leaves it unknown", {
  path <- tempfile()
  writeLines(c("Package: toyC", "Version: 0.4.0", "Imports: toyB"), path)
  idx <- read_description_index(path, "k", github_source("lab", "toyC", C2))
  expect_true(is.na(idx$needs_compilation))
  writeLines(c("Package: toyC", "Version: 0.4.0", "NeedsCompilation: yes"), path)
  expect_true(read_description_index(path, "k", "l")$needs_compilation)
})

test_that("a failed GitHub lookup says whether to suspect a private repository, the token or the rate limit", {
  where <- "github:lab/mypkg@HEAD"
  got <- function(status) list(ok = FALSE, status = status, detail = "x")
  expect_match(github_failure(where, got(404L), FALSE),
               "could not find github:lab/mypkg@HEAD on GitHub; if the repository is private, set GITHUB_PAT", fixed = TRUE)
  expect_match(github_failure(where, got(404L), TRUE), "the token can't see that repository", fixed = TRUE)
  expect_match(github_failure(where, got(422L), TRUE), "has no branch, tag or commit by that name", fixed = TRUE)
  expect_match(github_failure(where, got(403L), FALSE), "rate limit of 60 requests an hour without a token; set GITHUB_PAT", fixed = TRUE)
  expect_match(github_failure(where, got(429L), TRUE), "rate limit or the token's access", fixed = TRUE)
  expect_match(github_failure(where, got(401L), TRUE), "refused the token", fixed = TRUE)
  expect_match(github_failure(where, got(NA_integer_), FALSE), "could not reach GitHub for github:lab/mypkg@HEAD (x)", fixed = TRUE)
})

test_that("github_token takes GITHUB_PAT, then GITHUB_TOKEN, and asks no credential store for another host", {
  withr::local_envvar(GITHUB_PAT = "pat", GITHUB_TOKEN = "tok")
  expect_equal(github_token("https://api.github.com"), "pat")
  withr::local_envvar(GITHUB_PAT = NA)
  expect_equal(github_token("https://api.github.com"), "tok")
  withr::local_envvar(GITHUB_TOKEN = NA)
  expect_equal(github_token("file:///fixture"), "")
})

test_that("fetch_github_main stops, naming the source, when the ref isn't there", {
  cache <- tempfile("ember-gh-cache-")
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  key <- github_key("lab", "toyC", "no-such-branch")
  url <- repo_url(ember_repos(github = github_fixture()), key)
  expect_error(fetch_github_main(key, url, index_rds_path(key, cache)),
               "could not find github:lab/toyC@no-such-branch", fixed = TRUE)
  expect_false(file.exists(index_rds_path(key, cache)))
})

test_that("github_install_deps reads the cached commit's index, and fetches it when this cache never resolved it", {
  cache <- tempfile("ember-gh-cache-")
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  lock <- new_lock(c("toyB", "toyC"), c("1.0", "0.4.0"), c("CRAN", github_source("lab", "toyC", C2)))
  expect_equal(github_install_deps(lock, cache, github_fixture()), list(toyC = "toyB"))
  expect_true(file.exists(index_rds_path(github_key("lab", "toyC", C2), cache)))
  # Nothing to read: left to renv.
  missing <- new_lock("toyC", "0.4.0", github_source("lab", "toyC", strrep("0", 40)))
  expect_equal(github_install_deps(missing, tempfile(), github_fixture()), list())
})

# ---- The core ----------------------------------------------------------------

test_that("a package with a [sources] entry is looked up on GitHub together with CRAN's index", {
  s <- src_state(list(S = cell(""), A = cell("library(toyC)")), sources = c(toyC = "github:lab/toyC"))
  r <- drive(s, ev_open(at(1)))
  expect_setequal(effect_keys(r), c("github/lab/toyC@HEAD", "cran/2026-09-01"))
  fx <- Find(function(e) identical(e$key, "github/lab/toyC@HEAD"), r$effects)
  expect_equal(fx$url, "https://api.github.com/repos/lab/toyC")
  # CRAN's index alone doesn't resolve: toyC must not be looked for on CRAN.
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_at(), at(2)))
  expect_equal(r$state$file$lock$entries$name, character())
})

test_that("once both arrive the lock holds the commit, its dependencies come from CRAN, and the file says so", {
  r <- open_toyc()
  expect_equal(format_lock_lines(r$state$file$lock),
               c("cli 3.6.5 CRAN", paste("toyC 0.4.0", github_source("lab", "toyC", C2))))
  expect_equal(nrow(r$state$packages$problems), 0)
  expect_equal(r$state$packages$sources_for, c(toyC = "github:lab/toyC"))
  text <- format_notebook(notebook_file_of(r$state))
  expect_match(text, '# toyC = "github:lab/toyC"', fixed = TRUE)
  expect_match(text, paste0("# toyC 0.4.0 github:lab/toyC@", C2), fixed = TRUE)
  view <- packages_view(r$state)
  expect_equal(view$packages$source[view$packages$name == "toyC"], github_source("lab", "toyC", C2))
})

test_that("the install carries the GitHub API the packages come from", {
  s <- src_state(list(S = cell(""), A = cell("library(toyC)")), sources = c(toyC = "github:lab/toyC"),
                 options = list(repos = ember_repos(github = "file:///gh")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_at(), at(2)))
  r <- drive(r$state, ev_index_fetched("github/lab/toyC@HEAD", gh_index("github/lab/toyC@HEAD", C2), at(3)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(4)))
  r <- drive(r$state, ev_allow(at(5)))
  inst <- Find(function(e) identical(e$type, "install"), r$effects)
  expect_equal(inst$github, "file:///gh")
  expect_true(paste("toyC 0.4.0", github_source("lab", "toyC", C2)) %in% format_lock_lines(inst$lock))
})

test_that("a reopened notebook keeps its commit: no fetch at open, and the commit's key when the wanted set changes", {
  lock <- open_toyc()$state$file$lock
  s <- src_state(list(S = cell(""), A = cell("library(toyC)")), sources = c(toyC = "github:lab/toyC"),
                 lock = lock)
  r <- drive(s, ev_open(at(1)))
  expect_false("fetch_index" %in% effect_types_of(r))
  r <- drive(r$state, ev_apply(list(op_set_code("S", "library(viz)")), at(2)))
  pinned <- github_key("lab", "toyC", C2)
  expect_setequal(effect_keys(r), c(pinned, "cran/2026-09-01"))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_at(), at(3)))
  r <- drive(r$state, ev_index_fetched(pinned, gh_index(pinned, C2), at(4)))
  expect_equal(format_lock_lines(r$state$file$lock),
               c("cli 3.6.5 CRAN", paste("toyC 0.4.0", github_source("lab", "toyC", C2)), "viz 2.0.0 CRAN"))
})

test_that("a reopened notebook's failed install points a GitHub package's failed dependency back at it (#17)", {
  lock <- open_toyc()$state$file$lock
  s <- src_state(list(S = cell(""), A = cell("library(toyC)")), sources = c(toyC = "github:lab/toyC"),
                 lock = lock)
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(2)))
  r <- drive(r$state, ev_allow(at(3)))
  token <- r$state$packages$install$token
  failures <- data.frame(package = "cli", kind = "no_binary", detail = "3.6.5", stringsAsFactors = FALSE)
  r <- drive(r$state, ev_install_done(token, r$state$packages$target$key, NULL, "install failed",
                                      character(), at(4), failures = failures))
  # The lock's commit, not the branch: the walk reads what was installed.
  pinned <- github_key("lab", "toyC", C2)
  expect_setequal(effect_keys(r), c(pinned, "cran/2026-09-01"))
  r <- drive(r$state, ev_index_fetched(pinned, gh_index(pinned, C2), at(5)))
  view <- packages_view(r$state)
  expect_equal(view$library$failures$needed_by[[1]], "toyC")
  expect_equal(view$packages$status[view$packages$name == "toyC"], "failed")
  expect_identical(r$state$file$lock, lock)
})

test_that("changing the source looks the new ref up and moves the lock to its commit", {
  r <- open_toyc()
  r <- drive(r$state, ev_apply(list(op_set_source("toyC", "lab/toyC@v0.3.0")), at(4)))
  expect_equal(r$state$file$header$sources, c(toyC = "github:lab/toyC@v0.3.0"))
  expect_equal(effect_keys(r), "github/lab/toyC@v0.3.0")
  key <- "github/lab/toyC@v0.3.0"
  r <- drive(r$state, ev_index_fetched(key, gh_index(key, C1, version = "0.3.0"), at(5)))
  expect_equal(format_lock_lines(r$state$file$lock),
               c("cli 3.6.5 CRAN", paste("toyC 0.3.0", github_source("lab", "toyC", C1))))
  expect_equal(r$state$packages$sources_for, c(toyC = "github:lab/toyC@v0.3.0"))
})

test_that("removing the source sends the package back to CRAN, or to not_found when CRAN lacks it", {
  r <- open_toyc()
  r <- drive(r$state, ev_apply(list(op_remove_source("toyC")), at(4)))
  expect_equal(length(r$state$file$header$sources), 0)
  # Not on CRAN: looked for on Bioconductor, as any name CRAN lacks.
  bioc_keys <- vapply(names(bioc_kinds), function(k) repo_key(k, "2026-09-01", "3.23"), character(1))
  expect_setequal(effect_keys(r), bioc_keys)
  for (kind in names(bioc_kinds)) {
    idx <- read_repo_index(testthat::test_path("fixtures", "repos", "bioc", "2026-09-01", "packages", "3.23",
                                               bioc_kinds[[kind]], "src", "contrib", "PACKAGES"),
                           key = bioc_keys[[kind]], label = "Bioc")
    r <- drive(r$state, ev_index_fetched(bioc_keys[[kind]], idx, at(5)))
  }
  expect_equal(r$state$file$lock$entries$name, character())
  expect_true("toyC" %in% r$state$packages$problems$package[r$state$packages$problems$kind == "not_found"])

  # dplyr from GitHub, then from CRAN again.
  s <- src_state(list(S = cell(""), A = cell("library(dplyr)")), sources = c(dplyr = "github:tidy/dplyr"))
  key <- "github/tidy/dplyr@HEAD"
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_at(), at(2)))
  r <- drive(r$state, ev_index_fetched(key, gh_index(key, C2, name = "dplyr", version = "1.2.0.9000",
                                                     user = "tidy", repo = "dplyr"), at(3)))
  expect_equal(r$state$file$lock$entries$source[r$state$file$lock$entries$name == "dplyr"],
               github_source("tidy", "dplyr", C2))
  r <- drive(r$state, ev_apply(list(op_remove_source("dplyr")), at(4)))
  expect_equal(format_lock_lines(r$state$file$lock), c("cli 3.6.5 CRAN", "dplyr 1.1.4 CRAN", "glue 1.8.0 CRAN"))
})

test_that("a failed GitHub lookup doesn't fall back to CRAN: the lock stays and a row names the package, until running retries it", {
  s <- src_state(list(S = cell(""), A = cell("library(dplyr)")), sources = c(dplyr = "github:tidy/dplyr"))
  key <- "github/tidy/dplyr@HEAD"
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_at(), at(2)))
  r <- drive(r$state, ev_index_failed(key, "could not find github:tidy/dplyr@HEAD", at(3)))
  expect_equal(r$state$file$lock$entries$name, character())
  probs <- r$state$packages$problems
  expect_equal(probs$kind, "index_unavailable")
  expect_equal(probs$package, "dplyr")
  expect_match(probs$message, "github:tidy/dplyr", fixed = TRUE)
  expect_equal(effect_types_of(r), character())
  r <- drive(r$state, ev_run(NULL, at(4)))
  expect_true(key %in% effect_keys(r))
})

test_that("a source holding another package says so and resolves nothing", {
  s <- src_state(list(S = cell(""), A = cell("library(dplyr)")), sources = c(dplyr = "github:lab/toyC"))
  key <- "github/lab/toyC@HEAD"
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_at(), at(2)))
  r <- drive(r$state, ev_index_fetched(key, gh_index(key, C2), at(3)))
  expect_equal(r$state$file$lock$entries$name, character())
  probs <- r$state$packages$problems
  expect_equal(probs$kind, "source")
  expect_match(probs$message, "holds the package toyC, not dplyr", fixed = TRUE)
})

test_that("an unreadable source is reported and ignored", {
  s <- src_state(list(S = cell(""), A = cell("library(dplyr)")), sources = c(dplyr = "cran:dplyr"))
  expect_equal(s$packages$problems$kind, "source")
  r <- drive(s, ev_open(at(1)))
  expect_equal(effect_keys(r), "cran/2026-09-01")
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_at(), at(2)))
  expect_true("dplyr 1.1.4 CRAN" %in% format_lock_lines(r$state$file$lock))
  probs <- r$state$packages$problems
  expect_equal(probs$kind, "source")
  expect_match(probs$message, "can't read the source cran:dplyr for dplyr", fixed = TRUE)
})

test_that("a [sources] entry added by hand for a CRAN-locked package resolves at open and replaces the CRAN entry", {
  lock <- new_lock(c("cli", "glue", "dplyr"), c("3.6.5", "1.8.0", "1.1.4"), rep("CRAN", 3))
  s <- src_state(list(S = cell(""), A = cell("library(dplyr)")), sources = c(dplyr = "github:tidy/dplyr"),
                 lock = lock)
  expect_equal(s$packages$resolved_for, character())
  r <- drive(s, ev_open(at(1)))
  key <- "github/tidy/dplyr@HEAD"
  expect_setequal(effect_keys(r), c(key, "cran/2026-09-01"))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_at(), at(2)))
  r <- drive(r$state, ev_index_fetched(key, gh_index(key, C2, name = "dplyr", version = "1.2.0.9000",
                                                     user = "tidy", repo = "dplyr"), at(3)))
  expect_equal(format_lock_lines(r$state$file$lock),
               c("cli 3.6.5 CRAN", paste("dplyr 1.2.0.9000", github_source("tidy", "dplyr", C2))))
})

test_that("moving the date forward (update all) asks a branch again, and the preview shows its new commit", {
  r <- open_toyc("github:lab/toyC@main", sha = C1, version = "0.3.0")   # main was at C1
  expect_equal(format_lock_lines(r$state$file$lock)[[2]], paste("toyC 0.3.0", github_source("lab", "toyC", C1)))
  r <- drive(r$state, ev_preview_date("2026-09-30", at(4)))
  main <- github_key("lab", "toyC", "main")
  expect_setequal(effect_keys(r), c(main, "cran/2026-09-30"))
  # main has moved to C2.
  r <- drive(r$state, ev_index_fetched(main, gh_index(main, C2), at(5)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_at("2026-09-30"), at(6)))
  prop <- r$state$packages$proposal
  expect_equal(prop$status, "ready")
  expect_setequal(prop$changes$name, c("cli", "toyC"))
  expect_equal(prop$changes$to[prop$changes$name == "toyC"], "0.4.0")
  r <- drive(r$state, ev_set_date("2026-09-30", at(7)))
  expect_equal(format_lock_lines(r$state$file$lock),
               c("cli 3.6.6 CRAN", paste("toyC 0.4.0", github_source("lab", "toyC", C2))))
})

test_that("moving the date back keeps the GitHub commit and moves only the CRAN packages", {
  s <- src_state(list(S = cell(""), A = cell("library(toyC)")), sources = c(toyC = "github:lab/toyC"),
                 snapshot = "2026-09-30")
  head <- github_key("lab", "toyC", "HEAD")
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_at("2026-09-30"), at(2)))
  r <- drive(r$state, ev_index_fetched(head, gh_index(head, C2), at(3)))
  r <- drive(r$state, ev_preview_date("2026-09-01", at(4)))
  pinned <- github_key("lab", "toyC", C2)
  expect_setequal(effect_keys(r), c(pinned, "cran/2026-09-01"))
  r <- drive(r$state, ev_index_fetched(pinned, gh_index(pinned, C2), at(5)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_at("2026-09-01"), at(6)))
  prop <- r$state$packages$proposal
  expect_equal(prop$status, "ready")
  expect_equal(prop$changes$name, "cli")
})

test_that("a commit entry stays at its commit when the date moves forward", {
  short <- "3f2a1c9"
  r <- open_toyc(paste0("github:lab/toyC@", short), sha = C1, version = "0.3.0")
  r <- drive(r$state, ev_preview_date("2026-09-30", at(4)))
  expect_setequal(effect_keys(r), c(github_key("lab", "toyC", C1), "cran/2026-09-30"))
})

test_that("refreshes_sources: forward or the same date, not back, not a Bioconductor move", {
  h <- list(snapshot = "2026-09-01")
  expect_true(refreshes_sources(h, "2026-09-30"))
  expect_true(refreshes_sources(h, "2026-09-01"))
  expect_false(refreshes_sources(h, "2026-08-01"))
  expect_false(refreshes_sources(h, "2026-09-01", kind = "bioc"))
})

test_that("remove_package_source is refused without one package name, and removes nothing", {
  s <- src_state(list(S = cell("")), sources = c(toyC = "github:lab/toyC", other = "github:lab/other"))
  for (op in list(list(op = "remove_package_source"),
                  list(op = "remove_package_source", name = c("toyC", "other")),
                  list(op = "remove_package_source", name = NA_character_))) {
    r <- drive(s, ev_apply(list(op), at(1)))
    expect_match(conditionMessage(r$reply), "not a package name", fixed = TRUE)
    expect_length(r$state$file$header$sources, 2)
  }
  r <- drive(s, ev_apply(list(op_remove_source("other")), at(1)))
  expect_equal(r$state$file$header$sources, c(toyC = "github:lab/toyC"))
})

test_that("set_package_source is refused for a bad name or source", {
  s <- src_state(list(S = cell("")))
  r <- drive(s, ev_apply(list(op_set_source("toyC", "https://github.com/lab/toyC/blob/main/README.md")), at(1)))
  expect_match(conditionMessage(r$reply), "github:user/repo", fixed = TRUE)
  expect_match(conditionMessage(r$reply), "github.com link", fixed = TRUE)
  r <- drive(s, ev_apply(list(op_set_source("1bad", "lab/toyC")), at(1)))
  expect_match(conditionMessage(r$reply), "not a package name", fixed = TRUE)
  expect_equal(length(r$state$file$header$sources), 0)
})

test_that("a link is saved as its github: source, by the op and when the header is read (#85)", {
  s <- src_state(list(S = cell("")))
  r <- drive(s, ev_apply(list(op_set_source("toyC", "https://github.com/lab/toyC/tree/dev")), at(1)))
  expect_equal(r$state$file$header$sources, c(toyC = "github:lab/toyC@dev"))

  # Written by hand: a link is read as the op would save it, so the next
  # save writes no link. Anything else stays as written, for its problem
  # row: a bare "user/repo" is the op's shorthand, not the header's form.
  hand <- src_file(list(S = cell("")), sources = c(toyC = "https://github.com/lab/toyC.git",
                                                   other = "lab/other", bad = "cran:dplyr",
                                                   page = "https://github.com/lab/toyC/issues"))
  file <- parse_notebook(format_notebook(hand), new_id = new_id_seq(), version = "0.1.0")
  expect_equal(file$header$sources, c(toyC = "github:lab/toyC", other = "lab/other", bad = "cran:dplyr",
                                      page = "https://github.com/lab/toyC/issues"))
  text <- format_notebook(file)
  expect_true(grepl('# toyC = "github:lab/toyC"', text, fixed = TRUE))
  expect_false(grepl("toyC.git", text, fixed = TRUE))
})

# ---- The Packages tab's rows (#78) ------------------------------------------

view_row <- function(state, name) {
  v <- packages_view(state)$packages
  v[v$name == name, , drop = FALSE]
}

test_that("a not-found package given a source is looking up, then locked with its spec; a failed lookup keeps a row with the reason (121)", {
  s <- src_state(list(S = cell(""), A = cell("library(toyC)")), options = list(bioc_config = NA))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_at(), at(2)))
  for (k in effect_keys(r)) r <- drive(r$state, ev_index_failed(k, "offline", at(2)))
  row <- view_row(r$state, "toyC")
  expect_equal(row$status, "not_found")
  expect_true(is.na(row$spec))

  # The stale not_found problem is still there while the lookup runs, but
  # the row doesn't repeat it.
  r <- drive(r$state, ev_apply(list(op_set_source("toyC", "lab/nope")), at(3)))
  expect_equal(effect_keys(r), "github/lab/nope@HEAD")
  row <- view_row(r$state, "toyC")
  expect_equal(row$status, "looking_up")
  expect_equal(row$spec, "github:lab/nope")
  expect_true(is.na(row$message))

  # A typo: the lookup fails, nothing falls back, and the row stays to say why.
  r <- drive(r$state, ev_index_failed("github/lab/nope@HEAD", "could not find github:lab/nope@HEAD on GitHub", at(4)))
  row <- view_row(r$state, "toyC")
  expect_equal(nrow(row), 1)
  expect_equal(row$status, "source_failed")
  expect_true(row$direct)
  expect_match(row$message, "couldn't look up github:lab/nope for toyC", fixed = TRUE)

  # Fixed: looked up, then locked from the source.
  r <- drive(r$state, ev_apply(list(op_set_source("toyC", "lab/toyC")), at(5)))
  expect_equal(view_row(r$state, "toyC")$status, "looking_up")
  key <- "github/lab/toyC@HEAD"
  r <- drive(r$state, ev_index_fetched(key, gh_index(key, C2), at(6)))
  row <- view_row(r$state, "toyC")
  expect_equal(row$status, "missing")
  expect_equal(row$source, github_source("lab", "toyC", C2))
  expect_equal(row$spec, "github:lab/toyC")
  expect_true(is.na(row$message))
  expect_true(is.na(view_row(r$state, "cli")$spec))
})

test_that("a locked GitHub package whose new ref fails keeps its row and says why (121)", {
  r <- open_toyc()
  r <- drive(r$state, ev_apply(list(op_set_source("toyC", "lab/toyC@no-such-branch")), at(4)))
  expect_equal(view_row(r$state, "toyC")$status, "missing")
  r <- drive(r$state, ev_index_failed("github/lab/toyC@no-such-branch", "could not find github:lab/toyC@no-such-branch", at(5)))
  row <- view_row(r$state, "toyC")
  expect_equal(row$version, "0.4.0")
  expect_equal(row$spec, "github:lab/toyC@no-such-branch")
  expect_match(row$message, "couldn't look up github:lab/toyC@no-such-branch", fixed = TRUE)
})

test_that("a failed fetch's message drops R's wrapping, so the row reads as one sentence (121)", {
  # The job's output is one string (job_start()).
  expect_equal(fetch_error_message("Error: ember: could not find github:lab/nope@HEAD on GitHub\nExecution halted\n"),
               "could not find github:lab/nope@HEAD on GitHub")
  expect_equal(fetch_error_message(c("trying URL", "Error in f(x) : ", "  cannot open URL 'x'", "Execution halted")),
               "cannot open URL 'x'")
  expect_equal(fetch_error_message("Error in pkg::f(x) : boom\nExecution halted"), "boom")
  expect_equal(fetch_error_message(c("a", "b")), "a\nb")
})

test_that("a source answered while CRAN's index failed isn't left looking up: the row says why (121)", {
  s <- src_state(list(S = cell(""), A = cell("library(toyC)")), sources = c(toyC = "github:lab/toyC"))
  r <- drive(s, ev_open(at(1)))
  expect_equal(view_row(r$state, "toyC")$status, "looking_up")
  key <- "github/lab/toyC@HEAD"
  r <- drive(r$state, ev_index_fetched(key, gh_index(key, C2), at(2)))
  # Still waiting on CRAN's index.
  expect_equal(view_row(r$state, "toyC")$status, "looking_up")
  r <- drive(r$state, ev_index_failed(repo_key("cran", "2026-09-01"), "offline", at(3)))
  row <- view_row(r$state, "toyC")
  expect_equal(row$status, "source_failed")
  expect_equal(row$message, "offline")
})

test_that("a source needing Bioconductor is still looking up while the release list is fetched (121)", {
  s <- src_state(list(S = cell(""), A = cell("library(toyC)")), sources = c(toyC = "github:lab/toyC"))
  s$packages$bioc_releases$status <- "unknown"
  r <- drive(s, ev_open(at(1)))
  key <- "github/lab/toyC@HEAD"
  r <- drive(r$state, ev_index_fetched(key, gh_index(key, C2, deps = "limma"), at(2)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_at(), at(3)))
  expect_true("fetch_bioc_config" %in% effect_types_of(r))
  expect_equal(r$state$packages$bioc_releases$status, "fetching")
  row <- view_row(r$state, "toyC")
  expect_equal(row$status, "looking_up")
  expect_true(is.na(row$message))
})
