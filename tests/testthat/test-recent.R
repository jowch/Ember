# Tests for R/recent.R: remember_notebook() and forget_notebook() over
# tools::R_user_dir("ember", "data") (docs/ui-3-tests.md, piece 4, unit
# test 87). setup-cache.R already points R_USER_DATA_DIR at a temp
# folder for the whole session; each test here points it at its own temp
# folder instead, so the tests don't interfere with each other.

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
    expect_equal(read_recent(), c("/a.R", "/b.R"))

    remember_notebook("/c.R", replaces = "/b.R")
    expect_equal(read_recent(), c("/c.R", "/a.R"))
  })
})

test_that("remember_notebook(): at most 50 entries, newest first", {
  with_recent_dir({
    for (i in 1:55) remember_notebook(sprintf("/n%02d.R", i))
    recent <- read_recent()
    expect_length(recent, 50)
    expect_equal(recent[1], "/n55.R")
    expect_false("/n01.R" %in% recent)
    expect_false("/n05.R" %in% recent)
  })
})

test_that("forget_notebook(): drops the path, leaves the others", {
  with_recent_dir({
    remember_notebook("/a.R")
    remember_notebook("/b.R")
    forget_notebook("/a.R")
    expect_equal(read_recent(), "/b.R")
  })
})

test_that("read_recent(): a missing file reads as character()", {
  with_recent_dir({
    expect_equal(read_recent(), character())
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
