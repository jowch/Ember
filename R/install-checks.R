# Checks the installer (inst/installer.R) makes around renv: is there a
# compiler for the packages that will build from source, and does every
# installed package find the system libraries it links to. design.md,
# "Compilers"; packages.md, "Install checks".
#
# Knowledge owned here: how to tell a compiler is installed on each
# platform, which locked packages build from source, how to read `ldd`,
# Package Manager's system requirements API, and the words that tell the
# user what to install. Installing compilers or system libraries is the
# user's (design.md, Decisions); this only names them.
#
# The installer reports a missing piece on stderr as one line per package,
#   EMBER-MISSING <what> <package> <detail>
# with <what> one of `compiler` (detail: what to install), `system`
# (detail: the libraries not found, comma-separated, then the command
# that installs every package's) or `library` (detail: the libraries,
# when no command is known), followed by an `Error:` line that
# `install_failure_message()` shows. `install_failures()` turns the
# EMBER-MISSING lines into rows.

#' `"macos"`, `"windows"` or `"linux"` (anything else counts as Linux:
#' the checks below only need "not a Mac, not Windows").
os_kind <- function(sysname = Sys.info()[["sysname"]]) {
  switch(sysname, Darwin = "macos", Windows = "windows", "linux")
}

# ---- Compilers ---------------------------------------------------------------

#' A variable from `R CMD config`, or `""` when R can't say.
r_config <- function(var) {
  out <- tryCatch(suppressWarnings(system2(file.path(R.home("bin"), "R"), c("CMD", "config", var),
                                           stdout = TRUE, stderr = FALSE)),
                  error = function(e) character())
  if (length(out) == 0) "" else trimws(out[[1]])
}

#' Whether this machine can build a package with C code.
#'
#' On a Mac, Apple's command line tools: `xcode-select -p` fails without
#' them. `Sys.which("clang")` is no test there, since `/usr/bin/clang` is
#' a stub that offers to install the tools. Elsewhere, the C compiler R
#' was configured with (`R CMD config CC`, `gcc` or `clang`; on Windows
#' Rtools' gcc, which R's own Renviron puts on the PATH) must be on the
#' PATH. The Fortran compiler isn't checked here: only some packages need
#' it, and nothing says which before their source is unpacked, so its
#' absence is caught from the build's own output (`install_failures()`).
has_compiler <- function(os = os_kind()) {
  if (identical(os, "macos")) {
    status <- tryCatch(suppressWarnings(system2("xcode-select", "-p", stdout = FALSE, stderr = FALSE)),
                       error = function(e) 1L)
    return(identical(as.integer(status), 0L))
  }
  cc <- strsplit(r_config("CC"), "\\s+")[[1]]
  cc <- cc[nzchar(cc)]
  if (length(cc) == 0) return(TRUE)  # R can't say; don't stop an install over it
  nzchar(Sys.which(cc[[1]]))
}

#' Which Linux this is, from `/etc/os-release`: `list(id, version, like)`,
#' or `NULL` when the file can't be read. `like` is `ID_LIKE` split into
#' words, so a derivative (Linux Mint, Pop!_OS) still gets its parent's
#' package manager.
linux_release <- function(lines = if (file.exists("/etc/os-release"))
                            tryCatch(readLines("/etc/os-release", warn = FALSE),
                                     error = function(e) NULL)) {
  if (is.null(lines)) return(NULL)
  field <- function(name) {
    hit <- grep(paste0("^", name, "="), lines, value = TRUE)
    if (length(hit) == 0) return("")
    gsub("^[\"']|[\"']$", "", sub(paste0("^", name, "="), "", hit[[1]]))
  }
  list(id = tolower(field("ID")), version = field("VERSION_ID"),
       like = strsplit(tolower(field("ID_LIKE")), "\\s+")[[1]])
}

#' The package manager family of a Linux release: `"apt"`, `"dnf"`,
#' `"zypper"`, or `NA`.
linux_family <- function(release) {
  if (is.null(release)) return(NA_character_)
  ids <- c(release$id, release$like)
  if (any(ids %in% c("debian", "ubuntu"))) return("apt")
  if (any(ids %in% c("rhel", "fedora", "centos", "rocky", "almalinux"))) return("dnf")
  if (any(ids %in% c("suse", "opensuse", "sles", "opensuse-leap", "opensuse-tumbleweed"))) return("zypper")
  NA_character_
}

