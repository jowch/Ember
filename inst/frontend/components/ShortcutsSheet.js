import { html, useState } from "../imports/Preact.js"
import { useEventListener } from "../common/useEventListener.js"
import { t } from "../common/lang.js"
import { Dialog } from "../common/dialogs.js"
import { is_mac_keyboard } from "../common/KeyboardShortcuts.js"

const CLICK = { t: "t_shortcut_key_click" }

/**
 * The sheet's rows, in board Keys6's order. `keys` are for Windows and
 * Linux, `mac` for a Mac; each entry is one `<kbd>`, either the key's own
 * name or `{ t: <english.json key> }` for a word that is translated.
 *
 * @type {Array<{ group: string, rows: Array<{ label: string, keys: Array<string | { t: string }>, mac: Array<string | { t: string }> }> }>}
 */
export const SHORTCUT_GROUPS = [
    {
        group: "t_shortcuts_running",
        rows: [
            { label: "t_shortcut_run", keys: ["Shift", "Enter"], mac: ["Shift", "Enter"] },
            { label: "t_shortcut_run_add", keys: ["Ctrl", "Enter"], mac: ["⌘", "Enter"] },
            { label: "t_shortcut_run_edited", keys: ["Ctrl", "S"], mac: ["⌘", "S"] },
            { label: "t_shortcut_stop", keys: ["Ctrl", "Q"], mac: ["Ctrl", "Q"] },
        ],
    },
    {
        group: "t_shortcuts_cells",
        rows: [
            { label: "t_shortcut_move", keys: ["Alt", "↑ / ↓"], mac: ["⌥", "↑ / ↓"] },
            { label: "t_shortcut_go_to_definition", keys: ["Ctrl", CLICK], mac: ["⌘", CLICK] },
            { label: "t_shortcut_fold", keys: ["Ctrl", "Shift", "[ / ]"], mac: ["⌘", "⌥", "[ / ]"] },
            { label: "t_shortcut_copy_paste", keys: ["Ctrl", "C / V"], mac: ["⌘", "C / V"] },
            { label: "t_shortcut_delete", keys: ["Backspace"], mac: ["Delete"] },
        ],
    },
    {
        group: "t_shortcuts_editing",
        rows: [
            { label: "t_shortcut_complete", keys: ["Ctrl", "Space"], mac: ["Ctrl", "Space"] },
            { label: "t_shortcut_indent", keys: ["Ctrl", "] / ["], mac: ["⌘", "] / ["] },
            { label: "t_shortcut_indent_tab", keys: ["Tab / Shift", "Tab"], mac: ["Tab / ⇧", "Tab"] },
            { label: "t_shortcut_comment", keys: ["Ctrl", "/"], mac: ["⌘", "/"] },
            { label: "t_shortcut_next_match", keys: ["Ctrl", "D"], mac: ["⌘", "D"] },
            { label: "t_shortcut_undo", keys: ["Ctrl", "Z / Y"], mac: ["⌘", "Z / ⇧Z"] },
            { label: "t_shortcut_continue_text", keys: ["#'", "Enter"], mac: ["#'", "Enter"] },
        ],
    },
    {
        group: "t_shortcuts_moving",
        rows: [
            { label: "t_shortcut_page", keys: ["Page Up / Down"], mac: ["fn", "↑ / ↓"] },
            { label: "t_shortcut_leave", keys: ["Esc"], mac: ["Esc"] },
            { label: "t_shortcut_next_control", keys: ["Esc", "Tab"], mac: ["Esc", "Tab"] },
            { label: "t_shortcut_help", keys: ["F1"], mac: ["F1"] },
        ],
    },
]

const key_text = (/** @type {string | { t: string }} */ key) => (typeof key === "string" ? key : t(key.t))

const SheetBody = () => html`
    <div class="ember-shortcuts-grid">
        ${SHORTCUT_GROUPS.map(
            ({ group, rows }) => html`
                <section class="ember-shortcuts-group" aria-labelledby=${`ember-${group}`}>
                    <h3 id=${`ember-${group}`}>${t(group)}</h3>
                    ${rows.map(
                        (row) => html`
                            <div class="ember-shortcuts-row">
                                <span>${t(row.label)}</span>
                                <span class="ember-shortcuts-keys">${(is_mac_keyboard ? row.mac : row.keys).map((k) => html`<kbd>${key_text(k)}</kbd>`)}</span>
                            </div>
                        `
                    )}
                </section>
            `
        )}
    </div>
`

/**
 * The keyboard shortcuts sheet (ui-3.md, Keyboard shortcuts), opened by the
 * window event `"ember open shortcuts"` (the ⋯ menu).
 */
export const ShortcutsSheet = () => {
    const [open, set_open] = useState(false)
    useEventListener(window, "ember open shortcuts", () => set_open(true), [])
    return open
        ? html`<${Dialog}
              class_name="ember-shortcuts"
              title=${t("t_ember_keyboard_shortcuts")}
              title_note=${t("t_shortcuts_esc_closes")}
              on_close=${() => set_open(false)}
              render=${() => html`<${SheetBody} />`}
          />`
        : null
}
