import "../imports/RequestIdleCallbackPolyfill.js"
import { get_included_external_source } from "./external_source.js"

/** @type {Promise<void>?} */
let loading = null

/** Load MathJax from its CDN the first time it is needed; later calls return the same promise, until a load fails. */
export const load_mathjax = () => {
    loading ??= new Promise((resolve, reject) => setup_mathjax(resolve, reject)).catch((err) => {
        loading = null
        throw err
    })
    return loading
}

const setup_mathjax = (resolve, reject) => {
    const deprecated = () =>
        console.error("Ember loads MathJax 3 for TeX in outputs, but an output called a MathJax 2 function. The two versions can't be used on the same page.")
    // @ts-ignore
    if (window.MathJax != null && window.MathJax.startup == null) {
        return reject(new Error("An output loaded MathJax 2, so Ember can't load MathJax 3 to show TeX."))
    }

    // @ts-ignore
    window.MathJax = {
        options: {
            ignoreHtmlClass: "no-MαθJax",
            processHtmlClass: "tex",
        },
        startup: {
            typeset: false,
            ready: () => {
                // @ts-ignore
                window.MathJax.startup.defaultReady()

                // plotly uses MathJax 2, so we have this shim to make it work kindof
                // @ts-ignore
                window.MathJax.Hub = {
                    Queue: function () {
                        for (var i = 0, m = arguments.length; i < m; i++) {
                            // @ts-ignore
                            var fn = window.MathJax.Callback(arguments[i])
                            // @ts-ignore
                            window.MathJax.startup.promise = window.MathJax.startup.promise.then(fn)
                        }
                        // @ts-ignore
                        return window.MathJax.startup.promise
                    },
                    Typeset: function (elements, callback) {
                        // @ts-ignore
                        var promise = window.MathJax.typesetPromise(elements)
                        if (callback) {
                            promise = promise.then(callback)
                        }
                        return promise
                    },
                    Register: {
                        MessageHook: deprecated,
                        StartupHook: deprecated,
                        LoadHook: deprecated,
                    },
                    Config: deprecated,
                    Configured: deprecated,
                    setRenderer: deprecated,
                }
            },
        },
        tex: {
            inlineMath: [
                ["$", "$"],
                ["\\(", "\\)"],
            ],
        },
        svg: {
            fontCache: "global",
        },
    }

    const src = get_included_external_source("MathJax-script")
    if (!src) return reject(new Error("Could not find mathjax source"))

    const script = document.createElement("script")
    script.addEventListener("load", () => {
        // @ts-ignore
        const promise = window.MathJax?.startup?.promise
        if (promise == null) return reject(new Error("An output loaded MathJax 2, so Ember can't load MathJax 3 to show TeX."))
        promise.then(resolve, reject)
    })
    script.addEventListener("error", () => {
        script.remove()
        reject(new Error("MathJax failed to load"))
    })
    script.crossOrigin = src.crossOrigin
    script.integrity = src.integrity
    script.src = src.href
    document.head.append(script)
}