#' `sudo ` unless this process is root (a container, a cloud machine) or
#' there is no `sudo` to run.
sudo_prefix <- function(user = Sys.info()[["effective_user"]], has_sudo = nzchar(Sys.which("sudo"))) {
  if (identical(user, "root") || !has_sudo) "" else "sudo "
}

#' For someone who can't run the install command: most shared servers
#' have `sudo`, but its users may not use it. Shown with every missing
#' system library, on the page and in the install's message.
no_admin_sentence <- paste("On a shared server or cluster, ask its administrator to install",
                           "them, or load a module that provides them before starting R.")

#' What to install so packages can build from source, as one or two
#' sentences for the user. `fortran`: the build failed for want of a
#' Fortran compiler rather than a C one.
compiler_instructions <- function(fortran = FALSE, os = os_kind(), release = linux_release(),
                                  sudo = sudo_prefix(), r_version = getRversion()) {
  if (identical(os, "macos")) {
    if (fortran) {
      return(paste("Install the Fortran compiler R uses on macOS, from",
                   "https://mac.r-project.org/tools/, then try again."))
    }
    return(paste("Install Apple's command line tools: run `xcode-select --install`",
                 "in Terminal, then try again."))
  }
  if (identical(os, "windows")) {
    minor <- paste(unlist(r_version)[1:2], collapse = ".")
    return(sprintf(paste("Install Rtools for R %s from",
                         "https://cran.r-project.org/bin/windows/Rtools/, then try again."), minor))
  }
  cmd <- switch(linux_family(release),
                apt = "apt-get install -y build-essential gfortran",
                dnf = "dnf install -y gcc gcc-c++ gcc-gfortran make",
                zypper = "zypper install -y gcc gcc-c++ gcc-fortran make",
                NULL)
  if (is.null(cmd)) {
    return(paste("Install a C, C++ and Fortran compiler (gcc, g++ and gfortran)",
                 "with your system's package manager, then try again."))
  }
  sprintf("Install the compilers with `%s%s`, then try again.", sudo, cmd)
}

#' The locked packages that will build from source and have code to
#' compile: the ones a missing compiler stops.
#'
#' * `wanted`: named character, package -> locked version (CRAN and
#'   Bioconductor entries).
#' * `source_index`: `available.packages()` matrix of the source
#'   repositories (needs `NeedsCompilation`).
#' * `binary_index`: the same for the binary repositories, or `NULL` when
#'   there are none (Linux without Package Manager binaries for this
#'   system): then every package builds from source. renv installs a
#'   binary only at the locked version, so a binary at any other version
#'   doesn't count.
#'
#' A package missing from the source index isn't named: renv will say it
#' can't find it, which is the clearer error.
source_builds <- function(wanted, source_index, binary_index) {
  if (length(wanted) == 0) return(character())
  has_binary <- if (is.null(binary_index)) {
    rep(FALSE, length(wanted))
  } else {
    key <- paste(binary_index[, "Package"], binary_index[, "Version"])
    paste(names(wanted), wanted) %in% key
  }
  src <- source_index[source_index[, "Package"] %in% names(wanted), , drop = FALSE]
  compiled <- src[!is.na(src[, "NeedsCompilation"]) & src[, "NeedsCompilation"] == "yes", "Package"]
  sort(unique(names(wanted)[!has_binary & names(wanted) %in% compiled]))
}

#' An `available.packages()` matrix for `repos` of `type`, or `NULL` when
#' any of them can't be read. No filters: the lock already chose the
#' versions, and the R version filter would hide the very packages that
#' need a newer R.
read_available <- function(repos, type) {
  tryCatch(suppressWarnings(utils::available.packages(
    contriburl = utils::contrib.url(repos, type), filters = list(),
    fields = "NeedsCompilation")), error = function(e) NULL)
}

