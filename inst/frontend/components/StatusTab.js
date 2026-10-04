import { html, useContext, useEffect, useState } from "../imports/Preact.js"

import { prettytime, useMillisSinceTruthy } from "./RunArea.js"
import { scroll_cell_into_view } from "./Scroller.js"
import { use_r_status } from "./Header.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"
import { t } from "../common/lang.js"

/** `ember.r_version` is `R.version.string` ("R version 4.6.1 (2026-06-24)"),
 * the worker's own report (worker.R); shown as "R 4.6.1". */
const r_version_short = (/** @type {string?} */ r_version) => {
    if (r_version == null) return null
    const m = r_version.match(/[\d.]+/)
    return m == null ? r_version : `R ${m[0]}`
}

/** "14 minutes ago", re-rendered every 30s so it stays roughly right
 * without a per-second timer. `started_at` and `my_clock_is_ahead_by`
 * are both in seconds (Date.now()/1000, matching `ember.worker_started_at`
 * and `useMyClockIsAheadBy`). */
const useStartedAgo = (/** @type {number?} */ started_at, /** @type {number} */ my_clock_is_ahead_by) => {
    const [now, set_now] = useState(() => Date.now() / 1000)
    useEffect(() => {
        const handle = setInterval(() => set_now(Date.now() / 1000), 30000)
        return () => clearInterval(handle)
    }, [])
    if (started_at == null) return null
    const seconds = Math.max(0, now - my_clock_is_ahead_by - started_at)
    const minutes = Math.round(seconds / 60)
    if (minutes < 1) return t("t_ember_started_just_now")
    return t("t_ember_started_minutes_ago", { count: minutes })
}

/**
 * The "Status" tab (ui-3.md, Side panel; ui-3-plan.md piece 5's "Status
 * tab"): R's state, memory, version and uptime with Interrupt/Restart R;
 * the notebook's not-run and error counts; the autorun/lazy mode.
 *
 * @param {{
 * notebook: import("./Editor.js").NotebookData,
 * connected: boolean,
 * my_clock_is_ahead_by: number,
 * on_restart: () => void,
 * }} props
 */
export const StatusTab = ({ notebook, connected, my_clock_is_ahead_by, on_restart }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const status = use_r_status({ connected, notebook })
    const busy = notebook.ember?.process === "busy"

    // The running cell's own start (ui-3-plan.md piece 5's "Status tab"),
    // not just "R is busy": two cells back to back without R ever going
    // idle in between must not add up as one continuous run.
    const running_id = notebook.cell_order.find((id) => notebook.cell_results[id]?.running)
    const local_running_ms = useMillisSinceTruthy(running_id ?? false)
    const running_seconds = local_running_ms == null ? null : local_running_ms / 1000

    const started_ago = useStartedAgo(notebook.ember?.worker_started_at ?? null, my_clock_is_ahead_by)
    const worker_memory = notebook.ember?.worker_memory
    const memory_mb = worker_memory == null ? null : Math.round(worker_memory / 1024 / 1024)

    const cells = notebook.cell_order.length
    const not_run = notebook.ember?.not_run ?? 0
    const errored_id = notebook.cell_order.find((id) => notebook.cell_results[id]?.errored)
    const errors = notebook.cell_order.filter((id) => notebook.cell_results[id]?.errored).length

    const restart = notebook.ember?.plan?.restart ?? []
    const on_cell_change = notebook.ember?.on_cell_change ?? "autorun"
    const read_only = notebook.ember?.read_only === true

    return html`
        <div id="ember-status-tab">
            <section class="ember-status-section">
                <h3 class="ember-status-h3">${t("t_ember_status_r")}</h3>
                <div class="ember-status-kv">
                    <span>${t("t_ember_status_state")}</span>
                    <span class="ember-status-state">
                        <span class=${`ember-dot ember-dot-${status.dot}`} aria-hidden="true"></span>
                        ${status.words}${busy && running_seconds != null ? ` · ${prettytime(running_seconds * 1e9)}` : null}
                    </span>
                    <span>${t("t_ember_status_memory")}</span>
                    <span>${memory_mb == null ? "—" : t("t_ember_memory_value", { mb: memory_mb })}</span>
                    <span>${t("t_ember_status_version")}</span>
                    <span>${r_version_short(notebook.ember?.r_version) ?? "—"}</span>
                    <span>${t("t_ember_status_started")}</span>
                    <span>${started_ago ?? "—"}</span>
                </div>
                <div class="ember-status-buttons">
                    <button class="ember-btn" type="button" disabled=${!busy} onClick=${() => pluto_actions.interrupt_remote()}>
                        ${t("t_ember_status_interrupt")}
                    </button>
                    <button id="ember-status-restart" class="ember-btn" type="button" onClick=${() => on_restart()}>${t("t_ember_status_restart")}</button>
                </div>
                <span class="ember-status-hint">
                    ${restart.length > 0 ? t("t_ember_r_status_restart_title", { names: restart.join(", ") }) : t("t_ember_status_restart_hint")}
                </span>
            </section>
            <div class="ember-status-rule"></div>
            <section class="ember-status-section">
                <h3 class="ember-status-h3">${t("t_ember_status_notebook")}</h3>
                <div class="ember-status-kv">
                    <span>${t("t_ember_status_cells")}</span>
                    <span>${cells}</span>
                    <span>${t("t_ember_status_not_run")}</span>
                    <span class="ember-status-count-link">
                        ${not_run}
                        ${not_run > 0 ? html`<a href="#" onClick=${(e) => { e.preventDefault(); pluto_actions.ember_run_all() }}>${t("t_ember_status_run_them")}</a>` : null}
                    </span>
                    <span>${t("t_ember_status_errors")}</span>
                    <span class="ember-status-count-link">
                        ${errors}
                        ${errored_id != null
                            ? html`<a href="#" onClick=${(e) => { e.preventDefault(); scroll_cell_into_view(errored_id) }}>${t("t_ember_status_go_to_it")}</a>`
                            : null}
                    </span>
                </div>
            </section>
            <div class="ember-status-rule"></div>
            <fieldset class="ember-status-mode" disabled=${read_only}>
                <legend class="ember-status-h3">${t("t_ember_status_mode_legend")}</legend>
                <label class="ember-status-radio">
                    <input
                        type="radio"
                        name="ember-on-cell-change"
                        checked=${on_cell_change === "autorun"}
                        onInput=${() => pluto_actions.ember_set_mode("autorun")}
                    />
                    ${t("t_ember_status_mode_autorun")}
                </label>
                <label class="ember-status-radio">
                    <input
                        type="radio"
                        name="ember-on-cell-change"
                        checked=${on_cell_change === "lazy"}
                        onInput=${() => pluto_actions.ember_set_mode("lazy")}
                    />
                    ${t("t_ember_status_mode_lazy")}
                </label>
            </fieldset>
        </div>
    `
}

/**
 * @param {import("./Editor.js").StatusEntryData} status
 */
export const is_finished = (status) => status.finished_at != null

/**
 * @param {import("./Editor.js").StatusEntryData} status
 * @returns {number}
 */
export const total_done = (status) => Object.values(status.subtasks).reduce((total, status) => total + total_done(status), is_finished(status) ? 1 : 0)
