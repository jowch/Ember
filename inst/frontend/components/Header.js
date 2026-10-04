import { html, useEffect, useRef, useState } from "../imports/Preact.js"
import { cl } from "../common/ClassTable.js"
import { t } from "../common/lang.js"
import { useEventListener } from "../common/useEventListener.js"
import { useMenu } from "../common/useMenu.js"
import { use_run_progress } from "../common/use_run_progress.js"
import { useSettled } from "../common/useSettled.js"
import { FlameLogo, VariablesIcon, HelpIcon, PackagesIcon, SidePanelIcon, MoreIcon } from "../common/Icons.js"
import { ExportMenu, export_items, use_print_title } from "./ExportMenu.js"
import { open_bottom_right_panel } from "./BottomRightPanel.js"
import { is_desktop, open_main_menu } from "./DesktopInterface.js"

/** The page's own secret, read back out of its URL, as StartPage.js does. */
const page_secret = () => new URLSearchParams(window.location.search).get("secret") ?? ""

/** Tracks a `max-width` media query without a resize listener on every render. */
const use_narrow = (/** @type {number} */ max_width) => {
    const query = `(max-width: ${max_width}px)`
    const [narrow, set_narrow] = useState(() => window.matchMedia(query).matches)
    useEffect(() => {
        const mq = window.matchMedia(query)
        const handler = (/** @type {MediaQueryListEvent} */ e) => set_narrow(e.matches)
        mq.addEventListener("change", handler)
        return () => mq.removeEventListener("change", handler)
    }, [query])
    return narrow
}

/**
 * The R status dot/words (ui-3.md, Header): shared between the header
 * button and the Status tab (ui-3-plan.md piece 5's "Status tab"). A run
 * shows only once it has lasted SETTLE_MS (useSettled.js).
 *
 * @param {{ connected: boolean, key_refused?: boolean, notebook: import("./Editor.js").NotebookData }} props
 * @returns {{ dot: "faint"|"accent"|"run"|"red"|"amber", words: string, title: string?, busy?: boolean }}
 */
export const use_r_status = ({ connected, key_refused = false, notebook }) => {
    const { n, i } = use_run_progress(notebook)
    return useSettled(r_status({ connected, key_refused, notebook, n, i }), (status, shown) => !!status.busy && !shown.busy)
}

/**
 * @param {{ connected: boolean, key_refused: boolean, notebook: import("./Editor.js").NotebookData, n: number, i: number }} props
 * @returns {{ dot: "faint"|"accent"|"run"|"red"|"amber", words: string, title: string?, busy?: boolean }}
 */
const r_status = ({ connected, key_refused, notebook, n, i }) => {
    if (!connected && key_refused) return { dot: "red", words: t("t_ember_r_status_key_refused"), title: t("t_ember_key_refused") }
    if (!connected) return { dot: "faint", words: t("t_ember_r_status_not_connected"), title: null }
    const process = notebook.ember?.process
    switch (process) {
        case "preview":
            return { dot: "faint", words: t("t_ember_r_status_preview"), title: null }
        case "starting":
            return { dot: "run", words: t("t_ember_r_status_starting"), title: null }
        case "busy":
            return { dot: "run", words: t("t_ember_r_status_busy", { i, n }), title: null, busy: true }
        case "stopped":
            return { dot: "red", words: t("t_ember_r_status_stopped"), title: null }
        case "ready":
        default: {
            const restart = notebook.ember?.plan?.restart ?? []
            if (restart.length > 0) {
                return {
                    dot: "amber",
                    words: t("t_ember_r_status_ready"),
                    title: t("t_ember_r_status_restart_title", { names: restart.join(", ") }),
                }
            }
            return { dot: "accent", words: t("t_ember_r_status_ready"), title: null }
        }
    }
}

/**
 * The sticky header (ui-3.md, Header; ui-3-plan.md piece 5's "Header
 * contents"): the flame, the file name, "Saved", "Run N not run", the R
 * status, the panel icons, Export and the ⋯ menu. Below 641px the three
 * panel icons become one "Side panel" icon and Export moves into ⋯.
 *
 * @param {{
 * notebook: import("./Editor.js").NotebookData,
 * connected: boolean,
 * key_refused?: boolean,
 * code_differs: boolean,
 * export_links: import("./ExportMenu.js").ExportLinks,
 * print_title: string,
 * on_open_move: () => void,
 * on_run_all: () => void,
 * on_interrupt: () => void,
 * }} props
 */
