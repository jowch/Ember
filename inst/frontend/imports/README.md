# `frontend/imports/`

Every third-party browser dependency the editor uses is wrapped here in a
tiny ES-module shim (e.g. `Preact.js`, `msgpack-lite.js`). The rest of the
frontend imports **only** from this folder — no CDN URL appears anywhere in
`inst/frontend/`, and none of this runs over the network: `frontend-build/`
(the `frontend-build/` npm package, not a folder in here) bundles each
dependency with rollup into a content-hashed file under `vendor/`, and each
shim's `from "./vendor/<name>-<hash>.js"` line is rewritten to match by
`frontend-build/scripts/build.mjs` on every build. `vendor/` is served with
a year-long immutable cache lifetime (R/server.R); the hash in every file
name there is what makes that safe.

A couple of files in `vendor/` aren't rollup output: `dialog-polyfill.css`
and the two iframe-resizer scripts are copied in as-is (and still
content-hashed) by `frontend-build/scripts/copy-assets.mjs`, since they're
consumed as a `<link>`/classic `<script src>` rather than an ES import.
`THIRD-PARTY.txt`, one level up in `imports/`, lists every bundled
dependency's licence; it documents `vendor/` without being loaded by
anything, so it isn't itself hashed or cached immutably.

## How to update a dependency

1. Bump the version in `frontend-build/package.json` (or
   `rollup.vendor.config.js`/`rollup.config.js` for anything not a plain
   npm dependency).
2. From `frontend-build/`: `npm install && npm run build`. This rewrites
   every shim's `from "./vendor/..."` line to the freshly built file's new
   hash, and deletes any hashed file nothing points to any more.
3. Check `git diff` — a clean rebuild with no version bump should produce no
   diff at all (the hashes are a pure function of content).
4. Run the R test suite (`devtools::test()`); `tests/testthat/test-frontend-files.R`
   checks there's no stray CDN URL, every hashed file is actually hashed,
   and the bundle stays under its size budget.

## Shims with local behaviour

A few shims add a small adjustment next to the import rather than
re-exporting the dependency as-is:

- **`codemirror-ember-setup.js`** — Ember's own CodeMirror 6 setup (the R
  language, Ember's extensions), built from `frontend-build/src/` rather
  than re-exporting an upstream package.
- **`lang_imports.js`** — not a dependency at all. It bulk-imports the JSON
  files in `../lang/` with import attributes (`with { type: "json" }`), in
  its own file because some tooling can't parse `with`.
- **`PreactCustomElement.js`** — vendored source, not a rollup-bundled
  dependency: copied from
  [preactjs/preact-custom-element](https://github.com/preactjs/preact-custom-element)
  with local modifications (the reconnect grace period in
  `disconnectedCallback`). To update it, re-diff against upstream and
  re-apply the local changes by hand.

## Adding a new dependency

1. Add it to `frontend-build/package.json` and to
   `rollup.vendor.config.js`'s entry points.
2. Create a shim here, `Foo.js`, that imports from `./vendor/foo.js` (the
   unhashed placeholder the build rewrites) and re-exports the surface this
   frontend actually uses.
3. Import `Foo` only from `./imports/Foo.js` elsewhere in the frontend.
4. Run the build and the test suite as above.
