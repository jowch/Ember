// R language support for CodeMirror 6, built from Ember's own Lezer
// grammar (grammar/, exporting rParser). Highlighting tags are already
// attached to rParser by grammar/src/highlight.js (compiled in via the
// grammar's `@external propSource`); here we add the CodeMirror-side
// pieces the grammar package deliberately doesn't depend on: fold ranges,
// indentation, and bracket matching, then wrap it all in a
// LanguageSupport so `r()` drops in wherever `julia()` did
// (components/CellInput.js).
import { rParser } from "@ember/lezer-r"
import { NodeProp } from "@lezer/common"
import { LRLanguage, LanguageSupport, indentNodeProp, foldNodeProp, foldInside, delimitedIndent } from "@codemirror/language"

const configuredParser = rParser.configure({
    props: [
        indentNodeProp.add({
            Block: delimitedIndent({ closing: "}" }),
            ParenExpr: delimitedIndent({ closing: ")" }),
            ParamList: delimitedIndent({ closing: ")" }),
            ArgList: delimitedIndent({ closing: ")" }),
        }),
        foldNodeProp.add({
            Block: foldInside,
            ParenExpr: foldInside,
            ParamList: foldInside,
            ArgList: foldInside,
        }),
        // Bracket matching for (), {} and single-bracket [...]. `[[...]]`
        // (Subscript2) isn't matched pairwise here: its two BracketR
        // closing tokens aren't distinguishable from a single `]` by node
        // type alone. Falling back to CodeMirror's textual bracket
        // matching for that case is an accepted gap for increment 1.
        NodeProp.openedBy.add({
            ParenR: ["ParenL"],
            BraceR: ["BraceL"],
            BracketR: ["ContinueBracketL"],
        }),
        NodeProp.closedBy.add({
            ParenL: ["ParenR"],
            BraceL: ["BraceR"],
            ContinueBracketL: ["BracketR"],
        }),
    ],
})

export const rLanguage = LRLanguage.define({
    parser: configuredParser,
    languageData: {
        commentTokens: { line: "#" },
        closeBrackets: { brackets: ["(", "[", "{", '"', "'"] },
        indentOnInput: /^\s*[)\]}]$/,
    },
})

export function r() {
    return new LanguageSupport(rLanguage)
}
