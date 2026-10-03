import { html } from "../imports/Preact.js"
import { t } from "../common/lang.js"

/**
 * Placeholder for the Variables tab's frame (ui-3-plan.md piece 5, step 4);
 * the real contents (collecting `cell_results[id].ember.variables` across
 * `cell_order`) are step 8's.
 *
 * @param {{ notebook: import("./Editor.js").NotebookData }} props
 */
export const VariablesTab = ({ notebook }) => {
    return html`<p>${t("t_ember_variables_empty")}</p>`
}
