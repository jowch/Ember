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
27. (2) A `[sources]` GitHub entry wins over a CRAN package of the same name.

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

## Disk and jobs (test-library.R)

59. `read_library_manifest` returns `NULL` for a missing folder and for a folder without a manifest.
60. Two installs of one key racing in two processes leave one library and no staging folder.
61. `cached_index` returns the identical object to two callers in one process.
62. Two sessions asking for one index share one job and both get the event.
63. `job_leave` by the last subscriber kills the process.
64. `clean(dry_run = TRUE)` lists libraries older than `max_age` and staging folders older than a day, and deletes nothing.
65. `clean()` keeps libraries active in an open session even when old.
66. `clean(cache = TRUE)` deletes only cache entries no manifest lists.

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
85. A failed Bioconductor index leaves the name `not_found` with an `index_unavailable` row, and is refetched only when the wanted set changes.
86. A pinned release is kept on another R and flagged `bioc_r_version`; an R with no known release fetches no Bioconductor index and gets a `bioc_unavailable` row.
87. A date move keeps Bioconductor packages at the new date's release, and fails rather than dropping them when a Bioconductor index can't be fetched.
88. A reopened notebook with a Bioc lock fetches the Bioconductor indexes when its wanted set changes, and reports no `not_in_index`.
89. A date move on an R with no known Bioconductor release fails for a notebook with Bioc packages; a failed Bioconductor index doesn't fail one for a notebook without any.

## Network, opt-in

75. **[net]** A notebook with `library(dplyr)` at a fixed past date resolves from PPM, installs with renv, and the worker loads exactly the locked versions.
76. **[net]** (2) A Bioconductor package resolves and installs from the dated Bioconductor URL.
77. **[net]** (3) `preview_update(nb, "dplyr", "1.1.4")` finds the date from crandb and lists the changes.
