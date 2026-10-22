/**
 * Cell deletes as steps in the editors' own undo history (#349).
 *
 * A delete is recorded in the history of the cell that keeps focus after it
 * (the cell before, for Backspace in an empty cell; otherwise the cell after,
 * or before when the deleted cells were last). It goes in as an effect-only
 * step, so Ctrl+Z in that cell undoes whatever was typed there since, then
 * brings the deleted cells back, then goes on through the cell's earlier
 * typing, in the order it happened. Redo deletes them again.
 *
 * A restored cell gets its editor back as it was, history included, so
 * Ctrl+Z in it carries on through its own edits: Backspacing a cell empty
 * and then deleting it comes back in two Ctrl+Z, first the empty cell, then
 * its text.
 *
 * Text undo stays per cell, as in Jupyter, marimo and Pluto: Ctrl+Z never
 * reaches into a cell you're not in. Outside the editors (a selected cell,
 * the page), Ctrl+Z brings back the last delete, like the Undo button in the
 * bottom bar.
 *
 * The notebook keeps the deleted cells themselves (Editor.js); this module
 * holds the CodeMirror side: the effects, the live editors, and the editor
 * states waiting for their cells to come back.
 */
import { EditorView, StateEffect, invertedEffects, historyKeymap } from "../../imports/CodemirrorPlutoSetup.js"

/** A step that deleted the cells of one delete record (its id). */
export const CellsDeletedEffect = StateEffect.define()
/** Its inverse: undoing the delete brings the record's cells back. */
export const CellsRestoredEffect = StateEffect.define()

// @codemirror/commands' undo and redo, taken from its keymap because the
// bundle doesn't export them by name.
export const undo_command = /** @type {(view: EditorView) => boolean} */ (historyKeymap.find((b) => b.key === "Mod-z")?.run)
export const redo_command = /** @type {(view: EditorView) => boolean} */ (historyKeymap.find((b) => b.key === "Mod-y")?.run)

/** @type {Map<string, EditorView>} cell id → its editor, while it has one */
const live_views = new Map()
export const register_view = (/** @type {string} */ cell_id, /** @type {EditorView} */ view) => live_views.set(cell_id, view)
export const unregister_view = (/** @type {string} */ cell_id, /** @type {EditorView} */ view) => {
    if (live_views.get(cell_id) === view) live_views.delete(cell_id)
}
export const live_view = (/** @type {string} */ cell_id) => live_views.get(cell_id) ?? null

/**
 * Editor states of deleted cells that are on their way back, taken by the
 * cell's CellInput when it makes its editor. `focus` puts the cursor in it.
 * @type {Map<string, { state: import("../../imports/CodemirrorPlutoSetup.js").EditorState?, focus: boolean }>}
 */
const returning = new Map()
export const expect_return = (cell_id, state, focus) => returning.set(cell_id, { state, focus })
export const is_returning = (/** @type {string} */ cell_id) => returning.has(cell_id)
export const take_returning = (/** @type {string} */ cell_id) => {
    const entry = returning.get(cell_id) ?? null
    returning.delete(cell_id)
    return entry
}

/**
 * Set by the Editor. `restore` and `redelete` act on a delete record and
 * return false when it's already in that state (brought back from the bottom
 * bar, say), and the history step is then skipped. `restore_unhosted` brings
 * back the last delete that no editor's history holds, for Ctrl+Z in an
 * editor with nothing left to undo.
 */
let handlers = {
    restore: (/** @type {string} */ _id) => false,
    redelete: (/** @type {string} */ _id, /** @type {EditorView} */ _view) => false,
    restore_unhosted: () => false,
}
export const set_cell_undo_handlers = (h) => {
    handlers = h
}

/** Record a delete as a step in `view`'s history. */
export const record_delete = (/** @type {EditorView} */ view, /** @type {string} */ record_id) =>
    view.dispatch({
        effects: CellsDeletedEffect.of(record_id),
        // Not "delete.*": that would let the step merge with typing.
        userEvent: "cell.delete",
        scrollIntoView: false,
    })

export const cell_undo = [
    invertedEffects.of((tr) => {
        const inverted = []
        for (const e of tr.effects) {
            if (e.is(CellsDeletedEffect)) inverted.push(CellsRestoredEffect.of(e.value))
            else if (e.is(CellsRestoredEffect)) inverted.push(CellsDeletedEffect.of(e.value))
        }
        return inverted
    }),
    EditorView.updateListener.of((update) => {
        for (const tr of update.transactions) {
            const undoing = tr.isUserEvent("undo")
            if (!undoing && !tr.isUserEvent("redo")) continue
            for (const e of tr.effects) {
                let done = null
                if (e.is(CellsRestoredEffect)) done = handlers.restore(e.value)
                else if (e.is(CellsDeletedEffect)) done = handlers.redelete(e.value, update.view)
                // Already undone (or redone) elsewhere: this step would do
                // nothing, so the same key press goes on to the next one.
                if (done === false && tr.changes.empty) {
                    const view = update.view
                    queueMicrotask(() => (undoing ? undo_command : redo_command)(view))
                }
            }
        }
    }),
]

/** Ctrl+Z in an editor with nothing left to undo brings back a delete no editor holds. */
export const undo_or_restore_unhosted = (/** @type {EditorView} */ view) => undo_command(view) || handlers.restore_unhosted()
