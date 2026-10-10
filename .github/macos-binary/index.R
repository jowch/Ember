# Write the PACKAGES index for one Ember binary in the current folder, so the
# folder (and the GitHub release it's uploaded to) is an R package repository
# with just that build:
#
#   Rscript index.R <file> <sha256>
#
# File names the binary, which is named by commit rather than by version, and
# SHA256 is what EndeavorMCP's runtime names installed builds by, as it does
# for r-universe's. No PACKAGES.rds: R reads PACKAGES.gz when it's missing.
args <- commandArgs(TRUE)
file <- args[[1]]
sha256 <- args[[2]]
tools::write_PACKAGES(".", type = "mac.binary")
packages <- read.dcf("PACKAGES")
stopifnot(nrow(packages) == 1, packages[1, "Package"] == "ember")
set <- function(m, field, value) {
  if (!field %in% colnames(m)) m <- cbind(m, matrix(NA_character_, nrow(m), 1, dimnames = list(NULL, field)))
  m[, field] <- value
  m
}
packages <- set(packages, "File", file)
packages <- set(packages, "SHA256", sha256)
write.dcf(packages, "PACKAGES")
gz <- gzfile("PACKAGES.gz", "wt")
write.dcf(packages, gz)
close(gz)
unlink("PACKAGES.rds")
