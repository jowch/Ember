import { html, useRef, useState, useContext, useEffect, useLayoutEffect } from "../imports/Preact.js"

import { ANSITextOutput, OutputBody, PlutoImage } from "./CellOutput.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"
import { useEventListener } from "../common/useEventListener.js"
import { is_noop_action } from "../common/SliderServerClient.js"
import { t } from "../common/lang.js"
import { cl } from "../common/ClassTable.js"
import { SafePreviewSanitizeMessage } from "./SafePreviewUI.js"

// this is different from OutputBody because:
// it does not wrap in <div>. We want to do that in OutputBody for reasons that I forgot (feel free to try and remove it), but we dont want it here
// i think this is because i wrote those css classes with the assumption that pluto cell output is wrapped in a div, and tree viewer contents are not
// whatever
//
// We use a `<pre>${body}` instead of `<pre><code>${body}`, also for some CSS reasons that I forgot
//
// TODO: remove this, use OutputBody instead (maybe add a `wrap_in_div` option), and fix the CSS classes so that i all looks nice again
export const SimpleOutputBody = ({ mime, body, cell_id, persist_js_state, sanitize_html = true }) => {
    switch (mime) {
        case "image/png":
        case "image/jpg":
        case "image/jpeg":
        case "image/gif":
        case "image/bmp":
        case "image/svg+xml":
            return html`<${PlutoImage} mime=${mime} body=${body} />`
            break
        case "text/plain":
            // Check if the content contains ANSI escape codes
            return html`<${ANSITextOutput} body=${body} />`
        case "application/vnd.pluto.tree+object":
            return html`<${TreeView} cell_id=${cell_id} body=${body} persist_js_state=${persist_js_state} sanitize_html=${sanitize_html} />`
            break
        case "application/vnd.ember.vector+object":
            return html`<${VectorView} body=${body} />`
        default:
            return OutputBody({ mime, body, cell_id, persist_js_state, sanitize_html, last_run_timestamp: null })
            break
    }
}

const More = ({ on_click_more, disable }) => {
    const [loading, set_loading] = useState(false)
    const element_ref = useRef(/** @type {HTMLElement?} */ (null))
    useKeyboardClickable(element_ref)

    return html`<pluto-tree-more
        ref=${element_ref}
        tabindex=${disable ? "-1" : "0"}
        role="button"
        aria-disabled=${disable ? "true" : "false"}
        disable=${disable}
        class=${loading ? "loading" : disable ? "disabled" : ""}
        onclick=${(e) => {
            if (!loading && !disable) {
                if (on_click_more() !== false) {
                    set_loading(true)
                }
            }
        }}
        >${t("t_tree_show_more_items")}</pluto-tree-more
    >`
}

const useKeyboardClickable = (element_ref) => {
    useEventListener(
        element_ref,
        "keydown",
        (e) => {
            if (e.key === " ") {
                e.preventDefault()
            }
            if (e.key === "Enter") {
                e.preventDefault()
                element_ref.current.click()
            }
        },
        []
    )

    useEventListener(
        element_ref,
        "keyup",
        (e) => {
            if (e.key === " ") {
                e.preventDefault()
                element_ref.current.click()
            }
        },
        []
    )
}

const prefix = ({ prefix, prefix_short }) => {
    const element_ref = useRef(/** @type {HTMLElement?} */ (null))
    useKeyboardClickable(element_ref)
    return html`<pluto-tree-prefix role="button" tabindex="0" ref=${element_ref}
        ><span class="long">${prefix}</span><span class="short">${prefix_short}</span></pluto-tree-prefix
    >`
}

const actions_show_more = ({ pluto_actions, cell_id, node_ref, objectid, dim }) => {
    const actions = pluto_actions ?? node_ref.current.closest("pluto-cell")._internal_pluto_actions
    return actions.reshow_cell(cell_id ?? node_ref.current.closest("pluto-cell").id, objectid, dim)
}

