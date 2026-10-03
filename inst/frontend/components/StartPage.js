import { html, useContext, useEffect, useState } from "../imports/Preact.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"
import { FolderField } from "./FolderField.js"
import { FilePicker } from "./FilePicker.js"
import { t } from "../common/lang.js"

/**
 * Ember's start page (`GET /`, start.js): one "My notebooks" list with
 * "New notebook" at the top, then open notebooks, then recent ones, and
 * "Open a file" underneath. Loads from `ember_start_page` and refreshes
 * every 5s while the tab is visible (no hub, no worker: one plain
 * request each time). No `alert()`/`confirm()`: every error shows inside
 * the row that produced it.
 */
export const StartPage = () => {
    const pluto_actions = useContext(PlutoActionsContext)
    const [data, set_data] = useState(/** @type {{start_dir: string, new_name: string, open: Array<any>, recent: Array<any>}?} */ (null))

    const refresh = async () => {
        const response = await pluto_actions.send("ember_start_page", {})
        set_data(response.message)
    }

    useEffect(() => {
        refresh()
        const interval = setInterval(() => {
            if (document.visibilityState === "visible") refresh()
        }, 5000)
        return () => clearInterval(interval)
    }, [])

    if (data == null) {
        return html`<main class="ember-start"></main>`
    }

    return html`
        <main class="ember-start">
            <div class="ember-start-brand">
                <img class="ember-start-logo" src="./img/favicon.svg" alt="" />
                <span>ember</span>
            </div>
            <h1 class="ember-start-heading">${t("t_ember_start_my_notebooks")}</h1>
            <ul class="ember-start-list">
                <${NewNotebookRow} start_dir=${data.start_dir} new_name=${data.new_name} on_created=${(url) => (window.location.href = url)} />
                ${data.open.map((nb) => html`<${OpenRow} key=${nb.notebook_id} notebook=${nb} on_changed=${refresh} />`)}
                ${data.recent.map((nb) => html`<${RecentRow} key=${nb.path} notebook=${nb} on_changed=${refresh} />`)}
            </ul>
            <${OpenFileField} />
        </main>
    `
}

/** This page's own secret, read back out of its URL: `edit?id=` links need
 * it explicitly (the secret cookie `http_start()` sets covers `/edit`
 * itself, but not before the link is clicked for the first time in a
 * fresh tab that never loaded any Ember page). */
const page_secret = () => new URLSearchParams(window.location.search).get("secret") ?? ""

const mb_of = (/** @type {number?} */ worker_memory) => (worker_memory == null ? null : Math.round(worker_memory / 1024 / 1024))

const is_running = (/** @type {string} */ process) => process === "starting" || process === "ready" || process === "busy"

const process_label = (/** @type {{process: string, worker_memory: number?}} */ nb) => {
    if (nb.process === "preview") return t("t_safe_preview")
    if (!is_running(nb.process)) return t("t_ember_start_stopped")
    const mb = mb_of(nb.worker_memory)
    return mb == null ? t("t_ember_start_running_no_memory") : t("t_ember_start_running", { mb })
}

