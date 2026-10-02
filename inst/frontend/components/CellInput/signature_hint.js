import { EditorView, StateField, StateEffect, showTooltip, syntaxTree } from "../../imports/CodemirrorPlutoSetup.js"

/**
 * The call the cursor is inside, if any: the innermost `Call` whose
 * `ArgList` contains the cursor (the same rule `get_selected_doc_from_state`
 * uses, ui-2.md "4d. Signatures"). `name`/`package` split a `pkg::name` or
 * `pkg:::name` callee; `pos` is where the tooltip anchors (the call's own
 * start, so it stays above the line while the user types arguments).
 */
function call_at_cursor(state) {
    let pos = state.selection.main.head
    let tree = syntaxTree(state)
    for (let n = tree.resolveInner(pos, -1); n != null; n = n.parent) {
        if (n.name === "ArgList" && n.parent?.name === "Call") {
            let call = n.parent
            let callee = call.firstChild
            if (callee == null) return null
            let text = state.doc.sliceString(callee.from, callee.to)
            let m = text.match(/^([.\p{L}\p{N}_]+):::?([.\p{L}\p{N}_]+)$/u)
            return { name: m ? m[2] : text, package: m ? m[1] : null, pos: call.from }
        }
    }
    return null
}

const set_signature_tooltip = StateEffect.define()

const signature_tooltip_field = StateField.define({
    create: () => null,
    update(value, tr) {
        for (let e of tr.effects) if (e.is(set_signature_tooltip)) value = e.value
        return value
    },
    provide: (f) => showTooltip.from(f),
})

const render_tooltip = (text) => ({
    create: () => {
        let dom = document.createElement("div")
        dom.className = "cm-ember-signature-tooltip"
        dom.textContent = text
        return { dom }
    },
})

/**
 * A CodeMirror extension: inside a call's arguments, a tooltip above the
 * line shows its signature (ui-2.md "4d. Signatures"). Debounced 150 ms,
 * cached per `pkg::name`.
 * @param {{ request_signature: (q: { name: string, package: string? }) => Promise<string?> }} props
 */
export function signature_hint({ request_signature }) {
    let last_key = null
    let cache = new Map()
    let timer = null

    let dispatch_tooltip = (view, pos, text) => {
        view.dispatch({
            effects: set_signature_tooltip.of(text == null ? null : { pos, above: true, create: render_tooltip(text).create }),
        })
    }

    let compute = (view) => {
        let call = call_at_cursor(view.state)
        if (call == null) {
            last_key = null
            dispatch_tooltip(view, 0, null)
            return
        }
        let key = `${call.package ?? ""}::${call.name}`
        last_key = key

        if (cache.has(key)) {
            if (last_key === key) dispatch_tooltip(view, call.pos, cache.get(key))
            return
        }
        request_signature({ name: call.name, package: call.package })
            .then((text) => {
                cache.set(key, text)
                if (last_key === key) dispatch_tooltip(view, call.pos, text)
            })
            .catch(() => {})
    }

    return [
        signature_tooltip_field,
        EditorView.updateListener.of((update) => {
            if (!update.docChanged && !update.selectionSet) return
            if (timer != null) clearTimeout(timer)
            timer = setTimeout(() => compute(update.view), 150)
        }),
    ]
}
