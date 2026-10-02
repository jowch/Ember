// Rebuild of codemirror-pluto-setup@2002.0.8's own rollup config: bundle
// everything (CodeMirror, Lezer, and Ember's R grammar) into one
// self-contained ES module with no external imports, so the page never
// loads a second copy of @lezer/common or @lezer/highlight alongside this
// bundle. See docs/ui-frontend.md for why that matters. Minified and
// content-hashed: scripts/build.mjs moves the output into
// inst/frontend/imports/vendor/ and rewrites the shim that imports it.
import { nodeResolve } from "@rollup/plugin-node-resolve"
import terser from "@rollup/plugin-terser"

export default {
  input: { "codemirror-ember-setup": "src/index.js" },
  output: {
    dir: "dist",
    entryFileNames: "[name]-[hash].js",
    format: "es",
  },
  plugins: [nodeResolve(), terser()],
}
