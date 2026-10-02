// This file is codemirror-pluto-setup@2002.0.8's src/basic-setup.ts
// (https://github.com/JuliaPluto/codemirror-pluto-setup, tag 2002.0.8),
// copied verbatim as plain JS (the file has no TypeScript-only syntax),
// plus the additions needed to build Ember's R language support: the
// Lezer/CodeMirror language-building blocks upstream doesn't export
// (LRLanguage, LanguageSupport, styleTags), and `r()` itself. See
// docs/ui-frontend.md for why this has to be a rebuild of the whole
// bundle rather than a second <script> loading grammar/dist/index.js.
export {
    EditorState,
    EditorSelection,
    Compartment,
    SelectionRange,
    Facet,
    StateField,
    StateEffect,
    StateEffectType,
    Transaction,
    Text,
    ChangeSet,
    combineConfig,
    Annotation,
    Prec,
} from "@codemirror/state"
export {
    keymap,
    EditorView,
    highlightSpecialChars,
    drawSelection,
    highlightActiveLine,
    placeholder,
    Decoration,
    ViewUpdate,
    ViewPlugin,
    WidgetType,
    lineNumbers,
    rectangularSelection,
    tooltips,
    showTooltip,
    MatchDecorator,
} from "@codemirror/view"
export {
    defaultKeymap,
    indentMore,
    indentLess,
    moveLineUp,
    moveLineDown,
    historyKeymap,
    history,
    invertedEffects,
} from "@codemirror/commands"
export {
    indentOnInput,
    indentUnit,
    syntaxTree,
    syntaxTreeAvailable,
    bracketMatching,
    foldGutter,
    foldKeymap,
    HighlightStyle,
    defaultHighlightStyle,
    syntaxHighlighting,
    StreamLanguage,
    delimitedIndent,
    LRLanguage,
    LanguageSupport,
} from "@codemirror/language"
export { closeBrackets, closeBracketsKeymap, completionKeymap } from "@codemirror/autocomplete"
export * as autocomplete from "@codemirror/autocomplete"
export {
    highlightSelectionMatches,
    searchKeymap,
    selectNextOccurrence,
} from "@codemirror/search"
export { collab, receiveUpdates, sendableUpdates, getSyncedVersion, getClientID } from "@codemirror/collab"
export { linter, setDiagnostics } from "@codemirror/lint"
export { TreeCursor, Tree, NodeProp, parseMixed, NodeWeakMap } from "@lezer/common"
export { tags, styleTags } from "@lezer/highlight"
export { LRParser } from "@lezer/lr"

// Language support
export { markdown, markdownLanguage } from "@codemirror/lang-markdown"
export { parseCode } from "@lezer/markdown"
export { html, htmlLanguage } from "@codemirror/lang-html"
export { css, cssLanguage } from "@codemirror/lang-css"
export { javascript, javascriptLanguage } from "@codemirror/lang-javascript"
export * as merge from "@codemirror/merge"

// Ember's addition: the R grammar, wired up the same way @plutojl/lang-julia
// wires up Julia's.
export { r, rLanguage } from "./r.js"
