import { html, Component } from "../imports/Preact.js"
import * as preact from "../imports/Preact.js"
import immer, { applyPatches, produceWithPatches } from "../imports/immer.js"
import _ from "../imports/lodash-es.js"

import { empty_notebook_state, is_editor_embedded_inside_editor, set_disable_ui_css } from "../editor.js"
import { create_pluto_connection } from "../common/PlutoConnection.js"
import { ask, tell, reload_prompt } from "../common/dialogs.js"
import { serialize_cells, deserialize_cells, detect_deserializer } from "../common/Serialization.js"

import { Preamble } from "./Preamble.js"
import { Notebook } from "./Notebook.js"
import { BottomRightPanel, open_bottom_right_panel } from "./BottomRightPanel.js"
import { DropRuler, get_drop_index_for_paste } from "./DropRuler.js"
import { SelectionArea } from "./SelectionArea.js"
import { UndoDelete } from "./UndoDelete.js"
import { Scroller } from "./Scroller.js"
import { Popup } from "./Popup.js"

import { has_ctrl_or_cmd_pressed, is_mac_keyboard, in_textarea_or_input } from "../common/KeyboardShortcuts.js"
import { PlutoActionsContext, PlutoBondsContext, PlutoJSInitializingContext, SetWithEmptyCallback } from "../common/PlutoContext.js"
import { setup_mathjax } from "../common/SetupMathJax.js"
import { slider_server_actions, nothing_actions } from "../common/SliderServerClient.js"
import { ProgressBar } from "./ProgressBar.js"
import { NonCellOutput } from "./NonCellOutput.js"
import { IsolatedCell } from "./Cell.js"
import { HijackExternalLinksToOpenInNewTab } from "./HackySideStuff/HijackExternalLinksToOpenInNewTab.js"
import { get_environment } from "../common/Environment.js"
import { ProcessStatus } from "../common/ProcessStatus.js"
import { SafePreviewUI } from "./SafePreviewUI.js"
import { Header } from "./Header.js"
import { open_pluto_popup } from "../common/open_pluto_popup.js"
import { get_included_external_source } from "../common/external_source.js"
import { getCurrentLanguage, getWritingDirection, t, th } from "../common/lang.js"
import { MoveDialog } from "./MoveDialog.js"
import { with_query_params } from "../common/URLTools.js"
import { ConfirmBeforeLongRuntime, maybe_abort_long_runtime } from "./ConfirmBeforeLongRuntime.js"
import { RunTracker, run_started } from "./RunTracker.js"
import { Settings } from "./Settings.js"
import { ShortcutsSheet } from "./ShortcutsSheet.js"

// This is imported asynchronously - uncomment for development
// import environment from "../common/Environment.js"

export const default_path = ""
const DEBUG_DIFFING = false

// Be sure to keep this in sync with DEFAULT_CELL_METADATA in Cell.jl
/** @type {CellMetaData} */
const DEFAULT_CELL_METADATA = {
    disabled: false,
    show_logs: true,
    skip_as_script: false,
}

// from our friends at https://stackoverflow.com/a/2117523
// i checked it and it generates Julia-legal UUIDs and that's all we need -SNOF
const uuidv4 = () =>
    //@ts-ignore
    "10000000-1000-4000-8000-100000000000".replace(/[018]/g, (c) => (c ^ (crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (c / 4)))).toString(16))

/**
 * @typedef {import('../imports/immer').Patch} Patch
 * */

const Main = ({ children }) => {
    return html`<main>${children}</main>`
}

/**
 * Map of status => Bool. In order of decreasing priority.
 */
const statusmap = (/** @type {EditorState} */ state, /** @type {LaunchParameters} */ launch_params) => ({
    disconnected: !(state.connected || state.initializing || state.static_preview),
    loading: state.initializing,
    process_waiting_for_permission: state.notebook.process_status === ProcessStatus.waiting_for_permission && !state.initializing,
    process_restarting: state.notebook.process_status === ProcessStatus.waiting_to_restart,
    process_dead: state.notebook.process_status === ProcessStatus.no_process || state.notebook.process_status === ProcessStatus.waiting_to_restart,
    nbpkg_restart_required: state.notebook.nbpkg?.restart_required_msg != null,
    nbpkg_restart_recommended: state.notebook.nbpkg?.restart_recommended_msg != null,
    nbpkg_disabled: state.notebook.nbpkg?.enabled === false || state.notebook.nbpkg?.waiting_for_permission_but_probably_disabled === true,
    static_preview: state.static_preview,
    inspecting_hidden_code: state.inspecting_hidden_code,
    bonds_disabled: !(
        // initializing, no answer yet
        (
            state.initializing ||
            // connected to regular pluto server
            state.connected ||
            // connected to slider server
            (launch_params.slider_server_url != null && (state.slider_server?.connecting || state.slider_server?.interactive))
        )
    ),
    code_differs: state.notebook.cell_order.some(
        (cell_id) => state.cell_inputs_local[cell_id] != null && state.notebook.cell_inputs[cell_id]?.code !== state.cell_inputs_local[cell_id].code
    ),
    isolated_cell_view: launch_params.isolated_cell_ids != null && launch_params.isolated_cell_ids.length > 0,
    // Not sanitized merely for being an export: a downloaded export is an
    // HTML file and can run scripts anyway, and Ember exports inline widget
    // files so widgets work. An export of a notebook in safe preview still is.
    sanitize_html: state.notebook.process_status === ProcessStatus.waiting_for_permission,
})

/**
 * @typedef CellMetaData
 * @type {{
 *    disabled: boolean,
 *    show_logs: boolean,
 *    skip_as_script: boolean
 *  }}
 *
 * @typedef CellInputData
 * @type {{
 *  cell_id: string,
 *  code: string,
 *  code_folded: boolean,
 *  metadata: CellMetaData,
 * }}
 */

/**
 * @typedef LogEntryData
 * @type {{
 *   level: number,
 *   msg: string,
 *   file: string,
 *   line: number,
 *   kwargs: Object,
 * }}
 */

/**
 * @typedef CellResultData
 * @type {{
 *  cell_id: string,
 *  queued: boolean,
 *  running: boolean,
 *  errored: boolean,
 *  runtime: number?,
 *  downstream_cells_map: { [variable: string]: [string]},
 *  upstream_cells_map: { [variable: string]: [string]},
 *  precedence_heuristic: number?,
 *  depends_on_disabled_cells: boolean,
 *  depends_on_skipped_cells: boolean,
 *  ember: { stale: boolean, code_changed: boolean, upstream_error?: {name: string, cell: string}[], disabled_by?: string, can_disable: boolean, split?: number },
 *  output: {
 *      body: string | Object,
 *      persist_js_state: boolean,
 *      last_run_timestamp: number,
 *      mime: string,
 *      rootassignee: string?,
 *      has_pluto_hook_features: boolean,
 *  },
 *  logs: Array<LogEntryData>,
 *  published_object_keys: [string],
 * }}
 */

