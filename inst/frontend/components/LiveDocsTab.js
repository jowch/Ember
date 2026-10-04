import { html, useState, useRef, useLayoutEffect, useEffect, useMemo, useContext } from "../imports/Preact.js"
import immer from "../imports/immer.js"
import observablehq from "../common/SetupCellEnvironment.js"

import { RawHTMLContainer, highlight } from "./CellOutput.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"
import { cl } from "../common/ClassTable.js"
import { t } from "../common/lang.js"
import { BackIcon, ForwardIcon } from "../common/Icons.js"

const DOCS_RETRY_MS = 1000

/**
 * @param {{
 * focus_on_open: boolean,
 * desired_doc_query: string?,
 * on_update_doc_query: (query: string) => void,
 * notebook: import("./Editor.js").NotebookData,
 * sanitize_html?: boolean,
 * }} props
 */
export let LiveDocsTab = ({ focus_on_open, desired_doc_query, on_update_doc_query, notebook, sanitize_html = true }) => {
    let pluto_actions = useContext(PlutoActionsContext)
    let live_doc_search_ref = useRef(/** @type {HTMLInputElement?} */ (null))

    // Back/forward over every query shown, typed or from the cursor
    // (ui-3-plan.md piece 5's "Help tab"): `history[history_index]` is
    // the current one. `navigating_ref` tells the effect below not to
    // push a new entry for a change it itself caused.
    let [history, set_history] = useState(/** @type {string[]} */ ([]))
    let [history_index, set_history_index] = useState(-1)
    let navigating_ref = useRef(false)

    let go_to = (/** @type {number} */ i) => {
        if (i < 0 || i >= history.length) return
        navigating_ref.current = true
        explicit_ref.current = true
        set_history_index(i)
        on_update_doc_query(history[i])
    }

    // Set by this component's own explicit actions (typing in the search
    // box, Back/Forward) right before they change desired_doc_query, so
    // fetch_docs() can tell those apart from the cursor just moving: the
    // "{{package}} . follows the cursor" line (ui-3-plan.md piece 5's
    // "Help tab") only makes sense for the latter.
    let explicit_ref = useRef(false)

    // This is all in a single state object so that we can update multiple field simultaneously
    let [state, set_state] = useState({
        shown_query: null,
        searched_query: null,
        body: t("t_live_docs_body"),
        package: null,
        from_cursor: false,
        loading: false,
    })
    let update_state = (mutation) => set_state(immer((state) => mutation(state)))

    // An entry only when a docs reply actually succeeds (shown_query
    // changes), not on every keystroke in desired_doc_query: typing
    // "mean" one key at a time must add one history entry, not four.
    useEffect(() => {
        if (state.shown_query == null) return
        if (navigating_ref.current) {
            navigating_ref.current = false
            return
        }
        if (history[history_index] === state.shown_query) return
        set_history((h) => [...h.slice(0, history_index + 1), state.shown_query])
        set_history_index((i) => i + 1)
    }, [state.shown_query])

    useEffect(() => {
        if (state.loading) {
            return
        }
        if (desired_doc_query != null && !/[^\s]/.test(desired_doc_query)) {
            // only whitespace
            return
        }

        if (state.searched_query !== desired_doc_query) {
            fetch_docs(desired_doc_query)
        }
    }, [desired_doc_query, state.loading, state.searched_query])

    useLayoutEffect(() => {
        if (focus_on_open && live_doc_search_ref.current) {
            live_doc_search_ref.current.focus({ preventScroll: true })
            live_doc_search_ref.current.select()
        }
    }, [focus_on_open])

    let retry_timer = useRef(/** @type {any} */ (null))
    useEffect(() => () => clearTimeout(retry_timer.current), [])

    let fetch_docs = (new_query) => {
        const from_cursor = !explicit_ref.current
        explicit_ref.current = false
        update_state((state) => {
            state.loading = true
            state.searched_query = new_query
            state.from_cursor = from_cursor
        })
        Promise.race([
            observablehq.Promises.delay(2000, false),
            pluto_actions.send("docs", { query: new_query.replace(/^\?/, "") }, { notebook_id: notebook.notebook_id }).then((u) => {
                if (u.message.status === "⌛") {
                    // R couldn't answer yet (busy, not started, or slow). The
                    // query only changes when the cursor moves, so ask again.
                    if (u.message.doc != null) {
                        update_state((state) => {
                            state.shown_query = new_query
                            state.body = u.message.doc
                            state.package = u.message.package ?? null
                        })
                    }
                    clearTimeout(retry_timer.current)
                    retry_timer.current = setTimeout(() => {
                        update_state((state) => {
                            if (state.searched_query === new_query) state.searched_query = null
                        })
                    }, DOCS_RETRY_MS)
                    return false
                }
                if (u.message.status === "👍") {
                    // An empty `doc` is a real "not found" (help_reply_html(),
                    // R/editor-services.R, from a worker help_lookup() with
                    // nothing matching): not a page to show or add to history.
                    if (u.message.doc) {
                        update_state((state) => {
                            state.shown_query = new_query
                            state.body = u.message.doc
                            state.package = u.message.package ?? null
                        })
                    }
                    return true
                }
            }),
        ]).then(() => {
            update_state((state) => {
                state.loading = false
            })
        })
    }

    let docs_element = useMemo(
        () => html`<${RawHTMLContainer} body=${state.body} sanitize_html=${sanitize_html} sanitize_html_message=${false} />`,
        [state.body, sanitize_html]
    )
    let no_docs_found = state.loading === false && state.searched_query !== "" && state.searched_query !== state.shown_query

    return html`
        <div class="ember-help-bar">
            <button
                class="ibtn"
                type="button"
                aria-label=${t("t_ember_help_back")}
                disabled=${history_index <= 0}
                onClick=${() => go_to(history_index - 1)}
            >
                <${BackIcon} />
            </button>
            <button
                class="ibtn"
                type="button"
                aria-label=${t("t_ember_help_forward")}
                disabled=${history_index >= history.length - 1}
                onClick=${() => go_to(history_index + 1)}
            >
                <${ForwardIcon} />
            </button>
            <div
                class=${cl({
                    "live-docs-searchbox": true,
                    "loading": state.loading,
                    "notfound": no_docs_found,
                })}
                translate=${false}
            >
                <input
                    title=${no_docs_found ? `"${state.searched_query}" not found` : ""}
                    id="live-docs-search"
                    placeholder=${t("t_live_docs_search_placeholder")}
                    ref=${live_doc_search_ref}
                    onInput=${(e) => {
                        explicit_ref.current = true
                        on_update_doc_query(e.target.value)
                    }}
                    value=${desired_doc_query}
                    type="search"
                ></input>
            </div>
        </div>
        <section ref=${(ref) => ref != null && post_process_doc_node(ref, on_update_doc_query)}>
            ${state.package != null && state.from_cursor
                ? html`<p class="ember-help-package">${t("t_ember_help_follows_cursor", { package: state.package })}</p>`
                : null}
            <h1><code>${state.shown_query}</code></h1>
            ${docs_element}
        </section>
    `
}

