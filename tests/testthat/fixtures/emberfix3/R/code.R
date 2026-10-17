# Like conflicted's conflicts_register(): `.emberfix3` sits at position 2.
# A name two attached packages export is an active binding there that
# fails when read, and its library() takes `.emberfix3` off the path,
# attaches, then puts it back.
shield <- function() {
  unshield()
  env <- attach(NULL, pos = 2L, name = ".emberfix3", warn.conflicts = FALSE)
  if (all(c("package:emberfix1", "package:emberfix2") %in% search())) {
    makeActiveBinding("shared_fun", function(value) stop("shared_fun found in 2 packages"), env)
  }
  assign("library", shim_library, envir = env)
  invisible(env)
}

unshield <- function() {
  if (".emberfix3" %in% search()) detach(".emberfix3", character.only = TRUE)
}

# conflicted's own shim, cut down: every argument is passed on, missing or not.
shim_library <- function(package, help, pos = 2, lib.loc = NULL, character.only = FALSE,
                         logical.return = FALSE, warn.conflicts, quietly = FALSE,
                         verbose = getOption("verbose"), mask.ok, exclude, include.only,
                         attach.required = missing(include.only)) {
  if (!character.only) package <- as.character(substitute(package))
  unshield()
  on.exit(shield())
  library(package, pos = pos, lib.loc = lib.loc, character.only = TRUE,
          logical.return = logical.return, warn.conflicts = FALSE, quietly = quietly,
          verbose = verbose, mask.ok = mask.ok, exclude = exclude,
          include.only = include.only, attach.required = attach.required)
}