/**
 * @typedef CellDependencyData
 * @property {string} cell_id
 * @property {Record<string, Array<string>>} downstream_cells_map A map where the keys are the variables *defined* by this cell, and a value is the list of cell IDs that reference a variable.
 * @property {Record<string, Array<string>>} upstream_cells_map A map where the keys are the variables *referenced* by this cell, and a value is the list of cell IDs that define a variable.
 * @property {number} precedence_heuristic
 */

/**
 * @typedef CellDependencyGraph
 * @type {{ [uuid: string]: CellDependencyData }}
 */

/**
 * @typedef NotebookPkgData
 * @type {{
 *  enabled: boolean,
 *  waiting_for_permission: boolean?,
 *  waiting_for_permission_but_probably_disabled: boolean?,
 *  restart_recommended_msg: string?,
 *  restart_required_msg: string?,
 *  installed_versions: { [pkg_name: string]: string },
 *  terminal_outputs: { [pkg_name: string]: string },
 *  install_time_ns: number?,
 *  busy_packages: string[],
 *  instantiated: boolean,
 * }}
 */

/**
 * @typedef LaunchParameters
 * @type {{
 *  notebook_id: string?,
 *  statefile: string?,
 *  statefile_integrity: string?,
 *  notebookfile: string?,
 *  notebookfile_integrity: string?,
 *  disable_ui: boolean,
 *  preamble_html: string?,
 *  isolated_cell_ids: string[]?,
 *  slider_server_url: string?,
 *  recording_url: string?,
 *  recording_url_integrity: string?,
 *  recording_audio_url: string?,
 * }}
 */

/**
 * @typedef BondValueContainer
 * @type {{ value: any }}
 */

/**
 * @typedef BondValuesDict
 * @type {{ [name: string]: BondValueContainer }}
 */

/**
 * @typedef EmberPackageRow
 * @type {{ name: string, version: string?, source: string?, direct: boolean, status: string, message: string? }}
 */

/**
 * @typedef EmberInstallFailure
 * @type {{ package: string, version: string?, kind: string, detail: string?, needed_by: Array<string> }}
 */

/**
 * @typedef EmberPackagesUpdate
 * @type {{
 *  date: string, status: "checking" | "ready" | "failed",
 *  restart: Array<string>, changes: number, message: string?,
 * }}
 */

/**
 * @typedef EmberPackagesData
 * @type {{
 *  snapshot: string?,
 *  r_version: string?,
 *  bioc_version: string?,
 *  library: {
 *   status: string, message: string?, progress: { done: number, total: number, current: string }?,
 *   log: string?, failures: Array<EmberInstallFailure>,
 *  },
 *  rows: Array<EmberPackageRow>,
 *  update: EmberPackagesUpdate?,
 * }}
 */

/**
 * @typedef EmberData
 * @type {{
 *  process: "preview" | "starting" | "ready" | "busy" | "stopped",
 *  worker_memory: number?,
 *  not_run: number,
 *  stale: number,
 *  plan: { install: number, restart: Array<string> }?,
 *  packages: EmberPackagesData,
 * }}
 */

/**
 * @typedef NotebookData
 * @type {{
 *  pluto_version?: string,
 *  julia_version?: string,
 *  notebook_id: string,
 *  path: string,
 *  shortpath: string,
 *  in_temp_dir: boolean,
 *  process_status: string,
 *  last_save_time: number,
 *  last_hot_reload_time: number,
 *  cell_inputs: { [uuid: string]: CellInputData },
 *  cell_results: { [uuid: string]: CellResultData },
 *  cell_dependencies: CellDependencyGraph,
 *  cell_order: Array<string>,
 *  cell_execution_order: Array<string>,
 *  published_objects: { [objectid: string]: any},
 *  bonds: BondValuesDict,
 *  nbpkg: NotebookPkgData?,
 *  metadata: object,
 *  ember: EmberData,
 * }}
 */

export const url_logo_small = get_included_external_source("pluto-logo-small")?.href

/**
 * @typedef EditorProps
 * @type {{
 * launch_params: LaunchParameters,
 * initial_notebook_state: NotebookData,
 * preamble_element: preact.ReactElement?,
 * pluto_editor_element: HTMLElement,
 * }}
 */

/**
 * @typedef EditorState
 * @type {{
 * notebook: NotebookData,
 * cell_inputs_local: { [uuid: string]: { code: String } },
 * desired_doc_query: ?String,
 * recently_deleted: ?Array<{ index: number, cell: CellInputData }>,
 * last_update_time: number,
 * disable_ui: boolean,
 * static_preview: boolean,
 * inspecting_hidden_code: boolean,
 * refresh_target: ?string,
 * connected: boolean,
 * initializing: boolean,
 * scroller: {
 * up: boolean,
 * down: boolean,
 * },
 * move_dialog_open: boolean,
 * last_created_cell: string | undefined,
 * selected_cells: Array<string>,
 * extended_components: any,
 * slider_server: { connecting: boolean, interactive: boolean },
 * }}
 */

/**
 * @augments Component<EditorProps,EditorState>
 */
