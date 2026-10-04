# Tests for R/recent.R: remember_notebook() and forget_notebook() over
# tools::R_user_dir("ember", "data") (docs/ui-3-tests.md, piece 4, unit
# test 87). setup-cache.R already points R_USER_DATA_DIR at a temp
# folder for the whole session; each test here points it at its own temp
# folder instead, so the tests don't interfere with each other.

# What remember_notebook() stores for a path: "D:/a.R" on Windows.
np <- function(p) normalizePath(p, winslash = "/", mustWork = FALSE)

with_recent_dir <- function(code) {
  dir <- tempfile("ember-test-recent-")
  withr::local_envvar(R_USER_DATA_DIR = dir)
  code
}

test_that("remember_notebook(): newest first, no duplicates, replaces (ui-3 87)", {
  with_recent_dir({
    expect_equal(read_recent(), character())

    remember_notebook("/a.R")
    remember_notebook("/b.R")
    remember_notebook("/a.R")
    expect_equal(read_recent(), np(c("/a.R", "/b.R")))

    remember_notebook("/c.R", replaces = "/b.R")
    expect_equal(read_recent(), np(c("/c.R", "/a.R")))
  })
})

test_that("remember_notebook(): at most 50 entries, newest first", {
  with_recent_dir({
    for (i in 1:55) remember_notebook(sprintf("/n%02d.R", i))
    recent <- read_recent()
    expect_length(recent, 50)
    expect_equal(recent[1], np("/n55.R"))
    expect_false(np("/n01.R") %in% recent)
    expect_false(np("/n05.R") %in% recent)
  })
})

test_that("forget_notebook(): drops the path, leaves the others", {
  with_recent_dir({
    remember_notebook("/a.R")
    remember_notebook("/b.R")
    forget_notebook("/a.R")
    expect_equal(read_recent(), np("/b.R"))
  })
})

test_that("read_recent(): a missing file reads as character()", {
  with_recent_dir({
    expect_equal(read_recent(), character())
  })
})

test_that("remember_notebook()/forget_notebook(): paths are normalised, so a trailing slash or a '.' segment is the same entry", {
  with_recent_dir({
    dir <- tempfile("ember-test-recent-norm-")
    dir.create(dir)
    plain <- file.path(dir, "a.R")
    writeLines("# x", plain)
    with_trailing_slash <- file.path(paste0(dir, "/"), "a.R")
    with_dot <- file.path(dir, ".", "a.R")

    remember_notebook(with_trailing_slash)
    expect_equal(read_recent(), normalizePath(plain, mustWork = FALSE))

    remember_notebook(with_dot)
    expect_equal(read_recent(), normalizePath(plain, mustWork = FALSE), label = "still one entry, not two")

    forget_notebook(with_trailing_slash)
    expect_equal(read_recent(), character())
  })
})

test_that("remember_notebook(): 'replaces' matches even when spelled differently than the stored entry", {
  with_recent_dir({
    dir <- tempfile("ember-test-recent-replaces-")
    dir.create(dir)
    old_plain <- file.path(dir, "old.R")
    writeLines("# x", old_plain)

    remember_notebook(old_plain)
    remember_notebook(file.path(dir, "new.R"), replaces = file.path(paste0(dir, "/"), "old.R"))
    expect_equal(read_recent(), np(file.path(dir, "new.R")))
  })
})

test_that("write_recent(): drops any path containing a newline or carriage return", {
  with_recent_dir({
    write_recent(c("/a.R", "/b\nad.R", "/c\rad.R", "/d.R"))
    expect_equal(read_recent(), c("/a.R", "/d.R"))
  })
})

test_that("remember_notebook(): an unwritable data folder gives no error", {
  skip_on_os("windows")
  if (identical(Sys.info()[["effective_user"]], "root") || Sys.getenv("USER") == "root") {
    skip("running as root: file.access() permission checks don't apply")
  }
  parent <- tempfile("ember-test-recent-parent-")
  dir.create(parent)
  Sys.chmod(parent, "0500")
  on.exit(Sys.chmod(parent, "0700"), add = TRUE)
  withr::local_envvar(R_USER_DATA_DIR = file.path(parent, "data"))

  expect_error(remember_notebook("/a.R"), NA)
  expect_error(forget_notebook("/a.R"), NA)
})
