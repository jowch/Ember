// Copies the ionicons SVGs the frontend's CSS names into img/icons/, and
// dialog-polyfill.css plus the two iframe-resizer scripts into
// imports/vendor/ (not bundled by rollup: dialog-polyfill.css isn't JS, and
// the iframe-resizer scripts are consumed as classic <script> tags, not ES
// imports, so there is no shim to rewrite). No font files are copied:
// piece 1 chose system fonts.
//
// The three vendor files are content-hashed on the way in, the same as
// every rollup-built file in imports/vendor/: that folder is served with a
// year-long immutable Cache-Control (R/server.R's http_app()), so every
// file in it has to change name when its content does, or a stale browser
// cache would serve the old bytes forever under a new release. build.mjs
// rewrites editor.html's two <script src>s and editor.css's @import line to
// match; R/export.R's iframe-resizer regex matches any "iframeResizer*.js"
// name, hashed or not, so it needs no change.
import fs from "node:fs"
import path from "node:path"
import crypto from "node:crypto"
import { createRequire } from "node:module"
import { fileURLToPath } from "node:url"

const require = createRequire(import.meta.url)
const HERE = path.dirname(fileURLToPath(import.meta.url))
const DEFAULT_FRONTEND = path.resolve(HERE, "..", "..", "inst", "frontend")

/** `<base>-<8-char content hash>.<ext>`, the same shape rollup's own `[name]-[hash][extname]` gives a chunk. */
function hashedName(base, ext, contents) {
    const hash = crypto.createHash("sha256").update(contents).digest("base64url").slice(0, 8)
    return `${base}-${hash}${ext}`
}

/** Copy `src` into `vendorDir` under a content-hashed name; returns that name. */
function copyHashed(src, vendorDir, base, ext) {
    const contents = fs.readFileSync(src)
    const name = hashedName(base, ext, contents)
    fs.writeFileSync(path.join(vendorDir, name), contents)
    return name
}

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
    const dialogPolyfillHashed = copyHashed(dialogPolyfillCss, vendorDir, "dialog-polyfill", ".css")

    const iframeResizerDir = path.join(path.dirname(require.resolve("iframe-resizer/package.json")), "js")
    const iframeResizerHashed = copyHashed(
        path.join(iframeResizerDir, "iframeResizer.min.js"), vendorDir, "iframeResizer.min", ".js")
    const iframeResizerContentWindowHashed = copyHashed(
        path.join(iframeResizerDir, "iframeResizer.contentWindow.min.js"), vendorDir,
        "iframeResizer.contentWindow.min", ".js")

    return {
        icons: wanted,
        hashed: {
            "dialog-polyfill.css": dialogPolyfillHashed,
            "iframeResizer.min.js": iframeResizerHashed,
            "iframeResizer.contentWindow.min.js": iframeResizerContentWindowHashed,
        },
    }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
    const frontendDir = process.argv[2] ? path.resolve(process.argv[2]) : DEFAULT_FRONTEND
    const { icons } = copyAssets({ frontendDir })
    console.log(`copy-assets: ${icons.length} icons, dialog-polyfill.css, iframe-resizer scripts`)
}
