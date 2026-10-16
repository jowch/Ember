# Frontend changes for increment 1

_A historical record of increment 1's plan: `frontend-setup/` below was
later renamed `frontend-build/`, and increment 2 (docs/ui-2.md, "Offline
bundle") replaced every CDN module this describes with a vendored,
content-hashed bundle built by it -- the frontend has no CDN dependency any
more. Current build instructions live in docs/ui-2.md and
`frontend-build/README.md`._

Vendor `spikes/server-worker/pluto/frontend` (Pluto v1.0.3, commit 3a7651f)
into `inst/frontend/` as one commit with no changes, so every later change
shows as a diff against upstream. Then make only these changes. Julia-only
features are switched off where they are wired in, not deleted (deleting is
increment 2). One module, `common/EmberFlags.js`, exports `EMBER = true`, and
each switched-off spot reads `if (!EMBER)`, so increment 2 can find every
spot with one grep.

## R grammar (the one change that needs a build step)

- **`imports/CodemirrorPlutoSetup.js`**: point it at a vendored
  `imports/codemirror-ember-setup.js` instead of
  `codemirror-pluto-setup@2002.0.8` on jsdelivr. Why a rebuild and not a
  second `<script>`: the Pluto bundle exports `tags`, `NodeProp` and
  `syntaxTree`, but not `LRParser`, `LRLanguage`, `LanguageSupport` or
  `styleTags` (checked against the bundle's export list). Loading
  `grammar/dist/index.js` on its own would bring a second copy of
  `@lezer/highlight` and `@lezer/common`. CodeMirror matches highlight tags
  and node props by object identity (NodeProp ids come from a counter in
  each copy), so a second copy gives no highlighting at best and wrong node
  props at worst. The rebuild is codemirror-pluto-setup's own rollup config
  plus one export, `r()`: an `LRLanguage.define({ parser: rParser, languageData:
  { commentTokens: { line: "#" }, closeBrackets: ... } })` with fold and
  indent props, wrapped in `LanguageSupport`. It lives in
  `frontend-setup/` (package.json, rollup config, `src/index.js`), depends on
  `grammar/` by path, and its output file is committed. A CI job copies the
  existing `grammar` job: `npm ci && npm run build && git diff
  --exit-code inst/frontend/imports/codemirror-ember-setup.js`.
- **`components/CellInput.js`** lines 48, 107, 690: `julia()` -> `r()`.
  Force the mixed parser off (line 677: `julia_mixed` embeds Julia in
  Markdown strings); the setting stays in the menu but does nothing.
- **`components/CellOutput.js`** line 668: highlight code blocks in outputs
  as R when `language === "r"`, not Julia.

## Julia-only features switched off

- **`components/CellInput.js`**: `pkgBubblePlugin` and
  `NotebookpackagesFacet` (bubbles on `using` lines), the "unsubmitted
  global definitions" listener, `AiSuggestionPlugin`, and `pluto_autocomplete`'s
  `request_packages`/`request_special_symbols` (Julia package names and
  LaTeX symbols). Keep `pluto_autocomplete` itself: it asks `complete`, the
  server answers with no results, and increment 2 fills that in from the
  worker.
  `go_to_definition_plugin` is back on, reading the engine's analysis
  instead of Julia's: `ScopeStateField` and `scopestate_statefield.js` are
  gone. See "Go-to-definition" below.
- **`components/CellInput.js` cell menu** (and `Cell.js`'s handlers): hide
  "Disable in notebook" and "Skip as script". Ember has neither; the server
  would answer 👎 and revert them.
- **`components/Editor.js`**: don't render `ProjectTomlEditor`,
  `PlutoLandUpload`, `RecordingUI`, `FrontMatterInput`, `SlideControls`, the
  Binder and "run locally" launch buttons. Don't call `init_feedback`.
- **Calling home**: `count_stat()` (Editor.js 1056 and 1509, Binder.js 96)
  fetches `stats.plutojl.org` every 15 minutes with the screen size. Make it
  a no-op. Also skip `new_update_message` (asks GitHub for Pluto
  releases).
- **`components/LiveDocsTab.js`**: hide the tab. The server answers `docs`
  with "not_found"; help comes from the worker in increment 2.
  **Deviation**: the tab button and the tab's content live in
  `components/BottomRightPanel.js`, not in `LiveDocsTab.js` itself
  (`LiveDocsTab.js` only renders what's already open). Both are gated there
  with `!EMBER` instead: the "Live docs" tab button is not rendered, and the
  docs panel content is never shown even if `open_tab` were somehow "docs".
  `LiveDocsTab.js` is unchanged.

## R display

- **`components/ErrorMessage.js`**: the "Multiple definitions" and "Cyclic
  references" rewriters show every line after the first as Julia's "combine
  into a begin ... end block" hint. Show those lines as given instead: the
  server puts the engine's suggested fixes there.
- Nothing else changes for outputs: the server maps every `ember_display` to
  a MIME type Pluto already renders (see `project_output()`), and console
  output arrives as Pluto log entries.

## Go-to-definition

Pluto's links from a name to the cell defining it, driven by the engine's
analysis rather than a scope analysis in the page (ui-2.md 4e, #53).

- **Server** (`pluto-state.R`): each cell input carries `ember_spans`,
  `{defs, refs}`, each a list of `[name, from, to]`. They are the cell's
  own definition and reference rows, at UTF-16 offsets into its code
  (`span_offsets()` converts parse-data columns, which count a tab to the
  next multiple of 8). A reference is kept only when the code at its span
  is the name, plain or backticked, or a replacement function's name
  without `<-`. That drops the reads the walker places on a whole string
  (a glue segment, `new("C")`).
- **Page** (`CellInput/go_to_definition_plugin.js`): a reference to a name
  another cell defines becomes a `data-pluto-variable` link, and one to a
  name its own cell defines becomes a `data-cell-variable` link.
  Ctrl/Cmd-click focuses the defining cell and selects the definition.
  `Notebook.js` maps each name to the first cell defining it, from every
  cell's `defs`. Package exports and method generics, which
  `downstream_cells_map` also lists, are not links. The marks show only
  while the editor holds exactly the submitted code the spans were read
  from. While the user types they go away, until the cell is submitted.
- **Not covered yet:** the walker records no read of a name already bound
  in the cell, so `x <- 1; y <- x` gives no in-cell link on the second `x`.
  It also gives no link from a class name in a string (`new("Circle")`) to
  its `setClass()`.

## Not changed, on purpose

- **The secret**: `ws_address_from_base()` already copies `?secret=` from the
  page URL to the websocket URL, and the server also sets a cookie.
- **The ~130 CDN modules** (jsdelivr, esm.sh) stay as they are. Increment 1
  needs the network to load the page; the offline bundle is increment 2.
  Only `codemirror-ember-setup.js` is local, because it can't be on a CDN.
- **DOM hooks, CSS variable names, `window.editor_state`, the URLs**:
  untouched, so Endeavor's injected script keeps working.
- **Text, theme, logo, welcome page**: increment 2.

- `common/clock sync.js` and `lang/corporate english.json` are renamed with underscores, and their two imports updated: R CMD check rejects file names with spaces.
