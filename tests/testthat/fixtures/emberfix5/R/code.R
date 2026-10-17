# tune's .stash_last_result(): keep the last result in an entry of its own.
stash <- function(x) {
  if (!"org:emberfix5" %in% search()) {
    do.call("attach", list(new.env(), pos = length(search()), name = "org:emberfix5"))
  }
  env <- as.environment("org:emberfix5")
  env$.Last.emberfix5 <- x
  invisible(x)
}

# Like conflicted: an entry at position 2 whose `nchar` wins over base's.
prefer <- function() {
  if (!".emberfix5" %in% search()) {
    env <- attach(NULL, pos = 2L, name = ".emberfix5", warn.conflicts = FALSE)
    assign("nchar", function(x, ...) -1L, envir = env)
  }
  invisible()
}
