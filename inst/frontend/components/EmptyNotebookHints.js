import { html } from "../imports/Preact.js"
import { th } from "../common/lang.js"
import { ctrl_or_cmd_name } from "../common/KeyboardShortcuts.js"

/**
 * The three hints under the only cell of an empty notebook (ui-3.md,
 * "Empty notebook"). Notebook.js renders this once, after the cells.
 */
export const EmptyNotebookHints = () => html`
    <ember-empty-hints>
        <span>${th("t_hint_run")}</span>
        <span>${th("t_hint_run_add", { mod: ctrl_or_cmd_name })}</span>
        <span>${th("t_hint_text")}</span>
    </ember-empty-hints>
`
