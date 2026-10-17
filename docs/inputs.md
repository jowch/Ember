# Interactive inputs

_Design, 2026-10-17, for #36 (build step 5). Not built._

## Summary

A notebook can bind a slider, a number box, a checkbox, a text box, a
dropdown or a set of radio buttons to a variable. Moving the input sets the
variable and reruns the cells that read it, as Pluto's `@bind` and marimo's
`mo.ui` elements do.

```r
library(emberui)

n <- input_slider(10, 500, value = 100, step = 10)
```

```r
hist(rnorm(n))
```

- **An input is a function call assigned to a name.** `n` is an ordinary
  number. Other cells read `n`, not `n$value`.
- **Under plain `Rscript`, the call returns its default.** `n` is 100. The
  file stays an ordinary R script; it needs the small inputs package
  installed, and nothing else from Ember.
- **Moving the input doesn't rerun its own cell.** The worker sets `n` and
  Ember reruns the cells that read `n` (autorun), or marks them stale (lazy
  mode). Pluto and marimo do the same.
- **Input values aren't saved.** A notebook opens with every input at its
  default, which is also what `Rscript` uses. To keep a value, change the
  default in the code.
- **Agents set inputs with a new EndeavorMCP tool**, `set_input`, and see
  each input, with its current value, in `read_cell`.

The functions live in a separate package with no dependencies, the R
counterpart of PlutoUI (design.md:536), named `emberui`.

## Why a function, and not a `#|` line

