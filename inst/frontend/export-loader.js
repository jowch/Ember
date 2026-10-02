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
;(() => {
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
