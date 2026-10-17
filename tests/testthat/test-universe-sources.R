# r-universe packages from the header's `[sources]` (#203): the spec and
# lock-source helpers (resolve.R), renv's record (lock.R), the one-row index
# fetch against the `file://` fixtures (library.R), and the session core
# with `drive()` (packages-core.R), as test-github-sources.R does for GitHub.
#
# The universe fixture (fixtures/universe/lab) is laid out as
# https://lab.r-universe.dev is: `api/packages/toyD` holds toyD's JSON, and
# `src/contrib` its built tarball. The universe serves toyD 0.2.0 built from
# commit D2 of github.com/lab/toyD. The GitHub fixture has that repository
# at D1 and D2, both 0.2.0, as a development version that doesn't bump its
# version would be; toyD_hello() says which commit it is.

D1 <- "1d0c4e8b2a7f6e5d4c3b2a1908f7e6d5c4b3a291"
D2 <- "2e1f5a9c3b8a7f6e5d4c3b2a1908f7e6d5c4b3a2"

universe_fixture <- function() {
  paste0("file://", normalizePath(testthat::test_path("fixtures", "universe"), mustWork = TRUE), "/%s")
}
github_fixture <- function() {
  paste0("file://", github_fixture_dir())
}
toyd_source <- function(sha) universe_source("lab", "https://github.com/lab/toyD", sha)

src_file <- function(cells, sources = character(), lock = empty_lock(), snapshot = "2026-09-01") {
  new_notebook_file(
    header = new_header(ember_version = "0.1.0", r_version = "4.3.0", snapshot = snapshot,
                        sources = sources),
    cells = cells, run_order = names(cells), learned = list(),
    sourced = data.frame(path = character(), hash = character(), stringsAsFactors = FALSE),
    lock = lock, extra_blocks = list(), format = 1L, read_only = FALSE, problems = NULL)
}

src_state <- function(cells, ..., options = list()) {
  options$r <- options$r %||% list(version = "4.6.1", minor = "4.6", platform = "x86_64-pc-linux-gnu")
  options$bioc_releases <- options$bioc_releases %||%
    parse_bioc_config(readLines(testthat::test_path("fixtures", "bioc-config", "config.yaml"), warn = FALSE))
  new_state(src_file(cells, ...), path = "nb.R", id = "n1", options = options, at = 0)
}

cran_at <- function(date = "2026-09-01") {
  read_repo_index(testthat::test_path("fixtures", "repos", "cran", date, "src", "contrib", "PACKAGES"),
                  key = repo_key("cran", date), label = "CRAN")
}

#' The one-row index `fetch_universe_main()` would save for `key`.
u_index <- function(key, sha, name = "toyD", version = "0.2.0", deps = "cli") {
  new_repo_index(key, toyd_source(sha), name, version, list(deps), FALSE)
}

effect_keys <- function(r) {
  vapply(Filter(function(e) identical(e$type, "fetch_index"), r$effects), function(e) e$key, character(1))
}

#' Open a notebook using toyD from lab's universe and deliver both indexes.
open_toyd <- function(sha = D2, snapshot = "2026-09-01") {
  s <- src_state(list(S = cell(""), A = cell("library(toyD)")), sources = c(toyD = "universe:lab"),
                 snapshot = snapshot)
  r <- drive(s, ev_open(at(1)))
  key <- universe_key("lab", "toyD")
  r <- drive(r$state, ev_index_fetched(repo_key("cran", snapshot), cran_at(snapshot), at(2)))
  drive(r$state, ev_index_fetched(key, u_index(key, sha), at(3)))
}

# ---- Specs and sources -------------------------------------------------------

test_that("a universe: spec or an r-universe link reads as the universe, and anything else as nothing", {
  expect_equal(source_spec("universe:lab"), "universe:lab")
  expect_equal(source_spec(" Universe:Lab "), "universe:lab")
  expect_equal(source_spec("https://jowch.r-universe.dev"), "universe:jowch")
  expect_equal(source_spec("jowch.r-universe.dev/emberui"), "universe:jowch")
  expect_equal(source_spec("https://Jowch.r-universe.dev/emberui/doc/readme.html#x"), "universe:jowch")
  expect_equal(source_spec("lab/toyC"), "github:lab/toyC")
  expect_null(source_spec("universe:"))
  expect_null(source_spec("universe:lab/toyD"))
  expect_null(source_spec("https://r-universe.dev/search"))
})

