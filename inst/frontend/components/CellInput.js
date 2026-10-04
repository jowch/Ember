import { html, useState, useEffect, useLayoutEffect, useRef, useContext, useMemo } from "../imports/Preact.js"
import _ from "../imports/lodash-es.js"

import { utf8index_to_ut16index } from "../common/UnicodeTools.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"
import { get_selected_doc_from_state } from "./CellInput/LiveDocsFromCursor.js"
import { GlobalDefinitionsFacet } from "./CellInput/go_to_definition_plugin.js"
// import { debug_syntax_plugin } from "./CellInput/debug_syntax_plugin.js"

import {
    EditorState,
    EditorSelection,
    Compartment,
    EditorView,
    placeholder,
    keymap,
    history,
    historyKeymap,
    defaultKeymap,
    indentMore,
    indentLess,
    tags,
    HighlightStyle,
    lineNumbers,
    highlightSpecialChars,
    drawSelection,
    indentOnInput,
    closeBrackets,
    rectangularSelection,
    highlightSelectionMatches,
    closeBracketsKeymap,
    foldKeymap,
    indentUnit,
    autocomplete,
    htmlLanguage,
    javascriptLanguage,
    syntaxHighlighting,
    cssLanguage,
    setDiagnostics,
    moveLineUp,
    Facet,
    StateField,
    tooltips,
    Prec,
} from "../imports/CodemirrorPlutoSetup.js"

import { r } from "../imports/CodemirrorPlutoSetup.js"
import { pluto_autocomplete } from "./CellInput/pluto_autocomplete.js"
import { signature_hint } from "./CellInput/signature_hint.js"
import { ARBITRARY_INDENT_LINE_WRAP_LIMIT, awesome_line_wrapping, get_leading_indent } from "./CellInput/awesome_line_wrapping.js"
import { cell_movement_plugin, prevent_holding_a_key_from_doing_things_across_cells } from "./CellInput/cell_movement_plugin.js"
import { pluto_paste_plugin } from "./CellInput/pluto_paste_plugin.js"
import { bracketMatching } from "./CellInput/block_matcher_plugin.js"
import { cl } from "../common/ClassTable.js"
import { HighlightLineFacet, HighlightRangeFacet, highlightLinePlugin, highlightRangePlugin } from "./CellInput/highlight_line.js"
import { commentKeymap } from "./CellInput/comment_mixed_parsers.js"
import { ScopeStateField } from "./CellInput/scopestate_statefield.js"
import { mod_d_command } from "./CellInput/mod_d_command.js"
import { open_bottom_right_panel } from "./BottomRightPanel.js"
import { assert_not_null, timeout_promise } from "../common/PlutoConnection.js"
import { LastFocusWasForcedEffect, tab_help_plugin } from "./CellInput/tab_help_plugin.js"
import { useEventListener } from "../common/useEventListener.js"
import { moveLineDown } from "../imports/CodemirrorPlutoSetup.js"
import { detect_indent_unit, indent_unit_of_setting } from "./CellInput/detect_indent_unit.js"
import { t } from "../common/lang.js"
import { tell } from "../common/dialogs.js"
import { useMenu } from "../common/useMenu.js"
import { RunButton } from "./RunButton.js"
import { alt_or_options_name } from "../common/KeyboardShortcuts.js"
import { MoreIcon } from "../common/Icons.js"
import { DEFAULT_SETTINGS, get_settings } from "./Settings.js"
import { highlightKwargsPlugin } from "./CellInput/highlight_kwargs.js"
import { hash_quote_continue, hash_quote_highlight } from "./CellInput/text_cell.js"
import { highlight_assigned } from "./CellInput/highlight_assigned.js"
import { is_dark_theme } from "../common/theme.js"

// @ts-ignore
// @ts-ignore
window.PLUTO_TOGGLE_CM_SPELLCHECK = () => console.error("Use the Settings menu instead.")
// @ts-ignore
window.PLUTO_TOGGLE_CM_AUTOCOMPLETE_ON_TYPE = () => console.error("Use the Settings menu instead.")

// The Cells board's tokens: calls in the function colour, names and
// argument names plain, nothing bold or italic.
const common_style_tags = [
    { tag: tags.comment, color: "var(--cm-color-comment)", filter: "none" },

    { tag: tags.definition(tags.typeName), color: "var(--cm-color-variable)" },
    { tag: tags.function(tags.variableName), color: "var(--cm-color-function)" },
    { tag: tags.variableName, color: "var(--cm-color-variable)" },
    { tag: tags.name, color: "var(--cm-color-variable)" },
    { tag: tags.propertyName, color: "var(--cm-color-variable)" },
    { tag: tags.macroName, color: "var(--cm-color-macro)" },
    { tag: tags.typeName, filter: "var(--cm-filter-type)" },
    { tag: tags.atom, color: "var(--cm-color-symbol)" },
    { tag: tags.string, color: "var(--cm-color-string)" },
    { tag: tags.special(tags.string), color: "var(--cm-color-command)" },
    { tag: tags.character, color: "var(--cm-color-literal)" },
    { tag: tags.literal, color: "var(--cm-color-literal)" },
    { tag: tags.keyword, color: "var(--cm-color-keyword)" },
    { tag: tags.definitionOperator, color: "var(--cm-color-definition)" },
    { tag: tags.logicOperator, color: "var(--cm-color-keyword)" },
    { tag: [tags.controlKeyword, tags.controlOperator], color: "var(--cm-color-control-operator)" },
    { tag: tags.attributeName, color: `pink`, fontStyle: "italic" },

    { tag: tags.bracket, color: "var(--cm-color-bracket)" },
    { tag: tags.self, color: "var(--cm-color-keyword)" },
    { tag: tags.null, color: "var(--cm-color-literal)" },
]

