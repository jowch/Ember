import { ExternalTokenizer, ContextTracker } from "@lezer/lr"
import {
  InsertedSemi, newline, spaces, Comment, RawStringTail,
  ParenL, ParenR, BracketR, BraceL, BraceR,
  ContinueParenL, ContinueBracketL, ContinueDBracketL, ContinueAddOp
} from "./parser.terms.js"

// Track, at every point in the token stream, (a) whether a brace/top-level
// level is the innermost enclosing level (as opposed to being inside a
// round or square bracket), and (b) whether a real newline has been seen
// since the last non-trivial token. R treats a newline as ending an
// expression only when (a) holds; inside ( ... ) or [ ... ] / [[ ... ]]
// a newline is just whitespace, so an expression can always continue
// across lines there.
class Ctx {
  constructor(parent, bracket, nl) {
    this.parent = parent
    this.bracket = bracket
    this.nl = nl
  }
}

const topContext = new Ctx(null, false, false)

export const trackNewlines = new ContextTracker({
  start: topContext,
  shift(context, term) {
    if (term == spaces || term == Comment) return context
    if (term == newline) return context.nl ? context : new Ctx(context.parent, context.bracket, true)
    if (term == ParenL || term == ContinueParenL || term == ContinueBracketL)
      return new Ctx(context, true, false)
    if (term == ContinueDBracketL) return new Ctx(new Ctx(context, true, false), true, false)
    if (term == BraceL) return new Ctx(context, false, false)
    if (term == ParenR || term == BracketR || term == BraceR) {
      let parent = context.parent || context
      return new Ctx(parent.parent, parent.bracket, false)
    }
    return context.nl ? new Ctx(context.parent, context.bracket, false) : context
  }
})

// Emits a zero-width statement-separator token whenever a newline has
// occurred since the last real token and we are not nested inside ( or
// [ / [[. The parser only actually uses this token in states where a
// separator is grammatically expected (end of a statement), so offering
// it liberally here is safe: it is simply ignored elsewhere (for example
// right after a binary operator, where the grammar has no shift action
// for a separator and the real following token is used instead).
export const insertSemicolonTokenizer = new ExternalTokenizer((input, stack) => {
  let ctx = stack.context
  if (ctx.nl && !ctx.bracket) input.acceptToken(InsertedSemi)
}, { contextual: true, fallback: true })

// A call or subscript ("(", "[", "[[") directly continuing a preceding
// expression -- as opposed to one starting a fresh expression/statement --
// is only valid when no newline has intervened since that expression
// ended (at bracket depth 0: inside ( or [ this can't come up, since a
// newline there is never a statement break to begin with). Real R does
// NOT chain a call/subscript across such a newline: `f(1)\n(x)` is two
// statements, not a call to the result of f(1). So Call/Subscript/
// Subscript2 use these tokens instead of the plain bracket tokens;
// when a newline makes them invalid, this tokenizer declines and the
// plain ParenL/BracketL/DBracketL (used for a fresh parenthesized
// expression or subscript-as-new-statement) is used instead.
export const callContinuationTokenizer = new ExternalTokenizer((input, stack) => {
  let ctx = stack.context
  if (ctx.nl && !ctx.bracket) return
  if (input.next == PL) { input.advance(); input.acceptToken(ContinueParenL) }
  else if (input.next == BL) {
    input.advance()
    if (input.next == BL) { input.advance(); input.acceptToken(ContinueDBracketL) }
    else input.acceptToken(ContinueBracketL)
  }
}, { contextual: true, fallback: true })

// Likewise, "+" and "-" are ambiguous after a newline at bracket depth 0:
// they could continue the previous expression as a binary operator, or
// start a new one as a unary sign. Real R treats a newline there as
// ending the statement (binds as the new statement's unary sign), e.g.
// `f(1)\n-2` is two statements, not `f(1) - 2`. Only the binary/addsub
// use of "+"/"-" goes through this gate; the unary rule keeps using the
// plain tokens, so declining here still lets the next statement start.
export const continueAddOpTokenizer = new ExternalTokenizer((input, stack) => {
  let ctx = stack.context
  if (ctx.nl && !ctx.bracket) return
  if (input.next == PLUS || input.next == DASH) { input.advance(); input.acceptToken(ContinueAddOp) }
}, { contextual: true, fallback: true })

const Q = 34 /* " */, SQ = 39 /* ' */
const PL = 40 /* ( */, PR = 41 /* ) */
const BL = 91 /* [ */, BR = 93 /* ] */
const CL = 123 /* { */, CR = 125 /* } */
const DASH = 45 /* - */
const PLUS = 43 /* + */

function closerFor(open) {
  if (open == PL) return PR
  if (open == BL) return BR
  if (open == CL) return CR
  return -1
}

// Raw strings: r"(...)" R"[...]" r"---{...}---" etc, with zero or more
// dashes between the quote and the delimiter, any of ( [ {, and either
// quote character. The opening delimiter -- ("r"|"R") quote "-"* opener --
// is matched by the regular token grammar (as RawStringOpen), so it wins
// over a plain Identifier by ordinary longest-match; this tokenizer only
// has to pick up right after that, re-deriving the quote/dashes/opener by
// looking backward, and scanning forward for the matching close sequence:
// close-char, the same number of dashes, then the same quote character.
export const rawStringTailTokenizer = new ExternalTokenizer(input => {
  let i = -1
  let opener = input.peek(i)
  let close = closerFor(opener)
  if (close < 0) return
  i--
  let dashes = 0
  while (input.peek(i) == DASH) { dashes++; i-- }
  let quote = input.peek(i)
  if (quote != Q && quote != SQ) return

  let j = 0
  for (;;) {
    let ch = input.peek(j)
    if (ch < 0) {
      // Unterminated: swallow to EOF rather than erroring.
      for (let k = 0; k < j; k++) input.advance()
      input.acceptToken(RawStringTail)
      return
    }
    if (ch == close) {
      let ok = true
      for (let d = 0; d < dashes; d++) if (input.peek(j + 1 + d) != DASH) { ok = false; break }
      if (ok && input.peek(j + 1 + dashes) == quote) {
        let end = j + 1 + dashes + 1
        for (let k = 0; k < end; k++) input.advance()
        input.acceptToken(RawStringTail)
        return
      }
    }
    j++
  }
}, { fallback: true })