test_that("a universe lock source names the universe, the repository, a subdirectory and the commit", {
  s <- universe_source("jowch", "https://github.com/jowch/Ember.git", toupper(D1), "pkgs/emberui")
  expect_equal(s, paste0("universe:jowch/github.com/jowch/Ember//pkgs/emberui@", D1))
  expect_equal(parse_universe_source(s),
               list(universe = "jowch", git = "https://github.com/jowch/Ember", subdir = "pkgs/emberui", sha = D1))
  expect_equal(parse_universe_source(toyd_source(D2))$subdir, NA_character_)
  expect_equal(universe_github_repo(parse_universe_source(toyd_source(D2))), list(user = "lab", repo = "toyD"))
  expect_null(universe_github_repo(parse_universe_source(universe_source("x", "https://gitlab.com/g/sub/p", D1))))
  expect_null(universe_source("lab", "git@github.com:lab/toyD.git", D1))
  expect_null(universe_source("lab", NA_character_, D1))
  expect_null(parse_universe_source("universe:lab@abc"))
})

test_that("a universe entry keeps its locked commit, and asks for the latest build otherwise", {
  lock <- new_lock("toyD", "0.2.0", toyd_source(D1))
  header <- list(sources = c(toyD = "universe:lab", other = "universe:x"))
  keys <- source_keys(header, lock, readable_sources(header))
  expect_equal(keys[["toyD"]], universe_commit_key(toyd_source(D1), "toyD"))
  expect_equal(keys[["other"]], "universe/x/other")
  expect_equal(source_keys(header, lock, readable_sources(header), refresh = TRUE)[["toyD"]], "universe/lab/toyD")
  # Another universe's build doesn't answer the spec.
  header$sources[["toyD"]] <- "universe:elsewhere"
  expect_equal(source_keys(header, lock, readable_sources(header))[["toyD"]], "universe/elsewhere/toyD")
  expect_false(source_satisfied("universe:lab", "CRAN"))
  expect_false(source_satisfied("universe:lab", github_source("lab", "toyD", D1)))
  expect_true(is_moving_source_key("universe/lab/toyD"))
  expect_false(is_moving_source_key(universe_commit_key(toyd_source(D1), "toyD")))
  expect_false(index_may_change("universe/lab/toyD"))
})

test_that("lock_for_sources drops a universe entry once its source is gone or points elsewhere", {
  lock <- new_lock(c("cli", "toyD"), c("3.6.5", "0.2.0"), c("CRAN", toyd_source(D1)))
  header <- list(sources = c(toyD = "universe:lab"))
  expect_identical(lock_for_sources(lock, header, readable_sources(header)), lock)
  expect_equal(lock_for_sources(lock, list(sources = character()), character())$entries$name, "cli")
  moved <- list(sources = c(toyD = "github:lab/toyD"))
  expect_equal(lock_for_sources(lock, moved, readable_sources(moved))$entries$name, "cli")
})

test_that("a universe lock line reads back, and a move to another commit is a source change", {
  line <- paste("toyD 0.2.0", toyd_source(D1))
  expect_equal(format_lock_lines(parse_lock_lines(line)$lock), line)
  expect_equal(lock_diff(new_lock("toyD", "0.2.0", toyd_source(D1)),
                         new_lock("toyD", "0.2.0", toyd_source(D2)))$change, "source")
})

# ---- renv's record -----------------------------------------------------------

