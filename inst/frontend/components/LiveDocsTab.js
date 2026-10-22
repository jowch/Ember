import { html, useState, useRef, useLayoutEffect, useEffect, useMemo, useContext } from "../imports/Preact.js"
import immer from "../imports/immer.js"
import observablehq from "../common/SetupCellEnvironment.js"

import { RawHTMLContainer, highlight } from "./CellOutput.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"
import { cl } from "../common/ClassTable.js"
import { t } from "../common/lang.js"
import { BackIcon, ForwardIcon, SearchIcon } from "../common/Icons.js"

const DOCS_RETRY_MS = 1000

// The last docs requests and what came of each, for a host or a test to
// read when the Help tab doesn't show what it should (#110): when each
// went out, its query and scope, and whether a reply came, was too late to
// count, or wasn't waited for. Like window.ember_dialogs (common/dialogs.js).
const docs_log = []
const DOCS_LOG_LENGTH = 50
const note_docs = (/** @type {Record<string, any>} */ entry) => {
    docs_log.push({ at: Math.round(performance.now()), ...entry })
    if (docs_log.length > DOCS_LOG_LENGTH) docs_log.splice(0, docs_log.length - DOCS_LOG_LENGTH)
}
if (!Object.prototype.hasOwnProperty.call(window, "ember_docs")) Object.defineProperty(window, "ember_docs", { value: docs_log })

const escape_html = (/** @type {string} */ s) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)

/**
 * @param {{
 * focus_on_open: boolean,
 * desired_doc_query: string?,
 * doc_query_explicit: boolean,
 * on_update_doc_query: (query: string, explicit?: boolean) => void,
 * notebook: import("./Editor.js").NotebookData,
 * sanitize_html?: boolean,
 * }} props
 */
