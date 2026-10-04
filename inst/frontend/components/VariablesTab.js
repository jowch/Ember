import { html, useMemo, useState } from "../imports/Preact.js"
import { cl } from "../common/ClassTable.js"
import { t } from "../common/lang.js"
import { scroll_cell_into_view } from "./Scroller.js"

/** Scrolls to and selects the cell that defines a variable (Editor.js
 * listens for this; there is no action to set `selected_cells` from a
 * child component otherwise). */
const go_to_cell = (/** @type {string} */ cell_id) => {
    scroll_cell_into_view(cell_id)
    window.dispatchEvent(new CustomEvent("ember_select_cell", { detail: cell_id }))
}

/** @param {import("./Editor.js").EmberVariable} v */
const VariableValue = ({ v }) => {
    switch (v.kind) {
        case "value":
            return html`<span class="ember-mono">${v.value}</span>`
        case "shape":
            return html`<span class="ember-faint-text">${v.value}</span>`
        case "str":
            return html`<span class="ember-faint-text ember-variables-str">${v.value}</span>`
        default:
            return null
    }
}

/**
 * The "Variables" tab (ui-3.md, Side panel; ui-3-plan.md piece 5's "Tabs"):
 * collects piece 3's per-cell lists -- for each id in `cell_order`, each
 * entry of `cell_results[id].ember.variables` -- into one alphabetical
 * table. Clicking a name scrolls to and selects its defining cell; a
 * stale cell's rows are faint.
 *
 * @param {{ notebook: import("./Editor.js").NotebookData }} props
 */
export const VariablesTab = ({ notebook }) => {
    const [filter, set_filter] = useState("")

    const variables = useMemo(() => {
        const all = notebook.cell_order.flatMap((id) => {
            const result = notebook.cell_results[id]
            const vars = result?.ember?.variables ?? []
            return vars.map((v) => ({ ...v, cell_id: id, stale: result?.ember?.stale === true }))
        })
        return all.sort((a, b) => a.name.localeCompare(b.name))
    }, [notebook.cell_order, notebook.cell_results])

    const filtered = filter.trim() === "" ? variables : variables.filter((v) => v.name.toLowerCase().includes(filter.trim().toLowerCase()))

    if (variables.length === 0) {
        const empty_text = notebook.ember?.process === "preview" ? t("t_ember_variables_preview_empty") : t("t_ember_variables_empty")
        return html`<div id="ember-variables-tab"><p class="ember-variables-empty">${empty_text}</p></div>`
    }

    const worker_memory = notebook.ember?.worker_memory
    const memory_mb = worker_memory == null ? null : Math.round(worker_memory / 1024 / 1024)

    return html`
        <div id="ember-variables-tab">
            <div class="ember-variables-filter">
                <input
                    type="search"
                    placeholder=${t("t_ember_variables_filter")}
                    value=${filter}
                    onInput=${(e) => set_filter(e.target.value)}
                />
            </div>
            <table class="ember-variables-table">
                <colgroup>
                    <col style="width: 26%" />
                    <col style="width: 26%" />
                    <col />
                </colgroup>
                <thead>
                    <tr>
                        <th>${t("t_ember_variables_column_name")}</th>
                        <th>${t("t_ember_variables_column_type")}</th>
                        <th>${t("t_ember_variables_column_value")}</th>
                    </tr>
                </thead>
                <tbody>
                    ${filtered.map(
                        (v) => html`<tr class=${cl({ "ember-variable-row": true, stale: v.stale })} key=${`${v.cell_id}-${v.name}`}>
                            <td class="ember-mono">
                                <a
                                    href="#"
                                    class="ember-variable-name"
                                    title=${v.stale ? t("t_ember_variables_stale_title") : null}
                                    onClick=${(e) => {
                                        e.preventDefault()
                                        go_to_cell(v.cell_id)
                                    }}
                                >
                                    ${v.name}
                                </a>
                            </td>
                            <td>${v.type}</td>
                            <td><${VariableValue} v=${v} /></td>
                        </tr>`
                    )}
                </tbody>
            </table>
            <div class="ember-variables-footer">
                <span>${t("t_ember_variables_count", { count: filtered.length })}</span>
                ${memory_mb == null ? null : html`<span>${t("t_ember_variables_memory", { mb: memory_mb })}</span>`}
            </div>
        </div>
    `
}
