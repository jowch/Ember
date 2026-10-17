# The worker's compiled image (#229, R/shell.R): ready_worker_image()
# compiles worker.R once into the cache, and a worker booted with it runs
# compiled code from its first run.

is_compiled <- function(f) identical(typeof(.Internal(bodyCode(f))), "bytecode")

local_image_build <- function(env = parent.frame()) {
  saved <- as.list(worker_image_build)
  worker_image_build$path <- NULL
  worker_image_build$proc <- NULL
  withr::defer({
    p <- worker_image_build$proc
    if (!is.null(p) && p$is_alive()) p$kill()
    worker_image_build$path <- saved$path
    worker_image_build$proc <- saved$proc
  }, envir = env)
}

test_that("ready_worker_image(): one compile per image, then the image's path; older leftovers go", {
  local_image_build()
  dir <- withr::local_tempdir()
  src <- worker_script_path()
  path <- worker_image_path(src, dir)
  dir.create(file.path(dir, "worker"))
  stale <- file.path(dir, "worker", "R-0.0-old.Rc")
  fresh <- file.path(dir, "worker", "R-0.0-other.Rc")
  writeLines("x", stale)
  writeLines("x", fresh)
  Sys.setFileTime(stale, Sys.time() - 2 * 86400)

  expect_null(ready_worker_image(src, dir))
  proc <- worker_image_build$proc
  expect_true(inherits(proc, "process"))
  expect_null(ready_worker_image(src, dir))
  expect_identical(worker_image_build$proc, proc)  # no second compile

  proc$wait()
  expect_identical(proc$get_exit_status(), 0L)
  expect_identical(ready_worker_image(src, dir), path)
  expect_false(file.exists(stale))
  expect_true(file.exists(fresh))
  expect_identical(list.files(file.path(dir, "worker"), pattern = "\\.tmp$"), character())

  # The image defines what sourcing does, compiled.
  img <- new.env(parent = baseenv())
  compiler::loadcmp(path, img)
  sourced <- new.env(parent = baseenv())
  sys.source(src, sourced)
  expect_setequal(ls(img, all.names = TRUE), ls(sourced, all.names = TRUE))
  expect_true(is_compiled(img$run_cell))
  expect_false(is_compiled(sourced$run_cell))
})

test_that("a worker booted from the image runs cells; so does one sourced from worker.R, and a broken image falls back to it", {
  local_image_build()
  dir <- withr::local_tempdir()
  src <- worker_script_path()
  expect_null(ready_worker_image(src, dir))
  worker_image_build$proc$wait()
  path <- ready_worker_image(src, dir)

  for (image in c(path, "", file.path(dir, "broken.Rc"))) {
    if (nzchar(image) && !file.exists(image)) writeBin(as.raw(1:200), image)
    h <- worker_harness(image = image)
    for (i in 1:2) {
      h$send(list(type = "run", cell = paste0("c", i), token = i, code = paste0(i, " + 1"), role = "cell",
                  order = character(), settings = character(), formulas = list(), library = NULL, fig = NULL))
      r <- wait_for_done(h)
      expect_identical(r$status, "ok")
      expect_identical(r$output$text, paste0("[1] ", i + 1))
    }
    h$close()
  }
})
