import { combineConfig, Facet, StateField } from "../../imports/CodemirrorPlutoSetup.js"
import { syntaxTree } from "../../imports/CodemirrorPlutoSetup.js"
import { EditorView } from "../../imports/CodemirrorPlutoSetup.js"
import { Decoration } from "../../imports/CodemirrorPlutoSetup.js"

/**
 * ADAPTED MATCH BRACKETS PLUGIN FROM CODEMIRROR
 * Original: https://github.com/codemirror/matchbrackets/blob/99bf6b7e6891c09987269e370dc45ab1d588b875/src/matchbrackets.ts
 *
 * I changed it to ignore the closedBy and openBy properties provided by lezer, because these
 * are all wrong for julia... Also it doesn't do non-matching now, there is just matching or nothing.
 *
 * Ember: Pluto's `match_block`, which matched Julia's `begin ... end`-style blocks, is gone (#246).
 * R has no `end`, so it never matched. Only `()`, `[]` and `{}` are matched.
 */

const baseTheme = EditorView.baseTheme({
    ".cm-matchingBracket": { backgroundColor: "#328c8252" },
    ".cm-nonmatchingBracket": { backgroundColor: "#bb555544" },
})
const DefaultScanDist = 10000,
    DefaultBrackets = "()[]{}"
const bracketMatchingConfig = Facet.define({
    combine(configs) {
        return combineConfig(configs, {
            afterCursor: true,
            brackets: DefaultBrackets,
            maxScanDistance: DefaultScanDist,
        })
    },
})
const matchingMark = Decoration.mark({ class: "cm-matchingBracket" }),
    nonmatchingMark = Decoration.mark({ class: "cm-nonmatchingBracket" })
const bracketMatchingState = StateField.define({
    create() {
        return Decoration.none
    },
    update(deco, tr) {
        if (!tr.docChanged && !tr.selection) return deco
        let decorations = []
        let config = tr.state.facet(bracketMatchingConfig)
        for (let range of tr.state.selection.ranges) {
            if (!range.empty) continue
            let match =
                matchBrackets(tr.state, range.head, -1, config) ||
                (range.head > 0 && matchBrackets(tr.state, range.head - 1, 1, config)) ||
                (config.afterCursor &&
                    (matchBrackets(tr.state, range.head, 1, config) ||
                        (range.head < tr.state.doc.length && matchBrackets(tr.state, range.head + 1, -1, config))))
            if (!match) continue
            let mark = matchingMark
            for (let pos of match) {
                decorations.push(mark.range(pos.from, pos.to))
            }
        }
        return Decoration.set(decorations, true)
    },
    provide: (f) => EditorView.decorations.from(f),
})
const bracketMatchingUnique = [bracketMatchingState, baseTheme]
/// Create an extension that enables bracket matching. Whenever the
/// cursor is next to a bracket, that bracket and the one it matches
/// are highlighted. Or, when no matching bracket is found, another
/// highlighting style is used to indicate this.
export function bracketMatching(config = {}) {
    return [bracketMatchingConfig.of(config), bracketMatchingUnique]
}
/// Find the matching bracket for the token at `pos`, scanning
/// direction `dir`. Only the `brackets` and `maxScanDistance`
/// properties are used from `config`, if given. Returns null if no
/// bracket was found at `pos`, or a match result otherwise.
export function matchBrackets(state, pos, dir, config = {}) {
    let maxScanDistance = config.maxScanDistance || DefaultScanDist,
        brackets = config.brackets || DefaultBrackets
    let tree = syntaxTree(state),
        node = tree.resolveInner(pos, dir)

    return matchPlainBrackets(state, pos, dir, tree, bracket_node_name_normalizer(node.name), maxScanDistance, brackets)
}

function matchPlainBrackets(state, pos, dir, tree, tokenType, maxScanDistance, brackets) {
    let startCh = dir < 0 ? state.sliceDoc(pos - 1, pos) : state.sliceDoc(pos, pos + 1)
    let bracket = brackets.indexOf(startCh)
    if (bracket < 0 || (bracket % 2 == 0) != dir > 0) return null
    let startToken = { from: dir < 0 ? pos - 1 : pos, to: dir > 0 ? pos + 1 : pos }
    let iter = state.doc.iterRange(pos, dir > 0 ? state.doc.length : 0),
        depth = 0
    for (let distance = 0; !iter.next().done && distance <= maxScanDistance; ) {
        let text = iter.value
        if (dir < 0) distance += text.length
        let basePos = pos + distance * dir
        for (let pos = dir > 0 ? 0 : text.length - 1, end = dir > 0 ? text.length : -1; pos != end; pos += dir) {
            let found = brackets.indexOf(text[pos])
            if (found < 0 || bracket_node_name_normalizer(tree.resolve(basePos + pos, 1).name) != tokenType) continue
            if ((found % 2 == 0) == dir > 0) {
                depth++
            } else if (depth == 1) {
                // Closing
                if (found >> 1 == bracket >> 1) {
                    return [startToken, { from: basePos + pos, to: basePos + pos + 1 }]
                } else {
                    return null
                }
            } else {
                depth--
            }
        }
        if (dir > 0) distance += text.length
    }
    return iter.done ? [startToken] : null
}

/**
 * Little modification to the original matchPlainBrackets function: in our Julia language, the node that opens a bracket is called "(". In e.g. markdown it's called LinkMark or something (the same name for opening and closing). We don't have this so we make them equal.
 *
 * Ember: the R grammar (grammar/src/r.grammar) names its brackets, with different names for the
 * opening and the closing one, and a call's `(`, a `[` and a `[[` are tokens of their own. Without
 * these, an R bracket's partner never matched and only the bracket at the cursor was marked (#246).
 */
const bracket_node_name_normalizer = (/** @type {String} */ node_name) => {
    switch (node_name) {
        case "(":
        case ")":
        case "ParenL":
        case "ContinueParenL":
        case "ParenR":
            return "()"
        case "[":
        case "]":
        case "ContinueBracketL":
        case "ContinueDBracketL":
        case "BracketR":
            return "[]"
        case "{":
        case "}":
        case "BraceL":
        case "BraceR":
            return "{}"
        default:
            return node_name
    }
}
