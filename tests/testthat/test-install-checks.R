# The installer's checks (R/install-checks.R): a compiler for packages that
# build from source, and the system libraries installed packages link to.
# Plain functions; the parts that ask the machine (`xcode-select`, `ldd`,
# Package Manager) take their answers as arguments, so these run anywhere.
#
# Covers packages-tests.md items 90-99 ("Install checks").

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
  expect_null(compiler_check(lock, nowhere, linux_binaries = TRUE, os = "linux", compiler = FALSE))
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
  got <- system_library_check("unused", lock, c(), os = "linux", missing = missing, sysreqs = reqs)
  expect_equal(names(got$packages), c("sf", "units"))
  expect_equal(got$packages$units$libraries, "libudunits2.so.0")
  expect_match(got$packages$units$command, "apt-get install -y libudunits2-dev$")
  expect_match(got$command, "apt-get install -y libgdal-dev .*libudunits2-dev$")

  # Package Manager can't say (another server, an unknown Linux): libraries only.
  none <- system_library_check("unused", lock, c(), os = "linux", missing = missing, sysreqs = list())
  expect_true(is.na(none$packages$sf$command))
  expect_true(is.na(none$command))

  expect_null(system_library_check("unused", lock, c(), os = "linux", missing = list(), sysreqs = reqs))
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
  # Every row carries the one command that installs them all, and its own
  # libraries.
  expect_equal(rows$kind, c("missing_system", "missing_system"))
  expect_equal(rows$detail, rep("sudo apt-get install -y libgdal-dev", 2))
  expect_equal(rows$libraries, c("libgdal.so.34", "libudunits2.so.0"))
  msg <- install_failure_message(lines, 1L)
  expect_match(msg, "sf, units need system libraries that aren't installed (libgdal.so.34, libudunits2.so.0).", fixed = TRUE)
  expect_match(msg, "Install them with `sudo apt-get install -y libgdal-dev`, then try again.", fixed = TRUE)
  expect_match(msg, no_admin_sentence, fixed = TRUE)

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
