// Rebuild of codemirror-pluto-setup@2002.0.8's own rollup config: bundle
// everything (CodeMirror, Lezer, and Ember's R grammar) into one
// self-contained ES module with no external imports, so the page never
// loads a second copy of @lezer/common or @lezer/highlight alongside this
// bundle. See docs/ui-frontend.md for why that matters.
import { nodeResolve } from "@rollup/plugin-node-resolve"

export default {
  input: "src/index.js",
  output: {
    file: "dist/codemirror-ember-setup.js",
    format: "es",
  },
  plugins: [nodeResolve()],
}