export const Header = ({ notebook, connected, key_refused = false, code_differs, export_links, print_title, on_open_move, on_run_all, on_interrupt }) => {
    const [open_tab, set_open_tab] = useState(/** @type {import("./BottomRightPanel.js").PanelTabName} */ (null))
    const last_tab_ref = useRef(/** @type {"variables"|"docs"|"packages"|"process"} */ ("docs"))

    useEventListener(
        window,
        "open_bottom_right_panel",
        (/** @type {CustomEvent} */ e) => {
            set_open_tab(e.detail)
            if (e.detail != null) last_tab_ref.current = e.detail
        },
        [set_open_tab]
    )

    const toggle = (/** @type {import("./BottomRightPanel.js").PanelTabName} */ tab) => open_bottom_right_panel(open_tab === tab ? null : tab)

    const narrow = use_narrow(640)
    const status = use_r_status({ connected, key_refused, notebook })
    const not_run = useSettled(notebook.ember?.not_run ?? 0, (count, shown) => count > shown)

    use_print_title(print_title)

    const { button_props, menu_props, item_props, close, is_open } = useMenu({ count: narrow ? 6 : 3 })

    return html`
        <nav id="at_the_top">
            <a
                href=${`./?secret=${page_secret()}`}
                title=${t("t_ember_start_my_notebooks")}
                aria-label=${t("t_ember_start_my_notebooks")}
                onClick=${(e) => {
                    if (is_desktop()) {
                        e.preventDefault()
                        open_main_menu()
                    }
                }}
            >
                <h1><${FlameLogo} /></h1>
            </a>
            <button id="ember-file-name" type="button" title=${notebook.path} onClick=${on_open_move}>${notebook.shortpath}</button>
            ${code_differs || !connected ? null : html`<span class="ember-saved">${t("t_ember_saved")}</span>`}
            <div class="ember-header-spacer"></div>
            ${not_run > 0
                ? html`<button class="ember-btn ember-fade-in" type="button" title=${t("t_ember_run_not_run_title", { count: not_run })} onClick=${on_run_all}>
                      ${t("t_ember_run_not_run", { count: not_run })}
                  </button>`
                : null}
            <button
                id="ember-r-status"
                type="button"
                title=${status.title ?? status.words}
                aria-label=${status.title ?? status.words}
                onClick=${() => toggle("process")}
            >
                <span class=${`ember-dot ember-dot-${status.dot}`} aria-hidden="true"></span>
                <span class="ember-r-status-words">${status.words}</span>
            </button>
            ${status.busy ? html`<button class="ember-btn ember-fade-in" type="button" onClick=${on_interrupt}>${t("t_stop")}</button>` : null}
            ${narrow
                ? html`
                      <button
                          class="ibtn"
                          type="button"
                          title=${t("t_ember_side_panel")}
                          aria-label=${t("t_ember_side_panel")}
                          aria-pressed=${open_tab != null}
                          onClick=${() => toggle(open_tab ?? last_tab_ref.current)}
                      >
                          <${SidePanelIcon} />
                      </button>
                  `
                : html`
                      <nav class="ember-panel-nav" aria-label=${t("t_ember_side_panel")}>
                          <button
                              class=${cl({ ibtn: true, on: open_tab === "variables" })}
                              type="button"
                              title=${t("t_panel_variables")}
                              aria-label=${t("t_panel_variables")}
                              aria-pressed=${open_tab === "variables"}
                              onClick=${() => toggle("variables")}
                          >
                              <${VariablesIcon} />
                          </button>
                          <button
                              class=${cl({ ibtn: true, on: open_tab === "docs" })}
                              type="button"
                              title=${t("t_panel_docs")}
                              aria-label=${t("t_panel_docs")}
                              aria-pressed=${open_tab === "docs"}
                              onClick=${() => toggle("docs")}
                          >
                              <${HelpIcon} />
                          </button>
                          <button
                              class=${cl({ ibtn: true, on: open_tab === "packages" })}
                              type="button"
                              title=${t("t_panel_packages")}
                              aria-label=${t("t_panel_packages")}
                              aria-pressed=${open_tab === "packages"}
                              onClick=${() => toggle("packages")}
                          >
                              <${PackagesIcon} />
                          </button>
                      </nav>
                      <${ExportMenu} links=${export_links} />
                  `}
            <div style="position: relative">
                <button class=${cl({ ibtn: true, on: is_open })} type="button" title=${t("t_ember_more")} aria-label=${t("t_ember_more")} ...${button_props}>
                    <${MoreIcon} />
                </button>
                ${is_open &&
                html`
                    <div class="ember-menu" ...${menu_props}>
                        <button
                            type="button"
                            class="ember-menuitem"
                            ...${item_props(0)}
                            onClick=${() => {
                                close()
                                window.dispatchEvent(new CustomEvent("ember open shortcuts"))
                            }}
                        >
                            ${t("t_ember_keyboard_shortcuts")}
                        </button>
                        <button
                            type="button"
                            class="ember-menuitem"
                            ...${item_props(1)}
                            onClick=${() => {
                                close()
                                window.dispatchEvent(new CustomEvent("pluto open settings"))
                            }}
                        >
                            ${t("t_settings_title")}
                        </button>
                        ${narrow ? [html`<div class="ember-menu-sep"></div>`, ...export_items({ links: export_links, item_props, first_index: 2, note_on_items: true, close })] : null}
                        <div class="ember-menu-sep"></div>
                        <a class="ember-menuitem" href=${`./?secret=${page_secret()}`} ...${item_props(narrow ? 5 : 2)}>
                            ${t("t_ember_open_another_notebook")}
                        </a>
                    </div>
                `}
            </div>
        </nav>
    `
}
