# Packages (build step 3)

## Problem

Step 3 makes `library(dplyr)` work. The engine detects the package from the code, resolves it and its dependencies at the notebook's snapshot date, writes the lock into the file, installs a library with renv, and runs cells with that library. It must fit into step 2's engine without breaking its rules:

- One immutable `ember_state` per notebook.
- A pure `step()` and a thin shell.
- Saving and notifying are derived from the state before and after.
- The server never blocks.
- Safe preview: no installs before the first run.

Three things make the shape hard to see:

- **Slow outside work.** Resolution needs a 22k-entry index from the network. Installs take seconds to minutes.
- **Shared things.** Notebooks share an index cache, renv's cache and libraries. Several Ember processes may share them too.
- **A live worker.** A lock change has to reach a running worker. A new package should just load; a version change needs a restart.

Constraints that cross into this design:

- The worker only sees base R.
- `state$exports` feeds the graph.
- The lock is one line per package, stored verbatim today.
- The `seq` and `identical()` sharing rules.
- Endeavor's need for a snapshot and events.

## Usage (caller's view)

**The user adds `library(dplyr)` and runs.** Nothing about packages appears in the calls. The lock fills in as soon as the edit is applied, and the install starts on the first run.

```r
nb <- open_notebook("growth.R")                      # safe preview; no network if the lock already answers the code
edit_notebook(nb, insert_cell(2, "library(dplyr)\ncurves |> filter(od > 0.1)"))
package_status(nb)$plan                              # list(install = 34, restart = character())
# the file now has 34 lines in its /// lock block (cli 3.6.5 CRAN, dplyr 1.1.4 CRAN, ...)
run_cells(nb, 2, wait = TRUE)                        # allows; installs; then runs cell 2 and its ancestors
package_status(nb)$library$status                    # "ready"
```

While the install runs, cells that don't need dplyr still run. Cell 2 shows `queued` with `waiting_for = "dplyr"`.

**Endeavor's adapter asks for package status and acts on a missing package.**

```r
on_package_status <- function(nid) {
  p <- package_status(registry[[nid]])
  list(snapshot = p$snapshot, library = p$library$status, progress = p$library$progress,
       packages = p$packages,               # name, version, source, direct, status, message
       problems = p$problems)               # kind, package, message, fixes
}
on_notebook_event(nb, function(note) {
  if (note$kind == "packages_changed") push_notification(nid, "packages", seq = note$seq)
})
# A cell failed with `ggsave("x.svg")`:
err <- notebook_snapshot(nb)$cells[[7]]$errors[[1]]
err$kind; err$names; err$fixes   # "missing_package", "svglite", "Add svglite to [extra_packages]"
edit_notebook(nb, add_extra_package("svglite"))
```

**A test of resolution with a fixture index, and the same through the core.**

```r
idx <- read_repo_index(test_path("fixtures/repos/cran/2026-09-01/src/contrib/PACKAGES"),
                       key = "cran/2026-09-01", label = "CRAN")
r <- resolve_lock("dplyr", empty_lock(), list("cran/2026-09-01" = idx),
                  needed = "cran/2026-09-01")
expect_equal(format_lock_lines(r$lock), c("cli 3.6.5 CRAN", "dplyr 1.1.4 CRAN", "glue 1.8.0 CRAN"))

s <- new_state(file_with(cell("a", "library(dplyr)")), "nb.R", "n1", test_options(), at = t(0))
r <- drive(s, ev_open(t(1)))
expect_equal(effect_types(r), "fetch_index")
r <- drive(r$state, ev_index_fetched("cran/2026-09-01", idx, t(2)))
expect_match(format_notebook(notebook_file_of(r$state)), "# dplyr 1.1.4 CRAN", fixed = TRUE)  # the derived save writes it
```

**Moving the date ("update all").** You preview first, then apply.

```r
p <- preview_date(nb, Sys.Date())        # waits for the index of today's date
p$changes                                # name, from, to, change: dplyr 1.1.4 -> 1.2.1 upgraded, ...
set_date(nb, Sys.Date())                 # refused unless that preview is ready and current
# library installs; the worker had dplyr loaded, so it restarts once the
# library is ready, and the snapshot says "dplyr changed 1.1.4 -> 1.2.1"
```

**Running the file outside the engine.**

```r
ember::run("growth.R")                   # builds the lock's library if missing, then Rscript with it
ember::clean(dry_run = TRUE)             # what would be deleted
```

## Shape

**Data first.** All package facts for a notebook live in its state:

