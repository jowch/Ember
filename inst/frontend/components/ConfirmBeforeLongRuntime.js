import { html, useEffect, useState } from "../imports/Preact.js"
import _ from "../imports/lodash-es.js"

//@ts-ignore
import { useDialog } from "../common/useDialog.js"
import { useEventListener } from "../common/useEventListener.js"
import { t, pretty_long_time } from "../common/lang.js"
import { downstream_recursive } from "../common/SliderServerClient.js"
import { get_settings } from "./Settings.js"

/**
 * @typedef ConfirmEventData
 * @property {number} count cells that would rerun, roots included
 * @property {number} time their runtimes last time, in seconds
 * @property {(result: boolean) => void} on_result
 */

/**
 * Ask before a run whose cells took longer than the setting's seconds last
 * time (Settings: Ask before long runs). True when the person cancels.
 *
 * @param {import("./Editor.js").NotebookData} notebook
 * @param {string[]} cell_ids
 * @returns {Promise<boolean>}
 */
export const maybe_abort_long_runtime = async (notebook, cell_ids) => {
    const settings = get_settings()
    if (!settings.CONFIRM_LONG_RUNTIMES) return false

    const found = downstream_recursive(notebook.cell_dependencies, cell_ids, { recursive: true }).union(new Set(cell_ids))
    const total_runtime = _.sum([...found].map((id) => (notebook.cell_results[id]?.runtime ?? 0) / 1e9))
    if (total_runtime <= settings.CONFIRM_LONG_RUNTIMES_SECONDS) return false

    const confirmed = await new Promise((resolve) => {
        window.dispatchEvent(
            new CustomEvent("confirm before long runtime", {
                detail: /** @type {ConfirmEventData} */ ({ count: found.size, time: total_runtime, on_result: resolve }),
            })
        )
    })
    return !confirmed
}

export const ConfirmBeforeLongRuntime = () => {
    const [dialog_ref, open, close, _toggle, currently_open] = useDialog()
    const [detail, set_detail] = useState(/** @type {ConfirmEventData | undefined} */ (undefined))

    useEventListener(
        window,
        "confirm before long runtime",
        (/** @type {CustomEvent} */ e) => {
            set_detail(e.detail)
            open()
        },
        [open, set_detail]
    )

    // Esc, Cancel and Run all close the dialog; only Run answers first, so
    // this is a no-op after it.
    useEffect(() => {
        if (!currently_open) detail?.on_result(false)
    }, [currently_open])

    return html`<dialog ref=${dialog_ref} class="confirm-before-long-runtime" aria-describedby="ember-long-run-text">
        <p id="ember-long-run-text">${t("t_confirm_long_run", { count: detail?.count ?? 0, time: pretty_long_time(detail?.time ?? 0) })}</p>
        <div class="ember-dialog-actions">
            <button type="button" class="ember-btn" onClick=${close}>${t("t_cancel")}</button>
            <button
                type="button"
                class="ember-btn primary"
                autofocus
                onClick=${() => {
                    detail?.on_result(true)
                    close()
                }}
            >
                ${t("t_run")}
            </button>
        </div>
    </dialog>`
}
