import { cl } from "../common/ClassTable.js"
import { html, useContext, useEffect, useLayoutEffect, useRef, useState } from "../imports/Preact.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"
import _ from "../imports/lodash-es.js"
import { ansi_to_html } from "../imports/AnsiUp.js"
import { localized_list_htl, t, th } from "../common/lang.js"

/**
 * One traceback frame, as project_error() (R/pluto-state.R) sends it. Pluto's
 * fields are kept for Endeavor; Ember reads `call`, `source_package` and
 * `ember_cell`.
 * @typedef {Object} StackFrame
 * @property {string} call
 * @property {string} call_short
 * @property {string|null} func
 * @property {boolean} inlined
 * @property {boolean} from_c
 * @property {string} file
 * @property {string} path
 * @property {number} line
 * @property {string} linfo_type
 * @property {string|null} url
 * @property {string|null} source_package
 * @property {string|null} parent_module
 * @property {string|null} [ember_cell]
 */

const focus_cell = (/** @type {string} */ cell_id, /** @type {number?} */ line = null) =>
    window.dispatchEvent(new CustomEvent("cell_focus", { detail: { cell_id, line } }))

const MAX_CALL = 48

/** A call as the "Error in" line shows it: whole when short, else `name(…)`. */
export const short_call = (/** @type {string} */ call) => {
    const one_line = call.replace(/\s*\n\s*/g, " ")
    if (one_line.length <= MAX_CALL) return one_line
    const name = one_line.match(/^([^(\s]+)\(/)?.[1]
    return name != null ? `${name}(…)` : `${one_line.slice(0, MAX_CALL - 1)}…`
}

/** Text that may hold ANSI colour codes, shown without them until ansi_up has run. */
const AnsiText = (/** @type {{value: string}} */ { value }) => {
    const node_ref = useRef(/** @type {HTMLElement?} */ (null))
    useLayoutEffect(() => {
        if (node_ref.current) node_ref.current.innerHTML = ansi_to_html(value)
    }, [node_ref.current, value])
    return html`<span ref=${node_ref}>${value.replace(/\u001b\[[0-9;]*m/g, "")}</span>`
}

/** The first line as the message, any further lines (the engine's
 * suggested fixes, a multi-line R message) under it at normal weight. */
const first_and_rest = (/** @type {string} */ x, render_first = (/** @type {string} */ line) => html`<${AnsiText} value=${line} />`) => {
    const [first, ...rest] = _.dropRightWhile(x.split("\n"), (s) => s.trim() === "")
    return html`${render_first(first ?? "")}${rest.length > 0
        ? html`<span class="ember-error-more"><${AnsiText} value=${rest.join("\n")} /></span>`
        : null}`
}

const symbol_list_rewriter = (
    /** @type {RegExp} */ pattern,
    /** @type {(count: number) => import("../common/lang.js").TranslationKey} */ key_for,
    /** @type {(what: string) => any} */ make_link
) => ({
    pattern,
    display: (/** @type {string} */ x) =>
        first_and_rest(x, (line) => {
            const match = line.match(pattern)
            if (!match) return html`<${AnsiText} value=${line} />`
            const syms = (match[1] ?? "").replace(/\.$/, "").split(/, | and /)
            const links = syms.map(make_link)
            return th(key_for(syms.length), { count: syms.length, symbols: localized_list_htl(links, syms, { type: "conjunction" }) })
        }),
})

/**
 * "Error in `call` · line n", "… · called from line n", or "Error · line n".
 * Nothing when the error has no line (a graph error, an interrupt).
 */
const ErrorWhere = ({ call, line, deep }) => {
    if (line == null) return null
    if (call == null) return html`<p class="ember-error-where">${t("t_error_where_no_call", { line })}</p>`
    return html`<p class="ember-error-where">
        ${th(deep ? "t_error_where_called_from" : "t_error_where_line", {
            call: html`<code title=${call}>${short_call(call)}</code>`,
            line,
        })}
    </p>`
}

/**
 * The traceback, outermost call first. The first call is the one written in
 * this cell; the others are labelled by where their function comes from:
 * another cell ("notebook") or a package.
 * @param {{stacktrace: StackFrame[], line: number?, cell_id: string}} props
 */
const Traceback = ({ stacktrace, line, cell_id }) => {
    const [open, set_open] = useState(false)
    useEffect(() => set_open(false), [stacktrace])

    const frames = [...stacktrace].reverse()

    const from_label = (/** @type {StackFrame} */ frame, /** @type {number} */ i) => {
        const link = (/** @type {string} */ cell, /** @type {string} */ text, /** @type {number?} */ at) =>
            html`<a
                href=${`#${cell}`}
                onClick=${(e) => {
                    e.preventDefault()
                    focus_cell(cell, at)
                }}
                >${text}</a
            >`
        if (i === 0) {
            return line == null ? "" : link(cell_id, t("t_tb_this_cell", { line }), line - 1)
        }
        if (frame.ember_cell != null) return link(frame.ember_cell, t("t_tb_notebook"), 0)
        return frame.source_package ?? ""
    }

    const list_id = `ember-tb-${cell_id}`
    return html`<section>
        <button type="button" class="ember-tb-toggle" aria-expanded=${open ? "true" : "false"} aria-controls=${list_id} onClick=${() => set_open(!open)}>
            <span aria-hidden="true">${open ? "▾ " : "▸ "}</span>${open ? t("t_hide_traceback") : t("t_show_traceback", { count: frames.length })}
        </button>
        <ol class="ember-tb" id=${list_id} hidden=${!open}>
            ${frames.map((frame, i) => {
                const call = frame.call.replace(/\s*\n\s*/g, " ")
                return html`<li class=${cl({ mine: i === 0 || frame.ember_cell != null })}>
                    <span class="ember-tb-n">${i + 1}</span>
                    <code title=${call}>${call}</code>
                    <span class="ember-tb-from">${from_label(frame, i)}</span>
                </li>`
            })}
        </ol>
    </section>`
}

export const ParseError = ({ cell_id, diagnostics, last_run_timestamp }) => {
    useEffect(() => {
        window.dispatchEvent(
            new CustomEvent("cell_diagnostics", {
                detail: {
                    cell_id,
                    diagnostics,
                },
            })
        )
        return () => window.dispatchEvent(new CustomEvent("cell_diagnostics", { detail: { cell_id, diagnostics: [] } }))
    }, [diagnostics])

    const first = diagnostics[0]
    return html`<jlerror class="ember syntax-error">
        <header>
            <p class="ember-error-msg">${first_and_rest(first?.message ?? "")}</p>
            <${ErrorWhere} call=${null} line=${first?.line ?? null} deep=${false} />
        </header>
    </jlerror>`
}

/**
 * A run or graph error: the message, where it happened, and the traceback.
 * @param {Object} props
 * @param {string} props.msg
 * @param {StackFrame[]} props.stacktrace
 * @param {string} [props.plain_error]
 * @param {string?} [props.ember_call]
 * @param {number?} [props.ember_line]
 * @param {boolean} [props.ember_deep]
 * @param {number?} [props.ember_split] The Split button's cell count, for a cell mixing text and code.
 * @param {() => void} [props.on_split]
 * @param {string} props.cell_id
 * @returns {any}
 */
export const ErrorMessage = ({ msg, stacktrace, plain_error, ember_call = null, ember_line = null, ember_deep = false, ember_split = null, on_split, cell_id }) => {
    let pluto_actions = useContext(PlutoActionsContext)

    const default_rewriter = {
        pattern: /.?/,
        display: (/** @type{string} */ x) => first_and_rest(x),
    }
    const rewriters = [
        symbol_list_rewriter(
            /Cyclic references among (.*)\./,
            (count) => (count === 2 ? "t_cyclic_references_between_two" : "t_cyclic_references_among"),
            (what) => html`<a href="#${encodeURI(what)}">${what}</a>`),
        symbol_list_rewriter(
            /Multiple definitions for (.*)/,
            () => "t_multiple_definitions_for",
            (what) =>
                html`<a
                    href="#"
                    onClick=${(e) => {
                        e.preventDefault()
                        document.querySelector(`pluto-cell:not([id='${cell_id}']) span[id='${encodeURI(what)}']`)?.scrollIntoView()
                    }}
                    >${what}</a
                >`
        ),
        {
            pattern: /^\s*$/,
            display: () => default_rewriter.display("Error"),
        },
        {
            // The engine classifies this (step.R's failed_definers()); the
            // page only renders `ember.upstream_error`, the names and the
            // cells they came from.
            pattern: /^Another cell defining /,
            kind: "upstream",
            display: (/** @type{string} */ x) => {
                const notebook = /** @type{import("./Editor.js").NotebookData?} */ (pluto_actions.get_notebook())
                const upstream_error = notebook?.cell_results?.[cell_id]?.ember?.upstream_error ?? []

                if (upstream_error.length === 0) {
                    return html`<em>${x}</em>`
                }

                const symbol_links = upstream_error.map(({ name, cell }) => {
                    const onclick = (ev) => {
                        ev.preventDefault()
                        const where = document.querySelector(`pluto-cell[id='${cell}']`)
                        where?.scrollIntoView()
                    }
                    return html`<a href="#" onclick=${onclick}>${name}</a>`
                })

                const symbol_interp = localized_list_htl(
                    symbol_links,
                    upstream_error.map(({ name }) => name),
                    { type: "disjunction" }
                )

                return html`<em>${th("t_another_cell_defining_xs_contains_errors", { symbols: symbol_interp })}</em>`
            },
            show_stacktrace: () => false,
        },
        {
            // graph.R's mixed_text error: a title sentence, then what it means.
            pattern: /^Text and code in one cell\. /,
            kind: "mixed",
            display: (/** @type{string} */ x) => x.split(". ")[0],
            note: (/** @type{string} */ x) => {
                const rest = x.slice(x.indexOf(". ") + 2)
                return rest.split("#'").flatMap((part, i) => (i === 0 ? [part] : [html`<code>#'</code>`, part]))
            },
            show_stacktrace: () => false,
        },
        default_rewriter,
    ]

    const matched_rewriter = /** @type {{kind?: string, display: Function, note?: Function, show_stacktrace?: Function}} */ (
        rewriters.find(({ pattern }) => pattern.test(msg)) ?? default_rewriter
    )

    // A top-level stop() still has a one-call traceback, but the worker
    // records no frames for it, so no frame has a package or a cell.
    const has_frames = stacktrace.some((frame) => frame.source_package != null || frame.ember_cell != null)
    const show_traceback = has_frames && (matched_rewriter.show_stacktrace?.() ?? true)

    return html`<jlerror class=${cl({ ember: true, [`ember-${matched_rewriter.kind}`]: matched_rewriter.kind != null })}>
        <header translate="yes">
            <p class="ember-error-msg">${matched_rewriter.display(msg)}</p>
            ${matched_rewriter.note != null
                ? html`<p class="ember-error-note">${matched_rewriter.note(msg)}</p>`
                : html`<${ErrorWhere} call=${ember_call} line=${ember_line} deep=${ember_deep} />`}
        </header>
        ${ember_split != null ? html`<button type="button" class="ember-split" onClick=${on_split}>${t("t_ember_split", { n: ember_split })}</button>` : null}
        ${show_traceback ? html`<${Traceback} stacktrace=${stacktrace} line=${ember_line} cell_id=${cell_id} />` : null}
    </jlerror>`
}
