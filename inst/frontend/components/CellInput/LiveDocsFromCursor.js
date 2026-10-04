import { syntaxTree } from "../../imports/CodemirrorPlutoSetup.js"

// rHighlight's node names for a literal the cursor should never trigger
// docs from (codemirror-ember-setup.js).
const NEVER_SEARCHABLE = new Set(["String", "RawString", "Comment", "Number"])

// An R name as `help()` takes it: a syntactic name or a backticked one,
// optionally `pkg::` or `pkg:::` in front. A selection that isn't one (a
// word fragment from prose, a whole cell) is not a docs query.
const NAME = String.raw`(?:[\p{L}.][\p{L}\p{N}._]*|\x60[^\x60\n]+\x60)`
const NAME_SHAPED = new RegExp(`^(?:${NAME}:::?)?${NAME}$`, "u")

const is_text_line = (/** @type {string} */ line) => /^\s*#'/.test(line)

/** The callee of a `Call` node: its first child (an `Identifier`,
 * `NamespaceExpr` ("pkg::name"), `MemberExpr`, or a parenthesized
 * expression), as the text the user wrote. */
function callee_text(state, call_node) {
    let callee = call_node.firstChild
    if (callee == null) return undefined
    return state.doc.sliceString(callee.from, callee.to)
}

/**
 * The query to search docs for, from the cursor position (or the
 * selection, if non-empty): the callee of the innermost `Call` whose
 * `ArgList` contains the cursor (so typing a call's arguments keeps
 * showing that call's docs); else the `Identifier` under the cursor; else
 * the operand of a `HelpExpr` (`?lm`). Nothing inside a string, a comment
 * or a number, nor on a `#'` text line; a selection only when it is one
 * line, name-shaped and outside those.
 * @param {import("../../imports/CodemirrorPlutoSetup.js").EditorState} state
 */
export let get_selected_doc_from_state = (state) => {
    let selection = state.selection.main

    let first_line = state.doc.lineAt(selection.from)
    if (is_text_line(first_line.text)) return undefined

    if (!selection.empty) {
        if (state.doc.lineAt(selection.to).number !== first_line.number) return undefined
        let selected = state.doc.sliceString(selection.from, selection.to).trim()
        if (!NAME_SHAPED.test(selected)) return undefined
        for (let n = syntaxTree(state).resolveInner(selection.from, 1); n != null; n = n.parent) {
            if (NEVER_SEARCHABLE.has(n.name)) return undefined
        }
        return selected
    }

    // A cell starting with `?` is a docs query by itself, verbatim.
    let current_line = state.doc.lineAt(selection.from).text
    if (current_line[0] === "?") {
        return current_line.slice(1)
    }

    let tree = syntaxTree(state)
    let pos = selection.from
    let node = tree.resolveInner(pos, -1)

    for (let n = node; n != null; n = n.parent) {
        if (NEVER_SEARCHABLE.has(n.name)) return undefined
    }

    for (let n = node; n != null; n = n.parent) {
        if (n.name === "ArgList" && n.parent?.name === "Call") {
            return callee_text(state, n.parent)
        }
    }

    for (let n = node; n != null; n = n.parent) {
        if (n.name === "Identifier" || n.name === "Backtick") {
            return state.doc.sliceString(n.from, n.to)
        }
        if (n.name === "NamespaceExpr") {
            return state.doc.sliceString(n.from, n.to)
        }
        if (n.name === "Call") {
            return callee_text(state, n)
        }
        if (n.name === "HelpExpr") {
            // `?lm`: the operand is whichever child isn't the `?` token.
            let operand = n.getChild("Identifier") ?? n.getChild("NamespaceExpr") ?? n.getChild("Call")
            return operand ? state.doc.sliceString(operand.from, operand.to) : undefined
        }
        if (n.name === "Program") break
    }

    return undefined
}
