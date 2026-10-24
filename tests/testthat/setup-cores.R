# Under R CMD check --as-cran (_R_CHECK_LIMIT_CORES_ set) a check may use at
# most 2 cores. renv builds 4 packages at once by default and doesn't read
# that variable, so the install tests cap it for renv in the installer's
# child process too, which inherits this environment (#536).
if (nzchar(Sys.getenv("_R_CHECK_LIMIT_CORES_"))) Sys.setenv(RENV_CONFIG_INSTALL_JOBS = "2")