/** A long atomic vector: its first values, then "… int, 100 values". */
export const VectorView = ({ body }) =>
    html`<span class="ember-vector"
        >${(body.values ?? []).map((v) => String(v).trim()).join(" ")} … <span class="ember-vector-count"
            >${t("t_vector_values", { type: body.type_sum, count: body.length })}</span
        ></span
    >`

/** A "Show N more…" text button that asks R for more, busy until the body it belongs to changes. */
const ShowMore = ({ label, on_click, body }) => {
    const [loading, set_loading] = useState(false)
    useEffect(() => set_loading(false), [body])
    return html`<button
        type="button"
        class="ember-show-more"
        aria-busy=${loading ? "true" : "false"}
        onClick=${() => {
            if (loading) return
            set_loading(true)
            Promise.resolve(on_click()).catch(() => set_loading(false))
        }}
    >
        ${label}
    </button>`
}

const RListLeaf = ({ pair, cell_id, persist_js_state, sanitize_html }) => {
    const [body, mime] = pair
    if (mime === "text/plain") return html`<span class="ember-tree-text">${body}</span>`
    return html`<${SimpleOutputBody} cell_id=${cell_id} mime=${mime} body=${body} persist_js_state=${persist_js_state} sanitize_html=${sanitize_html} />`
}

/**
 * An R list (`type: "r_list"`): a row with a disclosure, its key and "list
 * of N", then, when open, one row per item and "Show N more". The root
 * (`item_key` null) starts open, nested lists closed.
 */
const RListTree = ({ body, item_key = null, cell_id, persist_js_state, sanitize_html }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const node_ref = useRef(/** @type {HTMLElement?} */ (null))
    const is_root = item_key == null
    const [open, set_open] = useState(is_root)
    const elements = body.elements ?? []
    const items = elements.filter((r) => r !== "more")
    const length = body.ember_length ?? items.length
    const n_more = Math.max(0, length - items.length)
    const can_load = !is_noop_action(pluto_actions?.reshow_cell) && cell_id !== "cell_id_not_known"

    return html`<pluto-tree class=${cl({ "r_list": true, "ember-tree": true, "collapsed": !open })} ref=${node_ref}>
        <button type="button" class=${cl({ "ember-tree-row": true, "ember-tree-toggle": true, "ember-tree-root": is_root })} aria-expanded=${open ? "true" : "false"} onClick=${() => set_open(!open)}>
            <span class="ember-tree-disc" aria-hidden="true">${open ? "▾" : "▸"}</span>
            ${is_root ? null : html`<span class="ember-tree-key">${item_key}</span>`}
            <span class="ember-tree-what">${t("t_list_of", { count: length })}</span>
        </button>
        ${open
            ? html`<div class="ember-tree-items">
                  ${items.map(([key, pair]) =>
                      pair[1] === "application/vnd.pluto.tree+object" && pair[0]?.type === "r_list"
                          ? html`<${RListTree} body=${pair[0]} item_key=${key} cell_id=${cell_id} persist_js_state=${persist_js_state} sanitize_html=${sanitize_html} />`
                          : html`<div class="ember-tree-row">
                                <span class="ember-tree-disc"></span>
                                <span class="ember-tree-key">${key}</span>
                                <span class="ember-tree-value"><${RListLeaf} pair=${pair} cell_id=${cell_id} persist_js_state=${persist_js_state} sanitize_html=${sanitize_html} /></span>
                            </div>`
                  )}
                  ${n_more > 0 && can_load
                      ? html`<div class="ember-tree-more">
                            <${ShowMore}
                                body=${body}
                                label=${t("t_show_more_items", { count: n_more })}
                                on_click=${() => actions_show_more({ pluto_actions, cell_id, node_ref, objectid: body.objectid, dim: 1 })}
                            />
                        </div>`
                      : null}
              </div>`
            : null}
    </pluto-tree>`
}

export const TreeView = (props) => (props.body?.type === "r_list" ? html`<${RListTree} ...${props} />` : html`<${PlutoTreeView} ...${props} />`)

