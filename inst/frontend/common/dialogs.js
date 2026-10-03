import { html, render, useLayoutEffect, useRef, useState } from "../imports/Preact.js"
import { useDialog } from "./useDialog.js"
import { cl } from "./ClassTable.js"
import { t } from "./lang.js"

/**
 * The modal shell behind `ask`/`tell` and, later, piece 4's rename form.
 * `showModal()` makes the rest of the page inert and keeps Tab inside (the
 * browser's own behaviour, via `useDialog`'s polyfill path on browsers
 * without `<dialog>`). Esc and the dialog's own `cancel`/`close` events call
 * `on_close`; focus returns to the element that had it before the dialog
 * opened, saved explicitly because browsers differ on restoring it
 * themselves.
 *
 * @param {{
 *   title?: string,
 *   on_close: () => void,
 *   render: (ctx: { close: () => void }) => import("../imports/Preact.js").ReactElement,
 * }} props
 */
const Dialog = ({ title, on_close, render: render_body }) => {
    const [dialog_ref, open, close, _toggle] = useDialog()
    const opener_ref = useRef(/** @type {Element?} */ (null))

    // The `close` listener is added by hand, on the live node read inside
    // the effect, rather than through `useEventListener(dialog_ref.current,
    // ...)`: that reads the ref during render, while it's still null (the
    // `<dialog>` isn't committed yet), and nothing here forces a second
    // render to pick up the real node once it exists.
    useLayoutEffect(() => {
        const dialog_el = dialog_ref.current
        opener_ref.current = document.activeElement

        const handle_close = () => {
            on_close()
            // Deferred a frame: Chromium's own post-close focus handling
            // (restoring whatever had focus when `showModal()` was called)
            // can still be in flight when `close` fires, and races this.
            // Running after it settles is what makes the end state land on
            // the opener reliably instead of wherever that race left it.
            requestAnimationFrame(() => {
                // `body.focus()` is a no-op (body has no tabindex), so when
                // nothing held focus before the dialog opened, blurring
                // whatever is focused now is what actually returns focus
                // to the page: the browser's own fallback is the body.
                // @ts-ignore
                document.activeElement?.blur?.()
                if (opener_ref.current != null && opener_ref.current !== document.body) {
                    // @ts-ignore
                    opener_ref.current?.focus?.()
                }
            })
        }
        dialog_el?.addEventListener("close", handle_close)

        open()
        requestAnimationFrame(() => {
            const el = dialog_el?.querySelector(".primary") ?? dialog_el?.querySelector("button, input, textarea, select, a[href]")
            // @ts-ignore
            el?.focus?.()
        })

        return () => {
            dialog_el?.removeEventListener("close", handle_close)
        }
    }, [])

    return html`
        <dialog class="ember-dialog" ref=${dialog_ref} aria-label=${title}>
            ${title != null ? html`<header class="ember-dialog-title">${title}</header>` : null}
            <div class="ember-dialog-body">${render_body({ close })}</div>
        </dialog>
    `
}

/** One queued dialog request: `render_body` and `on_close` as `Dialog` expects, plus a stable `id` used as the Preact key so the next item in the queue mounts fresh. */
let queue = /** @type {Array<{ id: number, title?: string, on_close: () => void, render: (ctx: { close: () => void }) => any }>} */ ([])
let listeners = /** @type {Set<(q: typeof queue) => void>} */ (new Set())
let host_mounted = false
let next_id = 1

const publish = () => listeners.forEach((listen) => listen(queue))

const DialogHost = () => {
    const [items, set_items] = useState(() => queue)
    useLayoutEffect(() => {
        listeners.add(set_items)
        return () => listeners.delete(set_items)
    }, [])

    const current = items[0]
    if (current == null) return null
    return html`<${Dialog} key=${current.id} title=${current.title} on_close=${current.on_close} render=${current.render} />`
}

const dequeue = (/** @type {{ id: number }} */ item) => {
    queue = queue.filter((x) => x.id !== item.id)
    publish()
}

const enqueue = (/** @type {Omit<typeof queue[0], "id">} */ item_without_id) => {
    const item = { ...item_without_id, id: next_id++ }
    queue = [...queue, item]
    if (!host_mounted) {
        host_mounted = true
        const container = document.createElement("div")
        document.body.appendChild(container)
        render(html`<${DialogHost} />`, container)
    } else {
        publish()
    }
    return item
}

/**
 * Show one dialog with named actions and wait for the one the person picks.
 * Esc, the dialog's cancel event and a click outside resolve `cancel_value`.
 * Buttons name their action (Delete, Cancel, Stop), never Yes/No.
 *
 * @param {{
 *   title?: string,
 *   body: string | import("../imports/Preact.js").ReactElement,
 *   actions: Array<{ label: string, value: any, primary?: boolean, danger?: boolean }>,
 *   cancel_value?: any,
 * }} options
 * @returns {Promise<any>}
 */
export const ask = ({ title, body, actions, cancel_value = null }) =>
    new Promise((resolve) => {
        let settled = false
        const settle = (/** @type {any} */ value) => {
            if (settled) return
            settled = true
            resolve(value)
            dequeue(item)
        }
        const item = enqueue({
            title,
            on_close: () => settle(cancel_value),
            render: ({ close }) => html`
                <p class="ember-dialog-text">${body}</p>
                <div class="ember-dialog-actions">
                    ${actions.map(
                        (a, i) => html`<button
                            key=${i}
                            type="button"
                            autofocus=${a.primary === true ? true : undefined}
                            class=${cl({ "ember-btn": true, primary: a.primary === true, danger: a.danger === true })}
                            onClick=${() => {
                                settle(a.value)
                                close()
                            }}
                        >
                            ${a.label}
                        </button>`
                    )}
                </div>
            `,
        })
    })

/**
 * Show one dialog with a single acknowledgement action.
 *
 * @param {{ title?: string, body: string | import("../imports/Preact.js").ReactElement, action_label?: string }} options
 * @returns {Promise<void>}
 */
export const tell = ({ title, body, action_label = t("t_close") }) =>
    ask({ title, body, actions: [{ label: action_label, value: undefined, primary: true }], cancel_value: undefined }).then(() => undefined)

/**
 * The dialog shown when something has gone wrong enough that reloading is
 * the only way forward. Resolves once the page starts reloading; there is
 * no Cancel, so Esc and the cancel event reload too.
 *
 * @returns {Promise<void>}
 */
export const reload_prompt = () =>
    ask({
        body: t("t_page_error_reload"),
        actions: [{ label: t("t_reload"), value: "reload", primary: true }],
        cancel_value: "reload",
    }).then(() => {
        location.reload()
    })