test_that("renv installs from the universe only while it serves the locked commit, then from the repository", {
  lock <- new_lock(c("toyB", "toyD"), c("1.0", "0.2.0"), c("CRAN", toyd_source(D1)))
  r <- list(version = "4.6.1", minor = "4.6", platform = "x")
  repos <- c(CRAN = "x", "universe-lab" = "https://lab.r-universe.dev")
  served <- renv_lockfile_of(lock, r, repos, deps = list(toyD = "toyB"), served = c(toyD = D1))$Packages$toyD
  expect_equal(served, list(Package = "toyD", Version = "0.2.0", Source = "Repository",
                            Repository = "universe-lab", Imports = "toyB"))
  # The universe moved on (same version, another commit), or can't be asked.
  for (now in list(c(toyD = D2), c(toyD = NA_character_), character())) {
    rec <- renv_lockfile_of(lock, r, repos, served = now)$Packages$toyD
    expect_equal(rec[c("Source", "RemoteHost", "RemoteUsername", "RemoteRepo", "RemoteSha")],
                 list(Source = "GitHub", RemoteHost = "api.github.com", RemoteUsername = "lab",
                      RemoteRepo = "toyD", RemoteSha = D1))
  }
  # A GitHub Enterprise API doesn't serve github.com's repositories.
  expect_equal(renv_lockfile_of(lock, r, repos, github = "https://ghe.example.org/api/v3")$Packages$toyD$RemoteHost,
               "api.github.com")
  # Elsewhere than GitHub: git, in the package's subdirectory.
  other <- new_lock("p", "1.0", universe_source("x", "https://codeberg.org/a/b", D1, "pkg"))
  rec <- renv_lockfile_of(other, r, c(CRAN = "x"))$Packages$p
  expect_equal(rec[c("Source", "RemoteType", "RemoteUrl", "RemoteSha", "RemoteSubdir")],
               list(Source = "Git", RemoteType = "git", RemoteUrl = "https://codeberg.org/a/b",
                    RemoteSha = D1, RemoteSubdir = "pkg"))
})

test_that("universe_wrong_builds names a universe build that isn't the locked commit", {
  lib <- tempfile("ember-u-lib-")
  on.exit(unlink(lib, recursive = TRUE), add = TRUE)
  write_desc <- function(pkg, sha) {
    dir.create(file.path(lib, pkg), recursive = TRUE)
    fields <- c(Package = pkg, Version = "0.2.0")
    if (!is.null(sha)) fields[["RemoteSha"]] <- sha
    write.dcf(t(fields), file.path(lib, pkg, "DESCRIPTION"))
  }
  write_desc("right", D1)
  write_desc("lagging", D2)
  write_desc("unsaid", NULL)
  write_desc("fallback", D2)
  src <- function(pkg) universe_source("lab", paste0("https://github.com/lab/", pkg), D1)
  lock <- new_lock(c("fallback", "lagging", "right", "toyB", "unsaid"), rep("0.2.0", 5),
                   c(src("fallback"), src("lagging"), src("right"), "CRAN", src("unsaid")))
  # `fallback` wasn't installed from its universe (served another commit), so
  # its record named the commit itself.
  served <- c(fallback = D2, lagging = D1, right = D1, unsaid = D1)
  expect_equal(universe_wrong_builds(lock, lib, served), c("lagging", "unsaid"))
})

test_that("repo_urls names each universe the lock's packages come from", {
  repos <- ember_repos(cran = "https://ppm/cran")
  header <- list(snapshot = "2026-09-01", bioc_version = NA_character_)
  lock <- new_lock(c("cli", "toyD"), c("3.6.5", "0.2.0"), c("CRAN", toyd_source(D1)))
  expect_equal(repo_urls(repos, header, lock),
               c(CRAN = "https://ppm/cran/2026-09-01", "universe-lab" = "https://lab.r-universe.dev"))
  expect_equal(repo_urls(repos, header), c(CRAN = "https://ppm/cran/2026-09-01"))
})

# ---- Fetching from the fixtures ----------------------------------------------

