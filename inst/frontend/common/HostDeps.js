// A widget's files (`deps/<key>/<file>`, written by project_dep_tags() in
// pluto-state.R) load from Ember's server on the live page, and from Blob URLs
// in an export (export-loader.js). A page shown where it can't reach Ember's
// server -- a host's sandboxed frame, like the notebook view in Claude's
// desktop app -- can set `window.ember_dep_file(path)`, which resolves to the
// file as `{ mime, data }` (data in base64, the same shape as an export's
// #ember-deps entries). Then an output's widget files come from the host:
// each script becomes a Blob URL, the same one for every output that uses it,
// so a library loads once; a stylesheet goes in as a <style>, since such a
// frame usually allows inline styles but not a stylesheet from a Blob URL.
// Without the hook nothing changes.

/** @type {Map<string, Promise<{ url?: string, css?: string }>>} */
const files = new Map()

const is_dep = (/** @type {string?} */ path) => path != null && path.startsWith("deps/") && !path.includes("..")

const decode = (/** @type {string} */ data) => Uint8Array.from(atob(data), (c) => c.charCodeAt(0))

const load = (/** @type {(path: string) => any} */ hook, /** @type {string} */ path) => {
    let file = files.get(path)
    if (file == null) {
        file = Promise.resolve(hook(path)).then(({ mime, data }) => {
            const bytes = decode(data)
            return /css/i.test(mime ?? "") ? { css: new TextDecoder().decode(bytes) } : { url: URL.createObjectURL(new Blob([bytes], { type: mime || "text/javascript" })) }
        })
        // A failed read can be tried again by the next output that needs it.
        file.catch(() => files.delete(path))
        files.set(path, file)
    }
    return file
}

const HELD = "data-ember-dep-href"

/**
 * `html` with each widget stylesheet's href moved aside, so that setting it
 * doesn't start a load the page can't make. `use_host_deps()` puts the file in.
 * `html` as it is without the hook.
 * @param {string} html
 */
export const hold_host_deps = (html) => {
    if (typeof (/** @type {any} */ (window).ember_dep_file) !== "function" || !html.includes("deps/")) return html
    const template = document.createElement("template")
    template.innerHTML = html
    let held = false
    for (const link of template.content.querySelectorAll("link[href]")) {
        const href = link.getAttribute("href")
        if (!is_dep(href)) continue
        link.setAttribute(HELD, /** @type {string} */ (href))
        link.removeAttribute("href")
        held = true
    }
    return held ? template.innerHTML : html
}

/**
 * Points the widget files in `container` at what the host gives, before its
 * scripts run. Does nothing without `window.ember_dep_file`.
 * @param {Element} container
 */
export const use_host_deps = async (container) => {
    const hook = /** @type {any} */ (window).ember_dep_file
    if (typeof hook !== "function") return
    const elements = [...container.querySelectorAll(`script[src], link[${HELD}]`)]
    await Promise.all(
        elements.map(async (el) => {
            const attr = el.tagName === "SCRIPT" ? "src" : HELD
            const path = el.getAttribute(attr)
            if (!is_dep(path)) return
            try {
                const file = await load(hook, /** @type {string} */ (path))
                if (file.css != null) {
                    const style = document.createElement("style")
                    style.textContent = file.css
                    el.replaceWith(style)
                } else if (file.url != null) {
                    el.setAttribute(el.tagName === "SCRIPT" ? "src" : "href", file.url)
                }
            } catch (e) {
                console.warn(`Couldn't get ${path} from the host`, e)
            }
        })
    )
}
