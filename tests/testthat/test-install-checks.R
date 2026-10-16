# The installer's checks (R/install-checks.R): a compiler for packages that
# build from source, and the system libraries installed packages link to.
# Plain functions; the parts that ask the machine (`xcode-select`, `ldd`,
# Package Manager) take their answers as arguments, so these run anywhere.
#
# Covers packages-tests.md items 90-99 and 117-120 ("Install checks").

sysreqs_fixture <- function(name) {
  readLines(testthat::test_path("fixtures", "sysreqs", paste0(name, ".json")), warn = FALSE)
}

os_release <- function(...) c(...)

test_that("linux_release() and linux_family() name the package manager, through ID_LIKE for a derivative (90)", {
  ubuntu <- linux_release(os_release('NAME="Ubuntu"', "ID=ubuntu", "ID_LIKE=debian", 'VERSION_ID="24.04"'))
  expect_equal(ubuntu$id, "ubuntu")
  expect_equal(ubuntu$version, "24.04")
  expect_equal(linux_family(ubuntu), "apt")

  mint <- linux_release(os_release("ID=linuxmint", "ID_LIKE=\"ubuntu debian\"", 'VERSION_ID="22"'))
  expect_equal(linux_family(mint), "apt")

  rocky <- linux_release(os_release('ID="rocky"', 'ID_LIKE="rhel centos fedora"', 'VERSION_ID="9.4"'))
  expect_equal(linux_family(rocky), "dnf")

  suse <- linux_release(os_release('ID="opensuse-leap"', 'ID_LIKE="suse opensuse"', 'VERSION_ID="15.6"'))
  expect_equal(linux_family(suse), "zypper")

  arch <- linux_release(os_release("ID=arch"))
  expect_true(is.na(linux_family(arch)))
  expect_true(is.na(linux_family(NULL)))
})

test_that("compiler_instructions() says what to install on each platform, with sudo only when not root (91)", {
  ubuntu <- linux_release(c("ID=ubuntu", 'VERSION_ID="24.04"'))
  expect_match(compiler_instructions(os = "macos"), "xcode-select --install", fixed = TRUE)
  expect_match(compiler_instructions(fortran = TRUE, os = "macos"), "https://mac.r-project.org/tools/", fixed = TRUE)
  expect_match(compiler_instructions(os = "windows", r_version = package_version("4.6.1")),
               "Rtools for R 4.6", fixed = TRUE)
  expect_match(compiler_instructions(os = "linux", release = ubuntu, sudo = "sudo "),
               "`sudo apt-get install -y build-essential gfortran`", fixed = TRUE)
  expect_match(compiler_instructions(os = "linux", release = ubuntu, sudo = ""),
               "`apt-get install -y build-essential gfortran`", fixed = TRUE)
  rocky <- linux_release(c("ID=rocky", "ID_LIKE=rhel", "VERSION_ID=9"))
  expect_match(compiler_instructions(os = "linux", release = rocky, sudo = ""), "dnf install -y gcc", fixed = TRUE)
  expect_match(compiler_instructions(os = "linux", release = NULL), "package manager", fixed = TRUE)
  expect_equal(sudo_prefix("root", has_sudo = TRUE), "")
  expect_equal(sudo_prefix("someone", has_sudo = TRUE), "sudo ")
  expect_equal(sudo_prefix("someone", has_sudo = FALSE), "")
})

test_that("source_builds() names the compiled packages with no binary at the locked version (92)", {
  src <- cbind(Package = c("Rcpp", "glue", "units", "cli"),
               Version = c("1.0.12", "1.8.0", "0.8-5", "3.6.5"),
               NeedsCompilation = c("yes", "no", "yes", NA))
  wanted <- c(Rcpp = "1.0.12", glue = "1.8.0", units = "0.8-5", cli = "3.6.5", gone = "1.0")
  # No binary repository (Linux without Package Manager binaries): every
  # compiled package builds from source.
  expect_equal(source_builds(wanted, src, NULL), c("Rcpp", "units"))
  # A binary at the locked version installs as one; at another version it
  # doesn't count.
  bin <- cbind(Package = c("Rcpp", "units"), Version = c("1.0.12", "0.8-4"))
  expect_equal(source_builds(wanted, src, bin), "units")
  expect_equal(source_builds(character(), src, bin), character())
})