const PlutoTreeView = ({ mime, body, cell_id, persist_js_state, sanitize_html = true }) => {
    let pluto_actions = useContext(PlutoActionsContext)
    const node_ref = useRef(/** @type {HTMLElement?} */ (null))

    const onclick = (e) => {
        // TODO: this could be reactified but no rush
        let self = node_ref.current
        if (!self) return
        let clicked = e.target.closest("pluto-tree-prefix") != null ? e.target.closest("pluto-tree-prefix").parentElement : e.target
        if (clicked !== self && !self.classList.contains("collapsed")) {
            return
        }
        const parent_tree = self.parentElement?.closest("pluto-tree")
        if (parent_tree != null && parent_tree.classList.contains("collapsed")) {
            return // and bubble upwards
        }

        self.classList.toggle("collapsed")
    }
    const on_click_more = () => {
        if (node_ref.current == null || node_ref.current.closest("pluto-tree.collapsed") != null) {
            return false
        }
        return actions_show_more({
            pluto_actions,
            cell_id,
            node_ref,
            objectid: body.objectid,
            dim: 1,
        })
    }
    const more_is_noop_action = is_noop_action(pluto_actions?.reshow_cell)

    const mimepair_output = (pair) =>
        html`<${SimpleOutputBody} cell_id=${cell_id} mime=${pair[1]} body=${pair[0]} persist_js_state=${persist_js_state} sanitize_html=${sanitize_html} />`
    const more = html`<p-r><${More} disable=${more_is_noop_action || cell_id === "cell_id_not_known"} on_click_more=${on_click_more} /></p-r>`

    let inner = null
    switch (body.type) {
        case "Pair":
            const r = body.key_value
            return html`<pluto-tree-pair class=${body.type}
                ><p-r><p-k>${mimepair_output(r[0])}</p-k><p-v>${mimepair_output(r[1])}</p-v></p-r></pluto-tree-pair
            >`
        case "circular":
            return html`<em>circular reference</em>`
        case "Array":
        case "Set":
        case "Tuple":
            inner = html`<${prefix} prefix=${body.prefix} prefix_short=${body.prefix_short} /><pluto-tree-items class=${body.type}
                    >${body.elements.map((r) =>
                        r === "more" ? more : html`<p-r>${body.type === "Set" ? "" : html`<p-k>${r[0]}</p-k>`}<p-v>${mimepair_output(r[1])}</p-v></p-r>`
                    )}</pluto-tree-items
                >`
            break
        case "Dict":
            inner = html`<${prefix} prefix=${body.prefix} prefix_short=${body.prefix_short} /><pluto-tree-items class=${body.type}
                    >${body.elements.map((r) =>
                        r === "more" ? more : html`<p-r><p-k>${mimepair_output(r[0])}</p-k><p-v>${mimepair_output(r[1])}</p-v></p-r>`
                    )}</pluto-tree-items
                >`
            break
        case "NamedTuple":
            inner = html`<${prefix} prefix=${body.prefix} prefix_short=${body.prefix_short} /><pluto-tree-items class=${body.type}
                    >${body.elements.map((r) =>
                        r === "more" ? more : html`<p-r><p-k>${r[0]}</p-k><p-v>${mimepair_output(r[1])}</p-v></p-r>`
                    )}</pluto-tree-items
                >`
            break
        case "struct":
            inner = html`<${prefix} prefix=${body.prefix} prefix_short=${body.prefix_short} /><pluto-tree-items class=${body.type}
                    >${body.elements.map((r) => html`<p-r><p-k>${r[0]}</p-k><p-v>${mimepair_output(r[1])}</p-v></p-r>`)}</pluto-tree-items
                >`
            break
    }

    return html`<pluto-tree class="collapsed ${body.type}" onclick=${onclick} ref=${node_ref}>${inner}</pluto-tree>`
}

