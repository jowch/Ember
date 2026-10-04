import { t } from "../common/lang.js"
import { html } from "../imports/Preact.js"
import { useDelayedTruth } from "./BottomRightPanel.js"
import { scroll_cell_into_view } from "./Scroller.js"
import { use_run_progress } from "../common/use_run_progress.js"

/**
 * @param {{
 * notebook: import("./Editor.js").NotebookData,
 * }} props
 */
export const ProgressBar = ({ notebook }) => {
    const { i, n, recently_running, currently_running } = use_run_progress(notebook)

    let progress = recently_running.length === 0 ? 0 : 1 - Math.max(0, currently_running.length - 0.3) / recently_running.length

    const anything = recently_running.length !== 0 && progress !== 1
    // Double inversion with ! to short-circuit the true, not the false
    const anything_for_a_short_while = !useDelayedTruth(!anything, 500)
    const anything_for_a_long_while = !useDelayedTruth(!anything, 2000)

    if (!(anything || anything_for_a_short_while || anything_for_a_long_while)) {
        return null
    }

    // set to 1 when all cells completed, instead of moving the progress bar to the start
    if (anything_for_a_short_while && recently_running.length === 0) {
        progress = 1
    }

    return html`<loading-bar
        class="fast"
        style=${`
            width: ${100 * progress}vw; 
            opacity: ${anything && anything_for_a_short_while ? 1 : 0};
            ${anything || anything_for_a_short_while ? "" : "transition: none;"}
            pointer-events: ${anything ? "auto" : "none"};
            cursor: ${anything ? "pointer" : "auto"};
        `}
        onClick=${() => scroll_to_busy_cell(notebook)}
        aria-hidden="true"
        title=${t("t_ember_r_status_busy", { i, n })}
    ></loading-bar>`
}

export const scroll_to_busy_cell = (notebook) => {
    const running_cell_id =
        notebook == null
            ? (document.querySelector("pluto-cell.running") ?? document.querySelector("pluto-cell.queued"))?.id
            : (Object.values(notebook.cell_results).find((c) => c.running) ?? Object.values(notebook.cell_results).find((c) => c.queued))?.cell_id
    if (running_cell_id) {
        scroll_cell_into_view(running_cell_id)
    }
}
