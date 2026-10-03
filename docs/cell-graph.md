# Cell reading and graph (build step 1)

## Problem

Ember needs to know, without running anything, what each cell defines and
reads, which packages it attaches, and therefore which cells depend on
which, in what order they run, and which cells can't run. The shape is not
obvious for three reasons. First, static reading is incomplete by design:
the worker learns definitions (`load()`, `assign()`, computed `source()`)
and corrects formula columns at run time, and those facts must feed back
into the same graph without a second code path. Second, R's rules cut
across cells: `df$col <- v` in a later cell is a redefinition, a
`library(dplyr)` cell must run before a cell that calls `mutate`, and
global settings are legal in exactly one cell. Third, the consumers differ:
the scheduler wants ancestors in run order and the set of cells whose code
changed; Endeavor's adapter wants a per-cell record (definitions, learned
definitions, references, upstream, downstream, packages) and the snapshot's
structured errors. Constraints from the design: keep dependencies to what
ships with R, keep
"the engine's rules" in one announced place, and prefer an extra edge to a
missing one.

## Usage (caller's view)

Two entry points, both pure. `read_cell()` turns one code string into a
record; `notebook_graph()` turns all cells (plus what the worker learned)
into the graph. Everything else is a query on the graph value.

```r
library(ember)

# The server, on open: cells in display order, footer's learned definitions.
g <- notebook_graph(
  cells   = c(`6f1c` = "library(dplyr)\noptions(digits = 4)",
              `a41e` = "curves <- read.csv('growth.csv')",
              `c93b` = "load('fits.RData')",
              `d7e0` = "fit <- lm(od ~ poly(t, deg), data = curves)"),
  setup   = "6f1c",
  exports = list(dplyr = getNamespaceExports("dplyr")),
  learned = list(definitions = list(c93b = "fits")),
  read_file = function(path) read_text_or_null(file.path(dir, path))
)
g$order            # "6f1c" "a41e" "c93b" "d7e0"
g$errors           # list(); each element has kind, cells, names, lines, message, fixes
```

```r
# The server, after the user edits one cell. Only that cell is re-read.
cells[["d7e0"]] <- new_code
g2 <- notebook_graph(cells, setup, exports, learned = g$learned,
                     previous = g, read_file = reader)
g2$reread                                  # "d7e0"
to_run <- run_order(g2, union("d7e0", downstream(g2, "d7e0", transitive = TRUE)))
```

```r
# The server, when the worker reports after a run: new global names, and
# formula columns that were not in the data frame.
g3 <- graph_learn(g2, "c93b", definitions = c("fits", "fits_meta"))
g3 <- graph_learn(g3, "d7e0", references = "deg")   # adds an edge, shows a note
footer$learned <- g3$learned$definitions             # persisted by the file writer
```

```r
# Endeavor's adapter, answering graph(nid, fresh, edges, packages).
s <- cell_summary(g, "d7e0")
s$definitions   # "fit"
s$learned       # character()
s$references    # "curves" "deg" "lm" "poly"
s$upstream      # "6f1c" "a41e"
s$downstream    # character()
s$packages      # data frame: name, attached
s$errors        # list of ember_graph_error
blocked_cells(g)  # cells with a graph error (they can't run)
```

```r
# Tests, and the UI's per-cell view: one cell in isolation.
a <- read_cell("fit <- lm(y ~ poly(x, deg), data = df)")
a$definitions$name   # "fit"
a$references$name    # "df" "deg" "lm" "poly"
a$formulas[[1]]$columns  # "y" "x"
```

## Shape

**Files.** `R/rules.R` holds the tables the design calls "the engine's
rules": attach functions, setting functions, untrackable reads, formula
operators, ignored names, glue functions. Changing a rule is one edit in one
file, which is what "rare and announced" needs. Reading one cell is
`R/analysis.R` (the result type and `read_cell()`), `R/scope.R`,
`R/walk.R`, `R/walk-formula.R`, `R/walk-calls.R` and `R/positions.R`.
Everything across cells is `R/graph.R` (building) and `R/queries.R`.
Nothing in the graph files inspects language objects and nothing in the
reading files knows about other cells, so the boundary is the
`ember_cell_analysis` value.

