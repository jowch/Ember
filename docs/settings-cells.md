# Settings cells

_Design, 2026-10-04. Replaces the setup cell. Not built yet; see
[design-gaps.md](design-gaps.md)._

## Summary

Ember drops the setup cell. Any cell may change a global setting, and a
setting is treated like a global variable: it may be set in only one cell.

- **A setting is a definition.** `options(digits = 3)` defines the setting
  `digits`. Two cells setting `digits` is an error, as two cells defining
  `x` is.
- **Settings cells run first.** A cell that changes a setting moves to the
  front of the run order, in display order, bringing along the cells it
  reads. Every cell after it depends on it.
- **The worker sets the settings for each run.** Before each cell runs, the
  worker puts every setting back to R's starting value and then applies the
  changes of the settings cells that come before that cell in the order.
- **Attaching a package is a definition too.** `library(tidyverse)` in two
  cells is an error.
- **Local changes use a scoped form**: `withr::with_options()` and the other
  `withr::with_*` functions, or plain base R.

This keeps what the setup cell gave (no hidden state, the file runs top to
bottom under `Rscript`) and removes its cost: a special cell in every
notebook that users had to know about and move code into.

## What counts as a setting

The calls are the ones in `setting_functions` in `R/rules.R`, unchanged:

| Call | Setting it defines | Shown as |
|---|---|---|
| `options(digits = 3)` | the option `digits` | `digits` |
| `Sys.setenv(TZ = "UTC")`, `Sys.unsetenv("TZ")` | the environment variable `TZ` | `TZ` |
| `setwd("data")` | the working directory | `wd` |
| `Sys.setlocale("LC_NUMERIC", "C")` | the locale (all categories are one setting) | `locale` |
| `ggplot2::theme_set(theme_minimal())` | ggplot2's theme | `theme` |
| `attach(survey)` | the attached object `survey` | `attach(survey)` |
| `withr::local_options()`, `local_envvar()`, `local_dir()`, `local_locale()` at the top level of a cell | as the base call | as the base call |

`withr::local_*` at the top level of a cell counts because the "local"
frame there is the global environment, which never exits.

