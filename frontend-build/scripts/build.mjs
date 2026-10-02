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
import { copyAssets } from "./copy-assets.mjs"
import { checkImports } from "./check-imports.mjs"

const HERE = path.dirname(new URL(import.meta.url).pathname)
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
        const thirdPartyPath = path.join(ROOT, "dist", "vendor", "THIRD-PARTY.txt")
        if (fs.existsSync(thirdPartyPath)) {
            fs.copyFileSync(thirdPartyPath, path.join(VENDOR_DIR, "THIRD-PARTY.txt"))
            keep.add("THIRD-PARTY.txt")
        }

        copyAssets({ frontendDir: FRONTEND })
        keep.add("dialog-polyfill.css")
        keep.add("iframeResizer.min.js")
        keep.add("iframeResizer.contentWindow.min.js")

        rewriteShimImports(hashedByBase)

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
