import { html, useEffect, useRef, useState } from "../imports/Preact.js"
import { cl } from "../common/ClassTable.js"

import { LiveDocsTab } from "./LiveDocsTab.js"
import { PackagesTab } from "./PackagesTab.js"
import { StatusTab } from "./StatusTab.js"
import { VariablesTab } from "./VariablesTab.js"
import { useMyClockIsAheadBy } from "../common/clock_sync.js"
import { useEventListener } from "../common/useEventListener.js"
import { t } from "../common/lang.js"
import { NotifyWhenDone } from "./NotifyWhenDone.js"
import { get_settings } from "./Settings.js"

/**
 * @typedef PanelTabName
 * @type {"variables" | "docs" | "packages" | "process" | null}
 */

export const open_bottom_right_panel = (/** @type {PanelTabName} */ tab) => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: tab }))

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
    const [open_tab, set_open_tab] = useState(/** @type { PanelTabName} */ (null))
    const hidden = open_tab == null

    useEventListener(
        window,
        "open_bottom_right_panel",
        (/** @type {CustomEvent} */ e) => {
            focus_docs_on_open_ref.current = e.detail === "docs"
            set_open_tab(e.detail)
        },
        [set_open_tab]
    )

    const status = notebook.status_tree
    const my_clock_is_ahead_by = useMyClockIsAheadBy({ connected })

    return html`
        <aside id="helpbox-wrapper" class=${cl({ open: !hidden })} ref=${container_ref}>
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
                              ? html`<${StatusTab} notebook=${notebook} my_clock_is_ahead_by=${my_clock_is_ahead_by} on_restart=${on_restart} />`
                              : null}
                    ${get_settings().ALWAYS_NOTIFY_LONG_BUSY && open_tab !== "process"
                        ? html`<div style="display: none" aria-hidden="true"><${NotifyWhenDone} status=${status} /></div>`
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