**`ember_cell_analysis`** is a list of small data frames (`definitions`,
`references`, `packages`, `settings`, `sourced`, `notes`), a list of
`formula_site`s, the original `code`, and `parse_error`. Data frames
because every consumer wants rows with a line number: the multiple-
definitions error points at lines, the UI highlights references, the
file-watcher wants paths with their text. Definitions carry a `kind` so the
error text can say "move the line into the defining cell" for a
replacement and "use `.i`" for a `for` variable without re-reading code.
Dot-names are recorded like any other name; privacy is a graph policy
(`is_private_name`), so the analysis of a cell never depends on the
notebook it sits in. Formula columns are not references; they are kept in
`formula_site` with the call head and the deparsed `data` argument, which
is exactly what the worker needs to check them after the run.

**Reference rule, stated once.** A read is a reference when no enclosing
scope has bound the name yet, in textual order. At the top level that is
immediate. Inside a function body, a name becomes local at its first
assignment, so `function() { data <- na.omit(data) }` reads the global
`data`; such reads are kept only if the cell doesn't define the name at the
top level, because the function runs after the whole cell. Textual order
applies across branches and loops too, which errs towards extra edges. A
cell that reads its own name before defining it (`s <- s + 1`) gets no self
edge: the worker removes the cell's variables before a rerun, so the read
fails at run time as under `Rscript`. codetools' `findGlobals()` treats `s`
there as local, which is why the walker tracks order itself. Scopes are
environments chained to their parent, so a nested function sees exactly the
enclosing locals bound so far.

Rows from a sourced file are appended after the cell's own rows, so source
order holds within the cell and within each file, not across them.

