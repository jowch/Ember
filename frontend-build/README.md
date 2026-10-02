# frontend-build

Builds everything `inst/frontend` loads instead of a CDN: the CodeMirror 6
bundle, the third-party vendor bundles, and the copied assets (icons,
dialog-polyfill's stylesheet, iframe-resizer's scripts). See docs/ui-2.md,
"Offline bundle".

```
npm install
npm run build
```

`grammar/` must be built first (`npm run build` there), since the CodeMirror
bundle depends on `grammar/dist/index.js`.

`npm run build` rebuilds three things, in `scripts/build.mjs`:

1. `codemirror-ember-setup.js`: `rollup.config.js` rebuilds
   `codemirror-pluto-setup@2002.0.8` (the bundle Pluto's frontend loads from
   jsdelivr) with Ember's R grammar built in and exported as `r()` /
   `rLanguage`, minified, without the Julia, Python and SQL languages. See
   `docs/ui-frontend.md` for why this has to be a full rebuild rather than
   loading `grammar/dist/index.js` as a second `<script>`.
2. The third-party libraries: `rollup.vendor.config.js` builds one input per
   library under `src/vendor/`, minified, with `rollup-plugin-license`
   writing `THIRD-PARTY.txt`.
3. `scripts/copy-assets.mjs`: the ionicons SVGs the CSS uses, plus
   `dialog-polyfill.css` and the two iframe-resizer scripts (these aren't
   bundled by rollup: the CSS file isn't JS, and the iframe-resizer scripts
   are loaded as classic `<script>` tags, not ES imports).

Every file these three steps produce is written content-hashed
(`<name>-<hash>.js`) to `inst/frontend/imports/vendor/`; the build then
rewrites the `from` line of each shim in `inst/frontend/imports/*.js` to the
new hashed name, and deletes any hashed file nothing points to any more, so
a rebuild with no source change leaves `git diff` clean.
`scripts/check-imports.mjs` then checks that every name the frontend imports
from `CodemirrorPlutoSetup.js` is actually exported by the trimmed bundle.

The build output is committed. CI (`.github/workflows/check.yaml`, job
`frontend-build`) rebuilds it and fails if the committed copy differs, or if
any file under `inst/frontend/imports` or `inst/frontend/img/icons` is
untracked.
