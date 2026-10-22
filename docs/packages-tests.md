# Step 3 tests

One line each. No test touches the network unless marked **[net]**; those
run only with `EMBER_TEST_NETWORK=1`. Fixtures:

- `fixtures/repos/cran/2026-09-01/src/contrib/PACKAGES` and
  `.../2026-09-30/...`: hand-written indexes (about 15 entries: a dplyr-like
  closure, a package with LinkingTo, one with `Depends: R (>= 4.1), methods`,
  Matrix as a recommended dependency, a duplicate entry with two versions).
- `fixtures/repos/toy/<date>/src/contrib/`: two tiny pure-R source packages
  (`toyA` imports `toyB`; `toyA` 0.1 on the first date, 0.2 on the second)
  with their PACKAGES, so renv installs offline from `file://` with no
  compiler.

Increment 1 unless marked (2) or (3).

## Lock format (test-lock.R)

1. `parse_lock_lines` reads `name version source` lines into sorted entries.
2. A line's extra fields after the source survive a parse and format byte for byte.
3. A malformed line goes to `unparsed` with a `lock_line` problem and is written back unchanged.
4. A duplicate name keeps the first line and reports the second.
5. `format_lock_lines` sorts by name in C order whatever the session locale.
6. `lock_diff` reports added, removed, upgraded and downgraded with `package_version` order (`1.10.0` > `1.9.0`).
7. `library_for` gives the same key for the same lines in any order, and a different key when one version changes.
8. `library_for` ignores extra fields and unparsed lines when hashing.
9. `library_for`'s path contains the R minor version and platform.
10. `renv_lockfile_of` gives one minimal record per entry and the dated CRAN URL.

## Detection (test-detect.R)

11. `wanted_packages` collects library, require, requireNamespace, `::`, box and pacman names across cells.
12. `wanted_packages` includes packages named in a sourced file.
13. `wanted_packages` adds `[extra_packages]` and drops base packages.
14. `wanted_packages` keeps recommended packages (MASS) as ordinary names.
15. A computed `library(pkg)` contributes nothing.

## Resolution with fixture indexes (test-resolve.R)

16. `read_repo_index` drops version constraints and `R`, and keeps Depends, Imports and LinkingTo but not Suggests.
17. `read_repo_index` keeps the highest version of a duplicated entry.
18. Resolving `dplyr` into an empty lock gives the full closure at the date's versions.
19. Adding `glue` keeps every existing entry at its locked version (mode keep).
20. Removing `dplyr` from the roots drops the dependencies nothing else needs and keeps shared ones.
21. A name in no index gives a `not_found` problem and leaves the rest resolved.
22. A locked version that differs from the index gives `off_date` and is kept.
23. A recommended package reached as a dependency (Matrix) is locked.
24. A missing index makes the result incomplete, names the key in `fetch` and returns the lock unchanged.
25. Mode fresh at a later date moves every version and `lock_diff` lists them.
26. (2) A name missing from CRAN asks for the Bioconductor indexes, then resolves there with source `Bioc`.
27. (2) A `[sources]` GitHub entry wins over a CRAN package of the same name (in test-github-sources.R).

## Core: packages in step() (test-packages-core.R, with drive())

28. Opening an Ember-written notebook whose lock answers its code emits no effect and changes nothing.
29. Opening a notebook whose code names a package the lock lacks emits `fetch_index` for its date.
30. A notebook with no snapshot date gets the event's date when its first package appears.
31. `index_fetched` resolves, writes the lock into the state, and the derived file text changes.
32. A duplicate `index_fetched` is a no-op.
33. `index_failed` keeps the lock and adds `index_unavailable`; the same wanted set doesn't refetch.
34. In safe preview a missing library is checked but never installed.
35. After `allow`, a missing target emits exactly one `install`; a second event emits none.
36. A lock change during an install waits for the running job, then installs the new target.
37. `install_done` for an old token or key leaves the target alone.
38. `install_done` with no manifest marks the target failed and adds `install_failed`.
39. A failed target is not retried until `ev_run`, which retries it once.
40. A cell attaching a package not yet installed stays pending and is not sent.
41. A cell downstream of a waiting cell is not sent; an unrelated cell is.
42. When the library becomes ready the waiting cell is sent with the new `library` path in its run message.
43. A cell using a `not_found` package is sent and doesn't wait.
44. A ready target with no version conflict becomes active without a restart.
45. A ready target that changes a loaded package's version restarts the worker and leaves every cell not run, with the reason in the snapshot.
46. A conflicting switch while a cell runs waits for `done`, sends nothing new, then restarts.
47. `library_checked` exports give a cell attaching the package edges before it runs.
48. A worker `packageNotFoundError` for a package outside the lock gives a `missing_package` error whose fix adds it to `[extra_packages]`.
49. The same error for a package the active library claims makes the library be checked again.
50. `add_extra_package` changes the header, resolves, and is refused for a name already from code when removed.
51. `preview_date` fetches the date's index and fills the proposal's changes.
52. `set_date` is refused without a ready, current preview for that date.
53. `set_date` moves the header date and the lock in one step.
54. An edit that changes the wanted set recomputes a ready proposal.
55. `allow` records the running R version in the header when it differs.
56. `packages_view` per-package statuses: installed, installing, missing, failed, not_found.
57. `packages_changed` is notified once per dispatch when the view changes, and not otherwise.
58. `check_state` holds after every step in every test above.

