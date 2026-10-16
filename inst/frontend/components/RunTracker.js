import { html, useEffect, useRef, useState } from "../imports/Preact.js"
import { useEventListener } from "../common/useEventListener.js"
import { t, pretty_long_time } from "../common/lang.js"
import { get_settings } from "./Settings.js"
import { display_name } from "../common/display_name.js"
import { url_logo_small } from "./Editor.js"

const NOTIFY_AFTER_SECONDS = 60
// A started run that never shows a running, queued or newly run cell
// (nothing to run, say) stops being tracked, so it can't claim a later run.
const GIVE_UP_MS = 5000

/** Tell the tracker this page just asked the server to run cells. */
export const run_started = () => window.dispatchEvent(new CustomEvent("ember run started"))

const last_run = (/** @type {import("./Editor.js").NotebookData} */ notebook, /** @type {string} */ id) =>
    notebook.cell_results[id]?.output?.last_run_timestamp ?? 0

/**
 * @param {import("./Editor.js").NotebookData} notebook
 * @param {Set<string>} seen
 */
const run_message = (notebook, seen) => {
    const errored = notebook.cell_order.filter((id) => seen.has(id) && notebook.cell_results[id]?.errored)
    if (errored.length === 0) return t("t_run_finished", { count: seen.size })
    const first_name = Object.keys(notebook.cell_dependencies[errored[0]]?.downstream_cells_map ?? {})[0]
    const name = first_name == null ? t("t_run_a_cell") : display_name(first_name)
    const first = t("t_run_error", { name })
    return errored.length === 1 ? first : first + t("t_run_more_errors", { count: errored.length - 1 })
}

/**
 * One polite announcement when a run this page started ends (ui-3.md,
 * Accessibility), and a system notification for a long one while the page
 * is hidden, if Settings asks for it. A run is every cell that is running
 * or queued, or that gets a new run time, from the start until the first
 * update with nothing running or queued.
 *
 * @param {{ notebook: import("./Editor.js").NotebookData }} props
 */
export const RunTracker = ({ notebook }) => {
    const notebook_ref = useRef(notebook)
    notebook_ref.current = notebook
    const run_ref = useRef(/** @type {{ started_at: number, before: Record<string, number>, seen: Set<string> }?} */ (null))
    // A run started while another is still being tracked. Its cells show
    // up only once its request reaches the server, which can be after the
    // tracked run has ended, so it can't simply join that run: it is
    // tracked as a run of its own from the moment that run ends (#70).
    const next_ref = useRef(false)
    const give_up_ref = useRef(/** @type {ReturnType<typeof setTimeout>?} */ (null))
    const [message, set_message] = useState("")

    const begin = (/** @type {import("./Editor.js").NotebookData} */ nb) => {
        run_ref.current = {
            started_at: Date.now(),
            before: Object.fromEntries(nb.cell_order.map((id) => [id, last_run(nb, id)])),
            seen: new Set(),
        }
        clearTimeout(give_up_ref.current ?? undefined)
        give_up_ref.current = setTimeout(() => {
            if (run_ref.current?.seen.size !== 0) return
            run_ref.current = null
            if (next_ref.current) {
                next_ref.current = false
                begin(notebook_ref.current)
            }
        }, GIVE_UP_MS)
    }

    useEventListener(
        window,
        "ember run started",
        () => {
            if (run_ref.current != null) next_ref.current = true
            else begin(notebook_ref.current)
        },
        []
    )
    useEffect(() => () => clearTimeout(give_up_ref.current ?? undefined), [])

    useEffect(() => {
        const run = run_ref.current
        if (run == null) return
        let busy = false
        for (const id of notebook.cell_order) {
            const result = notebook.cell_results[id]
            if (result == null) continue
            if (result.running || result.queued) {
                busy = true
                run.seen.add(id)
            } else if (last_run(notebook, id) !== (run.before[id] ?? 0)) {
                run.seen.add(id)
            }
        }
        if (busy || run.seen.size === 0) return
        run_ref.current = null
        // If the next run's cells already showed up in this one, they are
        // announced here, and the next run gives up with nothing to say.
        if (next_ref.current) {
            next_ref.current = false
            begin(notebook)
        }

        const text = run_message(notebook, run.seen)
        // Cleared first, so the same words twice in a row are read again.
        set_message("")
        requestAnimationFrame(() => set_message(text))

        const seconds = (Date.now() - run.started_at) / 1000
        if (get_settings().ALWAYS_NOTIFY_LONG_BUSY && seconds >= NOTIFY_AFTER_SECONDS && document.hidden && typeof Notification !== "undefined") {
            const file = (notebook.path ?? "").split(/[\\/]/).pop() || notebook.shortpath
            const notification = new Notification(t("t_run_notif_title", { file }), {
                body: t("t_run_notif_body", { count: run.seen.size, time: pretty_long_time(seconds) }),
                icon: url_logo_small,
            })
            notification.onclick = () => {
                window.focus()
                notification.close()
            }
        }
    }, [notebook])

    return html`<div id="ember-run-status" class="ember-visually-hidden" role="status" aria-live="polite">${message}</div>`
}
