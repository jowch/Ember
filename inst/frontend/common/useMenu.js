import { useMemo, useRef, useState } from "../imports/Preact.js"
import { useEventListener } from "./useEventListener.js"

/**
 * A hook for a button that opens a popup menu: `button_props` go on the
 * trigger, `menu_props` on the `role="menu"` container, `item_props(i)` on
 * each `role="menuitem"` button. Up/Down move between items (wrapping),
 * Home/End jump to the ends, Enter/Space activate (the browser's own
 * `<button>` behaviour, nothing extra to wire). Esc closes and returns
 * focus to the button, same as a click outside; Tab closes and lets focus
 * move on to wherever it would have gone anyway. Callers that want the
 * menu to close after an item is picked call `close()` themselves, since
 * some items (a toggle) may want to leave it open.
 *
 * @param {{ count: number }} options
 */
export const useMenu = ({ count }) => {
    const [is_open, set_is_open] = useState(false)
    const [active_index, set_active_index] = useState(0)
    const button_ref = useRef(/** @type {HTMLElement?} */ (null))
    const menu_ref = useRef(/** @type {HTMLElement?} */ (null))
    const item_refs = useRef(/** @type {Array<HTMLElement?>} */ ([]))

    const focus_item = (/** @type {number} */ i) => {
        set_active_index(i)
        requestAnimationFrame(() => item_refs.current[i]?.focus())
    }

    const { open, close } = useMemo(
        () => ({
            open: () => {
                set_is_open(true)
                focus_item(0)
            },
            close: (/** @type {{ refocus_button?: boolean }} */ { refocus_button = true } = {}) => {
                set_is_open(false)
                if (refocus_button) button_ref.current?.focus()
            },
        }),
        []
    )

    useEventListener(
        window,
        "pointerdown",
        (/** @type {PointerEvent} */ e) => {
            if (!is_open) return
            // @ts-ignore
            if (menu_ref.current?.contains(e.target) || button_ref.current?.contains(e.target)) return
            close()
        },
        [is_open, close]
    )

    const button_props = {
        ref: button_ref,
        "aria-haspopup": "menu",
        "aria-expanded": is_open,
        onClick: () => (is_open ? close() : open()),
        onKeyDown: (/** @type {KeyboardEvent} */ e) => {
            if (!is_open && (e.key === "Enter" || e.key === " " || e.key === "ArrowDown")) {
                e.preventDefault()
                open()
            }
        },
    }

    const menu_props = {
        ref: menu_ref,
        role: "menu",
        onKeyDown: (/** @type {KeyboardEvent} */ e) => {
            if (count === 0) return
            if (e.key === "ArrowDown") {
                e.preventDefault()
                focus_item((active_index + 1) % count)
            } else if (e.key === "ArrowUp") {
                e.preventDefault()
                focus_item((active_index - 1 + count) % count)
            } else if (e.key === "Home") {
                e.preventDefault()
                focus_item(0)
            } else if (e.key === "End") {
                e.preventDefault()
                focus_item(count - 1)
            } else if (e.key === "Escape") {
                // Stops here so Editor's own Esc handler (clearing the
                // selection) doesn't also act on the same keypress.
                e.preventDefault()
                e.stopPropagation()
                close()
            } else if (e.key === "Tab") {
                close({ refocus_button: false })
            }
        },
    }

    const item_props = (/** @type {number} */ i) => ({
        ref: (/** @type {HTMLElement?} */ el) => (item_refs.current[i] = el),
        role: "menuitem",
        tabIndex: i === active_index ? 0 : -1,
        onFocus: () => set_active_index(i),
    })

    return { button_props, menu_props, item_props, open, close, is_open }
}