A preview fetches a `provisional` index again with a `fresh` fetch (the same date included) and resolves against what arrives; one that isn't provisional is kept (#39).

## Disk and jobs (test-library.R)

59. `read_library_manifest` returns `NULL` for a missing folder and for a folder without a manifest.
60. Two installs of one key racing in two processes leave one library and no staging folder.
61. `cached_index` returns the identical object to two callers in one process.
62. Two sessions asking for one index share one job and both get the event.
63. `job_leave` by the last subscriber kills the process.
64. `clean(dry_run = TRUE)` lists libraries older than `max_age` and staging folders older than a day, and deletes nothing.
65. `clean()` keeps libraries active in an open session even when old.
66. `clean(cache = TRUE)` deletes only cache entries no manifest lists.

`index_may_change` is true for a dated key from yesterday on, in UTC, and false for older ones and GitHub keys (#39).

## Worker (test-worker.R additions)

67. The hello and each `done` report the namespaces loaded, with versions.
68. `library(notapkg)` reports `error$package = "notapkg"` in a non-English locale.
69. A run message with a new `library` changes `.libPaths()` before the code runs.

## Session end to end, offline (test-packages-session.R)

70. A notebook with `library(toyA)` on the `file://` toy repo installs toyA and toyB on first run, then runs the cell.
71. Adding a second notebook with the same lock reuses the library folder (same path, no installer run).
72. Moving the toy date from the first to the second upgrades toyA, restarts the loaded worker, and the cell reruns on request with 0.2.
73. The saved file's lock block lists toyA and toyB and round-trips unchanged on reopen.
74. `ember::run()` on the saved file installs if needed and prints the cell's output with the locked version.

An index dated today is read from the saved copy on open, fetched again by a preview of today (so a package added to today's snapshot later that day is found), and a session opened after that reads the new copy; offline, the preview falls back to the saved copy (#39).

## Bioconductor (increment 2)

In test-resolve.R:

78. Each Bioconductor kind (software, annotation, experiment) has its own key and dated URL, all labelled `Bioc`; `repo_urls` lists the three only with a pin.
79. The release is the latest one for the running R out by the snapshot date (none before that R's first release); `needed_repos` is CRAN, then the three Bioconductor keys at the pin or the derived release, and CRAN alone for an R with no known release.
80. A CRAN package needing an annotation package (`wgcna` -> `GO.db`) resolves it from the annotation repository.
81. `bioc_problems` flags a release built for another R and a snapshot date outside the release's window.

In test-packages-core.R, with `drive()`:

82. A CRAN-only notebook never fetches a Bioconductor index and carries no pin.
83. `library(DESeq2)` fetches the three Bioconductor indexes after CRAN's, locks it as `Bioc`, pins the release in the header, and the install gets all four repositories.
84. Removing the last Bioconductor package drops the pin.
85. A failed Bioconductor index leaves the name `not_found` with an `index_unavailable` row, shown as `lookup_failed`, and is refetched when the wanted set changes or on run (#264).
86. A pinned release is kept on another R and flagged `bioc_r_version`; an R with no known release fetches no Bioconductor index and gets a `bioc_unavailable` row.
87. A date move keeps Bioconductor packages at the new date's release, and fails rather than dropping them when a Bioconductor index can't be fetched.
88. A reopened notebook with a Bioc lock fetches the Bioconductor indexes when its wanted set changes, and reports no `not_in_index`.
89. A date move on an R with no known Bioconductor release fails for a notebook with Bioc packages; a failed Bioconductor index doesn't fail one for a notebook without any.

## Install checks (test-install-checks.R)

90. `linux_release`/`linux_family` name the package manager from `/etc/os-release`, through `ID_LIKE` for a derivative.
91. `compiler_instructions` says what to install on macOS, Windows and each Linux family, with `sudo` only when not root.
92. `source_builds` names compiled packages with no binary at the locked version, and every compiled one when there are no binaries.
93. `compiler_check` reads no index when the compiler is there or Linux gets binaries, and names the source builds otherwise.
94. `parse_ldd` reads the libraries not found, with and without per-file headers, leaving R's own out.
95. `ppm_sysreqs_url` builds Package Manager's request for CRAN and Bioconductor, and nothing for another server or an unknown Linux.
96. `parse_sysreqs`/`sysreqs_command` merge Package Manager's answer into one command, with Red Hat's pre-install steps first. **[net]** xml2 on Ubuntu 24.04 needs libxml2-dev.
97. `system_library_check` gives each package's libraries and command, and one command for all.
98. The installer's `EMBER-MISSING` lines become `missing_compiler`, `missing_system` and `system` rows, and its `Error:` line the message.
99. A compiler missing during a source build is `missing_compiler`; a missing header stays `system`.
117. On Linux with Package Manager binaries, `compiler_check` asks Package Manager about one package; binaries (or no answer) skip the check, a source answer counts every compiled package and offers a newer date. **[net]** At 2024-06-01 it sends R 4.6 cli's source, at 2026-09-01 its binary.
118. `renv_failed_packages` reads renv's "failed to install" error in either quotes; `failed_builds` leaves out dependents renv never built, and names none without an index; `no_binary_packages` names the failed packages with no binary at the locked version (macOS: the binary index; Linux with Package Manager binaries: asked per package, through Bioconductor's repositories; Linux without them, GitHub sources and unlocked names: none).
119. The installer's `EMBER-MISSING binary` line turns a failed build (`compile`, `configure`, `other`) into `no_binary` with the version, and leaves a missing compiler or a download as it was; its `Error:` line is the message.
120. A real renv log (cli 3.6.2 at 2024-06-01 on R 4.6.1) is `no_binary`; in a real log with dependents (cli, rlang failed; lifecycle waited on them), cli and rlang are `no_binary` and lifecycle a `dependency` on cli; without the installer's line, "ERROR: loading failed" after a source build is `compile`. The Packages tab card says why and offers Update (e2e, install-no-binary.test.mjs).

## GitHub sources (increment 2)

In test-github-sources.R:

100. A `github:` spec reads user, repo and an optional ref; `"user/repo"` reads as the same, and so does a github.com link to the repository or a `/tree/<ref>`, `/commit/<sha>` or `/releases/tag/<tag>` page (#85); any other link or scheme is no spec. The op and the header reader save a link in the `github:` form; the header reader leaves a bare `user/repo` as written.
101. A locked commit answers a spec of the same repository (any case), and a commit spec only when it is that commit.
102. `source_keys` asks for the locked commit's key while the spec is unchanged, and for the spec's ref otherwise; `lock_for_sources` drops entries that disagree with `[sources]`.
103. renv's record for a GitHub entry names the host, user, repo and commit, and the dependencies as `Imports`; `lock_diff` calls a move to another commit a source change.
104. `fetch_github_main` on the `file://` fixture finds a ref's commit, reads only its DESCRIPTION, and saves the index under both keys; a missing ref stops with the source named, and a commit with no DESCRIPTION says it isn't an R package. Without `NeedsCompilation` the index leaves it unknown.
105. `github_install_deps` reads the cached index, and fetches it into a cache that never resolved it.
106. A package with a source is fetched from GitHub together with CRAN's index, and isn't resolved from CRAN's alone.
107. Once both arrive the lock holds the commit, dependencies come from CRAN, and the file and the view show the source; the install carries the GitHub API.
108. A reopened notebook fetches nothing at open, and asks for its commit's key when the wanted set changes.
109. Changing the source looks the new ref up and moves the lock; removing it sends the package back to CRAN, or to `not_found`.
110. A failed GitHub lookup keeps the lock and names the package, until running retries it; a source holding another package resolves nothing; an unreadable source is reported and ignored.
111. A source added by hand for a CRAN-locked package resolves at open; moving the date back keeps the commit.
114. Moving the date forward ("update all") asks a branch again and the preview moves it to the new commit; a commit entry stays at its commit.
115. A failed lookup's message says whether to suspect a missing ref, a private repository without a token, the token, or the rate limit; `github_token` takes `GITHUB_PAT`, then `GITHUB_TOKEN`.
116. `remove_package_source` without one valid package name is refused and removes nothing.
121. The Packages tab's rows (#78): a not-found package given a source is `looking_up` while the lookup runs, then locked with its `spec`; a failed lookup keeps a `source_failed` row with the reason, without R's "Error:"/"Execution halted" wrapping; a locked package whose new ref fails keeps its row and says why.

In test-server.R:

122. `ember_set_package_source` replies `{ok}`, writes the entry and the row looks it up and locks it; a bad source's refusal is the reply and changes nothing; `ember_remove_package_source` sends the package back to not found; a read-only notebook gets the refusal for both.

In the browser (github-source-add.test.mjs, against the toy repository and the `file://` GitHub fixture): a refused source shows under the field; a typo leaves a "source failed" row with the reason; "Change source" starts from the entry and fixing it shows the GitHub line; "Remove source" sends it back to not found.

In test-packages-session.R:

112. A package from a `[sources]` entry installs at the ref's commit with its CRAN dependency from the toy repo, and the cell runs.
113. `ember::run()` installs a saved GitHub lock into a cache that never resolved it.

## r-universe sources (#203)

In test-universe-sources.R:

123. A `universe:` spec, or a link to an r-universe or any page in it, reads as `universe:<name>` (lower case); anything else reads as GitHub's or as nothing. The lock source names the universe, the git repository, a subdirectory after `//`, and the commit, and reads back.
124. `source_keys` keeps a locked universe commit's key while the spec is unchanged, and asks for the latest build otherwise or on refresh; `lock_for_sources` drops a universe entry whose source is gone or changed; a move to another commit is a source change.
125. renv's record is the universe's repository while it serves the locked commit, else a GitHub record for that commit (github.com, even with a GitHub Enterprise API set), else a git record with the subdirectory; `repo_urls` names each universe the lock uses.
126. `fetch_universe_main` on the `file://` fixture reads the latest build's JSON and saves it under both keys; a commit the universe no longer serves is read from GitHub; a missing package, a build that doesn't say its commit, and a moved commit off GitHub each stop with a message; `universe_served` and `github_install_deps` read the fixture.
127. In the core: a universe entry is fetched with CRAN's index and the lock holds its commit; the install gets the universe's URL; a reopened notebook asks for the commit's key; update all takes the latest build and moving back keeps the commit; `set_package_source` saves a link as `universe:`; a failed lookup names the package and doesn't fall back to CRAN.

In test-packages-session.R:

128. A package from a `[sources]` universe entry installs from the universe's own build (its DESCRIPTION's `Repository` and `RemoteSha`) and runs; a universe whose build isn't the commit its API names gets the package installed again from GitHub at that commit (`universe_wrong_builds()`, also unit-tested); a locked commit the universe no longer serves, under the same version, installs from GitHub at that commit.
129. **[net]** highr from yihui's universe resolves, its lock source names github.com/yihui/highr, and the installed build is the locked commit; pinned to v0.11's commit, which the universe no longer serves, `ember::run()` installs it from GitHub.

## Network, opt-in

75. **[net]** A notebook with `library(dplyr)` at a fixed past date resolves from PPM, installs with renv, and the worker loads exactly the locked versions.
76. **[net]** (2) A Bioconductor package resolves and installs from the dated Bioconductor URL.
77. **[net]** (3) `preview_update(nb, "dplyr", "1.1.4")` finds the date from CRAN's index of its files and lists the changes. Offline, the toy repo's `toy-meta` stands in for CRAN's files; the core tests cover a snapshot that lags a release.
130. (#37) An install whose Bioconductor data packages add up to more than `ask_above` stops before downloading, with the library `"asking"` and the sizes, and installs after `approve_install()`; nothing in renv's cache is counted, and running again isn't an OK. Offline: a copy of the Bioconductor fixture with a sized GO.db tarball and the fake installer (test-packages-session.R), plus the core and `large_downloads()` tests.