test_that("compiler_check() reads no index when the compiler is there or Linux gets binaries, and names source builds otherwise (93)", {
  lock <- parse_lock_lines(c("Rcpp 1.0.12 CRAN", "glue 1.8.0 CRAN"))$lock
  # An unreadable repository proves nothing is read in the first two cases.
  nowhere <- c(CRAN = "file:///nonexistent/ember-test-repo")
  expect_null(compiler_check(lock, nowhere, os = "macos", compiler = TRUE))
  expect_null(compiler_check(lock, nowhere, linux_binaries = TRUE, os = "linux", compiler = FALSE,
                             serves_binary = function(url) TRUE))
  # Unreadable indexes leave it to renv, which says why.
  expect_null(compiler_check(lock, nowhere, os = "linux", compiler = FALSE))

  # file:///D:/... on Windows: "file://D:/..." reads D: as a host.
  repo <- paste0(if (.Platform$OS.type == "windows") "file:///" else "file://",
                 normalizePath(testthat::test_path("fixtures", "repos", "cran", "2026-09-01"), winslash = "/"))
  got <- compiler_check(lock, c(CRAN = repo), os = "linux", compiler = FALSE)
  expect_equal(got$packages, "Rcpp")
  expect_equal(got$instructions, compiler_instructions(os = "linux"))
  # On a Mac with no binary repository to read, the same.
  expect_null(compiler_check(lock, c(CRAN = repo), os = "macos", compiler = FALSE,
                             binary_type = "mac.binary.big-sur-arm64"))
  # GitHub sources aren't counted (their build says so instead).
  gh <- parse_lock_lines("mypkg 3f2a1c9 github:lab/mypkg@3f2a1c9")$lock
  expect_null(compiler_check(gh, c(CRAN = repo), os = "linux", compiler = FALSE))
})

test_that("compiler_check() on Linux with Package Manager binaries asks about one package, and counts source builds when it comes as source (117)", {
  lock <- parse_lock_lines(c("Rcpp 1.0.12 CRAN", "glue 1.8.0 CRAN"))$lock
  repo <- paste0(if (.Platform$OS.type == "windows") "file:///" else "file://",
                 normalizePath(testthat::test_path("fixtures", "repos", "cran", "2026-09-01"), winslash = "/"))
  binary_repos <- c(CRAN = "https://ppm.example/cran/__linux__/noble/2024-06-01")
  asked <- character()
  answer <- function(value) function(url) { asked <<- c(asked, url); value }

  # Binaries for this R at this date: nothing to count, no index read.
  expect_null(compiler_check(lock, c(CRAN = "file:///nonexistent/ember-test-repo"), linux_binaries = TRUE,
                             os = "linux", compiler = FALSE, binary_repos = binary_repos,
                             serves_binary = answer(TRUE)))
  expect_equal(asked, "https://ppm.example/cran/__linux__/noble/2024-06-01/src/contrib/Rcpp_1.0.12.tar.gz")
  # Can't tell: left to the build's own error, as before.
  expect_null(compiler_check(lock, c(CRAN = repo), linux_binaries = TRUE, os = "linux", compiler = FALSE,
                             binary_repos = binary_repos, serves_binary = answer(NA)))
  # Source (a date from before Package Manager built for this R): every
  # compiled package builds, and the instructions offer a newer date.
  got <- compiler_check(lock, c(CRAN = repo), linux_binaries = TRUE, os = "linux", compiler = FALSE,
                        binary_repos = binary_repos, serves_binary = answer(FALSE))
  expect_equal(got$packages, "Rcpp")
  expect_match(got$instructions, compiler_instructions(os = "linux"), fixed = TRUE)
  expect_match(got$instructions, "updating the packages to a newer date, which has them, needs no compiler", fixed = TRUE)
  # With the compiler there nothing is asked.
  asked <- character()
  expect_null(compiler_check(lock, c(CRAN = repo), linux_binaries = TRUE, os = "linux", compiler = TRUE,
                             binary_repos = binary_repos, serves_binary = answer(FALSE)))
  expect_equal(asked, character())
})

test_that("renv_failed_packages() reads renv's \"failed to install\" error, in either quotes, and nothing else (118)", {
  expect_equal(renv_failed_packages('failed to install "cli"'), "cli")
  expect_equal(renv_failed_packages("failed to install \u201ccli\u201d, \u201cdata.table\u201d"), c("cli", "data.table"))
  expect_equal(renv_failed_packages('failed to retrieve package "cli"'), character())
})

test_that("no_binary_packages() names the failed packages with no binary for this R, per platform (118)", {
  lock <- parse_lock_lines(c("cli 3.6.2 CRAN", "glue 1.7.0 CRAN", "S4Vectors 0.40.0 Bioc",
                             "mypkg 3f2a1c9 github:lab/mypkg@3f2a1c9"))$lock
  failed <- c("cli", "glue", "S4Vectors", "mypkg", "notlocked")

  # macOS: not in the binary index at the locked version. The index is a
  # file repository laid out where contrib.url() looks for this R.
  type <- "mac.binary.big-sur-arm64"
  root <- tempfile("ember-bin-repo-")
  contrib <- sub("^file://", "", utils::contrib.url(paste0("file://", root), type))
  dir.create(contrib, recursive = TRUE)
  writeLines(c("Package: glue", "Version: 1.7.0", "", "Package: cli", "Version: 3.6.5", ""),
             file.path(contrib, "PACKAGES"))
  on.exit(unlink(root, recursive = TRUE))
  repos <- c(CRAN = paste0(if (.Platform$OS.type == "windows") "file:///" else "file://", normalizePath(root, winslash = "/")))
  got <- no_binary_packages(failed, lock, repos, os = "macos", binary_type = type)
  # cli has a binary only at another version; S4Vectors has none; glue
  # has one; mypkg is GitHub; notlocked isn't in the lock.
  expect_equal(got, c(S4Vectors = "0.40.0", cli = "3.6.2"))
  # An unreadable index names none.
  expect_equal(length(no_binary_packages(failed, lock, c(CRAN = "file:///nonexistent/ember-test-repo"),
                                         os = "macos", binary_type = type)), 0)

  # Linux with Package Manager binaries: Package Manager is asked, at the
  # rewritten URL, through Bioconductor's three repositories in turn.
  binary_repos <- c(CRAN = "https://ppm.example/cran/__linux__/noble/2024-06-01",
                    BioCsoft = "https://ppm.example/bioc/soft", BioCann = "https://ppm.example/bioc/ann")
  asked <- character()
  serves <- function(url) {
    asked <<- c(asked, url)
    if (grepl("glue_", url)) TRUE else if (grepl("bioc/soft", url)) NA else FALSE
  }
  got <- no_binary_packages(failed, lock, repos, binary_repos = binary_repos, linux_binaries = TRUE,
                            os = "linux", serves_binary = serves)
  expect_equal(got, c(S4Vectors = "0.40.0", cli = "3.6.2"))
  expect_true("https://ppm.example/bioc/ann/src/contrib/S4Vectors_0.40.0.tar.gz" %in% asked)
  # Linux without them: everything builds from source there anyway.
  expect_equal(length(no_binary_packages(failed, lock, repos, linux_binaries = FALSE, os = "linux",
                                         serves_binary = function(url) stop("not asked"))), 0)
})

