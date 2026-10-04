# Tests for R/notebook-files.R: notebook_target_path() (the New notebook
# and rename/move forms) and complete_path() (Pluto's completepath
# request, behind FolderField and FilePicker). Pure functions, no server,
# no worker (docs/ui-3-tests.md, piece 4, unit tests 86 and 88).

test_that("notebook_target_path(): names, extensions and refusals (ui-3 86)", {
  folder <- tempfile("ember-target-")
  dir.create(folder)

  expect_equal(notebook_target_path("fit", folder), file.path(folder, "fit.R"))
  expect_equal(notebook_target_path("fit.r", folder), file.path(folder, "fit.r"))
  expect_equal(notebook_target_path("  fit  ", folder), file.path(folder, "fit.R"))

  for (bad_name in c("a/b", "..", "", ".")) {
    expect_error(notebook_target_path(bad_name, folder), class = "ember_refused")
  }

  missing_folder <- file.path(folder, "does-not-exist")
  expect_error(notebook_target_path("fit", missing_folder), class = "ember_refused")

  skip_on_os("windows")
  if (Sys.getenv("USER") != "root" && !identical(Sys.info()[["effective_user"]], "root")) {
    readonly_folder <- file.path(folder, "readonly")
    dir.create(readonly_folder)
    Sys.chmod(readonly_folder, "0500")
    on.exit(Sys.chmod(readonly_folder, "0700"), add = TRUE)
    expect_error(notebook_target_path("fit", readonly_folder), class = "ember_refused")
  }

  home <- path.expand("~")
  sub_name <- paste0("ember-target-test-", Sys.getpid())
  home_target_dir <- file.path(home, sub_name)
  dir.create(home_target_dir)
  on.exit(unlink(home_target_dir, recursive = TRUE), add = TRUE)
  expect_equal(notebook_target_path("fit", file.path("~", sub_name)),
              file.path(home_target_dir, "fit.R"))
})

test_that("notebook_target_path(): a trailing slash on the folder never doubles up against the name", {
  folder <- tempfile("ember-target-trailing-")
  dir.create(folder)
  with_slash <- notebook_target_path("fit", paste0(folder, "/"))
  without_slash <- notebook_target_path("fit", folder)
  expect_equal(with_slash, without_slash)
  expect_equal(with_slash, file.path(folder, "fit.R"))
})

test_that("notebook_target_path(): refuses control characters and Windows' reserved characters in the name", {
  folder <- tempfile("ember-target-chars-")
  dir.create(folder)
  for (bad_name in c("fit\nfit", "fit\tfit", "fit<x", "fit>x", "fit:x", 'fit"x', "fit|x", "fit?x", "fit*x")) {
    expect_error(notebook_target_path(bad_name, folder), class = "ember_refused", info = bad_name)
  }
})

test_that("complete_path(): prefix match, dirs_only, hidden entries, byte offsets (ui-3 88)", {
  dir <- tempfile("ember-complete-")
  dir.create(dir)
  dir.create(file.path(dir, "ab"))
  writeLines("", file.path(dir, "a.R"))
  writeLines("", file.path(dir, ".hidden"))

  query <- file.path(dir, "a")
  r <- complete_path(query)
  expect_setequal(unlist(r$results), c("a.R", "ab/"))
  expect_equal(r$start, nchar(dir) + 1L)
  expect_equal(r$stop, nchar(query, type = "bytes"))

  r_dirs <- complete_path(query, dirs_only = TRUE)
  expect_equal(unlist(r_dirs$results), "ab/")

  old_wd <- getwd()
  setwd(dir)
  on.exit(setwd(old_wd), add = TRUE)
  r_hidden <- complete_path(".h")
  expect_equal(unlist(r_hidden$results), ".hidden")
  expect_equal(r_hidden$start, 0L)
})

test_that("complete_path(): start/stop are UTF-8 byte offsets, not character offsets (non-ASCII folder)", {
  # "Jos\u00e9" is 4 characters but 5 bytes in UTF-8 ("\u00e9" takes 2):
  # a folder name where byte and character offsets disagree, so a test
  # using only ASCII paths (like the one above) can't tell `start` being
  # computed in characters apart from it being computed in bytes, which
  # is what the frontend (FolderField.js, FilePicker.js) actually needs --
  # both run `start`/`stop` through `utf8index_to_ut16index()`, the same
  # convention Pluto's own completepath protocol uses.
  parent <- tempfile("ember-complete-nonascii-")
  dir <- file.path(parent, "Jos\u00e9")
  dir.create(dir, recursive = TRUE)
  writeLines("", file.path(dir, "a.R"))

  query <- file.path(dir, "a")
  r <- complete_path(query)
  expect_equal(unlist(r$results), "a.R")
  expect_equal(r$start, nchar(dir, type = "bytes") + 1L)
  expect_false(r$start == nchar(dir) + 1L, info = "byte and character offsets really do differ here")
  expect_equal(r$stop, nchar(query, type = "bytes"))
})

test_that("complete_path(): a backslash also separates the folder from the typed part (Windows paths)", {
  # Backslash is an ordinary filename character on POSIX, so a folder
  # literally named "sub\\" (ending in one) can exist here too, letting
  # this run without actually being on Windows: what's under test is
  # complete_path()'s own separator regex, not the OS.
  parent <- tempfile("ember-complete-backslash-")
  dir.create(parent)
  sub <- file.path(parent, "sub\\")
  dir.create(sub)
  writeLines("", file.path(sub, "a.R"))

  old_wd <- getwd()
  setwd(parent)
  on.exit(setwd(old_wd), add = TRUE)

  r <- complete_path("sub\\a")
  expect_equal(unlist(r$results), "a.R")
  expect_equal(r$start, nchar("sub\\", type = "bytes"))
})

test_that("first_free_notebook_name(): notebook.R, then notebook-2.R, notebook-3.R, ...", {
  dir <- tempfile("ember-free-name-")
  dir.create(dir)
  expect_equal(first_free_notebook_name(dir), "notebook.R")

  writeLines("", file.path(dir, "notebook.R"))
  expect_equal(first_free_notebook_name(dir), "notebook-2.R")

  writeLines("", file.path(dir, "notebook-2.R"))
  expect_equal(first_free_notebook_name(dir), "notebook-3.R")
})

test_that("home_relative_folder(): abbreviates the home folder to ~, leaves other paths alone", {
  home <- path.expand("~")
  expect_equal(home_relative_folder(home), "~")
  expect_equal(home_relative_folder(file.path(home, "projects")), file.path("~", "projects"))
  expect_equal(home_relative_folder("/not/home"), "/not/home")
})
