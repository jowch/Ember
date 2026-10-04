import _ from "../../imports/lodash-es.js"

import { EditorView, keymap, autocomplete, syntaxTree } from "../../imports/CodemirrorPlutoSetup.js"
import { get_selected_doc_from_state } from "./LiveDocsFromCursor.js"
import { cl } from "../../common/ClassTable.js"
import { open_bottom_right_panel } from "../BottomRightPanel.js"
import { GlobalDefinitionsFacet } from "./go_to_definition_plugin.js"

// R's string node names (rHighlight in codemirror-ember-setup.js): not
// mixedParsers.js's STRING_NODE_NAMES, which is Julia's set (for `md"""`
// mixed-language strings, which R has none of).
const R_STRING_NODE_NAMES = new Set(["String", "RawString"])

let { autocompletion, completionKeymap, completionStatus, acceptCompletion, selectedCompletion } = autocomplete

// These should be imported from  @codemirror/autocomplete, but they are not exported.
const completionState = autocompletion()[1]

/** @param {EditorView} cm */
const tab_completion_command = (cm) => {
    // This will return true if the autocomplete select popup is open
    if (acceptCompletion(cm)) {
        return true
    }
    if (cm.state.readOnly) {
        return false
    }

    let selection = cm.state.selection.main
    if (!selection.empty) return false

    let last_char = cm.state.sliceDoc(selection.from - 1, selection.from)
    let last_line = cm.state.sliceDoc(cm.state.doc.lineAt(selection.from).from, selection.from)

    // Some exceptions for when to trigger tab autocomplete
    if ("\t \n=".includes(last_char)) return false
    // ?lm(1, 2)<TAB> should trigger autocomplete
    if (last_char === ")" && !last_line.includes("?")) return false

    return autocomplete.startCompletion(cm)
}

let open_docs_if_autocomplete_is_open_command = (cm) => {
    if (autocomplete.completionStatus(cm.state) != null) {
        open_bottom_right_panel("docs")
        return true
    }
    return false
}

const pluto_autocomplete_keymap = (/** @type {boolean} */ tab_completes) => [
    ...(tab_completes ? [{ key: "Tab", run: tab_completion_command }] : []),
    { key: "?", run: open_docs_if_autocomplete_is_open_command },
]

/**
 * @param {(query: string) => void} on_update_doc_query
 */
let update_docs_from_autocomplete_selection = (on_update_doc_query) => {
    let last_query = null

    return EditorView.updateListener.of((update) => {
        if (selectedCompletion(update.state) == null) return

        let autocompletion_state = update.state.field(completionState, false)
        let open_autocomplete = autocompletion_state?.open
        if (open_autocomplete == null) return

        let selected_option = open_autocomplete.options[open_autocomplete.selected]
        let text_to_apply = selected_option.completion.apply ?? selected_option.completion.label
        if (typeof text_to_apply !== "string") return

        const active_result = update.view.state.field(completionState).active.find((a) => a.source == selected_option.source)
        if (active_result?.hasResult?.() !== true) return // not an ActiveResult instance

        const from = active_result.from,
            to = Math.min(active_result.to, update.state.doc.length)

        let result_transaction = update.state.update({
            changes: { from, to, insert: text_to_apply },
        })

        let docs_string = get_selected_doc_from_state(result_transaction.state)
        if (docs_string != null) {
            if (last_query != docs_string) {
                last_query = docs_string
                on_update_doc_query(docs_string)
            }
        }
    })
}

const section_regular = {
    name: "Suggestions",
    header: () => document.createElement("div"),
    rank: 0,
}

// R's reserved words (`?Reserved`); `TRUE`/`FALSE`/`NULL`/`Inf`/`NaN`/`NA*`
// are identifiers syntactically, but offered here the same way.
export const sorted_keywords = [
    "break",
    "else",
    "FALSE",
    "for",
    "function",
    "if",
    "Inf",
    "NA",
    "NA_character_",
    "NA_complex_",
    "NA_integer_",
    "NA_real_",
    "NaN",
    "next",
    "NULL",
    "repeat",
    "TRUE",
    "while",
]

const endswith_keyword_regex = new RegExp(`^(.*[^\\p{L}\\p{N}._])?(${sorted_keywords.join("|")})$`, "u")

const keyword_completions = sorted_keywords.map((label) => ({
    label,
    apply: label,
    type: "completion_keyword",
    section: section_regular,
}))

/** An R identifier, after the point other characters (an operator, a
 * bracket, whitespace) rule completion out: letters, digits, `.` and `_`
 * (R's `is_wc_cat_id_start`-ish rule, simplified -- `make.names()`'s own
 * character class, which is what both the worker's and the fallback's
 * names are drawn from). `$`/`@` are field access, not part of a name.
 * Anchored at the cursor, for `matchBefore()` (CodeMirror only accepts a
 * match that touches the cursor when the regex ends in `$`). */
