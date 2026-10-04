/** @typedef {"\t" | "  " | "    "} IndentUnit */

/**
 * The indent unit for the `CM_INDENT_UNIT` setting ("2", "4" or "tab").
 *
 * @param {string} setting
 * @returns {IndentUnit}
 */
export const indent_unit_of_setting = (setting) => (setting === "tab" ? "\t" : setting === "4" ? "    " : "  ")

/**
 * Detect how a CodeMirror document is indented: `"\t"` when tab-indented
 * lines win, else the smallest indent of the space-indented lines (2 or 4
 * spaces), else `fallback`.
 *
 * @param {import("../../imports/CodemirrorPlutoSetup.js").Text} doc
 * @param {IndentUnit} fallback Returned when no indented lines are found.
 * @returns {IndentUnit}
 */
export const detect_indent_unit = (doc, fallback) => {
    let tab_lines = 0
    let space_lines = 0
    let smallest = Infinity
    const max_lines = Math.min(doc.lines, 20)
    for (let i = 1; i <= max_lines; i++) {
        const text = doc.line(i).text
        if (text[0] === "\t") tab_lines++
        else if (text[0] === " " && text[1] === " " && text.trim() !== "") {
            space_lines++
            smallest = Math.min(smallest, text.length - text.trimStart().length)
        }
    }
    if (tab_lines === 0 && space_lines === 0) return fallback
    if (tab_lines >= space_lines) return "\t"
    return smallest % 4 === 0 ? "    " : smallest % 2 === 0 ? "  " : fallback
}
