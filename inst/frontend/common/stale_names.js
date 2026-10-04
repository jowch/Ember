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
