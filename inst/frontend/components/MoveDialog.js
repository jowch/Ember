import { html, useContext, useState } from "../imports/Preact.js"
import { Dialog } from "../common/dialogs.js"
import { FolderField } from "./FolderField.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"
import { t } from "../common/lang.js"

/**
 * Rename or move a notebook, opened from the header's file name button in
 * place of the old FilePicker. Built on dialogs.js's `Dialog` shell: Name
 * and Folder (`FolderField`), the note that the notebook stays open and a
 * relative-path read follows the move, then Cancel/Save. The file moves;
 * the worker keeps running and its working directory follows (chdir,
 * step.R's `reduce_move()`).
 *
 * @param {{ path: string, shortpath: string, on_close: () => void }} props
 */
export const MoveDialog = ({ path, shortpath, on_close }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const [name, set_name] = useState(shortpath)
    const [folder, set_folder] = useState(dirname(path))
    const [error, set_error] = useState(/** @type {string?} */ (null))
    const [saving, set_saving] = useState(false)

    return html`<${Dialog}
        title=${t("t_ember_move_title")}
        on_close=${on_close}
        render=${({ close }) => html`
            <div class="ember-field">
                <label for="ember-move-name">${t("t_ember_move_name")}</label>
                <input
                    id="ember-move-name"
                    class="ember-text-input mono"
                    type="text"
                    value=${name}
                    disabled=${saving}
                    onInput=${(/** @type {InputEvent} */ e) => set_name(/** @type {HTMLInputElement} */ (e.target).value)}
                />
            </div>
            <${FolderField} id="ember-move-folder" label=${t("t_ember_move_folder")} value=${folder} on_change=${set_folder} disabled=${saving} />
            <p class="ember-dialog-text">${t("t_ember_move_note")}</p>
            ${error != null && html`<p class="ember-dialog-text ember-dialog-error">${error}</p>`}
            <div class="ember-dialog-actions">
                <button type="button" class="ember-btn" disabled=${saving} onClick=${close}>${t("t_cancel")}</button>
                <button
                    type="button"
                    class="ember-btn primary"
                    disabled=${saving || !name.trim()}
                    onClick=${async () => {
                        set_saving(true)
                        set_error(null)
                        try {
                            const response = await pluto_actions.ember_move_notebook(name, folder)
                            if (response?.message?.error != null) {
                                set_error(t("t_move_file_failed", { reason: response.message.error, interpolation: { escapeValue: false } }))
                            } else {
                                close()
                            }
                        } finally {
                            set_saving(false)
                        }
                    }}
                >
                    ${t("t_ember_move_save")}
                </button>
            </div>
        `}
    />`
}

/** The folder part of a path, forward-slash only (as Ember's own paths are on the wire). */
const dirname = (/** @type {string} */ path) => {
    const i = path.lastIndexOf("/")
    return i < 0 ? path : path.slice(0, i)
}
