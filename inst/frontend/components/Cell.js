import _ from "../imports/lodash-es.js"
import { html, useState, useEffect, useMemo, useRef, useContext, useLayoutEffect, useErrorBoundary, useCallback } from "../imports/Preact.js"

import { CellOutput } from "./CellOutput.js"
import { CellInput, InputContextMenu } from "./CellInput.js"
import { Logs } from "./Logs.js"
import { RunButton, useDebouncedTruth } from "./RunButton.js"
import { cl } from "../common/ClassTable.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"
import { useEventListener } from "../common/useEventListener.js"
import { t, th } from "../common/lang.js"
import { CircleIcon, ClockIcon, SlashCircleIcon } from "../common/Icons.js"
import { stale_names } from "../common/stale_names.js"

/**
 * The "Stale" chip's text: "Stale" alone when no names are known, else
 * "Stale · x changed" / "Stale · x and y changed" / "Stale ·
 * x, y and N more changed" (ui-3.md, "Chips": "at most three names, then
 * 'and N more'").
 */
const format_stale_chip = (notebook, cell_id) => {
    const names = stale_names(notebook, cell_id)
    if (names.length === 0) return t("t_chip_stale")
    const shown = names.slice(0, 3)
    const rest = names.length - shown.length
    const parts = rest > 0 ? [...shown, t("t_n_more", { count: rest })] : shown
    const joined = parts.length === 1 ? parts[0] : `${parts.slice(0, -1).join(", ")} ${t("t_and")} ${parts[parts.length - 1]}`
    return t("t_chip_stale_names", { names: joined })
}

const useCellApi = (node_ref, published_object_keys, pluto_actions) => {
    const [cell_api_ready, set_cell_api_ready] = useState(false)
    const published_object_keys_ref = useRef(published_object_keys)
    published_object_keys_ref.current = published_object_keys

    useLayoutEffect(() => {
        Object.assign(node_ref.current, {
            getPublishedObject: (id) => {
                if (!published_object_keys_ref.current.includes(id)) throw `getPublishedObject: ${id} not found`
                return pluto_actions.get_published_object(id)
            },
            _internal_pluto_actions: pluto_actions,
        })

        set_cell_api_ready(true)
    })

    return cell_api_ready
}

/**
 * @param {{
 *  cell_result: import("./Editor.js").CellResultData,
 *  cell_input: import("./Editor.js").CellInputData,
 *  cell_input_local: { code: String },
 *  cell_dependencies: import("./Editor.js").CellDependencyData
 *  nbpkg: import("./Editor.js").NotebookPkgData?,
 *  selected: boolean,
 *  force_hide_input: boolean,
 *  focus_after_creation: boolean,
 *  process_waiting_for_permission: boolean,
 *  sanitize_html: boolean,
 *  inspecting_hidden_code: boolean,
 *  [key: string]: any,
 * }} props
 * */
