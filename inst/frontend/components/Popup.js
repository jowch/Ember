import { html, useState, useRef, useCallback, useLayoutEffect } from "../imports/Preact.js"
import { cl } from "../common/ClassTable.js"

import { useEventListener } from "../common/useEventListener.js"

/**
 * @typedef MiscPopupDetails
 * @property {"info" | "warn"} type
 * @property {import("../imports/Preact.js").ReactElement} body
 * @property {HTMLElement?} [source_element]
 * @property {string} [css_class]
 * @property {Boolean} [big]
 * @property {Boolean} [should_focus] Should the popup receive keyboard focus after opening? Rule of thumb: yes if the popup opens on a click, no if it opens spontaneously.
 */

export const Popup = () => {
    const [recent_event, set_recent_event] = useState(/** @type{MiscPopupDetails?} */ (null))
    const recent_event_ref = useRef(/** @type{MiscPopupDetails?} */ (null))
    recent_event_ref.current = recent_event
    const recent_source_element_ref = useRef(/** @type{HTMLElement?} */ (null))
    const pos_ref = useRef("")

    const open = useCallback(
        (/** @type {CustomEvent} */ e) => {
            const el = e.detail.source_element
            recent_source_element_ref.current = el

            if (el == null) {
                pos_ref.current = `top: 20%; left: 50%; transform: translate(-50%, -50%); position: fixed;`
            } else {
                const elb = el.getBoundingClientRect()
                const bodyb = document.body.getBoundingClientRect()

                pos_ref.current = `top: ${0.5 * (elb.top + elb.bottom) - bodyb.top}px; left: min(max(0px,100vw - 251px - 30px), ${elb.right - bodyb.left}px);`
            }

            set_recent_event(e.detail)
        },
        [set_recent_event]
    )

    const close = useCallback(() => {
        set_recent_event(null)
    }, [set_recent_event])

    useEventListener(window, "open pluto popup", open, [open])
    useEventListener(window, "close pluto popup", close, [close])
    useEventListener(
        window,
        "pointerdown",
        (e) => {
            if (recent_event_ref.current == null) return
            if (e.target == null) return
            if (e.target.closest("pluto-popup") != null) return
            if (recent_source_element_ref.current != null && recent_source_element_ref.current.contains(e.target)) return

            close()
        },
        [close]
    )
    useEventListener(
        window,
        "keydown",
        (e) => {
            if (e.key === "Escape") close()
        },
        [close]
    )

    // focus the popup when it opens
    const element_focused_before_popup = useRef(/** @type {any} */ (null))
    useLayoutEffect(() => {
        if (recent_event != null) {
            if (recent_event.should_focus === true) {
                requestAnimationFrame(() => {
                    element_focused_before_popup.current = document.activeElement
                    /** @type {HTMLElement?} */
                    const el = element_ref.current?.querySelector("a, input, button") ?? element_ref.current
                    // console.debug("restoring focus to", el)
                    el?.focus?.()
                })
            } else {
                element_focused_before_popup.current = null
            }
        }
    }, [recent_event != null])

    const element_ref = useRef(/** @type {HTMLElement?} */ (null))

    // if the popup was focused on opening:
    // when the popup loses focus (and the focus did not move to the source element):
    // 1. close the popup
    // 2. return focus to the element that was focused before the popup opened
    useEventListener(
        element_ref.current,
        "focusout",
        (e) => {
            if (recent_event_ref.current != null && recent_event_ref.current.should_focus === true) {
                if (element_ref.current?.matches(":focus-within")) return
                if (element_ref.current?.contains(e.relatedTarget)) return

                if (
                    recent_source_element_ref.current != null &&
                    (recent_source_element_ref.current.contains(e.relatedTarget) || recent_source_element_ref.current.matches(":focus-within"))
                )
                    return
                close()
                e.preventDefault()
                element_focused_before_popup.current?.focus?.()
            }
        },
        [close]
    )

    const type = recent_event?.type
    return html`<pluto-popup
            class=${cl({
                visible: recent_event != null,
                [type ?? ""]: type != null,
                big: recent_event?.big === true,
                [recent_event?.css_class ?? ""]: recent_event?.css_class != null,
            })}
            style="${pos_ref.current}"
            ref=${element_ref}
            tabindex=${
                "0" /* this makes the popup itself focusable (not just its buttons), just like a <dialog> element. It also makes the `.matches(":focus-within")` trick work. */
            }
        >
            ${type === "info" || type === "warn" ? html`<div>${recent_event?.body}</div>` : null}
        </pluto-popup>
        <div tabindex="0">
            <!-- We need this dummy tabindexable element here so that the element_focused_before_popup mechanism works on static exports. When tabbing out of the popup, focus would otherwise leave the page altogether because it's the last focusable element in DOM. -->
        </div>`
}
