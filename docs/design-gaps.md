# Design gaps

Known gaps and follow-ups, by area. **Missing**: doesn't exist yet.
**Improvised**: built, works, but needs a proper look. Tick an item when it's
done; clear out ticked items at each release.

## Engine

- [ ] Graph rebuild after an edit is whole-notebook: 30 ms at 100 cells, 64 ms at 500, 590 ms at 2000, spread across `notebook_graph()` with no single hot spot — improvised
- [ ] Learned references (formula columns that weren't in the data) aren't saved in the footer, so the edge they add is lost on reopen until the cell reruns — missing
- [ ] `library()` inside a function body counts as attaching, so a function that attaches conditionally always makes its cell run first — improvised
- [ ] Listeners run on the server thread after every dispatch; a `cell_state` storm during "Run all" on a 2000-cell notebook isn't measured — missing
- [ ] The session polls on `later`'s global loop, shared with whatever else the host process runs; a host callback that blocks stalls the poll. Decide whether to use a private loop — missing

## Worker

- [ ] Editor services: completion, help pages and signatures (the request kinds exist and reply "unsupported") — missing
- [ ] Code that sets out to can reach the worker's own environment (`parent.env(environment(library))`); accidental shadowing is prevented, deliberate access isn't — improvised
- [ ] Undoing a non-setup cell's `attach()` or `detach()` is best effort: an entry that left the search path can't be recreated — improvised
- [ ] Formula column check skips a `data` argument that is a call rather than a symbol or `$`/`[[` path — improvised
- [ ] Plot size isn't reported back, so `render_png()`'s `size` is always `NULL` — missing
- [ ] Interrupts on Windows: a plain interrupt works in CI, but one landing while a value is displayed isn't checked (the test is skipped there: processx's CTRL+C helper delivers too late for its timing). A late interrupt can also land in the next cell there, and one arriving between cells has stopped the worker in CI (test skipped there too) — improvised

## File format

- [ ] Converter tests need saved example files from each released format; only format 1 exists — missing
- [ ] Computed `source()` paths in the footer don't record which cell sourced them; they stand in for all cells until every code cell has run — improvised

## Packages (build step 3)

- [x] Detection from the code, the lock, installs with renv into per-notebook libraries — missing
- [x] Exports of installed packages for the graph before a cell attaches them — missing
- [ ] Per-package update and pin (crandb release dates), Bioconductor, GitHub sources, install consent for large downloads, compiler and system-library checks, disk use (increments 2 and 3 in packages.md); moving to a date and cleanup are built — missing
- [ ] A snapshot date from before the running R was released has no binaries for it, so packages build from source, and old versions may not compile on the new R (cli from 2024 on R 4.6: `Rf_findVar` removed). Detect it before installing and explain (increment 2's install plan) — missing
- [ ] `renv` is in Imports but used only by the installer script, so R CMD check notes it as not imported — improvised

## UI (build step 4)

- [x] A markdown cell shows its source under the rendered text, highlighted as R; it should start folded and highlight as markdown — improvised

- [x] Replace Pluto's logo and name in the page with Ember's own (with the theme, increment 2) — missing
- [x] Credit the Pluto.jl authors as copyright holders of the vendored frontend in DESCRIPTION or inst/COPYRIGHTS before any CRAN release — missing

- [ ] No way to create a notebook from the browser: the index page lists hosted notebooks only. Today it is `new_notebook()` in R, then `start_server()` — missing
- [x] The cell menu still offers Pluto's "ask AI", and the footer's feedback form still shows (inert: nothing is sent) — improvised

- [ ] Coloured console output (cli, crayon) sits on the log box's dark brown background, where red text is hard to read; the ANSI colours need values chosen for that background, or a lighter box — improvised

- [ ] Remote use: the server accepts only Host `127.0.0.1:<port>` or `localhost:<port>`, so an SSH tunnel to a different local port, or any reverse proxy (Posit Workbench, JupyterHub, VS Code port forwarding), gets 403. Accept a loopback Host on any port when Origin matches Host; add an opt-in `allowed_hosts` for proxies — missing
- [ ] Remote use behind a path prefix: links and redirects are absolute (`/edit`, `/deps/...`, `/open`), so a proxy serving Ember under `/s/<id>/p/<port>/` breaks them. Make every URL relative, as Pluto does — missing
- [ ] Self-contained exports, and a browser with no internet: bundle the frontend's third-party libraries (MathJax aside) and serve the bundle always, with content-hashed names and long cache headers so a slow tunnel carries it once — missing

- [ ] Pluto frontend fork, protocol in R, removals, R adaptations, theme — missing
- [ ] The R grammar wired into CodeMirror — missing
- [ ] Rich outputs in the browser: widget files as static paths, table and tree views, terminal colours — missing
- [x] URL secret — missing
- [ ] The server finds the notebook from each message's `notebook_id` rather than the one the client connected to, so one page's socket can act on another notebook it names (both need the secret) — improvised
- [ ] The browser tests run against whatever ember Rscript's default library has; they should install the working tree into a temp library themselves — improvised

## Grammar

- [ ] The corpus test reads the gitignored `spikes/corpus/`, so it only runs on one machine. Commit a small corpus or skip when absent — improvised
- [ ] Offer it back to `lezer-r` — missing

## Integration with Endeavor

- [ ] The adapter's `run(wait = TRUE)` can't block the server; it needs `on_notebook_event()` or a promise once httpuv is in (step 4) — missing
- [ ] Endeavor's docs still describe Pluto's restart ("then every cell runs") and a snapshot without stale state; update them there — missing

## Packaging and CI

- [x] LICENSE in R's two-line `YEAR` / `COPYRIGHT HOLDER` form for `MIT + file LICENSE` — missing
- [x] `R CMD check` clean on macOS — missing
- [x] CI on macOS, Linux and Windows (`.github/workflows/check.yaml`) — missing

## Spikes still to run

- [ ] Server and worker on Linux and Windows (responsiveness, interrupt, restart) — missing
- [ ] rig's user-mode R on Windows — missing
- [ ] rv against renv on Linux and Windows, including Bioconductor — missing
- [ ] Whether any package overwrites a setting the notebook already set (decides whether the note in Global settings is needed) — missing

## Interactive inputs (build step 5)

- [ ] The R-side API for bonds (Pluto's `@bind`) — missing
