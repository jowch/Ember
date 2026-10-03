import { html, render, useLayoutEffect, useRef, useState } from "../imports/Preact.js"
import { useDialog } from "./useDialog.js"
import { cl } from "./ClassTable.js"
import { t } from "./lang.js"

let next_dialog_id = 1

/**
 * The modal shell behind `ask`/`tell`. `showModal()` makes the rest of the
 * page inert and keeps Tab inside (the browser's own behaviour, via
 * `useDialog`'s polyfill path on browsers without `<dialog>`). Esc, the
 * dialog's own `cancel`/`close` events and a click on the backdrop call
 * `on_close`; focus returns to the element that had it before the dialog
 * opened, saved explicitly because browsers differ on restoring it
 * themselves.
 *
 * @param {{
 *   title?: string,
 *   on_close: () => void,
 *   role?: "dialog" | "alertdialog",
 *   render: (ctx: { close: () => void, describedby_id: string }) => import("../imports/Preact.js").ReactElement,
 * }} props
 */
export const Dialog = ({ title, on_close, role = "dialog", render: render_body }) => {
    const [dialog_ref, open, close, _toggle] = useDialog()
    const opener_ref = useRef(/** @type {Element?} */ (null))
    const ids_ref = useRef(/** @type {{ title: string, body: string }?} */ (null))
    if (ids_ref.current == null) {
        const n = next_dialog_id++
        ids_ref.current = { title: `ember-dialog-title-${n}`, body: `ember-dialog-body-${n}` }
    }

    // Listeners added by hand, not via useEventListener(dialog_ref.current,
    // ...): that reads the ref during render, while it's still null.
    useLayoutEffect(() => {
        const dialog_el = dialog_ref.current
        opener_ref.current = document.activeElement

        const handle_close = () => {
            on_close()
            // Deferred a frame: Chromium's own post-close focus handling can
            // still be in flight when `close` fires, and races this.
            requestAnimationFrame(() => {
                // `body.focus()` is a no-op (no tabindex), so blurring is
                // what actually falls back to it.
                // @ts-ignore
                document.activeElement?.blur?.()
                if (opener_ref.current != null && opener_ref.current !== document.body) {
                    // @ts-ignore
                    opener_ref.current?.focus?.()
                }
            })
        }
        dialog_el?.addEventListener("close", handle_close)

        // A click lands with `target` the <dialog> itself only when it's on
        // the backdrop: a click on any actual content stops there instead.
        const handle_backdrop_click = (/** @type {MouseEvent} */ e) => {
            if (e.target === dialog_el) close()
        }
        dialog_el?.addEventListener("click", handle_backdrop_click)

        open()
        requestAnimationFrame(() => {
            const el = dialog_el?.querySelector(".primary") ?? dialog_el?.querySelector("button, input, textarea, select, a[href]")
            // @ts-ignore
            el?.focus?.()
        })

        return () => {
            dialog_el?.removeEventListener("close", handle_close)
            dialog_el?.removeEventListener("click", handle_backdrop_click)
        }
    }, [])

    return html`
        <dialog
            class="ember-dialog"
            ref=${dialog_ref}
            role=${role}
            aria-labelledby=${title != null ? ids_ref.current.title : undefined}
            aria-describedby=${ids_ref.current.body}
        >
            ${title != null ? html`<header id=${ids_ref.current.title} class="ember-dialog-title">${title}</header>` : null}
            <div class="ember-dialog-body">${render_body({ close, describedby_id: ids_ref.current.body })}</div>
        </dialog>
    `
}

/** One queued dialog request: `render_body` and `on_close` as `Dialog` expects, plus a stable `id` used as the Preact key so the next item in the queue mounts fresh. */
let queue = /** @type {Array<{ id: number, key: string?, title?: string, on_close: () => void, render: (ctx: { close: () => void, describedby_id: string }) => any }>} */ ([])
let listeners = /** @type {Set<(q: typeof queue) => void>} */ (new Set())
let host_mounted = false
let next_id = 1

/** A pending request's promise, by `key`, while it's queued or showing: a later `ask()` with the same key is dropped, returning this instead of opening a second dialog. */
const pending_by_key = /** @type {Map<string, Promise<any>>} */ (new Map())

const publish = () => listeners.forEach((listen) => listen(queue))