export const Cell = ({
    cell_input: { cell_id, code, code_folded, kind, metadata },
    cell_result: { queued, running, runtime, errored, output, logs, published_object_keys, depends_on_disabled_cells, depends_on_skipped_cells, ember },
    cell_dependencies,
    cell_input_local,
    notebook_id,
    selected,
    force_hide_input,
    focus_after_creation,
    is_process_ready,
    disable_input,
    process_waiting_for_permission,
    sanitize_html = true,
    nbpkg,
    global_definition_locations,
    is_first_cell,
    inspecting_hidden_code,
}) => {
    const { show_logs, disabled: running_disabled, skip_as_script } = metadata
    const code_changed = !!ember?.code_changed
    const stale = !code_changed && !!ember?.stale
    let pluto_actions = useContext(PlutoActionsContext)
    // useCallback because pluto_actions.set_doc_query can change value when you go from viewing a static document to connecting (to binder)
    const on_update_doc_query = useCallback((...args) => pluto_actions.set_doc_query(...args), [pluto_actions])
    const on_focus_neighbor = useCallback((...args) => pluto_actions.focus_on_neighbor(...args), [pluto_actions])
    const on_change = useCallback((val) => pluto_actions.set_local_cell(cell_id, val), [cell_id, pluto_actions])
    const variables = useMemo(() => Object.keys(cell_dependencies?.downstream_cells_map ?? {}), [cell_dependencies])

    // We need to unmount & remount when a destructive error occurs.
    // For that reason, we will use a simple react key and increment it on error
    const [key, setKey] = useState(0)
    const cell_key = useMemo(() => cell_id + key, [cell_id, key])

    const [, resetError] = useErrorBoundary((error) => {
        console.log(`An error occurred in the CodeMirror code, resetting CellInput component. See error below:\n\n${error}\n\n -------------- `)
        setKey(key + 1)
        resetError()
    })

    const remount = useMemo(() => () => setKey(key + 1))
    // cm_forced_focus is null, except when a line needs to be highlighted because it is part of a stack trace
    const [cm_forced_focus, set_cm_forced_focus] = useState(/** @type {any} */ (null))
    const [cm_highlighted_range, set_cm_highlighted_range] = useState(/** @type {{from, to}?} */ (null))
    const [cm_highlighted_line, set_cm_highlighted_line] = useState(null)
    const [cm_diagnostics, set_cm_diagnostics] = useState([])

    useEventListener(
        window,
        "cell_diagnostics",
        (e) => {
            if (e.detail.cell_id === cell_id) {
                set_cm_diagnostics(e.detail.diagnostics)
            }
        },
        [cell_id, set_cm_diagnostics]
    )

    useEventListener(
        window,
        "cell_highlight_range",
        (e) => {
            if (e.detail.cell_id == cell_id && e.detail.from != null && e.detail.to != null) {
                set_cm_highlighted_range({ from: e.detail.from, to: e.detail.to })
            } else {
                set_cm_highlighted_range(null)
            }
        },
        [cell_id]
    )

    useEventListener(
        window,
        "cell_focus",
        useCallback((e) => {
            if (e.detail.cell_id === cell_id) {
                if (e.detail.line != null) {
                    const ch = e.detail.ch
                    if (ch == null) {
                        set_cm_forced_focus([
                            { line: e.detail.line, ch: 0 },
                            { line: e.detail.line, ch: Infinity },
                            { scroll: true, definition_of: e.detail.definition_of },
                        ])
                    } else {
                        set_cm_forced_focus([
                            { line: e.detail.line, ch: ch },
                            { line: e.detail.line, ch: ch },
                            { scroll: true, definition_of: e.detail.definition_of },
                        ])
                    }
                }
            }
        }, [])
    )

    // When you click to run a cell, we use `waiting_to_run` to immediately set the cell's traffic light to 'queued', while waiting for the backend to catch up.
    const [waiting_to_run, set_waiting_to_run] = useState(false)
    useEffect(() => {
        set_waiting_to_run(false)
    }, [queued, running, output?.last_run_timestamp, depends_on_disabled_cells, running_disabled])
    // We activate animations instantly BUT deactivate them NSeconds later.
    // We then toggle animation visibility using opacity. This saves a bunch of repaints.
    const activate_animation = useDebouncedTruth(running || queued || waiting_to_run)

    const class_code_differs = code !== (cell_input_local?.code ?? code)
    // Markdown cells never run: their output is always the rendered text.
    const no_output_yet = kind !== "markdown" && (output?.last_run_timestamp ?? 0) === 0
    const code_not_trusted_yet = process_waiting_for_permission && no_output_yet

    // When reading the code in a static HTML preview
    const [inspecting_hidden_code_here, set_inspecting_hidden_code_here] = useState(false)
    useEffect(() => {
        if (!inspecting_hidden_code) set_inspecting_hidden_code_here(false)
    }, [inspecting_hidden_code])

    // during the initial page load, force_hide_input === true, so that cell outputs render fast, and codemirrors are loaded after
    let show_input =
        !force_hide_input && (code_not_trusted_yet || errored || class_code_differs || cm_forced_focus != null || !code_folded || inspecting_hidden_code_here)

    const [line_heights, set_line_heights] = useState([15])
    const node_ref = useRef(/** @type {HTMLElement?} */ (null))

    const disable_input_ref = useRef(disable_input)
    disable_input_ref.current = disable_input
    const should_set_waiting_to_run_ref = useRef(true)
    should_set_waiting_to_run_ref.current = !running_disabled && !depends_on_disabled_cells
    useEventListener(
        window,
        "set_waiting_to_run_smart",
        (e) => {
            if (e.detail.cell_ids.includes(cell_id)) set_waiting_to_run(should_set_waiting_to_run_ref.current)
        },
        [cell_id, set_waiting_to_run]
    )

    const cell_api_ready = useCellApi(node_ref, published_object_keys, pluto_actions)
    const on_delete = useCallback(() => {
        pluto_actions.confirm_delete_multiple(pluto_actions.get_selected_cells(cell_id, selected))
    }, [pluto_actions, selected, cell_id])
    const on_submit = useCallback(async () => {
        if (!disable_input_ref.current) {
            return await pluto_actions.set_and_run_multiple([cell_id])
        }
        return false
    }, [pluto_actions, cell_id])
    const on_change_cell_input = useCallback(
        (new_code) => {
            if (!disable_input_ref.current) {
                if (code_folded && cm_forced_focus != null) {
                    pluto_actions.fold_remote_cells([cell_id], false)
                }
                on_change(new_code)
            }
        },
        [code_folded, cm_forced_focus, pluto_actions, on_change]
    )
    const on_add_after = useCallback(() => {
        return pluto_actions.add_remote_cell(cell_id, "after")
    }, [pluto_actions, cell_id, selected])
    // Same arithmetic as CellInput.js's Alt+Up/Down keymap (keyMapMoveLine).
    const on_move_up = useCallback(() => {
        pluto_actions.move_remote_cells([cell_id], pluto_actions.get_notebook().cell_order.indexOf(cell_id) - 1)
    }, [pluto_actions, cell_id])
    const on_move_down = useCallback(() => {
        pluto_actions.move_remote_cells([cell_id], pluto_actions.get_notebook().cell_order.indexOf(cell_id) + 2)
    }, [pluto_actions, cell_id])
    const on_code_fold = useCallback(() => {
        if (inspecting_hidden_code) {
            set_inspecting_hidden_code_here(!inspecting_hidden_code_here)
        } else {
            pluto_actions.fold_remote_cells(pluto_actions.get_selected_cells(cell_id, selected), !code_folded)
        }
    }, [pluto_actions, cell_id, selected, code_folded, inspecting_hidden_code_here, inspecting_hidden_code])
    const on_run = useCallback(async () => {
        return await pluto_actions.set_and_run_multiple(pluto_actions.get_selected_cells(cell_id, selected))
    }, [pluto_actions, cell_id, selected])
    const set_show_logs = useCallback(
        (show_logs) =>
            pluto_actions.update_notebook((notebook) => {
                notebook.cell_inputs[cell_id].metadata.show_logs = show_logs
            }),
        [pluto_actions, cell_id]
    )
    const set_cell_disabled = useCallback(
        async (new_val) => {
            await pluto_actions.update_notebook((notebook) => {
                notebook.cell_inputs[cell_id].metadata["disabled"] = new_val
            })
            // we also 'run' the cell if it is disabled, this will make the backend propage the disabled state to dependent cells
            // (except in safe preview: submitting there would ask to run the whole notebook just from toggling the checkbox)
            if (!process_waiting_for_permission) await on_submit()
        },
        [pluto_actions, cell_id, on_submit, process_waiting_for_permission]
    )

    const any_logs = useMemo(() => !_.isEmpty(logs), [logs])

    const disabled_by_cell_id = ember?.disabled_by ?? null
    const disabled_jump = useCallback(() => {
        if (disabled_by_cell_id != null) {
            window.dispatchEvent(new CustomEvent("cell_focus", { detail: { cell_id: disabled_by_cell_id, line: 0 } }))
        }
    }, [disabled_by_cell_id])

    const split_n = ember?.split ?? null
    const on_split = useCallback(() => {
        pluto_actions.ember_split_cell(cell_id, code)
    }, [pluto_actions, cell_id, code])

    const on_interrupt = useCallback(() => {
        pluto_actions.interrupt_remote(cell_id)
    }, [pluto_actions, cell_id])

    // The rail's colour (ui-3.md, "Rail"): running, queued, edited, error,
    // idle, in that precedence -- an edited cell that also has an error
    // shows amber, because the error belongs to code that has since changed.
    const rail = running
        ? "run"
        : queued || waiting_to_run
          ? "queued"
          : class_code_differs || code_changed
            ? "due"
            : errored
              ? "err"
              : "idle"

    const not_run_yet =
        no_output_yet &&
        !running &&
        !queued &&
        code.trim() !== "" &&
        !process_waiting_for_permission &&
        kind !== "markdown" &&
        !running_disabled &&
        !depends_on_disabled_cells

    // ui-3.md, "Chips": at most one shown, in this order. depends_on_disabled_cells
    // is also true on the disabled cell itself (as in Pluto), so running_disabled
    // is checked first.
    const chip = running_disabled
        ? { icon: SlashCircleIcon, text: t("t_chip_disabled") }
        : depends_on_disabled_cells
          ? {
                icon: SlashCircleIcon,
                text: th("t_chip_depends_on_disabled", {
                    link: html`<a
                        href="#"
                        onClick=${(e) => {
                            e.preventDefault()
                            disabled_jump()
                        }}
                        >${t("t_go_to_it")}</a
                    >`,
                }),
            }
          : not_run_yet
            ? { icon: CircleIcon, text: t("t_chip_not_run") }
            : stale
              ? { icon: ClockIcon, text: format_stale_chip(pluto_actions.get_notebook(), cell_id) }
              : null

    return html`
        <pluto-cell
            key=${cell_key}
            ref=${node_ref}
            class=${cl({
                queued: queued || (waiting_to_run && is_process_ready),
                internal_test_queued: !is_process_ready && (queued || waiting_to_run),
                running,
                activate_animation,
                errored,
                selected,
                code_differs: class_code_differs,
                code_folded,
                inspecting_hidden_code: code_folded && inspecting_hidden_code_here,
                skip_as_script,
                running_disabled,
                depends_on_disabled_cells,
                depends_on_skipped_cells,
                stale,
                code_changed,
                show_input,
                shrunk: Object.values(logs).length > 0,
                hooked_up: output?.has_pluto_hook_features ?? false,
                no_output_yet,
                not_run_yet,
                text_cell: kind === "markdown",
            })}
            data-rail=${rail}
            id=${cell_id}
        >
            ${variables.map((name) => html`<span id=${encodeURI(name)} />`)}
            <button
                onClick=${() => {
                    pluto_actions.add_remote_cell(cell_id, "before")
                }}
                class="add_cell before"
                title=${t("t_add_cell_here")}
                aria-label=${t("t_add_cell_here")}
                tabindex=${is_first_cell ? undefined : "-1"}
            >
                <span></span>
            </button>
            <pluto-shoulder draggable="true" title=${t("t_drag_to_move_cell")}>
                <button onClick=${on_code_fold} class="foldcode" title=${code_folded ? t("t_show_code") : t("t_hide_code")}>
                    <span></span>
                </button>
            </pluto-shoulder>
            <pluto-trafficlight></pluto-trafficlight>
            ${rail === "due" ? html`<ember-rail-tip>${t("t_rail_due_hint")}</ember-rail-tip>` : null}
            <${InputContextMenu}
                cell_id=${cell_id}
                on_delete=${on_delete}
                code_folded=${code_folded}
                on_code_fold=${on_code_fold}
                can_disable=${ember?.can_disable ?? false}
                running_disabled=${running_disabled}
                set_cell_disabled=${set_cell_disabled}
                on_move_up=${on_move_up}
                on_move_down=${on_move_down}
            />
            ${chip != null
                ? html`<ember-chip role="status"><span class="ember-chip-icon" aria-hidden="true"><${chip.icon} /></span><span>${chip.text}</span></ember-chip>`
                : null}
            ${code_not_trusted_yet
                ? null
                : cell_api_ready
                  ? html`<${CellOutput} errored=${errored} ...${output} ember_figure=${ember?.figure} sanitize_html=${sanitize_html} cell_id=${cell_id} />`
                  : html``}
            ${split_n != null ? html`<button class="ember-split" onClick=${on_split}>${t("t_ember_split", { n: split_n })}</button>` : null}
            <${CellInput}
                local_code=${cell_input_local?.code ?? code}
                remote_code=${code}
                kind=${kind}
                global_definition_locations=${global_definition_locations}
                disable_input=${disable_input}
                focus_after_creation=${focus_after_creation}
                cm_forced_focus=${cm_forced_focus}
                set_cm_forced_focus=${set_cm_forced_focus}
                show_input=${show_input}
                skip_static_fake=${is_first_cell}
                on_submit=${on_submit}
                on_delete=${on_delete}
                on_add_after=${on_add_after}
                on_change=${on_change_cell_input}
                on_update_doc_query=${on_update_doc_query}
                on_focus_neighbor=${on_focus_neighbor}
                on_line_heights=${set_line_heights}
                cell_id=${cell_id}
                notebook_id=${notebook_id}
                cm_highlighted_line=${cm_highlighted_line}
                cm_highlighted_range=${cm_highlighted_range}
                cm_diagnostics=${cm_diagnostics}
                onerror=${remount}
                running_disabled=${running_disabled}
                depends_on_disabled_cells=${depends_on_disabled_cells}
                running=${running}
                queued=${queued || (waiting_to_run && is_process_ready)}
                runtime=${runtime}
                on_run=${on_run}
                on_interrupt=${on_interrupt}
            />
            ${show_logs && cell_api_ready
                ? html`<${Logs}
                      logs=${Object.values(logs)}
                      line_heights=${line_heights}
                      set_cm_highlighted_line=${set_cm_highlighted_line}
                      sanitize_html=${sanitize_html}
                  />`
                : null}
            <button
                onClick=${() => {
                    pluto_actions.add_remote_cell(cell_id, "after")
                }}
                class="add_cell after"
                title=${t("t_add_cell_here")}
                aria-label=${t("t_add_cell_here")}
            >
                <span></span>
            </button>
        </pluto-cell>
    `
}
/**
 * @param {{
 *  cell_result: import("./Editor.js").CellResultData,
 *  cell_input: import("./Editor.js").CellInputData,
 *  [key: string]: any,
 * }} props
 * */
export const IsolatedCell = ({ cell_input: { cell_id, metadata }, cell_result: { logs, output, published_object_keys, ember }, hidden, sanitize_html = true }) => {
    const node_ref = useRef(/** @type {HTMLElement?} */ (null))
    let pluto_actions = useContext(PlutoActionsContext)
    const cell_api_ready = useCellApi(node_ref, published_object_keys, pluto_actions)
    const { show_logs } = metadata

    return html`
        <pluto-cell ref=${node_ref} id=${cell_id} class=${hidden ? "hidden-cell" : "isolated-cell"}>
            ${cell_api_ready ? html`<${CellOutput} ...${output} ember_figure=${ember?.figure} sanitize_html=${sanitize_html} cell_id=${cell_id} />` : html``}
            ${show_logs ? html`<${Logs} logs=${Object.values(logs)} line_heights=${[15]} set_cm_highlighted_line=${() => {}} />` : null}
        </pluto-cell>
    `
}
