# Serves a folder over HTTP, like a CRAN mirror, but cuts renv's first
# download of each package archive in half (#450): the body is shorter
# than the archive and the transfer still "succeeds", as a connection that
# drops mid-download leaves it. Later downloads are whole.
#
#   Rscript cut-download-server.R <root>
#
# Prints "PORT <n>" once listening, then "GET <file> <count>" per archive
# request.
root <- commandArgs(trailingOnly = TRUE)[[1]]
seen <- new.env()
app <- list(call = function(req) {
  path <- file.path(root, utils::URLdecode(req$PATH_INFO))
  if (!file.exists(path) || dir.exists(path)) {
    return(list(status = 404L, headers = list(`Content-Type` = "text/plain"), body = "not found"))
  }
  body <- readBin(path, "raw", file.size(path))
  if (grepl("\\.(tar\\.gz|zip|tgz)$", path) && grepl("renv", req$HTTP_USER_AGENT %||% "")) {
    n <- (if (exists(path, seen, inherits = FALSE)) seen[[path]] else 0) + 1
    assign(path, n, envir = seen)
    cat("GET", basename(path), n, "\n")
    flush(stdout())
    if (n == 1) body <- body[seq_len(length(body) %/% 2)]
  }
  list(status = 200L, headers = list(`Content-Type` = "application/octet-stream"), body = body)
})
port <- httpuv::randomPort()
server <- httpuv::startServer("127.0.0.1", port, app)
cat("PORT", port, "\n")
flush(stdout())
repeat httpuv::service(1)