#' The compiler check, before renv runs: `NULL` when nothing stops the
#' install, else `list(packages, instructions)`.
#'
#' Cheap in the usual case: the compiler is there, or no package builds
#' from source. The repository indexes are read only when the compiler is
#' missing. `linux_binaries`: whether renv will install Package Manager's
#' Linux binaries (the installer knows from renv's own URL rewrite);
#' unused elsewhere: with them nothing builds from source, and the
#' compiler isn't even looked for. `binary_type`: the binary repositories'
#' type on macOS and Windows (a parameter so tests on Linux can ask for a
#' Mac's). GitHub sources aren't counted: whether they have code to
#' compile is known only once they're downloaded, so a missing compiler
#' shows up from their build instead.
compiler_check <- function(lock, repos, linux_binaries = FALSE, os = os_kind(),
                           compiler = NULL, binary_type = .Platform$pkgType) {
  linux <- identical(os, "linux")
  if (linux && linux_binaries) return(NULL)
  if (is.null(compiler)) compiler <- has_compiler(os)
  if (isTRUE(compiler)) return(NULL)
  entries <- lock$entries[lock$entries$source %in% c("CRAN", "Bioc"), , drop = FALSE]
  if (nrow(entries) == 0) return(NULL)
  wanted <- stats::setNames(entries$version, entries$name)
  source_index <- read_available(repos, "source")
  if (is.null(source_index)) return(NULL)
  # On Linux without Package Manager binaries everything builds from
  # source; elsewhere an unreadable binary index leaves it to renv.
  binary_index <- if (linux) NULL else read_available(repos, binary_type)
  if (!linux && is.null(binary_index)) return(NULL)
  pkgs <- source_builds(wanted, source_index, binary_index)
  if (length(pkgs) == 0) return(NULL)
  list(packages = pkgs, instructions = compiler_instructions(os = os))
}

# ---- System libraries --------------------------------------------------------

#' The libraries `ldd` couldn't find, from its output for one or more
#' files: data frame `file`, `lib`. With one file `ldd` prints no
#' `<file>:` header, so `files` says which it was. R's own libraries
#' (`libR.so`, `libRblas.so`, `libRlapack.so`) are left out: R finds them
#' itself when it loads a package.
parse_ldd <- function(lines, files) {
  file <- if (length(files) == 1) files[[1]] else NA_character_
  out_file <- character(); out_lib <- character()
  for (line in lines) {
    if (length(files) > 1 && grepl(":$", line) && !grepl("^\\s", line)) {
      file <- sub(":$", "", line)
      next
    }
    m <- regmatches(line, regexec("^\\s*(\\S+) => not found", line))[[1]]
    if (length(m) == 2 && !grepl("^libR(blas|lapack)?\\.so", m[[2]])) {
      out_file <- c(out_file, file)
      out_lib <- c(out_lib, m[[2]])
    }
  }
  data.frame(file = out_file, lib = out_lib, stringsAsFactors = FALSE)
}

#' Which installed packages link to a library this machine doesn't have:
#' named list, package -> character of library file names (`libgdal.so.34`),
#' empty when all are found or `ldd` isn't there. Linux only.
#'
#' Run after renv and before the library is made ready. A Package Manager
#' binary installs ("* DONE") without the system libraries it links to,
#' and fails only when a cell loads it, with a linker error. `ldd` asks
#' the same loader R will use, so a library from somewhere other than the
#' system's packages (an HPC module, conda, `/usr/local`) counts as found,
#' which a check of the package manager's database would get wrong.
missing_system_libraries <- function(library, packages) {
  ldd <- Sys.which("ldd")
  if (!nzchar(ldd)) return(list())
  # Each file's package, keyed by the path ldd echoes back (the one passed).
  pkg_of <- unlist(lapply(packages, function(p) {
    f <- list.files(file.path(library, p, "libs"), pattern = "\\.so$", recursive = TRUE, full.names = TRUE)
    stats::setNames(rep(p, length(f)), f)
  }))
  files <- names(pkg_of)
  if (length(files) == 0) return(list())
  chunks <- split(files, ceiling(seq_along(files) / 100))
  found <- do.call(rbind, lapply(chunks, function(ch) {
    out <- tryCatch(suppressWarnings(system2(ldd, shQuote(ch), stdout = TRUE, stderr = TRUE)),
                    error = function(e) character())
    parse_ldd(out, ch)
  }))
  if (is.null(found) || nrow(found) == 0) return(list())
  found$package <- unname(pkg_of[found$file])
  out <- lapply(split(found$lib, found$package), function(x) sort(unique(x)))
  out[order(names(out))]
}

