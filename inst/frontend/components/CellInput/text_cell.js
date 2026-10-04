import { Decoration, EditorSelection, Prec, ViewPlugin, autocomplete, keymap } from "../../imports/CodemirrorPlutoSetup.js"

const hash_quote_re = /^(\s*)#'/

/**
 * Enter after the `#'` of a line starting `#'` (after optional spaces)
 * starts the next line with `#' ` at the same indent (ui-3.md, "Text
 * cells"). With the cursor at or before the prefix, Enter is plain Enter.
 */
export const hash_quote_continue = Prec.high(
    keymap.of([
        {
            key: "Enter",
            run: (view) => {
                const { state } = view
                // At this precedence the binding runs before the completion
                // keymap's, so it steps aside while a completion is open.
                if (autocomplete.completionStatus(state) === "active") return false
                if (state.readOnly || state.selection.ranges.some((r) => !r.empty)) return false
                const after_prefix = (head) => {
                    const line = state.doc.lineAt(head)
                    const m = line.text.match(hash_quote_re)
                    return m != null && head - line.from >= m[0].length
                }
                if (!state.selection.ranges.every((r) => after_prefix(r.head))) return false
                view.dispatch(
                    state.changeByRange((range) => {
                        const indent = /** @type {RegExpMatchArray} */ (state.doc.lineAt(range.head).text.match(hash_quote_re))[1]
                        const insert = `\n${indent}#' `
                        return {
                            changes: { from: range.head, insert },
                            range: EditorSelection.cursor(range.head + insert.length),
                        }
                    }),
                    { scrollIntoView: true, userEvent: "input" }
                )
                return true
            },
        },
    ])
)

const line_deco = Decoration.line({ class: "cm-ember-hq-line" })
const prefix_deco = Decoration.mark({ class: "cm-ember-hq" })
const heading_deco = Decoration.mark({ class: "cm-ember-md-h" })
const bold_deco = Decoration.mark({ class: "cm-ember-md-b" })
const inline_r_deco = Decoration.mark({ class: "cm-ember-r" })

const bold_re = /(\*\*|__)(?=\S)(.+?)\1/g
const inline_r_re = /`r[ \t][^`]*`/g

const hash_quote_decorations = (view) => {
    const ranges = []
    const { doc } = view.state
    const { from, to } = view.viewport
    for (let pos = from; pos <= to; ) {
        const line = doc.lineAt(pos)
        const m = line.text.match(/^(\s*)#'( ?)/)
        if (m) {
            const body_start = m[0].length
            const body = line.text.slice(body_start)
            const at = (i) => line.from + body_start + i
            ranges.push(line_deco.range(line.from))
            ranges.push(prefix_deco.range(line.from + m[1].length, at(0)))
            if (/^\s*#{1,6}(\s|$)/.test(body)) {
                ranges.push(heading_deco.range(at(0), line.to))
            } else {
                for (const b of body.matchAll(bold_re)) ranges.push(bold_deco.range(at(b.index), at(b.index + b[0].length)))
            }
            for (const r of body.matchAll(inline_r_re)) ranges.push(inline_r_deco.range(at(r.index), at(r.index + r[0].length)))
        }
        pos = line.to + 1
    }
    return Decoration.set(ranges, true)
}

/**
 * Marks the rendered `#'` lines by their text alone: the prefix
 * (`cm-ember-hq`), a heading line (`cm-ember-md-h`), `**bold**` or
 * `__bold__` (`cm-ember-md-b`) and `` `r expr` `` (`cm-ember-r`). The R
 * grammar reads each such line as a comment, so the line also gets
 * `cm-ember-hq-line`, under which cells.css undoes the comment colour.
 */
export const hash_quote_highlight = ViewPlugin.fromClass(
    class {
        constructor(view) {
            this.decorations = hash_quote_decorations(view)
        }
        update(update) {
            if (update.docChanged || update.viewportChanged) this.decorations = hash_quote_decorations(update.view)
        }
    },
    { decorations: (v) => v.decorations }
)
