# UI, increment 2

Increment 1 (docs/ui.md, docs/ui-frontend.md) put Pluto's frontend in front
of the engine with Julia-only features switched off behind `EMBER`. This
increment makes the page Ember's own and fills in what increment 1 deferred.
It is five pieces, each a separate branch that ends in something that runs:

1. **Ember's look**: delete what was switched off, Ember's name, theme and
   logo placeholder, markdown cells, credits.
2. **Offline bundle**: no CDN at run time; exports that highlight as R.
3. **Rich outputs**: table and tree views, widget files, plot re-render,
   terminal colours.
4. **Editor services**: completion, help panel, signatures, go-to-definition.
5. **Status views**: packages, "N cells not run", stale label, worker memory.

Recommended order: 1, 2, 3, 5, 4 (see [Order](#order-of-implementation)).
Tests are listed in [ui-2-tests.md](ui-2-tests.md).

## Rules every piece follows

- **Pluto's fields stay filled.** Endeavor's page script reads
  `process_status`, `status_tree` and `nbpkg` from `window.editor_state`
  (endeavor/frontend/src/status.ts:20-22, drawer.ts:218). Ember's own data is
  added beside them, never in their place.
- **Ember's additions to the frontend object** go in three places only, so
  they are easy to find: a top-level `ember` map (piece 5), a per-cell
  `cell_results[id].ember` map (piece 5), and new fields on
  `cell_inputs[id]` (`kind` in piece 1, `ember_spans` in piece 4). The
  projection stays a pure function of `ember_state` (pluto-state.R:48).
  `pluto_edits()` already refuses client patches to any `cell_inputs` field
  other than `code` and `code_folded` (pluto-edits.R:76-95), so the page can
  read these fields but not change them.
- **New page requests are named `ember_*`** so they never collide with a
  Pluto request type, and each gets a row in the request table
  (server.R:468-491).
- **New worker messages are added on both sides in one commit.** The shell
  turns an unknown worker message type into `wk_failed`, and the poll then
  kills the worker (shell.R:685-697, 551-564). A worker that sends a reply
  the server doesn't know yet would be killed for it.
- **Kept as they are**: the DOM hooks (`pluto-cell[id]`, `pluto-input
  .cm-content`, `button.add_cell`, `pluto-output`, `.code_differs`,
  `header`, `main pluto-notebook`), every CSS variable name in
  `themes/light.css` and `themes/dark.css` (203 names), `window.editor_state`,
  CodeMirror 6 as one copy, and the URLs `/edit`, `/notebookfile`,
  `/notebookexport`. Endeavor's page code reads all of these
  (endeavor/frontend/src/*.ts; the URLs from endeavor/src/notebook_pane.rs).

---

## 1. Ember's look

### Problem

The page still says Pluto and Julia, and the switched-off Julia features are
still in the code behind 22 `EMBER` checks. Several Pluto features that
contact outside servers were never switched off:

- `check_access()` fetches `https://pluto-available.fonsp.com/` on connect
  when the host is `localhost`, and can blank the page and kill the socket
  if that server says so (Editor.js:927, 1917-1931).
- On every parse error, `FixWithAIButton` probes Pluto's AI server and
  `chat.openai.com` and, if they answer, offers to send the cell's code to
  Pluto's AI service (ErrorMessage.js:268, FixWithAIButton.js:17-35,
  75-99). The cell menu also offers "Ask AI" (CellInput.js:1093-1101). The
  server never sends `enable_ai_editor_features = false`, so both show.
- The footer's feedback form is rendered unconditionally (Editor.js:1897);
  only `init_feedback` (which loads Firebase) is switched off.

Also: a markdown cell shows its source highlighted as R and unfolded
(design-gaps.md, UI), and the cell menu's "Hide logs" item is still shown
although the server refuses `show_logs` (CellInput.js:1065-1073,
pluto-edits.R:86-88). Pluto.jl's authors are not credited anywhere in the
package metadata.

### What the user sees

- The header shows the word "Ember" where Pluto's logo was; the tab title is
  `<file> — Ember`; the favicon is the same wordmark.
- Ember's colours and fonts (values to be chosen, see Open questions); the
  same layout as today.
- No "Ask AI", "Fix with AI", "Disable in notebook", "Skip as script",
  "Hide logs", feedback form, Binder or "run locally" buttons, recording,
  slides, front matter, Pluto.land upload, Pkg bubbles, language picker.
- Markdown cells: rendered text with the source folded away; unfolding shows
  the source highlighted as markdown (with R highlighting inside fenced
  code blocks). New markdown cells start folded.
- Text that mentioned Julia or Pluto now says R or Ember ("You are reading
  and editing this file without running R code").

### Shape

**Every `EMBER` spot, and what happens to it.** After this piece
`common/EmberFlags.js` is deleted and `grep -r EMBER inst/frontend` finds
nothing.

| spot | what it gates | piece 1 |
|---|---|---|
| ErrorMessage.js:436, 465 | Julia's "begin … end" hint vs. the engine's fix lines | keep the Ember branch, delete the Julia branch and the import |
| CellInput.js:281 | `NotebookpackagesFacet` (Pkg bubbles) | delete the compartment and the facet |
| CellInput.js:609 | `pkgBubblePlugin` | delete; delete `CellInput/pkg_bubble_plugin.js` |
| CellInput.js:638 | `unsubmitted_globals_updater` (Julia scope) | delete, with Editor's `unsumbitted_global_definitions` state and `get_unsubmitted_global_definitions` |
| CellInput.js:678 | Julia mixed parser | delete the Julia branch; replace with the language-by-kind rule below |
| CellInput.js:693 | `go_to_definition_plugin` | delete the line; piece 4 adds the R version |
| CellInput.js:694 | `AiSuggestionPlugin` | delete; delete `CellInput/ai_suggestion.js` |
| CellInput.js:712 | `request_packages`, `request_special_symbols` | delete the gate; piece 4 rewrites `pluto_autocomplete.js` |
| CellInput.js:1057 | "Disable in notebook" | delete, with Cell.js's `toggle_running_disabled` |
| CellInput.js:1084 | "Skip as script" | delete, with Cell.js's `toggle_skip_as_script` |
| Editor.js:954 | `init_feedback` | delete; delete `common/Feedback.js` and the footer form (Editor.js:1897-1903) |
| Editor.js:1758 | `RecordingUI` | delete; also `RecordingPlaybackUI` (rendered unconditionally at Editor.js:1767), `common/AudioRecording.js`, `AudioPlayer.js` |
| Editor.js:1779 | `FrontMatterInput` | delete the file |
| Editor.js:1788 | `ProjectTomlEditor` | delete the file |
| Editor.js:1794 | `PlutoLandUpload` | delete the file and its export-menu entry |
| Editor.js:1882 | `SlideControls` | delete the file |
| BottomRightPanel.js:119, 179 | "Live docs" tab | left gated until piece 4 replaces it with the R help panel; the only `EMBER` use that survives piece 1 (moved to a local constant `HELP_PANEL = false`, deleted in piece 4) |
| common/NewUpdateMessage.js:4 | GitHub release check | delete the file and its caller |
| Editor/LaunchBackendButton.js:33 | Binder / run locally | delete, with `EditOrRunButton.js`, `common/Binder.js` (`count_stat`, `start_binder`), `common/RunLocal.js`, `binder.css` |
| common/Binder.js:89 | `count_stat` | delete with its callers (Editor.js:1057, 1510; Binder.js:101) |

**Not gated in increment 1, deleted now**: `check_access` (Editor.js:927,
1917-1931); `FixWithAIButton.js`, `AIContext.js`, the "Ask AI" menu item and
the `AI_EDITOR_FEATURES` setting (Settings.js:118, 222); the "Hide logs" menu
item (Ember has no `show_logs`); the Ctrl/Cmd+M handler `keyMapMD`
(CellInput.js:406-466, 539-542), which wraps code in Julia's `md"""`;
`PkgStatusMark.js` and the `nbpkg` popup branch in `Popup.js` (reachable
only from the deleted bubbles); the welcome page (`index.html`, `index.js`,
`index.css`, `welcome.css`, `featured-card.css`, `components/welcome/`,
`featured_sources.js`; `/` is already Ember's own page, server.R:774-785);
`error.jl.html`; Pluto's logo files. `scopestate_statefield.js` (62 KB)
stays until piece 4: three places still read it (LiveDocsFromCursor.js:69,
pluto_autocomplete.js:512, CellInput.js:856), and removing the field makes
them throw (docs/ui-frontend.md, "Deviation").

About 350 KB of files go, plus 534 KB of translations (below).

**Name and text.**

- `lang/english.json`: the 27 strings that mention Julia or Pluto are
  rewritten or deleted with their feature. Other languages: see Open
  questions; the proposal is English only, deleting the other 20 files,
  `LanguagePicker.js`, `lang/update_languages.jl`, `lang/Project.toml`, and
  the dynamic loader in `imports/lang_imports.js`.
- Editor.js:1535 title: `` `${shortpath} — Ember` `` (no balloon).
- Editor.js:1695 `alt="Pluto.jl"` becomes `alt="Ember"`.
- PasteHandler.js:10 looks for `### An Ember notebook ###`, the file
  format's first line (design.md, File format), not Pluto's.
- editor.html:20-24: the console line becomes
  `"Ember, an R notebook. Its frontend is a fork of Pluto.jl by Fons van der
  Plas and the Pluto.jl authors (MIT)."` The credit stays.
- Footer: keep the settings link; the FAQ link points at Ember's README
  until Ember has docs.

**Logo.** The mark is a flame with a twisting hollow heart, giving off
specks; the word is "ember" in Instrument Sans SemiBold, converted to
outlines so no font is needed. Three files:

- `img/logo.svg`: the mark beside the word, for the header (`pluto-logo-big`).
- `img/favicon.svg`: the mark alone, for the tab icon and the narrow header
  (`pluto-logo-small`).
- `man/figures/logo.svg` and `logo.png` (240 by 278): the hex sticker, for
  the README and pkgdown.

The dark theme already passes header images through `--image-filters`, which
lightens the word and keeps the flame orange.

- Editor.js:289-290 and NotifyWhenDone.js:45 already read those links.
- Deleted: `favicon*.png`, `favicon.ico`, `favicon*.svg`,
  `logo_white_contour.svg`.

The CSS sizes the header image by height (editor.css:1049-1054), so any
aspect ratio fits. Not every browser has supported SVG favicons (Safari was
the holdout); if the tab icon is blank there, add a PNG fallback beside it.

**Theme.** `themes/light.css` and `themes/dark.css` get new values for the
same 203 variable names; none is renamed or removed. Colours, fonts and
spacing that `editor.css` hard-codes (for example `"Alegreya Sans"` at
editor.css:130, `"Vollkorn"` at 142, 332, 691) become variables. Variables
that are new, not renamed, are named `--ember-*`. `--julia-mono-font-stack`
keeps its name (Endeavor doesn't read it, but other CSS does) and gets the
new code font. Which colours and fonts is the user's choice (Open
questions). Piece 2 vendors whichever fonts this piece keeps.

**Markdown cells.**

- Projection: `project_cell_input()` (pluto-state.R:176) adds
  `kind = view$kind` ("code" or "markdown"). The cell key already covers it
  (it holds `state$cells[[i]]`).
- Page: Cell.js passes `kind` to CellInput; CellInput picks the language in
  a compartment: `r()` for code; for markdown,
  `markdown({ base: markdownLanguage, codeLanguages: (info) => /^(r|R|)$/.test(info) ? rLanguage : null })`.
  `markdown`, `markdownLanguage` and `rLanguage` are already exported by the
  bundle (frontend-build/src/index.js:82, 91).
- Engine: `insert_cell(..., kind = "markdown")` makes the cell folded
  (step.R:532: `folded = identical(op$kind, "markdown")`).
- Translation: `order_ops()` inserts with
  `kind = after$cell_inputs[[id]]$kind %||% "code"` (pluto-edits.R:156), so
  "undo delete" and paste of a markdown cell keep it markdown. Today they
  would come back as code cells.
- A file that lists a markdown cell without `folded` still opens it
  unfolded; the fold state is the file's (Open questions).

**Credits.**

- DESCRIPTION:
  `Authors@R: c(person("Jonathan", "Chen", ..., role = c("aut", "cre")), person("The Pluto.jl authors", role = "cph", comment = "frontend in inst/frontend, forked from Pluto.jl (MIT)"))`
  and `Copyright: See inst/COPYRIGHTS.`
- `inst/COPYRIGHTS`: one entry per component with its licence and holder.
  This piece writes Pluto.jl (MIT, "Copyright (c) 2020-2026 the Pluto.jl
  authors", as inst/frontend/LICENSE says), codemirror-pluto-setup (whose
  source `frontend-build/src/index.js` copies), CodeMirror 6 and Lezer
  (MIT). Piece 2 adds the generated third-party list.
- `inst/frontend/LICENSE` (Pluto's MIT text) stays where it is.

### Tests

ui-2-tests.md 1-12.

### Risks

- A deleted file still imported somewhere stops the whole module graph and
  leaves a blank page. The e2e "open" test catches it; run it after each
  batch of deletions, not once at the end.
- Endeavor's page script submits Pluto's feedback form
  (endeavor/frontend/src/actions.ts:92). On an Ember page that form no
  longer exists, so Endeavor should not offer "feedback" for Ember
  notebooks.
- New theme values can make Endeavor's own overrides
  (endeavor/frontend/src/theme.ts) clash in colour. The names are
  unchanged, so nothing breaks; check it by eye.
- Dropping the other languages removes translations some users rely on.

### Order within the piece

1. Credits (no code risk).
2. Deletions, one row of the table at a time, e2e after each batch.
3. Name and text, then logo.
4. Markdown cells (engine, projection, translation, page).
5. Theme.

---

## 2. Offline bundle

**Revived, after piece 4 (decided with the user).** Two needs the CDN can't
meet: self-contained downloaded exports (what Pluto's own export menu and
Endeavor ask for), and a browser with no internet, as when Ember runs on a
remote machine reached over SSH from a locked-down desktop. So the
third-party libraries are bundled (MathJax aside, loaded from the CDN only
when a page has TeX, as Pluto does) and the bundle is served always, live
page and exports alike. Bundle files get content-hashed names and long
cache headers, so a slow tunnel carries them once per browser.

### Problem

The page loads its libraries, fonts and icons from jsdelivr, esm.sh, unpkg
and Google Fonts. The frontend's source names 160 distinct external URLs;
following their imports gives 263 files (crawl of every URL, sizes read,
nothing saved). So:

- the page doesn't work offline, and the e2e job fails when a CDN does
  (ui-tests.md section 3);
- every page load tells several third parties that someone is using it;
- exports have no usable frontend root (below).

### What the user sees

Nothing changes on screen. The notebook opens with the network off (as
over an SSH tunnel from a machine without internet). After the first visit
the large library files come from the browser's cache without a request. A
downloaded export is one HTML file that opens from disk on another machine,
offline, with code highlighted as R and widgets working.

### Bundle or vendor as-is

**Vendor as-is** (download each CDN file, rewrite its URL): the jsdelivr
`+esm` and esm.sh files are build outputs of those services, with absolute
imports inside them (`/npm/d3-require@1.2.4/+esm`, `/node/process.mjs`) that
would need rewriting too. Rerunning the download is the only way to check
the copy is current, and the services rebuild these files over time, so the
check would be flaky. Licences have to be collected by hand.

**Bundle third-party libraries from npm (chosen).** Pin every library in a
`package.json` with a lockfile and build them with rollup into
`inst/frontend/imports/vendor/`. Ember's own frontend files (Pluto's
components) stay unbundled in `inst/frontend`, so there is still no build
step for Ember's own code, and its diffs against upstream Pluto stay
readable. The existing `imports/*.js` shims (`Preact.js`, `lodash-es.js`,
`immer.js`, `DOMPurify.js`, ...) already isolate each library behind one
file; only their `from` lines change. The CI check is the same as the
CodeMirror bundle's: `npm ci && npm run build`, then the committed output
must match. This is deterministic because the lockfile pins every version.

A **full bundle** of the whole frontend (Pluto's own release does this for
its offline exports) is not built. It would be a second copy of the
frontend (about 1.9 MB, pushing the installed package past CRAN's 5 MB),
and it would have to be rebuilt and committed after every edit to Ember's
own frontend files. Exports embed the files the live page uses instead
(Shape, Exports).

### Measured sizes

From the crawl (bytes as the CDNs serve them):

| group | files | size | what ships after this piece |
|---|---|---|---|
| JavaScript libraries | 42 | 525 KB | about 450 KB (two immer versions and two js-sha256 copies become one each) |
| MathJax `tex-svg-full.js` | 1 | 2.2 MB | stays on the CDN, loaded only for TeX (Open questions) |
| font files, all formats and subsets | 140 | 6.6 MB | the woff2 Latin and Latin-extended files of the families piece 1 keeps: 0 KB (system fonts) to about 400 KB |
| font CSS | 18 | 36 KB | replaced by local `@font-face` rules |
| ionicons SVGs | 61 | 35 KB | 35 KB |

And what is already in `inst/frontend` (4.3 MB today):

| part | today | after pieces 1 and 2 |
|---|---|---|
| `imports/codemirror-ember-setup.js` | 2.09 MB, not minified | about 1.0 MB: minified (upstream's minified build of the same bundle with Julia is 1.07 MB) and without the Julia, Python and SQL languages |
| `lang/` | 564 KB | 28 KB (English only) |
| components and common | 1.03 MB | about 0.7 MB after piece 1's deletions |
| fonts, img, themes, CSS | 0.3 MB | 0.2 MB plus the kept fonts |

Estimate: `inst/frontend` about 2.4-2.8 MB after this piece; installed
package about 3.3-3.7 MB with `R/`, `inst/worker.R` and the compiled code.

**CRAN.** `R CMD check` reports a NOTE when the installed package is larger
than 5 MB (`_R_CHECK_PKG_SIZES_THRESHOLD_`, default 5), listing
sub-directories over 1 MB. CRAN's policy asks for "the minimum necessary
size", and a NOTE has to be explained at submission. The working limit is
therefore 5 MB installed. Vendoring MathJax (2.2 MB) would cross it.
Minified JavaScript is not binary code, so the "no binary executables"
rule doesn't apply; `inst/COPYRIGHTS` names each library's npm package and
version so its source can be found.

### Shape

- **`frontend-setup/` is renamed `frontend-build/`** and builds three things
  (one `npm run build`):
  1. `codemirror-ember-setup.js` as today, plus `@rollup/plugin-terser`, and
     without `@plutojl/lang-julia`, `@plutojl/lezer-julia`, `lang-python`,
     `lang-sql` and `legacy-modes/toml` once piece 1 has removed their last
     importers. `merge` stays (Endeavor draws inline diffs).
  2. `rollup.vendor.config.js`: one input per library under `src/vendor/`
     (each file re-exports exactly what the shim needs), output
     `inst/frontend/imports/vendor/<name>-<hash>.js`, format `es`, minified,
     with `entryFileNames`/`chunkFileNames: "[name]-[hash].js"` so every
     file's name changes when its content does (R/server.R serves
     `imports/vendor/` with a year-long immutable `Cache-Control`) and
     shared code (Preact's core under `preact` and `preact/hooks`) is one
     file reached by import, not duplicated per entry. `build.mjs` rewrites
     each shim's `from "./vendor/..."` line to match the current hash after
     every build. Libraries:
     preact 10.29.2, htm 3.1.1, lodash-es, immer 11.1.8, dompurify 3.4.5,
     semver 7.8.0, ansi_up 6.0.6, @observablehq/stdlib 3.3.1,
     dialog-polyfill 0.5.6, iframe-resizer 4.3.11 (4.x is MIT; 5.x changed
     licence), highlight.js 11.11.1 (core plus `r` and `markdown`, not
     `julia`), requestidlecallback-polyfill 1.0.2,
     seamless-scroll-polyfill 2.1.8, and the two GitHub-only forks Pluto
     uses: fonsp/msgpack-lite 0.1.27-es.1 and JuliaPluto/js-sha256
     v0.9.0-es6, as npm git dependencies pinned to their tags.
     `rollup-plugin-license` writes
     `inst/frontend/imports/vendor/THIRD-PARTY.txt`.
  3. `scripts/copy-assets.mjs`: copies the ionicons SVGs the CSS names into
     `inst/frontend/img/icons/`, and `dialog-polyfill.css` and the two
     iframe-resizer scripts into `imports/vendor/` (piece 1 chose system
     fonts, so no font files are copied).
- **Frontend edits**: every `https://` import becomes a relative import:
  the shims in `imports/`, `common/PlutoHash.js`,
  `common/SetupCellEnvironment.js`, `common/SetupMathJax.js`,
  `common/useDialog.js`, `components/ExportBanner.js`, `imports/AnsiUp.js`,
  `imports/highlightjs.js`. Icon URLs in CSS become `./img/icons/*.svg`;
  `@import url(https://...)` font lines (editor.css:3-24) become local
  `@font-face` files; editor.html:26-29 loads iframe-resizer locally.
- **`scripts/check-imports.mjs`** (run by the build): every name the
  frontend imports from `CodemirrorPlutoSetup.js` is exported by the
  bundle, so trimming languages can't silently break an import.
- **CI**: the `codemirror-ember-setup` job becomes `frontend-build`: build
  the grammar, `npm ci && npm run build` in `frontend-build/`, then
  `git diff --exit-code inst/frontend/imports inst/frontend/img/icons`.
  `.Rbuildignore` gets `^frontend-build$`.
- **An R test that the shipped frontend has no external URLs**
  (`test-frontend-files.R`): it reads every `.js`, `.css` and `.html` under
  `system.file("frontend")` and fails on `https?://` in an `import`, `src`,
  `href` or `url()` position, except an allowlist (MathJax while it stays on
  the CDN). This runs in `R CMD check` with no Node.
- **Hashed names and cache headers.** The vendor bundles and
  `codemirror-ember-setup.js` are written as `<name>-<hash>.js` (rollup's
  `[name]-[hash].js`, hash of the content). The build then rewrites the
  `from` line of each shim in `imports/` to the new name and deletes the
  old hashed files, so a rebuild with no change leaves git clean. All hashed
  files live under `imports/vendor/`. `serve()` mounts that folder as its
  own static path with `Cache-Control: public, max-age=31536000, immutable`,
  and the rest of the frontend with `Cache-Control: no-cache` (the browser
  keeps the file and revalidates it with `If-Modified-Since`, a 304 when
  unchanged). Both are httpuv static paths
  (`staticPathOptions(headers = ...)`), served without R. Ember's own files
  are small, so a revalidation round trip per file is acceptable; the
  hashed files are the bulk of the bytes. `editor.html` is served by R and
  gets `no-cache` too.
- **Exports are self-contained**, every one (`/notebookexport`, with or
  without `offline_bundle=true`, which Endeavor sends). The export embeds
  the same files the live page loads; there is no second build.

  ```r
  #' editor.html with the launch parameters (as today), and the frontend
  #' inlined: all-styles.css with its @imports expanded and every url()
  #' to a local file turned into a data: URL; the favicon and logo links
  #' as data: URLs; the iframe-resizer scripts inline; and every .js and
  #' .json file under the frontend embedded as text in one
  #' <script type="application/json" id="ember-modules">, keyed by its path
  #' relative to the frontend ("components/Cell.js").
  #' Each module's relative import specifiers (static `from "..."`,
  #' `import "..."`, `export ... from "..."`, and `import("...")` with a
  #' literal) are rewritten to bare keys `ember/<path>`, resolved against
  #' the importing file's folder.
  #' Output deps (htmlwidgets' `deps/<name>-<version>/<file>` script and
  #' stylesheet URLs in the projected state) become data: URLs, so widgets
  #' work in the file; the export is larger by their size.
  export_html(state)
  ```

  A small classic `<script>` in the export (`inst/frontend/export-loader.js`,
  inlined) reads `#ember-modules`, makes a Blob URL per module
  (`text/javascript`, or `application/json` for `.json`), inserts
  `<script type="importmap">` mapping each `ember/<path>` to its Blob URL,
  then inserts `<script type="module">import "ember/editor.js"</script>`.
  Import maps resolve any order of imports, including cycles, and module
  scripts inlined in the page load from `file://`, which `./editor.js` can't.
  `</script` inside embedded text is escaped as `<\/script`.

  This works because nothing in the frontend computes an import path at
  run time or uses `import.meta` (checked: the one computed `import()`,
  `common/Environment.js`, loads an injected data URL that Ember never
  sets). A test (ui-2-tests.md 15) fails if either appears.

  An export of the development package is self-contained too, so
  `export_root()`, the jsdelivr root and the banner note are dropped.

- **Release builds minify Ember's own files** (decided with the user).
  The repository keeps them readable; a release script minifies each one
  in place (same names, same layout, so the live page and exports work
  the same way) before `R CMD build`, and CI runs the browser tests
  against that build as well. About 0.7 MB becomes about 0.3 MB.
  Tracked in design-gaps.md (Packaging and CI); not part of this piece.

### Tests

ui-2-tests.md 13-21.

### Risks

- npm packages differ from the CDN builds Pluto was tested with: jsdelivr's
  `+esm` and esm.sh convert CommonJS to ES modules. Pluto imports lodash's
  default export from `lodash@4.18.1/+esm`; `lodash-es` has the same
  default. Each shim gets a smoke test in the e2e "offline" scenario.
- `@observablehq/stdlib`'s `require()` still fetches from jsdelivr when a
  user's HTML output calls it. That is the user's code reaching the
  network, not the page's, and is out of scope.
- The two GitHub forks have no npm releases; git dependencies need network
  for `npm ci` in CI, as everything else does.
- Size grows back if fonts are added later; the R test can also assert
  `inst/frontend` stays under 3 MB so a growth is a deliberate change.
- The committed bundles must be byte-identical across platforms: build on
  Linux in CI only, and mark the generated files `-text` in
  `.gitattributes` so Windows checkouts don't convert line endings.

### Order within the piece

1. Rename `frontend-setup`; minify and trim the CodeMirror bundle
   (`check-imports.mjs` first).
2. Vendor libraries, one shim at a time, e2e after each.
3. Icons and fonts; then editor.html's scripts.
4. The R "no external URLs" test and the e2e offline test.
5. Hashed names, the cache headers, then self-contained `export_html()`.

---

## 3. Rich outputs

### Problem

The worker builds tables, trees and plots, but the page shows only their
text form: `project_output()` maps `application/vnd.ember.table` and
`application/vnd.ember.tree` to `text/plain` (pluto-state.R:228, 269).
Specifically:

- **Tables**: the worker sends the first 1000 rows of every column as
  character vectors, with `class(col)[1]` as the type (worker.R:1061-1069).
  That is up to 1000 × ncol strings per output in the engine state, while
  the page needs about ten rows. There is no way to ask for more.
- **Trees**: every `is.list()` value becomes a tree (worker.R:1176). That
  includes classed objects with their own print method: an `lm` fit and a
  `t.test()` result both display as trees (checked by sourcing worker.R and
  calling `display_value()`). Today the text fallback hides this; a tree
  view would show the fit's internals instead of its summary. The tree's
  value isn't kept, so it can't page either.
- **Widgets**: `display_html()` always sends `deps = list()`
  (worker.R:1148-1155). An htmlwidget arrives without its JavaScript and
  renders nothing.
- **Plots**: the engine can re-render (`ev_render` → `render` →
  `wk_rendered`, step.R:737-745, 1042-1058), but nothing in the page asks.
  Even if it did, the new image wouldn't appear: CellOutput re-renders only
  when `last_run_timestamp` changes (CellOutput.js:67-68), and a re-render
  keeps the run's timestamp. Every plot is 720×480 at 96 dpi
  (worker.R:993-1003), which is blurry on a high-density screen.
- **Colours**: `print()` of the output value has colour (worker.R:1038-1041
  sets `cli.num_colors`), but earlier printed values (worker.R:972-976) and
  everything a cell writes while it runs (cli messages, printed tibbles)
  don't. The page's ANSI check matches only simple codes like `\x1b[31m`
  (CellOutput.js:762), not `\x1b[38;5;246m`.

### What the user sees

- A data frame shows as a table: column names, types like `<dbl>` and
  `<chr>` under them, the first 10 rows, the size (`32 × 11`), and "more"
  rows and columns, as Pluto's table view does. Clicking "more" loads the
  next rows or columns from R.
- A plain list shows as a collapsed tree, `list(a = 1, b = "x", …)`, that
  expands on click, with "more" for long lists. An `lm` fit, test result or
  any other classed object prints as R prints it.
- plotly, leaflet, DT and other htmlwidgets render. Ten plotly charts load
  plotly.js once.
- Plots are sharp and fit the cell's width; making the window narrower or
  wider redraws them at the new size.
- Coloured console output (tibble, cli, testthat) keeps its colours in the
  output and in the log under it.

### Shape

**Worker display data.** `display[[cell]]` (worker.R:61) changes from the
bare value to a record, so every kind of display that needs R can be redrawn
and paged the same way:

```r
#' What a cell's output needs kept: list(value, token, limits). `value` is
#' the data frame, the list, or the recorded plot; `token` the run that made
#' it; `limits` the paging state, path -> list(rows, cols, items).
#' Dropped when the cell reruns or is deleted (worker.R:428), as now.
display[[cell]]
```

`render_plot()` (worker.R:1189) reads `display[[cell]]$value`.

**3a. Which lists are trees.** `display_value()` (worker.R:1163) uses the
tree only for a list whose class is exactly `"list"` (no class attribute);
every other list-based object falls through to `print()` text. This
changes what is shown for classed objects, matching design.md's order
(Ember's own views are for data frames, plots and plain lists; everything
else prints).

**3b. Table.**

```r
#' A data frame, tibble or data.table, the first `limits$rows` rows and
#' `limits$cols` columns formatted as print() would (format() of the shown
#' rows only, per column, each in tryCatch so one odd column can't fail the
#' whole table).
display_table(value, cell, token, limits = list(rows = 10L, cols = 8L))
# -> list(kind = "table", mime = "application/vnd.ember.table",
#         names = <chr, shown columns>, types = <chr, e.g. "<dbl>">,
#         nrow = <int>, ncol = <int>,
#         row_labels = <chr, shown rows: row names, or "1", "2", …>,
#         rows = <list of chr, one per shown row>,
#         more_rows = <int>, more_cols = <int>,
#         text, truncated)
```

Types use `pillar::type_sum()` when pillar is loaded (tibble users have it),
else a fixed table (`numeric` → `<dbl>`, `integer` → `<int>`, `character` →
`<chr>`, `logical` → `<lgl>`, `factor` → `<fct>`, `Date` → `<date>`,
`POSIXct` → `<dttm>`, `list` → `<list>`, anything else `<cls>`).

Projection, pure, in pluto-state.R:

```r
#' Ember's table display as Pluto's table body (TreeView.js:203-262):
#' list(objectid = "", ember_dims = "<nrow> × <ncol>",
#'      schema = list(names = arr(names, "more"?), types = arr(types, "more"?)),
#'      rows = list(arr(label, arr(arr(text, "text/plain"), …, "more"?)), …, "more"?))
#' "more" after the names and in each row when more_cols > 0; a final "more"
#' row when more_rows > 0. `objectid` "" is the table itself.
project_table(data)
```

`TableView` gets one change: when `body.ember_dims` is set, it shows that
text in the empty top-left header cell (TreeView.js:227 renders `""`
there today).

**3c. Tree.**

```r
#' A plain list, to `max_depth` levels; at each level the first
#' `limits[[path]]$items` (default 20) elements.
display_tree(value, cell, token, limits = list())
# node: list(type = "list", path = "2/1", length = <int>, named = <lgl>,
#            items = list(list(key = <chr>, value = <node | leaf>)), more = <int>)
# leaf: list(type = "text", text = <one line: format() for length 1,
#            the first line of str() otherwise>)
```

```r
#' Pluto's tree body (TreeView.js:105-180):
#' list(objectid = path, type = "r_list", prefix = "list", prefix_short = "",
#'      elements = list(arr(key, arr(<body>, <mime>)), …, "more"?))
#' A leaf is arr(text, "text/plain"); a node is
#' arr(project_tree(node), "application/vnd.pluto.tree+object").
project_tree(data)
```

`TreeView` gets a `case "r_list":` that renders like `"NamedTuple"` but
omits the key for unnamed items. treeview.css gets `pluto-tree.r_list`
rules: `list(` before, `)` after, `name = value` for named items.

**Paging ("more")**, for tables and trees. Pluto's frontend already sends
`reshow_cell {cell_id, objectid, dim}` without awaiting a reply
(Editor.js:715-725, TreeView.js:99-103); the server logs and ignores it
today (server.R:578).

- server.R: `reshow_cell` gets a handler: resolve the cell, then
  `dispatch(nb, ev_show_more(cell, path = objectid, dim, at))`. `dim` is 1
  (rows or items) or 2 (columns).
- step.R: `reduce_show_more(state, event)`: if the cell's output is a table
  or tree and the worker is `ready` or `busy`,
  `fx_send(gen, list(type = "more", cell, path, dim))`. Otherwise nothing.
- worker.R: `more` message → `show_more(msg)`: grow `limits[[path]]` (rows
  +60, columns +30, items +60, Pluto's steps), rebuild the display from
  `display[[cell]]$value`, send `rendered`.
- `rendered` now carries `token`; the shell's `as_display()`
  (shell.R:723-734) copies it into the display as `display$token`.
  `wk_done` sets `output$token` from the run's token the same way.
- `reduce_wk_rendered()` (step.R:1042) accepts any mime, not only
  `image/png`, when `identical(event$display$token, r$output$token)` (so a
  reply for an older run of the cell is dropped), and stamps
  `out$rendered_at <- event$at`.
- `project_output()`: `last_run_timestamp` becomes
  `max(last_run, rendered_at)`. This is what makes the page redraw a paged
  table or a resized plot (CellOutput.js:67-68), and it is how Pluto
  behaves: its `reshow_cell` stores a new output with a new timestamp.

**3d. Widget files.**

Worker:

```r
#' htmlwidgets / htmltools HTML and its dependencies, resolved
#' (htmltools::resolveDependencies keeps the newest of each name).
display_html(value)
# -> list(kind = "html", mime = "text/html", html, deps = list(dep, …), text, truncated)
# dep: list(name, version,
#           dir = <absolute folder: system.file(src$file, package = package),
#                  or src$file when package is NULL; NULL when only href>,
#           href = <src$href or NULL>,
#           script = <chr, relative paths>, stylesheet = <chr>, head = <chr or NULL>)
```

Server (server.R), not the projection, because it touches httpuv:

```r
#' Serve a dependency folder at /deps/<name>-<version>/ when it lies inside
#' the notebook's library. Idempotent: a key already registered is left as
#' it is (same name and version, same files, by htmlwidgets' convention).
#' The check is on the path as given, not its symlink target: renv links
#' library entries into its shared cache, so the resolved path lies outside
#' the library by design. The path must be absolute, contain no "..", and
#' start with the active library path (state$packages$active$path) plus "/".
#' With server$http NULL (tests) it only records.
register_deps(server, hub, deps)

#' Remove the static paths only this notebook used (drop_hub()).
unregister_deps(server, hub)
```

`register_deps()` runs in `on_note()` (server.R:327) for `cell_state` notes,
on the changed cells' outputs, before the flush is scheduled, so the
files are served before the page sees the HTML. `host_notebook()` runs it
over existing outputs. `server$deps` is an environment of `key ->
list(dir, notebooks)`. httpuv's `server$http$setStaticPath()` and
`removeStaticPath()` serve the folder on httpuv's own thread, without R
(design.md, Performance).

Projection: `project_output()` for `text/html` with `deps` prepends, per
dependency in order: `<link rel="stylesheet" href="/deps/<key>/<file>">`,
`<script src="/deps/<key>/<file>"></script>`, and `head`. Dependencies with
only `href` use that URL. If any dependency is named `htmlwidgets`, it
appends `<script>window.HTMLWidgets && HTMLWidgets.staticRender()</script>`.
Pluto's script runner already copies each `<script src>` into the page head
once, awaits it, and runs inline scripts after (CellOutput.js:379-414), so
"load plotly.js once" needs no page change. htmlwidgets binds only on
`DOMContentLoaded` by itself, hence the explicit `staticRender()`; it skips
widgets it has already rendered.

**3e. Plot re-render on resize.**

- Page: `components/EmberPlot.js`, used by `OutputBody` for `image/png`
  when it has a `cell_id`. It wraps `PlutoImage` and watches its
  container's width with a `ResizeObserver`, debounced 300 ms. It asks for
  a render when the wanted pixel width (`round(width * devicePixelRatio)`)
  differs from the image's `naturalWidth` by more than 10%, and only (a)
  after the container's width changed or (b) when a new run's image
  arrived. It never asks because another tab's re-render changed the
  image: two tabs of different widths would otherwise take turns forever.
  It asks only while `document.visibilityState === "visible"`. The height
  keeps the current image's aspect ratio.
- Request: `ember_render_plot {cell_id, width, height, res}`, `res = 96 *
  devicePixelRatio`. The server clamps width and height to 100-4000 and res
  to 72-384, then calls `dispatch(nb, ev_render(id, width, height, res,
  at))`. `ev_render` (step.R:46) gains `res = 96`, and `render_png()`
  (api.R:331) passes it.
- Worker: `render_plot()` uses `msg$res`; the plot display carries `size =
  list(width, height, res)`. This closes design-gaps' "plot size isn't
  reported back".
- The image's CSS width is its container's width (`max-width: 100%`), so a
  2× image shows sharp at the same layout size.

**3f. Terminal colours.**

- Worker: at boot, before `settings_start` is taken (worker.R:93), set
  `options(cli.num_colors = 256L, crayon.enabled = TRUE, crayon.colors =
  256L)`. Because they are in the baseline, the global-settings check
  doesn't see them as a cell's change, a setup cell can still change them,
  and a setup rerun resets to them. Code that reads
  `getOption("cli.num_colors")` sees 256, as it would in a colour terminal
  under `Rscript`.
- `text_form()` (worker.R:1038) no longer needs its own `options()` call.
  When it truncates, it drops a trailing partial escape sequence
  (`\x1b\[[0-9;]*$`) and appends `\x1b[0m`.
- Page: CellOutput.js:762 uses `/\x1b\[[0-9;]*m/`.
- API: `notebook_snapshot()` strips ANSI codes from each output's `text`
  and console item. A program reading text (Endeavor's agent) then sees
  `tibble [32 × 11]`, not escape codes. The engine state keeps the coloured
  text for the page.

### Tests

ui-2-tests.md 22-44.

### Risks

- A data frame with an odd column class whose `format()` errors or is slow:
  each column is formatted separately in `tryCatch`, and only shown rows
  are formatted. A data.table with 10^8 rows: `head()` is cheap; `nrow()` is
  stored.
- `register_deps()` trusts the folder named by the worker if it is inside
  the library. A notebook can make a dependency pointing anywhere inside
  its own library, which is not private. Anything outside is refused and
  logged; that widget then renders without its files.
- Two notebooks with different libraries and the same dependency name and
  version share one static path, the first one registered.
- The table display's `data` changes shape, and it appears in
  `notebook_snapshot()`. The API promises callers the MIME type and the
  `text/plain` form (design.md, Integration with Endeavor), not this
  structure; the change goes in the release notes anyway.
- Widgets in exports: their `deps/...` files are inlined as data: URLs
  (piece 2, Exports), so an export with a DT table is larger by DT's files.
- Raising `last_run_timestamp` on a re-render re-runs inline scripts in that
  output. Plot, table and tree outputs have none.
- The colour options are visible to user code (above).
- A page asking for many re-renders while a long cell runs: the worker
  reads `render` only between runs (worker.R header), so requests queue.
  The debounce and the "width changed" rule keep it to one per plot per
  resize.

### Order within the piece

1. 3a (which lists are trees), alone: it is a fix.
2. Worker display record and token; generalised `wk_rendered`;
   `rendered_at` in the projection.
3. 3b table with paging, 3c tree with paging.
4. 3f colours (small, independent).
5. 3e plots (needs step 2).
6. 3d widgets last: it touches httpuv and needs a package with JavaScript in
   the notebook's library for its e2e test.

---

## 4. Editor services

### Problem

The page asks for completions on every pause in typing and for help when the
cursor moves, but nothing answers. The server replies to `complete` with
an empty list (server.R:544-547), `docs` with "not_found" (server.R:553),
and the help tab is hidden (BottomRightPanel.js:119, 179). design-gaps.md
says the request kinds exist in the worker and reply "unsupported". They
don't: the worker's message switch has no editor messages
(worker.R:143-152), and its "Editor services (later)" note (worker.R:1232)
describes a reply nothing sends.

Two related gaps:

- The page's own "notebook definitions" completion and go-to-definition
  anchors use `Object.keys(downstream_cells_map)` (Notebook.js:170-180,
  Cell.js:132). The projection puts a name there only if another cell reads
  it (pluto-state.R:372-403), so a definition nobody reads yet is missing.
  Pluto lists every definition, with an empty list when unread.
- Go-to-definition, the in-cell local-variable completion and the help
  query from the cursor all read `ScopeStateField`, Julia's scope analysis,
  which finds nothing on an R tree (docs/ui-frontend.md, "Deviation").

### What the user sees

- Typing `fil` offers `filter`, `file.path`, `fill`, …; `df$` offers the
  columns of `df`; `library(` offers installed packages; `dplyr::` offers
  dplyr's exports. Names defined in the notebook come first.
- While a cell runs or before R has started, completion still works for the
  notebook's own names, the exports of its packages, and base R; `$`
  columns need R and don't appear then.
- The help panel ("Help" tab, bottom right) shows the R help page for the
  function under the cursor, links inside it open other pages in the panel,
  and examples are highlighted as R. For a function defined in the notebook,
  it shows that definition.
- Inside a call, a hint above the line shows the function's arguments:
  `lm(formula, data, subset, weights, na.action, method = "qr", …)`.
- Ctrl/Cmd-click on a name defined in another cell jumps to that cell.

### Shape

**4a. Queries to the worker, outside the engine.** Completion, help and
signatures don't change the notebook, so they don't go through `step()` or
the event log; the shell sends them and calls back.

```r
#' Ask the worker a question if it is idle, else answer NULL at once.
#' "Idle": allowed, status "ready", nothing running or pending, socket open.
#' `callback(reply)` runs once: with the worker's reply, or with NULL after
#' `timeout` seconds, or when the worker exits. Replies that arrive late are
#' dropped.
worker_query(nb, msg, callback, timeout = 0.8)
```

`nb$queries` (environment: id → callback) lives on the shell's `nb`
handle, not in `ember_state`. In `poll()` (shell.R:544-566), a message of
type `completions`, `help_page` or `signature` goes to `answer_query()`
before `worker_event()`; the worker-exit path calls every pending callback
with NULL. `worker_event()`'s table (shell.R:685-697) needs no change
because these never reach it.

Worker messages (worker.R header and `handle_next()`):

```
Server -> worker
  complete   id, line, cursor     line: the current line up to the cursor
  help       id, topic, package   package NULL: search attached, then all installed
  signature  id, name, package
Worker -> server
  completions  id, token, items = list(name, kind, notebook), too_long
  help_page    id, found, topic, package, html, matches (packages, when several)
  signature    id, text            NULL if not a function
```

The worker reads these only between runs, as it reads `render`. A question
that arrives while a cell runs waits; the server times out and answers from
its fallback.

**4b. Completion.**

Worker, as IRkernel does:

```r
#' utils' own completion on one line. rc.settings(ipck = TRUE) is set at
#' boot, so library( completes installed package names.
complete_line(line, cursor)
# utils:::.assignLinebuffer(line); utils:::.assignEnd(cursor)
# token <- utils:::.guessTokenFromLine(); utils:::.completeToken()
# items <- utils:::.retrieveCompletions()   (first 500; too_long if more)
# kind: "argument" (ends in " = "), "function", "package", "path", "other";
# notebook = TRUE when the name is bound in globalenv(). Values are looked
# up with get0() only when the binding is not active (bindingIsActive()).
```

Server, pure, new file `R/editor-services.R`:

```r
#' What is being completed: the line and cursor (from the page's
#' `query_full`, the cell's text up to the cursor), the token and its UTF-8
#' byte start in `query_full`, and `namespace` for "pkg::" or "pkg:::".
completion_context(query_full)

#' Completion without the worker: the notebook's definitions (graph cells'
#' `definitions`), the exports of packages any cell attaches
#' (`exports_of(state)`), and base R names; for "pkg::", that package's
#' exports. Prefix match, notebook first, at most 500.
fallback_completions(state, ctx, base = base_names())

#' Base R names, once per server process: ls(baseenv()), the exports of
#' stats, utils, graphics, grDevices and methods, the datasets, R's
#' reserved words.
base_names()

#' Pluto's reply: list(start, stop, results, too_long), each result
#' arr(text, value_type, is_exported = TRUE, is_from_notebook,
#'     completion_type, NULL), value_type "Function" or "Any",
#' completion_type "keyword_argument" for arguments, "path" for files,
#' "" otherwise. `start`/`stop` are UTF-8 byte offsets into query_full,
#' as the page expects (CellInput.js:706-707).
completion_reply(ctx, items)
```

server.R `complete` handler: `pkg::` is always answered by the fallback,
from the exports the engine already has. utils' own `pkg::` completion
loads the namespace into the worker, and typing should not load packages.
Everything else: `worker_query(complete)`, and on NULL the fallback. The
reply is sent from the callback; `send()` already handles a client that
has gone (server.R:357-364).

Projection: `project_dependencies()` adds every public definition of a cell
to its `downstream_cells_map`, with an empty array when no cell reads it,
as Pluto does. That fills the page's notebook-name completion
(`global_variables_completion`) and the per-cell anchors that
go-to-definition scrolls to.

Page, `CellInput/pluto_autocomplete.js` rewritten for R:

- keep: `global_variables_completion` (notebook names from
  `GlobalDefinitionsFacet`), the server completion source (renamed
  `r_completions_to_cm`), the memoised request, the keymaps;
- delete: LaTeX and emoji symbols, superscripts, Julia keywords (replaced by
  R's reserved words), `complete_package_name` (Julia `using`),
  `local_variables_completion` (Julia scope), the `request_*` parameters
  for those;
- R identifier rules: `[\p{L}\p{N}._]` for the token and `validFor`;
  `writing_variable_name_or_keyword()` reads the R tree (left side of an
  `AssignExpr`, a `ParamName`, an `ArgName`); field access is `$` and `@`,
  not `.`.

**4c. Help panel.**

- BottomRightPanel.js: the tab is shown, labelled "Help"; the gate is
  deleted.
- `CellInput/LiveDocsFromCursor.js` rewritten for the R grammar:
  `get_selected_doc_from_state(state)` returns, for the cursor, the callee
  of the innermost `Call` whose `ArgList` contains it (`Identifier`, or
  `NamespaceExpr` as `pkg::name`), else the `Identifier` under it, else the
  operand of a `HelpExpr` (`?lm`); nothing inside strings, comments or
  numbers.
- server.R `docs` handler, query `name` or `pkg::name`:
  1. a name defined in the notebook (and no `pkg::`): `{status: "👍", doc:
     <defining cell's code in <pre><code class="language-r">, headed
     "Defined in this notebook">}` from `state` alone;
  2. worker idle: `worker_query(help)`; worker side: `utils::help()` by
     `do.call()`, `utils:::.getHelpFile()`, `tools::Rd2HTML(rd, out,
     package, dynamic = TRUE)`, body only. Several matches: a list of
     `pkg::topic` links;
  3. otherwise: `{status: "👍", doc: "<p>Help pages need R running. Run a
     cell to start it.</p>"}`, or "R is busy running a cell…".
- `rewrite_help_links(html)` (pure): Rd2HTML's `../../pkg/help/topic`
  links become `@ref pkg::topic`, which LiveDocsTab already turns into a
  new query (LiveDocsTab.js:126-135).
- LiveDocsTab.js: highlight `code` blocks as `r`, not `julia`
  (LiveDocsTab.js:122); delete `without_workspace_stuff` (Julia module
  names). A small `--helpbox-*`-based stylesheet for Rd2HTML's tables and
  headings; Endeavor already themes the `--helpbox-*` variables.

**4d. Signatures.**

- Page: new `CellInput/signature_hint.js`, a CodeMirror plugin. When the
  cursor is inside a `Call`'s `ArgList`, it sends `ember_signature {name,
  package}` (debounced 150 ms, cached per name) and shows the answer with
  `showTooltip` above the call.
- Server: `ember_signature` handler; worker idle → `worker_query(signature)`
  (worker: `args(fn)` deparsed, the trailing `NULL` dropped); otherwise
  `signature_fallback(name, package)`: `formals()` of the function in the
  server's own base, stats, utils, graphics, grDevices or methods
  namespaces (same R version as the worker). No fallback for notebook or
  package functions: that would need R to load them.

**4e. Go-to-definition and variable marks, from the engine's analysis.**
This is cheap: every analysis row already has `line`, `col` and `end_col`
"for the editor's go-to-definition" (positions.R:7-10).

- Projection: `cell_inputs[id].ember_spans = {defs: [[name, from, to]],
  refs: [[name, from, to]]}` from `graph$analyses[[id]]`, rows of the
  cell's own code only (`file` NA), rows with `col` NA left out.
  `span_offsets(code, line, col, end_col)` (pure) turns parse-data columns
  into UTF-16 offsets: `getParseData()` counts characters with tabs
  expanded to multiples of 8 (in `"é <- 1; \tb"`, `b` is column 17), and
  CodeMirror counts UTF-16 code units. The spans change exactly when the
  code does, which the cell key already covers.
- Page: `go_to_definition_plugin.js` reads an `EmberSpansFacet` instead of
  `ScopeStateField`: a ref whose name another cell defines
  (`GlobalDefinitionsFacet`) becomes the existing `data-pluto-variable`
  link; a ref to a definition in the same cell becomes the existing
  `data-cell-variable` link. Marks show only while the editor text equals
  the code the analysis read (the cell's remote code); while the user
  types, they disappear until the cell is submitted. CellInput.js:855-857
  (jump target after scrolling) selects the target cell's def span.
- Then `scopestate_statefield.js` and `lezer_template.js` (if nothing else
  imports it) are deleted, with every `ScopeStateField` use.

This part can be cut without affecting 4a-4d; it is listed last for that
reason.

### Tests

ui-2-tests.md 45-63.

### Risks

- `utils:::.completeToken` and friends are internal and can change in any R
  release (design.md, Editor services). The worker tests call them on each
  R version CI runs; a change shows as a test failure, not a wrong answer.
  Help uses `utils:::.getHelpFile` likewise. Both are in `inst/worker.R`,
  which `R CMD check` doesn't inspect for `:::`.
- Completing `x$` evaluates nothing new but reads `x`; an object whose
  `names()` method or active binding runs code runs it during completion.
- The fallback has no columns and no locals; quality drops while a cell
  runs.
- Spans are for submitted code only; a user typing in a cell sees no links
  until it is run (or the code is otherwise sent).
- Removing `ScopeStateField` touches four modules at once; it goes last,
  behind passing e2e for completion, help and links.

### Order within the piece

1. `downstream_cells_map` with every definition (projection; also fixes
   today's notebook-name completion).
2. Shell `worker_query` and the three worker messages, with worker unit
   tests.
3. Completion (server fallback first, then worker), then the page rewrite.
4. Help panel.
5. Signatures.
6. Go-to-definition and removal of `ScopeStateField`.

---

## 5. Status views

### Problem

Increment 1 maps Ember's status onto Pluto's Julia-shaped fields
(docs/ui.md strain 7): packages go into `nbpkg` and `status_tree`
(pluto-state.R:446-520); "stale", "an ancestor failed" and "code changed
outside the page" all become one dimmed state, `depends_on_disabled_cells`
(pluto-state.R:203-204). That flag also suppresses the "waiting to run"
mark while a stale cell is queued (Cell.js:230). design.md asks for a
package status view, "N cells not run" with "Run all", a labelled stale
state, and the worker's memory next to its status. None of these exist.

### What the user sees

- Header, next to the process status: `R · 412 MB`, with a tooltip: "Memory
  used by R. R rarely gives freed memory back to the system; restart R to
  free it (cells will need to run again)." and a restart button. In safe
  preview: nothing.
- A bar above the first cell when R is running and some code cells have
  not run since it started: "5 cells not run · Run all".
- A stale cell keeps its output, dimmed, with a small "stale" label; a cell
  whose code changed since its last run (edited from R or by Endeavor)
  shows "code changed"; a cell blocked by a failed ancestor stays dimmed as
  today, labelled "upstream error" (replaced in increment 3, piece 1).
- A "Packages" tab beside "Help" and "Status": the snapshot date and R
  version, the library's state and install progress, and one row per
  package (name, version, source, status, message), with what running will
  install or restart.
- The safe preview banner says what running will do: "Running starts R and
  installs 3 packages."

### Shape

**Projection.** A top-level `ember` map, built from `view_context()` and
`packages_view()`, each part through `reuse()` so an unchanged part
produces no patch:

```r
#' list(process = "preview"|"starting"|"ready"|"busy"|"stopped",
#'      worker_memory = <double, bytes> | NULL,
#'      not_run = <int>, stale = <int>,
#'      plan = list(install = <int>, restart = arr(<chr>)) | NULL,
#'      packages = list(snapshot, r_version, bioc_version,
#'                      library = list(status, message,
#'                                     progress = list(done, total, current) | NULL),
#'                      rows = list(list(name, version | NULL, source | NULL,
#'                                       direct, status, message | NULL))))
#' not_run: code cells with non-blank code, no result, not queued or
#' running, while R is running (0 in preview).
project_ember(state, ctx)
```

Per cell, `cell_results[id].ember = list(stale, code_changed, blocked_by =
<id> | NULL)`, from the view (`stale`, `code_differs`, `blocked_by`), all
already in the cell key. `depends_on_disabled_cells` becomes `blocked_by`
only. Pluto's `nbpkg`, `status_tree` and `process_status` are still filled
for Endeavor. (`blocked_by` and this `depends_on_disabled_cells` rule are
replaced in increment 3, piece 1.)

**Worker memory.**

- Shell: in `poll()`, every 2 s while a worker process is alive,
  `nb$proc$get_memory_info()` (processx, through ps, already a dependency
  of processx). RSS is what the operating system charges to R, which is
  the number design.md means ("a long session can look large"). It
  dispatches `ev_worker_usage(gen, rss, at)` only when RSS moved by 16 MB
  or 5% since the last report.
- Engine: `reduce_worker_usage()` stores `state$worker_usage <- list(gen,
  rss)`, top-level rather than in `state$worker`. `notifications()`
  compares `state$worker` with `identical()` to decide whether to rebuild
  every cell's snapshot (state.R:465-471); a memory change every few
  seconds must not trigger that at 2000 cells. `notifications()` gains a
  `worker_usage` kind; the server flushes on any note (server.R:327-347).
  The projection ignores a usage whose `gen` isn't the current worker's.
- API: `notebook_snapshot()` gains `worker_memory`.

**"Run all".** New request `ember_run_all` → `run_cells(hub$nb, ids)`
with `ids` the code cells whose status is "not_run" (the same set the bar
counts), then flush. The scheduler adds whatever they depend on and what
depends on them; cells already up to date keep their results (Decisions). In safe preview the
bar isn't shown; the banner's own button already runs all
(server.R:520-525).

**Page.**

- `components/EmberStatus.js` in the header beside `#process_status`
  (Editor.js:1725-1745).
- `components/NotRunBar.js`, rendered above `<${Notebook}>`.
- Cell.js: classes `stale`, `code_changed`, `upstream_error` on
  `pluto-cell` from `cell_result.ember`, and a `<ember-cell-label>` element
  with the text. CSS dims the output for `.stale` as editor.css:1712-1719
  does for disabled cells. Pluto's `.code_differs` (the page's own
  unsubmitted edit, which Endeavor reads) is unchanged.
- `components/PackagesTab.js`, a third tab in BottomRightPanel.js.
  `BigPkgTerminal` (Editor.js:1799) and `PkgTerminalView.js` are deleted
  once the tab shows install progress.
- SafePreviewUI.js reads `ember.plan` for the banner text.

### Tests

ui-2-tests.md 64-75.

### Risks

- Counting rules (setup cell, blank cells, markdown) must match what "Run
  all" will run, or the bar never goes away. The test runs all and expects
  0.
- `get_memory_info()` on Windows and in sandboxed CI: if it errors, memory
  is left out (NULL), never an error.
- Endeavor's page script reads `nbpkg.terminal_outputs.nbpkg_sync` for
  install failures (endeavor/frontend/src/drawer.ts:218, 244); it keeps
  being filled.

### Order within the piece

1. Projection `ember` and per-cell fields, with unit tests.
2. Stale and code-changed labels; `depends_on_disabled_cells` narrowed.
3. "N cells not run" and `ember_run_all`.
4. Worker memory (engine event, shell sampling, header).
5. Packages tab and the preview banner text; then delete `BigPkgTerminal`.

---

## Order of implementation

**1 → 3 → 5 → 4 → 2.** Piece 2 comes last (see its section).

- **1 first**: everything after it edits the same frontend files. Deleting
  first means piece 2 doesn't vendor Julia-only libraries (vmsg,
  rebel-tag-input, Firebase) and piece 4 doesn't rewrite code that is about
  to go. It also stops the page contacting Pluto's servers.
- **3 third**: most user value per line of code. 3a fixes classed objects
  before a tree view could show them wrong. It also adds the missing plot
  e2e test (ui-tests.md 42).
- **5 before 4**: small and mostly projection. It replaces the
  Julia-shaped stand-ins while they are fresh in mind.
- **4 last**: the largest: a new worker protocol, internal utils
  functions, and a rewrite of the page's completion and scope code. Its
  last step (go-to-definition) can slip to a later increment without
  holding up the rest.

3 and 5 touch different files except `pluto-state.R` and `Cell.js`, so they
can run in parallel if needed.

## Decisions and open questions

Decided with the user:

- **Languages:** English only. The 20 translations and the language
  picker are deleted in piece 1.
- **MathJax:** loaded from the CDN, only when a page has TeX. Offline TeX
  doesn't render.
- **"Run all" in the not-run bar:** runs only the cells not yet run (and
  what depends on them), not every cell. This replaces design.md's
  `run_cells(nb, NULL)` for this button.
- **Fonts:** working offline is not a hard requirement. Fonts may load from
  the network, as long as the page still works offline, falling back to
  system fonts. Piece 1 uses system font stacks for UI and prose, and the
  system monospace stack for code. A web code font can be added later with
  a system fallback.

Still open (placeholders until the user decides):

1. **Logo.** Decided: the flame-and-specks mark with Instrument Sans (see
   piece 1, Logo).
2. **Palette.** Piece 1 keeps Pluto's colour values under the same variable
   names until a palette is chosen.
3. **Downloaded exports.** Decided: self-contained, offline, one file (piece
   2, Exports), including widgets' files.
4. **Markdown fold state in existing files.** New markdown cells start
   folded. A markdown cell in a file without a `folded` mark opens
   unfolded, since fold state is the file's. Folding those by default
   would need an "unfolded" mark in the file format.
5. **Signature hint.** A tooltip above the call while typing its arguments
   (proposed), or signatures only in the help panel?
6. **Table and tree sizes.** Proposed: 10 rows and 8 columns at first, +60
   rows / +30 columns per "more"; trees 4 levels deep, 20 items at first,
   +60 per "more" (Pluto's numbers).

## Still deferred after this increment

Bonds and interactive inputs (build step 5); creating markdown cells from
the page (the Julia Ctrl+M toggle is deleted in piece 1 and not replaced);
read-only mode in the page for files from a newer Ember; a frontend-sent
acknowledgement counter to close the edit race (docs/ui.md); LaTeX output
(`text/latex` is still shown as text, pluto-state.R:228); per-package
update and pin in the Packages tab (packages.md increments 2 and 3).

## Where the code and the docs disagree

Found while writing this; none is changed by this document.

1. **Editor services** (design-gaps.md, Worker): "the request kinds exist and
   reply 'unsupported'". The worker has no such kinds (worker.R:143-152);
   only the server answers `complete` (empty) and `docs` (not found),
   server.R:544-553. A worker reply type the shell doesn't know would kill
   the worker (shell.R:685-697).
2. **Widget files** (design.md, Widget files: "The worker sends them with
   the widget's HTML"): the worker sends `deps = list()` always
   (worker.R:1154).
3. **Trees** (design.md, How values display, step 4: "lists and nested
   structures as an expandable tree"): the worker applies this to every
   `is.list()` value (worker.R:1176), so `lm` and `htest` objects are trees,
   not their print text.
4. **Exports** (docs/ui.md, Tradeoffs accepted; server.R:860-864): "exports
   load Pluto v1.0.3 from jsdelivr (code highlighted as Julia)".
   `export_html()` never sets a root (server.R:866-882), so the template's
   relative `./` stays: served exports load Ember's frontend and highlight
   as R, and a downloaded export can't load at all.
5. **Hidden menu items** (docs/ui.md, Tradeoffs: "Hiding their menu items is
   part of increment 1"): "Hide logs" is still offered (CellInput.js:1065-1073)
   and refused by the server (pluto-edits.R:86-88).
6. **Calling home** (docs/ui-frontend.md, "Calling home"; design.md lists the
   AI features under Remove): `check_access()` (Editor.js:927, 1917-1931),
   `FixWithAIButton` (ErrorMessage.js:268) and "Ask AI"
   (CellInput.js:1093-1101) are still live.
7. **Notebook definitions** sent to the page: only names some cell reads
   (pluto-state.R:372-403), where Pluto sends every definition. This affects
   completion and go-to-definition anchors (Notebook.js:170-180,
   Cell.js:132).
8. **Increment 1 tests**: ui-tests.md lists a plot scenario (42) and a
   two-tab scenario (44); `tests/e2e/tests/` has neither. Pieces 3 and 5
   add them.
