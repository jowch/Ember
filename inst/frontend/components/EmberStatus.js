import { html } from "../imports/Preact.js"
import { t } from "../common/lang.js"

/**
 * "R · 412 MB" next to the process status (ui-2.md, 5): the worker's
 * last-reported memory, with a tooltip explaining why it only grows, and a
 * restart link to free it. Nothing in safe preview: `worker_memory` is
 * `null` there, and stays `null` until the current worker has reported once.
 *
 * @param {{ worker_memory: number?, restart: () => void }} props
 */
export const EmberStatus = ({ worker_memory, restart }) => {
    if (worker_memory == null) return null
    const mb = Math.round(worker_memory / 1024 / 1024)
    return html`
        <div id="ember-status" title=${t("t_ember_memory_tooltip")}>
            <span>${t("t_ember_memory", { mb })}</span>
            <span aria-hidden="true"> · </span>
            <a
                href="#"
                id="ember-status-restart"
                onClick=${(e) => {
                    e.preventDefault()
                    restart()
                }}
                >${t("t_process_restart_action_short")}</a
            >
        </div>
    `
}
