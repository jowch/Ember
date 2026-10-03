// Ember's theme: the `THEME` setting ("system" | "light" | "dark") resolved
// onto `<html data-theme>`. editor.html's inline <head> script does the
// same resolution once, synchronously, before the stylesheet loads, so the
// first paint is already right; this module takes over afterwards (piece
// 7's Settings row is the only other reader of `THEME`, via get_settings()).
import { DEFAULT_SETTINGS, get_settings } from "../components/Settings.js"

const prefers_dark = () => window.matchMedia("(prefers-color-scheme: dark)")

/** The resolved theme ("light" or "dark") for a `THEME` setting value,
 * following the system when it is "system". */
const resolve_theme = (/** @type {string} */ theme) => (theme === "system" ? (prefers_dark().matches ? "dark" : "light") : theme)

/** Set `<html data-theme>` from the current `THEME` setting, and (only
 * while that setting is "system") keep following `prefers-color-scheme`.
 * Fires a window `"ember theme change"` event on every switch, including
 * this first one, so anything that can't just read the attribute later
 * (a CodeMirror compartment, a `matchMedia` snapshot taken once) can react.
 * Call once, after the page's modules are loaded; safe to call again. */
export function apply_theme() {
    const set = () => {
        const theme = resolve_theme(get_settings().THEME ?? DEFAULT_SETTINGS.THEME)
        document.documentElement.setAttribute("data-theme", theme)
        window.dispatchEvent(new CustomEvent("ember theme change", { detail: { theme } }))
    }
    set()

    const mq = prefers_dark()
    const on_system_change = () => {
        if ((get_settings().THEME ?? DEFAULT_SETTINGS.THEME) === "system") set()
    }
    mq.addEventListener("change", on_system_change)
    return () => mq.removeEventListener("change", on_system_change)
}

/** Whether the page is currently showing the dark theme, read straight
 * from `<html data-theme>` (not `matchMedia`, which misses a `THEME`
 * setting other than "system"). */
export const is_dark_theme = () => document.documentElement.getAttribute("data-theme") === "dark"
