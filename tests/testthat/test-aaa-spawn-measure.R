# Temporary measurement for #499, not to merge: how long a notebook's first
# run holds the server's loop on each OS, in a fresh, installed R. Fails on
# purpose so the numbers show in the check log.
test_that("measure: the first run's hold on the loop (#499)", {
  lines <- character()
  spawn <- NA_real_
  real <- start_worker_process
  local_mocked_bindings(start_worker_process = function(nb, fx) {
    t <- Sys.time(); on.exit(spawn <<- as.numeric(Sys.time() - t, units = "secs")); real(nb, fx)
  })
  for (k in 1:3) {
    path <- write_session_notebook(list(S = cell(""), A = cell("1")))
    nb <- open_notebook(path)
    spawn <- NA_real_
    t <- Sys.time()
    run_cells(nb, "A", wait = FALSE)
    held <- as.numeric(Sys.time() - t, units = "secs")
    wait_for(nb, is_idle, timeout = 30)
    first_spawn <- spawn
    spawn <- NA_real_
    t <- Sys.time()
    run_cells(nb, "A", wait = FALSE)
    warm <- as.numeric(Sys.time() - t, units = "secs")

    wait_for(nb, is_idle, timeout = 30)
    close_notebook(nb)
    lines <- c(lines, sprintf("notebook %d: first run_cells() %.3f s, of which the spawn %.3f s; a second run_cells() %.3f s", k, held, first_spawn, warm))
  }
  expect_true(FALSE, label = paste(c(R.version.string, Sys.info()[["sysname"]], lines), collapse = "\n"))
})
