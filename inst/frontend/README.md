# Pluto frontend (vendored)

This directory is Pluto.jl's frontend (the `frontend/` folder of
https://github.com/fonsp/Pluto.jl), vendored at v1.0.3, commit
`3a7651f2322d69f11ab98a020e97466b19d53723`. Pluto is MIT-licensed; the
license is in `LICENSE` alongside this file.

Ember's changes on top of this vendored copy are listed file by file in
`docs/ui-frontend.md`. The one exception is `imports/codemirror-ember-setup.js`,
which does not exist upstream: it's a locally built replacement for the
`codemirror-pluto-setup` CDN bundle that adds the R grammar (see
`frontend-setup/` at the repository root for how it's built, and
`docs/ui-frontend.md` for why it has to be a rebuild rather than a second
`<script>`).
