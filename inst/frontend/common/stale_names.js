/**
 * Names this cell reads whose defining cell ran after this cell's last
 * run, or is itself stale: what "Stale · x changed" lists (ui-3.md,
 * "Chips"). Sorted; [] when none is known (a sourced file changed), and
 * the chip then says "Stale".
 *
 * @param {import("../components/Editor.js").NotebookData} notebook
 * @param {string} cell_id
 * @returns {string[]}
 */
export const stale_names = (notebook, cell_id) => {
    const upstream = notebook.cell_dependencies?.[cell_id]?.upstream_cells_map ?? {}
    const this_ts = notebook.cell_results?.[cell_id]?.output?.last_run_timestamp ?? 0

    const names = new Set()
    for (const [name, definers] of Object.entries(upstream)) {
        for (const definer_id of definers) {
            const definer_result = notebook.cell_results?.[definer_id]
            if (definer_result == null) continue
            const definer_ts = definer_result.output?.last_run_timestamp ?? 0
            if (definer_result.ember?.stale || definer_ts > this_ts) {
                names.add(name)
                break
            }
        }
    }
    return [...names].sort()
}

/**
 * The one cell other than `cell_id` that defines `name`, or null when no
 * cell or more than one does: a chip or note naming it links there (#285).
 *
 * @param {import("../components/Editor.js").NotebookData} notebook
 * @param {string} cell_id
 * @param {string} name
 * @returns {string?}
 */
export const defining_cell = (notebook, cell_id, name) => {
    const definers = (notebook.cell_order ?? []).filter(
        (id) => id !== cell_id && Object.hasOwn(notebook.cell_dependencies?.[id]?.downstream_cells_map ?? {}, name)
    )
    return definers.length === 1 ? definers[0] : null
}
