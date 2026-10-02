// Copies the ionicons SVGs the frontend's CSS names into img/icons/, and
// dialog-polyfill.css plus the two iframe-resizer scripts into
// imports/vendor/ (not bundled by rollup: dialog-polyfill.css isn't JS, and
// the iframe-resizer scripts are consumed as classic <script> tags, not ES
// imports, so there is no shim to rewrite). No font files are copied:
// piece 1 chose system fonts.
import fs from "node:fs"
import path from "node:path"
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const HERE = path.dirname(new URL(import.meta.url).pathname)
const DEFAULT_FRONTEND = path.resolve(HERE, "..", "..", "inst", "frontend")

/** Every ionicons basename named by a url(...) in the frontend's CSS. */
export function iconNamesUsedIn(frontendDir) {
    const names = new Set()
    const cssFiles = ["editor.css", "treeview.css", "highlightjs.css"]
        .map((f) => path.join(frontendDir, f))
        .filter((f) => fs.existsSync(f))
    const re = /img\/icons\/([a-zA-Z0-9_-]+\.svg)/g
    for (const file of cssFiles) {
        const text = fs.readFileSync(file, "utf8")
        for (const m of text.matchAll(re)) names.add(m[1])
    }
    return [...names].sort()
}

export function copyAssets({ frontendDir = DEFAULT_FRONTEND } = {}) {
    const iconsDir = path.join(frontendDir, "img", "icons")
    fs.mkdirSync(iconsDir, { recursive: true })

    const ioniconsSvgDir = path.join(path.dirname(require.resolve("ionicons/package.json")), "dist", "svg")
    const wanted = iconNamesUsedIn(frontendDir)
    const missing = []
    for (const name of wanted) {
        const src = path.join(ioniconsSvgDir, name)
        if (!fs.existsSync(src)) {
            missing.push(name)
            continue
        }
        fs.copyFileSync(src, path.join(iconsDir, name))
    }
    if (missing.length > 0) {
        throw new Error(`copy-assets: ionicons is missing: ${missing.join(", ")}`)
    }
    // Remove icons that are no longer referenced.
    for (const existing of fs.readdirSync(iconsDir)) {
        if (!wanted.includes(existing)) fs.rmSync(path.join(iconsDir, existing))
    }

    const vendorDir = path.join(frontendDir, "imports", "vendor")
    fs.mkdirSync(vendorDir, { recursive: true })

    const dialogPolyfillCss = require.resolve("dialog-polyfill/dialog-polyfill.css")
    fs.copyFileSync(dialogPolyfillCss, path.join(vendorDir, "dialog-polyfill.css"))

    const iframeResizerDir = path.join(path.dirname(require.resolve("iframe-resizer/package.json")), "js")
    for (const f of ["iframeResizer.min.js", "iframeResizer.contentWindow.min.js"]) {
        fs.copyFileSync(path.join(iframeResizerDir, f), path.join(vendorDir, f))
    }

    return { icons: wanted }
}

if (import.meta.url === `file://${process.argv[1]}`) {
    const frontendDir = process.argv[2] ? path.resolve(process.argv[2]) : DEFAULT_FRONTEND
    const { icons } = copyAssets({ frontendDir })
    console.log(`copy-assets: ${icons.length} icons, dialog-polyfill.css, iframe-resizer scripts`)
}