test_that("fetch_universe_main reads the latest build's JSON and saves it under both keys", {
  cache <- tempfile("ember-u-cache-")
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  repos <- ember_repos(universe = universe_fixture(), github = github_fixture())
  key <- universe_key("lab", "toyD")
  fetch_universe_main(key, repo_url(repos, key), index_rds_path(key, cache))
  idx <- fresh_index(key, cache)
  expect_equal(idx$name, "toyD")
  expect_equal(idx$version, "0.2.0")
  expect_equal(idx$label, toyd_source(D2))
  expect_equal(idx$deps, list("toyB"))
  expect_false(idx$needs_compilation)
  pinned <- cached_index(universe_commit_key(toyd_source(D2), "toyD"), cache)
  expect_equal(pinned$label, idx$label)
})

test_that("a commit the universe no longer serves is read from GitHub", {
  cache <- tempfile("ember-u-cache-")
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  repos <- ember_repos(universe = universe_fixture(), github = github_fixture())
  key <- universe_commit_key(toyd_source(D1), "toyD")
  expect_equal(repo_url(repos, key), paste0(github_fixture(), "/repos/lab/toyD"))
  fetch_universe_main(key, repo_url(repos, key), index_rds_path(key, cache))
  idx <- cached_index(key, cache)
  expect_equal(idx$label, toyd_source(D1))
  expect_equal(idx$deps, list("toyB"))
})

test_that("a missing package, a universe build without its commit, and a moved commit off GitHub each say so", {
  dir <- tempfile("ember-universe-")
  dir.create(file.path(dir, "x", "api", "packages"), recursive = TRUE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  base <- paste0("file://", normalizePath(dir), "/x")
  writeLines('{"Package": "nocommit", "Version": "1.0"}', file.path(dir, "x", "api", "packages", "nocommit"))
  writeLines(sprintf('{"Package": "p", "Version": "1.0", "RemoteUrl": "https://codeberg.org/a/p", "RemoteSha": "%s"}', D2),
             file.path(dir, "x", "api", "packages", "p"))
  expect_error(fetch_universe_main("universe/x/nope", base, tempfile()), "r-universe x has no package nope")
  expect_error(fetch_universe_main("universe/x/nocommit", base, tempfile()), "doesn't say which git commit")
  key <- universe_commit_key(universe_source("x", "https://codeberg.org/a/p", D1), "p")
  expect_error(fetch_universe_main(key, base, tempfile()), "no longer serves p at commit")
  # While it still serves the commit, the universe answers for it.
  key2 <- universe_commit_key(universe_source("x", "https://codeberg.org/a/p", D2), "p")
  path <- tempfile(fileext = ".rds")
  fetch_universe_main(key2, base, path)
  expect_equal(readRDS(path)$label, universe_source("x", "https://codeberg.org/a/p", D2))
})

test_that("universe_served says which commit each universe serves now", {
  lock <- new_lock(c("toyB", "toyD"), c("1.0", "0.2.0"), c("CRAN", toyd_source(D1)))
  repos <- c(CRAN = "x", "universe-lab" = sprintf(universe_fixture(), "lab"))
  expect_equal(universe_served(lock, repos), c(toyD = D2))
  expect_equal(universe_served(lock, c(CRAN = "x")), c(toyD = NA_character_))
  expect_equal(universe_served(new_lock("toyB", "1.0", "CRAN"), repos), character())
})

test_that("github_install_deps reads a universe package's dependencies, fetching its commit when needed", {
  cache <- tempfile("ember-u-cache-")
  on.exit(unlink(cache, recursive = TRUE), add = TRUE)
  lock <- new_lock(c("toyB", "toyD"), c("1.0", "0.2.0"), c("CRAN", toyd_source(D1)))
  expect_equal(github_install_deps(lock, cache, github_fixture()), list(toyD = "toyB"))
})

# ---- The core ----------------------------------------------------------------

test_that("a universe entry is looked up together with CRAN's index, and the lock holds its commit", {
  s <- src_state(list(S = cell(""), A = cell("library(toyD)")), sources = c(toyD = "universe:lab"))
  r <- drive(s, ev_open(at(1)))
  expect_setequal(effect_keys(r), c("universe/lab/toyD", "cran/2026-09-01"))
  fx <- Find(function(e) identical(e$key, "universe/lab/toyD"), r$effects)
  expect_equal(fx$url, "https://lab.r-universe.dev")
  r <- open_toyd()
  expect_equal(format_lock_lines(r$state$file$lock), c("cli 3.6.5 CRAN", paste("toyD 0.2.0", toyd_source(D2))))
  expect_equal(nrow(r$state$packages$problems), 0)
  text <- format_notebook(notebook_file_of(r$state))
  expect_match(text, '# toyD = "universe:lab"', fixed = TRUE)
  expect_match(text, paste("# toyD 0.2.0", toyd_source(D2)), fixed = TRUE)
})

test_that("the install is told where the universe is", {
  r <- open_toyd()
  r <- drive(r$state, ev_library_checked(r$state$packages$target$key, NULL, at(4)))
  r <- drive(r$state, ev_allow(at(5)))
  inst <- Find(function(e) identical(e$type, "install"), r$effects)
  expect_equal(inst$repos[["universe-lab"]], "https://lab.r-universe.dev")
})

test_that("a reopened notebook keeps the universe commit when the wanted set changes", {
  lock <- open_toyd(sha = D1)$state$file$lock
  s <- src_state(list(S = cell(""), A = cell("library(toyD)")), sources = c(toyD = "universe:lab"), lock = lock)
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_apply(list(op_set_code("S", "library(viz)")), at(2)))
  pinned <- universe_commit_key(toyd_source(D1), "toyD")
  expect_setequal(effect_keys(r), c(pinned, "cran/2026-09-01"))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_at(), at(3)))
  r <- drive(r$state, ev_index_fetched(pinned, u_index(pinned, D1), at(4)))
  expect_equal(format_lock_lines(r$state$file$lock),
               c("cli 3.6.5 CRAN", paste("toyD 0.2.0", toyd_source(D1)), "viz 2.0.0 CRAN"))
})