test_that("a failed build with no binary becomes a no_binary row with the version, and other kinds stay (119)", {
  lines <- missing_report_lines(no_binary = c(cli = "3.6.2"), r_version = "4.6.1")
  expect_equal(lines[[1]], "EMBER-MISSING binary cli 3.6.2")
  expect_match(lines[[2]], "^Error: cli 3.6.2 has no binary for R 4.6.1, so it was built from source")
  expect_match(lines[[2]], "Most often the snapshot date is older than this R", fixed = TRUE)
  expect_match(lines[[2]], "Update the packages to a newer date", fixed = TRUE)
  two <- missing_report_lines(no_binary = c(cli = "3.6.2", rlang = "1.1.3"), r_version = "4.6.1")
  expect_match(two[[3]], "cli 3.6.2, rlang 1.1.3 have no binary", fixed = TRUE)

  build <- c("* installing *source* package 'cli' ...",
             "ERROR: compilation failed for package 'cli'",
             "* installing *source* package 'rlang' ...",
             "make: gcc: No such file or directory",
             "ERROR: compilation failed for package 'rlang'",
             "- [vctrs]: failed to retrieve package 'vctrs@0.6.5'",
             "- [glue]: install failed")
  report <- missing_report_lines(no_binary = c(cli = "3.6.2", rlang = "1.1.3", vctrs = "0.6.5", glue = "1.7.0"))
  rows <- install_failures(c(build, report))
  expect_equal(rows$package, c("cli", "glue", "rlang", "vctrs"))
  # A build failure says why it was built; a missing compiler and a
  # download stay what they are.
  expect_equal(rows$kind, c("no_binary", "no_binary", "missing_compiler", "download"))
  expect_equal(rows$detail[1:2], c("3.6.2", "1.7.0"))
  expect_match(install_failure_message(c(build, report), 1L), "have no binary for R", fixed = TRUE)
  # Without the installer's line, a build failure stays one.
  expect_equal(install_failures(build)$kind, c("compile", "other", "missing_compiler", "download"))
})

test_that("a real renv 1.3.0 / R 4.6.1 log: cli 3.6.2 at 2024-06-01 builds, fails to load, and is no_binary (120)", {
  # Captured from `ember::run()` on Linux (Ubuntu 24.04) against Package
  # Manager at 2024-06-01, which sends R 4.6 sources only: cli builds,
  # then fails R's load test (`undefined symbol: SET_FRAME`). The gcc lines
  # are cut.
  lines <- readLines(testthat::test_path("fixtures", "install-output", "real-renv-old-snapshot.txt"), warn = FALSE)
  rows <- install_failures(lines)
  expect_equal(rows$package, "cli")
  expect_equal(rows$kind, "no_binary")
  expect_equal(rows$detail, "3.6.2")
  # Without the installer's line, "ERROR: loading failed" after a source
  # build is a failed build, not "other".
  plain <- install_failures(lines[!grepl("EMBER-MISSING", lines, fixed = TRUE)])
  expect_equal(plain$kind, "compile")
})

test_that("failed_builds() leaves out the dependents renv never built, and names none without an index (118)", {
  index <- cbind(Package = c("cli", "rlang", "lifecycle", "glue"),
                 Version = c("3.6.2", "1.1.3", "1.0.4", "1.7.0"),
                 Depends = c("R (>= 3.4)", "R (>= 3.5.0)", "R (>= 3.6)", NA),
                 Imports = c("utils", "utils", "cli (>= 3.4.0), glue, rlang (>= 1.1.0)", NA),
                 LinkingTo = NA)
  expect_equal(failed_builds(c("cli", "lifecycle", "rlang"), index), c("cli", "rlang"))
  expect_equal(failed_builds("lifecycle", index), "lifecycle")
  expect_equal(failed_builds(c("cli", "rlang"), NULL), character())
})