- `state$file$lock` is now an `ember_lock` value instead of verbatim lines. It holds sorted entries plus `unparsed` lines that are kept as they are. `notebook.R` parses and formats it, so the file round-trips byte for byte.
- `state$file$header` keeps `snapshot`, `bioc_version`, `sources` and `extra_packages`.
- `state$packages` (packages-core.R) holds:
  - `resolved_for`
  - `indexes` (one slot per repo key)
  - `problems`
  - `target` and `active` library slots
  - the one running `install`
  - a `proposal` for a date move
- `state$worker$loaded` records which namespace versions the worker has loaded.

The lock and header stay in `file`. The derived save writes them with no new code, and Endeavor sees a lock change as an ordinary `file_saved`.

**Each fact has one source:**

- The package set is `wanted_packages(graph, header)`, derived and never stored.
- A cell's waiting state is `waiting_cells(state)`, derived the same way as `failed_blockers()`.
- The library a lock needs is `library_for(lock)`, derived from the lock text.
- Readiness is one fact on disk: the manifest exists. The installer writes it last, in a staging folder that is then renamed into place.
- `resolved_for` is the only package history the core stores, and it is the counterpart of `stale`. The lock alone can't say which entries were roots, so without it removal would need the index on every open.

**One more stage in `step()`:** reduce, then `schedule_packages()`, then `schedule()`, then file reads. `schedule_packages()` decides everything:

- whether to resolve
- which index to fetch
- whether to look at or install the library
- when to switch the worker to a new library

Any event that changes what the notebook wants reaches the same code, so no handler has to remember to resolve or install. This applies to edits, sourced files, learned definitions, extra-package ops, an index arriving, an install finishing and a date move. It is the step-2 `schedule()` rule applied to packages.

**Resolution is a pure function.** `resolve_lock(roots, lock, indexes, needed, mode)` does a closure walk:

- Locked names keep their version (`"keep"` mode).
- New names come from the first index that has them.
- Anything the walk doesn't reach drops out, so removal needs no extra code.
- If a needed index isn't loaded, it returns `complete = FALSE` with the keys to fetch, and the stage emits the fetches. Bioconductor and GitHub (increment 2) plug in as more keys in `needed`, with no special case.
- A `"fresh"` walk at another date is the date move. No solver is needed: one date fixes one version per package.

**The worker follows the library; it isn't restarted for it.**

- Each library is named by its lock, so adding a package means a new folder, built quickly from cache links.
- `active` is the last ready library. The `run` message carries `library` the way it carries `order`, and the worker calls `.libPaths()` when the path differs. So a new package just loads.
- A restart happens only in `switch_library()`, when the new library changes the version of a namespace the worker has loaded. It waits for a running cell to finish.

**Waiting, not failing.**

- A cell whose packages are in the lock but not yet installed stays pending, and so does its downstream. `schedule()` skips them, so unrelated cells keep running during an install.
- A package that resolved to `not_found` doesn't hold its cell back. R raises "there is no package called" and the problem row explains it.

**Effects and events.**

- Effects: `fx_fetch_index`, `fx_check_library`, `fx_install`, `fx_cancel_install`.
- Events: `ev_index_fetched` / `ev_index_failed`, `ev_library_checked`, `ev_install_progress`, `ev_install_done`.
- Install events carry a token and library events carry a key. A stale or duplicated event is a no-op, as with worker generations.
- Safe preview gets resolution (metadata only) and a library look (one file read), so the banner can say "installs 34 packages". `fx_install` is never emitted until execution is allowed.

**Shared things are plain functions over the filesystem (library.R).**

- The index cache is a dated index saved as RDS forever, plus a memo per process so sessions share one R object.
- Libraries are built in a staging folder and then renamed into place. A process that loses the race deletes its copy, so no locks are needed.
- The renv cache is Ember's own, so `clean()` can never break the user's renv projects.
- `clean()` and `ember::run()` sit outside the core.

One process-wide table, `jobs`, lets two sessions that want the same index or library share one subprocess. It holds processes and subscribers and makes no decisions.

**renv comes from the server's own library** as an Imports dependency. Only the installer subprocess loads it, never the server or the worker.

**The test seam is the repository URL.** `ember_repos(cran = "file://…/fixtures/repos/cran")` drives the same code that reads PPM, with no mock. Resolution unit tests call `resolve_lock()` with a parsed fixture index. An offline end-to-end test installs two toy source packages from a `file://` repo. One opt-in test uses PPM.

**Interface depth.** The public additions are:

