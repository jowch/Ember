// Copies the ionicons SVGs the frontend's CSS names into img/icons/,
// dialog-polyfill.css plus the two iframe-resizer scripts into
// imports/vendor/ (not bundled by rollup: dialog-polyfill.css isn't JS, and
// the iframe-resizer scripts are consumed as classic <script> tags, not ES
// imports, so there is no shim to rewrite), and the three bundled font
// families (Figtree, Source Serif 4, IBM Plex Mono) plus their licences
// into fonts/.
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

/** The three bundled font families: which package, which of its CSS files
 * to read `@font-face` blocks from, which files (by basename, without
 * extension) of those blocks to keep -- Latin and Latin Extended only,
 * woff2 only, the variable-weight axis for Figtree and Source Serif 4,
 * weights 400 and 500 for IBM Plex Mono -- and the CSS `font-family` name
 * Ember's tokens reference (ui-3-plan.md, "Fonts"). */
const FONT_FAMILIES = [
    {
        pkg: "@fontsource-variable/figtree",
        cssFiles: ["wght.css", "wght-italic.css"],
        basenames: ["figtree-latin-wght-normal", "figtree-latin-ext-wght-normal", "figtree-latin-wght-italic", "figtree-latin-ext-wght-italic"],
        family: "Figtree",
        licence: "OFL-figtree.txt",
    },
    {
        pkg: "@fontsource-variable/source-serif-4",
        cssFiles: ["wght.css", "wght-italic.css"],
        basenames: [
            "source-serif-4-latin-wght-normal",
            "source-serif-4-latin-ext-wght-normal",
            "source-serif-4-latin-wght-italic",
            "source-serif-4-latin-ext-wght-italic",
        ],
        family: "Source Serif 4",
        licence: "OFL-source-serif-4.txt",
    },
    {
        pkg: "@fontsource/ibm-plex-mono",
        cssFiles: ["400.css", "500.css"],
        basenames: ["ibm-plex-mono-latin-400-normal", "ibm-plex-mono-latin-ext-400-normal", "ibm-plex-mono-latin-500-normal", "ibm-plex-mono-latin-ext-500-normal"],
        family: "IBM Plex Mono",
        licence: "OFL-ibm-plex-mono.txt",
    },
]

/** Parse every `@font-face` block in `css`, keeping the ones whose `src`
 * names a woff2 file in `basenames`. Returns `{ basename, style, weight,
 * unicodeRange }` per kept block. */
function parseFontFaces(css, basenames) {
    const out = []
    const re = /@font-face\s*{([^}]*)}/g
    for (const m of css.matchAll(re)) {
        const body = m[1]
        const styleMatch = body.match(/font-style:\s*([a-z]+)/)
        const weightMatch = body.match(/font-weight:\s*([0-9 ]+)/)
        const srcMatch = body.match(/url\(\.\/files\/([a-zA-Z0-9_-]+)\.woff2\)\s*format\('woff2(?:-variations)?'\)/)
        const unicodeMatch = body.match(/unicode-range:\s*([^;]+);/)
        if (srcMatch == null || !basenames.includes(srcMatch[1])) continue
        out.push({
            basename: srcMatch[1],
            style: styleMatch?.[1] ?? "normal",
            weight: weightMatch?.[1]?.trim() ?? "400",
            unicodeRange: unicodeMatch?.[1]?.trim() ?? "",
        })
    }
    return out
}

/** Copy the bundled fonts' woff2 files and OFL licences into
 * `frontendDir/fonts/`; returns the `@font-face` descriptors (with the
 * fonts/ hashed file name filled in) `fonts.css` is generated from. */
export function copyFonts(frontendDir) {
    const fontsDir = path.join(frontendDir, "fonts")
    fs.mkdirSync(fontsDir, { recursive: true })
    const faces = []
    const keep = new Set()
    for (const fam of FONT_FAMILIES) {
        const pkgDir = path.dirname(require.resolve(`${fam.pkg}/package.json`))
        const seen = new Set()
        for (const cssFile of fam.cssFiles) {
            const css = fs.readFileSync(path.join(pkgDir, cssFile), "utf8")
            for (const face of parseFontFaces(css, fam.basenames)) {
                if (seen.has(face.basename)) continue
                seen.add(face.basename)
                const src = path.join(pkgDir, "files", `${face.basename}.woff2`)
                const hashedFile = copyHashed(src, fontsDir, face.basename, ".woff2")
                keep.add(hashedFile)
                faces.push({ family: fam.family, style: face.style, weight: face.weight, unicodeRange: face.unicodeRange, fileName: hashedFile })
            }
        }
        if (seen.size !== fam.basenames.length) {
            throw new Error(`copy-assets: expected ${fam.basenames.length} font files for ${fam.pkg}, found ${seen.size}`)
        }
        const licenceSrc = path.join(pkgDir, "LICENSE")
        fs.copyFileSync(licenceSrc, path.join(fontsDir, fam.licence))
        keep.add(fam.licence)
    }
    // Remove font files nothing refers to any more (a version bump or a
    // dropped family changes the hash or the set of files).
    for (const existing of fs.readdirSync(fontsDir)) {
        if (!keep.has(existing)) fs.rmSync(path.join(fontsDir, existing))
    }
    return faces
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

    const fontFaces = copyFonts(frontendDir)

    return {
        icons: wanted,
        hashed: {
            "dialog-polyfill.css": dialogPolyfillHashed,
            "iframeResizer.min.js": iframeResizerHashed,
            "iframeResizer.contentWindow.min.js": iframeResizerContentWindowHashed,
        },
        fontFaces,
    }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
    const frontendDir = process.argv[2] ? path.resolve(process.argv[2]) : DEFAULT_FRONTEND
    const { icons, fontFaces } = copyAssets({ frontendDir })
    console.log(`copy-assets: ${icons.length} icons, dialog-polyfill.css, iframe-resizer scripts, ${fontFaces.length} font files`)
}