export const pluto_syntax_colors_julia = HighlightStyle.define(common_style_tags, {
    all: { color: `var(--cm-color-editor-text)` },
    scope: r().language,
})

export const pluto_syntax_colors_javascript = HighlightStyle.define(common_style_tags, {
    all: { color: `var(--cm-color-editor-text)`, filter: `contrast(0.5)` },
    scope: javascriptLanguage,
})

export const pluto_syntax_color_any = HighlightStyle.define(common_style_tags, {
    all: { color: `var(--cm-color-editor-text)` },
})

export const pluto_syntax_colors_css = HighlightStyle.define(
    [
        { tag: tags.comment, color: "var(--cm-color-comment)", fontStyle: "italic" },
        { tag: tags.variableName, color: "var(--cm-color-css-accent)", fontWeight: 700 },
        { tag: tags.propertyName, color: "var(--cm-color-css-accent)", fontWeight: 700 },
        { tag: tags.tagName, color: "var(--cm-color-css)", fontWeight: 700 },
        //{ tag: tags.className,          color: "var(--cm-css-why-doesnt-codemirror-highlight-all-the-text-aaa)" },
        //{ tag: tags.constant(tags.className), color: "var(--cm-css-why-doesnt-codemirror-highlight-all-the-text-aaa)" },
        { tag: tags.definitionOperator, color: "var(--cm-color-css)" },
        { tag: tags.keyword, color: "var(--cm-color-css)" },
        { tag: tags.modifier, color: "var(--cm-color-css-accent)" },
        { tag: tags.literal, color: "var(--cm-color-css)" },
        // { tag: tags.unit,              color: "var(--cm-color-css-accent)" },
        { tag: tags.punctuation, opacity: 0.5 },
    ],
    {
        scope: cssLanguage,
        all: { color: "var(--cm-color-css)" },
    }
)

export const pluto_syntax_colors_html = HighlightStyle.define(
    [
        { tag: tags.comment, color: "var(--cm-color-comment)", fontStyle: "italic" },
        { tag: tags.content, color: "var(--cm-color-html)", fontWeight: 400 },
        { tag: tags.tagName, color: "var(--cm-color-html-accent)", fontWeight: 600 },
        { tag: tags.documentMeta, color: "var(--cm-color-html-accent)" },
        { tag: tags.attributeName, color: "var(--cm-color-html-accent)", fontWeight: 600 },
        { tag: tags.attributeValue, color: "var(--cm-color-html-accent)" },
        { tag: tags.angleBracket, color: "var(--cm-color-html-accent)", fontWeight: 600, opacity: 0.7 },
    ],
    {
        all: { color: "var(--cm-color-html)" },
        scope: htmlLanguage,
    }
)

const getValue6 = (/** @type {EditorView} */ cm) => cm.state.doc.toString()
const setValue6 = (/** @type {EditorView} */ cm, value) =>
    cm.dispatch({
        changes: { from: 0, to: cm.state.doc.length, insert: value },
    })
const replaceRange6 = (/** @type {EditorView} */ cm, text, from, to) =>
    cm.dispatch({
        changes: { from, to, insert: text },
    })

// Compartments: https://codemirror.net/6/examples/config/
let useCompartment = (/** @type {import("../imports/Preact.js").Ref<EditorView?>} */ codemirror_ref, value) => {
    const compartment = useRef(new Compartment())
    const initial_value = useRef(compartment.current.of(value))

    useLayoutEffect(() => {
        codemirror_ref.current?.dispatch?.({
            effects: compartment.current.reconfigure(value),
        })
    }, [value])

    return initial_value.current
}

export const LastRemoteCodeSetTimeFacet = Facet.define({
    combine: (values) => values[0],
    compare: _.isEqual,
})

/** The `CM_INDENT_UNIT` setting's unit, used where a cell's own code shows none. */
const IndentFallback = Facet.define({
    combine: (values) => values[0] ?? indent_unit_of_setting(DEFAULT_SETTINGS.CM_INDENT_UNIT),
})

const indentUnitField = StateField.define({
    create: (state) => detect_indent_unit(state.doc, state.facet(IndentFallback)),
    update: (value, tr) =>
        tr.docChanged || tr.startState.facet(IndentFallback) !== tr.state.facet(IndentFallback)
            ? detect_indent_unit(tr.state.doc, tr.state.facet(IndentFallback))
            : value,
})