- `package_status`
- two edit ops (`add_extra_package`, `remove_extra_package`)
- `preview_date` and `set_date`
- `run` and `clean`
- `ember_repos` and `cache_dir`, plus `repos`/`cache` arguments to `open_notebook`
- `preview_update` in increment 3

Behind that sit detection, resolution, index caching, library naming, installs, waiting cells, the worker library switch, restarts, exports for the graph, the missing-package fix and cleanup. No caller ever asks for an install or a resolution: they edit code and run cells, as in Pluto.

### Decisions the brief asked for

- **Recommended packages are locked when the notebook needs them.** They are ordinary CRAN packages whose bundled copy changes with each R release. Leaving them out would let `ember::run()` on another R pick a different Matrix, and newer CRAN packages often need a newer Matrix than R ships. Base packages are never locked.
- **renv is an Imports dependency** and runs only in the installer subprocess with the server's library.
- **Moving the date:** "update all" and "move to date D" (preview, then apply) are in increment 1. They are the same `resolve_lock(mode = "fresh")` with no new data source, and the preview/apply flow is needed anyway. Per-package update and pinning an older version need CRAN release dates from crandb, so they are in increment 3. That brings a community service, its cache and its failure modes, but it only produces a date that feeds the increment-1 flow, so it adds nothing structural.

### Increments

1. **CRAN end to end:**
   - detection
   - the lock type in the file
   - CRAN resolution (add, remove, keep exact)
   - index cache and jobs
   - renv installs into hash-named libraries (staging and rename, manifest with exports)
   - worker library switch and restart rule
   - waiting cells
   - exports for the graph
   - the missing-package fix and `[extra_packages]` ops
   - package status in the snapshot
   - date move to an explicit date
   - R version recorded on allow
   - `ember::run()`, `clean()` with the 60-day pass
   - offline and opt-in tests