#' Package Manager's distribution names for a Linux release
#' (`list(distribution, release)`), or `NULL` for one it doesn't build for.
#' Red Hat's family is named by its major version (`"9"`).
ppm_distribution <- function(release) {
  if (is.null(release)) return(NULL)
  id <- release$id
  distro <- switch(id, ubuntu = "ubuntu", debian = "debian", rhel = "redhat",
                   centos = "centos", rocky = "rockylinux", almalinux = "almalinux",
                   fedora = "fedora", sles = "sle", "opensuse-leap" = "opensuse", NULL)
  if (is.null(distro) || !nzchar(release$version)) return(NULL)
  version <- release$version
  if (distro %in% c("redhat", "centos", "rockylinux", "almalinux")) version <- sub("\\..*$", "", version)
  list(distribution = distro, release = version)
}

#' The system requirements API URL for `packages` from the repository at
#' `url` (a dated Package Manager URL as `repo_urls()` builds it), or
#' `NULL` when `url` isn't one. CRAN's `<server>/cran/<date>` and
#' Bioconductor's `<server>/bioconductor/<date>/packages/<release>/bioc`
#' both name their repository right after the server.
ppm_sysreqs_url <- function(url, packages, dist) {
  if (is.null(dist) || length(packages) == 0) return(NULL)
  date <- "[0-9]{4}-[0-9]{2}-[0-9]{2}|latest"
  bioc <- regmatches(url, regexec(paste0("^(https?://.+)/([^/]+)/(", date, ")/packages/([0-9.]+)/[a-z/]+$"), url))[[1]]
  cran <- regmatches(url, regexec(paste0("^(https?://.+)/([^/]+)/(", date, ")$"), url))[[1]]
  if (length(bioc) == 5) {
    server <- bioc[[2]]; repo <- bioc[[3]]; extra <- paste0("&bioc_version=", bioc[[5]])
  } else if (length(cran) == 4) {
    server <- cran[[2]]; repo <- cran[[3]]; extra <- ""
  } else {
    return(NULL)
  }
  paste0(server, "/__api__/repos/", utils::URLencode(repo, reserved = TRUE), "/sysreqs?all=false",
         paste0("&pkgname=", utils::URLencode(packages, reserved = TRUE), collapse = ""),
         "&distribution=", dist$distribution, "&release=", dist$release, extra)
}

#' Read the API's answer: named list, package -> `list(scripts, pre)`
#' (its install commands and the commands to run first, such as enabling
#' EPEL), for the packages it names. `list()` for an error answer
#' ("Unsupported system") or text that isn't its JSON.
parse_sysreqs <- function(text) {
  json <- tryCatch(jsonlite::fromJSON(paste(text, collapse = "\n"), simplifyVector = FALSE),
                   error = function(e) NULL)
  reqs <- json$requirements
  if (!is.list(reqs)) return(list())
  out <- list()
  for (r in reqs) {
    if (!is.character(r$name)) next
    pre <- vapply(r$requirements$pre_install %||% list(), function(p) p$command %||% "", "")
    out[[r$name]] <- list(scripts = as.character(unlist(r$requirements$install_scripts)),
                          pre = pre[nzchar(pre)])
  }
  out
}

#' One command that installs everything `reqs` (from `parse_sysreqs()`)
#' asks for, or `NA` when it asks for nothing. Install lines of one shape
#' (`apt-get install -y libxml2-dev`) are merged into one; the commands to
#' run first come first.
sysreqs_command <- function(reqs, sudo = sudo_prefix()) {
  scripts <- unique(unlist(lapply(reqs, `[[`, "scripts")))
  pre <- unique(unlist(lapply(reqs, `[[`, "pre")))
  if (length(scripts) == 0 && length(pre) == 0) return(NA_character_)
  shape <- "^(\\S+( \\S+)* install( -y)?) (\\S+)$"
  merged <- character()
  if (length(scripts) > 0) {
    simple <- grepl(shape, scripts)
    heads <- sub(shape, "\\1", scripts[simple])
    for (h in unique(heads)) {
      merged <- c(merged, paste(h, paste(unique(sub(shape, "\\4", scripts[simple][heads == h])), collapse = " ")))
    }
    merged <- c(merged, scripts[!simple])
  }
  paste(paste0(sudo, c(pre, merged)), collapse = " && ")
}

