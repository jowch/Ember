import { html } from "../imports/Preact.js"
import { t } from "./lang.js"

// @ts-ignore
export let is_mac_keyboard = /Mac/i.test(navigator.userAgentData?.platform ?? navigator.platform)

export let control_name = is_mac_keyboard ? "⌃" : "Ctrl"
export let ctrl_or_cmd_name = is_mac_keyboard ? "⌘" : "Ctrl"
export let alt_or_options_name = is_mac_keyboard ? "⌥" : "Alt"
export let and = is_mac_keyboard ? " " : "+"

export let has_ctrl_or_cmd_pressed = (event) => event.ctrlKey || (is_mac_keyboard && event.metaKey)

export let map_cmd_to_ctrl_on_mac = (keymap) => {
    if (!is_mac_keyboard) {
        return keymap
    }

    let keymap_with_cmd = { ...keymap }
    for (let [key, handler] of Object.entries(keymap)) {
        keymap_with_cmd[key.replace(/Ctrl/g, "Cmd")] = handler
        // remove Ctrl-D from Pluto.jl keybind for MacOS
        if (key == "Ctrl-D") {
            delete keymap_with_cmd[key]
        }
    }
    return keymap_with_cmd
}

export let in_textarea_or_input = () => {
    const in_footer = document.activeElement?.closest("footer") != null
    const in_header = document.activeElement?.closest("header") != null
    const in_cm = document.activeElement?.closest(".cm-editor") != null

    const { tagName } = document.activeElement ?? {}
    return tagName === "INPUT" || tagName === "TEXTAREA" || in_footer || in_header || in_cm
}

/** The keyboard-shortcuts list (today's Ctrl/Cmd+Shift+? / F1 handler,
 * Editor.js, and the header's ⋯ menu item, ui-3-plan.md piece 5's
 * "Header contents"): a Preact body for dialogs.js's `tell()`. */
export const keyboard_shortcuts_body = () => {
    const fold_prefix = is_mac_keyboard ? `⌥${and}⌘` : `Ctrl${and}Shift`
    const or = t("t_key_or")

    return html`<span class="ember-shortcuts-list">
⇧${and}Enter:   ${t("t_key_run")}
${ctrl_or_cmd_name}${and}Enter:   ${t("t_key_run_add")}
${ctrl_or_cmd_name}${and}S:   ${t("t_key_submit_all_changes")}
Delete ${or} Backspace:   ${t("t_key_delete_or_backspace")}

PageUp ${or} fn${and}↑:   ${t("t_key_page_up")}
PageDown ${or} fn${and}↓:   ${t("t_key_page_down")}
${control_name}${and}click:   ${t("t_key_ctrl_click")}
${alt_or_options_name}${and}↑:   ${t("t_key_alt_up")}
${alt_or_options_name}${and}↓:   ${t("t_key_alt_down")}

${control_name}${and}/:   ${t("t_key_ctrl_slash")}
${control_name}${and}M:   ${t("t_key_ctrl_m")}
${fold_prefix}${and}[:   ${t("t_key_ctrl_m")}
${fold_prefix}${and}]:   ${t("t_key_ctrl_m")}
${control_name}${and}Q:   ${t("t_key_ctrl_q")}

${t("t_key_selection_description")}
${ctrl_or_cmd_name}${and}C:   ${t("t_key_ctrl_c")}
${ctrl_or_cmd_name}${and}X:   ${t("t_key_ctrl_x")}
${ctrl_or_cmd_name}${and}V:   ${t("t_key_ctrl_v")}

${t("t_key_autosave_description")}</span
    >`
}