test_that("update all takes the universe's latest build, and moving the date back keeps the commit", {
  r <- open_toyd(sha = D1)
  r <- drive(r$state, ev_preview_date("2026-09-30", at(4)))
  expect_setequal(effect_keys(r), c("universe/lab/toyD", "cran/2026-09-30"))
  r <- drive(r$state, ev_index_fetched("universe/lab/toyD", u_index("universe/lab/toyD", D2), at(5)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-30"), cran_at("2026-09-30"), at(6)))
  prop <- r$state$packages$proposal
  expect_equal(prop$status, "ready")
  expect_true("toyD" %in% prop$changes$name)
  r <- drive(r$state, ev_set_date("2026-09-30", at(7)))
  expect_equal(format_lock_lines(r$state$file$lock)[[2]], paste("toyD 0.2.0", toyd_source(D2)))

  # Back: CRAN's earlier index is already loaded; the universe package
  # is asked for at its locked commit, not at the latest build.
  back <- drive(r$state, ev_preview_date("2026-09-01", at(8)))
  expect_equal(effect_keys(back), universe_commit_key(toyd_source(D2), "toyD"))
})

test_that("set_package_source takes a universe link and saves it as universe:", {
  s <- src_state(list(S = cell(""), A = cell("library(toyD)")))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_apply(list(list(op = "set_package_source", name = "toyD",
                                         source = "https://lab.r-universe.dev/toyD")), at(2)))
  expect_equal(r$state$file$header$sources, c(toyD = "universe:lab"))
  expect_true("universe/lab/toyD" %in% effect_keys(r))
})

test_that("a failed universe lookup names the package and doesn't fall back to CRAN", {
  s <- src_state(list(S = cell(""), A = cell("library(toyD)")), sources = c(toyD = "universe:lab"))
  r <- drive(s, ev_open(at(1)))
  r <- drive(r$state, ev_index_fetched(repo_key("cran", "2026-09-01"), cran_at(), at(2)))
  r <- drive(r$state, ev_index_failed("universe/lab/toyD", "ember: r-universe lab has no package toyD", at(3)))
  probs <- r$state$packages$problems
  expect_equal(probs$kind, "index_unavailable")
  expect_match(probs$message, "couldn't look up universe:lab for toyD: ember: r-universe lab has no package toyD", fixed = TRUE)
  expect_equal(nrow(r$state$file$lock$entries), 0)
})