test_that("a real log with dependents: the ones that failed to build are no_binary, lifecycle is a dependency (120)", {
  # Captured from `ember::run()` (Ubuntu 24.04, R 4.6.1, Package Manager
  # at 2024-06-01) on cli, glue, lifecycle and rlang, with the installer
  # as it was before `failed_builds()`: rlang fails to compile, cli to
  # load, and renv never builds lifecycle ("dependency failed (cli,
  # rlang)") but names it in "failed to install". gcc lines cut.
  lines <- readLines(testthat::test_path("fixtures", "install-output", "real-renv-old-snapshot-dependents.txt"), warn = FALSE)
  rows <- install_failures(lines)
  expect_equal(rows$package, c("cli", "lifecycle", "rlang"))
  # Even with the old installer's line for lifecycle, its row stays a
  # dependency, named by the first package it waited on.
  expect_equal(rows$kind, c("no_binary", "dependency", "no_binary"))
  expect_equal(rows$detail, c("3.6.2", "cli", "1.1.3"))
})

test_that("parse_ldd() reads the libraries ldd couldn't find, with and without per-file headers, leaving R's own out (94)", {
  one <- c("\tlinux-vdso.so.1 (0x00007ffd)",
           "\tlibudunits2.so.0 => not found",
           "\tlibR.so => not found",
           "\tlibc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f)")
  got <- parse_ldd(one, "/lib/units/libs/units.so")
  expect_equal(got$file, "/lib/units/libs/units.so")
  expect_equal(got$lib, "libudunits2.so.0")

  two <- c("/lib/units/libs/units.so:", "\tlibudunits2.so.0 => not found",
           "/lib/sf/libs/sf.so:", "\tlibgdal.so.34 => not found", "\tlibgeos_c.so.1 => not found",
           "\tlibRblas.so => not found")
  got <- parse_ldd(two, c("/lib/units/libs/units.so", "/lib/sf/libs/sf.so"))
  expect_equal(got$file, c("/lib/units/libs/units.so", "/lib/sf/libs/sf.so", "/lib/sf/libs/sf.so"))
  expect_equal(got$lib, c("libudunits2.so.0", "libgdal.so.34", "libgeos_c.so.1"))
  expect_equal(nrow(parse_ldd(character(), "x.so")), 0)
})

test_that("parse_ldd() reads a library that lacks a symbol version the file needs (#76)", {
  # As ldd prints it, for one file and for several (the per-file header,
  # then the loader's own line, which starts with the file's path).
  one <- c("/lib/sf/libs/sf.so: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found (required by /lib/sf/libs/sf.so)",
           "/lib/sf/libs/sf.so: /lib/x86_64-linux-gnu/libstdc++.so.6: version `GLIBCXX_3.4.32' not found (required by /usr/lib/libgdal.so.34)",
           "\tlinux-vdso.so.1 (0x00007ffd)",
           "\tlibgdal.so.34 => /usr/lib/libgdal.so.34 (0x00007f)")
  got <- parse_ldd(one, "/lib/sf/libs/sf.so")
  expect_equal(got$lib, c("libc.so.6", "libstdc++.so.6"))
  expect_equal(got$version, c("GLIBC_2.38", "GLIBCXX_3.4.32"))
  expect_equal(got$path, c("/lib/x86_64-linux-gnu/libc.so.6", "/lib/x86_64-linux-gnu/libstdc++.so.6"))

  two <- c("/my lib/a/libs/a.so:", "/my lib/a/libs/a.so: /lib/libc.so.6: version `GLIBC_2.39' not found (required by /my lib/a/libs/a.so)",
           "\tlibfoo.so.1 => not found", "/my lib/b/libs/b.so:", "\tlibc.so.6 => /lib/libc.so.6 (0x00007f)")
  got <- parse_ldd(two, c("/my lib/a/libs/a.so", "/my lib/b/libs/b.so"))
  expect_equal(got$file, rep("/my lib/a/libs/a.so", 2))
  expect_equal(got$lib, c("libc.so.6", "libfoo.so.1"))
  expect_equal(got$version, c("GLIBC_2.39", NA))
})