#' Fetch the system requirements of `packages` (named character, package
#' -> lock source, `"CRAN"` or `"Bioc"`) from the repositories in `repos`.
#' `list()` when the repositories aren't Package Manager, this Linux isn't
#' one it knows, or the request fails: then the user gets the library
#' names without a command.
fetch_sysreqs <- function(packages, repos, dist = ppm_distribution(linux_release())) {
  out <- list()
  groups <- list(CRAN = names(packages)[packages == "CRAN"],
                 BioCsoft = names(packages)[packages == "Bioc"])
  for (repo in names(groups)) {
    url <- if (repo %in% names(repos)) ppm_sysreqs_url(repos[[repo]], groups[[repo]], dist) else NULL
    if (is.null(url)) next
    text <- tryCatch(suppressWarnings(readLines(url, warn = FALSE)), error = function(e) NULL)
    if (is.null(text)) next
    got <- parse_sysreqs(text)
    out[names(got)] <- got
  }
  out
}

#' The system-library check, after renv: `NULL` when every installed
#' package finds its libraries, else `list(packages, command)`:
#' `packages` is a named list, package -> `list(libraries, command)`, and
#' `command` installs what all of them need. A command is `NA` when
#' Package Manager can't say which system packages provide the libraries.
system_library_check <- function(library, lock, repos, os = os_kind(),
                                 missing = missing_system_libraries(library, lock$entries$name),
                                 sysreqs = NULL) {
  if (!identical(os, "linux") || length(missing) == 0) return(NULL)
  if (is.null(sysreqs)) {
    src <- lock$entries$source[match(names(missing), lock$entries$name)]
    sysreqs <- fetch_sysreqs(stats::setNames(src, names(missing)), repos)
  }
  known <- intersect(names(missing), names(sysreqs))
  packages <- stats::setNames(lapply(names(missing), function(p) {
    list(libraries = missing[[p]],
         command = if (p %in% known) sysreqs_command(sysreqs[p]) else NA_character_)
  }), names(missing))
  list(packages = packages,
       command = if (length(known) > 0) sysreqs_command(sysreqs[known]) else NA_character_)
}

#' The installer's report of a check that stopped the install (see the
#' top of this file): the lines it prints, without the newline.
missing_report_lines <- function(compiler = NULL, system = NULL) {
  out <- character()
  if (!is.null(compiler)) {
    out <- c(out, sprintf("EMBER-MISSING compiler %s %s", compiler$packages, compiler$instructions),
             sprintf("Error: %s %s to build from source, and no compiler is installed. %s",
                     paste(compiler$packages, collapse = ", "),
                     if (length(compiler$packages) == 1) "needs" else "need",
                     compiler$instructions))
  }
  if (!is.null(system)) {
    pk <- system$packages
    # Every package's row carries the command for all of them, so one
    # command, run once, fixes the whole install.
    libs <- vapply(pk, function(s) paste(s$libraries, collapse = ","), "")
    out <- c(out, if (is.na(system$command)) {
      sprintf("EMBER-MISSING library %s %s", names(pk), libs)
    } else {
      sprintf("EMBER-MISSING system %s %s %s", names(pk), libs, system$command)
    })
    how <- if (!is.na(system$command)) {
      paste0(" Install them with `", system$command, "`, then try again. ", no_admin_sentence)
    } else {
      paste(" Install them with your system's package manager, then try again.", no_admin_sentence)
    }
    out <- c(out, sprintf("Error: %s %s system libraries that aren't installed (%s).%s",
                          paste(names(pk), collapse = ", "),
                          if (length(pk) == 1) "needs" else "need",
                          paste(sort(unique(unlist(lapply(pk, `[[`, "libraries")))), collapse = ", "),
                          how))
  }
  out
}
