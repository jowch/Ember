# @ember/lezer-r

A [Lezer](https://lezer.codemirror.net/) grammar for R, for CodeMirror 6
syntax highlighting, folding and bracket matching in Ember's Pluto-based
frontend. Written from scratch (not a fork of the unmaintained `lezer-r`
npm package, which fails on `;`, `->`, `|>`, `\(x)` lambdas, formulas,
`if/else` across lines, unary minus, `:`, and `x[1, ]`).

## What it covers

- All R operators with R's real precedence and associativity (`?Syntax`):
  `::`/`:::`, `$`/`@`, calls and `[`/`[[` indexing, `^` (right-assoc),
  unary `-`/`+`, `:`, `%any%` operators and `|>` (same tier), `*`/`/`,
  `+`/`-`, comparisons, `!`, `&`/`&&`, `|`/`||`, `~` (unary and binary),
  `->`/`->>`, `<-`/`<<-` (right-assoc), `=`, `:=` (data.table/rlang
  walrus assignment), and `?`.
- `function`, `\(x)` lambdas, `if`/`else`, `for`, `while`, `repeat`,
  `break`, `next`, `{}` blocks, `;` separators.
- Calls and subscripts with empty arguments (`x[1, ]`, `x[, 2]`,
  `f(,)`), named arguments including string and backtick names, `...`
  and `..1`-style dots, the pipe placeholder `_`.
- Backtick identifiers, Unicode identifiers, all R numeric literal forms
  (`1L`, `1e-3`, `0x1F`, `1i`, `.5`, `1.`), `TRUE`/`FALSE`/`NULL`/`NA`
  (and its typed variants)/`Inf`/`NaN`, double- and single-quoted strings
  (including ones spanning multiple lines, which real R allows), raw
  strings (`r"(...)"`, `R"[...]"`, `r"---{...}---"`, any delimiter and
  dash count), and comments.
- R's newline-sensitive statement separation: a newline ends a statement
  at bracket depth 0 (top level or directly inside `{}`), but not inside
  `(...)` or `[...]`/`[[...]]`, and not when it would otherwise ambiguously
  continue as a binary operator, call, or subscript (`f(1)\n-2` and
  `f(1)\n(x)` are two statements, matching real R, not `f(1) - 2` or a
  chained call).

See `src/r.grammar` for the grammar and `src/tokens.js` for the external
tokenizers (statement-separator insertion, raw strings, and the
newline-vs-continuation disambiguation for calls/subscripts/`+`/`-`).

## Build

```
npm install
npm run build   # lezer-generator src/r.grammar -o src/parser.js, then rollup -c
```

Produces `dist/index.js` / `dist/index.cjs`, exporting `rParser` (an
`@lezer/lr` `LRParser` with highlighting tags already attached via
`src/highlight.js`). This package has no CodeMirror dependency; wire it
into CM6 with `LRLanguage.define({ parser: rParser, ... })` from
`@codemirror/language` on the consumer side.

## Test

```
npm test     # unit tests: test/cases.txt via @lezer/generator's file-test format
npm run corpus  # corpus test against real R, see below
```

### Corpus test

`npm run corpus` runs `test/r_boundaries.R` (needs `Rscript` on `PATH`,
or at `~/.local/share/rig/r/4.6.1/bin/Rscript` / `~/.local/bin/Rscript`)
against the 399-file corpus in `spikes/corpus/files/`, extracting R's own
top-level expression boundaries via `getParseData()`, converting R's
(line, column) positions to character offsets (carefully: columns are
character-counted but tabs expand to the next multiple of 8, like a
terminal). `test/corpus.mjs` then parses every file with the Lezer
grammar and checks:

1. Zero error nodes on files R can parse.
2. The grammar's top-level `TopExpr` boundaries exactly match R's.

Latest run: **0 error nodes** and **100.000% boundary match** (9207/9207)
across the corpus, in ~160ms total parse time for all 399 files. One
file fails to parse in R and is skipped from the boundary comparison
(see Known gaps).

Per-file failures are written to `test/corpus-failures.txt`.

## Known gaps

- `tt_data_2026_2026_01_27_cleaning.R` in the corpus is mislabeled: it is
  genuinely Python source (`import pandas as pd`, `def ...`), not R. It
  fails to parse in R itself too, so it's excluded from the boundary
  comparison; the grammar's 36 error nodes on it are expected and not a
  bug.
- Assignment-target validity isn't checked: `1 <- x` parses structurally
  (as a lenient editor grammar, not a validator) even though real R
  rejects non-assignable left-hand sides.
- `=`-assignment is only allowed in statement position, inside `{}`, or
  inside explicit parentheses (`(x = 1)`), not as an arbitrary nested
  sub-expression (e.g. `1 + (x = 2)` needs the parens). This mirrors R's
  actual grammar, which has a separate `expr`/`expr_or_assign` split for
  exactly this reason, and it avoids a real ambiguity: without it,
  `f(x = 1)` could parse `x = 1` as a positional argument that happens to
  be an assignment, instead of unambiguously as the named argument `x`.
- Comparison operators (`==`, `<`, etc.) are parsed as left-associative
  for simplicity; R's grammar documents them as non-associative. Chains
  like `a < b < c` parse without error (as `(a < b) < c`) rather than
  being rejected, which is the intended leniency for an editor grammar.
- `::`/`:::`/`$`/`@` only accept an identifier, backtick name, or string
  on the right-hand side (matching R's actual grammar), not an arbitrary
  expression.
- Two known-safe ambiguities are resolved by the generator's default
  shift preference rather than an explicit rule: dangling `if`/`else`
  binds to the nearest `if`, and `else` is always consumed if the next
  token (even across a newline, even at top level) is `else` -- so
  `if (a) x\nelse y` parses even outside `{}`, which is more lenient
  than real R (which errors there at the top level). This was an
  explicit design choice (see task notes): be lenient rather than error.