test_that("a package built against a newer library is named with the versions it needs, apart from missing ones (#76)", {
  skip_if_not(identical(os_kind(), "linux") && nzchar(Sys.which("ldd")), "needs Linux and ldd")
  cc <- Sys.which("gcc")
  skip_if_not(nzchar(cc), "needs gcc to build stub libraries")
  dir <- tempfile("ember-ldd-test-"); dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  build <- file.path(dir, "build"); old <- file.path(dir, "old"); lib <- file.path(dir, "lib")
  for (d in c(build, old)) dir.create(d)
  # libfakec.so.6 in two builds: the new one adds `f2` under FAKE_2. The
  # package links the new one and calls `f2`; the loader is then pointed
  # at the old one, as on a system older than the one it was built on.
  writeLines(c("int f1(void){return 1;}", "int f2(void){return 2;}"), file.path(build, "c.c"))
  writeLines(c("FAKE_1 { global: f1; local: *; };", "FAKE_2 { global: f2; } FAKE_1;"), file.path(build, "new.map"))
  writeLines("FAKE_1 { global: f1; local: *; };", file.path(build, "old.map"))
  so <- function(out, map) {
    system2(cc, c("-shared", "-fPIC", "-o", shQuote(out), "-Wl,-soname,libfakec.so.6",
                  paste0("-Wl,--version-script=", shQuote(map)), shQuote(file.path(build, "c.c"))))
  }
  expect_equal(so(file.path(build, "libfakec.so.6"), file.path(build, "new.map")), 0)
  expect_equal(so(file.path(old, "libfakec.so.6"), file.path(build, "old.map")), 0)
  writeLines("int f2(void); int g(void){return f2();}", file.path(build, "pkg.c"))
  out <- file.path(lib, "fakenew", "libs", "fakenew.so")
  dir.create(dirname(out), recursive = TRUE)
  expect_equal(system2(cc, c("-shared", "-fPIC", "-o", shQuote(out), shQuote(file.path(build, "pkg.c")),
                             paste0("-L", shQuote(build)), "-l:libfakec.so.6")), 0)

  old_path <- Sys.getenv("LD_LIBRARY_PATH", NA)
  Sys.setenv(LD_LIBRARY_PATH = old)
  on.exit(if (is.na(old_path)) Sys.unsetenv("LD_LIBRARY_PATH") else Sys.setenv(LD_LIBRARY_PATH = old_path), add = TRUE)
  found <- ldd_findings(lib, "fakenew")
  expect_equal(missing_system_libraries(lib, "fakenew", found), list())
  expect_equal(newer_system_libraries(found),
               list(fakenew = list(versions = "FAKE_2", paths = file.path(old, "libfakec.so.6"))))

  # The check stops the install, with no libraries to install.
  lock <- parse_lock_lines("fakenew 1.0 CRAN")$lock
  got <- system_library_check(lib, lock, c(), os = "linux", findings = found, available = character(), sysreqs = list())
  expect_length(got$packages, 0)
  expect_equal(names(got$newer), "fakenew")
})

test_that("a missing library that is here as another version isn't a library to install (#76)", {
  expect_equal(other_library_versions(c("libgdal.so.34", "libudunits2.so.0", "libicuuc.so.70"),
                                      c("libgdal.so.36", "libgdal.so", "libgdal.so.36.3.8.4", "libicuuc.so.74",
                                        "libicuuc-extra.so.70", "libudunits2.so")),
               list(libgdal.so.34 = c("libgdal.so.36", "libgdal.so.36.3.8.4"), libicuuc.so.70 = "libicuuc.so.74"))

  dir <- tempfile("ember-loader-test-"); dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  file.create(file.path(dir, c("libgdal.so.36", "notalib.txt")))
  expect_equal(loader_libraries(ldconfig = "", ld_library_path = paste0("/does/not/exist:", dir)), "libgdal.so.36")

  lock <- parse_lock_lines(c("sf 1.0-21 CRAN", "units 0.8-5 CRAN"))$lock
  reqs <- parse_sysreqs(sysreqs_fixture("ubuntu-sf-units"))
  missing <- list(sf = c("libgdal.so.34", "libgeos_c.so.1"), units = "libudunits2.so.0")
  got <- system_library_check("unused", lock, c(), os = "linux", missing = missing, newer = list(),
                              available = c("libgdal.so.36", "libudunits2.so.0"), sysreqs = reqs)
  expect_equal(got$packages$sf$libraries, "libgeos_c.so.1")
  expect_equal(got$versions, list(sf = c(libgdal.so.34 = "libgdal.so.36")))
  # Only a version mismatch: no command, and still a stop.
  only <- system_library_check("unused", lock, c(), os = "linux", missing = list(sf = "libgdal.so.34"), newer = list(),
                               available = "libgdal.so.36", sysreqs = reqs)
  expect_length(only$packages, 0)
  expect_true(is.na(only$command))
  expect_equal(names(only$versions), "sf")
})