export class Editor extends Component {
    constructor(/** @type {EditorProps} */ props) {
        super(props)

        const { launch_params, initial_notebook_state } = this.props

        /** @type {EditorState} */
        this.state = {
            notebook: initial_notebook_state,
            cell_inputs_local: {},
            desired_doc_query: null,
            recently_deleted: [],
            last_update_time: 0,

            disable_ui: launch_params.disable_ui,
            static_preview: launch_params.statefile != null,
            inspecting_hidden_code: false,
            refresh_target: null,
            connected: false,
            initializing: true,

            scroller: {
                up: false,
                down: false,
            },
            move_dialog_open: false,

            last_created_cell: undefined,
            selected_cells: [],

            extended_components: {
                CustomHeader: null,
            },

            slider_server: {
                connecting: false,
                interactive: false,
            },
        }

        this.setStatePromise = (fn) => new Promise((r) => this.setState(fn, r))

        // these are things that can be done to the local notebook
        this.real_actions = {
            get_notebook: () => this?.state?.notebook ?? {},
            get_session_options: () => this.client.session_options,
            get_launch_params: () => this.props.launch_params,
            send: (message_type, ...args) => this.client.send(message_type, ...args),
            get_published_object: (objectid) => this.state.notebook.published_objects[objectid],
            //@ts-ignore
            update_notebook: (...args) => this.update_notebook(...args),
            set_doc_query: (query) => this.setState({ desired_doc_query: query }),
            set_local_cell: (cell_id, new_val) => {
                return this.setStatePromise(
                    immer((/** @type {EditorState} */ state) => {
                        state.cell_inputs_local[cell_id] = {
                            code: new_val,
                        }
                        state.selected_cells = []
                    })
                )
            },
            select_cell: (cell_id) => {
                this.setState({ selected_cells: [cell_id] }, () => document.getElementById(cell_id)?.focus({ preventScroll: true }))
                document.getElementById(cell_id)?.scrollIntoView({ block: "nearest" })
            },
            focus_on_neighbor: (cell_id, delta, line = delta === -1 ? Infinity : -1, ch = 0) => {
                const i = this.state.notebook.cell_order.indexOf(cell_id)
                const new_i = i + delta
                if (new_i >= 0 && new_i < this.state.notebook.cell_order.length) {
                    window.dispatchEvent(
                        new CustomEvent("cell_focus", {
                            detail: {
                                cell_id: this.state.notebook.cell_order[new_i],
                                line: line,
                                ch: ch,
                            },
                        })
                    )
                }
            },
            add_deserialized_cells: async (data, index_or_id, deserializer = deserialize_cells) => {
                let new_codes = deserializer(data)
                /** @type {Array<CellInputData>} Create copies of the cells with fresh ids */
                let new_cells = new_codes.map((code) => ({
                    cell_id: uuidv4(),
                    code: code,
                    code_folded: false,
                    metadata: {
                        ...DEFAULT_CELL_METADATA,
                    },
                }))

                let index

                if (typeof index_or_id === "number") {
                    index = index_or_id
                } else {
                    /* if the input is not an integer, try interpreting it as a cell id */
                    index = this.state.notebook.cell_order.indexOf(index_or_id)
                    if (index !== -1) {
                        /* Make sure that the cells are pasted after the current cell */
                        index += 1
                    }
                }

                if (index === -1) {
                    index = this.state.notebook.cell_order.length
                }

                /** Update local_code. Local code doesn't force CM to update it's state
                 * (the usual flow is keyboard event -> cm -> local_code and not the opposite )
                 * See ** 1 **
                 */
                this.setState(
                    immer((/** @type {EditorState} */ state) => {
                        // Deselect everything first, to clean things up
                        state.selected_cells = []

                        for (let cell of new_cells) {
                            state.cell_inputs_local[cell.cell_id] = cell
                        }
                        state.last_created_cell = new_cells[0]?.cell_id
                    })
                )

                /**
                 * Create an empty cell in the julia-side.
                 * Code will differ, until the user clicks 'run' on the new code
                 */
                await update_notebook((notebook) => {
                    for (const cell of new_cells) {
                        notebook.cell_inputs[cell.cell_id] = {
                            ...cell,
                            // Fill the cell with empty code remotely, so it doesn't run unsafe code
                            code: "",
                            metadata: {
                                ...DEFAULT_CELL_METADATA,
                            },
                        }
                    }
                    notebook.cell_order = [
                        ...notebook.cell_order.slice(0, index),
                        ...new_cells.map((x) => x.cell_id),
                        ...notebook.cell_order.slice(index, Infinity),
                    ]
                })
            },
            interrupt_remote: (cell_id) => {
                // TODO Make this cooler
                // set_notebook_state((prevstate) => {
                //     return {
                //         cells: prevstate.cells.map((c) => {
                //             return { ...c, errored: c.errored || c.running || c.queued }
                //         }),
                //     }
                // })
                this.client.send("interrupt_all", {}, { notebook_id: this.state.notebook.notebook_id }, false)
            },
            move_remote_cells: (cell_ids, new_index) => {
                return update_notebook((notebook) => {
                    new_index = Math.max(0, new_index)
                    let before = notebook.cell_order.slice(0, new_index).filter((x) => !cell_ids.includes(x))
                    let after = notebook.cell_order.slice(new_index, Infinity).filter((x) => !cell_ids.includes(x))
                    notebook.cell_order = [...before, ...cell_ids, ...after]
                })
            },
            add_remote_cell_at: async (index, code = "") => {
                let id = uuidv4()
                this.setState({ last_created_cell: id })
                await update_notebook((notebook) => {
                    notebook.cell_inputs[id] = {
                        cell_id: id,
                        code,
                        code_folded: false,
                        metadata: { ...DEFAULT_CELL_METADATA },
                    }
                    notebook.cell_order = [...notebook.cell_order.slice(0, index), id, ...notebook.cell_order.slice(index, Infinity)]
                })
                if (code.trim() !== "") run_started()
                await this.client.send("run_multiple_cells", { cells: [id] }, { notebook_id: this.state.notebook.notebook_id })
                return id
            },
            add_remote_cell: async (cell_id, before_or_after, code) => {
                const index = this.state.notebook.cell_order.indexOf(cell_id)
                const delta = before_or_after == "before" ? 0 : 1
                return await this.actions.add_remote_cell_at(index + delta, code)
            },
            confirm_delete_multiple: async (cell_ids) => {
                if (
                    cell_ids.length <= 1 ||
                    (await ask({
                        body: t("t_confirm_delete_multiple_cells", { count: cell_ids.length }),
                        actions: [
                            { label: t("t_delete"), value: true, primary: true, danger: true },
                            { label: t("t_cancel"), value: false },
                        ],
                        cancel_value: false,
                    }))
                ) {
                    if (cell_ids.some((cell_id) => this.state.notebook.cell_results[cell_id]?.running || this.state.notebook.cell_results[cell_id]?.queued)) {
                        if (
                            await ask({
                                body: t("t_confirm_delete_multiple_interrupt_notebook"),
                                actions: [
                                    { label: t("t_stop"), value: true, primary: true },
                                    { label: t("t_cancel"), value: false },
                                ],
                                cancel_value: false,
                            })
                        ) {
                            this.actions.interrupt_remote(cell_ids[0])
                        }
                    } else {
                        this.setState(
                            immer((/** @type {EditorState} */ state) => {
                                state.recently_deleted = cell_ids.map((cell_id) => {
                                    return {
                                        index: this.state.notebook.cell_order.indexOf(cell_id),
                                        cell: this.state.notebook.cell_inputs[cell_id],
                                    }
                                })
                                state.selected_cells = []
                            })
                        )
                        await update_notebook((notebook) => {
                            for (let cell_id of cell_ids) {
                                delete notebook.cell_inputs[cell_id]
                            }
                            notebook.cell_order = notebook.cell_order.filter((cell_id) => !cell_ids.includes(cell_id))
                        })
                        await this.client.send("run_multiple_cells", { cells: [] }, { notebook_id: this.state.notebook.notebook_id })
                    }
                }
            },
            fold_remote_cells: async (cell_ids, new_value) => {
                await update_notebook((notebook) => {
                    for (let cell_id of cell_ids) {
                        const cell = notebook.cell_inputs[cell_id]
                        if (cell) cell.code_folded = new_value ?? !cell.code_folded
                    }
                })
            },
            set_and_run_all_changed_remote_cells: async () => {
                const changed = this.state.notebook.cell_order.filter(
                    (cell_id) =>
                        this.state.cell_inputs_local[cell_id] != null &&
                        this.state.notebook.cell_inputs[cell_id]?.code !== this.state.cell_inputs_local[cell_id]?.code
                )
                await this.actions.set_and_run_multiple(changed)
                return changed.length > 0
            },
            set_and_run_multiple: async (cell_ids) => {
                // This function is called with an empty list when you press Shift+Enter without any selected cells.
                if (cell_ids.length > 0) {
                    if (await maybe_abort_long_runtime(this.state.notebook, cell_ids)) {
                        return false
                    }
                    run_started()

                    window.dispatchEvent(
                        new CustomEvent("set_waiting_to_run_smart", {
                            detail: {
                                cell_ids,
                            },
                        })
                    )

                    await update_notebook((notebook) => {
                        for (let cell_id of cell_ids) {
                            if (this.state.cell_inputs_local[cell_id]) {
                                if (notebook.cell_inputs[cell_id]) {
                                    notebook.cell_inputs[cell_id].code = this.state.cell_inputs_local[cell_id].code
                                }
                            }
                        }
                    })
                    await this.setStatePromise(
                        immer((/** @type {EditorState} */ state) => {
                            for (let cell_id of cell_ids) {
                                // This is a "dirty" trick, as this should actually be stored in some shared request_status => status state
                                // But for now... this is fine 😼
                                if (state.notebook.cell_results[cell_id] != null) {
                                    state.notebook.cell_results[cell_id].queued = this.is_process_ready()
                                } else {
                                    // nothing
                                }
                            }
                        })
                    )
                    await this.client.send("run_multiple_cells", { cells: cell_ids }, { notebook_id: this.state.notebook.notebook_id })
                    return true
                }
                return false
            },
            /**
             *
             * @param {string} name name of bound variable
             * @param {*} value value (not in wrapper object)
             */
            set_bond: async (name, value) => {
                await update_notebook((notebook) => {
                    // Wrap the bond value in an object so immer assumes it is changed
                    let new_bond = { value: value }
                    notebook.bonds[name] = new_bond
                })
            },
            reshow_cell: (cell_id, objectid, dim) =>
                this.client.send(
                    "reshow_cell",
                    {
                        objectid,
                        dim,
                        cell_id,
                    },
                    { notebook_id: this.state.notebook.notebook_id },
                    false
                ),
            ember_render_plot: (cell_id, res) =>
                this.client.send(
                    "ember_render_plot",
                    {
                        cell_id,
                        res,
                    },
                    { notebook_id: this.state.notebook.notebook_id },
                    false
                ),
            ember_run_all: () => {
                run_started()
                return this.client.send("ember_run_all", {}, { notebook_id: this.state.notebook.notebook_id }, false)
            },
            ember_set_mode: (mode) =>
                this.client.send("ember_set_mode", { mode }, { notebook_id: this.state.notebook.notebook_id }, false),
            ember_update_packages: () =>
                this.client.send("ember_update_packages", {}, { notebook_id: this.state.notebook.notebook_id }, false),
            ember_apply_update: (date) =>
                this.client.send("ember_apply_update", { date }, { notebook_id: this.state.notebook.notebook_id }, false),
            ember_cancel_update: () =>
                this.client.send("ember_cancel_update", {}, { notebook_id: this.state.notebook.notebook_id }, false),
            ember_split_cell: (cell_id, code) =>
                this.client.send("ember_split_cell", { cell_id, code }, { notebook_id: this.state.notebook.notebook_id }, false),
            ember_move_notebook: (name, folder) =>
                this.client.send("ember_move_notebook", { name, folder }, { notebook_id: this.state.notebook.notebook_id }),
            request_js_link_response: (cell_id, link_id, input) => {
                return this.client
                    .send(
                        "request_js_link_response",
                        {
                            cell_id,
                            link_id,
                            input,
                        },
                        { notebook_id: this.state.notebook.notebook_id }
                    )
                    .then((r) => r.message)
            },
            /** This actions avoids pushing selected cells all the way down, which is too heavy to handle! */
            get_selected_cells: (cell_id, /** @type {boolean} */ allow_other_selected_cells) =>
                allow_other_selected_cells ? this.state.selected_cells : [cell_id],
            get_avaible_versions: async ({ package_name, notebook_id }) => {
                const { message } = await this.client.send("nbpkg_available_versions", { package_name: package_name }, { notebook_id: notebook_id })
                return message
            },
        }
        this.actions = { ...this.real_actions }

        const apply_notebook_patches = (patches, /** @type {NotebookData?} */ old_state = null, get_reverse_patches = false) =>
            new Promise((resolve) => {
                if (patches.length !== 0) {
                    let _copy_of_patches,
                        reverse_of_patches = []
                    this.setState(
                        immer((/** @type {EditorState} */ state) => {
                            let new_notebook
                            try {
                                // To test this, uncomment the lines below:
                                // if (Math.random() < 0.25) {
                                //     throw new Error(`Error: [Immer] minified error nr: 15 '${patches?.[0]?.path?.join("/")}'    .`)
                                // }

                                if (get_reverse_patches) {
                                    ;[new_notebook, _copy_of_patches, reverse_of_patches] = produceWithPatches(old_state ?? state.notebook, (state) => {
                                        applyPatches(state, patches)
                                    })
                                    // TODO: why was `new_notebook` not updated?
                                    // this is why the line below is also called when `get_reverse_patches === true`
                                }
                                new_notebook = applyPatches(old_state ?? state.notebook, patches)
                            } catch (exception) {
                                /** Example: `"a.b[2].c"` */
                                const failing_path = String(exception).match(".*'(.*)'.*")?.[1]?.replace(/\//gi, ".") ?? String(exception)
                                const path_value = _.get(this.state.notebook, failing_path, "Not Found")
                                console.log(String(exception).match(".*'(.*)'.*")?.[1]?.replace(/\//gi, ".") ?? exception, failing_path, typeof failing_path)
                                console.error(
                                    `#######################**************************########################
PlutoError: StateOutOfSync: Failed to apply patches.
Please report this: https://github.com/JuliaPluto/Pluto.jl/issues adding the info below:
failing path: ${failing_path}
notebook previous value: ${path_value}
patch: ${JSON.stringify(
                                        patches?.find(({ path }) => path.join("") === failing_path),
                                        null,
                                        1
                                    )}
all patches: ${JSON.stringify(patches, null, 1)}
#######################**************************########################`,
                                    exception
                                )

                                let parts = failing_path.split(".")
                                for (let i = 0; i < parts.length; i++) {
                                    let path = parts.slice(0, i).join(".")
                                    console.log(path, _.get(this.state.notebook, path, "Not Found"))
                                }

                                if (this.state.connected) {
                                    console.error("Trying to recover: Refetching notebook...")
                                    this.client.send(
                                        "reset_shared_state",
                                        {},
                                        {
                                            notebook_id: this.state.notebook.notebook_id,
                                        },
                                        false
                                    )
                                } else if (this.state.static_preview && launch_params.slider_server_url != null) {
                                    open_pluto_popup({
                                        type: "warn",
                                        body: html`Something went wrong while updating the notebook state. Please refresh the page to try again.`,
                                    })
                                } else {
                                    console.error("Trying to recover: reloading...")
                                    window.parent.location.href = this.state.refresh_target ?? window.location.href
                                }
                                return
                            }

                            if (DEBUG_DIFFING) {
                                console.group("Update!")
                                for (let patch of patches) {
                                    console.group(`Patch :${patch.op}`)
                                    console.log(patch.path)
                                    console.log(patch.value)
                                    console.groupEnd()
                                }
                                console.groupEnd()
                            }

                            let cells_stuck_in_limbo = new_notebook.cell_order.filter((cell_id) => new_notebook.cell_inputs[cell_id] == null)
                            if (cells_stuck_in_limbo.length !== 0) {
                                console.warn(`cells_stuck_in_limbo:`, cells_stuck_in_limbo)
                                new_notebook.cell_order = new_notebook.cell_order.filter((cell_id) => new_notebook.cell_inputs[cell_id] != null)
                            }
                            this.on_patches_hook(patches)
                            state.notebook = new_notebook
                        }),
                        () => resolve(reverse_of_patches)
                    )
                } else {
                    resolve([])
                }
            })

        this.apply_notebook_patches = apply_notebook_patches
        // these are update message that are _not_ a response to a `send(*, *, {create_promise: true})`
        this.last_update_counter = -1
        const check_update_counter = (new_val) => {
            if (new_val <= this.last_update_counter) {
                console.error("State update out of order", new_val, this.last_update_counter)
                reload_prompt()
            }
            this.last_update_counter = new_val
        }

        const on_update = (update, by_me) => {
            if (this.state.notebook.notebook_id === update.notebook_id) {
                const message = update.message
                switch (update.type) {
                    case "notebook_diff":
                        check_update_counter(message?.counter)
                        let apply_promise = Promise.resolve()
                        if (message?.response?.from_reset) {
                            console.log("Trying to reset state after failure")
                            apply_promise = apply_notebook_patches(
                                message.patches,
                                empty_notebook_state({ notebook_id: this.state.notebook.notebook_id })
                            ).catch((e) => {
                                console.error("Failed to reset state after failure", e)
                                reload_prompt()
                                throw e
                            })
                        } else if (message.patches.length !== 0) {
                            apply_promise = apply_notebook_patches(message.patches)
                        }

                        const set_waiting = () => {
                            let from_update = message?.response?.update_went_well != null
                            let is_just_acknowledgement = from_update && message.patches.length === 0
                            if (!is_just_acknowledgement) {
                                this.waiting_for_bond_to_trigger_execution = false
                            }
                        }
                        apply_promise.finally(set_waiting).then(() => {
                            this.maybe_send_queued_bond_changes()
                        })

                        break
                    default:
                        console.error("Received unknown update type!", update)
                        // alert("Something went wrong 🙈\n Try clearing your browser cache and refreshing the page")
                        break
                }
            } else {
                // Update for a different notebook, TODO maybe log this as it shouldn't happen
            }
        }

        const on_establish_connection = async (client) => {
            // nasty
            Object.assign(this.client, client)
            try {
                const environment = await get_environment(client)
                const { custom_editor_header_component, custom_non_cell_output } = environment({ client, editor: this, imports: { preact } })
                this.setState({
                    extended_components: {
                        ...this.state.extended_components,
                        CustomHeader: custom_editor_header_component,
                        NonCellOutputComponents: custom_non_cell_output,
                    },
                })
            } catch (e) {}

            // @ts-ignore
            window.version_info = this.client.version_info // for debugging
            // @ts-ignore
            window.kill_socket = this.client.kill // for debugging

            if (!client.notebook_exists) {
                console.error("Notebook does not exist. Not connecting.")
                return
            }
            console.debug("Sending update_notebook request...")
            await this.client.send("update_notebook", { updates: [] }, { notebook_id: this.state.notebook.notebook_id }, false)
            console.debug("Received update_notebook request")

            this.setState({
                initializing: false,
                static_preview: false,
                inspecting_hidden_code: false,
            })

            this.updateLang()
        }

        const on_connection_status = (val, hopeless) => {
            this.setState({ connected: val })
            if (hopeless) {
                // https://github.com/fonsp/Pluto.jl/issues/55
                // https://github.com/fonsp/Pluto.jl/issues/2398
                open_pluto_popup({
                    type: "warn",
                    body: html`<p>A new server was started - this notebook session is no longer running.</p>
                        <p>Would you like to go back to the main menu?</p>
                        <br />
                        <a href="./">Go back</a>
                        <br />
                        <a
                            href="javascript:;"
                            target="_self"
                            onClick=${(e) => {
                                e.preventDefault()
                                window.dispatchEvent(new CustomEvent("close pluto popup"))
                            }}
                            >Stay here</a
                        >`,
                    should_focus: false,
                })
            }
        }

        const on_reconnect = async () => {
            console.warn("Reconnected! Checking states")

            await this.client.send(
                "reset_shared_state",
                {},
                {
                    notebook_id: this.state.notebook.notebook_id,
                },
                false
            )

            return true
        }

        this.export_url = (/** @type {string} */ u, /** @type {Record<string, string | null | undefined>=} */ params = {}) =>
            with_query_params(`./${u}?id=${this.state.notebook.notebook_id}`, params)

        /** @type {import('../common/PlutoConnection').PlutoConnection} */
        this.client = /** @type {import('../common/PlutoConnection').PlutoConnection} */ ({})

        this.connect = (/** @type {string | undefined} */ ws_address = undefined) => {
            return create_pluto_connection({
                ws_address: ws_address,
                on_unrequested_update: on_update,
                on_connection_status: on_connection_status,
                on_reconnect: on_reconnect,
                connect_metadata: { notebook_id: this.state.notebook.notebook_id },
            }).then(on_establish_connection)
        }

        this.on_disable_ui = () => {
            set_disable_ui_css(this.state.disable_ui, props.pluto_editor_element)

            // Pluto has three modes of operation:
            // 1. (normal) Connected to a Pluto notebook.
            // 2. Static HTML with PlutoSliderServer. All edits are ignored, but bond changes are processes by the PlutoSliderServer.
            // 3. Static HTML without PlutoSliderServer. All interactions are ignored.
            //
            // To easily support all three with minimal changes to the source code, we sneakily swap out the `this.actions` object (`pluto_actions` in other source files) with a different one:
            Object.assign(
                this.actions,
                // if we have no pluto server...
                this.state.disable_ui || (launch_params.slider_server_url != null && !this.state.connected)
                    ? // then use a modified set of actions
                      launch_params.slider_server_url != null
                        ? slider_server_actions({
                              setStatePromise: this.setStatePromise,
                              actions: this.actions,
                              launch_params: launch_params,
                              apply_notebook_patches,
                              get_original_state: () => this.props.initial_notebook_state,
                              get_current_state: () => this.state.notebook,
                          })
                        : nothing_actions({
                              actions: this.actions,
                          })
                    : // otherwise, use the real actions
                      this.real_actions
            )
        }
        this.on_disable_ui()

        // Not completely happy with this yet, but it will do for now - DRAL
        /** Patches that are being delayed until all cells have finished running. */
        this.bond_changes_to_apply_when_done = []
        this.maybe_send_queued_bond_changes = () => {
            if (this.notebook_is_idle() && this.bond_changes_to_apply_when_done.length !== 0) {
                // console.log("Applying queued bond changes!", this.bond_changes_to_apply_when_done)
                let bonds_patches = this.bond_changes_to_apply_when_done
                this.bond_changes_to_apply_when_done = []
                this.update_notebook((notebook) => {
                    applyPatches(notebook, bonds_patches)
                })
            }
        }
        /** This tracks whether we just set a bond value which will trigger a cell to run, but we are still waiting for the server to process the bond value (and run the cell). During this time, we won't send new bond values. See https://github.com/fonsp/Pluto.jl/issues/1891 for more info. */
        this.waiting_for_bond_to_trigger_execution = false
        /** Number of local updates that have not yet been applied to the server's state. */
        this.pending_local_updates = 0
        /**
         * User scripts that are currently running (possibly async).
         * @type {SetWithEmptyCallback<HTMLElement>}
         */
        this.js_init_set = new SetWithEmptyCallback(() => {
            // console.info("All scripts finished!")
            this.maybe_send_queued_bond_changes()
        })

        // @ts-ignore This is for tests
        document.body._js_init_set = this.js_init_set

        /** Is the notebook ready to execute code right now? (i.e. are no cells queued or running?) */
        this.notebook_is_idle = () => {
            return !(
                this.waiting_for_bond_to_trigger_execution ||
                this.pending_local_updates > 0 ||
                // a cell is running:
                Object.values(this.state.notebook.cell_results).some((cell) => cell.running || cell.queued) ||
                // a cell is initializing JS:
                !_.isEmpty(this.js_init_set) ||
                !this.is_process_ready()
            )
        }
        this.is_process_ready = () =>
            this.state.notebook.process_status === ProcessStatus.starting || this.state.notebook.process_status === ProcessStatus.ready

        const bond_will_trigger_evaluation = (/** @type {string|PropertyKey} */ sym) =>
            Object.entries(this.state.notebook.cell_dependencies).some(([cell_id, deps]) => {
                // if the other cell depends on the variable `sym`...
                if (deps.upstream_cells_map.hasOwnProperty(sym)) {
                    // and the cell is not disabled
                    const running_disabled = this.state.notebook.cell_inputs[cell_id]?.metadata?.disabled ?? false
                    // or indirectly disabled
                    const indirectly_disabled = this.state.notebook.cell_results[cell_id]?.depends_on_disabled_cells ?? false
                    return !(running_disabled || indirectly_disabled)
                }
            })

        /**
         * We set `waiting_for_bond_to_trigger_execution` to `true` if it is *guaranteed* that this bond change will trigger something to happen (i.e. a cell to run). See https://github.com/fonsp/Pluto.jl/pull/1892 for more info about why.
         *
         * This is guaranteed if there is a cell in the notebook that references the bound variable. We use our copy of the notebook's toplogy to check this.
         *
         * # Gotchas:
         * 1. We (the frontend) might have an out-of-date copy of the notebook's topology: this bond might have dependents *right now*, but the backend might already be processing a code change that removes that dependency.
         *
         *     However, this change in topology will result in a patch, which will set `waiting_for_bond_to_trigger_execution` back to `false`.
         *
         * 2. The backend has a "first value" mechanism: if bond values are being set for the first time *and* this value is already set on the backend, then the value will be skipped. See https://github.com/fonsp/Pluto.jl/issues/275. If all bond values are skipped, then we might get zero patches back (because no cells will run).
         *
         *     A bond value is considered a "first value" if it is sent using an `"add"` patch. This is why we require `x.op === "replace"`.
         */
        const bond_patch_will_trigger_evaluation = (/** @type {Patch} */ x) =>
            x.op === "replace" && x.path[1] != undefined && bond_will_trigger_evaluation(x.path[1])

        let last_update_notebook_task = Promise.resolve()
        /** @param {(notebook: NotebookData) => void} mutate_fn */
        let update_notebook = (mutate_fn) => {
            const new_task = last_update_notebook_task.then(async () => {
                // if (this.state.initializing) {
                //     console.error("Update notebook done during initializing, strange")
                //     return
                // }

                let [new_notebook, changes, inverseChanges] = produceWithPatches(this.state.notebook, (notebook) => {
                    mutate_fn(notebook)
                })

                // If "notebook is not idle" we seperate and store the bonds updates,
                // to send when the notebook is idle. This delays the updating of the bond for performance,
                // but when the server can discard bond updates itself (now it executes them one by one, even if there is a newer update ready)
                // this will no longer be necessary
                let is_idle = this.notebook_is_idle()
                let changes_involving_bonds = changes.filter((x) => x.path[0] === "bonds")
                if (!is_idle) {
                    this.bond_changes_to_apply_when_done = [...this.bond_changes_to_apply_when_done, ...changes_involving_bonds]
                    changes = changes.filter((x) => x.path[0] !== "bonds")
                }

                if (DEBUG_DIFFING) {
                    try {
                        let previous_function_name = new Error().stack?.split("\n")[2]?.trim().split(" ")[1]
                        console.log(`Changes to send to server from "${previous_function_name}":`, changes)
                    } catch (error) {}
                }
                for (let change of changes) {
                    if (change.path.some((x) => typeof x === "number")) {
                        throw new Error("This sounds like it is editing an array...")
                    }
                }

                if (changes.length === 0) {
                    return
                }
                if (is_idle) {
                    this.waiting_for_bond_to_trigger_execution =
                        this.waiting_for_bond_to_trigger_execution || changes_involving_bonds.some(bond_patch_will_trigger_evaluation)
                }
                this.pending_local_updates++
                this.on_patches_hook(changes)
                try {
                    // console.log("Sending changes to server:", changes)
                    await Promise.all([
                        this.client.send("update_notebook", { updates: changes }, { notebook_id: this.state.notebook.notebook_id }, false).then((response) => {
                            if (response.message?.response?.update_went_well === "👎") {
                                // We only throw an error for functions that are waiting for this
                                // Notebook state will already have the changes reversed
                                throw new Error(`Pluto update_notebook error: (from Julia: ${response.message.response.why_not})`)
                            }
                        }),
                        this.setStatePromise({
                            notebook: new_notebook,
                            last_update_time: Date.now(),
                        }),
                    ])
                } finally {
                    this.pending_local_updates--
                    // this property is used to tell our frontend tests that the updates are done
                    //@ts-ignore
                    document.body._update_is_ongoing = this.pending_local_updates > 0
                }
            })
            last_update_notebook_task = new_task.catch(console.error)
            return new_task
        }
        this.update_notebook = update_notebook
        //@ts-ignore
        window.shutdownNotebook = this.close = () => {
            this.client.send(
                "shutdown_notebook",
                {
                    keep_in_session: false,
                },
                {
                    notebook_id: this.state.notebook.notebook_id,
                },
                false
            )
        }
        this.delete_selected = () => {
            const active = /** @type {HTMLElement?} */ (document.activeElement)
            const typing = active != null && (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable)
            if (this.state.selected_cells.length > 0 && !typing) {
                this.actions.confirm_delete_multiple(this.state.selected_cells)
                return true
            }
        }

        this.run_selected = () => {
            return this.actions.set_and_run_multiple(this.state.selected_cells)
        }
        this.fold_selected = (new_val) => {
            if (_.isEmpty(this.state.selected_cells)) return
            return this.actions.fold_remote_cells(this.state.selected_cells, new_val)
        }
        this.move_selected = (/** @type {KeyboardEvent} */ e, /** @type {1|-1} */ delta) => {
            if (this.state.selected_cells.length > 0) {
                const current_indices = this.state.selected_cells.map((id) => this.state.notebook.cell_order.indexOf(id))
                const new_index = (delta > 0 ? Math.max : Math.min)(...current_indices) + (delta === -1 ? -1 : 2)

                e.preventDefault()
                return this.actions.move_remote_cells(this.state.selected_cells, new_index).then(
                    // scroll into view
                    () => {
                        document.getElementById((delta > 0 ? _.last : _.first)(this.state.selected_cells) ?? "")?.scrollIntoView({ block: "nearest" })
                    }
                )
            }
        }

        this.serialize_selected = (/** @type {string?} */ cell_id = null) => {
            const cells_to_serialize = cell_id == null || this.state.selected_cells.includes(cell_id) ? this.state.selected_cells : [cell_id]
            if (cells_to_serialize.length) {
                return serialize_cells(cells_to_serialize.map((id) => this.state.notebook.cell_inputs[id]).filter((c) => c != null))
            }
        }

        this.patch_listeners = []
        this.on_patches_hook = (patches) => {
            this.patch_listeners.forEach((f) => f(patches))
        }

        let ctrl_down_last_val = { current: false }
        const set_ctrl_down = (value) => {
            if (value !== ctrl_down_last_val.current) {
                ctrl_down_last_val.current = value
                document.body.querySelectorAll("[data-pluto-variable], [data-cell-variable]").forEach((el) => {
                    el.setAttribute("data-ctrl-down", value ? "true" : "false")
                })
            }
        }

        document.addEventListener("keyup", (e) => {
            set_ctrl_down(has_ctrl_or_cmd_pressed(e))
        })
        document.addEventListener("visibilitychange", (e) => {
            set_ctrl_down(false)
            setTimeout(() => {
                set_ctrl_down(false)
            }, 100)
        })

        document.addEventListener("keydown", (e) => {
            set_ctrl_down(has_ctrl_or_cmd_pressed(e))
            // if (e.defaultPrevented) {
            //     return
            // }
            if (e.key?.toLowerCase() === "q" && has_ctrl_or_cmd_pressed(e)) {
                // This one can't be done as cmd+q on mac, because that closes chrome - Dral
                if (Object.values(this.state.notebook.cell_results).some((c) => c.running || c.queued)) {
                    this.actions.interrupt_remote()
                }
                e.preventDefault()
            } else if (e.key?.toLowerCase() === "s" && has_ctrl_or_cmd_pressed(e)) {
                const some_cells_ran = this.actions.set_and_run_all_changed_remote_cells()
                if (!some_cells_ran) {
                    // all cells were in sync allready
                    // TODO: let user know that the notebook autosaves
                }
                e.preventDefault()
            } else if (["BracketLeft", "BracketRight"].includes(e.code) && (is_mac_keyboard ? e.altKey && e.metaKey : e.ctrlKey && e.shiftKey)) {
                this.fold_selected(e.code === "BracketLeft")
            } else if (e.key === "Backspace" || e.key === "Delete") {
                if (this.delete_selected()) {
                    e.preventDefault()
                }
            } else if (e.key === "Enter" && e.shiftKey) {
                this.run_selected()
                e.preventDefault()
            } else if (e.key === "ArrowUp" && e.altKey) {
                this.move_selected(e, -1)
            } else if (e.key === "ArrowDown" && e.altKey) {
                this.move_selected(e, 1)
            } else if (e.key === "F1") {
                open_bottom_right_panel("docs")
                e.preventDefault()
            } else if (e.key === "Escape" && !e.defaultPrevented) {
                this.setState({
                    selected_cells: [],
                })
            }
        })

        document.addEventListener("copy", (e) => {
            if (!in_textarea_or_input()) {
                const serialized = this.serialize_selected()
                if (serialized) {
                    e.preventDefault()
                    // wait one frame to get transient user activation
                    requestAnimationFrame(() =>
                        navigator.clipboard.writeText(serialized).catch((err) => {
                            console.error("Error copying cells", e, err, navigator.userActivation)
                            tell({ body: t("t_copy_cells_failed") })
                        })
                    )
                }
            }
        })

        document.addEventListener("cut", (e) => {
            // Disabled because we don't want to accidentally delete cells
            // or we can enable it with a prompt
            // Even better would be excel style: grey out until you paste it. If you paste within the same notebook, then it is just a move.
            // if (!in_textarea_or_input()) {
            //     const serialized = this.serialize_selected()
            //     if (serialized) {
            //         navigator.clipboard
            //             .writeText(serialized)
            //             .then(() => this.delete_selected("Cut"))
            //             .catch((err) => {
            //                 alert(`Error cutting cells: ${e}`)
            //             })
            //     }
            // }
        })

        document.addEventListener("paste", async (e) => {
            const topaste = e.clipboardData?.getData("text/plain")
            if (topaste) {
                const deserializer = detect_deserializer(topaste)
                if (deserializer != null) {
                    const drop_index = get_drop_index_for_paste(this.props.pluto_editor_element)
                    this.actions.add_deserialized_cells(topaste, drop_index, deserializer)
                    e.preventDefault()
                }
            }
        })

        window.addEventListener("beforeunload", (event) => {
            const unsaved_cells = this.state.notebook.cell_order.filter(
                (id) => this.state.cell_inputs_local[id] && this.state.notebook.cell_inputs[id]?.code !== this.state.cell_inputs_local[id].code
            )
            const first_unsaved = unsaved_cells[0]
            if (first_unsaved != null) {
                window.dispatchEvent(new CustomEvent("cell_focus", { detail: { cell_id: first_unsaved } }))
                // } else if (this.state.notebook.in_temp_dir) {
                //     window.scrollTo(0, 0)
                //     // TODO: focus file picker
                console.log("Preventing unload")
                event.stopImmediatePropagation()
                event.preventDefault()
                event.returnValue = ""
            } else {
                console.warn("unloading 👉 disconnecting websocket")
            }
        })
    }

    updateLang() {
        document.documentElement.lang = getCurrentLanguage()
        document.documentElement.dir = getWritingDirection()
    }

    componentDidMount() {
        const lp = this.props.launch_params
        if (this.state.static_preview) {
            this.setState({
                initializing: false,
            })

            this.updateLang()
        } else {
            this.connect()
        }

        // The Variables tab's name links (VariablesTab.js): scroll to and
        // select the cell that defines a variable.
        window.addEventListener("ember_select_cell", (/** @type {CustomEvent} */ e) => {
            this.setState({ selected_cells: [e.detail] })
        })
    }

    componentDidUpdate(/** @type {EditorProps} */ old_props, /** @type {EditorState} */ old_state) {
        //@ts-ignore
        window.editor_state = this.state
        //@ts-ignore
        window.editor_state_set = this.setStatePromise

        const new_state = this.state

        if (old_state?.notebook?.shortpath !== new_state.notebook.shortpath) {
            if (!is_editor_embedded_inside_editor(old_props.pluto_editor_element)) document.title = `${new_state.notebook.shortpath} — Ember`
        }

        this.maybe_send_queued_bond_changes()

        if (old_state.disable_ui !== this.state.disable_ui || old_state.connected !== this.state.connected) {
            this.on_disable_ui()
        }
        if (!this.state.initializing) {
            setup_mathjax()
        }
    }

    componentWillUpdate(new_props, new_state) {
        this.cached_status = statusmap(new_state, this.props.launch_params)

        Object.entries(this.cached_status).forEach(([k, v]) => {
            new_props.pluto_editor_element.classList.toggle(k, v === true)
        })
    }

    render() {
        const { launch_params } = this.props
        let { notebook } = this.state

        const status = this.cached_status ?? statusmap(this.state, launch_params)

        if (status.isolated_cell_view) {
            return html`
                <${PlutoActionsContext.Provider} value=${this.actions}>
                    <${PlutoBondsContext.Provider} value=${this.state.notebook.bonds}>
                        <${PlutoJSInitializingContext.Provider} value=${this.js_init_set}>
                            <${ProgressBar} notebook=${this.state.notebook} />
                            <div style="width: 100%">
                                ${this.state.notebook.cell_order.map(
                                    (cell_id, i) => html`
                                        <${IsolatedCell}
                                            cell_input=${notebook.cell_inputs[cell_id]}
                                            cell_result=${this.state.notebook.cell_results[cell_id]}
                                            hidden=${!launch_params.isolated_cell_ids?.includes(cell_id)}
                                            sanitize_html=${status.sanitize_html}
                                        />
                                    `
                                )}
                            </div>
                        </${PlutoJSInitializingContext.Provider}>
                    </${PlutoBondsContext.Provider}>
                </${PlutoActionsContext.Provider}>
            `
        }
        const restart = async () => {
            await this.client.send(
                "restart_process",
                {},
                {
                    notebook_id: notebook.notebook_id,
                }
            )
        }

        return html`
            ${this.state.disable_ui === false && html`<${HijackExternalLinksToOpenInNewTab} />`}
            <${PlutoActionsContext.Provider} value=${this.actions}>
                <${PlutoBondsContext.Provider} value=${this.state.notebook.bonds}>
                    <${PlutoJSInitializingContext.Provider} value=${this.js_init_set}>
                    <a
                        class="skip-link"
                        href="#"
                        onClick=${(e) => {
                            e.preventDefault()
                            const first = document.querySelector("pluto-notebook > pluto-cell")
                            const targets = [first?.querySelector("pluto-input .cm-editor:not(.cm-ssr-fake) .cm-content"), first?.querySelector(":scope > pluto-output[tabindex]"), first]
                            const target = /** @type {HTMLElement?} */ (targets.find((el) => el != null && el.getClientRects().length > 0) ?? null)
                            target?.focus()
                        }}
                        >${t("t_skip_to_notebook")}</a
                    >
                    <${Scroller} active=${this.state.scroller} />
                    <${ProgressBar} notebook=${this.state.notebook} />
                    <header id="pluto-nav">
                        <${Header}
                            notebook=${notebook}
                            connected=${this.state.connected}
                            code_differs=${status.code_differs}
                            export_links=${{
                                file_url: this.export_url("notebookfile"),
                                html_url: this.export_url("notebookexport", { offline_bundle: "true" }),
                                file_name: (notebook.path ?? "").split(/[\\/]/).pop() || notebook.shortpath,
                                safe_preview: status.process_waiting_for_permission,
                            }}
                            print_title=${
                                new URLSearchParams(window.location.search).get("name") ??
                                this.state.notebook.shortpath
                            }
                            on_open_move=${() => this.setState({ move_dialog_open: true })}
                            on_run_all=${() => this.actions.ember_run_all()}
                            on_interrupt=${() => this.actions.interrupt_remote()}
                        />
                    </header>
                    ${this.state.move_dialog_open &&
                    html`<${MoveDialog} path=${notebook.path} shortpath=${notebook.shortpath} on_close=${() => this.setState({ move_dialog_open: false })} />`}
                    <${SafePreviewUI}
                        process_waiting_for_permission=${status.process_waiting_for_permission}
                        restart=${restart}
                        plan=${notebook.ember?.plan}
                    />
                    <${ConfirmBeforeLongRuntime} />
                    <${RunTracker} notebook=${notebook} />
                    <${Settings} />
                    <${ShortcutsSheet} />
                    ${this.props.preamble_element}
                    <${Main}>
                        <${Preamble}
                            last_update_time=${this.state.last_update_time}
                            any_code_differs=${status.code_differs}
                            last_hot_reload_time=${notebook.last_hot_reload_time}
                            connected=${this.state.connected}
                        />
                        <${Notebook}
                            notebook=${notebook}
                            cell_inputs_local=${this.state.cell_inputs_local}
                            disable_input=${this.state.disable_ui || !this.state.connected}
                            last_created_cell=${this.state.last_created_cell}
                            selected_cells=${this.state.selected_cells}
                            is_initializing=${this.state.initializing}
                            inspecting_hidden_code=${status.inspecting_hidden_code}
                            is_process_ready=${this.is_process_ready()}
                            process_waiting_for_permission=${status.process_waiting_for_permission}
                            sanitize_html=${status.sanitize_html}
                        />
                        <${DropRuler} 
                            actions=${this.actions}
                            selected_cells=${this.state.selected_cells}
                            set_scroller=${(enabled) => this.setState({ scroller: enabled })}
                            serialize_selected=${this.serialize_selected}
                            pluto_editor_element=${this.props.pluto_editor_element}
                        />
                        <${NonCellOutput} 
                            notebook_id=${this.state.notebook.notebook_id} 
                            environment_component=${this.state.extended_components.NonCellOutputComponents} />
                    </${Main}>
                    ${
                        this.state.disable_ui ||
                        html`<${SelectionArea}
                            cell_order=${this.state.notebook.cell_order}
                            set_scroller=${(enabled) => {
                                this.setState({ scroller: enabled })
                            }}
                            on_selection=${(selected_cell_ids) => {
                                // @ts-ignore
                                if (
                                    selected_cell_ids.length !== this.state.selected_cells.length ||
                                    _.difference(selected_cell_ids, this.state.selected_cells).length !== 0
                                ) {
                                    this.setState({
                                        selected_cells: selected_cell_ids,
                                    })
                                }
                            }}
                        />`
                    }
                    <${BottomRightPanel}
                        desired_doc_query=${this.state.desired_doc_query}
                        on_update_doc_query=${this.actions.set_doc_query}
                        connected=${this.state.connected}
                        notebook=${this.state.notebook}
                        sanitize_html=${status.sanitize_html}
                        on_restart=${restart}
                    />
                    <${UndoDelete}
                        recently_deleted=${this.state.recently_deleted}
                        on_click=${() => {
                            const rd = this.state.recently_deleted
                            if (rd == null) return
                            this.update_notebook((notebook) => {
                                for (let { index, cell } of rd) {
                                    notebook.cell_inputs[cell.cell_id] = cell
                                    notebook.cell_order = [...notebook.cell_order.slice(0, index), cell.cell_id, ...notebook.cell_order.slice(index, Infinity)]
                                }
                            }).then(() => {
                                this.actions.set_and_run_multiple(rd.map(({ cell }) => cell.cell_id))
                            })
                        }}
                    />
                    <${Popup} />
                </${PlutoJSInitializingContext.Provider}>
                </${PlutoBondsContext.Provider}>
            </${PlutoActionsContext.Provider}>
        `
    }
}
