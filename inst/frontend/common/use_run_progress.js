import _ from "../imports/lodash-es.js"
import { useEffect, useState } from "../imports/Preact.js"

/**
 * "Running {{i}} of {{n}} cells" (ui-3.md, Header; ui-3-plan.md piece 5's
 * "Header contents"): `n` is every cell that has been running or queued
 * since the current run started (it only grows, until nothing is left
 * running), `i` is how many of them are done, plus the one now running,
 * capped at `n` so it never reads "6 of 5". Shared with ProgressBar.js,
 * which this hook's `recently_running`/`currently_running` counting used
 * to live in alone.
 *
 * @param {import("../components/Editor.js").NotebookData} notebook
 * @returns {{ n: number, i: number }}
 */
export const use_run_progress = (notebook) => {
    const [recently_running, set_recently_running] = useState(/** @type {string[]} */ ([]))
    const [currently_running, set_currently_running] = useState(/** @type {string[]} */ ([]))

    useEffect(
        () => {
            const currently = Object.values(notebook.cell_results)
                .filter((c) => c.running || c.queued)
                .map((c) => c.cell_id)

            set_currently_running(currently)

            if (currently.length === 0) {
                set_recently_running([])
            } else {
                set_recently_running(_.union(currently, recently_running))
            }
        },
        Object.values(notebook.cell_results).map((c) => c.running || c.queued)
    )

    const n = recently_running.length
    const done = n - currently_running.length
    const i = n === 0 ? 0 : Math.min(n, done + 1)

    return { n, i, recently_running, currently_running }
}
