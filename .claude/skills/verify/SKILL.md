---
name: verify
description: Verify a change to Ember's notebook UI (the forked Pluto frontend in inst/frontend, or the R server behind it) by launching a real ember server, driving the page in a browser, and capturing screenshots and layout problems as evidence. Use after any frontend/CSS change, or to check a UI bug report.
---

# Verify an Ember UI change

Ember's UI is a page served by `ember::serve()` (R, `R/server.R`) and
driven over a websocket by a real R worker. Verify a change by running
that real stack, not by reading the CSS: open a notebook, put it in the
state the change is about, and look at it at the widths it's used at.

Everything here runs from `tests/e2e` and reuses the e2e suite's own
harness. Set up once: `npm --prefix tests/e2e ci`. Chromium comes from
`npx playwright-core install chromium`, or point `EMBER_CHROMIUM` at a
Chromium binary (in a Claude Code cloud session:
`/opt/pw-browsers/chromium-*/chrome-linux/chrome`).

## Launch

Two ways, both start a fresh server on a free port against a *copy* of
the notebook, from an empty data folder, and stop it afterwards:

- **Screenshots only:** `node tests/e2e/shots.mjs [fixture or path]
  [--run] [--dark] [--mac] [--full] [--widths 600,900,1440]`. Saves PNGs
  to `tests/e2e/test-results/shots/` and prints layout problems.
- **Driving a scenario:** write a scratch script (outside the repo) that
  imports the harness, the same way the tests in `tests/e2e/tests/` do:

  ```js
  import { startServer, tempNotebook } from "<repo>/tests/e2e/server.mjs";
  import { launchBrowser, newPage, openNotebook, cellSelector, setCellCode, runCell } from "<repo>/tests/e2e/browser.mjs";
  import { pageProblems, emulatePlatform, formatProblems } from "<repo>/tests/e2e/layout-check.mjs";
  const nb = tempNotebook("ui-sweep.R");
  const server = await startServer([nb]);          // resolves on "listening"
  const browser = await launchBrowser();
  const page = await newPage(browser);              // records console errors in page.problems
  await openNotebook(page, server.origin, server.secret, nb);
  // ... drive, screenshot, check ...
  await browser.close(); server.stop();
  ```

  Run it with `EMBER_E2E_LIB` set to a library holding this checkout's
  ember: `R CMD INSTALL --no-test-load --library=<dir> .` once, and again
  after every change to `R/` or `inst/frontend/` (the server serves the
  installed copy, not the working tree). `shots.mjs` and `npm test` do
  this install themselves when `EMBER_E2E_LIB` is unset.

Readiness: `startServer` resolves on the server's `ember: listening on`
line; `openNotebook` returns once `pluto-editor` loses `.loading`.

## Doctor

Before driving, check the instance is worth driving:
- `openNotebook` returned without timing out and `pluto-cell` count
  matches the notebook's cells.
- `page.problems` is empty (no console errors, page errors or dialogs).
- After "Run this notebook", `#ember-r-status` reads "R ready" and no
  `pluto-cell.running, pluto-cell.queued` remain.
If any fails, read the server log (`logFile` option of `startServer`)
and report that, rather than verifying against a broken page.

## Drive

Use the real user path: click the buttons and type into the editors a
person would, with the selectors in `features/`. Helpers in
`browser.mjs`: `setCellCode` (click into the cell's CodeMirror,
select-all, type), `runCell` (Shift+Enter), `cellSelector(id)`. Cell ids
come from the fixture's `# %% id=X` lines. Off-screen cells render a
static stand-in editor (`.cm-ssr-fake`); scroll a cell into view before
clicking it. Prefer roles and aria-labels (`getByRole("button", { name:
"Variables" })`) over coordinates.

Platform and size matter for this UI: it's used in a browser tab and in
Endeavor's notebook pane (WebKitGTK on Linux, WKWebView on macOS, often
600-900 px wide next to a chat). `emulatePlatform(page, "mac" | "other")`
before the first `goto` switches ⌘/Ctrl labels; `EMBER_BROWSER=webkit`
runs in Playwright's WebKit where it's installed.

## Evidence

For a UI change, the evidence is:
1. Screenshots of the affected state before and after the change, at
   600, 900 and 1440 px, light and dark if colours changed. Look at them
   (Read the PNG) and say what you see; don't only report that they exist.
2. `pageProblems(page)` for that state: generic rules (clipped, covered,
   off-screen, under an overlay scrollbar, cells in the same state that
   look different). Explained at the top of `tests/e2e/layout-check.mjs`.
   Report the problems that are new, not only "zero problems".
3. The side effect, where there is one: the notebook file on disk after
   an edit, the output text after a run.
4. `page.problems` empty at the end.

A precondition you can't meet (a package that won't install, WebKit not
installable here) is a failure to report, not something to work around
with a mock. The only accepted fakes are the suite's own: fixture
notebooks, fixture package repositories (`startServer`'s `repos`).

Then make it permanent where it's cheap: a layout bug that the sweep
caught should drop its `KNOWN` entry in `tests/e2e/tests/ui-sweep.test.mjs`
in the fixing PR; a state the sweep doesn't reach yet can be added to
that test or its fixture, `fixtures/ui-sweep.R`.

## Cleanup

`browser.close()` and `server.stop()` in a `finally`; stop only the
servers your script started (never by process name: other sessions'
servers may be running). Keep the screenshots: write them somewhere that
survives, and attach or link them in your report.

## Feature map

`features/README.md` indexes the main surfaces, with how to reach each,
how to drive it, and what a correct end state looks like. For release-
level and Endeavor checks that automation can't judge, see
`docs/ui-checklist.md`.
