// Core plus the two languages Ember needs (not julia): hljs.highlightElement()
// auto-detects from the code element's `language-*` class.
import hljs from "highlight.js/lib/core"
import r from "highlight.js/lib/languages/r"
import markdown from "highlight.js/lib/languages/markdown"

hljs.registerLanguage("r", r)
hljs.registerLanguage("markdown", markdown)

export default hljs
