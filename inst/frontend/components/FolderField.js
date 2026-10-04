import { html, useContext, useEffect, useRef, useState } from "../imports/Preact.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"
import { utf8index_to_ut16index } from "../common/UnicodeTools.js"
import { t } from "../common/lang.js"

/**
 * A folder path field, shown as plain text with a "Change..." link until
 * clicked; clicking turns it into a text input that completes against
 * the server's `completepath` request (`ember_dirs_only: true`), Up/Down
 * to move through the matches, Enter to accept the highlighted one, Esc
 * to close the list without closing whatever this field is part of.
 * Shared by MoveDialog and the start page's New notebook.
 *
 * @param {{
 *   id: string,
 *   label: string,
 *   value: string,
 *   on_change: (value: string) => void,
 *   disabled?: boolean,
 * }} props
 */
export const FolderField = ({ id, label, value, on_change, disabled = false }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const [editing, set_editing] = useState(false)
    const [matches, set_matches] = useState(/** @type {Array<string>} */ ([]))
    const [replace_from, set_replace_from] = useState(0)
    const [highlighted, set_highlighted] = useState(-1)
    const input_ref = useRef(/** @type {HTMLInputElement?} */ (null))

    useEffect(() => {
        if (editing) requestAnimationFrame(() => input_ref.current?.focus())
    }, [editing])

    const query_completions = async (/** @type {string} */ text) => {
        const response = await pluto_actions.send("completepath", { query: text, ember_dirs_only: true })
        const message = response?.message ?? { start: 0, stop: text.length, results: [] }
        set_replace_from(utf8index_to_ut16index(text, message.start))
        set_matches(message.results ?? [])
        set_highlighted(-1)
    }

    const choose = (/** @type {string} */ match) => {
        const next = value.slice(0, replace_from) + match
        on_change(next)
        set_matches([])
        query_completions(next)
    }

    if (!editing) {
        return html`<div class="ember-field">
            <span class="ember-field-label">${label}</span>
            <div class="ember-folder-display mono">
                <span>${value}</span>
                <button type="button" class="ember-link-btn" disabled=${disabled} onClick=${() => set_editing(true)}>${t("t_ember_folder_change")}</button>
            </div>
        </div>`
    }

    return html`<div class="ember-field">
        <label for=${id}>${label}</label>
        <div class="ember-folder-completing">
            <input
                id=${id}
                ref=${input_ref}
                class="ember-text-input mono"
                type="text"
                value=${value}
                disabled=${disabled}
                onInput=${(/** @type {InputEvent} */ e) => {
                    const text = /** @type {HTMLInputElement} */ (e.target).value
                    on_change(text)
                    query_completions(text)
                }}
                onFocus=${(/** @type {FocusEvent} */ e) => query_completions(/** @type {HTMLInputElement} */ (e.target).value)}
                onBlur=${() => setTimeout(() => set_matches([]), 100)}
                onKeyDown=${(/** @type {KeyboardEvent} */ e) => {
                    if (matches.length === 0) return
                    if (e.key === "ArrowDown") {
                        e.preventDefault()
                        set_highlighted((i) => (i + 1) % matches.length)
                    } else if (e.key === "ArrowUp") {
                        e.preventDefault()
                        set_highlighted((i) => (i - 1 + matches.length) % matches.length)
                    } else if (e.key === "Enter" && highlighted >= 0) {
                        e.preventDefault()
                        choose(matches[highlighted])
                    } else if (e.key === "Escape") {
                        e.preventDefault()
                        e.stopPropagation()
                        set_matches([])
                    }
                }}
            />
            ${matches.length > 0 &&
            html`<ul class="ember-folder-matches" role="listbox">
                ${matches.map(
                    (m, i) => html`<li
                        key=${m}
                        role="option"
                        aria-selected=${i === highlighted}
                        class=${i === highlighted ? "highlighted" : ""}
                        onMouseDown=${(/** @type {MouseEvent} */ e) => {
                            e.preventDefault()
                            choose(m)
                        }}
                    >
                        ${m}
                    </li>`
                )}
            </ul>`}
        </div>
    </div>`
}
