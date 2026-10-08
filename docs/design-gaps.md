# Design gaps

Known gaps and follow-ups, by area. **Missing**: doesn't exist yet.
**Improvised**: built, works, but needs a proper look. Tick an item when it's
done; clear out ticked items at each release.

## Engine

- [ ] Replace the setup cell with settings cells ([settings-cells.md](settings-cells.md)) — missing
- [ ] Graph rebuild after an edit is whole-notebook: 30 ms at 100 cells, 64 ms at 500, 590 ms at 2000, spread across `notebook_graph()` with no single hot spot — improvised
- [ ] Learned references (formula columns that weren't in the data) aren't saved in the footer, so the edge they add is lost on reopen until the cell reruns — missing
- [ ] `library()` inside a function body counts as attaching, so a function that attaches conditionally always makes its cell run first — improvised
- [ ] Listeners run on the server thread after every dispatch; a `cell_state` storm during "Run all" on a 2000-cell notebook isn't measured — missing
- [ ] The session polls on `later`'s global loop, shared with whatever else the host process runs; a host callback that blocks stalls the poll. Decide whether to use a private loop — missing

- [x] An idle notebook with a worker used about 6% of a CPU core, because the shell polled every 5 ms while a worker existed. The poll now runs at 5 ms only while the shell waits on the worker, and at 250 ms otherwise (R/shell.R, `poll_interval()`) — improvised
- [ ] Replace the worker poll with a push: register the worker socket with `later::later_fd()` so a callback runs when it is readable, and keep only a slow timer for process exit and file watching. Base R connections don't expose their file descriptor, so the worker link would move to a socket library that does (e.g. nanonext); check Windows support first. Wanted long term: even the 250 ms idle poll is waste — improvised

## Worker

- [x] Editor services: completion, help pages and signatures (the request kinds exist and reply "unsupported") — missing
- [ ] Code that sets out to can reach the worker's own environment (`parent.env(environment(library))`); accidental shadowing is prevented, deliberate access isn't — improvised
- [ ] Undoing a non-setup cell's `attach()` or `detach()` is best effort: an entry that left the search path can't be recreated — improvised
- [ ] Formula column check skips a `data` argument that is a call rather than a symbol or `$`/`[[` path — improvised
- [x] Plot size isn't reported back, so `render_png()`'s `size` is always `NULL` — missing
- [ ] Interrupts on Windows: a plain interrupt works in CI, but one landing while a value is displayed isn't checked (the test is skipped there: processx's CTRL+C helper delivers too late for its timing). A late interrupt can also land in the next cell there, and one arriving between cells has stopped the worker in CI (test skipped there too) — improvised

- [ ] On macOS, R's `serverSocket()` can bind 0.0.0.0:P while another process already listens on 127.0.0.1:P, so a worker connecting to 127.0.0.1:P may reach the other process instead of its own server. Rare, macOS only; bind 127.0.0.1 explicitly or check the peer on connect — missing

## File format

- [ ] Converter tests need saved example files from each released format; only format 1 exists — missing
- [ ] Computed `source()` paths in the footer don't record which cell sourced them; they stand in for all cells until every code cell has run — improvised

## Packages (build step 3)

