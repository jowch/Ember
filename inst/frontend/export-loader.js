// Makes a self-contained export's embedded frontend runnable from file://,
// where a relative `<script type="module" src="./editor.js">` can't load
// (module scripts are fetched, and `file://` fetches of other `file://`
// URLs are blocked by browsers). Read #ember-modules (every frontend .js
// and .json file, written by export_html() with relative import specifiers
// already rewritten to bare "ember/<path>" keys), turn each into a Blob URL,
// map "ember/<path>" to that URL in an <script type="importmap">, then run
// the frontend with a module script that imports "ember/editor.js". Import
// maps resolve any import order, including cycles, so insertion order here
// doesn't matter; it only has to happen before the module script below.
// A widget dependency file (`deps/<key>/<file>`, server.R's register_deps())
// is embedded once here -- not once per output that uses it, which used to
// multiply a shared dependency's size by however many outputs used it (a
// 10-plotly-output notebook: ~66 MB instead of ~7 MB) -- as one entry in
// #ember-deps (path -> {mime, data}, R/export.R's dep_files_json()). Each
// becomes one Blob URL here, in a global map CellOutput.js's
// RawHTMLContainer reads to rewrite a rendered output's own `deps/...`
// src/href to the right Blob URL; the map is absent on the live page (which
// has no #ember-deps and serves /deps/<key>/<file> for real), so that
// rewrite never runs there.
;(() => {
    const depsEl = document.getElementById("ember-deps")
    if (depsEl) {
        const deps = JSON.parse(depsEl.textContent)
        const urls = {}
        for (const key in deps) {
            const { mime, data } = deps[key]
            const bytes = Uint8Array.from(atob(data), (c) => c.charCodeAt(0))
            urls[key] = URL.createObjectURL(new Blob([bytes], { type: mime }))
        }
        window.__ember_export_dep_urls = urls
    }

    const modules = JSON.parse(document.getElementById("ember-modules").textContent)
    const imports = {}
    for (const path in modules) {
        const type = path.endsWith(".json") ? "application/json" : "text/javascript"
        imports["ember/" + path] = URL.createObjectURL(new Blob([modules[path]], { type }))
    }

    const importMap = document.createElement("script")
    importMap.type = "importmap"
    importMap.textContent = JSON.stringify({ imports })
    document.currentScript.after(importMap)

    const main = document.createElement("script")
    main.type = "module"
    main.textContent = 'import "ember/editor.js"'
    importMap.after(main)
})()
