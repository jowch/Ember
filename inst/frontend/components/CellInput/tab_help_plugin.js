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

const pass_through = (view, on) => {
    passing_through.set(view, on)
    // CodeMirror's tab focus mode: while it's on, no keymap handles Tab or
    // Shift+Tab, so the browser moves focus.
    if (get_settings().CM_TAB_KEY_FOR_INDENT) view.setTabFocusMode(on)
}

// Whether a Tab or Shift+Tab keydown is being handled right now. The
// browser moves focus as that keydown's default action, in the same task,
// so a focus while it's set was moved by Tab.
let tab_pressed = false
if (typeof document !== "undefined") {
    document.addEventListener(
        "keydown",
        (event) => {
            if (event.key !== "Tab" || event.ctrlKey || event.metaKey || event.altKey) return
            tab_pressed = true
            setTimeout(() => {
                tab_pressed = false
            })
        },
        { capture: true }
    )
}

// Keys that start a shortcut rather than do anything on their own.
const MODIFIERS = ["Shift", "Control", "Alt", "Meta", "AltGraph", "CapsLock"]

/** Tab passes through a cell's editor until the person starts working in
 * it (#297). With Tab set to indent, tabbing through the page used to land
 * in the first cell and indent its code on every further press. Now, when
 * Tab or Shift+Tab moves focus into an editor, the next Tab moves on, the
 * way JupyterLab's cells do; once the person types, clicks or moves the
 * cursor there, Tab indents as before. Focus that arrives any other way (a
 * click, Enter on a selected cell, arrow keys from the next cell, a new
 * cell, coming back to the window) is working there. */
export const tab_pass_through = EditorView.domEventHandlers({
    mousedown(event, view) {
        if (passing_through.get(view)) pass_through(view, false)
        return false
    },
    focus(event, view) {
        const on = tab_pressed
        if (on || passing_through.get(view)) pass_through(view, on)
        return false
    },
    blur(event, view) {
        if (passing_through.get(view)) pass_through(view, false)
        return false
    },
    keydown(event, view) {
        // Tab moves on, and a modifier on its own is the start of Shift+Tab
        // or a shortcut; any other key is work in this editor.
        if (event.key !== "Tab" && !MODIFIERS.includes(event.key) && passing_through.get(view)) pass_through(view, false)
        return false
    },
})
