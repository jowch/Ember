import { html, useRef } from "../imports/Preact.js"
import { cl } from "../common/ClassTable.js"
import { t } from "../common/lang.js"
import { useEventListener } from "../common/useEventListener.js"
import { useMenu } from "../common/useMenu.js"
import { ExportIcon, WarningIcon } from "../common/Icons.js"

/**
 * @typedef ExportLinks
 * @property {string} file_url
 * @property {string} html_url
 * @property {string} file_name
 * @property {boolean} safe_preview
 */

/** Anchors don't activate on Space by themselves, unlike the menu's buttons. */
const space_clicks = (/** @type {KeyboardEvent} */ e) => {
    if (e.key === " ") {
        e.preventDefault()
        /** @type {HTMLElement} */ (e.currentTarget).click()
    }
}

/** Props for one item: named by its title alone, described by the line under it and, if `note`, the safe-preview note. */
const item = (/** @type {string} */ id, /** @type {string} */ title, /** @type {string} */ description, /** @type {boolean} */ note) => ({
    "aria-labelledby": `${id}-title`,
    "aria-describedby": note ? `${id}-desc ember-export-note` : `${id}-desc`,
    children: html`
        <span class="ember-menuitem-title" id=${`${id}-title`}>${title}</span>
        <span class="ember-menuitem-desc" id=${`${id}-desc`}>${description}</span>
    `,
})

/**
 * The three export items, and the safe-preview note before them. Shared by
 * the Export menu and the narrow header's ⋯ menu, which takes the items
 * from `first_index` on. The Export menu itself is described by the note;
 * in the ⋯ menu, `note_on_items` has each item described by it instead.
 *
 * @param {{
 *   links: ExportLinks,
 *   item_props: (i: number) => Record<string, any>,
 *   first_index?: number,
 *   note_on_items?: boolean,
 *   close: () => void,
 * }} props
 */
export const export_items = ({ links, item_props, first_index = 0, note_on_items = false, close }) => {
    const { file_url, html_url, file_name, safe_preview } = links
    const note = safe_preview && note_on_items
    const code_only = t("t_export_code_only")
    return [
        safe_preview
            ? html`<div class="ember-menu-note" id="ember-export-note">
                  <${WarningIcon} />
                  <span>${t("t_export_safe_preview_note")}</span>
              </div>`
            : null,
        html`<a
            class="ember-menuitem"
            href=${file_url}
            download=${file_name}
            ...${item_props(first_index)}
            ...${item("ember-export-r", t("t_export_download_r"), t("t_export_download_r_description"), note)}
            onClick=${() => close()}
            onKeyDown=${space_clicks}
        />`,
        html`<a
            class="ember-menuitem"
            href=${html_url}
            download=""
            ...${item_props(first_index + 1)}
            ...${item("ember-export-html", t("t_export_download_html"), safe_preview ? code_only : t("t_export_download_html_description"), note)}
            onClick=${() => close()}
            onKeyDown=${space_clicks}
        />`,
        html`<a
            class="ember-menuitem"
            href="#"
            ...${item_props(first_index + 2)}
            ...${item("ember-export-print", t("t_export_print"), safe_preview ? code_only : t("t_export_print_description"), note)}
            onClick=${(/** @type {MouseEvent} */ e) => {
                e.preventDefault()
                close()
                window.print()
            }}
            onKeyDown=${space_clicks}
        />`,
    ]
}

/**
 * While printing, the document title is the notebook's name without `.R`,
 * which browsers offer as the PDF's file name.
 */
export const use_print_title = (/** @type {string} */ print_title) => {
    const old_title_ref = useRef("")
    useEventListener(
        window,
        "beforeprint",
        (/** @type {CustomEvent} */ e) => {
            if (!e.detail?.fake) {
                old_title_ref.current = document.title
                document.title = print_title.replace(/\.R$/i, "")
            }
        },
        [print_title]
    )
    useEventListener(
        window,
        "afterprint",
        () => {
            document.title = old_title_ref.current
        },
        [print_title]
    )
}

/**
 * The header's Export button and its menu (ui-3.md, Menus and Settings):
 * Download .R file, Download HTML, Print or save as PDF.
 *
 * @param {{ links: ExportLinks }} props
 */
export const ExportMenu = ({ links }) => {
    const { button_props, menu_props, item_props, close, is_open } = useMenu({ count: 3 })
    return html`
        <div style="position: relative">
            <button
                class=${cl({ ibtn: true, toggle_export: true, on: is_open })}
                type="button"
                title=${t("t_ember_export")}
                aria-label=${t("t_ember_export")}
                ...${button_props}
            >
                <${ExportIcon} />
            </button>
            ${is_open &&
            html`<div
                class="ember-menu ember-export-menu"
                aria-label=${t("t_ember_export")}
                aria-describedby=${links.safe_preview ? "ember-export-note" : undefined}
                ...${menu_props}
            >
                ${export_items({ links, item_props, close })}
            </div>`}
        </div>
    `
}
