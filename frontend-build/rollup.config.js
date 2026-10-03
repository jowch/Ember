// Rebuild of codemirror-pluto-setup@2002.0.8's own rollup config: bundle
// everything (CodeMirror, Lezer, and Ember's R grammar) into one
// self-contained ES module with no external imports, so the page never
// loads a second copy of @lezer/common or @lezer/highlight alongside this
// bundle. See docs/ui-frontend.md for why that matters. Minified and
// content-hashed: scripts/build.mjs moves the output into
// inst/frontend/imports/vendor/ and rewrites the shim that imports it.
import { nodeResolve } from "@rollup/plugin-node-resolve"
import terser from "@rollup/plugin-terser"
import license from "rollup-plugin-license"
import path from "node:path"

export default {
  input: { "codemirror-ember-setup": "src/index.js" },
  output: {
    dir: "dist",
    entryFileNames: "[name]-[hash].js",
    format: "es",
  },
  plugins: [
    nodeResolve({ dedupe: (id) => id.startsWith("@lezer/") }),
    terser(),
    // A separate file, not dist/vendor/THIRD-PARTY.txt (rollup.vendor.config.js's
    // own output): this is a different rollup build with no access to that
    // one's already-collected dependency list, so writing the same path
    // would just overwrite it rather than merge. build.mjs concatenates
    // both into the one file inst/frontend/imports/THIRD-PARTY.txt ships.
    license({
      thirdParty: {
        output: {
          file: path.resolve("dist", "THIRD-PARTY-codemirror.txt"),
          template: (dependencies) =>
            [...dependencies]
              .sort((a, b) => a.name.localeCompare(b.name))
              .map((d) => d.text())
              .join("\n\n---\n\n"),
        },
      },
    }),
  ],
}
