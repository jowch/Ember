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
# that installs every package's), `library` (detail: the libraries,
# when the command doesn't cover them), `newer` (built for a newer
# system, #76; detail: the symbol versions it needs, then the libraries
# here that lack them), `symbols` (a library's own symbol versions the
# copy here lacks, #76; detail as for `newer`), `soname` (a library it was built against is here
# only as another version, #76; detail: `wanted=have[,have];...`) or
# `binary` (after a failed build: the
# package had no binary for this R, detail: its version), followed by an `Error:` line that
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
#' was configured with (`R CMD config CC`, `gcc` or `clang`) must be on the
#' PATH. On Windows that's the PATH `R CMD` builds with: R's Rcmd_environ
#' puts Rtools there (`RTOOLS45_HOME`, which rig's user mode sets, or
#' `C:/rtools45`), and only for `R CMD`, so Rtools' gcc is on no other
#' process's PATH (#49). The Fortran compiler isn't checked here: only some
#' packages need it, and nothing says which before their source is
#' unpacked, so its absence is caught from the build's own output
#' (`install_failures()`). `r_cmd_runs` is a parameter for tests.
has_compiler <- function(os = os_kind(), r_cmd_runs = r_cmd_succeeds) {
  if (identical(os, "macos")) {
    status <- tryCatch(suppressWarnings(system2("xcode-select", "-p", stdout = FALSE, stderr = FALSE)),
                       error = function(e) 1L)
    return(identical(as.integer(status), 0L))
  }
  cc <- strsplit(r_config("CC"), "\\s+")[[1]]
  cc <- cc[nzchar(cc)]
  # On Windows `R CMD config` runs Rtools' `sh`, so saying nothing there
  # means no Rtools.
  if (identical(os, "windows")) return(length(cc) > 0 && r_cmd_runs(c(cc[[1]], "--version")))
  if (length(cc) == 0) return(TRUE)  # R can't say; don't stop an install over it
  nzchar(Sys.which(cc[[1]]))
}

