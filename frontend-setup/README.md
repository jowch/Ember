# frontend-setup

Rebuilds `codemirror-pluto-setup@2002.0.8` (the CodeMirror 6 bundle Pluto's
frontend loads from jsdelivr) with Ember's R grammar (`grammar/`, via a
`file:` dependency) built in and exported as `r()` / `rLanguage`, alongside
everything the original bundle exported. See
`docs/ui-frontend.md` for why this has to be a full rebuild rather than
loading `grammar/dist/index.js` as a second `<script>`.

```
npm install
npm run build   # -> dist/codemirror-ember-setup.js
```

The build output is committed at
`inst/frontend/imports/codemirror-ember-setup.js` (served locally, not from
a CDN, since it doesn't exist upstream). `grammar/` must be built first
(`npm run build` there) since this package depends on `grammar/dist/index.js`.

CI (`.github/workflows/check.yaml`, job `codemirror-ember-setup`) rebuilds
this bundle and fails if the committed copy differs.
