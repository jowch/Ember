import { html, useEffect, useRef, useState } from "../imports/Preact.js"
import { cl } from "../common/ClassTable.js"

import { LiveDocsTab } from "./LiveDocsTab.js"
import { PackagesTab } from "./PackagesTab.js"
import { StatusTab } from "./StatusTab.js"
import { VariablesTab } from "./VariablesTab.js"
import { useMyClockIsAheadBy } from "../common/clock_sync.js"
import { useEventListener } from "../common/useEventListener.js"
import { t } from "../common/lang.js"

/**
 * @typedef PanelTabName
 * @type {"variables" | "docs" | "packages" | "process" | null}
 */

export const open_bottom_right_panel = (/** @type {PanelTabName} */ tab) => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: tab }))

/** The width from which the panel docks beside the column (editor.css's 1239px query). */
const DOCKED_QUERY = "(min-width: 1240px)"

const read_stored = (/** @type {string} */ key) => {
    try {
        return localStorage.getItem(key)
    } catch (e) {
        return null
    }
}
const write_stored = (/** @type {string} */ key, /** @type {string} */ value) => {
    try {
        localStorage.setItem(key, value)
    } catch (e) {}
}

/**
 * The tab this browser last had open, else Variables.
 * @returns {Exclude<PanelTabName, null>}
 */
export const last_panel_tab = () => {
    const tab = read_stored("ember_panel_tab")
    return tab === "variables" || tab === "docs" || tab === "packages" || tab === "process" ? tab : "variables"
}

/** @type {PanelTabName | undefined} */
let load_tab = undefined

/**
 * The tab open when the page loads: the last one used, if the panel fits
 * docked and the viewer didn't close it last time; otherwise none.
 * Computed once, so the header and the panel start out agreeing.
 * @returns {PanelTabName}
 */
export const initial_panel_tab = () => {
    if (load_tab === undefined) load_tab = window.matchMedia(DOCKED_QUERY).matches && read_stored("ember_panel_open") !== "false" ? last_panel_tab() : null
    return load_tab
}

const TABS = /** @type {const} */ ([
    ["variables", "t_panel_variables"],
    ["docs", "t_panel_docs"],
    ["packages", "t_panel_packages"],
    ["process", "t_panel_status_short"],
])

/**
 * The side panel (ui-3.md, Side panel): docked in the free space from
 * 1240 px, a slide-over below that, a bottom sheet at 640 px and
 * narrower. Four tabs: Variables, Help ("docs"), Packages, Status
 * ("process"; the two names are kept because Endeavor's drawer sends
 * "docs" and `open_bottom_right_panel`'s detail is part of its contract,
 * ui-3-plan.md piece 5's "Rules touched").
 *
 * @param {{
 * notebook: import("./Editor.js").NotebookData,
 * desired_doc_query: string?,
 * on_update_doc_query: (query: string?) => void,
 * connected: boolean,
 * sanitize_html?: boolean,
 * on_restart: () => void,
 * }} props
 */
export let BottomRightPanel = ({ desired_doc_query, on_update_doc_query, notebook, connected, sanitize_html = true, on_restart }) => {
    const container_ref = useRef()
    const focus_docs_on_open_ref = useRef(false)
    const opener_ref = useRef(/** @type {HTMLElement?} */ (null))
    const [open_tab, set_open_tab] = useState(initial_panel_tab)
    const hidden = open_tab == null

    useEventListener(
        window,
        "open_bottom_right_panel",
        (/** @type {CustomEvent} */ e) => {
            focus_docs_on_open_ref.current = e.detail === "docs"
            const active = /** @type {HTMLElement?} */ (document.activeElement)
            if (e.detail != null && !container_ref.current?.contains(active)) opener_ref.current = active != null && active !== document.body ? active : null
            write_stored("ember_panel_open", String(e.detail != null))
            if (e.detail != null) write_stored("ember_panel_tab", e.detail)
            set_open_tab(e.detail)
        },
        [set_open_tab]
    )

    const on_keydown = (/** @type {KeyboardEvent} */ e) => {
        if (e.key !== "Escape" || e.defaultPrevented || hidden) return
        e.preventDefault()
        open_bottom_right_panel(null)
        opener_ref.current?.focus()
    }

    const my_clock_is_ahead_by = useMyClockIsAheadBy({ connected })

    return html`
        <aside id="helpbox-wrapper" class=${cl({ open: !hidden })} ref=${container_ref} onKeyDown=${on_keydown}>
            <pluto-helpbox class=${cl({ hidden, [`helpbox-${open_tab}`]: open_tab != null })}>
                <header translate=${false} role="tablist" aria-label=${t("t_panel_tablist")}>
                    ${TABS.map(
                        ([tab, label_key]) => html`
                            <button
                                class=${cl({ tab: true, on: open_tab === tab })}
                                type="button"
                                role="tab"
                                aria-selected=${open_tab === tab}
                                onClick=${() => open_bottom_right_panel(tab)}
                            >
                                ${t(label_key)}
                            </button>
                        `
                    )}
                </header>
                <section role="tabpanel">
                    ${open_tab === "variables"
                        ? html`<${VariablesTab} notebook=${notebook} />`
                        : open_tab === "docs"
                          ? html`<${LiveDocsTab}
                                focus_on_open=${focus_docs_on_open_ref.current}
                                desired_doc_query=${desired_doc_query}
                                on_update_doc_query=${on_update_doc_query}
                                notebook=${notebook}
                                sanitize_html=${sanitize_html}
                            />`
                          : open_tab === "packages"
                            ? html`<${PackagesTab} packages=${notebook.ember?.packages} />`
                            : open_tab === "process"
                              ? html`<${StatusTab} notebook=${notebook} connected=${connected} my_clock_is_ahead_by=${my_clock_is_ahead_by} on_restart=${on_restart} />`
                              : null}
                </section>
            </pluto-helpbox>
        </aside>
        ${hidden ? null : html`<div class="ember-scrim" onClick=${() => open_bottom_right_panel(null)} aria-hidden="true"></div>`}
    `
}

export const useDelayedTruth = (/** @type {boolean} */ x, /** @type {number} */ timeout) => {
    const [output, set_output] = useState(false)

    useEffect(() => {
        if (x) {
            let handle = setTimeout(() => {
                set_output(true)
            }, timeout)
            return () => clearTimeout(handle)
        } else {
            set_output(false)
        }
    }, [x])

    return output
}