const accept_autocomplete_command = autocomplete.completionKeymap.find((keybinding) => keybinding.key === "Enter")
const keyMapTab = (/** @type {EditorView} */ cm) => {
    // I think this only gets called when we are not in an autocomplete situation, otherwise `tab_completion_command` is called. I think it only happens when you have a selection.

    if (cm.state.readOnly) {
        return false
    }
    // This will return true if the autocomplete select popup is open
    if (accept_autocomplete_command?.run?.(cm)) {
        return true
    }

    const anySelect = cm.state.selection.ranges.some((r) => !r.empty)
    if (anySelect) {
        return indentMore(cm)
    } else {
        const unit = cm.state.facet(indentUnit)
        cm.dispatch(
            cm.state.changeByRange((selection) => ({
                range: EditorSelection.cursor(selection.from + unit.length),
                changes: { from: selection.from, to: selection.to, insert: unit },
            }))
        )
        return true
    }
}

let line_and_ch_to_cm6_position = (/** @type {import("../imports/CodemirrorPlutoSetup.js").Text} */ doc, { line, ch }) => {
    let line_object = doc.line(_.clamp(line + 1, 1, doc.lines))
    let ch_clamped = _.clamp(ch, 0, line_object.length)
    return line_object.from + ch_clamped
}

/**
 * @param {{
 *  local_code: string,
 *  remote_code: string,
 *  scroll_into_view_after_creation: boolean,
 *  global_definition_locations: { [variable_name: string]: string },
 *  [key: string]: any,
 * }} props
 */
