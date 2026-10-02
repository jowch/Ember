# Pluto frontend (vendored)

This directory is Pluto.jl's frontend (the `frontend/` folder of
https://github.com/fonsp/Pluto.jl), vendored at v1.0.3, commit
`3a7651f2322d69f11ab98a020e97466b19d53723`. Pluto is MIT-licensed; the
license is in `LICENSE` alongside this file.

Ember's changes on top of this vendored copy are listed file by file in
`docs/ui-frontend.md`. Two exceptions don't exist upstream:

- `imports/vendor/codemirror-ember-setup-*.js`: a locally built replacement
  for the `codemirror-pluto-setup` CDN bundle that adds the R grammar (see
  `frontend-build/` at the repository root for how it's built, and
  `docs/ui-frontend.md` for why it has to be a rebuild rather than a second
  `<script>`).
- `imports/vendor/`: every other third-party library the frontend uses,
  bundled from npm instead of loaded from a CDN, so the page works offline
  and exports are self-contained (`frontend-build/`, docs/ui-2.md "Offline
  bundle"). Its files are content-hashed and served with a long cache
  lifetime (`imports/vendor/*-<hash>.js`); don't hand-edit them or the
  shims' `from` lines that point at them -- rerun `frontend-build`'s
  `npm run build` instead.