**Computed names.** `options(op)` and `Sys.setenv(.list)` don't say which
setting they change. The cell is a settings cell from the start, shown as
"Setting · options"; the names are filled in once it runs (see
[Settings found at run time](#settings-found-at-run-time)). A computed name
never conflicts until it is known.

**Not settings.** `set.seed()` stays as it is: the random state changes with
every draw, so making it a setting would not make results independent of
what ran before, and resetting it per run would hand every cell the same
random stream, which `Rscript` doesn't do. `par()` needs no rule, since each
cell draws on its own device. Changes a package makes while it loads stay
the package's, as today.

**Calls inside `local()`** no longer count statically, as calls inside a
function body already don't. The runtime check still sees any change that
outlives the cell, so nothing is missed, and the base-R pattern below stops
being a false settings cell.

## One cell per setting

The rule is the one-definition rule applied to settings:

```r
# Cell A
options(digits = 3)

# Cell B
options(digits = 5, scipen = 999)
```

Both cells show:

> **`digits` is set in two cells.**
> Set it in one cell, or use `withr::with_options()` to change it for one
> piece of code.

The fix names the scoped function for the kind of setting:
`with_options()`, `with_envvar()`, `with_dir()`, `with_locale()`; for the
ggplot2 theme, add the theme to the plot (`p + theme_minimal()`); for
`attach()`, use `with(survey, ...)` or `survey$col`.

This is the compromise a reactive notebook needs. If two cells could set
`digits`, a cell's output would depend on which of them ran last, which is
hidden state.

**Local changes.** A change meant for one piece of code doesn't belong in a
settings cell. Two ways, both plain R that runs under `Rscript`:

```r
# withr: Ember installs it like any other package it sees in pkg:: calls.
withr::with_options(list(digits = 3), print(fit))
withr::with_envvar(c(TZ = "UTC"), format(Sys.time()))

summarise_fit <- function(fit) {
  withr::local_options(digits = 3)   # restored when the function returns
  print(summary(fit))
}

# Base R: pass the argument directly...
print(x, digits = 3)
format(Sys.time(), tz = "UTC")

# ...or set and restore by hand.
local({
  op <- options(digits = 3)
  on.exit(options(op))
  print(summary(fit))
})
```

Ember adds nothing to a notebook to make this work: no helper is injected,
and withr is detected through `withr::` like any other package. Notebooks
stay plain R scripts.

## How settings cells run

### Run order

The engine computes the order in three passes, as today, with the first
pass changed:

1. **Settings cells**, in display order. Each one first emits the cells it
   reads (its ancestors), then itself.
2. **Cells that attach packages**, in display order, with their ancestors.
3. **Everything else**, display order first, moving a cell only when an
   edge forces it.

After the order is fixed, every code cell gets an edge to each settings cell
that comes before it in the order (`via = "setting"`, named by the setting,
so messages can say why). These edges agree with the order by construction,
so they can never create a cycle.

The file is written in this order, so a settings cell appears near the top
of the file, and `Rscript` applies it before the cells after it, as the
notebook does.

Example, in display order:

```r
# Cell 1
fit <- lm(mpg ~ wt, data = mtcars)

# Cell 2
library(ggplot2)

# Cell 3
theme_set(theme_minimal(base_size = n))

# Cell 4
n <- 14

# Cell 5
ggplot(mtcars, aes(wt, mpg)) + geom_point()
```

Order: 2, 4, 3, 1, 5. Cell 3 is the settings cell; it reads `theme_set`
from ggplot2 (attached by cell 2) and `n` from cell 4, so those run before
it, without its setting, as they would under `Rscript`. Cells 1 and 5 come
after it and depend on it: changing the base size reruns the plot and, as a
cost, the model fit.

### Why "every cell depends on every settings cell" fails

The simpler rule, where every other cell depends on each settings cell,
gives a cycle in four common cases. The setup cell had the same limits; they
were rare there because people put plain `library()` and `options()` lines
in it on purpose. Once any cell can hold a setting, they become common.

1. **Two settings cells.** Cell A sets `digits`, cell B sets `TZ`. Each
   depends on the other: a cycle. Ordering settings cells by display order
   breaks it.
2. **A settings cell using another cell's package.** Cell A has
   `library(ggplot2)`, cell B has `theme_set(theme_minimal())`. B reads
   `theme_set` from A, and A depends on B.
3. **A setting inside a helper.** Cell F defines
   `prep <- function() options(digits = 3)`, cell G calls `prep()`. Once the
   run finds the setting, G is a settings cell, every cell depends on it, and
   G reads `prep` from F: F→G→F.
4. **A setting computed from another cell.** `options(digits = n)` with `n`
   from cell N: N depends on the settings cell, which reads `n` from N. A
   slider driving an option (`@bind`, planned) is the same case.

Under the chosen rule, the cells a settings cell reads come before it and
don't depend on it, so all four work.

### What the worker does before each run

The worker keeps, for each settings cell, the values it left behind (its
after-values). The run message carries the settings cells in effect before
the cell: those before it in the order that aren't disabled, off or in
error. Before running the cell, the worker:

1. puts every setting any cell has changed this session back to its
   starting value (the value when the worker started, plus what package
   loads added);
2. applies the after-values of the settings cells in effect, in order.

Settings no cell touched are left alone, so options that packages set when
they load survive. The worker already rebuilds the search path from `order`
before every run (`rebuild_search_path()`); this follows the same pattern.

Consequences:

- **Rerunning a settings cell starts from a clean slate.** `setwd("data")`
  run twice goes to `data`, not `data/data`. A setting deleted from the cell
  stops applying.
- **Deleting or disabling a settings cell** removes its settings from the
  next run. The worker drops its after-values with its globals
  (`remove_cell`). A disabled settings cell adds no setting edges, so
  disabling it doesn't turn off the rest of the notebook. Delete and disable are allowed
  on every code cell.
- **A cell that runs before a settings cell doesn't see it**, as under
  `Rscript`.
- **The random state is never touched.**

The cost per run is a few `options()`, `Sys.setenv()` and `setwd()` calls,
well under a millisecond.

### Rerunning

Editing a settings cell runs nothing, as for any edit. Running it marks
every cell after it in the order stale; autorun reruns those that had
results, lazy mode leaves them dimmed. This can be most of the notebook: no
method can find which cells read `digits`, because `print()` reads it from
C, `lm()` reads `contrasts` deep inside, and environment variables are read
through C `getenv()`. A missing edge would leave stale output, so Ember
assumes the dependency. The scoped forms above are the way to change a
setting for one cell without that rerun.

Safe preview shows the chip and the order from static reading and the
learned settings in the file.

### Settings found at run time

The worker compares settings before and after each cell, as today, and so
finds changes made inside functions. Today such a change is reverted and the
cell is an error. Now the worker reports it and the cell becomes a settings
cell:

1. The core stores the setting names as the cell's **learned settings**.
2. The graph is rebuilt: the cell moves to pass 1, and the cells now after
   it are marked stale (and rerun in autorun).
3. The cell shows a one-line note: "Found a global setting (`digits`) when
   this cell ran; the cells after it rerun."
4. The learned settings are saved in the file, so the next open starts with
   the right order.

Learned settings are kept until the cell's code changes, even on runs that
change nothing. A cell like `if (big) prep()` would otherwise switch between
settings cell and ordinary cell from one run to the next, rerunning the
notebook each time. A cell's settings are its static ones plus its learned
ones, and both count for the conflict rule. Two cells found to change the
same setting at run time get the same "set in two cells" error.

`theme_set()` is the exception: ggplot2 keeps the theme inside its namespace,
outside what the worker compares, so only the static check finds it (see
[Open questions](#open-questions)).

## Attaching a package is a definition

`library()`, `require()` and `pacman::p_load()` still work in any cell, but
the same package attached in two cells is an error:

```r
# Cell A
library(tidyverse)

# Cell B
library(tidyverse)
library(broom)
```

> **`tidyverse` is attached in two cells.**
> Keep one `library(tidyverse)` and remove the other.

This matches Pluto, where `using X` defines the name `X`, so two cells with
`using X` give "Multiple definitions", and marimo, where an `import` is an
ordinary definition. It keeps the search path one-to-one with cells: which
cell to rerun when a package's attachment changes is never ambiguous.

Overlaps stay allowed. `library(tidyverse)` in one cell and
`library(ggplot2)` in another is fine, though tidyverse attaches ggplot2 too:
Ember only sees the package names written in the code, not what a package
attaches in turn. `requireNamespace()` and `pkg::fn` load without attaching
and never conflict.

The rest of [Attached packages](design.md#attached-packages) is unchanged:
attaching cells run early (pass 2), the worker rebuilds the search path in
file order before each run, namespaces stay loaded, and masking follows file
order.

## In the page

**Chip.** A settings cell has a chip in its top bar: **"Setting · digits"**,
or **"Settings · digits, wd"** for more than one. Hovering it shows:

> This cell changes a global setting. It runs before the cells that don't
> feed it, and they rerun when it changes.

For a learned setting the hover adds "Found when it ran."

**Conflict errors** use the wording above, in the error box "Multiple
definitions" uses, with both cells linked.

**Run-time note.** The first time the worker finds a setting in a cell:
"Found a global setting (`digits`) when this cell ran; the cells after it
rerun." It shows once, on that run.

**Cell menu.** "Disable cell" and "Delete cell" are offered for every code
cell. No cell is special.

**New notebooks** start with one empty ordinary code cell.

## File format

- `[setup]` on a cell marker is read and ignored; Ember no longer writes it.
  The next save drops it.
- A new footer block records learned settings, in the shape of learned
  definitions:

  ```r
  # /// learned settings
  # c93b… option:digits wd
  # ///
  ```

  Names are `option:<name>`, `env:<name>`, `wd`, `locale`, `theme` and
  `attach:<name>`.
- The `no_setup_marker` and `disabled_setup_cell` problems go away.
- The format number stays 1. The change only adds a footer block and stops
  writing a tag; an older Ember already opens a newer file read-only.

### Old notebooks

No user action is needed. On open, the old setup cell is an ordinary cell
and is read like any other:

- **With `options()`, `Sys.setenv()` and the like:** a settings cell. It still
  runs first and still comes first in the file.
- **With only `library()` calls:** an attaching cell. It still runs early, in
  pass 2. Cells that don't use its packages no longer depend on it.
- **Empty:** an empty ordinary cell, kept in place. The user can delete it.
- **Reading another cell's name:** this was a cycle error and now works.

Two changes in what counts as an error, which go in the release notes:

- A setting outside the old setup cell was an error; it is now a settings
  cell, unless the old setup cell sets the same thing.
- A package attached in the old setup cell and again in another cell is now
  "attached in two cells".

## Implementation outline

Sizes are rough and include tests. About 1,000–1,500 changed lines in all,
roughly one ui-3 branch. The plan comes later.

**Engine (graph), ~200 lines.**
- `graph.R`: drop the `setup` argument and its special cases in
  `resolve_edges()` and `find_errors()`.
- A cell is a settings cell if it has static or learned settings and isn't
  disabled.
- `compute_order()`: pass 1 emits settings cells in display order with their
  ancestors; passes 2 and 3 as today.
- After ordering, add `via = "setting"` edges from each later code cell to
  each earlier settings cell.
- Replace `global_setting` with `setting_conflict` (one setting in two
  cells) and add `package_conflict` (one package attached in two cells).
- `walk.R`: settings calls inside `local()` don't count statically.

**Engine (session), ~150 lines.**
- `step.R`, `state.R`: remove `state$setup`, the delete and disable
  refusals, the `global_setting` run error and `role = "setup"`.
- Store the worker's reported setting names as learned settings, dropped
  when the cell's code changes; on a change, rebuild the graph and
  invalidate.
- Send the settings cells in effect with each run message.
- Leave `via = "setting"` edges out of "upstream failed" messages, as setup
  edges are today.

**Worker, ~150 lines.**
- Replace `setup_restore` and the revert with per-cell after-values.
- Before each run, set the starting values plus the after-values of the
  settings cells in effect (`apply_settings_context()`).
- `remove_cell` drops the cell's after-values.
- Restoring `attach()` stays best effort; `.Random.seed` is never touched.

**File format, ~80 lines.**
- Read `[setup]` as a tag with no effect; stop writing it.
- Add the `learned settings` footer block; drop the two setup problems.

**R API, ~60 lines.**
- `new_notebook()` writes one empty code cell.
- `run()` and `notebook_graph()` lose `setup`.
- Cell views replace `setup` with `settings`: the names a cell sets plus
  where each was found (`"code"` or `"run"`). `notebook_snapshot()` shows
  them as they are.
- `delete_cell()` and `disable_cell()` lose their refusals.

**UI, ~80 lines.**
- `pluto-state.R`: send each cell's settings; drop `can_disable`'s setup
  case.
- `Cell.js`: the chip and its hover; "Disable cell" for every code cell.
- `Notebook.js`: the empty-notebook check counts one blank cell, not two.

**Tests, ~400 lines.** Rewrite the roughly 40 tests that use `setup =` or
`[setup]` (mostly mechanical), and add one for each case: two settings
cells, a settings cell reading a package or a name, a setting in a helper,
a conditional setting, delete and disable, `setwd()` rerun, lazy mode, an
old file with `[setup]`, and both conflict errors.

**Docs.** [engine.md](engine.md) and [cell-graph.md](cell-graph.md) describe
the setup cell as built; update them with the code.

## Open questions

- **A setting changed after a package loaded.** `Sys.setenv(RETICULATE_PYTHON
  = ...)` edited after reticulate loaded reruns the cells, but the package
  keeps the old value; a namespace can't reload in place. Offer a restart
  when a settings cell changes an environment variable or option that a
  package loaded since may have read? Which settings, and how to word it, is
  open. This is true with the setup cell too.
- **ggplot2's theme.** `theme_set()` inside a function is invisible at run
  time. Add `ggplot2::theme_get()` to the worker's snapshot when ggplot2 is
  loaded, or accept that only the static check finds it.
- **The rerun count.** Changing a setting reruns most of the notebook.
  Showing the number of cells that will rerun next to Run on a settings cell
  may be worth it.
- **First run of a cell like `prep()`.** A setting found at run time
  reorders the notebook once, so a first "Run all" does one extra pass over
  the cells after it. Accepted for now.