const DialogHost = () => {
    const [items, set_items] = useState(() => queue)
    useLayoutEffect(() => {
        listeners.add(set_items)
        return () => listeners.delete(set_items)
    }, [])

    const current = items[0]
    if (current == null) return null
    return html`<${Dialog} key=${current.id} title=${current.title} role=${current.role} on_close=${current.on_close} render=${current.render} />`
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
 * Every dialog shown on this page, oldest first, as `{ title, body, answer }`:
 * `body` is the text (null when it isn't a plain string) and `answer` the
 * picked action's label, or null for a cancel, once answered. A host that
 * embeds the page reads it instead of wrapping `window.alert`, which these
 * dialogs never call; an "ember-dialog" event carries each new entry.
 */
const dialog_log = /** @type {Array<{ title: string?, body: string?, answer: string? | undefined }>} */ ([])
Object.defineProperty(window, "ember_dialogs", { value: dialog_log })

/**
 * Show one dialog with named actions and wait for the one the person picks.
 * Esc, the dialog's cancel event and a click outside resolve `cancel_value`.
 * Buttons name their action (Delete, Cancel, Stop), never Yes/No.
 *
 * `key`, when given, dedupes: a second `ask()` with the same key while one
 * is already queued or showing doesn't open another dialog, it returns the
 * first call's promise.
 *
 * @param {{
 *   title?: string,
 *   body: string | import("../imports/Preact.js").ReactElement,
 *   actions: Array<{ label: string, value: any, primary?: boolean, danger?: boolean }>,
 *   cancel_value?: any,
 *   role?: "dialog" | "alertdialog",
 *   key?: string,
 * }} options
 * @returns {Promise<any>}
 */
export const ask = ({ title, body, actions, cancel_value = null, role = "alertdialog", key }) => {
    if (key != null && pending_by_key.has(key)) return /** @type {Promise<any>} */ (pending_by_key.get(key))

    const entry = { title: title ?? null, body: typeof body === "string" ? body : null, answer: /** @type {string? | undefined} */ (undefined) }
    dialog_log.push(entry)
    window.dispatchEvent(new CustomEvent("ember-dialog", { detail: entry }))

    const promise = new Promise((resolve) => {
        let settled = false
        const settle = (/** @type {any} */ value, /** @type {string?} */ label) => {
            if (settled) return
            settled = true
            entry.answer = label
            if (key != null) pending_by_key.delete(key)
            resolve(value)
            dequeue(item)
        }
        const item = enqueue({
            title,
            role,
            on_close: () => settle(cancel_value, null),
            render: ({ close, describedby_id }) => html`
                <p id=${describedby_id} class="ember-dialog-text">${body}</p>
                <div class="ember-dialog-actions">
                    ${actions.map(
                        (a, i) => html`<button
                            key=${i}
                            type="button"
                            autofocus=${a.primary === true ? true : undefined}
                            class=${cl({ "ember-btn": true, primary: a.primary === true, danger: a.danger === true })}
                            onClick=${() => {
                                settle(a.value, a.label)
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

    if (key != null) pending_by_key.set(key, promise)
    return promise
}

/**
 * Show one dialog with a single acknowledgement action.
 *
 * @param {{ title?: string, body: string | import("../imports/Preact.js").ReactElement, action_label?: string, key?: string }} options
 * @returns {Promise<void>}
 */
export const tell = ({ title, body, action_label = t("t_close"), key }) =>
    ask({ title, body, actions: [{ label: action_label, value: undefined, primary: true }], cancel_value: undefined, key }).then(() => undefined)

/**
 * The dialog shown when something has gone wrong enough that reloading is
 * the best way forward, without forcing it: Cancel leaves the page as it
 * is (as the native dialog it replaces did) and only Reload reloads.
 *
 * Every caller shares one `key` by default, so a page failing repeatedly
 * (a retrying connection, say) shows one dialog, not a stack of them.
 *
 * @param {{ key?: string }} options
 * @returns {Promise<void>}
 */
export const reload_prompt = ({ key = "ember-reload-prompt" } = {}) =>
    ask({
        body: t("t_page_error_reload"),
        actions: [
            { label: t("t_reload"), value: "reload", primary: true },
            { label: t("t_cancel"), value: "cancel" },
        ],
        cancel_value: "cancel",
        key,
    }).then((value) => {
        if (value === "reload") location.reload()
    })
