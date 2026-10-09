import { StateField, StateEffect, ViewPlugin, showTooltip, syntaxTree } from "../../imports/CodemirrorPlutoSetup.js"

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
 * line shows its signature (ui-2.md "4d. Signatures"). Debounced 150 ms.
 *
 * Only `pkg::name`/`pkg:::name` answers are cached: a package's exports
 * don't change mid-session. An unqualified name may be a notebook
 * definition, which can be redefined with different arguments at any time,
 * so it's requested fresh every time. A `null` answer (worker busy, safe
 * preview, or the 5s timeout in CellInput.js) is never cached either way,
 * so the next keystroke or cursor move retries instead of showing nothing
 * forever.
 * @param {{ request_signature: (q: { name: string, package: string? }) => Promise<string?> }} props
 */
export function signature_hint({ request_signature }) {
    let cache = new Map()

    let dispatch_tooltip = (view, pos, text) => {
        view.dispatch({
            effects: set_signature_tooltip.of(text == null ? null : { pos, above: true, create: render_tooltip(text).create }),
        })
    }

    let plugin = ViewPlugin.define((view) => {
        let last_key = null
        let timer = null

        let compute = () => {
            // A cell can stay busy for a while (CellInput.js's 5s request
            // timeout); the cursor, and the view's focus, can easily have
            // moved to a different cell by the time this runs.
            if (!view.hasFocus) return
            let call = call_at_cursor(view.state)
            if (call == null) {
                last_key = null
                dispatch_tooltip(view, 0, null)
                return
            }
            let key = `${call.package ?? ""}::${call.name}`
            last_key = key

            if (cache.has(key)) {
                dispatch_tooltip(view, call.pos, cache.get(key))
                return
            }
            request_signature({ name: call.name, package: call.package })
                .then((text) => {
                    if (call.package != null && text != null) cache.set(key, text)
                    if (!view.hasFocus) return
                    if (last_key === key) dispatch_tooltip(view, call.pos, text)
                })
                .catch(() => {})
        }

        // Argument tooltips must not stay on screen: closing the
        // tooltip on blur isn't enough on its own -- the debounce timer
        // from a keystroke just before the blur, or a request_signature
        // promise already in flight, can still fire afterwards and reopen
        // it over whatever cell has focus next. Both need cancelling here
        // too; the view.hasFocus checks above are the second line of
        // defense for a promise that was in flight before the blur fired.
        let on_blur = () => {
            if (timer != null) {
                clearTimeout(timer)
                timer = null
            }
            last_key = null
            dispatch_tooltip(view, 0, null)
        }
        view.dom.addEventListener("blur", on_blur, true)

        return {
            update(update) {
                if (!update.docChanged && !update.selectionSet) return
                if (timer != null) clearTimeout(timer)
                timer = setTimeout(compute, 150)
            },
            destroy() {
                if (timer != null) clearTimeout(timer)
                view.dom.removeEventListener("blur", on_blur, true)
            },
        }
    })

    return [signature_tooltip_field, plugin]
}