const EmptyCols = ({ colspan = 999 }) =>
    html`<thead>
        <tr class="empty">
            <td colspan=${colspan}>
                <div>⌀ <small>${t("t_table_no_columns")}</small></div>
            </td>
        </tr>
    </thead>`

/** "32 rows × 11 columns" from `ember_size`; older statefiles have `ember_dims`, already in words. */
const table_size_words = (body) => {
    const size = body.ember_size
    if (size == null) return body.ember_dims ?? ""
    return t("t_table_size", { rows: t("t_table_rows", { count: size[0] }), columns: t("t_table_columns", { count: size[1] }) })
}

export const TableView = ({ mime, body, cell_id, persist_js_state, sanitize_html }) => {
    let pluto_actions = useContext(PlutoActionsContext)
    const node_ref = useRef(null)

    const cell_output = (pair) =>
        pair[1] === "text/plain"
            ? pair[0]
            : html`<${SimpleOutputBody} cell_id=${cell_id} mime=${pair[1]} body=${pair[0]} persist_js_state=${persist_js_state} sanitize_html=${sanitize_html} />`
    const show_more = (dim, label) =>
        html`<${ShowMore} body=${body} label=${label} on_click=${() => actions_show_more({ pluto_actions, cell_id, node_ref, objectid: body.objectid, dim })} />`

    const names = (body?.schema?.names ?? []).filter((x) => x !== "more")
    const types = (body?.schema?.types ?? []).filter((x) => x !== "more")
    const rows = (body?.rows ?? []).filter((x) => x !== "more")
    const more_rows = body.ember_size?.[2] ?? 0
    const more_cols = body.ember_size?.[3] ?? 0
    const can_load = !is_noop_action(pluto_actions?.reshow_cell) && cell_id !== "cell_id_not_known"
    const colspan = 1 + names.length

    const thead =
        names.length === 0
            ? html`<${EmptyCols} colspan=${colspan} />`
            : html`<thead>
                  <tr class="schema-names">
                      <th class="ember-table-size">${table_size_words(body)}</th>
                      ${names.map((x) => html`<th>${x}</th>`)}
                  </tr>
                  <tr class="schema-types">
                      <th></th>
                      ${types.map((x) => html`<th>${String(x).replace(/^<(.*)>$/, "$1")}</th>`)}
                  </tr>
              </thead>`

    const tbody = html`<tbody>
        ${rows.map((row, i) => {
            const na = body.ember_na?.[i] ?? []
            return html`<tr>
                <th>${row[0]}</th>
                ${row[1].filter((x) => x !== "more").map((x, j) => html`<td class=${na.includes(j) ? "na" : ""}>${cell_output(x)}</td>`)}
            </tr>`
        })}
    </tbody>`

    return html`<div class="ember-table" ref=${node_ref}>
        <table class="pluto-table">
            ${thead}${tbody}
        </table>
        ${can_load && (more_rows > 0 || more_cols > 0)
            ? html`<div class="ember-table-more">
                  ${more_rows > 0 ? show_more(1, t("t_show_more_rows", { count: more_rows })) : null}
                  ${more_cols > 0 ? show_more(2, t("t_show_more_cols", { count: more_cols })) : null}
              </div>`
            : null}
    </div>`
}

export let ReactDOMElement = ({ cell_id, tag, attributes, children, persist_js_state = false, sanitize_html = true }) => {
    if (sanitize_html) {
        return html`<div dangerouslySetInnerHTML=${SafePreviewSanitizeMessage}></div>`
    }
    const mimepair_output = (pair) => {
        const [body, mime] = pair
        const key = mime === "application/vnd.pluto.reactdomelement+object" ? body?.attributes?.key : undefined
        return html`<${SimpleOutputBody}
            key=${key}
            cell_id=${cell_id}
            mime=${mime}
            body=${body}
            persist_js_state=${persist_js_state}
            sanitize_html=${sanitize_html}
        />`
    }

    return html`<${tag ?? "div"} ...${attributes ?? {}}>${(children ?? []).map(mimepair_output)}<//>`
}