const NewNotebookRow = ({ start_dir, new_name, on_created }) => {
    const [expanded, set_expanded] = useState(false)
    const [name, set_name] = useState(new_name)
    const [folder, set_folder] = useState(start_dir)
    const [error, set_error] = useState(/** @type {string?} */ (null))
    const [creating, set_creating] = useState(false)
    const pluto_actions = useContext(PlutoActionsContext)

    if (!expanded) {
        return html`<li class="ember-start-row ember-start-new">
            <button
                type="button"
                class="ember-start-new-btn"
                onClick=${() => {
                    set_name(new_name)
                    set_folder(start_dir)
                    set_error(null)
                    set_expanded(true)
                }}
            >
                + ${t("t_ember_start_new_notebook")}
            </button>
        </li>`
    }

    const create = async () => {
        set_creating(true)
        set_error(null)
        try {
            const response = await pluto_actions.send("ember_new_notebook", { name, folder })
            if (response.message.error != null) {
                set_error(response.message.error)
            } else {
                on_created(response.message.url)
            }
        } finally {
            set_creating(false)
        }
    }

    return html`<li class="ember-start-row ember-start-new ember-start-new-expanded">
        <div class="ember-field">
            <label for="ember-start-new-name">${t("t_ember_move_name")}</label>
            <input
                id="ember-start-new-name"
                class="ember-text-input mono"
                type="text"
                value=${name}
                disabled=${creating}
                onInput=${(/** @type {InputEvent} */ e) => set_name(/** @type {HTMLInputElement} */ (e.target).value)}
            />
        </div>
        <${FolderField} id="ember-start-new-folder" label=${t("t_ember_move_folder")} value=${folder} on_change=${set_folder} disabled=${creating} />
        ${error != null && html`<p class="ember-dialog-text ember-dialog-error">${error}</p>`}
        <div class="ember-dialog-actions">
            <button type="button" class="ember-btn" disabled=${creating} onClick=${() => set_expanded(false)}>${t("t_cancel")}</button>
            <button type="button" class="ember-btn primary" disabled=${creating || !name.trim()} onClick=${create}>${t("t_ember_start_create")}</button>
        </div>
    </li>`
}

const OpenRow = ({ notebook, on_changed }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const [closing, set_closing] = useState(false)

    const stop = async () => {
        set_closing(true)
        await pluto_actions.send("shutdown_notebook", { keep_in_session: false }, { notebook_id: notebook.notebook_id }, false)
        setTimeout(on_changed, 300)
    }

    return html`<li class="ember-start-row">
        <a class="ember-start-name" href=${`edit?id=${notebook.notebook_id}&secret=${page_secret()}`}>${notebook.name}</a>
        <span class="ember-start-folder mono">${notebook.folder}</span>
        <span class="ember-start-status">${process_label(notebook)}</span>
        ${notebook.owned &&
        html`<button
            type="button"
            class="ember-start-stop"
            disabled=${closing}
            title=${is_running(notebook.process) ? t("t_ember_start_stop_title") : t("t_ember_start_close_title")}
            onClick=${stop}
        ></button>`}
    </li>`
}

const RecentRow = ({ notebook, on_changed }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const [forgetting, set_forgetting] = useState(false)

    const forget = async () => {
        set_forgetting(true)
        const response = await pluto_actions.send("ember_forget_recent", { path: notebook.path })
        on_changed(response.message)
    }

    return html`<li class="ember-start-row">
        <a class="ember-start-name" href="#" onClick=${(/** @type {MouseEvent} */ e) => {
            e.preventDefault()
            pluto_actions.send("ember_open_notebook", { path: notebook.path }).then((response) => {
                if (response.message.url != null) window.location.href = response.message.url
            })
        }}>${notebook.name}</a>
        <span class="ember-start-folder mono">${notebook.folder}</span>
        <button type="button" class="ember-link-btn ember-start-forget" disabled=${forgetting} title=${t("t_ember_start_forget_title")} onClick=${forget}>
            ${t("t_ember_start_forget")}
        </button>
    </li>`
}

const OpenFileField = () => {
    const pluto_actions = useContext(PlutoActionsContext)
    const [error, set_error] = useState(/** @type {string?} */ (null))

    return html`<div class="ember-start-open-file">
        <span class="ember-field-label">${t("t_ember_start_open_file")}</span>
        <${FilePicker}
            value=${""}
            client=${pluto_actions}
            placeholder=${t("t_ember_start_open_placeholder")}
            button_label=${t("t_ember_start_open_button")}
            clear_on_blur=${false}
            readonly=${false}
            on_submit=${async (/** @type {string} */ path) => {
                set_error(null)
                const response = await pluto_actions.send("ember_open_notebook", { path })
                if (response.message.error != null) {
                    set_error(response.message.error)
                    throw new Error(response.message.error)
                }
                window.location.href = response.message.url
            }}
        />
        ${error != null && html`<p class="ember-dialog-text ember-dialog-error">${error}</p>`}
    </div>`
}
