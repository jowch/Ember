import { t } from "../common/lang.js"
import { html } from "../imports/Preact.js"

/**
 * What running would do (ui-2.md, 5), when it's worth saying: `null` when
 * running installs and restarts nothing, otherwise a sentence from
 * `{ install, restart }` (`notebook.ember.plan`, project_ember(),
 * pluto-state.R / packages_view(), packages-core.R).
 * @param {{ install: number, restart: string[] }?} plan
 * @returns {string?}
 */
const plan_text = (plan) => {
    if (plan == null) return null
    if (plan.install > 0) return t("t_ember_safe_preview_plan_install", { count: plan.install })
    if (plan.restart.length > 0) return t("t_ember_safe_preview_plan_restart", { names: plan.restart.join(", ") })
    return null
}

/**
 * One banner under the header while nothing has run (ui-3.md, Header;
 * ui-3-plan.md piece 5's "Safe preview banner"): the sentence from
 * `plan_text()`, and a primary "Run this notebook" that starts R. Replaces
 * the page outline and its info popup; no cell shows "not executed"
 * anymore (Cell.js no longer renders `SafePreviewOutput`).
 *
 * @param {{ process_waiting_for_permission: boolean, restart: () => void, plan: { install: number, restart: string[] }? }} props
 */
export const SafePreviewUI = ({ process_waiting_for_permission, restart, plan }) => {
    if (!process_waiting_for_permission) return null
    return html`
        <div id="ember-safe-preview">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" aria-hidden="true">
                <path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"></path>
            </svg>
            <span>${t("t_ember_safe_preview_banner")}${plan_text(plan) == null ? "" : ` ${plan_text(plan)}`}</span>
            <button class="ember-btn primary" type="button" onClick=${() => restart()}>${t("t_ember_run_this_notebook")}</button>
        </div>
    `
}

/** @type {string} */ // Because this is used as innerHTML content, without preact.
export const SafePreviewSanitizeMessage = `<div class="safe-preview-output">
<span class="offline-icon pluto-icon"></span><span>${t("t_safe_preview_not_rendered")}</span>
</div>`
