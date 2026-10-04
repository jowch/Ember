import { html, useRef, useState } from "../imports/Preact.js"
import { useEventListener } from "../common/useEventListener.js"
import { t } from "../common/lang.js"
import { Dialog } from "../common/dialogs.js"

export const DEFAULT_SETTINGS = {
    THEME: "system",
    CM_INDENT_UNIT: "2",
    CM_AUTOCOMPLETE_ON_TYPE: true,
    CM_SPELLCHECK: false,
    CM_TAB_KEY_FOR_INDENT: true,
    CONFIRM_LONG_RUNTIMES: true,
    CONFIRM_LONG_RUNTIMES_SECONDS: 120,
    ALWAYS_NOTIFY_LONG_BUSY: false,
}

/**
 * @returns {typeof DEFAULT_SETTINGS}
 */
export const get_settings = () =>
    /** @type {typeof DEFAULT_SETTINGS} */ (
        Object.fromEntries(
            Object.keys(DEFAULT_SETTINGS).map((key) => {
                const raw = localStorage.getItem(`pluto_setting_${key}`)
                if (raw == null) return [key, DEFAULT_SETTINGS[key]]
                try {
                    return [key, JSON.parse(raw)]
                } catch (e) {
                    console.error(`Failed to JSON.parse pluto_setting_${key}, falling back to default.`, e)
                    return [key, DEFAULT_SETTINGS[key]]
                }
            })
        )
    )

const announce = (/** @type {string} */ key, /** @type {any} */ value) =>
    window.dispatchEvent(new CustomEvent("ember settings changed", { detail: { key, value } }))

/**
 * Store a setting, then tell the page with a window `"ember settings
 * changed"` event (`detail: { key, value }`); open editors and the theme
 * listen for it.
 *
 * @template {string & keyof typeof DEFAULT_SETTINGS} K
 * @param {K} key
 * @param {(typeof DEFAULT_SETTINGS)[K]} value
 */
export const set_setting = (key, value) => {
    localStorage.setItem(`pluto_setting_${key}`, JSON.stringify(value))
    announce(key, value)
}

export const clear_settings = () => {
    Object.entries(DEFAULT_SETTINGS).forEach(([key, value]) => {
        localStorage.removeItem(`pluto_setting_${key}`)
        announce(key, value)
    })
}

/**
 * A segmented control: one `role="radio"` button per option, ←/→ move and
 * pick.
 *
 * @param {{ labelledby: string, options: Array<{ value: string, label: string }>, value: string, on_change: (value: string) => void }} props
 */
const Segmented = ({ labelledby, options, value, on_change }) => {
    const group_ref = useRef(/** @type {HTMLElement?} */ (null))
    const pick = (/** @type {number} */ i) => {
        on_change(options[i].value)
        /** @type {HTMLElement?} */ (group_ref.current?.children[i] ?? null)?.focus()
    }
    const current = options.findIndex((o) => o.value === value)
    return html`<div class="ember-seg" role="radiogroup" aria-labelledby=${labelledby} ref=${group_ref}>
        ${options.map(
            (o, i) => html`<button
                type="button"
                role="radio"
                aria-checked=${o.value === value}
                tabIndex=${i === Math.max(current, 0) ? 0 : -1}
                onClick=${() => on_change(o.value)}
                onKeyDown=${(/** @type {KeyboardEvent} */ e) => {
                    const step = e.key === "ArrowRight" || e.key === "ArrowDown" ? 1 : e.key === "ArrowLeft" || e.key === "ArrowUp" ? -1 : 0
                    if (step === 0) return
                    e.preventDefault()
                    pick((i + step + options.length) % options.length)
                }}
            >
                ${o.label}
            </button>`
        )}
    </div>`
}

/** @param {{ labelledby: string, checked: boolean, on_change: (checked: boolean) => void }} props */
const Switch = ({ labelledby, checked, on_change }) =>
    html`<button type="button" class="ember-switch" role="switch" aria-checked=${checked} aria-labelledby=${labelledby} onClick=${() => on_change(!checked)}></button>`

/** @param {{ id: string, title: string, note?: any, children: any }} props */
const Row = ({ id, title, note, children }) => html`<div class="ember-settings-row">
    <div>
        <b id=${id}>${title}</b>
        ${note != null ? html`<small>${note}</small>` : null}
    </div>
    ${children}
</div>`

