import { th } from "../../common/lang.js"
import { open_pluto_popup } from "../../common/open_pluto_popup.js"
import { ViewPlugin, StateEffect, StateField, EditorView } from "../../imports/CodemirrorPlutoSetup.js"
import _ from "../../imports/lodash-es.js"
import { html } from "../../imports/Preact.js"
import { get_settings } from "../Settings.js"

/** @type {any} */
const TabHelpEffect = StateEffect.define()
const TabHelp = StateField.define({
    create() {
        return false
    },
    update(value, tr) {
        for (let effect of tr.effects) {
            if (effect.is(TabHelpEffect)) return effect.value
        }
        return value
    },
})

/** @type {any} */
export const LastFocusWasForcedEffect = StateEffect.define()
const LastFocusWasForced = StateField.define({
    create() {
        return false
    },
    update(value, tr) {
        for (let effect of tr.effects) {
            if (effect.is(LastFocusWasForcedEffect)) return effect.value
        }
        return value
    },
})

export const tab_help_plugin = ViewPlugin.define(
    (view) => ({
        setready: (x) =>
            requestIdleCallback(() => {
                view.dispatch({
                    effects: [TabHelpEffect.of(x)],
                })
            }),
    }),
    {
        provide: (p) => [TabHelp, LastFocusWasForced],
        eventObservers: {
            focus: function (event, view) {
                // The next key should trigger the popup
                this.setready(true)
            },
            blur: function (event, view) {
                this.setready(false)
                requestIdleCallback(() => {
                    view.dispatch({
                        effects: [LastFocusWasForcedEffect.of(false)],
                    })
                })
            },
            click: function (event, view) {
                // This means you are not doing keyboard navigation :)
                this.setready(false)
            },
            keydown: function (event, view) {
                if (event.key == "Tab" && get_settings().CM_TAB_KEY_FOR_INDENT) {
                    if (view.state.field(TabHelp) && !view.state.field(LastFocusWasForced) && !view.state.readOnly && !passing_through.get(view)) {
                        open_pluto_popup({
                            type: "info",
                            source_element: view.dom,
                            body: th("t_help_about_tab_navigation_inside_cell"),
                        })
                        this.setready(false)
                    }
                } else {
                    this.setready(false)
                }
            },
        },
    }
)

/** Editors that keyboard focus arrived in (Tab or Shift+Tab) and that the
 * person hasn't worked in since: no typing, clicking or cursor keys. */
const passing_through = new WeakMap()
const pointer_down = new WeakSet()

const pass_through = (view, on) => {
    passing_through.set(view, on)
    // CodeMirror's tab focus mode: while it's on, no keymap handles Tab or
    // Shift+Tab, so the browser moves focus.
    if (get_settings().CM_TAB_KEY_FOR_INDENT) view.setTabFocusMode(on)
}

/** Tab passes through a cell's editor until the person starts working in
 * it (#297). With Tab set to indent, tabbing through the page used to land
 * in the first cell and indent its code on every further press. Now Tab and
 * Shift+Tab move on from an editor that focus only passed into, the way
 * JupyterLab's cells do; once the person types, clicks or moves the cursor
 * there, Tab indents as before. Focus Ember moves into an editor itself (a
 * new cell, go to definition), and Enter on a selected cell, count as
 * working in it. */
export const tab_pass_through = EditorView.domEventHandlers({
    mousedown(event, view) {
        pointer_down.add(view)
        if (passing_through.get(view)) pass_through(view, false)
        return false
    },
    focus(event, view) {
        const by_pointer = pointer_down.has(view)
        pointer_down.delete(view)
        // Enter on a selected cell (focus on the pluto-cell itself) asks
        // to edit it, like JupyterLab's Enter.
        const from_own_cell = event.relatedTarget != null && event.relatedTarget === view.dom.closest("pluto-cell")
        const on = !by_pointer && !from_own_cell && !view.state.field(LastFocusWasForced, false)
        if (on || passing_through.get(view)) pass_through(view, on)
        return false
    },
    blur(event, view) {
        pointer_down.delete(view)
        if (passing_through.get(view)) pass_through(view, false)
        return false
    },
    keydown(event, view) {
        // Tab moves on, and Shift on its own is the start of Shift+Tab;
        // any other key is work in this editor.
        if (!["Tab", "Shift"].includes(event.key) && passing_through.get(view)) pass_through(view, false)
        return false
    },
})
