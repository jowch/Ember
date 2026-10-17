import { Facet, ViewPlugin, Decoration, EditorView } from "../../imports/CodemirrorPlutoSetup.js"
import { ctrl_or_cmd_name, has_ctrl_or_cmd_pressed } from "../../common/KeyboardShortcuts.js"
import _ from "../../imports/lodash-es.js"
import { display_name } from "../../common/display_name.js"

/**
 * Where a cell's code defines and reads each name, from the engine's own
 * analysis (pluto-state.R's `project_spans()`, ui-2.md 4e): `[name, from,
 * to]` at offsets into `code`, the cell's submitted code the analysis read.
 *
 * @typedef {[string, number, number]} Span
 * @typedef {{ code: string, defs: Span[], refs: Span[] }} EmberSpans
 */

/** @type {Facet<EmberSpans?, EmberSpans?>} */
export const EmberSpansFacet = Facet.define({
    combine: (values) => values[0] ?? null,
    compare: _.isEqual,
})

/**
 * Key: a name some cell defines, value: the first cell (in notebook order)
 * defining it, from every cell's `ember_spans.defs`. Unlike
 * `GlobalDefinitionsFacet`, it holds only real definitions: no package
 * exports or method generics, which `downstream_cells_map` also keys by.
 *
 * @type {Facet<{ [variable_name: string]: string }, { [variable_name: string]: string }>}
 */
export const DefinitionCellsFacet = Facet.define({
    combine: (values) => values[0] ?? {},
    compare: _.isEqual,
})

/**
 * The spans, but only while the editor shows exactly the code they were
 * read from: while the user types, the offsets would point at the wrong
 * text, so there are none until the cell is submitted.
 *
 * @param {import("../../imports/CodemirrorPlutoSetup.js").EditorState} state
 * @returns {EmberSpans?}
 */
export const current_spans = (state) => {
    const spans = state.facet(EmberSpansFacet)
    if (spans == null || spans.code !== state.doc.toString()) return null
    return spans
}

/**
 * A reference to a name this cell defines links to that definition in the
 * cell (`data-cell-variable`); one to a name another cell defines links to
 * that cell (`data-pluto-variable`). Anything else (a base or package
 * function, a name nobody defines) gets no mark. Two reads at one span
 * (`names(x) <- v` reads `names<-` at `names`) give one mark.
 *
 * @param {import("../../imports/CodemirrorPlutoSetup.js").EditorState} state
 * @param {{ [variable_name: string]: string }} definition_cells
 */
const get_variable_marks = (state, definition_cells) => {
    const spans = current_spans(state)
    if (spans == null) return Decoration.none
    const length = state.doc.length
    const own = new Map()
    for (const [name, from, to] of spans.defs) if (!own.has(name)) own.set(name, { from, to })
    const taken = new Set()
    const marks = []
    for (const [name, from, to] of spans.refs) {
        if (from >= to || to > length || taken.has(from)) continue
        const definition = own.get(name)
        if (definition != null) {
            taken.add(from)
            marks.push(
                Decoration.mark({
                    tagName: "a",
                    attributes: {
                        "title": `${ctrl_or_cmd_name}-Click to jump to the definition of ${display_name(name)}.`,
                        "data-cell-variable": name,
                        "data-cell-variable-from": `${definition.from}`,
                        "data-cell-variable-to": `${definition.to}`,
                        "href": `#`,
                    },
                }).range(from, to)
            )
        } else if (definition_cells[name] != null) {
            taken.add(from)
            marks.push(
                Decoration.mark({
                    tagName: "a",
                    attributes: {
                        "title": `${ctrl_or_cmd_name}-Click to jump to the definition of ${display_name(name)}.`,
                        "data-pluto-variable": name,
                        "href": `#${encodeURI(display_name(name))}`,
                    },
                }).range(from, to)
            )
        }
    }
    return Decoration.set(marks, true)
}

/**
 * Key: variable name, value: cell id.
 * @type {Facet<{ [variable_name: string]: string }, { [variable_name: string]: string }>}
 */
export const GlobalDefinitionsFacet = Facet.define({
    combine: (values) => values[0],
    compare: _.isEqual,
})

export const go_to_definition_plugin = ViewPlugin.fromClass(
    class {
        /**
         * @param {EditorView} view
         */
        constructor(view) {
            this.decorations = get_variable_marks(view.state, view.state.facet(DefinitionCellsFacet))
        }

        update(update) {
            const definition_cells = update.state.facet(DefinitionCellsFacet)
            if (
                update.docChanged ||
                definition_cells !== update.startState.facet(DefinitionCellsFacet) ||
                update.state.facet(EmberSpansFacet) !== update.startState.facet(EmberSpansFacet)
            ) {
                this.decorations = get_variable_marks(update.state, definition_cells)
            }
        }
    },
    {
        decorations: (v) => v.decorations,

        eventHandlers: {
            click: (event, view) => {
                if (event.target instanceof Element) {
                    let pluto_variable = event.target.closest("[data-pluto-variable]")
                    if (pluto_variable) {
                        let variable = pluto_variable.getAttribute("data-pluto-variable")
                        if (variable == null) {
                            return false
                        }

                        if (!(has_ctrl_or_cmd_pressed(event) || view.state.readOnly)) {
                            return false
                        }

                        event.preventDefault()
                        // By id, not a selector: an R name can hold any character
                        // (`` `n's` ``), which a quoted selector would choke on.
                        document.getElementById(encodeURI(display_name(variable)))?.scrollIntoView({
                            behavior: "smooth",
                            block: "center",
                        })

                        // TODO Something fancy where it counts going to definition as a page in history,
                        // .... so pressing/swiping back will go back to where you clicked on the definition.
                        // window.history.replaceState({ scrollTop: document.documentElement.scrollTop }, null)
                        // window.history.pushState({ scrollTo: scrollto_selector }, null)

                        // The cell selects the definition itself (CellInput.js, `definition_of`).
                        let definition_cells = view.state.facet(DefinitionCellsFacet)
                        if (definition_cells[variable]) {
                            window.dispatchEvent(
                                new CustomEvent("cell_focus", {
                                    detail: {
                                        cell_id: definition_cells[variable],
                                        line: 0, // 1-based to 0-based index
                                        definition_of: variable,
                                    },
                                })
                            )
                            return true
                        }
                    }

                    let cell_variable = event.target.closest("[data-cell-variable]")
                    if (cell_variable) {
                        let variable_name = cell_variable.getAttribute("data-cell-variable")
                        let variable_from = Number(cell_variable.getAttribute("data-cell-variable-from"))
                        let variable_to = Number(cell_variable.getAttribute("data-cell-variable-to"))

                        if (variable_name == null || variable_from == null || variable_to == null) {
                            return false
                        }

                        if (!(has_ctrl_or_cmd_pressed(event) || view.state.readOnly)) {
                            return false
                        }

                        event.preventDefault()

                        view.dispatch({
                            scrollIntoView: true,
                            selection: { anchor: variable_from, head: variable_to },
                        })
                        view.focus()
                        return true
                    }
                }
            },
        },
    }
)
