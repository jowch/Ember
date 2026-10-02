// Every name the frontend imports from imports/CodemirrorPlutoSetup.js must
// be exported by the bundle it re-exports (imports/vendor/codemirror-ember-setup-*.js).
// Trimming a language (or anything else) from frontend-build/src/index.js
// can't silently break an importer: this fails loudly instead.
import fs from "node:fs"
import path from "node:path"

const HERE = path.dirname(new URL(import.meta.url).pathname)
const DEFAULT_FRONTEND = path.resolve(HERE, "..", "..", "inst", "frontend")

function listJsFiles(dir) {
    const out = []
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name)
        if (entry.isDirectory()) out.push(...listJsFiles(full))
        else if (entry.name.endsWith(".js")) out.push(full)
    }
    return out
}

/** Named imports pulled from a `from "<...>/CodemirrorPlutoSetup.js"` specifier. */
function importedNames(source) {
    const names = new Set()
    const re = /import\s*\{([^}]*)\}\s*from\s*["'][^"']*CodemirrorPlutoSetup\.js["']/g
    for (const m of source.matchAll(re)) {
        for (let part of m[1].split(",")) {
            part = part.trim()
            if (!part) continue
            const [orig] = part.split(/\s+as\s+/)
            names.add(orig.trim())
        }
    }
    return names
}

/** The bundle's own top-level `export { ... }` names (and `export const/class/function NAME`). */
function bundleExports(source) {
    const names = new Set()
    for (const m of source.matchAll(/export\s*\{([^}]*)\}/g)) {
        for (let part of m[1].split(",")) {
            part = part.trim()
            if (!part) continue
            const pieces = part.split(/\s+as\s+/)
            names.add(pieces[pieces.length - 1].trim())
        }
    }
    for (const m of source.matchAll(/export\s+(?:const|class|function)\s+([A-Za-z0-9_$]+)/g)) {
        names.add(m[1])
    }
    return names
}

export function checkImports({ frontendDir = DEFAULT_FRONTEND } = {}) {
    const shimPath = path.join(frontendDir, "imports", "CodemirrorPlutoSetup.js")
    const shimSource = fs.readFileSync(shimPath, "utf8")
    const m = shimSource.match(/from\s*["'](\.\/vendor\/[^"']+\.js)["']/)
    if (!m) throw new Error("check-imports: CodemirrorPlutoSetup.js doesn't re-export from ./vendor/*.js")
    const bundlePath = path.join(frontendDir, "imports", m[1])
    if (!fs.existsSync(bundlePath)) throw new Error(`check-imports: bundle not found: ${bundlePath}`)
    const exported = bundleExports(fs.readFileSync(bundlePath, "utf8"))

    const missing = []
    for (const file of listJsFiles(frontendDir)) {
        if (file === shimPath) continue
        const used = importedNames(fs.readFileSync(file, "utf8"))
        for (const name of used) {
            if (!exported.has(name)) missing.push({ file: path.relative(frontendDir, file), name })
        }
    }
    return missing
}

if (import.meta.url === `file://${process.argv[1]}`) {
    const frontendDir = process.argv[2] ? path.resolve(process.argv[2]) : DEFAULT_FRONTEND
    const missing = checkImports({ frontendDir })
    if (missing.length > 0) {
        for (const { file, name } of missing) {
            console.error(`check-imports: ${file} imports "${name}" from CodemirrorPlutoSetup.js, which the bundle doesn't export`)
        }
        process.exit(1)
    }
    console.log("check-imports: ok")
}