const identifier_char_before_cursor = /[\p{L}\p{N}._]$/u
/** The same class, anchored start-to-end, for `validFor`: unanchored,
 * `RegExp.test()` matches anywhere in the typed-so-far text, so typing
 * `::` after `stats` would still "validate" against the word `stats` and
 * CodeMirror would never ask the source again. */
const identifier_token = /^[\p{L}\p{N}._]*$/u

/** Inside a `#` comment or a `#'` text line. The line test covers a
 * comment-only line before the parser has reached it. */
const in_comment = (/** @type {autocomplete.CompletionContext} */ ctx) => {
    if (/^\s*#/.test(ctx.state.doc.lineAt(ctx.pos).text)) return true
    for (let n = syntaxTree(ctx.state).resolveInner(ctx.pos, -1); n != null; n = n.parent) {
        if (n.name === "Comment") return true
    }
    return false
}

const not_explicit_and_too_boring = (/** @type {autocomplete.CompletionContext} */ ctx) => {
    if (ctx.explicit) return false
    // Not ":" alone: "pkg::" and "pkg:::" must keep completing.
    if (ctx.matchBefore(/[\s=)+\-/,*'(;\[\]{}"]$/)) return true
    if (ctx.matchBefore(/[^:]:$/)) return true
    if (ctx.tokenBefore(["IntegerLiteral", "FloatLiteral"]) != null) return true
    if (in_comment(ctx)) return true
    if (ctx.tokenBefore([...R_STRING_NODE_NAMES]) != null) return true
    return false
}

/**
 * Are we currently writing a variable name (so autocomplete would just be
 * in the way)? The left side of an `AssignExpr` (`x <- ...` or `... -> x`),
 * a `ParamName` (a function definition's own parameter), or an `ArgName`
 * (a call's `name = value`).
 */
const writing_variable_name_or_keyword = (/** @type {autocomplete.CompletionContext} */ ctx) => {
    if (ctx.matchBefore(endswith_keyword_regex)) return true

    let node = syntaxTree(ctx.state).resolve(ctx.pos, -1)
    if (node == null) return false
    let parent = node.parent
    // ParamName/ArgName wrap an Identifier (rHighlight's "ParamName/Identifier",
    // "ArgName/Identifier"); they are not the identifier node themselves.
    if (parent?.name === "ParamName" || parent?.name === "ArgName") return true

    if (node.name === "Identifier" && parent?.name === "AssignExpr") {
        let op = parent.getChild("AssignOp")
        if (op == null) return false
        let op_text = ctx.state.sliceDoc(op.from, op.to)
        let is_left_assign = op_text === "<-" || op_text === "<<-" || op_text === "="
        let is_our_side = is_left_assign ? node.to <= op.from : node.from >= op.to
        return is_our_side
    }
    return false
}

/** Use the completion results from the server to create CM completion
 * objects (R's `pkg::`, `$`-column, notebook and base-R names). */
const r_completions_to_cm =
    (/** @type {PlutoRequestAutocomplete} */ request_autocomplete) =>
    /** @returns {Promise<autocomplete.CompletionResult?>} */
    async (/** @type {autocomplete.CompletionContext} */ ctx) => {
        if (!ctx.explicit && writing_variable_name_or_keyword(ctx)) return null
        if (not_explicit_and_too_boring(ctx)) return null

        let to_complete_full = /** @type {String} */ (ctx.state.sliceDoc(0, ctx.pos))

        let found = await request_autocomplete({ query_full: to_complete_full })
        // A newer keystroke (e.g. typing the `$` right after `df`) started
        // its own request while this one was in flight; CodeMirror doesn't
        // drop a stale resolved promise on its own, so an older answer
        // (fallback results from before the worker caught up) could
        // otherwise replace a newer, better one that already landed.
        if (ctx.aborted) return null
        if (!found) return null
        let { start, stop, results, too_long } = found

        const globals = ctx.state.facet(GlobalDefinitionsFacet)
        const is_already_a_global = (text) => text != null && Object.keys(globals).includes(text)

        const to_complete_onto = to_complete_full.slice(0, start)

        const skip_filter = ctx.matchBefore(/~[^\s"]*/) != null

        return {
            from: start,
            to: ctx.pos,
            validFor: too_long ? undefined : identifier_token,
            filter: !skip_filter,
            options: results
                .filter(([text, _1, _2, is_from_notebook, completion_type]) => (ctx.explicit || completion_type != "path") && !is_already_a_global(text))
                .map(([text, value_type, is_exported, is_from_notebook, completion_type]) => ({
                    label: text,
                    apply: text,
                    type:
                        cl({
                            c_notexported: !is_exported,
                            [`c_${value_type}`]: true,
                            [`completion_${completion_type}`]: true,
                            c_from_notebook: is_from_notebook,
                        }) ?? undefined,
                    section: section_regular,
                    boost: completion_type === "keyword_argument" ? 7 : undefined,
                })),
        }
    }

const complete_keyword = async (/** @type {autocomplete.CompletionContext} */ ctx) => {
    if (
        ctx.matchBefore(/[\s([][a-zA-Z]*$/) == null &&
        ctx.matchBefore(/^[a-zA-Z]*$/) == null
    )
        return null
    if (!ctx.explicit && writing_variable_name_or_keyword(ctx)) return null
    if (not_explicit_and_too_boring(ctx)) return null
    return autocomplete.completeFromList(keyword_completions)(ctx)
}

const from_notebook_type = "c_from_notebook completion_module c_Any"

const map_name_to_global_completions = (name) => ({
    label: name,
    apply: name,
    type: from_notebook_type,
    section: section_regular,
    boost: 1,
})

const global_variables_completion =
    (/** @type {() => { [uuid: String]: String[]}} */ request_unsubmitted_global_definitions, cell_id) =>
    /** @returns {Promise<autocomplete.CompletionResult?>} */
    async (/** @type {autocomplete.CompletionContext} */ ctx) => {
        if (ctx.matchBefore(identifier_char_before_cursor) == null) return null
        if (!ctx.explicit && writing_variable_name_or_keyword(ctx)) return null
        if (not_explicit_and_too_boring(ctx)) return null

        // Not after `$`/`@` (a column/slot, not a notebook name).
        if (ctx.matchBefore(/[$@][\p{L}\p{N}._]*$/u)) return null

        const globals = ctx.state.facet(GlobalDefinitionsFacet)
        const local_globals = request_unsubmitted_global_definitions()

        const possibles = _.union(
            Object.entries(globals)
                .filter(([_, cell_id]) => local_globals[cell_id] == null)
                .map(([name]) => name),
            ...Object.values(_.omit(local_globals, cell_id))
        )

        const result = autocomplete.completeFromList(possibles.map(map_name_to_global_completions))(ctx)
        if (result == null) return null
        return { ...result, validFor: identifier_token }
    }

/**
 *
 * @typedef PlutoAutocompleteResult
 * @type {[
 * text: string,
 * value_type: string,
 * is_exported: boolean,
 * is_from_notebook: boolean,
 * completion_type: string,
 * special_symbol: string | null,
 * ]}
 *
 * @typedef PlutoAutocompleteResults
 * @type {{ start: number, stop: number, results: Array<PlutoAutocompleteResult>, too_long: boolean }}
 *
 * @typedef PlutoRequestAutocomplete
 * @type {(options: { query_full: string }) => Promise<PlutoAutocompleteResults?>}
 */

/**
 * @param {object} props
 * @param {PlutoRequestAutocomplete} props.request_autocomplete
 * @param {(query: string) => void} props.on_update_doc_query
 * @param {() => { [uuid: string] : String[]}} props.request_unsubmitted_global_definitions
 * @param {string} props.cell_id
 * @param {boolean} props.activate_on_typing
 * @param {boolean} props.tab_completes
 */
export let pluto_autocomplete = ({ request_autocomplete, on_update_doc_query, request_unsubmitted_global_definitions, cell_id, activate_on_typing, tab_completes }) => {
    let last_query = null
    let last_result = null
    /**
     * One request per distinct query, even though several completion
     * sources run on every keystroke.
     * @type {PlutoRequestAutocomplete}
     **/
    let memoize_last_request_autocomplete = async (options) => {
        if (_.isEqual(options, last_query)) {
            let result = await last_result
            if (result != null) return result
        }

        last_query = options
        last_result = request_autocomplete(options)
        return await last_result
    }

    return [
        autocompletion({
            activateOnTyping: activate_on_typing,
            override: [
                global_variables_completion(request_unsubmitted_global_definitions, cell_id),
                r_completions_to_cm(memoize_last_request_autocomplete),
                complete_keyword,
            ],
            defaultKeymap: false, // We add these manually later, so we can override them if necessary
            maxRenderedOptions: 512,
            optionClass: (c) => c.type ?? "",
        }),

        update_docs_from_autocomplete_selection(on_update_doc_query),

        keymap.of(pluto_autocomplete_keymap(tab_completes)),
        keymap.of(completionKeymap),
    ]
}