- [x] Detection from the code, the lock, installs with renv into per-notebook libraries — missing
- [x] Exports of installed packages for the graph before a cell attaches them — missing
- [x] Moving to a date ("update all", "move to date D") and `clean()` — missing
- [x] Bioconductor: `bioc_version`, its index keys (software, annotation, experiment), the release that matches the notebook's R and date, the date-window warning (packages.md, "Bioconductor") — missing
- [ ] Bioconductor: an R minor version change with a Bioconductor pin keeps the pin and only warns (`bioc_r_version`); design.md ("R itself") wants the engine to say the new release updates every Bioconductor package before recording it — missing
- [ ] Bioconductor: never installed for real. The renv-with-Bioconductor spike (Spikes) and the opt-in network test 76 are still to run; renv is trusted to find an annotation package in `BioCann` though the lock entry prefers `BioCsoft` (lock.R, checked in renv 1.0.3's code only) — missing
- [ ] GitHub sources: `[sources]` as one-row indexes (increment 2) — missing
- [ ] Install consent for large downloads, from the install plan's download size (increment 2) — missing
- [ ] Compiler check before an install that builds from source (increment 2) — missing
- [ ] System-library check before an install (increment 2) — missing
- [ ] Disk use of the per-notebook libraries (increment 2) — missing
- [ ] Per-package update and pin, with CRAN release dates from crandb (increment 3) — missing
- [ ] A snapshot date from before the running R was released has no binaries for it, so packages build from source, and old versions may not compile on the new R (cli from 2024 on R 4.6: `Rf_findVar` removed). Detect it before installing and explain (increment 2's install plan) — missing
- [x] A failed install reports only "install failed, status 1" with an empty log: the installer's output (renv's and the compiler's errors) never reaches the session, so the reason is invisible in the page and in `notebook_snapshot()` — missing. Built in c764563: the installer's output is kept and `install_failures()` parses it (test-packages-session.R, 90)
- [ ] `renv` is in Imports but used only by the installer script, so R CMD check notes it as not imported — improvised
- [ ] Indexes are cached forever because a dated index never changes (resolve.R:84-88), but today's can: PPM may publish today's snapshot after the first fetch, so updating to today twice on one day can miss packages released later that day. Harmless, since the lock pins what was chosen; the cache could skip writing an index dated today (ui-3-plan.md, piece 4) — improvised

## UI (build step 4)

- [x] A markdown cell shows its source under the rendered text, highlighted as R; it should start folded and highlight as markdown — improvised

- [x] Replace Pluto's logo and name in the page with Ember's own (with the theme, increment 2) — missing
- [x] Credit the Pluto.jl authors as copyright holders of the vendored frontend in DESCRIPTION or inst/COPYRIGHTS before any CRAN release — missing

- [x] No way to create a notebook from the browser: the index page lists hosted notebooks only. Today it is `new_notebook()` in R, then `start_server()` — missing
- [x] The cell menu still offers Pluto's "ask AI", and the footer's feedback form still shows (inert: nothing is sent) — improvised

- [ ] Coloured console output (cli, crayon) sits on the log box's dark brown background, where red text is hard to read; the ANSI colours need values chosen for that background, or a lighter box — improvised

- [x] Self-contained exports, and a browser with no internet: bundle the frontend's third-party libraries (MathJax aside) and serve the bundle always, with content-hashed names and long cache headers so a slow tunnel carries it once — missing

- [x] The page requested MathJax from the CDN after every load, even with no TeX on it; offline that was one failed request and a console error (exports included). Now it loads the first time an output contains TeX (an element with class `tex`), safe preview included (ui-3-plan.md, piece 7) — improvised
- [x] Argument tooltips stay on screen after the cursor leaves the cell (seen with `plot(` and `cat(` hints floating over later cells; planned: ui-3-plan.md, piece 6a) — missing
- [ ] Go-to-definition and variable links in the editor (ui-2.md piece 4e, cut from increment 2). Pluto's Julia `ScopeStateField` stays wired until it has an R replacement — missing
- [ ] Undo after deleting a disabled cell brings it back enabled: `order_ops()` re-inserts with code only (pluto-edits.R:157-158) (ui-3-plan.md, piece 1) — improvised
- [ ] `render_png()` with an explicit pixel size replaces the cell's stored image, so the page then shows that one-off image; it should return the bytes without storing them (ui-3-plan.md, piece 3) — improvised

- [x] Remote use: the server accepted only Host `127.0.0.1:<port>` or `localhost:<port>`, so an SSH tunnel to a different local port, or any reverse proxy (Posit Workbench, JupyterHub, VS Code port forwarding), got 403. Now a loopback Host is accepted on any port when Origin matches Host (or is absent); an opt-in `allowed_hosts` argument covers a proxy that isn't loopback — missing
- [x] Remote use behind a path prefix: the `/open` redirect and `/`'s notebook links were absolute (`/edit?...`), so a proxy serving Ember under a prefix like `/s/<id>/p/<port>/` (stripping that prefix before forwarding, the usual model) broke them once the browser followed a link built from the unprefixed path the backend sees. Both are relative now, as Pluto does — missing
- [ ] Remote use behind a path prefix, without its trailing slash: a request for the bare prefix (`/s/<id>/p/<port>`, no trailing `/`) and one for the prefix with a trailing slash both arrive here as exactly `GET /` once the proxy strips the prefix (checked against `tests/e2e/proxy.mjs`'s `forwardPath()`, which collapses both to `/`) -- this process has no way to tell them apart, since it never learns the prefix at all (the whole reason every URL it builds is relative, not absolute). Every relative edit link this process hands back (`/open`'s redirect, the start page's `ember_new_notebook`/`ember_open_notebook` replies) resolves correctly against the trailing-slash URL but one folder too high against the bare one (a browser resolves a relative URL against its directory, and `.../p/<port>` with no trailing slash has `.../p/` as its directory). Not fixable here: the fix has to be on the proxy's side (redirect the bare prefix to one with a trailing slash before forwarding, which is what a path-prefix-aware proxy like JupyterHub's server proxy already does) — missing

- [x] Pluto frontend fork, protocol in R, removals, R adaptations, theme — missing
- [x] The R grammar wired into CodeMirror (`frontend-build/package.json` depends on `@ember/lezer-r`) — missing
- [x] Rich outputs in the browser: widget files as static paths, table and tree views, terminal colours — missing
- [x] URL secret — missing
- [ ] The server finds the notebook from each message's `notebook_id` rather than the one the client connected to, so one page's socket can act on another notebook it names (both need the secret). An access check, not polish: refuse a message whose `notebook_id` isn't the socket's own — missing
- [ ] The browser tests run against whatever ember Rscript's default library has; they should install the working tree into a temp library themselves — improvised
- [ ] Intermittent e2e failure: after clicking "run this notebook" in the safe-preview popup, the server sometimes never receives `restart_process`, so nothing runs and the test times out (CI run 37133421678, `lazy.R: editing A shows B as "stale"` (73), waiting for B's "2"). Seen twice in well over 1,000 runs of that scenario, and only under heavy load: once on CI, and once on a 2-CPU Linux VM running three suites at once. Never seen on macOS or with CPU throttling alone. In the traced failure the page was alive (pings answered, render state current, no console errors), the server log showed no `restart_process`, and a second page on the same notebook still showed safe preview. So the server, worker and state sync are fine; the click never sent the request. Still open: whether the click missed the link's handler (the popup closing or moving between Playwright's hit test and the click, e.g. its 0.2 s open transition or a reflow while MathJax or fonts load) or `restart()` (Editor.js) stopped before its `send`; one way it could, an `await update_notebook()` chained behind earlier updates, was removed in ui-3-plan.md piece 7a, so a recurrence would point at the click. Next step: log the popup's close reason and `restart()`'s steps in a test build until a failure shows which one; if it is the click, the test should wait for safe preview to end and click again — missing

- [ ] Undo after deleting a cell fails when the cell's id isn't a UUID (hand-written files, such as the e2e fixtures' `B`): the server refuses the re-insert with "cell id must be a UUID" (R/step.R:670) and the page logs an error. Accept any id the file format accepts on re-insert, or give such cells a UUID when the file is read — improvised
- [ ] "Restart R" in the Status tab doesn't tell the run tracker a run started, so a restart that reruns cells isn't announced when it ends (ui-3.md, Accessibility) — improvised
- [ ] `tests/testthat/fixtures/pluto-css-variables.txt` still requires dead theme variables (`--frontmatter-*`, `--binder-loading-header-color`) that were kept for Pluto/Endeavor compatibility. Ember is now built standalone, so the contract can drop names nothing uses — improvised

- [ ] Flaky on Windows CI: test-server.R test 31 ("interrupt_all sends SIGINT to the running cell") once saw no restart offer within 15 s, then passed on re-run (ci/flame-secret, a frontend-only change). Look at the interrupt grace timer's timing on slow Windows runners if it recurs — improvised

- [ ] Packages tab against Panel3: the failure card has a plain border where the board's is red-tinted; the table header and status pills differ a little; the Status tab's Interrupt and Restart buttons are 32 px, the board's 30 px. `ember-forms.css` and `editor.css` both define `.ember-btn` with different padding and colours — improvised
- [ ] When a never-run cell starts running, the "Not run yet" chip goes and the output arrives about 60 ms later, so the layout moves twice; keep the chip's space until the output arrives. Cmd+Enter on an unchanged cell briefly sets it waiting to run (the 250 ms delay hides it) — improvised
- [ ] Help panel against Panel3: R's own "Description" heading still shows; the search field lacks the board's icon, 30 px height and page background; See Also is R's paragraph, not a row of links — improvised
- [ ] Help page links: R's footer (`00Index.html`) and "Run examples" (`../Example/...`) aren't rewritten, so they leave the page or break; a link clicked inside a help page is labelled "follows the cursor" — improvised
- [ ] `start_server()` checks the server's output every 0.5 s from the user's R session to reprint the link; on macOS and Linux it should wait on the pipe with `later::later_fd()` instead (Windows pipes don't work with it, so keep a slower poll there) — improvised
- [ ] Dialogs opened with `ask()`/`tell()` (reload, lost connection, "Ember restarted") show in the browser's default serif font: `.ember-dialog` is attached outside the editor and has no `font-family` — improvised
- [ ] After the server refuses a stale key, the Status tab still says "Reconnecting"; the header says "Ember restarted". Pass `key_refused` through BottomRightPanel.js — improvised
- [ ] A tab left open across a restart that lands on a different port keeps retrying with "Reconnecting", since nothing at its address refuses it — improvised
- [ ] The signature tooltip above the line catches clicks meant for the line under it — improvised
- [ ] `not_explicit_and_too_boring` (live docs) checks Julia's number node names (`IntegerLiteral`, `FloatLiteral`); R's parser calls it `Number`, so the check never fires — improvised

## Grammar

- [ ] The corpus test reads the gitignored `spikes/corpus/`, so it only runs on one machine. Commit a small corpus or skip when absent — improvised
- [ ] Offer it back to `lezer-r` — missing

## Integration with Endeavor

- [ ] Endeavor's debug state records page messages by wrapping `window.alert` (src/debug_state.rs `RECORD_ALERTS`); Ember's messages are in-page dialogs now (common/dialogs.js) and never call `alert`, so that list stays empty for Ember. Ember records each dialog in `window.ember_dialogs` (`{title, body, answer}`) and fires an `ember-dialog` event; Endeavor's debug script should read that — missing
- [x] The adapter's `run(wait = TRUE)` can't block the server; it needs `on_notebook_event()` or a promise once httpuv is in (step 4). Built on Ember's side: `on_notebook_event()` (R/api.R) — missing
- [ ] Check that Endeavor's adapter waits on a run with `run_cells(wait = FALSE)` and `on_notebook_event()`, not `run(wait = TRUE)` — missing
- [ ] Endeavor's docs still describe Pluto's restart ("then every cell runs") and a snapshot without stale state; update them there — missing
- [ ] Endeavor takes F1 and Ctrl/Cmd + ? on `window` in the capture phase for its own shortcut sheet (endeavor/frontend/src/actions.ts:161-172), so inside Endeavor F1 never reaches Ember's "R help at the cursor" (ui-3.md, Keyboard shortcuts). Endeavor should let both keys through on Ember pages, or open Ember's sheet from ⋯ instead — missing
- [ ] Endeavor's overrides follow the system theme (theme.ts:77, 139, 196), not Ember's Theme setting; an Ember set to Dark on a light system shows Endeavor's overrides in light colours. Read `<html data-theme>` instead, or hide the setting inside Endeavor — missing
- [ ] Endeavor's CSS targets Pluto shapes that increment 3 restyles: the striped `pluto-trafficlight::after`, `jlerror > .error-header`, `section.stacktrace-waiting-to-view` (cells.ts:24-34, errors.ts:32-43). Nothing breaks, but those rules stop matching — improvised
- [ ] Endeavor's Present, Record and Frontmatter actions (actions.ts:1-5, 155-159) do nothing on Ember pages; hide them there — improvised
- [ ] Graph edges gain `via = "disabled"` (a reader of a name only a disabled cell defines; ui-3-plan.md, piece 1). Check that Endeavor's graph queries treat it as an edge to a cell that doesn't run — missing
- [ ] Endeavor hides the header's old file picker (frontend/src/theme.ts:295, `nav#at_the_top > pluto-filepicker`) so renaming/moving isn't offered inside it; Ember's header now has a file-name button `#ember-file-name` opening the Rename or move dialog, which that rule no longer matches, so it shows inside Endeavor until Endeavor's CSS targets `#ember-file-name` (decided: Endeavor adapts) — missing. Keep the button's id stable.
- [ ] Ember's side panel (`#helpbox-wrapper.open`) now has a fixed width (400px docked, 380px slide-over). Endeavor's docs drawer (frontend/src/drawer.ts:83-85) sets `left: 0; right: 0` but no width, so the docs show in a 400px strip; Endeavor adds `width: auto` to that rule (decided: Endeavor adapts) — missing
- [ ] Endeavor adds its own "Stack trace ›" toggle to every `jlerror` with a `> section` (frontend/src/errors.ts:222-247), and opening it clicks Pluto's old `section.stacktrace-waiting-to-view button`. Ember's error box (increment 3, piece 6) has its own traceback toggle and no such button, so inside Endeavor an error shows two toggles and Endeavor's opens nothing. Endeavor stops adding its toggle on Ember pages and uses Ember's; its agent text (`errorText()`) can keep reading `stacktrace` from the notebook state (decided: Endeavor adapts) — missing

## Packaging and CI

- [x] LICENSE in R's two-line `YEAR` / `COPYRIGHT HOLDER` form for `MIT + file LICENSE` — missing
- [x] `R CMD check` clean on macOS — missing
- [x] CI on macOS, Linux and Windows (`.github/workflows/check.yaml`) — missing

## Spikes still to run

- [ ] Release builds ship Ember's own frontend files minified (dev keeps them readable): a release script minifies each file in place, keeping names and layout, before `R CMD build`; CI runs the browser tests against that build too. Say where the readable source is (inst/COPYRIGHTS, the frontend README), in case CRAN asks — missing
- [ ] Server and worker on Linux and Windows (responsiveness, interrupt, restart) — missing
- [ ] rig's user-mode R on Windows — missing
- [ ] rv against renv on Linux and Windows. The Bioconductor part is the first step of the Bioconductor work (Packages) — missing
- [ ] Whether any package overwrites a setting the notebook already set (decides whether the note in Global settings is needed) — missing

## Interactive inputs (build step 5)

- [ ] The R-side API for bonds (Pluto's `@bind`) — missing
- [ ] Interactive inputs bound to variables: a slider or text box whose value is an R variable, so moving it reruns the cells that depend on it. Not in increment 3. Two references: Pluto's `@bind` with the `AbstractPlutoDingetjes` Bonds protocol (the page side, `common/Bond.js` and `common/SliderServerClient.js`, is still in Ember's vendored frontend and is kept), and marimo's `mo.ui.*` elements, whose value other cells read. Increment 3's Export menu drops Pluto's check for password inputs inside bonds (`WarnForVisisblePasswords`); bonds would need it back — missing