**`ember_graph`** is a value built whole by `notebook_graph()` from
`(cells, setup, exports, learned, read_file)`. `previous` only saves work:
an analysis is reused when the code is identical and its sourced files
read the same. The graph carries the analyses (its own cache) and
`learned`, so the server keeps one object and hands it back. There is no
mutable graph: the scheduler and the adapter read a snapshot, and a rebuild
is idempotent (per make-operations-idempotent). The single source of truth
across cells is `edges` (from, to, name, via); `upstream`, `downstream`,
`order`, and the cycle error are derived from it at build time (per
single-source-of-truth: derive, don't sync).

**Edge resolution** applies R's search order: a global definition wins over
a package export (a cell defining `filter` shadows dplyr's), and package
edges exist only when `exports` names the package, so the graph is rebuilt
with fuller exports once packages install. Every non-setup cell gets a
setup edge, which is what makes "changing the setup cell reruns
everything" and "the setup cell can't read other cells' names" both fall
out of ordinary cycle detection instead of special cases.

**Disabled cells** (piece 1b) are given to `notebook_graph()` as
`disabled`, a set of ids. A disabled cell is read and resolved exactly
like any other -- it keeps edges to what it reads, and `wanted_packages()`
still sees what it would attach -- but it defines nothing for anyone else:
`resolve_edges()` only falls back to a disabled definer or attacher
(`via = "disabled"`) when no enabled cell provides the name, and
`find_errors()` leaves disabled cells out of every rule but `parse`. `off`
is the disabled cells plus everything downstream of them through any edge
(Pluto's `depends_on_disabled_cells`): a cell is off exactly when it needs
a name only an off cell provides. A cycle that only exists through a
`"disabled"` edge is not reported, since that edge is how a dependent of a
disabled cell is found, not a real ordering constraint.

**Run order** is a display-order-first topological walk (emit ancestors in
display order, then the cell), run three times: setup, package-attaching
cells, everyone. Compared with Kahn's algorithm with a priority queue, it
moves a cell only when an edge forces it, which keeps markdown cells beside
their neighbours in the written file. The order is total: cycle members
are placed in display order, so the file writer and the scheduler use one
`order` and one `errors` list rather than two orderings.

**Learning at run time** goes through one function, `graph_learn()`, that
replaces a cell's learned definitions or learned references and rebuilds
with `previous = graph`. Learned definitions take part in the
multiple-definitions rule and in edges exactly like static ones; learned
references go through the same edge resolution as static references. The
adapter still sees them apart (`cell_summary()$learned`), because the
snapshot shows both.

**Interface depth.** Public surface: two constructors' worth of value
types, `read_cell`, `notebook_graph`, `graph_learn`, and seven queries
(`upstream`, `downstream`, `run_order`, `cell_errors`, `blocked_cells`,
`cell_summary`, `changed_cells`). Behind it: scope tracking, the formula
column rule, `source()` following with cycle protection, package-call
forms, replacement targets, export shadowing, SCC detection, the stable
order, the error wording, and the cache. The caller never learns which
cells to re-read, how cycles are grouped, or how exports shadow.
What remains exposed on purpose: `read_file` (IO stays outside, per
boundary-discipline), `exports` (only the server knows what's installed),
and `learned` (the server persists it). Validation happens once at
`notebook_graph()`'s boundary (ids unique, setup in ids, learned ids
filtered); inside, the types are trusted.

**What it deliberately does not do.** It does not decide what to run: the
scheduler composes `run_order(g, union(ids, ancestors))`. It does not
filter base R names out of references: an unknown name that no cell
defines produces no edge, and the UI can grey it out. It does not tag NSE
symbols: the design says a column name that looks like a reference is a
reference, and the only policy attached is the wording of the cycle error.
It does not read the footer or write it.

## Synthesis decision

Three candidates were drafted on three models. B is the base: a pure
`read_cell()` with no notebook context, a graph rebuilt whole from its inputs
(analyses cached by code), rule tables in `R/rules.R`, and a run order that
keeps display order unless an edge forces a move.

- From A (one facts table for static and learned information): `affected()`,
  because the cells to rerun after an edit include cells that read a name the
  edit removed, which only the old graph shows; and the list of model
  functions whose second positional argument is the data. A's single facts
  table was not taken: it puts variables, packages and paths in one string
  column, and B's `graph_learn()` already sends learned facts through the
  same rules.
- From A, not taken: run numbers on learned facts. One worker runs cells in
  order over one socket, so a report can't arrive out of order.
- From C (analysis and graph split with many small exported rule functions):
  nothing structural; B's split is the same with a smaller public surface.
- Changed from B: no self edge or cycle error for a cell reading its own name
  (see above), and sourced files are compared by text, not an md5 that needs
  R 4.5.

## Tradeoffs accepted

- We accept re-reading every sourced file on every rebuild (through the
  reader, to compare text) in exchange for a cache that needs no
  invalidation call from the file watcher; helper files are small and few.
- We accept keeping the full code string in each analysis instead of a
  hash in exchange for no hashing dependency and an `identical()` check
  that is fast on unchanged strings.
- We accept a fixed list of model functions whose second positional
  argument is the data (`formula_data_positional`); a function outside it
  called as `f(y ~ x, df)` reads every formula symbol as a reference, which
  costs a possible false cycle, not a stale result.
- We accept recording every free name, including base R functions, as a
  reference in exchange for an analysis that needs no environment.
- We accept that a rebuild is whole-notebook (linear in cells and
  references) in exchange for no incremental edge maintenance; the
  performance section budgets about a millisecond per changed cell for
  reading and the rest is table lookups.

## Alternatives considered

- **Mutable graph with per-edit patching** (add/remove a cell, update its
  edges in place). It hides less: callers must call the right update for
  each edit kind, and shared mutable state between the scheduler and the
  adapter needs a lock. A pure rebuild with a cache gives the same cost for
  the common edit and a smaller surface.
- **References tagged by context (NSE argument, formula, plain) on the
  public record.** More surface for a distinction the design attaches no
  rule to. Formula columns are the one context with a rule, so they alone
  get their own structure (`formula_site`).
- **One module** (`analysis.R` holding graph functions too). Smaller file
  count, but the rule tables would be buried among walker code, and the
  cross-cell policy (privacy, shadowing, errors) would sit next to
  single-cell reading, blurring the one boundary that matters for tests:
  `read_cell()` is testable against the corpus without a notebook.
- **A Kahn topological sort with priority classes** for run order. Correct
  and standard, but it emits any ready cell as soon as it is ready, so an
  independent markdown cell drifts away from its neighbours in the written
  file; the design asks for display order to break ties in a way that
  keeps diffs small.

## Open questions and risks

- Resolved: the setup cell is marked `[setup]` in the file (see
  [engine.md](engine.md)), and the walker's speed was measured on the
  corpus (about 5 ms per file at the median).
- Still open, tracked in [design-gaps.md](design-gaps.md): `library()`
  inside a function body, and saving learned references in the footer.

## Next implementation step

Implement `read_cell()` with the scope chain and assignment handling
(tests 1–13), run it over the script corpus against flowR, and only then
add packages, settings, formulas and `source()`.
