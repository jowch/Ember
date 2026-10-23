# Serves a folder over HTTP, like a CRAN mirror, but cuts the first
# download (GET) of each package archive in half (#450): the body is shorter
# than the archive and the transfer still "succeeds", as a connection that
# drops mid-download leaves it. Later downloads are whole. Only renv GETs
# archives; Ember's own size checks are HEAD requests, which aren't cut.
#
#   Rscript cut-download-server.R <root> [refuse]
#
# With a number `refuse` as well, the first `refuse` downloads of each
# archive are refused outright instead (HTTP 404, no body), as a download
# that never starts (a host lookup that fails) leaves no file (#478).
#
# Prints "PORT <n>" once listening, then "GET <file> <count>" per archive
# download and "<method> <file> agent=<user agent>" per archive request.
# A request for /__quit makes it exit.
args <- commandArgs(trailingOnly = TRUE)
root <- args[[1]]
refuse <- if (length(args) > 1) as.integer(args[[2]]) else 0L
seen <- new.env()
done <- FALSE
app <- list(call = function(req) {
  if (identical(req$PATH_INFO, "/__quit")) {
    done <<- TRUE
    return(list(status = 200L, headers = list(`Content-Type` = "text/plain"), body = "bye"))
  }
  path <- file.path(root, utils::URLdecode(req$PATH_INFO))
  if (!file.exists(path) || dir.exists(path)) {
    return(list(status = 404L, headers = list(`Content-Type` = "text/plain"), body = "not found"))
  }
  body <- readBin(path, "raw", file.size(path))
  if (grepl("\\.(tar\\.gz|zip|tgz)$", path)) {
    cat(req$REQUEST_METHOD, basename(path), paste0("agent=", req$HTTP_USER_AGENT %||% ""), "\n")
    flush(stdout())
  }
  if (grepl("\\.(tar\\.gz|zip|tgz)$", path) && identical(req$REQUEST_METHOD, "GET")) {
    n <- (if (exists(path, seen, inherits = FALSE)) seen[[path]] else 0) + 1
    assign(path, n, envir = seen)
    cat("GET", basename(path), n, "\n")
    flush(stdout())
    if (n <= refuse) return(list(status = 404L, headers = list(`Content-Type` = "text/plain"), body = "refused"))
    if (refuse == 0 && n == 1) body <- body[seq_len(length(body) %/% 2)]
  }
  list(status = 200L, headers = list(`Content-Type` = "application/octet-stream"), body = body)
})
port <- httpuv::randomPort()
server <- httpuv::startServer("127.0.0.1", port, app)
cat("PORT", port, "\n")
flush(stdout())
while (!done) httpuv::service(1)
httpuv::stopServer(server)
