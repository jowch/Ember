import { html, useContext, useEffect, useRef, useState } from "../imports/Preact.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"
import { t } from "../common/lang.js"

/**
 * The question a running cell waits on (#186): `readline()`, `menu()`,
 * `askYesNo()` and the like ask here as they would in an R console. The
 * prompt's text sits before a one-line field; Enter sends the answer. For
 * `menu()`, each choice is also a button that answers with its number. The
 * field takes focus when it appears if the page's focus is in this cell
 * (its code was just run) or nowhere, so typing the answer needs no click.
 *
 * @param {{
 *  cell_id: string,
 *  prompt: { id: number, text: string, choices: string[] },
 * }} props
 */
export const CellPrompt = ({ cell_id, prompt }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const [value, set_value] = useState("")
    const [sent, set_sent] = useState(false)
    const input_ref = useRef(/** @type {HTMLInputElement?} */ (null))

    // A new prompt (menu() asking again has a new id) starts empty.
    useEffect(() => {
        set_value("")
        set_sent(false)
        const input = input_ref.current
        if (input == null) return
        const active = document.activeElement
        if (active == null || active === document.body || input.closest("pluto-cell")?.contains(active)) {
            input.focus({ preventScroll: true })
        }
    }, [prompt.id])

    const answer = (text) => {
        if (sent) return
        set_sent(true)
        pluto_actions.ember_answer_input(cell_id, text)
    }
    const choices = prompt.choices ?? []

    return html`<ember-prompt>
        <form
            onSubmit=${(e) => {
                e.preventDefault()
                answer(value)
            }}
        >
            <label>
                <span class="ember-prompt-text">${prompt.text}</span>
                <input
                    ref=${input_ref}
                    type="text"
                    value=${value}
                    disabled=${sent}
                    autocomplete="off"
                    spellcheck="false"
                    aria-label=${prompt.text.trim() === "" ? t("t_prompt_answer") : prompt.text}
                    onInput=${(e) => set_value(e.target.value)}
                />
            </label>
        </form>
        ${choices.length > 0
            ? html`<div class="ember-prompt-choices" role="group" aria-label=${t("t_prompt_choices")}>
                  ${choices.map(
                      (choice, i) =>
                          html`<button type="button" disabled=${sent} onClick=${() => answer(String(i + 1))}>${choice}</button>`
                  )}
              </div>`
            : null}
        <span class="ember-prompt-hint">${t("t_prompt_hint")}</span>
    </ember-prompt>`
}