#' Whether `R CMD <args>` runs and exits 0: R CMD runs any command with
#' the environment R's own builds get.
r_cmd_succeeds <- function(args) {
  status <- tryCatch(suppressWarnings(system2(file.path(R.home("bin"), "R"), c("CMD", args),
                                              stdout = FALSE, stderr = FALSE)),
                     error = function(e) 1L)
  identical(as.integer(status), 0L)
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
#' unused elsewhere. With them almost nothing builds from source, except
#' at a snapshot date from before Package Manager built binaries for this
#' R (#19): then none of its packages has one. So one locked CRAN package
#' is asked about (`ppm_serves_binary()`), at the URL renv will use
#' (`binary_repos`, the installer's rewritten repositories), and only when
#' it comes as source are the packages counted, as without binaries.
#' (Measured: at 2024-06-01 Package Manager sent R 4.6 the source of every
#' package asked about, pure R ones too; at 2026-09-01, binaries.)
#' `binary_type`: the binary repositories' type on macOS and Windows (a
#' parameter so tests on Linux can ask for a Mac's). GitHub sources aren't
#' counted: whether they have code to compile is known only once they're
#' downloaded, so a missing compiler shows up from their build instead.
compiler_check <- function(lock, repos, linux_binaries = FALSE, os = os_kind(),
                           compiler = NULL, binary_type = .Platform$pkgType,
                           binary_repos = repos, serves_binary = ppm_serves_binary) {
  linux <- identical(os, "linux")
  if (is.null(compiler)) compiler <- has_compiler(os)
  if (isTRUE(compiler)) return(NULL)
  entries <- lock$entries[lock$entries$source %in% c("CRAN", "Bioc"), , drop = FALSE]
  if (nrow(entries) == 0) return(NULL)
  if (linux && linux_binaries) {
    cran <- entries[entries$source == "CRAN", , drop = FALSE]
    if (nrow(cran) == 0 || !"CRAN" %in% names(binary_repos)) return(NULL)
    if (!identical(serves_binary(package_url(binary_repos[["CRAN"]], cran$name[[1]], cran$version[[1]])), FALSE)) {
      return(NULL)
    }
    old_date <- TRUE
  } else {
    old_date <- FALSE
  }
  wanted <- stats::setNames(entries$version, entries$name)
  source_index <- read_available(repos, "source")
  if (is.null(source_index)) return(NULL)
  # On Linux without Package Manager binaries everything builds from
  # source; elsewhere an unreadable binary index leaves it to renv.
  binary_index <- if (linux) NULL else read_available(repos, binary_type)
  if (!linux && is.null(binary_index)) return(NULL)
  pkgs <- source_builds(wanted, source_index, binary_index)
  if (length(pkgs) == 0) return(NULL)
  instructions <- compiler_instructions(os = os)
  if (old_date) {
    instructions <- paste(instructions, sprintf(paste(
      "Package Manager has no binaries for R %s at this snapshot date; updating the",
      "packages to a newer date, which has them, needs no compiler."), getRversion()))
  }
  list(packages = pkgs, instructions = instructions)
}

# ---- Packages with no binary for this R (#19) ----------------------------------
#
# A snapshot date from before this R came out has no binaries for it, so
# renv builds its packages from source, and versions that old often don't
# build on a newer R (cli 3.6.2 from 2024 on R 4.6: `undefined symbol:
# SET_FRAME`). The build's own error says nothing about why. When a build
# fails, the installer asks which of the failed packages had no binary and
# says so, with what to do: move the date forward, or use an older R.

#' A source package's URL in the repository at `repo`.
package_url <- function(repo, package, version) {
  paste0(sub("/+$", "", repo), "/src/contrib/", package, "_", version, ".tar.gz")
}

#' Whether Package Manager sends the package at `url` (under a `__linux__`
#' repository) as a binary for this R: `TRUE`, `FALSE`, or `NA` when it
#' can't be asked. It picks the binary from R's user agent, which
#' `curlGetHeaders()` sends as renv's downloads do, and names what it sent
#' in `X-Package-Type`. Bounded by `timeout` seconds, so a slow or
#' unreachable server costs at most that, and answers `NA`.
ppm_serves_binary <- function(url, timeout = 10L) {
  h <- tryCatch(suppressWarnings(curlGetHeaders(url, timeout = timeout)), error = function(e) NULL)
  if (is.null(h) || !identical(as.integer(attr(h, "status")), 200L)) return(NA)
  type <- grep("^x-package-type:", h, ignore.case = TRUE, value = TRUE)
  if (length(type) == 0) return(NA)
  grepl("binary", type[[length(type)]], ignore.case = TRUE)
}

#' The packages renv names in its "failed to install" error, or none for
#' any other error (a failed download stops renv with other words).
renv_failed_packages <- function(message) {
  if (!grepl("failed to install", message, fixed = TRUE)) return(character())
  m <- regmatches(message, gregexpr("[\"\u201c][A-Za-z][A-Za-z0-9.]*[\"\u201d]", message))[[1]]
  unique(gsub("[\"\u201c\u201d]", "", m))
}

#' The packages in `failed` that renv tried to build: those whose own
#' dependencies (`Depends`, `Imports`, `LinkingTo` in `index`, the source
#' `available.packages()` matrix) include no other failed package. renv's
#' "failed to install" names its dependents too, which it never built
#' (`- [lifecycle]: dependency failed (cli, rlang)`); they mustn't be said
#' not to build. `NULL` index (unreadable): none, rather than guess.
failed_builds <- function(failed, index) {
  if (length(failed) == 0 || is.null(index)) return(character())
  deps <- tools::package_dependencies(failed, db = index, which = c("Depends", "Imports", "LinkingTo"))
  failed[!vapply(failed, function(p) any(deps[[p]] %in% failed), logical(1))]
}

#' Which of the locked packages in `failed` had no binary for this R at the
#' snapshot date, so renv built them from source: named character,
#' package -> locked version.
#'
#' * macOS and Windows: not in the binary index (`binary_type`) of `repos`
#'   at the locked version. An unreadable index names none.
#' * Linux with Package Manager binaries (`linux_binaries`): Package
#'   Manager sends the source (`serves_binary`), asked at the URL renv used
#'   (`binary_repos`, the installer's rewritten repositories).
#' * Linux without them: none. Everything builds from source there, so a
#'   failed build says nothing about the date.
#'
#' GitHub sources aren't counted: they always build from source.
no_binary_packages <- function(failed, lock, repos, binary_repos = repos, linux_binaries = FALSE,
                               os = os_kind(), binary_type = .Platform$pkgType,
                               serves_binary = ppm_serves_binary) {
  e <- lock$entries
  e <- e[e$name %in% failed & e$source %in% c("CRAN", "Bioc"), , drop = FALSE]
  none <- stats::setNames(character(), character())
  if (nrow(e) == 0) return(none)
  if (identical(os, "linux")) {
    if (!linux_binaries) return(none)
    repo_names <- list(CRAN = "CRAN", Bioc = c("BioCsoft", "BioCann", "BioCexp"))
    no_binary <- vapply(seq_len(nrow(e)), function(i) {
      for (r in intersect(repo_names[[e$source[[i]]]], names(binary_repos))) {
        got <- serves_binary(package_url(binary_repos[[r]], e$name[[i]], e$version[[i]]))
        if (!is.na(got)) return(!got)
      }
      FALSE
    }, logical(1))
  } else {
    index <- read_available(repos, binary_type)
    if (is.null(index)) return(none)
    no_binary <- !paste(e$name, e$version) %in% paste(index[, "Package"], index[, "Version"])
  }
  stats::setNames(e$version[no_binary], e$name[no_binary])[order(e$name[no_binary])]
}

# ---- System libraries --------------------------------------------------------

#' What `ldd` couldn't resolve, from its output for one or more files:
#' data frame `file`, `lib`, `version`, `path`. A library it couldn't find
#' (`libgdal.so.34 => not found`) has `version` and `path` `NA`. A library
#' it found but that lacks a symbol version the file was built against
#' (`<file>: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not
#' found (required by <obj>)`, #76) has `lib` its file name, `path` where
#' it was found and `version` the one missing: the file was built for a
#' newer system. With one file `ldd` prints no `<file>:` header, so
#' `files` says which it was. R's own libraries (`libR.so`,
#' `libRblas.so`, `libRlapack.so`) are left out: R finds them itself when
#' it loads a package.
parse_ldd <- function(lines, files) {
  file <- if (length(files) == 1) files[[1]] else NA_character_
  out_file <- character(); out_lib <- character(); out_version <- character(); out_path <- character()
  add <- function(lib, version = NA_character_, path = NA_character_) {
    out_file[length(out_file) + 1L] <<- file
    out_lib[length(out_lib) + 1L] <<- lib
    out_version[length(out_version) + 1L] <<- version
    out_path[length(out_path) + 1L] <<- path
  }
  for (line in lines) {
    if (length(files) > 1 && grepl(":$", line) && !grepl("^\\s", line)) {
      file <- sub(":$", "", line)
      next
    }
    v <- regmatches(line, regexec("^.*?: ([^:]+): version `([^']+)' not found", line))[[1]]
    if (length(v) == 3) {
      add(basename(v[[2]]), v[[3]], v[[2]])
      next
    }
    m <- regmatches(line, regexec("^\\s*(\\S+) => not found", line))[[1]]
    if (length(m) == 2 && !grepl("^libR(blas|lapack)?\\.so", m[[2]])) add(m[[2]])
  }
  data.frame(file = out_file, lib = out_lib, version = out_version, path = out_path, stringsAsFactors = FALSE)
}

#' `ldd`'s findings for every shared object of `packages` installed in
#' `library` (`parse_ldd()`'s columns plus `package`), or `NULL` when it
#' finds nothing or `ldd` isn't there. Linux only.
#'
#' Run after renv and before the library is made ready. A Package Manager
#' binary installs ("* DONE") without the system libraries it links to,
#' and fails only when a cell loads it, with a linker error. `ldd` asks
#' the same loader R will use, so a library from somewhere other than the
#' system's packages (an HPC module, conda, `/usr/local`) counts as found,
#' which a check of the package manager's database would get wrong.
ldd_findings <- function(library, packages) {
  ldd <- Sys.which("ldd")
  if (!nzchar(ldd)) return(NULL)
  # Each file's package, keyed by the path ldd echoes back (the one passed).
  pkg_of <- unlist(lapply(packages, function(p) {
    f <- list.files(file.path(library, p, "libs"), pattern = "\\.so$", recursive = TRUE, full.names = TRUE)
    stats::setNames(rep(p, length(f)), f)
  }))
  files <- names(pkg_of)
  if (length(files) == 0) return(NULL)
  chunks <- split(files, ceiling(seq_along(files) / 100))
  found <- do.call(rbind, lapply(chunks, function(ch) {
    out <- tryCatch(suppressWarnings(system2(ldd, shQuote(ch), stdout = TRUE, stderr = TRUE)),
                    error = function(e) character())
    parse_ldd(out, ch)
  }))
  if (is.null(found) || nrow(found) == 0) return(NULL)
  found$package <- unname(pkg_of[found$file])
  found
}

#' Which installed packages link to a library this machine doesn't have:
#' named list, package -> character of library file names (`libgdal.so.34`),
#' empty when all are found or `ldd` isn't there. From `ldd_findings()`.
missing_system_libraries <- function(library, packages, findings = ldd_findings(library, packages)) {
  if (is.null(findings)) return(list())
  found <- findings[is.na(findings$version), , drop = FALSE]
  if (nrow(found) == 0) return(list())
  out <- lapply(split(found$lib, found$package), function(x) sort(unique(x)))
  out[order(names(out))]
}

#' Whether a symbol version is the toolchain's (`GLIBC_2.38`,
#' `GLIBCXX_3.4.32`, `CXXABI_1.3.15`, `GCC_14.0`): one this system lacks
#' means the binary was built on a newer system. A library's own
#' (`CURL_OPENSSL_4`, `LIBXML2_2.9`) only says that the copy here was
#' built differently: older, or with another TLS backend (#76).
toolchain_version <- function(v) grepl("^(GLIBC|GLIBCXX|CXXABI|GCC)_", v)

#' The highest of each family of symbol versions (`GLIBC_2.38` of
#' `GLIBC_2.34`, `GLIBC_2.38`): what someone acts on. A name with no
#' number at the end is kept as it is.
highest_versions <- function(v) {
  v <- unique(v)
  m <- regmatches(v, regexec("^(.*)_([0-9]+(\\.[0-9]+)*)$", v))
  family <- vapply(seq_along(v), function(i) if (length(m[[i]]) > 0) m[[i]][[2]] else v[[i]], "")
  out <- vapply(split(seq_along(v), family), function(ix) {
    num <- vapply(ix, function(i) if (length(m[[i]]) > 0) m[[i]][[3]] else NA_character_, "")
    if (anyNA(num)) return(v[[ix[[1]]]])
    v[[ix[[which.max(rank(numeric_version(num), ties.method = "first"))]]]]
  }, "")
  sort(unname(out))
}

#' Which installed packages need symbol versions the libraries here lack
#' (#76): named list, package -> `list(versions, paths)`, the highest
#' version of each family its files need (`highest_versions()`) and the
#' libraries that lack them. `toolchain = TRUE`: only the toolchain's
#' (`toolchain_version()`), the packages built for a newer system;
#' `FALSE`: only the libraries' own. From `ldd_findings()`.
newer_system_libraries <- function(findings, toolchain = TRUE) {
  if (is.null(findings)) return(list())
  found <- findings[!is.na(findings$version), , drop = FALSE]
  found <- found[toolchain_version(found$version) == toolchain, , drop = FALSE]
  if (nrow(found) == 0) return(list())
  out <- lapply(split(found, found$package), function(d) {
    list(versions = highest_versions(d$version), paths = sort(unique(d$path)))
  })
  out[order(names(out))]
}

#' The shared libraries the loader can find, as paths: `ldconfig -p`'s
#' cache plus every file in `LD_LIBRARY_PATH`'s folders. Used only to say
#' that a missing `libgdal.so.34` is there as another version (#76).
#' `character()` when neither can be read.
loader_libraries <- function(ldconfig = c(Sys.which("ldconfig"), "/sbin/ldconfig", "/usr/sbin/ldconfig"),
                             ld_library_path = Sys.getenv("LD_LIBRARY_PATH")) {
  out <- character()
  tool <- Filter(function(p) nzchar(p) && file.exists(p), ldconfig)
  if (length(tool) > 0) {
    lines <- tryCatch(suppressWarnings(system2(tool[[1]], "-p", stdout = TRUE, stderr = FALSE)),
                      error = function(e) character())
    out <- sub("^.*=> ", "", grep("=>", lines, value = TRUE, fixed = TRUE))
  }
  dirs <- strsplit(ld_library_path, .Platform$path.sep, fixed = TRUE)[[1]]
  for (d in dirs[nzchar(dirs) & dir.exists(dirs)]) out <- c(out, list.files(d, pattern = "\\.so", full.names = TRUE))
  unique(out)
}

#' For each library in `libs` (`libgdal.so.34`), the other versions of it
#' in `available` (`loader_libraries()`, paths): a named list, library ->
#' the file names found (`libgdal.so.36`), only for those with one.
#'
#' * Only a version in a folder the distribution manages counts (`/lib`,
#'   `/lib64`, `/usr/lib`, `/usr/lib64` and their multiarch folders): its
#'   package manager's install command would install that same version,
#'   so it can't help. One in `/usr/local`, conda or a loaded module says
#'   nothing about what the distribution ships, so the library stays one
#'   to install (#76's review).
#' * A library is matched by its name up to `.so`, and only numbered
#'   versions count: the `-dev` package's bare `libgdal.so` is a link to
#'   one of them.
#' * A file whose name extends another's (`libxml2.so.2.9.14` of
#'   `libxml2.so.2`) is the same library under its full version, so only
#'   the soname is kept.
other_library_versions <- function(libs, available) {
  stem <- function(x) sub("\\.so(\\..*)?$", "", x)
  distro <- grepl("^/(usr/)?lib(64)?(/[^/]+)?$", dirname(available))
  names_here <- unique(basename(available[distro]))
  numbered <- names_here[grepl("\\.so\\.[0-9]", names_here)]
  numbered <- numbered[!vapply(numbered, function(n) any(startsWith(n, paste0(setdiff(numbered, n), "."))), logical(1))]
  out <- lapply(libs, function(l) sort(setdiff(numbered[stem(numbered) == stem(l)], l)))
  names(out) <- libs
  Filter(length, out)
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
#' package finds its libraries, else `list(packages, command, newer,
#' versions)`:
#'
#' * `packages`: named list, package -> `list(libraries, command)`, the
#'   libraries not installed and the command that installs them, `NA`
#'   when Package Manager can't say which system packages provide them (a
#'   GitHub package, another server, a Linux it doesn't know);
#' * `command` installs what all of those need;
#' * `newer`: `newer_system_libraries()`, packages built for a newer
#'   system than this one (#76);
#' * `symbols`: `newer_system_libraries(toolchain = FALSE)`, packages
#'   needing a library's own symbol versions the copy here lacks (#76);
#' * `versions`: named list, package -> named character, a library it was
#'   built against -> the other versions this system has
#'   (`c(libgdal.so.34 = "libgdal.so.36")`, several comma-separated):
#'   the command would install the version already here, so these aren't
#'   in `packages` or the command (#76).
system_library_check <- function(library, lock, repos, os = os_kind(),
                                 findings = ldd_findings(library, lock$entries$name),
                                 missing = missing_system_libraries(library, lock$entries$name, findings),
                                 newer = newer_system_libraries(findings),
                                 symbols = newer_system_libraries(findings, toolchain = FALSE),
                                 available = loader_libraries(),
                                 sysreqs = NULL) {
  if (!identical(os, "linux")) return(NULL)
  versions <- list()
  for (p in names(missing)) {
    other <- other_library_versions(missing[[p]], available)
    if (length(other) == 0) next
    versions[[p]] <- vapply(other, paste, "", collapse = ", ")
    missing[[p]] <- setdiff(missing[[p]], names(other))
  }
  missing <- Filter(length, missing)
  if (length(missing) == 0 && length(newer) == 0 && length(symbols) == 0 && length(versions) == 0) return(NULL)
  if (is.null(sysreqs) && length(missing) > 0) {
    src <- lock$entries$source[match(names(missing), lock$entries$name)]
    sysreqs <- fetch_sysreqs(stats::setNames(src, names(missing)), repos)
  }
  known <- intersect(names(missing), names(sysreqs))
  packages <- stats::setNames(lapply(names(missing), function(p) {
    list(libraries = missing[[p]],
         command = if (p %in% known) sysreqs_command(sysreqs[p]) else NA_character_)
  }), names(missing))
  commands <- vapply(packages, `[[`, "", "command")
  covered <- names(packages)[!is.na(commands)]
  list(packages = packages,
       command = if (length(covered) > 0) sysreqs_command(sysreqs[covered]) else NA_character_,
       newer = newer, symbols = symbols, versions = versions)
}

#' The installer's report of a check that stopped the install (see the
#' top of this file): the lines it prints, without the newline.
#' `no_binary`: packages whose build failed and that had no binary for
#' this R (`no_binary_packages()`), with `r_version` the running R.
missing_report_lines <- function(compiler = NULL, system = NULL, no_binary = character(),
                                 r_version = as.character(getRversion())) {
  out <- character()
  if (length(no_binary) > 0) {
    named <- paste(names(no_binary), no_binary)
    out <- c(out, sprintf("EMBER-MISSING binary %s %s", names(no_binary), unname(no_binary)),
             sprintf(paste("Error: %s %s no binary for R %s, so %s built from source, and %s on R %s.",
                           "Most often the snapshot date is older than this R, and versions from",
                           "before an R release often don't build on it. Update the packages to a",
                           "newer date, whose versions have binaries, or run the notebook on an older R."),
                     paste(named, collapse = ", "), if (length(named) == 1) "has" else "have", r_version,
                     if (length(named) == 1) "it was" else "they were",
                     if (length(named) == 1) "it doesn't build" else "they don't build", r_version))
  }
  if (!is.null(compiler)) {
    out <- c(out, sprintf("EMBER-MISSING compiler %s %s", compiler$packages, compiler$instructions),
             sprintf("Error: %s %s to build from source, and no compiler is installed. %s",
                     paste(compiler$packages, collapse = ", "),
                     if (length(compiler$packages) == 1) "needs" else "need",
                     compiler$instructions))
  }
  # The system check's findings make one `Error:` line, the one
  # `install_failure_message()` shows.
  why <- character()
  if (!is.null(system) && length(system$packages) > 0) {
    pk <- system$packages
    libs <- vapply(pk, function(s) paste(s$libraries, collapse = ","), "")
    # A package's row carries the command for all of them, so one command,
    # run once, fixes the whole install; a package the command doesn't
    # cover (a GitHub package, which Package Manager knows nothing about)
    # gets its libraries alone.
    covered <- !is.na(vapply(pk, function(s) s$command %||% NA_character_, "")) & !is.na(system$command %||% NA_character_)
    out <- c(out,
             sprintf("EMBER-MISSING system %s %s %s", names(pk)[covered], libs[covered], rep(system$command, sum(covered))),
             sprintf("EMBER-MISSING library %s %s", names(pk)[!covered], libs[!covered]))
    how <- if (all(covered)) {
      paste0(" Install them with `", system$command, "`, then try again.")
    } else if (any(covered)) {
      paste0(" Install them with `", system$command, "`, which doesn't install what ",
             paste(names(pk)[!covered], collapse = ", "), " ", if (sum(!covered) == 1) "needs" else "need",
             ": install that with your system's package manager. Then try again.")
    } else {
      " Install them with your system's package manager, then try again."
    }
    why <- c(why, sprintf("%s %s system libraries that aren't installed (%s).%s %s",
                          paste(names(pk), collapse = ", "),
                          if (length(pk) == 1) "needs" else "need",
                          paste(sort(unique(unlist(lapply(pk, `[[`, "libraries")))), collapse = ", "),
                          how, no_admin_sentence))
  }
  newer <- system$newer %||% list()
  if (length(newer) > 0) {
    out <- c(out, sprintf("EMBER-MISSING newer %s %s %s", names(newer),
                          vapply(newer, function(n) paste(n$versions, collapse = ","), ""),
                          vapply(newer, function(n) paste(n$paths, collapse = ","), "")))
    one <- length(newer) == 1
    why <- c(why, sprintf(paste("%s %s built for a newer system than this one, and %s %s from libraries",
                                "here that are older (%s)."),
                          paste(names(newer), collapse = ", "), if (one) "was" else "were",
                          if (one) "needs" else "need",
                          paste(unique(unlist(lapply(newer, `[[`, "versions"))), collapse = ", "),
                          paste(unique(unlist(lapply(newer, `[[`, "paths"))), collapse = ", ")))
  }
  symbols <- system$symbols %||% list()
  if (length(symbols) > 0) {
    out <- c(out, sprintf("EMBER-MISSING symbols %s %s %s", names(symbols),
                          vapply(symbols, function(n) paste(n$versions, collapse = ","), ""),
                          vapply(symbols, function(n) paste(n$paths, collapse = ","), "")))
    paths <- unique(unlist(lapply(symbols, `[[`, "paths")))
    why <- c(why, sprintf("%s %s %s from %s, which the %s here %s.",
                          paste(names(symbols), collapse = ", "),
                          if (length(symbols) == 1) "needs" else "need",
                          paste(unique(unlist(lapply(symbols, `[[`, "versions"))), collapse = ", "),
                          paste(paths, collapse = ", "),
                          if (length(paths) == 1) "copy" else "copies",
                          if (length(paths) == 1) "doesn't have" else "don't have"))
  }
  versions <- system$versions %||% list()
  if (length(versions) > 0) {
    out <- c(out, sprintf("EMBER-MISSING soname %s %s", names(versions),
                          vapply(versions, function(v) paste0(names(v), "=", gsub(", ", ",", v), collapse = ";"), "")))
    wanted <- unlist(lapply(versions, names))
    have <- unlist(lapply(versions, function(v) unname(v)))
    why <- c(why, sprintf(paste("%s %s built against %s, and this system has %s instead. The install",
                                "command would install the version already here: if your Linux has a",
                                "package that provides %s, install that, then try again."),
                          paste(names(versions), collapse = ", "), if (length(versions) == 1) "was" else "were",
                          paste(unique(wanted), collapse = ", "), paste(unique(have), collapse = ", "),
                          paste(unique(wanted), collapse = ", ")))
  }
  if (length(why) > 0) out <- c(out, paste("Error:", paste(why, collapse = " ")))
  out
}
