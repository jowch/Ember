// A widget's files (`deps/<key>/<file>`, written by project_dep_tags() in
// pluto-state.R) load from Ember's server on the live page, and from Blob URLs
// in an export (export-loader.js). A page shown where it can't reach Ember's
// server -- a host's sandboxed frame, like the notebook view in Claude's
// desktop app -- can set `window.ember_dep_file(path)`, which resolves to the
// file as `{ mime, data }` (data in base64, the same shape as an export's
// #ember-deps entries). The host sets it before the page's scripts run. Then
// an output's widget files come from the host: each script becomes a Blob URL,
// the same one for every output that uses it, so a library loads once; a
// stylesheet goes in as a <style>, since such a frame usually allows inline
// styles but not a stylesheet from a Blob URL, and the files its url()s name
// next to it (images, fonts) go in as data: URLs. A stylesheet's @import isn't
// followed. Without the hook nothing changes.

/** How long the host may take over one file before the output goes on without it. */
const HOST_WAIT_MS = 60000

/** @type {Map<string, Promise<{ mime: string, bytes: Uint8Array }>>} */
const files = new Map()
/** @type {Map<string, Promise<string>>} */
const made = new Map()

const is_dep = (/** @type {string?} */ path) => path != null && path.startsWith("deps/") && !path.split("/").includes("..")

const decode = (/** @type {string} */ data) => Uint8Array.from(atob(data), (c) => c.charCodeAt(0))

const hook = () => {
    const f = /** @type {any} */ (window).ember_dep_file
    return typeof f === "function" ? f : null
}

/** The file at `path` from the host, read once; a failed read is tried again the next time. */
const read = (/** @type {string} */ path) => {
    let file = files.get(path)
    if (file == null) {
        const host = /** @type {(path: string) => any} */ (hook())
        file = Promise.race([
            Promise.resolve(host(path)),
            new Promise((_, reject) => setTimeout(() => reject(new Error(`the host took over ${HOST_WAIT_MS / 1000} s`)), HOST_WAIT_MS)),
        ]).then(({ mime, data }) => ({ mime: mime ?? "", bytes: decode(data) }))
        file.catch(() => files.delete(path))
        files.set(path, file)
    }
    return file
}

/** Each made thing (a script's Blob URL, a stylesheet's text) once per path; a failure is tried again. */
const once = (/** @type {string} */ key, /** @type {() => Promise<string>} */ make) => {
    let thing = made.get(key)
    if (thing == null) {
        thing = make()
        thing.catch(() => made.delete(key))
        made.set(key, thing)
    }
    return thing
}

const script_url = (/** @type {string} */ path) =>
    once(`script ${path}`, async () => {
        const { bytes } = await read(path)
        // Run as a script whatever the host calls it.
        return URL.createObjectURL(new Blob([bytes], { type: "text/javascript" }))
    })

const base64 = (/** @type {Uint8Array} */ bytes) => {
    let s = ""
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, /** @type {any} */ (bytes.subarray(i, i + 0x8000)))
    return btoa(s)
}

/** `href` resolved against the folder of `path`, if it names a file of the same widget. */
const beside = (/** @type {string} */ path, /** @type {string} */ href) => {
    if (/^([a-z][a-z0-9+.-]*:|\/|#)/i.test(href)) return null
    const parts = path.split("/").slice(0, -1)
    for (const part of href.split(/[?#]/)[0].split("/")) {
        if (part === "..") parts.pop()
        else if (part !== "." && part !== "") parts.push(part)
    }
    const resolved = parts.join("/")
    return resolved.startsWith(path.split("/").slice(0, 2).join("/") + "/") && is_dep(resolved) ? resolved : null
}

const stylesheet = (/** @type {string} */ path) =>
    once(`css ${path}`, async () => {
        const css = new TextDecoder().decode((await read(path)).bytes)
        // Images and fonts next to the stylesheet, as data: URLs; one that can't be read stays as it is.
        const refs = [...new Set([...css.matchAll(/url\(\s*(['"]?)([^'")]+)\1\s*\)/g)].map((m) => m[2]))]
        const urls = new Map()
        await Promise.all(
            refs.map(async (ref) => {
                const file = beside(path, ref)
                if (file == null) return
                try {
                    const { mime, bytes } = await read(file)
                    urls.set(ref, `data:${mime || "application/octet-stream"};base64,${base64(bytes)}`)
                } catch (e) {
                    console.warn(`Couldn't get ${file} from the host`, e)
                }
            })
        )
        return css.replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/g, (whole, _q, ref) => (urls.has(ref) ? `url("${urls.get(ref)}")` : whole))
    })

const HELD = "data-ember-dep-href"

/**
 * `html` with each widget stylesheet's href moved aside, so that setting it
 * doesn't start a load the page can't make. `use_host_deps()` puts the file in.
 * `html` as it is without the hook.
 * @param {string} html
 */
export const hold_host_deps = (html) => {
    if (hook() == null || !html.includes("deps/")) return html
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
    if (hook() == null) return
    const elements = [...container.querySelectorAll(`script[src], link[${HELD}]`)]
    await Promise.all(
        elements.map(async (el) => {
            const is_script = el.tagName === "SCRIPT"
            const path = el.getAttribute(is_script ? "src" : HELD)
            if (!is_dep(path)) return
            try {
                if (is_script) {
                    el.setAttribute("src", await script_url(/** @type {string} */ (path)))
                } else {
                    const style = document.createElement("style")
                    style.textContent = await stylesheet(/** @type {string} */ (path))
                    el.replaceWith(style)
                }
            } catch (e) {
                console.warn(`Couldn't get ${path} from the host`, e)
            }
        })
    )
}
