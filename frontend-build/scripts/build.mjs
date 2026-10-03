// One `npm run build`: the CodeMirror bundle, the third-party vendor
// bundles, and the copied assets (ionicons, dialog-polyfill.css,
// iframe-resizer). Every JS file ends up under inst/frontend/imports/vendor/
// with a content hash in its name; this script then rewrites the `from`
// line of each shim in inst/frontend/imports/*.js to match, and deletes
// hashed files nothing points to any more, so a rebuild with no source
// change leaves `git diff` clean. See docs/ui-2.md, "Offline bundle".
import { rollup } from "rollup"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { copyAssets } from "./copy-assets.mjs"
import { checkImports } from "./check-imports.mjs"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, "..")
const FRONTEND = path.resolve(ROOT, "..", "inst", "frontend")
const IMPORTS_DIR = path.join(FRONTEND, "imports")
const VENDOR_DIR = path.join(IMPORTS_DIR, "vendor")

async function runRollup(configPath) {
    const { default: config } = await import(configPath)
    const bundle = await rollup(config)
    const { output } = await bundle.write(config.output)
    await bundle.close()
    return output
}

function main_build() {
    return (async () => {
        fs.mkdirSync(VENDOR_DIR, { recursive: true })

        const cmOutput = await runRollup(path.join(ROOT, "rollup.config.js"))
        const vendorOutput = await runRollup(path.join(ROOT, "rollup.vendor.config.js"))

        // Named entries (the input keys) map to their hashed file name; this is
        // what each shim's `from` line needs rewritten to. Other chunks (shared
        // code rollup split out, such as commonjs's helper module) have no
        // shim of their own -- they're only ever reached via another chunk's
        // own import, which rollup already points at the right hashed name.
        const hashedByBase = new Map()
        for (const o of [...cmOutput, ...vendorOutput]) {
            if (o.type === "chunk" && o.isEntry && o.name) hashedByBase.set(o.name, o.fileName)
        }

        // Move every built .js file into inst/frontend/imports/vendor/.
        const keep = new Set()
        for (const [outDir, output] of [
            [path.join(ROOT, "dist"), cmOutput],
            [path.join(ROOT, "dist", "vendor"), vendorOutput],
        ]) {
            for (const o of output) {
                if (!o.fileName.endsWith(".js")) continue
                fs.copyFileSync(path.join(outDir, o.fileName), path.join(VENDOR_DIR, o.fileName))
                keep.add(o.fileName)
            }
        }
        // THIRD-PARTY.txt documents imports/vendor/ but isn't itself loaded
        // by anything; it lives one level up, in imports/, which the rest of
        // the frontend already serves as no-cache (R/server.R's http_app()
        // only grants the year-long immutable lifetime to imports/vendor/
        // itself) -- a licence file has no content hash to invalidate a
        // stale cache with, so it can't share that path.
        const thirdPartyPath = path.join(ROOT, "dist", "vendor", "THIRD-PARTY.txt")
        if (fs.existsSync(thirdPartyPath)) {
            fs.copyFileSync(thirdPartyPath, path.join(IMPORTS_DIR, "THIRD-PARTY.txt"))
        }

        const { hashed } = copyAssets({ frontendDir: FRONTEND })
        for (const name of Object.values(hashed)) keep.add(name)

        rewriteShimImports(hashedByBase)
        rewriteVendorAssetReferences(hashed)

        // Delete hashed files nothing refers to any more.
        for (const existing of fs.readdirSync(VENDOR_DIR)) {
            if (!keep.has(existing)) fs.rmSync(path.join(VENDOR_DIR, existing))
        }

        const missing = checkImports({ frontendDir: FRONTEND })
        if (missing.length > 0) {
            for (const { file, name } of missing) {
                console.error(`check-imports: ${file} imports "${name}" from CodemirrorPlutoSetup.js, which the bundle doesn't export`)
            }
            process.exit(1)
        }

        console.log(`frontend-build: ${keep.size} files in imports/vendor/`)
    })()
}

const ESCAPE_RE = /[.*+?^${}()|[\]\\]/g

/** Rewrite editor.html's two iframe-resizer <script src>s and editor.css's
 * dialog-polyfill @import to the current build's hashed vendor file names
 * (`hashed`: unhashed base name -> hashed file name, from copyAssets()). */
function rewriteVendorAssetReferences(hashed) {
    const rewrite = (file, base) => {
        const target = hashed[base]
        const dot = base.lastIndexOf(".")
        const stem = base.slice(0, dot).replace(ESCAPE_RE, "\\$&")
        const ext = base.slice(dot + 1)
        // Matches the unhashed placeholder (a fresh checkout) or a previous
        // build's hashed name (a rebuild), the same two cases
        // rewriteShimImports() above handles for a module's own `from` line.
        const re = new RegExp(`imports/vendor/${stem}(-[0-9A-Za-z_-]+)?\\.${ext}`)
        let source = fs.readFileSync(file, "utf8")
        if (!re.test(source)) {
            throw new Error(`build: couldn't find imports/vendor/${base} (or a previously hashed form) in ${file}`)
        }
        // Not "if changed, write": a rebuild with the same content (the
        // common case) finds the match already up to date, which is still a
        // successful find, not an error -- unlike rewriteShimImports()
        // above, there's exactly one match here, so re-writing it
        // unconditionally costs nothing.
        const next = source.replace(re, `imports/vendor/${target}`)
        fs.writeFileSync(file, next)
    }
    rewrite(path.join(FRONTEND, "editor.html"), "iframeResizer.min.js")
    rewrite(path.join(FRONTEND, "editor.html"), "iframeResizer.contentWindow.min.js")
    rewrite(path.join(FRONTEND, "editor.css"), "dialog-polyfill.css")
}

/** Rewrite every `./vendor/<base>[-<hash>].js` specifier in imports/*.js to the current hashed name. */
function rewriteShimImports(hashedByBase) {
    // Longest base name first, so "js-sha256" isn't shadowed by a shorter
    // false match before it's tried.
    const bases = [...hashedByBase.keys()].sort((a, b) => b.length - a.length)
    for (const entry of fs.readdirSync(IMPORTS_DIR, { withFileTypes: true })) {
        if (!entry.isFile() || !entry.name.endsWith(".js")) continue
        const file = path.join(IMPORTS_DIR, entry.name)
        let source = fs.readFileSync(file, "utf8")
        let changed = false
        for (const base of bases) {
            const hashed = hashedByBase.get(base)
            const escaped = base.replace(ESCAPE_RE, "\\$&")
            // Matches both the unhashed placeholder ("./vendor/preact.js", as
            // authored) and a previous build's hashed name, so a version bump
            // or a fresh checkout both resolve to the current hash.
            const re = new RegExp(`\\./vendor/${escaped}(-[0-9A-Za-z_-]+)?\\.js`, "g")
            const next = source.replace(re, `./vendor/${hashed}`)
            if (next !== source) changed = true
            source = next
        }
        if (changed) fs.writeFileSync(file, source)
    }
}

main_build()
