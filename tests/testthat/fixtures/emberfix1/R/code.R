.onLoad <- function(libname, pkgname) {
  options(emberfix_load_opt = "fix1-load")
}

.onAttach <- function(libname, pkgname) {
  options(emberfix_attach_opt = "fix1-attach")
}

fix1_fun <- function() "fix1"
shared_fun <- function() "fix1"