const SettingsBody = ({ close }) => {
    const [settings, set_settings] = useState(get_settings)
    useEventListener(window, "ember settings changed", () => set_settings(get_settings()), [])
    const [notify_blocked, set_notify_blocked] = useState(false)

    const on_notify = async (/** @type {boolean} */ on) => {
        set_notify_blocked(false)
        set_setting("ALWAYS_NOTIFY_LONG_BUSY", on)
        if (!on) return
        const permission = typeof Notification === "undefined" ? "denied" : await Notification.requestPermission()
        if (permission !== "granted") {
            set_setting("ALWAYS_NOTIFY_LONG_BUSY", false)
            set_notify_blocked(true)
        }
    }

    return html`
        <section class="ember-settings-section">
            <h3>${t("t_settings_section_appearance")}</h3>
            <${Row} id="ember-setting-theme" title=${t("t_settings_theme")}>
                <${Segmented}
                    labelledby="ember-setting-theme"
                    value=${settings.THEME}
                    on_change=${(v) => set_setting("THEME", v)}
                    options=${[
                        { value: "system", label: t("t_settings_theme_system") },
                        { value: "light", label: t("t_settings_theme_light") },
                        { value: "dark", label: t("t_settings_theme_dark") },
                    ]}
                />
            <//>
        </section>
        <section class="ember-settings-section">
            <h3>${t("t_settings_section_editing")}</h3>
            <${Row} id="ember-setting-indent" title=${t("t_settings_indent")}>
                <${Segmented}
                    labelledby="ember-setting-indent"
                    value=${settings.CM_INDENT_UNIT}
                    on_change=${(v) => set_setting("CM_INDENT_UNIT", v)}
                    options=${[
                        { value: "2", label: t("t_settings_indent_2") },
                        { value: "4", label: t("t_settings_indent_4") },
                        { value: "tab", label: t("t_settings_indent_tab") },
                    ]}
                />
            <//>
            <${Row} id="ember-setting-autocomplete" title=${t("t_settings_autocomplete")} note=${t("t_settings_autocomplete_note")}>
                <${Switch}
                    labelledby="ember-setting-autocomplete"
                    checked=${settings.CM_AUTOCOMPLETE_ON_TYPE}
                    on_change=${(v) => set_setting("CM_AUTOCOMPLETE_ON_TYPE", v)}
                />
            <//>
            <${Row} id="ember-setting-spellcheck" title=${t("t_settings_spellcheck")}>
                <${Switch} labelledby="ember-setting-spellcheck" checked=${settings.CM_SPELLCHECK} on_change=${(v) => set_setting("CM_SPELLCHECK", v)} />
            <//>
            <${Row} id="ember-setting-tab" title=${t("t_settings_tab_key")} note=${t("t_settings_tab_key_note")}>
                <${Segmented}
                    labelledby="ember-setting-tab"
                    value=${settings.CM_TAB_KEY_FOR_INDENT ? "indent" : "focus"}
                    on_change=${(v) => set_setting("CM_TAB_KEY_FOR_INDENT", v === "indent")}
                    options=${[
                        { value: "indent", label: t("t_settings_tab_key_indents") },
                        { value: "focus", label: t("t_settings_tab_key_moves_focus") },
                    ]}
                />
            <//>
        </section>
        <section class="ember-settings-section">
            <h3>${t("t_settings_section_running")}</h3>
            <${Row} id="ember-setting-long-runs" title=${t("t_settings_long_runs")} note=${t("t_settings_long_runs_note")}>
                <div class="ember-settings-controls">
                    <input
                        class="ember-seconds"
                        type="number"
                        min="0"
                        step="1"
                        aria-labelledby="ember-setting-long-runs ember-setting-seconds"
                        value=${settings.CONFIRM_LONG_RUNTIMES_SECONDS}
                        onChange=${(/** @type {Event} */ e) => {
                            const seconds = /** @type {HTMLInputElement} */ (e.target).valueAsNumber
                            if (Number.isFinite(seconds) && seconds >= 0) set_setting("CONFIRM_LONG_RUNTIMES_SECONDS", seconds)
                        }}
                    />
                    <span id="ember-setting-seconds" class="ember-settings-unit">${t("t_settings_seconds")}</span>
                    <${Switch}
                        labelledby="ember-setting-long-runs"
                        checked=${settings.CONFIRM_LONG_RUNTIMES}
                        on_change=${(v) => set_setting("CONFIRM_LONG_RUNTIMES", v)}
                    />
                </div>
            <//>
            <${Row}
                id="ember-setting-notify"
                title=${t("t_settings_notify")}
                note=${notify_blocked
                    ? html`${t("t_settings_notify_note")}<span class="ember-settings-blocked" role="status">${t("t_settings_notify_blocked")}</span>`
                    : t("t_settings_notify_note")}
            >
                <${Switch} labelledby="ember-setting-notify" checked=${settings.ALWAYS_NOTIFY_LONG_BUSY} on_change=${on_notify} />
            <//>
        </section>
        <footer class="ember-settings-footer">
            <button type="button" class="ember-btn ember-settings-reset" onClick=${() => clear_settings()}>${t("t_settings_reset_defaults")}</button>
            <button type="button" class="ember-btn primary" onClick=${close}>${t("t_settings_done")}</button>
        </footer>
    `
}

/**
 * The Settings dialog (ui-3.md, Menus and Settings), opened by the window
 * event `"pluto open settings"` (the ⋯ menu). Every change applies at once.
 */
export const Settings = () => {
    const [open, set_open] = useState(false)
    useEventListener(window, "pluto open settings", () => set_open(true), [])
    return open
        ? html`<${Dialog}
              class_name="psettings"
              title=${t("t_settings_title")}
              title_note=${t("t_settings_scope")}
              on_close=${() => set_open(false)}
              render=${({ close }) => html`<${SettingsBody} close=${close} />`}
          />`
        : null
}
