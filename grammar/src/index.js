// The R Lezer parser, with highlighting tags attached. Consumers wire
// this into CodeMirror with `LRLanguage.define({ parser: rParser, ... })`
// (from @codemirror/language) themselves, so this package does not
// depend on CodeMirror at all.
export { parser as rParser } from "./parser.js"
