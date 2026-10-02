import { html, useContext } from "../imports/Preact.js"
import { t } from "../common/lang.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"

/**
 * "N cells not run · Run all" (ui-2.md, 5): shown above the notebook once R
 * has started and some code cells haven't run since (`notebook.ember.not_run`,
 * which is 0 in safe preview). "Run all" sends `ember_run_all`, which the
 * server answers by running exactly this set (and what they need) -- never
 * every cell, so a cell already up to date keeps its result.
 *
 * @param {{ not_run: number }} props
 */
export const NotRunBar = ({ not_run }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    if (!(not_run > 0)) return null
    return html`
        <div id="ember-not-run-bar">
            <span>${t("t_ember_not_run", { count: not_run })}</span>
            <span aria-hidden="true">·</span>
            <button onClick=${() => pluto_actions.ember_run_all()}>${t("t_ember_run_all")}</button>
        </div>
    `
}