const post_process_doc_node = (node, on_update_doc_query) => {
    // Apply syntax highlighting to code blocks:

    // In the standard HTML container we already do this for code.language-julia blocks,
    // but in the docs it's safe to extend to to all highlighting I think
    // Actually, showing the jldoctest stuff wasn't as pretty... should make a mode for that sometimes
    // for (let code_element of container_ref.current.querySelectorAll("code.language-jldoctest")) {
    //     highlight(code_element, "julia")
    // }
    for (let code_element of node.querySelectorAll("code:not([class])")) {
        highlight(code_element, "r")
    }

    // Resolve @doc reference links:
    for (let anchor of node.querySelectorAll("a")) {
        const href = anchor.getAttribute("href")
        if (href != null && href.startsWith("@ref")) {
            const query = href.length > 4 ? href.substr(5) : anchor.textContent
            anchor.onclick = (e) => {
                on_update_doc_query(query)
                e.preventDefault()
            }
        }
    }

    // A notebook function's "Go to it" link (notebook_definition_doc(),
    // R/editor-services.R): scroll to and select the cell that defines it,
    // the same event a Variables name's click dispatches.
    for (let anchor of node.querySelectorAll("a[data-ember-cell]")) {
        const cell_id = anchor.getAttribute("data-ember-cell")
        anchor.onclick = (e) => {
            e.preventDefault()
            window.dispatchEvent(new CustomEvent("cell_focus", { detail: { cell_id, line: 0 } }))
        }
    }
}