export const CellInput = ({
    local_code,
    remote_code,
    kind,
    disable_input,
    focus_after_creation,
    cm_forced_focus,
    set_cm_forced_focus,
    show_input,
    skip_static_fake = false,
    on_submit,
    on_delete,
    on_add_after,
    on_change,
    on_update_doc_query,
    on_focus_neighbor,
    on_line_heights,
    cell_id,
    notebook_id,
    cm_highlighted_line,
    cm_highlighted_range,
    global_definition_locations,
    cm_diagnostics,
    running_disabled,
    depends_on_disabled_cells,
    running,
    queued,
    runtime,
    on_run,
    on_interrupt,
    can_disable,
    set_cell_disabled,
    code_folded,
    on_code_fold,
    on_move_up,
    on_move_down,
}) => {
    let pluto_actions = useContext(PlutoActionsContext)
    let [error, set_error] = useState(null)
    if (error) {
        const to_throw = error
        set_error(null)
        throw to_throw
    }

    const notebook_id_ref = useRef(notebook_id)
    notebook_id_ref.current = notebook_id
    const kind_ref = useRef(kind)
    kind_ref.current = kind
    const editor_label = t(kind === "markdown" ? "t_cell_editor_text" : "t_cell_editor_code")

    const newcm_ref = useRef(/** @type {EditorView?} */ (null))
    const dom_node_ref = useRef(/** @type {HTMLElement?} */ (null))
    const remote_code_ref = useRef(/** @type {string?} */ (null))

    const [dark_theme, set_dark_theme] = useState(is_dark_theme())
    useEventListener(window, "ember theme change", () => set_dark_theme(is_dark_theme()), [])
    let dark_theme_compartment = useCompartment(newcm_ref, EditorView.theme({}, { dark: dark_theme }))

    let global_definitions_compartment = useCompartment(newcm_ref, GlobalDefinitionsFacet.of(global_definition_locations))
    let highlighted_line_compartment = useCompartment(newcm_ref, HighlightLineFacet.of(cm_highlighted_line))
    let highlighted_range_compartment = useCompartment(newcm_ref, HighlightRangeFacet.of(cm_highlighted_range))
    let editable_compartment = useCompartment(newcm_ref, EditorState.readOnly.of(disable_input))
    let last_remote_code_set_time_compartment = useCompartment(
        newcm_ref,
        useMemo(() => LastRemoteCodeSetTimeFacet.of(Date.now()), [remote_code])
    )

    let on_change_compartment = useCompartment(
        newcm_ref,
        // Functions are hard to compare, so I useMemo manually
        useMemo(() => {
            return EditorView.updateListener.of((update) => {
                if (update.docChanged) {
                    on_change(update.state.doc.toString())
                }
            })
        }, [on_change])
    )

    // Settings apply to open editors at once: one compartment holds every
    // extension that reads them.
    const [settings, set_settings] = useState(get_settings)
    useEventListener(window, "ember settings changed", () => set_settings(get_settings()), [])
    let settings_compartment = useCompartment(
        newcm_ref,
        useMemo(
            () => [
                IndentFallback.of(indent_unit_of_setting(settings.CM_INDENT_UNIT)),
                pluto_autocomplete({
                    request_autocomplete: async ({ query_full }) => {
                        let response = await timeout_promise(
                            pluto_actions.send("complete", { query_full }, { notebook_id: notebook_id_ref.current }),
                            5000
                        ).catch(console.warn)
                        if (!response) return null

                        let { message } = response

                        return {
                            start: utf8index_to_ut16index(query_full, message.start),
                            stop: utf8index_to_ut16index(query_full, message.stop),
                            results: message.results,
                            too_long: message.too_long,
                        }
                    },
                    on_update_doc_query,
                    // Notebook names a cell doesn't read yet still show (the
                    // engine's downstream_cells_map has an empty array, not a
                    // missing entry, ui-2.md 4): there is no separate
                    // "unsubmitted local definition" concept for R.
                    request_unsubmitted_global_definitions: () => ({}),
                    cell_id,
                    activate_on_typing: settings.CM_AUTOCOMPLETE_ON_TYPE,
                    tab_completes: settings.CM_TAB_KEY_FOR_INDENT,
                }),
                // After the autocomplete keymap, whose Tab accepts a completion first.
                keymap.of(settings.CM_TAB_KEY_FOR_INDENT ? [{ key: "Tab", run: keyMapTab, shift: indentLess }] : []),
                EditorView.contentAttributes.of({
                    "spellcheck": String(settings.CM_SPELLCHECK && kind === "markdown"),
                    "aria-label": editor_label,
                }),
            ],
            [settings.CM_INDENT_UNIT, settings.CM_AUTOCOMPLETE_ON_TYPE, settings.CM_TAB_KEY_FOR_INDENT, settings.CM_SPELLCHECK, kind]
        )
    )

    const [show_static_fake_state, set_show_static_fake] = useState(!skip_static_fake)

    const show_static_fake_excuses_ref = useRef(false)
    show_static_fake_excuses_ref.current ||= navigator.userAgent.includes("Firefox") || focus_after_creation || cm_forced_focus != null || skip_static_fake

    const show_static_fake = show_static_fake_excuses_ref.current ? false : show_static_fake_state

    useLayoutEffect(() => {
        if (!show_static_fake) return
        let node = dom_node_ref.current
        if (node == null) return
        let observer

        const show = () => {
            set_show_static_fake(false)
            observer.disconnect()
            window.removeEventListener("beforeprint", show)
        }

        observer = new IntersectionObserver((e) => {
            if (e.some((e) => e.isIntersecting)) {
                show()
            }
        })

        observer.observe(node)
        window.addEventListener("beforeprint", show)
        return () => {
            observer.disconnect()
            window.removeEventListener("beforeprint", show)
        }
    }, [])

    useLayoutEffect(() => {
        if (show_static_fake) return
        if (dom_node_ref.current == null) return

        const keyMapSubmit = (/** @type {EditorView} */ cm) => {
            autocomplete.closeCompletion(cm)
            on_submit()
            return true
        }
        let run = async (fn) => await fn()
        const keyMapRun = (/** @type {EditorView} */ cm) => {
            autocomplete.closeCompletion(cm)
            run(async () => {
                const new_value = cm.state.doc.toString()
                if (new_value !== remote_code_ref.current) {
                    const success_promise = on_submit()

                    // Wait for the dialog to maybe open.
                    await new Promise((r) => requestAnimationFrame(r))

                    // Check if there is currently the confirmation dialog open.
                    const waiting_for_confirmation = (() => {
                        const c = dom_node_ref.current
                        if (!c) return false
                        return !!c.closest("pluto-editor")?.querySelector("dialog[open].confirm-before-long-runtime")
                    })()

                    // If so...
                    if (waiting_for_confirmation) {
                        // ...wait for the result of the dialog. If canceled, then also cancel this.
                        const success = await success_promise
                        if (!success) return
                    }

                    // Why not just await success_promise?
                    // We want to create the new cell quickly so the next keystrokes after Ctrl+Enter start writing text in the new cell, instead of the current one.
                }

                // we await to prevent an out-of-sync issue
                await on_add_after()
            })
            return true
        }

        const keyMapDelete = (/** @type {EditorView} */ cm) => {
            if (cm.state.facet(EditorState.readOnly)) {
                return false
            }
            if (cm.state.doc.length === 0) {
                on_focus_neighbor(cell_id, +1)
                on_delete()
                return true
            }
            return false
        }

        const keyMapBackspace = (/** @type {EditorView} */ cm) => {
            if (cm.state.facet(EditorState.readOnly)) {
                return false
            }

            // Previously this was a very elaborate timed implementation......
            // But I found out that keyboard events have a `.repeated` property which is perfect for what we want...
            // So now this is just the cell deleting logic (and the repeated stuff is in a separate plugin)
            if (cm.state.doc.length === 0) {
                // `Infinity, Infinity` means: last line, last character
                on_focus_neighbor(cell_id, -1, Infinity, Infinity)
                on_delete()
                return true
            }
            return false
        }

        const keyMapMoveLine = (/** @type {EditorView} */ cm, direction) => {
            if (cm.state.facet(EditorState.readOnly)) {
                return false
            }

            const selection = cm.state.selection.main
            const all_is_selected = selection.anchor === 0 && selection.head === cm.state.doc.length

            if (all_is_selected || cm.state.doc.lines === 1) {
                pluto_actions.move_remote_cells([cell_id], pluto_actions.get_notebook().cell_order.indexOf(cell_id) + (direction === -1 ? -1 : 2))

                // workaround for https://github.com/preactjs/preact/issues/4235
                // but the scrollIntoView behaviour is nice, also when the preact issue is fixed.
                requestIdleCallback(() => {
                    cm.dispatch({
                        // TODO: remove me after fix
                        selection: {
                            anchor: 0,
                            head: cm.state.doc.length,
                        },

                        // TODO: keep me after fix
                        scrollIntoView: true,
                    })
                    // TODO: remove me after fix
                    cm.focus()
                })
                return true
            } else {
                return direction === 1 ? moveLineDown(cm) : moveLineUp(cm)
            }
        }
        const keyMapFold = (/** @type {EditorView} */ cm, new_value) => {
            set_cm_forced_focus(true)
            pluto_actions.fold_remote_cells([cell_id], new_value)
            return true
        }

        const plutoKeyMaps = [
            { key: "Shift-Enter", run: keyMapSubmit },
            { key: "Ctrl-Enter", mac: "Cmd-Enter", run: keyMapRun },
            { key: "Ctrl-Enter", run: keyMapRun },
            // TODO Move Delete and backspace to cell movement plugin
            { key: "Delete", run: keyMapDelete },
            { key: "Ctrl-Delete", run: keyMapDelete },
            { key: "Backspace", run: keyMapBackspace },
            { key: "Ctrl-Backspace", run: keyMapBackspace },
            { key: "Alt-ArrowUp", run: (x) => keyMapMoveLine(x, -1) },
            { key: "Alt-ArrowDown", run: (x) => keyMapMoveLine(x, 1) },
            { key: "Ctrl-Shift-[", mac: "Cmd-Alt-[", run: (x) => keyMapFold(x, true) },
            { key: "Ctrl-Shift-]", mac: "Cmd-Alt-]", run: (x) => keyMapFold(x, false) },
            {
                key: "F1",
                run: (/** @type {EditorView} */ cm) => {
                    const query = get_selected_doc_from_state(cm.state)
                    if (query != null) on_update_doc_query(query)
                    open_bottom_right_panel("docs")
                    return true
                },
            },
            mod_d_command,
        ]

        let DOCS_UPDATER_VERBOSE = false
        const docs_updater = EditorView.updateListener.of((update) => {
            if (!update.view.hasFocus) {
                return
            }

            if (update.docChanged || update.selectionSet) {
                let state = update.state
                DOCS_UPDATER_VERBOSE && console.groupCollapsed("Live docs updater from docChange or selectionSet")
                try {
                    let result = get_selected_doc_from_state(state, DOCS_UPDATER_VERBOSE)
                    if (result != null) {
                        on_update_doc_query(result)
                    }
                } finally {
                    DOCS_UPDATER_VERBOSE && console.groupEnd()
                }
            }
        })

        const newcm = (newcm_ref.current = new EditorView({
            state: EditorState.create({
                doc: local_code,
                extensions: [
                    dark_theme_compartment,
                    // Compartments coming from react state/props
                    highlighted_line_compartment,
                    highlighted_range_compartment,
                    global_definitions_compartment,
                    editable_compartment,
                    last_remote_code_set_time_compartment,
                    highlightLinePlugin(),
                    highlightRangePlugin(),

                    // This is waaaay in front of the keys it is supposed to override,
                    // Which is necessary because it needs to run before *any* keymap,
                    // as the first keymap will activate the keymap extension which will attach the
                    // keymap handlers at that point, which is likely before this extension.
                    // TODO Use https://codemirror.net/6/docs/ref/#state.Prec when added to pluto-codemirror-setup
                    prevent_holding_a_key_from_doing_things_across_cells,

                    ScopeStateField,
                    syntaxHighlighting(pluto_syntax_colors_julia),
                    syntaxHighlighting(pluto_syntax_colors_html),
                    syntaxHighlighting(pluto_syntax_colors_javascript),
                    syntaxHighlighting(pluto_syntax_colors_css),
                    lineNumbers(),
                    highlightSpecialChars(),
                    highlightKwargsPlugin(),
                    highlight_assigned,
                    history(),
                    drawSelection(),
                    EditorState.allowMultipleSelections.of(true),
                    // Multiple cursors with `alt` instead of the default `ctrl` (which we use for go to definition)
                    EditorView.clickAddsSelectionRange.of((event) => event.altKey && !event.shiftKey),
                    indentOnInput(),
                    // Experimental: Also add closing brackets for tripple string
                    // TODO also add closing string when typing a string macro
                    EditorState.languageData.of((state, pos, side) => {
                        return [{ closeBrackets: { brackets: ["(", "[", "{"] } }]
                    }),
                    closeBrackets(),
                    rectangularSelection({
                        eventFilter: (e) => e.altKey && e.shiftKey && e.button == 0,
                    }),
                    highlightSelectionMatches({ minSelectionLength: 2, wholeWords: true }),
                    bracketMatching(),
                    docs_updater,
                    tab_help_plugin,
                    // Remove selection on blur
                    EditorView.domEventHandlers({
                        blur: (event, view) => {
                            // it turns out that this condition is true *exactly* if and only if the blur event was triggered by blurring the window
                            let caused_by_window_blur = document.activeElement === view.contentDOM

                            if (!caused_by_window_blur) {
                                // then it's caused by focusing something other than this cell in the editor.
                                // in this case, we want to collapse the selection into a single point, for aesthetic reasons.
                                setTimeout(() => {
                                    // Focus can come back first, e.g. a text cell reopened from the keyboard.
                                    if (view.hasFocus) return
                                    view.dispatch({
                                        selection: {
                                            anchor: view.state.selection.main.head,
                                        },
                                        scrollIntoView: false,
                                    })
                                    // and blur the DOM again (because the previous transaction might have re-focused it)
                                    view.contentDOM.blur()
                                }, 0)

                                set_cm_forced_focus(null)
                            }
                        },
                    }),
                    pluto_paste_plugin({
                        pluto_actions,
                        cell_id,
                    }),
                    // Update live docs when in a cell that starts with `?`
                    EditorView.updateListener.of((update) => {
                        if (!update.docChanged) return
                        if (update.state.doc.length > 0 && update.state.sliceDoc(0, 1) === "?") {
                            open_bottom_right_panel("docs")
                        }
                    }),
                    EditorState.tabSize.of(4),
                    indentUnitField,
                    indentUnit.from(indentUnitField),
                    // Every cell is R, text cells included: their code
                    // starts with `#'`, and highlighting it as markdown
                    // would misread `#' ## Title` as an R comment followed
                    // by a markdown heading instead of one text line.
                    r(),
                    settings_compartment,

                    tooltips({ position: "absolute" }),
                    signature_hint({
                        request_signature: async ({ name, package: pkg }) => {
                            let response = await timeout_promise(
                                pluto_actions.send("ember_signature", { name, package: pkg }, { notebook_id: notebook_id_ref.current }),
                                5000
                            ).catch(console.warn)
                            return response?.message?.text ?? null
                        },
                    }),

                    // I put plutoKeyMaps separately because I want make sure we have
                    // higher priority 😈
                    keymap.of(plutoKeyMaps),
                    keymap.of(commentKeymap),
                    // Before default keymaps (because we override some of them)
                    // but after the autocomplete plugin, because we don't want to move cell when scrolling through autocomplete
                    cell_movement_plugin({
                        focus_on_neighbor: ({ cell_delta, line, character }) => on_focus_neighbor(cell_id, cell_delta, line, character),
                    }),
                    keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...historyKeymap, ...foldKeymap]),
                    // Low, so an open completion list closes on Esc first.
                    Prec.low(
                        keymap.of([
                            {
                                key: "Escape",
                                run: () => {
                                    if (kind_ref.current === "markdown") return false
                                    pluto_actions.select_cell(cell_id)
                                    return true
                                },
                            },
                        ])
                    ),
                    placeholder(t("t_cell_input_placeholder")),
                    hash_quote_continue,
                    hash_quote_highlight,

                    EditorView.lineWrapping,
                    awesome_line_wrapping,

                    // Reset diagnostics on change
                    EditorView.updateListener.of((update) => {
                        if (!update.docChanged) return
                        update.view.dispatch(setDiagnostics(update.state, []))
                    }),

                    on_change_compartment,

                    // This is my weird-ass extension that checks the AST and shows you where
                    // there're missing nodes.. I'm not sure if it's a good idea to have it
                    // show_missing_syntax_plugin(),

                    // Enable this plugin if you want to see the lezer tree,
                    // and possible lezer errors and maybe more debug info in the console:
                    // debug_syntax_plugin,
                    // Handle errors hopefully?
                    EditorView.exceptionSink.of((exception) => {
                        set_error(exception)
                        console.error("EditorView exception!", exception)
                        // alert(
                        //     `We ran into an issue! We have lost your cursor 😞😓😿\n If this appears again, please press F12, then click the "Console" tab,  eport an issue at https://github.com/JuliaPluto/Pluto.jl/issues`
                        // )
                    }),
                ],
            }),
            parent: dom_node_ref.current,
        }))
        // EditorView appends; the run button and ⋯ must follow the code in Tab order.
        dom_node_ref.current.prepend(newcm.dom)

        // For use from useDropHandler
        // @ts-ignore
        newcm.dom.CodeMirror = {
            getValue: () => getValue6(newcm),
            setValue: (x) => setValue6(newcm, x),
        }

        if (focus_after_creation) {
            setTimeout(() => {
                let view = newcm_ref.current
                if (view == null) return
                view.dom.scrollIntoView({
                    behavior: "smooth",
                    block: "nearest",
                })
                view.dispatch({
                    selection: {
                        anchor: view.state.doc.length,
                        head: view.state.doc.length,
                    },
                    effects: [LastFocusWasForcedEffect.of(true)],
                })
                view.focus()
            })
        }

        // @ts-ignore
        const lines_wrapper_dom_node = dom_node_ref.current.querySelector("div.cm-content")
        if (lines_wrapper_dom_node) {
            const lines_wrapper_resize_observer = new ResizeObserver(() => {
                const line_nodes = lines_wrapper_dom_node.children
                const tops = _.map(line_nodes, (c) => /** @type{HTMLElement} */ (c).offsetTop)
                const diffs = tops.slice(1).map((y, i) => y - assert_not_null(tops[i]))
                const heights = [...diffs, 15]
                on_line_heights(heights)
            })

            lines_wrapper_resize_observer.observe(lines_wrapper_dom_node)
            return () => {
                lines_wrapper_resize_observer.unobserve(lines_wrapper_dom_node)
            }
        }
    }, [show_static_fake])

    useEffect(() => {
        if (newcm_ref.current == null) return
        const cm = newcm_ref.current
        const diagnostics = cm_diagnostics

        cm.dispatch(setDiagnostics(cm.state, diagnostics))
    }, [cm_diagnostics])

    // Effect to apply "remote_code" to the cell when it changes...
    // ideally this won't be necessary as we'll have actual multiplayer,
    // or something to tell the user that the cell is out of sync.
    useEffect(() => {
        if (newcm_ref.current == null) return // Not sure when and why this gave an error, but now it doesn't

        const current_value = getValue6(newcm_ref.current) ?? ""
        if (remote_code_ref.current == null && remote_code === "" && current_value !== "") {
            // this cell is being initialized with empty code, but it already has local code set.
            // this happens when pasting or dropping cells
            return
        }
        remote_code_ref.current = remote_code
        if (current_value !== remote_code) {
            setValue6(newcm_ref.current, remote_code)
        }
    }, [remote_code])

    useEffect(() => {
        const cm = newcm_ref.current
        if (cm == null) return
        if (cm_forced_focus == null) {
            cm.dispatch({
                selection: {
                    anchor: cm.state.selection.main.head,
                    head: cm.state.selection.main.head,
                },
            })
        } else if (cm_forced_focus === true) {
        } else {
            let new_selection = {
                anchor: line_and_ch_to_cm6_position(cm.state.doc, cm_forced_focus[0]),
                head: line_and_ch_to_cm6_position(cm.state.doc, cm_forced_focus[1]),
            }

            if (cm_forced_focus[2]?.definition_of) {
                let scopestate = cm.state.field(ScopeStateField)
                let definition = scopestate?.definitions.get(cm_forced_focus[2]?.definition_of)
                if (definition) {
                    new_selection = {
                        anchor: definition.from,
                        head: definition.to,
                    }
                }
            }

            let dom = /** @type {HTMLElement} */ (cm.dom)
            dom.scrollIntoView({
                behavior: "smooth",
                block: "nearest",
                // UNCOMMENT THIS AND SEE, this feels amazing but I feel like people will not like it
                // block: "center",
            })

            cm.focus()
            cm.dispatch({
                scrollIntoView: true,
                selection: new_selection,
                effects: [
                    EditorView.scrollIntoView(EditorSelection.range(new_selection.anchor, new_selection.head), {
                        yMargin: 80,
                    }),
                    LastFocusWasForcedEffect.of(true),
                ],
            })
        }
    }, [cm_forced_focus])

    return html`
        <pluto-input ref=${dom_node_ref} class="CodeMirror" translate=${false}>
            ${show_static_fake ? (show_input ? html`<${StaticCodeMirrorFaker} value=${remote_code} label=${editor_label} />` : null) : null}
            ${running_disabled || depends_on_disabled_cells
                ? null
                : html`<${RunButton} running=${running} queued=${queued} runtime=${runtime} on_run=${on_run} on_interrupt=${on_interrupt} />`}
            <${InputContextMenu}
                cell_id=${cell_id}
                on_delete=${on_delete}
                code_folded=${code_folded}
                on_code_fold=${on_code_fold}
                can_disable=${can_disable}
                running_disabled=${running_disabled}
                set_cell_disabled=${set_cell_disabled}
                on_move_up=${on_move_up}
                on_move_down=${on_move_down}
            />
            ${PreviewHiddenCode}
        </pluto-input>
    `
}

