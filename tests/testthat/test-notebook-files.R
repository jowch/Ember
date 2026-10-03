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