The alternative was a `#|` line above a cell holding a literal
(`#| input: slider(1, 10)` above `x <- 5`), where moving the slider edits the
literal. It needs no package, and the file records the last value. It was
dropped because a comment line that changes what a cell does isn't
something R users would think to write or expect to find, and because
choices computed from data (a dropdown of a column's levels) don't fit in a
comment. A function is how R users already meet inputs (Shiny's
`sliderInput()`), autocompletes, has help pages, and takes computed
arguments.

The cost is the package: a notebook with inputs needs `emberui` installed to
run as a script. Once Ember can find it by name (on CRAN, or on
r-universe once notebooks can install from there), Ember detects, installs
and locks it like any other package, so `ember::run()` supplies it. Until
then (guessing a repository is not built, packages.md:515), the notebook
needs a `[sources]` entry; see the decisions at the end.

## What the user writes

```r
n      <- input_slider(10, 500, value = 100, step = 10)
method <- input_select(c("Pearson" = "pearson", "Spearman" = "spearman"))
show   <- input_checkbox(TRUE, label = "Show points")
title  <- input_text("Results")
```

Each function returns a plain R value (no class, no attributes), so `n * 2`,
`if (show)` and `paste(title)` behave exactly as with a literal. The label
defaults to the variable's name.

**The binding rule.** An input is bound to a variable when all of these
hold:

1. The call is the whole right-hand side of a top-level assignment in a
   cell, written as such: `name <- input_*(...)`, `name = input_*(...)`, or
   the same with `emberui::`. This is a check on the code, made by the
   server from the cell's parse.
2. When the cell runs, the input is reported by that call itself, not by a
   function it calls. A user's own function named `input_slider` reports
   nothing, so it doesn't bind; nor does a nested input
   (`input_slider(1, input_number(10))` binds only the slider).
3. Nothing else in the cell reads or redefines `name`.

A cell may hold several. One definition per global already makes the name
unique, so the name is the input's key, as in Pluto's `bonds[name]`.

Any other input call returns its default, as under `Rscript`, and its
widget shows greyed with a note naming the fix. A call inside a function, a
loop or `round(...)` gets "Assign this input to a name at the top of the
cell to use it." A binding broken by rule 3 gets "Read `n` in another
cell." No R warning, since plain R wouldn't give one.

Why so strict: Ember sets the variable without rerunning the cell. That is
only the same as rerunning when the variable *is* the call's value and the
rest of the cell doesn't depend on it. With `x <- round(input_slider(1, 10))`,
setting `x` would skip `round()`. With

```r
n <- input_slider(10, 500, value = 100)
m <- n * 2
```

setting `n` would leave `m` (and any printed value or plot in that cell) at
the old `n`, silently stale. marimo refuses the same case with an error
("Accessing the value of a UIElement in the cell that created it is not
allowed", `marimo/_plugins/ui/_core/ui_element.py`); Ember can't raise one,
since plain R doesn't, so it greys the widget instead.

The alternative is to rerun the input's own cell on every change, with the
hook giving back the new value. That makes every form work, but it reruns
whatever sits next to the input on each step of a drag, and it redraws the
widget while it is being dragged. Pluto and marimo both avoid that, and so
does this design.

**Inputs built from data.** Arguments are ordinary R, so

```r
group <- input_select(levels(penguins$species))
```

reads `penguins`, and the cell depends on the cell that defines it. When
`penguins` changes, the input's cell reruns and the dropdown is rebuilt.

**Where the widget shows.** A cell's bound inputs are shown in its output
area, in the order they were called, above the cell's own output if it has
one. `n <- input_slider(...)` has no visible value, so the slider is the
whole output. This differs from Pluto, where `@bind` returns the widget as
the cell's value, and from marimo, where the cell must end with the element
to show it. In R the variable is a number, so there is nothing to print;
the worker shows the input itself.

## Under plain `Rscript`

Each function checks its arguments, then returns `value`. That is all.

- `input_slider(10, 500, value = 100)` returns `100`.
- `input_slider(10, 500)` returns `10` (`value` defaults to `min`).
- `input_select(c("a", "b"))` returns `"a"` (`selected` defaults to the
  first choice).
- `input_slider(1, 10, value = 20)` is an error, in Ember and in `Rscript`
  alike.

The same holds in an R console, RStudio, `source()` and knitr. Pluto is
close: every Pluto file that uses `@bind` starts with a fallback macro that,
outside Pluto, gives the variable the widget's initial value (or `missing`
when the widget defines none and AbstractPlutoDingetjes isn't loaded).

So `Rscript notebook.R` gives the results the notebook gives with every
input at its default. This PR adds that qualifier to design.md's
"`Rscript notebook.R` gives the notebook's results".

**How the package knows it is in Ember.** The package keeps a small
environment of its own (`.state`, inside its namespace; an environment there
stays writable after the namespace is locked). The worker sets a hook
function in it with `setHook(packageEvent("emberui", "onLoad"), ...)`, so
the hook is in place whenever the notebook loads the package. With the
hook, an input function reports its spec (type, evaluated arguments, and
its own call, for binding rule 2) to the worker and returns the value the
worker gives back. With no hook, it returns `value`. Nothing shows in
`options()` or in the settings comparison, so user code can't see a
difference. The package never imports Ember, and the worker loads nothing
extra: the package is in the notebook's own library because the notebook
calls it.

## How a value enters the graph

To the engine, `n` is an ordinary global defined by the input's cell. The
graph, the run order, safe preview and the file need nothing new. What is
new is a way to change `n` without editing code.

**When the user moves an input:**

1. The page sends the new value (Pluto's `set_bond`, which Ember's
   frontend still has; `Editor.js:652`).
2. The server checks the cell has run, still binds that name, and is
   neither stale nor edited since it ran, and passes the value to the
   worker. While the cell is stale or has unrun edits, its widgets are
   disabled, so a value checked against an old spec can't run dependents
   as if it were current.
3. The worker converts and checks it against the input's spec. A dropdown
   sends an index; the worker turns it into the R object in `choices`. A
   value the spec doesn't allow is refused and the page snaps back.
4. The worker assigns `n` in the global environment.
5. **Autorun:** the server reruns the cells that read `n`, as if the input's
   cell had just run, but not that cell itself. **Lazy:** it marks those
   cells stale instead. marimo does both (`set_ui_element_value` in its
   runtime: referring cells minus the defining cell; `set_stale` in lazy
   mode).

Only cells that read the name that changed rerun. If one cell binds `n`
and `bins`, moving `n` doesn't rerun a cell that reads only `bins`.

**Values arriving faster than cells run.** A slider sends while it is
dragged. Pluto's page already holds new values back while a run is in
progress and sends only the latest when it ends (`Editor.js:1010-1076`).
Ember keeps that, and never interrupts a run for a new value. Text boxes
send when the user presses Enter or leaves the box, not on every key.

**When the input's own cell reruns** (its code was edited, something it
reads changed, or the worker restarted): the server keeps each input's
current value for the session. When the cell reruns, the hook gives the
function that value if the new spec still allows it, so a dropdown of
`levels(...)` keeps its choice when the data reloads. If the cell's code was
edited, or the value is no longer allowed, the input goes back to its
default. For a dropdown or radio, the kept value is the chosen element,
compared with `identical()`, not its position, so a reload that reorders
the levels keeps the same choice.

This follows Pluto, whose page puts the old value back into a redrawn
widget (`set_bound_elements_to_their_value`, Ember's `CellOutput.js:564`)
and sends it as a first value, which the server applies if it differs.
marimo always resets. One difference from Pluto: Pluto keeps the value even
after the input's code is edited; Ember resets it, since editing the call
usually means changing what the input should start at.

**Before the cell has run** there is no widget. That includes safe preview,
since a widget's arguments may need R to compute. Running a cell that reads
`n` runs the input's cell first, as for any unrun ancestor, and `n` gets its
default.

**An input driving a setting.** `options(digits = d)` where `d` is an input:
the settings cell reads `d`, so moving the input reruns the settings cell and
then every cell after it. settings-cells.md:188 already covers this case.

## What's saved in the file

Nothing new. The code is saved; input values are not, as with Pluto and
marimo. A notebook opens with every input at its default, which matches
`Rscript`. This follows "the code in the file is the authority": a value
saved beside the code would make the notebook and the script disagree.

To keep a value, the user edits the default (`value = 250`). A widget
whose value differs from its default is marked, so the user can tell that
`Rscript` would give different results. A "Make this the default" action,
which writes the current value into the call, comes later.

## Widgets in the first version

Names and arguments follow Shiny where R users already know them (`min`,
`max`, `value`, `step`, `choices`, `selected`, `label`), and marimo's set
for which widgets come first. There is no `inputId`: the variable is the
id.

| Function | Returns | Like |
|---|---|---|
| `input_slider(min, max, value = min, step = NULL, label = NULL)` | a number | PlutoUI `Slider`, `mo.ui.slider`, `sliderInput` |
| `input_number(value = 0, min = NA, max = NA, step = NA, label = NULL)` | a number | `NumberField`, `mo.ui.number`, `numericInput` |
| `input_checkbox(value = FALSE, label = NULL)` | `TRUE`/`FALSE` | `CheckBox`, `mo.ui.checkbox`, `checkboxInput` |
| `input_text(value = "", label = NULL)` | a string | `TextField`, `mo.ui.text`, `textInput` |
| `input_select(choices, selected = choices[[1]], multiple = FALSE, label = NULL)` | an element of `choices`, or several | `Select`/`MultiSelect`, `mo.ui.dropdown`/`multiselect`, `selectInput` |
| `input_radio(choices, selected = choices[[1]], label = NULL)` | an element of `choices` | `Radio`, `mo.ui.radio`, `radioButtons` |

- A number keeps `value`'s type: `input_slider(1L, 10L)` returns an integer.
- `choices` may be any vector or list. Names, if present, are what the
  widget shows (as in Shiny); the value is the element itself, not its
  label. PlutoUI's `Select` takes pairs for the same reason.
- The `input_` prefix is decided by Ember's promise to match plain R.
  Bare names would mask functions users already have: `text()` masks
  `graphics::text`, which every session attaches, so after
  `library(emberui)` the call `text(x, y, "a")` would return `"a"` and draw
  nothing, a silently wrong plot. `select()` masks `dplyr::select` and
  `MASS::select`, and `number()` masks `scales::number`.
- bslib already uses the prefix (`input_switch`, `input_task_button`,
  `input_dark_mode`, `input_code_editor`, `input_submit_textarea`). Later
  widgets avoid those names, so Shiny users who attach both get no
  masking.

The package only describes inputs. Ember's frontend draws them, in Ember's
theme, inside Pluto's `<bond>` element, so `Bond.js` handles values and
`CellOutput.js:564` puts a value back after a redraw. PlutoUI instead emits
its own HTML; Ember's way keeps the package free of HTML and dependencies.

**Later, not in the first version:** date, range slider, button and run
button, file picker, forms that send several inputs at once (marimo's
`form`, PlutoUI's `confirm`), combined inputs (`combine`, `mo.ui.array`),
inputs inside markdown text, "Make this the default", and third-party inputs (an htmlwidget that
reports a value, the way any Julia package can implement
AbstractPlutoDingetjes' `Bonds`). A password input would also bring back
Pluto's export check for visible passwords (#36).

**HTML export** shows each input at its current value, disabled, since
there is no server behind it.

## Agents (EndeavorMCP)

An agent should see inputs and be able to move them, as a user does.

- **`read_cell`** lists the cell's inputs in its text output, for example
  `input n: slider 10 to 500, step 10, value 250 (default 100)`.
- **A new tool, `set_input(name, value)`**, goes through the same path as
  the page (steps 2 to 5 above) and returns what `execute_cell` returns for
  the cells that reran, or the stale cells in lazy mode. A refused value is
  an error naming what the input allows. The page shows the new value too.
- **To keep a value**, the agent edits the default with `edit_cell`, as a
  user would. The tool's description says so, since a value set with
  `set_input` is gone when the notebook closes.

This needs an Ember R API call (`set_input(notebook, name, value)`) and
inputs in the snapshot, which the adapter (`runtime/r/adapter.R`) calls. It
is a tool change, so EndeavorMCP's interface number goes up. Pluto notebooks
in EndeavorMCP could get the same tool through Pluto's own bonds; that is a
separate EndeavorMCP issue.

## Where this differs from Pluto and marimo, and why

| | Pluto | marimo | Ember |
|---|---|---|---|
| Form | `@bind x Slider(1:10)` | `x = mo.ui.slider(1, 10)`; read `x.value` | `x <- input_slider(1, 10)`; read `x` |
| The variable holds | the value | the element | the value |
| Shown by | the cell's value | ending the cell with the element | the worker, from the binding |
| Value change reruns | dependents, not the cell | referring cells, not the defining cell | cells that read the name, not the cell |
| Lazy mode | none | marks them stale | marks them stale |
| Outside the app | fallback `@bind` gives the initial value | script mode gives the initial value | the function returns `value` |
| Saved in the file | no | no | no |

R has no macros, so the binding comes from the assignment instead of from
`@bind`. Holding the value rather than an element (Pluto, not marimo) keeps
`x` a plain number under `Rscript` and avoids `x$value` in every cell.

## Engine and page changes, in outline

- **The inputs package:** six functions, the hook check, argument checks.
  Base R only. Tests run it with and without the hook.
- **Worker:** install the hook; for each binding the server found
  (rules 1 and 3), set the expected call before evaluating that top-level
  assignment, and bind an input only if the call it reports is identical
  to it (rule 2); keep each input's spec for the cell's current output (as
  display data is kept); convert, check and assign a new value.
- **Engine:** `set_input()`; per-session input values, cleared when the
  notebook closes; run or mark stale the cells that read the name.
- **Server projection:** emit `bonds` from the session's values, and
  translate the page's `bonds` patches into `set_input()` instead of
  refusing them with 👎 (ui.md:199-203).
- **Frontend:** draw the six widgets from a new output type,
  `application/vnd.ember.inputs+json`, inside `<bond>` elements.
- **EndeavorMCP:** the tool and `read_cell` text, above.

## Decided with Jonathan (2026-10-17)

- **The package is `emberui`**, PlutoUI's counterpart.
- **It ships on r-universe only, like Ember.** CRAN would add standing
  upkeep (policy changes, R-devel check failures with fix-by deadlines,
  archival if one is missed), and everyone who sees a widget already has
  Ember, which ships the same way. The `Rscript` fallback needs only the
  package, from wherever it comes. This needs notebooks to be able to
  install from r-universe, which is separate work; today `ember_repos()` in
  R/resolve.R knows only CRAN, Bioconductor and GitHub sources. Until it
  lands, Ember writes a GitHub `[sources]` entry itself when it sees the
  package.

The other choices are decided above: `input_*` names (matching plain R),
keeping a value on rerun (Pluto), lazy mode marking dependents stale
(design.md's definition of lazy, which marimo applies to inputs; Jonathan
confirmed it), and "Make this the default" coming later.