test_that("the installer's report of a binary that doesn't fit becomes failure rows and a message (#76)", {
  system <- list(packages = list(),
                 command = NA_character_,
                 newer = list(sf = list(versions = c("GLIBCXX_3.4.32", "GLIBC_2.38"),
                                        paths = c("/lib/libc.so.6", "/opt/conda/lib/libstdc++.so.6"))),
                 versions = list(terra = c(libgdal.so.34 = "libgdal.so.36", libproj.so.25 = "libproj.so.22, libproj.so.24")))
  lines <- missing_report_lines(system = system)
  rows <- install_failures(lines)
  expect_equal(rows$package, c("sf", "terra"))
  expect_equal(rows$kind, c("newer_system", "library_version"))
  expect_equal(rows$detail, c("GLIBCXX_3.4.32, GLIBC_2.38", "libgdal.so.36, libproj.so.22, libproj.so.24"))
  expect_equal(rows$libraries, c("/lib/libc.so.6, /opt/conda/lib/libstdc++.so.6", "libgdal.so.34, libproj.so.25"))
  msg <- install_failure_message(lines, 1L)
  expect_match(msg, paste("sf was built for a newer system than this one, and needs GLIBCXX_3.4.32, GLIBC_2.38",
                          "from libraries here that are older (/lib/libc.so.6, /opt/conda/lib/libstdc++.so.6)."), fixed = TRUE)
  expect_match(msg, "terra was built against libgdal.so.34, libproj.so.25, and this system has libgdal.so.36,", fixed = TRUE)
  expect_match(msg, "Installing the library again won't help.", fixed = TRUE)
  # One `Error:` line, so the message says both.
  expect_length(grep("^Error:", lines), 1)

  # A package with a missing library and a mismatched one: the missing
  # one's row wins, since installing it is something to do.
  both <- list(packages = list(sf = list(libraries = "libgeos_c.so.1", command = "sudo apt-get install -y libgeos-dev")),
               command = "sudo apt-get install -y libgeos-dev", newer = list(),
               versions = list(sf = c(libgdal.so.34 = "libgdal.so.36")))
  rows <- install_failures(missing_report_lines(system = both))
  expect_equal(rows$kind, "missing_system")
})

test_that("missing_system_libraries() finds nothing missing for packages whose libraries are all there (94)", {
  skip_if_not(identical(os_kind(), "linux") && nzchar(Sys.which("ldd")), "needs Linux and ldd")
  # R's own stats package links only to libraries R itself has.
  expect_equal(missing_system_libraries(.Library, "stats"), list())
  # A package with no compiled code has nothing to look at.
  expect_equal(missing_system_libraries(.Library, "datasets"), list())
})

test_that("missing_system_libraries() names each package whose library is gone, a symlinked package folder too (94)", {
  skip_if_not(identical(os_kind(), "linux") && nzchar(Sys.which("ldd")), "needs Linux and ldd")
  cc <- Sys.which("gcc")
  skip_if_not(nzchar(cc), "needs gcc to build stub libraries")
  dir <- tempfile("ember-ldd-test-"); dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  build <- file.path(dir, "build"); lib <- file.path(dir, "lib"); cache <- file.path(dir, "cache")
  dir.create(build); dir.create(lib)
  # A shared object linking `soname`, which is deleted once linked.
  stub <- function(out, soname) {
    writeLines("int fake(void){return 1;}", file.path(build, "fake.c"))
    writeLines("int fake(void); int f(void){return fake();}", file.path(build, "pkg.c"))
    fake <- file.path(build, soname)
    expect_equal(system2(cc, c("-shared", "-fPIC", "-o", shQuote(fake), paste0("-Wl,-soname,", soname),
                               shQuote(file.path(build, "fake.c")))), 0)
    dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
    expect_equal(system2(cc, c("-shared", "-fPIC", "-o", shQuote(out), shQuote(file.path(build, "pkg.c")),
                               paste0("-L", shQuote(build)), paste0("-l:", soname))), 0)
    unlink(fake)
  }
  stub(file.path(lib, "fakeunits", "libs", "fakeunits.so"), "libfakeudunits.so.0")
  # renv's cache layout when it links: the package folder is a symlink.
  stub(file.path(cache, "fakesf", "1.0", "abc", "fakesf", "libs", "fakesf.so"), "libfakegdal.so.34")
  file.symlink(file.path(cache, "fakesf", "1.0", "abc", "fakesf"), file.path(lib, "fakesf"))

  # One package: ldd prints no per-file header.
  expect_equal(missing_system_libraries(lib, "fakeunits"), list(fakeunits = "libfakeudunits.so.0"))
  # Two, plus one with nothing missing: one ldd call, with headers.
  expect_equal(missing_system_libraries(c(lib), c("fakesf", "fakeunits", "nothere")),
               list(fakesf = "libfakegdal.so.34", fakeunits = "libfakeudunits.so.0"))
})

test_that("ppm_distribution() and ppm_sysreqs_url() build the request for Package Manager, and nothing for other servers (95)", {
  expect_equal(ppm_distribution(linux_release(c("ID=ubuntu", 'VERSION_ID="24.04"'))),
               list(distribution = "ubuntu", release = "24.04"))
  expect_equal(ppm_distribution(linux_release(c('ID="rhel"', 'VERSION_ID="9.4"'))),
               list(distribution = "redhat", release = "9"))
  expect_null(ppm_distribution(linux_release(c("ID=arch"))))
  expect_null(ppm_distribution(NULL))

  dist <- list(distribution = "ubuntu", release = "24.04")
  expect_equal(ppm_sysreqs_url("https://packagemanager.posit.co/cran/2026-09-01", c("sf", "units"), dist),
               paste0("https://packagemanager.posit.co/__api__/repos/cran/sysreqs?all=false",
                      "&pkgname=sf&pkgname=units&distribution=ubuntu&release=24.04"))
  expect_equal(ppm_sysreqs_url("https://packagemanager.posit.co/bioconductor/2026-09-01/packages/3.23/bioc",
                               "Rhtslib", dist),
               paste0("https://packagemanager.posit.co/__api__/repos/bioconductor/sysreqs?all=false",
                      "&pkgname=Rhtslib&distribution=ubuntu&release=24.04&bioc_version=3.23"))
  # An institution's own Package Manager under a path.
  expect_match(ppm_sysreqs_url("https://ppm.example.org/rspm/cran/latest", "sf", dist),
               "^https://ppm.example.org/rspm/__api__/repos/cran/sysreqs")
  expect_null(ppm_sysreqs_url("https://cloud.r-project.org", "sf", dist))
  expect_null(ppm_sysreqs_url("file:///tmp/repos/cran/2026-09-01", "sf", dist))
  expect_null(ppm_sysreqs_url("https://packagemanager.posit.co/cran/2026-09-01", "sf", NULL))
})

