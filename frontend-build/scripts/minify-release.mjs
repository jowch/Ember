// `node scripts/minify-release.mjs <frontend dir>`: minifies Ember's own
// JavaScript in a copy of inst/frontend, in place, for a CRAN release tarball
// (#60; release-tarball.sh runs it). The repository keeps these files
// readable; never run this on the checkout itself.
//
// Each file keeps its name and place, so the live page and exports load the
// same paths. `imports/` is left alone: its bundles are minified already by
// `npm run build`, and its shims are a line or two. CSS and HTML stay as they
// are. Import specifiers keep their double quotes, which export_html()'s
// rewrite (R/export.R) looks for. The translation functions keep the names
// `t` and `th`: CRAN runs the tests on this tarball, and test-frontend-files.R
// finds every translation key by its t("...") or th("...") call.
import { minify } from "terser"
import fs from "node:fs"
import path from "node:path"

// Loaded as classic scripts, not modules: editor.html's warn_old_browsers.js,
// and export-loader.js, which export_html() inlines. Their top-level names
// stay as they are.
const CLASSIC = new Set(["warn_old_browsers.js", "export-loader.js"])

const frontend = process.argv[2]
if (!frontend || !fs.existsSync(path.join(frontend, "editor.html"))) {
    console.error("usage: node scripts/minify-release.mjs <a copy of inst/frontend>")
    process.exit(2)
}
if (fs.existsSync(path.join(frontend, "..", "..", ".git"))) {
    console.error(`${frontend} is in a git checkout; minify a copy (release-tarball.sh makes one)`)
    process.exit(2)
}

const files = []
const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name)
        if (entry.isDirectory()) {
            if (full !== path.join(frontend, "imports")) walk(full)
        } else if (entry.name.endsWith(".js")) {
            files.push(full)
        }
    }
}
walk(frontend)

let before = 0
let after = 0
for (const file of files) {
    const source = fs.readFileSync(file, "utf8")
    const rel = path.relative(frontend, file)
    const module = !CLASSIC.has(rel)
    const out = await minify(source, { module, compress: true, mangle: { reserved: ["t", "th"] }, keep_classnames: true, keep_fnames: true, format: { quote_style: 3, comments: false } })
    fs.writeFileSync(file, out.code)
    before += Buffer.byteLength(source)
    after += Buffer.byteLength(out.code)
}
console.log(`Minified ${files.length} files: ${before} -> ${after} bytes`)
