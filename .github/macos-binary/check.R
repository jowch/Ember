# Install the binary in the current folder the way EndeavorMCP's runtime does
# (runtime/r/install.R), into a fresh library, and load it:
#
#   Rscript check.R <commit> <sha256>
args <- commandArgs(TRUE)
commit <- args[[1]]
sha256 <- args[[2]]
type <- .Platform$pkgType
stopifnot(startsWith(R.version$platform, "aarch64-apple-darwin"), type != "source")
here <- paste0("file://", normalizePath("."))
listed <- available.packages(contriburl = here, type = type, fields = "SHA256")
stopifnot("ember" %in% rownames(listed), listed["ember", "SHA256"] == sha256)
downloads <- tempfile("ember")
dir.create(downloads)
file <- download.packages("ember", downloads, contriburl = here, type = type, quiet = TRUE)[1, 2]
stopifnot(tools::sha256sum(file) == sha256)
lib <- tempfile("lib")
dir.create(lib)
install.packages(file, lib = lib, repos = NULL, type = type)
loadNamespace("ember", lib.loc = c(lib, .libPaths()))
stopifnot(dirname(getNamespaceInfo("ember", "path")) == normalizePath(lib))
stopifnot(packageDescription("ember", lib.loc = lib)$RemoteSha == commit)
cat("Ember", commit, "installs and loads from", file, "\n")
