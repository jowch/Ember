/**
 * A defined or read name as the page shows it. R keeps class `Circle` in
 * the global binding `.__C__Circle`, which the engine uses as the name of
 * the class (graph.R, "Classes"); the page says "class Circle", as the
 * engine's own messages do (pluto-state.R's `display_names()`).
 *
 * @param {string} name
 * @returns {string}
 */
export const display_name = (name) => (name.startsWith(".__C__") ? `class ${name.slice(".__C__".length)}` : name)
