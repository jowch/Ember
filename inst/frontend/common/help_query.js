/**
 * The help topic a cell asks for when its whole code is one `?topic` line,
 * as typed at R's console: `?mean`, `? mean`, `?stats::sd`, `` ?`+` ``,
 * `?"if"`. The quotes and backticks R allows around a topic are dropped, so
 * the Help panel looks up the topic itself. `null` for anything else: a
 * cell with more code, `??search` (a search, not one page), or a `?` with
 * no topic. Running such a cell opens its page in the Help panel, which is
 * what `?mean` does at R's console (#558).
 */
export const help_query_of = (/** @type {string?} */ code) => {
    const m = /^\s*\?(?!\?)\s*(\S(?:.*\S)?)\s*$/.exec(code ?? "")
    if (m == null) return null
    let topic = m[1]
    const q = /^(?:([A-Za-z.][\w.]*):::?)?(`[^`]+`|"[^"]+"|'[^']+'|[^\s`"'()]+)$/.exec(topic)
    if (q == null) return null
    const name = /^[`"']/.test(q[2]) ? q[2].slice(1, -1) : q[2]
    return q[1] != null ? `${q[1]}::${name}` : name
}
