// Ember's theme: the `THEME` setting ("system" | "light" | "dark") resolved
// onto `<html data-theme>`. editor.html's inline <head> script does the
// same resolution once, synchronously, before the stylesheet loads, so the
// first paint is already right; this module takes over afterwards.
import { DEFAULT_SETTINGS, get_settings } from "../components/Settings.js"

const prefers_dark = () => window.matchMedia("(prefers-color-scheme: dark)")

/** The resolved theme ("light" or "dark") for a `THEME` setting value,
 * following the system when it is "system". */
const resolve_theme = (/** @type {string} */ theme) => (theme === "system" ? (prefers_dark().matches ? "dark" : "light") : theme)

const current_setting = () => get_settings().THEME ?? DEFAULT_SETTINGS.THEME

const set_theme = () => {
    const theme = resolve_theme(current_setting())
    document.documentElement.setAttribute("data-theme", theme)
    document.getElementById("ember-theme-color")?.setAttribute("content", theme === "dark" ? "#1b201d" : "#fcfcfb")
    window.dispatchEvent(new CustomEvent("ember theme change", { detail: { theme } }))
}

let following = false

/** Set `<html data-theme>` from the current `THEME` setting. From the first
 * call on, the page also follows a change of the setting (Settings) and,
 * while it is "system", of `prefers-color-scheme`. Fires a window
 * `"ember theme change"` event on every switch, including this first one,
 * so anything that can't just read the attribute later (a CodeMirror
 * compartment, a `matchMedia` snapshot taken once) can react. */
export function apply_theme() {
    set_theme()
    if (following) return
    following = true
    prefers_dark().addEventListener("change", () => {
        if (current_setting() === "system") set_theme()
    })
    window.addEventListener("ember settings changed", (/** @type {CustomEvent} */ e) => {
        if (e.detail?.key === "THEME") set_theme()
    })
}

/** Whether the page is currently showing the dark theme, read straight
 * from `<html data-theme>` (not `matchMedia`, which misses a `THEME`
 * setting other than "system"). */
export const is_dark_theme = () => document.documentElement.getAttribute("data-theme") === "dark"