test_that("parse_sysreqs() and sysreqs_command() turn Package Manager's answer into one command (96)", {
  reqs <- parse_sysreqs(sysreqs_fixture("ubuntu-sf-units"))
  expect_true(all(c("sf", "units") %in% names(reqs)))
  expect_equal(reqs$units$scripts, "apt-get install -y libudunits2-dev")
  expect_equal(sysreqs_command(reqs["units"], sudo = "sudo "), "sudo apt-get install -y libudunits2-dev")
  # Several packages: one apt-get line, each system package once.
  both <- sysreqs_command(reqs[c("sf", "units")], sudo = "")
  expect_match(both, "^apt-get install -y libgdal-dev .*libudunits2-dev$")
  expect_false(grepl("&&", both))

  # Red Hat's family: the commands that enable EPEL and CRB come first.
  rocky <- parse_sysreqs(sysreqs_fixture("rocky-sf"))
  cmd <- sysreqs_command(rocky["sf"], sudo = "sudo ")
  expect_match(cmd, "^sudo dnf install -y epel-release && ")
  expect_match(cmd, "sudo dnf install -y gdal3.4-devel gdal3.4 geos-devel proj-devel sqlite-devel$")

  expect_equal(parse_sysreqs(sysreqs_fixture("unsupported")), list())
  expect_equal(parse_sysreqs("not json"), list())
  expect_true(is.na(sysreqs_command(list())))
})

test_that("system_library_check() gives each package's libraries and command, and one command for all (97)", {
  lock <- parse_lock_lines(c("Rcpp 1.0.12 CRAN", "sf 1.0-21 CRAN", "units 0.8-5 CRAN"))$lock
  reqs <- parse_sysreqs(sysreqs_fixture("ubuntu-sf-units"))
  missing <- list(sf = c("libgdal.so.34", "libgeos_c.so.1"), units = "libudunits2.so.0")
  got <- system_library_check("unused", lock, c(), os = "linux", missing = missing, newer = list(),
                              available = character(), sysreqs = reqs)
  expect_equal(names(got$packages), c("sf", "units"))
  expect_equal(got$packages$units$libraries, "libudunits2.so.0")
  expect_match(got$packages$units$command, "apt-get install -y libudunits2-dev$")
  expect_match(got$command, "apt-get install -y libgdal-dev .*libudunits2-dev$")

  # Package Manager can't say (another server, an unknown Linux): libraries only.
  none <- system_library_check("unused", lock, c(), os = "linux", missing = missing, newer = list(),
                               available = character(), sysreqs = list())
  expect_true(is.na(none$packages$sf$command))
  expect_true(is.na(none$command))

  expect_null(system_library_check("unused", lock, c(), os = "linux", missing = list(), newer = list(),
                                   available = character(), sysreqs = reqs))
  expect_null(system_library_check("unused", lock, c(), os = "macos", missing = missing, sysreqs = reqs))
})

