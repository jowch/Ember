// One rollup input per third-party library the frontend uses, each a tiny
// re-export file under src/vendor/ naming exactly what the shim in
// inst/frontend/imports/ needs. Output is minified ES, content-hashed
// ([name]-[hash].js for both entries and shared chunks, so Preact's core
// used by both src/vendor/preact.js and nothing else still gets one
// stable-named file). scripts/build.mjs moves the result into
// inst/frontend/imports/vendor/ and rewrites each shim's import to match.
import { nodeResolve } from "@rollup/plugin-node-resolve"
import commonjs from "@rollup/plugin-commonjs"
import terser from "@rollup/plugin-terser"
import license from "rollup-plugin-license"
import path from "node:path"

const inputs = [
    "preact",
    "htm",
    "lodash-es",
    "immer",
    "dompurify",
    "semver",
    "ansi_up",
    "observablehq-stdlib",
    "dialog-polyfill",
    "highlightjs",
    "requestidlecallback-polyfill",
    "seamless-scroll-polyfill",
    "msgpack-lite",
    "js-sha256",
]

export default {
    input: Object.fromEntries(inputs.map((name) => [name, `src/vendor/${name}.js`])),
    output: {
        dir: "dist/vendor",
        format: "es",
        entryFileNames: "[name]-[hash].js",
        chunkFileNames: "[name]-[hash].js",
    },
    plugins: [
        nodeResolve({ exportConditions: ["import", "module", "browser", "default"] }),
        commonjs(),
        terser(),
        license({
            thirdParty: {
                output: {
                    file: path.resolve("dist/vendor/THIRD-PARTY.txt"),
                    // Sorted by name: rollup's own dependency-collection order
                    // isn't stable across runs, and an unstable file would
                    // fail "a rebuild with no change leaves git clean".
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