const PreviewHiddenCode = html`<div class="preview_hidden_code_info">${t("t_reading_hidden_code")}</div>`

/**
 * The cell menu (ui-3.md, "Cell menu"): Hide/Show code, Disable/Enable
 * cell, Copy output, Move up, Move down, a separator, Delete cell. Built
 * on useMenu.js (piece 7a), which gives it arrow-key navigation, Esc and
 * click-outside; the DOM hooks (button.input_context_menu,
 * div.input_context_menu) are kept as Pluto named them.
 */
const InputContextMenu = ({ cell_id, on_delete, code_folded, on_code_fold, can_disable, running_disabled, set_cell_disabled, on_move_up, on_move_down }) => {
    let pluto_actions = useContext(PlutoActionsContext)

    const is_copy_output_supported = () => {
        let notebook = /** @type{import("./Editor.js").NotebookData?} */ (pluto_actions.get_notebook())
        let cell_result = notebook?.cell_results?.[cell_id]
        if (cell_result == null) return false

        return (
            (!cell_result.errored && cell_result.output.mime === "text/plain" && !!cell_result.output.body) ||
            (cell_result.errored && cell_result.output.mime === "application/vnd.pluto.stacktrace+object")
        )
    }

    const strip_ansi_codes = (s) => (typeof s === "string" ? s.replace(/\x1b\[[0-9;]*m/g, "") : s)

    const copy_output = () => {
        let notebook = /** @type{import("./Editor.js").NotebookData?} */ (pluto_actions.get_notebook())
        let cell_result = notebook?.cell_results?.[cell_id]
        if (cell_result == null) return

        let cell_output =
            cell_result.output.mime === "text/plain"
                ? cell_result.output.body
                : // @ts-ignore
                  cell_result.output.body.plain_error

        if (cell_output != null)
            navigator.clipboard.writeText(strip_ansi_codes(cell_output)).catch((err) => {
                console.error("Couldn't copy the output", err)
                tell({ body: t("t_copy_output_failed") })
            })
    }

    const items = [
        { tag: "hide_code", contents: code_folded ? t("t_show_code") : t("t_hide_code"), onClick: on_code_fold },
        // The class stays disable_cell in both states (test-disabled.test.mjs
        // (37) selects on it before and after toggling); only the label
        // changes.
        can_disable
            ? {
                  tag: "disable_cell",
                  contents: running_disabled ? t("t_enable_cell") : t("t_disable_cell"),
                  onClick: () => set_cell_disabled(!running_disabled),
              }
            : null,
        is_copy_output_supported() ? { tag: "copy_output", contents: t("t_copy_output_action"), onClick: copy_output } : null,
        { tag: "move_up", contents: t("t_move_up"), hint: `${alt_or_options_name} ↑`, onClick: on_move_up },
        { tag: "move_down", contents: t("t_move_down"), hint: `${alt_or_options_name} ↓`, onClick: on_move_down },
        { tag: "delete", contents: t("t_delete_cell_action"), onClick: on_delete, danger: true },
    ].filter((item) => item != null)

    const { button_props, menu_props, item_props, close, is_open } = useMenu({ count: items.length })

    return html`
        <button
            type="button"
            class=${cl({ input_context_menu: true, on: is_open })}
            title=${t("t_cell_options")}
            aria-label=${t("t_cell_options")}
            ...${button_props}
        >
            <${MoreIcon} size=${16} />
        </button>
        ${is_open &&
        html`
            <div class="input_context_menu" ...${menu_props}>
                <ul>
                    ${items.map(
                        (item, i) => html`${item.tag === "delete" ? html`<li class="ember-menu-sep" role="separator"></li>` : null}
                            <li>
                                <${InputContextMenuItem}
                                    tag=${item.tag}
                                    contents=${item.contents}
                                    hint=${item.hint}
                                    danger=${!!item.danger}
                                    item_props=${item_props(i)}
                                    onClick=${() => {
                                        close()
                                        item.onClick()
                                    }}
                                />
                            </li>`
                    )}
                </ul>
            </div>
        `}
    `
}

const InputContextMenuItem = ({ contents, hint, danger, onClick, item_props, tag }) =>
    html`<button type="button" class=${cl({ "ember-menuitem": true, [tag]: true, "ember-menuitem-danger": danger })} onClick=${onClick} ...${item_props}>
        ${contents}${hint != null ? html`<span class="ember-menuitem-key">${hint}</span>` : null}
    </button>`

const generate_fake_deco_indent_text = (width) => {
    const tab_size = 4
    const max_indent_ch = ARBITRARY_INDENT_LINE_WRAP_LIMIT * tab_size
    if (width <= max_indent_ch) return " ".repeat(width)

    const left = width - max_indent_ch
    return " ".repeat(max_indent_ch) + "⇥ ".repeat(Math.floor(left / 4)) + " ".repeat(left % 4)
}

const StaticCodeMirrorFaker = ({ value, label }) => {
    const tab_size = 4
    const lines = value.split("\n").map((line, i) => {
        const { text: indent_text, width: indent_width } = get_leading_indent(line, tab_size)
        const max_indent_ch = ARBITRARY_INDENT_LINE_WRAP_LIMIT * tab_size
        const offset = Math.min(indent_width, max_indent_ch)

        const tabbed_line =
            indent_text.length == 0
                ? line
                : html`<span class="awesome-wrapping-plugin-the-tabs"><span class="ͼo">${generate_fake_deco_indent_text(indent_width)}</span></span
                      >${line.substring(indent_text.length)}`

        return html`<div class="awesome-wrapping-plugin-the-line cm-line" style="--indented: ${offset}ch;">
            ${line.length === 0 ? html`<br />` : tabbed_line}
        </div>`
    })

    return html`
        <div class="cm-editor ͼ1 ͼ2 ͼ4 ͼ4z cm-ssr-fake">
            <div tabindex="-1" class="cm-scroller">
                <div class="cm-gutters" aria-hidden="true">
                    <div class="cm-gutter cm-lineNumbers"></div>
                </div>
                <div
                    spellcheck=${false}
                    autocorrect="off"
                    autocapitalize="off"
                    translate=${false}
                    contenteditable="false"
                    style="tab-size: 4;"
                    class="cm-content cm-lineWrapping"
                    role="textbox"
                    aria-label=${label}
                    aria-multiline="true"
                    aria-autocomplete="list"
                >
                    ${lines}
                </div>
            </div>
        </div>
    `
}