export let LiveDocsTab = ({ focus_on_open, desired_doc_query, doc_query_explicit, on_update_doc_query, notebook, sanitize_html = true }) => {
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
        set_history_index(i)
        on_update_doc_query(history[i], true)
    }

    // This component's own actions (typing in the search box, Back/Forward,
    // a link clicked in a help page, #30) set the query as explicit, so
    // fetch_docs() can tell them apart from the cursor just moving: only an
    // explicit query searches every installed package, and the
    // "{{package}} . follows the cursor" line (ui-3-plan.md piece 5's
    // "Help tab") only makes sense for the cursor. `doc_query_explicit`
    // comes with the query from the Editor, so it holds for every retry and
    // survives this tab being closed and opened again (#121).
    let follow_link = (/** @type {string} */ query) => on_update_doc_query(query, true)

    // This is all in a single state object so that we can update multiple field simultaneously
    let [state, set_state] = useState({
        shown_query: null,
        searched_query: null,
        body: t("t_live_docs_body"),
        package: null,
        from_cursor: false,
        loading: false,
        waiting: false,
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
    // Each request's number. A reply can come after a later request has
    // gone out (a slow reply loses the race below, and the next query is
    // asked while it's still on the way). Only the latest request's reply
    // may change the page or the retry timer: an older one's "R is busy"
    // would otherwise cancel the current query's retry and leave the
    // panel saying R is busy for good (#132).
    let latest_request = useRef(0)

    let fetch_docs = (new_query) => {
        const from_cursor = !doc_query_explicit
        const request = ++latest_request.current
        update_state((state) => {
            state.loading = true
            state.searched_query = new_query
            state.from_cursor = from_cursor
        })
        note_docs({ request, event: "sent", query: new_query, all_packages: !from_cursor })
        Promise.race([
            observablehq.Promises.delay(2000, "gave up waiting"),
            pluto_actions.send("docs", { query: new_query.replace(/^\?/, ""), all_packages: !from_cursor }, { notebook_id: notebook.notebook_id }).then((u) => {
                note_docs({ request, event: request === latest_request.current ? "reply" : "stale reply", status: u.message.status, has_doc: !!u.message.doc })
                if (request !== latest_request.current) return false
                if (u.message.status === "⌛") {
                    // R couldn't answer yet (busy, not started, or slow). The
                    // query only changes when the cursor moves, so ask again.
                    // The reply is a message about R, not a page for this
                    // query, so it never becomes shown_query or a history entry.
                    if (u.message.doc != null) {
                        update_state((state) => {
                            state.body = u.message.doc
                            state.package = null
                            state.waiting = true
                        })
                    }
                    // The retry asks for the same query, with the scope
                    // that comes with it (#92).
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
                    // The page shown stays, unless it's a message about R
                    // ("R is busy…"), which is no longer true (#121).
                    update_state((state) => {
                        if (!u.message.doc && state.waiting) {
                            state.body = `<p>${t("t_live_docs_not_found", { query: escape_html(new_query) })}</p>`
                            state.package = null
                        }
                        state.waiting = false
                    })
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
        ]).then(
            (result) => {
                if (result === "gave up waiting") note_docs({ request, event: "gave up waiting" })
            },
            (error) => note_docs({ request, event: "failed", error: String(error) })
        ).then(() => {
            update_state((state) => {
                state.loading = false
            })
        })
    }

    let docs_element = useMemo(
        () => html`<${RawHTMLContainer} body=${state.body} sanitize_html=${sanitize_html} sanitize_html_message=${false} />`,
        [state.body, sanitize_html]
    )
    let no_docs_found = state.loading === false && !state.waiting && state.searched_query !== "" && state.searched_query !== state.shown_query

    return html`
        <div class="ember-help-bar">
            <button
                class="ibtn"
                type="button"
                title=${t("t_ember_help_back")}
                aria-label=${t("t_ember_help_back")}
                disabled=${history_index <= 0}
                onClick=${() => go_to(history_index - 1)}
            >
                <${BackIcon} />
            </button>
            <button
                class="ibtn"
                type="button"
                title=${t("t_ember_help_forward")}
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
                <span class="ember-help-search-icon" aria-hidden="true"><${SearchIcon} /></span>
                <input
                    title=${no_docs_found ? `"${state.searched_query}" not found` : ""}
                    id="live-docs-search"
                    placeholder=${t("t_live_docs_search_placeholder")}
                    ref=${live_doc_search_ref}
                    onInput=${(e) => {
                        on_update_doc_query(e.target.value, true)
                    }}
                    value=${desired_doc_query}
                    type="search"
                ></input>
            </div>
        </div>
        <section class="ember-help-page" ref=${(ref) => ref != null && post_process_doc_node(ref, follow_link)}>
            ${state.package != null && state.from_cursor
                ? html`<p class="ember-help-package">${t("t_ember_help_follows_cursor", { package: state.package })}</p>`
                : null}
            ${docs_element}
        </section>
    `
}

const post_process_doc_node = (node, follow_link) => {
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

    // No link in a help page may navigate the editor away (#30). The
    // server already rewrote or unwrapped R's relative links
    // (rewrite_help_links(), R/editor-services.R); what's left is `@ref`
    // (a new query), an anchor on the page, or an external URL.
    for (let anchor of node.querySelectorAll("a")) {
        const href = anchor.getAttribute("href")
        if (href == null || anchor.hasAttribute("data-ember-cell")) continue
        if (href.startsWith("@ref")) {
            const query = href.length > 4 ? href.substr(5) : anchor.textContent
            anchor.onclick = (e) => {
                follow_link(query)
                e.preventDefault()
            }
        } else if (href.startsWith("#")) {
            // A citation's link to its reference: scroll within the page,
            // leaving the URL's hash (Notebook.js reads it as a cell id) alone.
            anchor.onclick = (e) => {
                e.preventDefault()
                const target = href.length > 1 ? node.querySelector(`[id="${CSS.escape(href.substr(1))}"]`) : null
                target?.scrollIntoView({ block: "start" })
            }
        } else {
            anchor.target = "_blank"
            anchor.rel = "noopener noreferrer"
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
