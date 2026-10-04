import { html, useState, useEffect } from "../imports/Preact.js"
import { cl } from "../common/ClassTable.js"
import { t } from "../common/lang.js"

export const UndoDelete = ({ recently_deleted, on_click }) => {
    const [hidden, set_hidden] = useState(true)

    useEffect(() => {
        if (recently_deleted != null && recently_deleted.length > 0) {
            set_hidden(false)
            const interval = setTimeout(
                () => {
                    set_hidden(true)
                },
                8000 * Math.pow(recently_deleted.length, 1 / 3)
            )

            return () => {
                clearTimeout(interval)
            }
        }
    }, [recently_deleted])

    let text = recently_deleted == null ? "" : t("t_undo_delete", { count: recently_deleted.length })

    return html`
        <nav id="undo_delete" inert=${hidden} class=${cl({ hidden })}>
            ${text} · <a
                href="#"
                onClick=${(e) => {
                    e.preventDefault()
                    set_hidden(true)
                    on_click()
                }}
                >${t("t_undo_delete_link")}</a
            >
        </nav>
    `
}
