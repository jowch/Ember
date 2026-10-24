import { html, useState, useEffect, useRef } from "../imports/Preact.js"
import { cl } from "../common/ClassTable.js"

/**
 * Show a short note in the corner where "Cell deleted · Undo" shows, for
 * an action that otherwise leaves no trace on the page, such as Copy output
 * (#538). The page keeps one; anything can show a note with `toast(text)`.
 */
export const toast = (/** @type {string} */ text) => window.dispatchEvent(new CustomEvent("ember_toast", { detail: text }))

export const Toast = () => {
    const [note, set_note] = useState({ text: "", n: 0 })
    const [hidden, set_hidden] = useState(true)
    const timer = useRef(/** @type {any} */ (null))

    useEffect(() => {
        const on_toast = (/** @type {CustomEvent} */ e) => {
            set_note(({ n }) => ({ text: e.detail, n: n + 1 }))
            set_hidden(false)
            clearTimeout(timer.current)
            timer.current = setTimeout(() => set_hidden(true), 2500)
        }
        window.addEventListener("ember_toast", on_toast)
        return () => {
            window.removeEventListener("ember_toast", on_toast)
            clearTimeout(timer.current)
        }
    }, [])

    // Keeps its text while it fades, as UndoDelete does. Each note is a new
    // span, so a screen reader announces a second "Output copied" too.
    return html`<nav id="ember-toast" role="status" class=${cl({ hidden })}><span key=${note.n}>${note.text}</span></nav>`
}