test_that("the installer's report becomes failure rows and the install's message (98)", {
  compiler <- list(packages = c("Rcpp", "units"), instructions = "Install Apple's command line tools.")
  lines <- missing_report_lines(compiler = compiler)
  rows <- install_failures(lines)
  expect_equal(rows$package, c("Rcpp", "units"))
  expect_equal(rows$kind, c("missing_compiler", "missing_compiler"))
  expect_equal(rows$detail, rep("Install Apple's command line tools.", 2))
  expect_match(install_failure_message(lines, 1L),
               "Rcpp, units need to build from source, and no compiler is installed. Install Apple's", fixed = TRUE)

  system <- list(packages = list(sf = list(libraries = c("libgdal.so.34"), command = "sudo apt-get install -y libgdal-dev"),
                                 units = list(libraries = "libudunits2.so.0", command = NA_character_)),
                 command = "sudo apt-get install -y libgdal-dev")
  lines <- missing_report_lines(system = system)
  rows <- install_failures(lines)
  expect_equal(rows$package, c("sf", "units"))
  # A row the command covers carries the one command that installs them
  # all; one it doesn't (Package Manager had no command for units: a
  # GitHub package, #76) carries only its libraries.
  expect_equal(rows$kind, c("missing_system", "system"))
  expect_equal(rows$detail, c("sudo apt-get install -y libgdal-dev", "libudunits2.so.0 not found"))
  expect_equal(rows$libraries, c("libgdal.so.34", "libudunits2.so.0"))
  msg <- install_failure_message(lines, 1L)
  expect_match(msg, "sf, units need system libraries that aren't installed (libgdal.so.34, libudunits2.so.0).", fixed = TRUE)
  expect_match(msg, paste("Install them with `sudo apt-get install -y libgdal-dev`, which doesn't install what",
                          "units needs: install that with your system's package manager. Then try again."), fixed = TRUE)
  expect_match(msg, no_admin_sentence, fixed = TRUE)

  # Every package covered: the one command.
  system$packages$units$command <- "sudo apt-get install -y libudunits2-dev"
  rows <- install_failures(missing_report_lines(system = system))
  expect_equal(rows$kind, c("missing_system", "missing_system"))
  expect_equal(rows$detail, rep("sudo apt-get install -y libgdal-dev", 2))
  expect_match(install_failure_message(missing_report_lines(system = system), 1L),
               "Install them with `sudo apt-get install -y libgdal-dev`, then try again.", fixed = TRUE)

  # No command known (not Package Manager): the libraries, as "system".
  two <- list(packages = list(sf = list(libraries = c("libgdal.so.34", "libgeos_c.so.1"), command = NA_character_)),
              command = NA_character_)
  lines <- missing_report_lines(system = two)
  rows <- install_failures(lines)
  expect_equal(rows$kind, "system")
  expect_equal(rows$detail, "libgdal.so.34, libgeos_c.so.1 not found")
  expect_equal(rows$libraries, "libgdal.so.34, libgeos_c.so.1")
  expect_match(install_failure_message(lines, 1L), "your system's package manager", fixed = TRUE)
  # Rows of other kinds have no libraries.
  expect_true(all(is.na(install_failures(missing_report_lines(compiler = compiler))$libraries)))
})

test_that("install_failures() reads a compiler missing during a source build as missing_compiler (99)", {
  gcc <- install_failures(c("* installing *source* package 'brokenpkg' ...",
                            "make: gcc: No such file or directory",
                            "make: *** [init.o] Error 127",
                            "ERROR: compilation failed for package 'brokenpkg'"))
  expect_equal(gcc$kind, "missing_compiler")
  expect_equal(gcc$detail, compiler_instructions())

  fortran <- install_failures(c("* installing *source* package 'brokenpkg' ...",
                                "make: /opt/gfortran/bin/gfortran: No such file or directory",
                                "ERROR: compilation failed for package 'brokenpkg'"))
  expect_equal(fortran$kind, "missing_compiler")
  expect_equal(fortran$detail, compiler_instructions(fortran = TRUE))

  xcrun <- install_failures(c("* installing *source* package 'brokenpkg' ...",
                              "xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools), missing xcrun at: /Library/Developer/CommandLineTools/usr/bin/xcrun",
                              "ERROR: compilation failed for package 'brokenpkg'"))
  expect_equal(xcrun$kind, "missing_compiler")

  # A compiler that is there but can't link (configure's own words, as
  # seen with BiocParallel and a stub compiler): not a build to Update.
  stub <- install_failures(c("* installing *source* package \u2018BiocParallel\u2019 ...",
                             "configure: error: in `/tmp/RtmpX/R.INSTALL1/BiocParallel':",
                             "configure: error: C++ compiler cannot create executables",
                             "See `config.log' for more details",
                             "ERROR: configuration failed for package \u2018BiocParallel\u2019"))
  expect_equal(stub$kind, "missing_compiler")

  # A missing header is still a system library, not the compiler.
  hdr <- install_failures(c("* installing *source* package 'xml2' ...",
                            "fatal error: libxml/tree.h: No such file or directory",
                            "ERROR: compilation failed for package 'xml2'"))
  expect_equal(hdr$kind, "system")
})

test_that("[net] Package Manager names libxml2's development package for xml2 on Ubuntu 24.04 (96)", {
  skip_if_not(identical(Sys.getenv("EMBER_TEST_NETWORK"), "1"),
              "set EMBER_TEST_NETWORK=1 to run the opt-in network test")
  reqs <- fetch_sysreqs(c(xml2 = "CRAN"), c(CRAN = "https://packagemanager.posit.co/cran/2026-09-01"),
                        dist = list(distribution = "ubuntu", release = "24.04"))
  expect_equal(sysreqs_command(reqs["xml2"], sudo = ""), "apt-get install -y libxml2-dev")
})

test_that("[net] Package Manager sends R 4.6 on Linux cli's source at 2024-06-01 and its binary at 2026-09-01 (117)", {
  skip_if_not(identical(Sys.getenv("EMBER_TEST_NETWORK"), "1"),
              "set EMBER_TEST_NETWORK=1 to run the opt-in network test")
  skip_if_not(identical(os_kind(), "linux") && getRversion() >= "4.6" && getRversion() < "4.7",
              "Package Manager's answer depends on this R's user agent")
  base <- "https://packagemanager.posit.co/cran/__linux__/noble/"
  expect_false(ppm_serves_binary(paste0(base, "2024-06-01/src/contrib/cli_3.6.2.tar.gz")))
  expect_true(ppm_serves_binary(paste0(base, "2026-09-01/src/contrib/cli_3.6.6.tar.gz")))
})