2. **Bioconductor, GitHub and source builds:**
   - Bioconductor (`bioc_version`, its index keys, the date-window warning): built, see [Bioconductor](#bioconductor)
   - `[sources]` GitHub as one-row indexes
   - the install plan job: download size and consent, compilers, system requirements
   - disk use
   - R minor version change with a Bioconductor pin: built, see [Bioconductor](#bioconductor)
3. **Release dates:** crandb, `preview_update()` for per-package update and pinning.

### Bioconductor

Built from increment 2. Resolution, the lock, the pin and the install's
repositories; the install plan (download size and consent, compilers) is
not.

- **Three repositories per release.** Bioconductor splits a release into
  software (`bioc`), annotation data (`data/annotation`: `GO.db`,
  `org.Hs.eg.db`, `BSgenome.*`) and experiment data (`data/experiment`).
  Each is its own key kind (`bioc`, `bioc-ann`, `bioc-exp`), dated like
  CRAN's (`bioc-ann/2026-09-01/3.23` ->
  `<repos$bioc>/2026-09-01/packages/3.23/data/annotation`). All three give
  the lock source `Bioc`; renv gets all three (`BioCsoft`, `BioCann`,
  `BioCexp`) and finds a package in whichever has it, so the lock doesn't
  need to say which.
- **Which release.** Each release is built for one R minor version, and
  each R minor version gets two (spring and autumn). The release is the
  latest one for the running R that was out by the snapshot date
  (`bioc_release_for()`, from the release list below). An R the list
  doesn't know, or a date before that R's first release, has no
  Bioconductor keys: its packages are `not_found`, next to a
  `bioc_unavailable` row that says why.
- **The release list** comes from bioconductor.org's `config.yaml`, the
  map BiocManager reads (`ember_repos(bioc_config)`, parsed by
  `parse_bioc_config()`); Ember ships no copy, so a new release needs no
  code change. A session fetches it once, when it first meets
  Bioconductor (a name CRAN lacks, or a lock holding a `Bioc` entry), and
  resolution waits for it as for an index. A list fetched on day F speaks
  only for snapshot dates up to F, since a release out by a later date may
  be missing from it (`releases_at()`); a later date asks for it again.
  The shell keeps the last list fetched in the cache and reuses it for a
  day if it covers the date asked for; when a fetch fails it falls back to
  that copy however old. A pinned notebook needs no list to resolve, and
  an unpinned one at a date the copy covers resolves as before, so both
  keep working while bioconductor.org is down. An unpinned notebook dated
  after the copy, or with no copy at all, finds no release rather than
  silently pinning an older one, and a `bioc_releases_unavailable` row
  says why; running asks again. A CRAN-only notebook never fetches the
  list. Tests use a checked-in copy (`fixtures/bioc-config`).
- **Fetched only when needed.** `needed_repos()` is CRAN's key, then the
  three Bioconductor keys. `schedule_packages()` fetches only CRAN's up
  front; `resolve_lock()` asks for the rest through `fetch` when a name
  isn't on CRAN. A CRAN-only notebook never downloads a Bioconductor index;
  a typo costs three index fetches, cached for good like CRAN's.
- **A locked name no loaded index has** asks for the unloaded keys too,
  so a reopened notebook whose lock holds Bioconductor packages fetches
  their indexes when its wanted set changes, rather than reporting each
  one `not_in_index`.
- **A failed Bioconductor index** is left out of resolution until the
  wanted set changes, so its packages resolve as `not_found` next to an
  `index_unavailable` row naming the index, instead of waiting forever.
  Then its slot is dropped rather than refetched, so it is fetched again
  only if a name still needs it.
- **The pin.** `header$bioc_version` is set to the release used once the
  lock holds a `Bioc` entry, and cleared when it holds none. A pinned
  release is kept on every later resolution; on another R,
  `bioc_r_version` says the release was built for a different R.
  `bioc_off_date` says the snapshot date is outside the release's window
  (from its release to the next).
- **Moving the date** resolves against the new date's CRAN index and the
  release for the running R at that date, so "update all" moves
  Bioconductor packages too, and the proposal carries the new pin. When
  the lock holds Bioconductor packages and the new date has no usable
  Bioconductor index (a fetch failed, or Bioconductor has no release for this R
  at that date), the proposal fails rather than dropping them from the
  lock. A notebook without any resolves without the failed index.
- **A new R minor version** (design.md, "R itself"). Package Manager
  builds a release's binaries only for its own R, so keeping a pin on
  another R builds every Bioconductor package from source. In safe
  preview, `bioc_r_version` says where running will move the pin
  (`bioc_move_target()`: the release for the running R at the notebook's
  date) and that it updates every Bioconductor package. Running the
  notebook, which also records the new R, proposes the move
  (`propose_bioc_move()`, a proposal of kind `"bioc"`): it re-resolves
  only the Bioconductor packages at the same date (`resolve_lock(mode =
  "bioc")`, CRAN entries kept) and applies itself, restarting R if a
  loaded package changes. The old pin's library isn't installed while the
  move is pending. With no release for the running R at that date, the
  pin stays and the row says so; moving the date (which moves the pin to
  that date's release) is the way out. A move whose index can't be
  fetched keeps the pin, shows a `bioc_move_failed` row, lets the old
  library install, and is proposed again on the next run.

Not built: asking before large downloads, compiler and system-library
checks.

## Where the direction strains

- **The index lives in state.** A 22k-entry index sits in every notebook state that uses that date. The per-process memo keeps it to one object, but it is still memory the state holds for good. Today's design keeps every index the session ever fetched, including old proposals' indexes. Should slots no longer needed be dropped?
- **Facts on disk mirrored in the state go stale.** The core believes a library is ready until something proves otherwise. Another process running `clean()`, or a user deleting the folder, is noticed only when a package fails to load (test 49). A shared service could watch the filesystem; a per-notebook core can't.
- **Cross-notebook work is coordinated below the core.** Two notebooks with the same lock each decide to install. Only the job table (shared subprocess) and staging-plus-rename (shared result) stop duplicate work. Those rules are outside `step()` and tested separately. The core can't express "another notebook is already installing this".
- **History in the state.** `resolved_for` is stored, not derived. A file whose code was edited outside Ember (a `library()` removed) keeps the extra lock lines until the next in-session change triggers resolution. The extra lines are harmless, since they only make the lock a superset, but they aren't pruned on open.
- **Waiting needs the shell loop.** `preview_date(wait = TRUE)` is a shell loop like `run_cells(wait = TRUE)`, and it can't be used inside `later` callbacks. The adapter uses `packages_changed` events.
- **`step()` gets bigger.** It gains a stage, seven event types and four effect types, and `check_state()` gains invariants. The step-2 file roughly doubles its package-related surface even though each piece is small.
- **The library hash is "pure in effect".** On R below 4.5, hashing text needs a temporary file.
- **`ember::run()` and `clean()` bypass the core.** They share functions with it (lock, library layout, installer) but not its state.

## Synthesis decision

Two candidates were drafted on two models. A is the base: package facts live
in each notebook's `ember_state`, and one more stage in `step()`,
`schedule_packages()`, decides resolving, fetching, checking and installing,
the way `schedule()` decides what the worker runs. Resolution is a pure
function over parsed indexes. Indexes, library checks and installs are
effects run in subprocesses by the shell, with results back as events.

B put a server-wide package manager beside the shell: it owned the index
cache, one install queue across notebooks and cleanup, and each session
mirrored its status. B's shape was not taken: lock changes, waits and
restarts would be decided in two places, the manager's status machine would
be mirrored in every session, and the `drive()` tests would no longer cover
packages. The two converged on most details, which A already has: libraries
named by the lock and the R version, built in a staging folder and renamed
into place, ready when their manifest exists; exports read from installed
packages without loading them; the worker switching `.libPaths()` and
restarting only when a loaded package's version changes; cells waiting per
package while unrelated cells run; recommended packages locked, base
packages never; renv only in a subprocess; moving to a date (and "update
all") in the first increment, crandb release dates later.

Taken from B: the test installer seam (a fake installer that writes an
empty library with a manifest), so core and shell tests need no renv run.

Build order: increment 1 below. Bioconductor, GitHub sources, install
consent, compiler and system-library checks (increment 2) and per-package
update and pin through crandb (increment 3) follow.

## Tradeoffs accepted

- We accept storing `resolved_for` (history) in exchange for opening an Ember-written notebook with no network and no write.
- We accept resolving and looking at the library in safe preview (network for metadata, one file read) in exchange for a banner that says what running will do. Nothing installs and no package code runs.
- We accept a new library folder per lock, even when adding one package, in exchange for libraries that are never modified in place. That means no locking, an atomic rename, and safe sharing between notebooks. A new library is built from cache links in seconds (measured 1.8 s warm).
- We accept that a cell downstream of a waiting cell waits too, even if it only uses base R, in exchange for never running a cell before its ancestors.
- We accept locking recommended packages in exchange for a lock that means the same thing on every R.
- We accept that edits update the lock in the file immediately, before any run, in exchange for the file always matching the code. A typed-then-deleted `library()` churns the lock block.
- We accept best-effort install progress, parsed from renv's output, in exchange for not reimplementing renv's restore. The manifest, not the progress, says what was installed.

## Alternatives considered

- **A package manager owned by the shell (or a process-wide service), with the core seeing only "library ready at path".** It would dedupe cross-notebook installs naturally and keep big indexes out of the state. But lock changes, waits and restarts would happen outside `step()`, so the save, notify and scheduling rules would need a second home, and the drive() tests would no longer cover packages. It hides less behind the same API and spreads one decision across two places. (The other runner explores this.)
- **Restart the worker on every lock change.** It is simpler: no `library` in the run message and no conflict check. But every added package would throw away all results, against the design's "a new package is just loaded".
- **One mutable library per notebook, installed into in place.** It saves disk churn, but two notebooks or processes could write one folder at once, a crashed install leaves a half library, and the design names libraries by lock hash so they can be shared.
- **Waiting by blocking the whole queue** (head of line) instead of skipping waiting cells. It is simpler, but a slow Bioconductor install would stall unrelated cells.

## Open questions and risks

- Does renv's cache link into libraries with hard links or symlinks on each platform? The spike saw the same inode, which a symlinked folder also produces. Cleanup is safe either way (manifests list cache entries), but "a library holds only links" and the disk-use numbers depend on it.
- Does `renv::restore()` install from a `file://` repository of source tarballs? The offline end-to-end tests depend on it. If it doesn't, should those tests use a local HTTP server (`httpuv` is coming in step 4)?
- Is resolving in safe preview acceptable? An unfamiliar notebook makes the server fetch an index from PPM when it opens: metadata only, but a network call before the user asked for anything.
- How long does `read.dcf()` on CRAN's full PACKAGES take? The design assumes about a second, which is why it happens in the fetch subprocess. This needs measuring.
- Should the waiting rule also hold cells while a needed index is still being fetched for an unlocked package (as sketched), or let them fail fast?
- Is a staging folder plus rename atomic enough on Windows, where a folder in use can't be renamed? A worker never uses a staging folder, but antivirus scanners do hold files.
- Does PPM's public instance accept a tool that fetches a dated index for every notebook date? The design already notes its terms are unstated.

## Next implementation step

Build lock.R and resolve.R with their fixture tests (1–27): the pure lock type and closure walk that everything else stands on. Then add `schedule_packages()` with `drive()` tests against fake index and install events.
