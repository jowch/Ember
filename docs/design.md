# Ember design

Ember is a reactive notebook for R with Pluto.jl's
guarantees: each global is defined in one cell, editing a cell reruns the
cells that depend on it (or marks them stale, if the notebook asks), the
notebook is one plain-text file with durable cell IDs, and its package
environment is detected from the code and recorded in that file. Nothing
here is built yet.

_Drafted 2026-09-26 in the Endeavor project; moved here 2026-09-27._

## Summary

No maintained R notebook works this way. Reactor (2021, abandoned) tracked
dependencies while code ran; marimo-r (a 2026 fork of marimo) wraps R cells in
Python cells with inputs declared by hand; Quarto, Shiny and learnr need
reactivity declared with `reactive()` or `input:`. marimo closed R support as
"not planned" (marimo#6620).

Ember is an **R package written in R**, standalone, MIT-licensed. It plays
the part Pluto plays for Julia:

- a **server** R process: reads cells, builds the graph, schedules runs,
  writes the file, manages packages, serves the UI (httpuv);
- one **worker** R process per notebook: evaluates code with only the
  notebook's packages on its library path;
- the **UI**: a hard fork of Pluto's frontend, shipped inside the package.

Other programs (Endeavor first) drive it through its R API; nothing in this
repository depends on them.

## Decisions

- **Platforms: macOS, Linux and Windows**, wherever the current R release
  runs.
- **`Rscript notebook.R` gives the notebook's results.** Running the file top
  to bottom does what running every cell in the notebook does, given the
  same package versions (`ember::run()` supplies them from the lock). So
  cells run in the global environment, as a script's code does, not in a new
  environment per run as Pluto's cells run in a new module: `source()`,
  `<<-`, `data()` and S4 classes all write to the global environment.
- **Reuse before writing.** Use an existing package or R's own code where one
  does the job, and write new code only for what is Ember's own. The worker
  is the exception: it can use only R and the packages that ship with it.
- **Plain R first, compiled code only where measured.** The parts that need
  speed are already compiled (httpuv, later, processx, jsonlite, and R's own
  `serialize()` and `identical()`). If the server spike finds an R part too
  slow, only that part moves to C or Rust (extendr), behind the same R
  function, and only in the server; the worker stays base R.
- **A stable file format.** The format should rarely change. When it does,
  every Ember can open and convert notebooks written by any earlier
  version; dropping support for an old format needs a strong reason. The
  engine's rules (what counts as a reference, masking order, what is a
  global setting) get the same care: a change can make the same file rerun
  different cells or raise new errors, so it is rare and announced in the
  release notes.
- **Static cell IDs, cell order and fold state in the file**, as in Pluto.
- **The code in the file is the authority.** Eliminating hidden state
  includes stale outputs: every output shown comes from running the current
  code in the current worker, or is visibly marked stale (see the next
  entry). Outputs are never saved or restored, not in the file and not
  beside it.
- **Edits rerun dependents, or mark them stale.** A notebook setting, as
  marimo's `on_cell_change`: "autorun" (the default, as Pluto) reruns the
  cells that depend on an edited cell; "lazy" marks them stale instead,
  keeping their outputs dimmed and labelled until they run. Running a stale
  cell runs its stale ancestors first. Pluto's safe preview shows editing
  without running is workable.
- **Open without running.** Running a cell runs its unrun ancestors first.
  "Run all" is one click. Long simulations don't start just because a
  notebook was opened.
- **Every notebook opens in safe preview**, as in Pluto, even one that ran
  before: no worker and no installs. This protects against unfamiliar code
  (installing detected packages runs their install scripts, and loading runs
  their `.onLoad`) and against a crash loop, where code that crashed the last
  session crashes the next one as soon as it opens. The user can read and
  edit cells; edits are staged, not run. A banner says what running will do
  ("starts R, installs 3 packages"). The first run the user asks for, a cell
  or "Run all", allows execution for the session: it starts the worker,
  installs what's missing, then runs. Nothing is remembered between sessions.
  Endeavor's `allow_execution` tool maps onto this. marimo has no such
  state: it opens without running by default (`auto_instantiate = False`),
  but its `--sandbox` mode starts installing a notebook's packages as soon as
  it opens, and its docs only warn to "run notebooks from sources you trust".
- **Packages detected from the code** (`library()` and friends), installed
  automatically and locked inside the file, as Pluto's package manager does.
- **`library()` in any cell**, as `using` is in Pluto, but each package in
  one cell only. The worker keeps the search path in step with the notebook
  (see [Attached packages](#attached-packages)).
- **One definition per global, as in Pluto**, including objects modified in
  a later cell (see [Reading cells](#reading-cells)).
- **No setup cell. A global setting is set in one cell only**, like a
  global; settings cells run first, and the worker sets the settings for
  each run. A scoped form (`withr::with_options()`) covers local changes.
  See [settings-cells.md](settings-cells.md).
- **Enforce only what the engine needs.** Errors are limited to what keeps
  the notebook free of hidden state: one definition per global (and per
  setting and attached package), private dot-names. Everything else is
  plain R. Style advice (`local()` for private work, pipelines or named
  stages, where to put `set.seed()`) goes in the user docs, never in errors.
- **Assume too many dependencies rather than too few.** An extra edge costs a
  rerun, or rarely a false "Cyclic references" error; a missing edge leaves a
  stale result.
- **Random numbers work as in R.** `set.seed()` goes wherever the user puts
  it; the engine adds no seeding. The random state isn't a variable in the
  graph, so a cell that draws numbers without its own `set.seed()` can give
  different results depending on what ran before it, as in a script.
- **Compilers are the user's to install.** The engine detects when a package
  needs building from source and explains what to install; it doesn't install
  compilers itself.
- **Interactive inputs** (sliders, dropdowns and the like, Pluto's `@bind`)
  are in scope. Their design comes later.
- **No script importer for now.** Converting existing `.R` and `.Rmd` files
  into notebooks may come later.

## Layout

```
DESCRIPTION               # imports: httpuv, later, processx, jsonlite, RcppMsgPack, renv
R/
  rules.R                 # the engine's rules as tables
  analysis.R              # cell reading: the result type and read_cell()
  scope.R, walk*.R        # the walker: scopes, constructs, formulas, calls
  positions.R             # exact positions from getParseData()
  graph.R                 # edges, run order, errors
  queries.R               # upstream, downstream, affected, summaries
  notebook.R              # file format: read, write
  state.R, step.R         # the session: one state value, one pure step()
  shell.R                 # the worker process, socket, polling, saving
  api.R                   # the R API: open, edit, run, snapshot, events
  server.R                # httpuv, websocket protocol, state diffs
  packages.R              # detection, lock, install
inst/
  worker.R                # started in the worker; base R only
  frontend/               # forked Pluto frontend
tests/testthat/
```

## Processes

This maps one to one onto Pluto's server and workers:

- **Server** (its own library): httpuv for HTTP and websockets, `later` for
  its event loop, processx to start and watch workers. It must never block:
  it watches workers without waiting on them, and package installs run in
  their own subprocess.
- **Worker** (the notebook's library): a plain `Rscript` running a loop
  written in base R plus the packages that ship with R (utils, tools,
  grDevices, codetools). It exchanges `serialize()`d messages with the server
  over a socket. Its code is `inst/worker.R`, found with
  `system.file("worker.R", package = "ember")`: files in `R/` are built into
  Ember's namespace at install, so the worker couldn't read them without
  loading Ember. It starts as `Rscript --vanilla` with `R_LIBS_USER` set to
  the notebook's library and `R_LIBS` and `R_LIBS_SITE` unset, which leaves
  exactly the notebook's library and R's own (measured: the user's personal
  library, where rig puts pak, is hidden). A worker starts and connects in
  about 115 ms; package loading comes on top.

The server resets SIGINT to its default before starting workers. A process
started in the background by a shell (`&`) inherits SIGINT as ignored, R then
never installs its interrupt handler, and interrupts silently do nothing
(measured: a 10 s loop ran to the end; with the reset, it stopped in 10 ms).
The reset is a few lines of C, so the server package has compiled code from
the start. The server polls the worker socket from its `later` loop every
5 ms (about 2% of a core when idle), and must read a large worker message in
pieces rather than all at once, so a big output can't stall it.

The server runs two ways. From an interactive R session, the R API starts
it as a background process (processx) and returns a handle to get its URL and
stop it; running httpuv inside the caller's session would freeze the UI
whenever that session is busy. A host program that starts its own R process
(Endeavor) calls a blocking entry point instead, as `Pluto.run()` is, after
loading its adapter into the same process (see
[Integration with Endeavor](#integration-with-endeavor)).

The UI requires a secret in its URL, as Pluto's `require_secret_for_access`
and Jupyter's token do: the server runs code, and any page or program on the
machine can reach a loopback port.

Why not callr or mirai for the worker: both load their own packages into the
worker, and R shares loaded packages across the whole process. If a notebook
then asked for a different version of one of them, it would fail with
"namespace already loaded". Posit's Ark kernel keeps its helpers out of the
user's session the same way: it sources them into a private environment
instead of loading a package.

**Why not Ark as the worker.** Ark prints auto-printed values as plain text
only (its code has "TODO: Implement rich printing" at that spot); rich output
goes through Positron-only channels, and the one way for R code to send HTML
is an internal function. We would also be a Jupyter client in R, which is
awkward. Ark is useful as reference code: helper isolation, completion and
help.

## Reading cells

A walker over R's language objects, in the style of Pluto's
ExpressionExplorer (about 1000 lines), written as a plain recursion rather
than on codetools' `walkCode()`: codetools would only supply the recursion,
and its `findGlobals()` rules differ from Ember's (it treats `s` in
`s <- s + 1` as local and skips formulas). The design of this step is in
[cell-graph.md](cell-graph.md). For each cell:

- **Definitions:** names assigned at the top level (`<-`, `=`, `->`, `<<-`,
  `->>`, `%<>%`), `for` loop variables, names assigned in either branch of an
  `if`, functions.
- **References:** names read before the cell defines them, excluding
  function arguments and names local to function bodies or `local()`.
  Formulas follow their own rule (see [Formulas](#formulas)).
- **Packages:** `library`, `require`, `requireNamespace`, `pkg::fn`,
  `pkg:::fn`, `box::use`, `pacman::p_load`, as `renv::dependencies()` does.
- **Edges:** a reference becomes an edge only if another cell defines that
  name, or a package the cell attaches exports it. Exports come from
  `getNamespaceExports()` once the package is installed, so editing a
  `library(dplyr)` cell reruns the cells that call `mutate`. Pluto doesn't
  know exports and only runs `using` cells first.
- **Private names:** names starting with a dot (`.i`, `.tmp`) are private to
  their cell, like marimo's `_` names (R doesn't allow a leading `_`). R
  already hides dot-names from `ls()`. Using one from another cell is an
  error that suggests dropping the dot. The user docs also recommend
  `local({ … })`, R's equivalent of Julia's `let`, for a block of private
  work; the engine already treats it as its own scope.

R's own behaviour doesn't change: a plain `for (i in …)` still defines `i`,
so two cells looping over `i` conflict, and the error suggests `.i`.

Non-standard evaluation (dplyr columns, ggplot's `aes`) makes column names
look like references; that only adds an edge when some cell defines a global
with the same name. The cost is a rerun, or a false cycle when that cell also
reads the result (`df |> mutate(z = x * 2)`, then a later cell defines `x`
from it); the error suggests renaming the global.

**Code inside strings and lambdas.** glue and cli interpolate `{…}` in
strings (`glue("{total} of {n}")`, `cli_alert("{n} files")`), so the
expression in each segment is read as code; `{{` is an escape. stringr's
`str_interp()` is read the same way for its `${...}` and `$[fmt]{...}`
segments. A one-sided
formula passed to a function that isn't a model function (purrr's
`~ { v <- .x * 2; v + 1 }`) is a lambda: it is read as a function body with
its own locals, not by the formula rule. Both were found by the corpus test
in build step 1.

**Writes static reading can't see.** `assign()`, `load()`, `data()`,
`list2env()`, `makeActiveBinding()`, and `<<-` or `rm()` inside a function
change globals without a visible assignment. Under the `Rscript` target they
must be tracked, not just noted, so the worker compares the global
environment before and after each cell. Before the cell it keeps a list of
the global variables (references, not copies, dropped when the cell ends);
after, it compares names with `ls(globalenv(), all.names = TRUE)` and values
with `identical()`, which returns at once for an object that wasn't replaced.

- **A new name** becomes a definition of the cell, learned at run time as a
  computed `source()` path is, under the usual rules: dependents rerun, and
  a name another cell defines is a "Multiple definitions" error.
- **A changed or removed variable of another cell** is the same case as
  `df$col <- v` in a later cell: a "Multiple definitions" error, pointing to
  the line where it can.
- **Definitions learned at run time are recorded in the footer**, so a
  notebook opened without running still orders its cells correctly.
  Editing the cell keeps them until it runs again, so it still runs before
  its readers, unless keeping them would block the cell: a cycle, or
  "Multiple definitions" against a cell that now defines the name. A
  blocked cell can't run its way out, so then they are dropped, and the
  next run learns them again.
- `.Random.seed` is skipped; see the random-numbers decision.

Reads can't be watched this way. A literal name is read statically:
`get("x")`, `exists("x")` and `mget(c("a", "b"))` reference those globals,
and data.table's `dt[, ..cols]` references `cols`. A computed name
(`get(paste0("fit_", i))`), a call with `envir` or `pos`, and
`eval(parse())` run normally, and the engine shows a note that it can't
track them.

**Code in other files.** `source("helpers.R")` with a literal path is read
like part of the cell:

- The engine parses the file and counts its top-level definitions (and its
  `library()` calls) as the cell's own, following `source()` calls inside it.
- It watches the file. When the file changes, the cell and its dependents
  rerun or are marked stale, following the notebook's autorun or lazy
  setting, like marimo's module reloader.
- A computed path (`source(file.path(dir, "helpers.R"))`, a loop over
  `list.files()`) is learned when the cell runs. The worker traces
  `base::source` and `sys.source`, which also catches `base::source()` and
  calls from packages, and sends the resolved path to the engine before the
  file's code runs. The engine parses the file, rejects it if it defines a
  name another cell defines, removes the cell's old definitions, then lets
  `source` proceed. Before the cell's first run, the paths the footer's
  `learned sources` block records for that cell stand in, until the cell
  runs again. This happens silently; the user sees no note.
- The notebook's footer records each sourced file's path and hash, so a
  changed or missing helper is reported on open. The helper's code stays in
  its own file; the notebook alone is no longer the whole record, and the
  UI says so.

The user docs also recommend the module form, R's version of PlutoLinks'
`@ingredients`: `h <- new.env(); sys.source("helpers.R", envir = h)` or
`box::use(./helpers)`, then `h$fit_growth(…)`. The graph sees one name. This
is advice, not a rule.

**Modifying an object in a later cell.** `df$col <- v`, `names(x) <- v`,
`x[[i]] <- v` are rewritten by R into `df <- \`$<-\`(df, "col", v)`: a new
definition of `df`, and so a "Multiple definitions" error, as in Pluto. The
error offers a fix: move the line into the defining cell, or name the result
(`df2 <- …`).

R is stricter here than Julia or Python. Pluto and marimo treat `x[1] = 2`
or `df["col"] = v` in another cell as a use of `x`, not a definition, so it's
allowed and not tracked: cells that read `x` don't rerun. Both document this
as something to avoid rather than something they prevent. R's copy-on-modify
makes the same code a visible redefinition, so the rule catches it.

Only reference objects change in place in R (environments, R6, reference
classes, data.table's `:=` and `set*()`). Those stay untracked, as mutation
is in Pluto and marimo; the user docs say so and the engine warns when a
cell modifies one defined elsewhere.

### Methods

R finds a method at call time: `print(x)` runs `print.foo` when `x` has
class `foo`, so a cell that calls `print` never names `print.foo`, and
`registerS3method()` and `setMethod()` register a method without defining
any name at all. Ember follows Pluto here: a method definition defines the
(generic, class) pair, and every cell that reads the generic depends on
the cell that defines the method. Editing a `print.foo` cell reruns, or
marks stale, every cell that calls `print`. It costs extra reruns (a cell
printing a data frame reruns too), and an extra edge is the cheap side.
Method edges are soft, though: one that would close a cycle is dropped.
Any method whose body reads a global from a cell that happens to call the
generic (and `+`, `c`, `print` are called nearly everywhere) would
otherwise block cells that run fine under `Rscript`, which is worse than
the rerun the dropped edge misses.

- **What counts.** A top-level function with at least one argument named
  `generic.class`, when the generic is one of base R's (a table in
  `R/rules.R`), a function or `setGeneric()` another cell defines, or a
  name exported by a package some cell attaches or calls with `pkg::`. A
  dotted helper with any other prefix (`fit.plot`), or with no arguments
  (`print.stats <- function()`), is just a function. Also
  `registerS3method()`, `.S3method()` and `setMethod()` with a literal
  generic, which always count. `setGeneric("area")` defines `area`.
- **Many cells, one generic.** Any number of cells may add methods to one
  generic. The same pair in two cells (`print.foo` in one,
  `registerS3method("print", "foo", …)` in another, or two
  `setMethod("show", "Foo", …)`) is a "Multiple definitions" error. Of two
  cells that each define a `print` method and call `print()`, the later
  depends on the earlier, not both ways.
- **Removing a method.** The worker undoes a cell's `registerS3method()`
  and `setMethod()` calls when the cell is removed, disabled or rerun, as
  it removes the cell's globals, so R falls back to the method that was
  there before (or none).
- **Autoprint is not a call.** A value printed only because it is the
  cell's last expression gets no edge to the `print` methods, as in Pluto
  (whose own test for this is marked broken). Otherwise nearly every cell
  with output would rerun on any `print` method edit.
- **Not covered yet:** group generics (`Ops.money`, `Math.interval`), `$`
  methods (the walker doesn't read `$` as a call), `setClass()`,
  `setValidity()` and `setReplaceMethod()`.

### Formulas

A formula looks up each name in `data` first and then in the environment it
was created in, which for cell code is the global environment. So
`lm(y ~ poly(x, deg), data = df)` reads the global `deg`, and `Rscript`
always uses its current value. Which names are columns depends on `df`'s
value, so static reading decides by position instead:

- **No `data` argument** (`lm(y ~ x)`): every symbol in the formula is a
  reference. R can only find them among the globals.
- **With `data`:** bare terms and the first argument of calls inside the
  formula (`x` in `poly(x, deg)`, `log(n)` in `offset(log(n))`) are taken as
  columns. Other arguments (`deg` in `poly(x, deg)`, `k` in `s(x, k = k)`)
  are references: they are nearly always settings, not data. `.` (all other
  columns) is never a reference.

Taking terms as columns keeps a common pattern free of a false cycle: a cell
fits `lm(y ~ x, data = df)`, and a later cell defines a prediction grid
`x <- seq(…)` and calls `predict(fit, …)`.

The rule is wrong when a formula mixes a data frame with a global vector
(`lm(y ~ x + z, data = df)`, `z` not a column), and it errs towards a missing
edge. So after the cell runs, the worker checks that each name taken as a
column is in `names()` of the data frame the function received; if one
isn't, the engine adds the edge and shows a note. The footer's `learned
references` block records these names, so the edge is there when the
notebook is opened without running. Editing the cell drops them, as it
drops learned settings; the next run's check finds them again.

In Julia, StatsModels' `@formula` always treats terms as columns, so Pluto
needs no such rule.

## Running cells

The worker runs each cell in the global environment:

1. Remove the variables the cell defined last time and drop its display
   data (see below), so the old and new values aren't in memory at once.
2. Evaluate inside `withCallingHandlers`, collecting messages and warnings
   as structured items and errors with `sys.calls()` for the traceback.
3. Open a fresh plot device per cell (ragg if the notebook's library has it,
   otherwise base `png`), at the cell's own figure size (`#| fig-width`/
   `fig-height`, inches; 7.5 x 5 by default) and a 2x pixel density, so
   `par()` settings end with the cell. Figures are a fixed size, never
   changed by the window; they redraw only when the screen's pixel density
   goes up.
4. Turn the output value into a display (see "How values display" below).

**Which values a cell shows** follows marimo: the last visible value is the
cell's output. Earlier visible values, `print()`, `cat()`, messages and
warnings go to a console area below it, in order. R Markdown instead shows
every visible value inline, and Pluto shows only the last value.

**How values display.** Julia has one display function in its base
language, `show(io, MIME"text/html"(), x)`, that every package extends. R has
none; packages implement two outside conventions instead: knitr's
`knit_print()` (R Markdown and Quarto; gt, flextable, kableExtra) and repr's
`repr_html()`, `repr_png()`, `repr_markdown()`, `repr_latex()` (IRkernel's
MIME types). Ember supports both rather than adding a third, and tries in
order, as marimo does with `_display_`, its own formatters, `_mime_` and
`_repr_*_`:

1. htmlwidgets and htmltools HTML (plotly, leaflet, DT, reactable, `tags`).
2. `knit_print()` methods.
3. `repr_*()` methods.
4. Ember's own views: data frames, tibbles and data.table in the paged
   table view; plots (ggplot, lattice, grid, base) as fixed-size images,
   sharp from the first draw and redrawn only when the screen's pixel
   density goes up; lists and nested structures as an expandable tree, as
   Pluto shows Julia collections.
5. `print()` text, with colour on, so tibble and cli output keeps its
   colours; the UI turns the terminal colour codes into styled text.

Every rich output also carries a `text/plain` form, the value's `print()`
text truncated, as a Jupyter MIME bundle does, so programs that read outputs
as text (Endeavor's agent) see the first rows of a table rather than "HTML
output". The UI accepts HTML, PNG, SVG, markdown and LaTeX. Steps 2 and 3
need knitr or repr loaded; the worker loads them from the notebook's library
only when they are there and a value needs them. That changes no results, so
the `Rscript` target holds. Measured: knitr is in the dependencies of common
packages (rmarkdown, roxygen2); repr was absent from all 222 packages behind
the top 200, so step 3 rarely applies.

Markdown, HTML and layout need no Ember package: htmltools and commonmark do
it and run under `Rscript`. Interactive inputs will need one, the R
counterpart of PlutoUI; see [Interactive inputs](#the-ui).

**Widget files.** An htmlwidget carries its JavaScript and CSS as
dependencies: a name, a version and a folder in the installed package. The
worker sends them with the widget's HTML; the server registers each folder as
an httpuv static path (`/deps/<name>-<version>/`), and the page adds a
`<script>` or `<link>` the first time it sees a name and version. Ten plotly
charts load plotly.js once. Inlining the files instead would resend about
3.5 MB of plotly.js with every plot and rerun. The server only serves folders
inside the notebook's library.

**Display data.** Re-rendering a plot at a new size needs the recorded plot
(`recordPlot()`), and paging a table needs the data frame. The worker keeps
these only for each cell's current output and drops them when the cell
reruns or is deleted, so a removed variable isn't kept alive by its display.

Interrupts go to the worker as SIGINT on macOS and Linux (processx). Windows
has no SIGINT; processx sends CTRL+C through a helper (to verify in the
spike). Compiled code often ignores interrupts, so "restart worker" is always
available, as in Pluto. If a cell hasn't stopped a few seconds after an
interrupt, the UI offers the restart and lists the cells that will need to
run again, as RStudio's "Terminate R" does. An interrupt isn't lost: R acts
on it when the compiled code returns, so if the cell stops late, the offer
goes away. A restart takes about 120 ms before packages load.

Nothing stops native code short of a restart, and Ember doesn't try to keep
state across one. R only sets a flag on SIGINT, which native code sees only
if it calls `R_CheckUserInterrupt()`; repeated interrupts don't escalate as
they do in Julia. Keeping a forked copy of the worker before each cell works
on macOS and Linux but crashes when a library has started threads
(Accelerate, OpenMP, Java) and doesn't exist on Windows; saving values to
disk loses external pointers. A cell that hangs or crashes the worker is the
user's to avoid.

**Restarting the worker** should be rare. It happens when compiled code
ignores an interrupt, when a package crashes the process, when a package the
worker has loaded changes version (R can't reload it in place; with a fixed
snapshot date this mostly happens when the user moves the date), or when the
user frees memory. A new worker is empty, as on open, and is treated the same
way: outputs are cleared and every cell shows as not run. Running a cell runs
the ancestors it needs first, so the user runs only as far into the graph as
they want, as in marimo's lazy mode; "Run all" regenerates everything.

**Global settings.** `options()` (printed digits, `warn`, `contrasts`, which
changes model fits), `ggplot2::theme_set()`, `Sys.setenv()`, `setwd()` and
`Sys.setlocale()` change later cells' results without any variable
connecting them. So does `attach()`, which makes a data frame's columns
visible to every cell. Each setting is treated like a global: any cell may
set it, but only one cell, and a cell that sets one is a settings cell.
Settings cells run first and every later cell depends on them; before each
run the worker sets R's starting values plus the changes of the settings
cells before it. The design is in [settings-cells.md](settings-cells.md).
(Ember first had a setup cell that alone could hold settings; that note
replaces it.) Settings are found twice:

- **When reading the cell:** a top-level call to one of these functions.
- **After running it:** the worker compares `options()`, environment
  variables, working directory, locale and `search()` (leaving out what the
  notebook's `library()` calls attached) before and after each cell, which
  also catches changes made inside functions. A setting found this way is
  saved in the file as a learned setting.

Loading a package can change these too: many packages set default options
in `.onLoad`, and with `library()` allowed in any cell, and `pkg::fn` loading
a package without one, that happens in ordinary cells (measured: 86 of the
199 most-downloaded CRAN packages add options when loaded, 10 add
environment variables). So the worker traces `loadNamespace()`, which every
load goes through, and `library()`, whose `.onAttach` can add more (openxlsx
and tidyverse set options only there), and compares the settings before and
after each. Changes made while loading belong to the package and are
allowed; `Rscript` makes them too. The rest belong to the cell's code and
make it a settings cell. A package that overwrites a setting the notebook
already changed gets a note, since in the notebook it may load at a different point
than in the script. In a clean process none of the 199 changed an existing
option or variable, only added new ones; whether any overwrite a value the
notebook set is still untested. None changed the working directory or
locale. RcppArmadillo, rstan and V8 create `.Random.seed` when loaded, which
the global-environment check already skips.

For a change that should apply to one piece of code, use the scoped form:
withr's `with_options(list(digits = 3), print(fit))`, `with_envvar`,
`with_dir`, `with_seed`, `local_options()` inside a function. These restore
the setting when the code finishes, like a Julia `do` block. withr is a common
CRAN package, detected as a dependency like any other, so the file still runs
with plain `Rscript`. Base R works too: pass the argument
(`print(x, digits = 3)`), or set and restore inside `local()` with
`on.exit(options(op))`. `par()` needs no rule: each cell draws on its own
device.

**Deleting a cell** removes its variables and its settings. **Rerunning a
settings cell** starts from the worker's starting values plus the earlier
settings cells' changes, so a deleted setting doesn't linger.

**Editor services** run in the worker with base R: completion through
`utils`'s completion functions (as IRkernel does), help pages through
`tools::Rd2HTML`, signatures through `args()`. These use internal `utils`
functions, so they're tested on each R release.

### Attached packages

`library()` and `require()` may appear in any cell, but each package in one
cell only. This follows Pluto, which allows `using` in any cell but treats
`using X` as a definition of `X`, so the same package in two cells is
"Multiple definitions"; here the error reads "tidyverse is attached in two
cells" (see [settings-cells.md](settings-cells.md#attaching-a-package-is-a-definition)).
Overlaps such as `library(tidyverse)` in one cell and `library(ggplot2)` in
another are allowed: Ember only sees the names written in the code. Pluto
handles `using` in two steps (`PlutoDependencyExplorer.jl`'s
`cell_precedence_heuristic`, and `move_vars` in Pluto's `Run.jl`):

- **Cells that attach packages run first**, before other cells (after
  settings cells).
- **The search path is rebuilt, not unloaded.** Pluto evaluates each run in a
  new module and repeats only the `using` lines of cells still in the
  notebook, so a deleted `using` stops applying while the package stays
  loaded. Ember's worker does the same with the search path: when a cell
  that attaches packages is added, edited or deleted, it detaches the
  packages the notebook attached (`detach()` without unloading) and attaches
  the current set again. Namespaces stay loaded. Only a change of package
  version restarts the worker.
- **Masking follows file order.** In R the package attached last wins
  (`dplyr::filter` over `stats::filter`), and that is normal use, so Julia's
  rule that an ambiguous name is an error doesn't fit. The worker attaches in
  file order, so which function a name means doesn't depend on which cell ran
  last. The UI shows R's masking message.
- **The real search path is kept**, rather than a private chain of
  environments, so packages that attach others themselves (`Depends:`, or a
  `library()` call in package code) keep working.

marimo also treats an `import` as an ordinary definition under the
one-definition rule. Its other rule doesn't carry over: `from x import *` is
an error, and `library()` is R's star import.

## Performance

Writing the engine in R costs speed only in parts that are small next to
running user code:

- **Reading cells.** Walking language objects in R takes about a
  millisecond for a typical cell (estimate). Only changed cells are re-read,
  so this matters only when opening large notebooks.
- **The server has one thread.** Anything slow in it (reading a big file,
  resolving packages) freezes the UI for every notebook it serves. Installs
  and resolution run in subprocesses; everything else must stay short.
  httpuv's networking runs on its own C++ thread, and static paths (widget
  files, the frontend) are served there without R. If notebooks still slow
  each other down, the fallback is one server process per notebook.
- **State diffs and encoding.** Measured, for a state of 2000 cells with
  1 KB outputs: encoding it all with RcppMsgPack takes 14 ms (jsonlite: 583
  ms), and the diff for one changed cell 0.95 ms. A straight port of Pluto's
  diff grew with the square of the notebook's size; two changes fixed it:
  match names once per object, and skip any part where `identical()` finds
  the same object. That holds when each new state is made by modifying the
  previous one, so R's copy-on-modify shares everything unchanged; the server
  keeps to that. Images go as raw bytes (0.06 ms for 500 KB).
- **Results from the worker.** Values never cross to the server; the worker
  renders them (the first rows of a data frame, a PNG, HTML) and sends only
  that, as Pluto's worker does.
- **Startup.** An R process starts in about 0.2 s, plus package loading
  (a second or two for the tidyverse), the same cost any R user already pays.
  Each worker is a full R process (tens of MB before data), like Pluto's
  workers.

The server spike (below) measures the first three on a large notebook.

## Package environments

As with Pluto, the user writes `library(dplyr)` and the engine does the
rest:

1. Detect the notebook's packages from the code, plus the header's short
   `[extra_packages]` list for packages the code can't reveal: some are only
   needed at run time (`ggsave("x.svg")` needs svglite). When a cell fails
   with "there is no package called 'svglite'", the engine offers to add it
   to that list.
2. Resolve each against CRAN and Bioconductor at the notebook's snapshot
   date. GitHub packages can't be inferred; the user records `user/repo` for
   them, and the engine prompts when a name isn't found.
3. Update the lock and install into the notebook's library in a subprocess.
   The worker restarts only if a package it has already loaded changed
   version; a new package is just loaded.

The file records the R version, the snapshot date, the Bioconductor release
when one is used, the explicit sources and the full lock. The snapshot and
the lock do different jobs: the snapshot fixes which versions are available
to install, the lock records which versions the notebook uses.

**Every lock is CRAN as it was on one date.** CRAN checks that a new version
doesn't break the packages that depend on it before accepting it, so the
versions current on one day were checked together; a lock mixing dates was
not. R packages declare only minimum versions (`rlang (>= 1.1.0)`), never
upper bounds, so this is the strictest consistency R's metadata allows, and
Ember enforces it: the lock never mixes CRAN dates. With a Bioconductor pin,
the rule is one CRAN date plus one Bioconductor release, whose packages are
already consistent with each other. GitHub packages have no date; they sit
outside the rule and are marked unchecked.

- **Adding a package** resolves it at the notebook's date, with its
  dependencies. On open, packages already in the lock install at exactly the
  locked versions; only new ones are resolved.
- **Removing a package** from the code removes it, and dependencies nothing
  else needs, from the lock when the file is saved, as Pluto does.
- **Updating one package** ("update dplyr to 1.2.0", as Pluto offers per
  package) moves the notebook to the earliest date on which that version was
  current, so the other packages move only as far as they must. **Update
  all** moves the date to today. **Pinning an older version** moves the date
  back to when it was current. Each shows every version that changes before
  applying.
- **No solver is needed.** Each package version was current for one span of
  time, from its release to the next. Versions that were all current at one
  moment form a valid lock, and for spans of time, overlapping pairwise
  already means overlapping at one moment; so finding a lock is finding a
  date. The data is every CRAN version's release date, which
  crandb.r-pkg.org gives per package (fetching 100 packages took 3 s with 16
  requests at a time; finding a date took 13 ms). Ember caches it, since
  crandb is a community service. The installer only ever sees one dated
  repository URL.

CRAN's checks aren't a guarantee (a package can be broken or archived on
some date), but they are much stronger than minimum versions. Moving the date
can move many packages when a notebook is old; the preview shows it.

**The lock in the file** is one line per package: name, version and source
(`CRAN`, `Bioc`, or a GitHub commit). Ember converts it to an `renv.lock`
when installing. Measured: `renv.lock` runs to about 38 lines per
package (2201 lines for 58 packages) and `rv.lock` to about 9; either
conflicts when two people add packages on different branches, and one line
per package lets git merge additions line by line. There is no hash: CRAN
never republishes a version and Bioconductor bumps the version on every
change, so name, version and source already fix the code (GitHub packages
carry their commit). A hash couldn't check what Ember installs anyway:
binaries differ per platform and can be rebuilt, and the source tarball's MD5
is already in CRAN's index. renv restored exact versions from such a
minimal lock in 4 s. A line may carry extra fields after the source, which
older versions of Ember ignore, so a stronger check (SHA-256) can be added
later without breaking files.

**Running the file with its own packages.** `Rscript notebook.R` uses the
packages installed where it runs, so it gives the notebook's results only
when the versions match. `ember::run("notebook.R")` runs the file top to
bottom with the notebook's own library, installing it from the lock first
if needed.

**Snapshots.** Posit Package Manager freezes a repository at a date through a
dated URL (`https://packagemanager.posit.co/cran/2026-09-01`), and
Bioconductor the same way, per release
(`…/bioconductor/2026-06-01/packages/3.23/bioc`); both serve binaries for
R 4.6 on macOS (measured). The engine sets the notebook's `repos` to those
URLs when resolving and installing, and leaves the path within them to the
installer: R 4.6 moved macOS binaries to a new path, which rv and renv both
found without help.
Posit's docs describe this as the supported way to pin
(https://docs.posit.co/rspm/user/get-repo-url.html). Its terms for a tool
that uses the public instance by default aren't stated; the engine
lets the repository base URL be changed, for example to an institution's own
Package Manager.

**Bioconductor** is always a source when resolving, because some CRAN
packages depend on Bioconductor ones (WGCNA needs `impute` and `GO.db`);
Bioconductor doesn't reuse CRAN package names, so the two don't clash. Its
packages are versioned by release, not by date, and each release supports
one R minor version (and each R minor version gets two releases). So
`bioc_version` goes in the header only once the lock holds a Bioconductor
package, directly or as a dependency. It is set to the latest release for
the notebook's R that was out at the snapshot date, Bioconductor packages
resolve from that release, and the engine warns if the CRAN snapshot date
falls outside the release's window, since those combinations were never
tested together. A release has three repositories, software, annotation
data (`GO.db`, `org.Hs.eg.db`) and experiment data, and all three are
sources. Their indexes are fetched only when a name isn't on CRAN. A
CRAN-only notebook carries no Bioconductor pin and no tie to an R version.

**Large installs ask first.** Annotation and genome packages
(`org.Hs.eg.db`, `BSgenome.*`) run from hundreds of MB to several GB. Above a
size threshold the engine shows the download size and waits for the user
before installing.

**Installs** link from a shared cache into a per-notebook library, so a
second notebook with the same packages installs in seconds. A library is
named by a hash of the lock, not by the notebook's path: moving or renaming a
notebook doesn't orphan it, notebooks with the same lock share one, and
Ember never has to track where notebooks live.

**Cleanup.** Ember records when each library was last used and, when the
server starts, deletes those unused for 60 days; they hold only links, so a
returning notebook's library is rebuilt from the cache in seconds, or from
the lock. The shared cache is what grows, since it keeps every version ever
installed. The package view shows disk use (libraries and cache) with a
"clean up" button, and `ember::clean()` does the same from R, also clearing
cache entries no library uses; hosts such as Endeavor call it through the R
API.

**Installer: renv.** pak copies instead of linking, so it's out. The
spike installed the same 42 packages (dplyr, ggplot2, data.table, lme4, sf)
with both, from a dated URL:

| | rv (Rust CLI, pre-1.0) | renv (R, mature) |
|---|---|---|
| First library | 8.4 s | 6.5 s |
| Second library, same cache | 0.15 s | 1.8 s (mostly R startup) |
| Library from cache | APFS clones | hard links |
| Bioconductor | a second dated repository | the same |
| Exact versions from a list | refuses per-package pins; relies on the dated URL | yes |

Both work; Ember uses renv. It is an ordinary CRAN dependency that R users
know, restores exact versions, and installs four packages at a time by
default (`renv.config.install.jobs`); `MAKEFLAGS=-jN` parallelises compiling
within a package. rv's measured gain, about 1.5 s on a warm cache, is mostly
R's startup. Shipping rv would mean one of: bundling seven platform binaries
(about 28 MB), which CRAN rejects; building its Rust source at install; or
downloading it on first use, as tinytex fetches TeX. Because the file's lock
is Ember's own one-line format, rv can be added later behind the same
conversion without changing notebooks.

**R itself.** The engine runs on the R it was started with. If that differs
from the notebook's recorded R version, the engine says so and records the
new version once the user runs the notebook on it. With a Bioconductor pin, a
new R minor version also means a new Bioconductor release, which updates
every Bioconductor package at once; the engine says so before recording it.
Installing a matching R (rig, including its user mode that needs no admin
rights) is up to the user or the program driving the engine.

Measured with rig 0.10.0 user mode on macOS: R installs into
`~/.local/share/rig/r/<version>` without admin rights, and versions run side
by side. The tree can be moved or copied, but only runs through its own
`bin/R` and `bin/Rscript` scripts, which point the dynamic linker at its
`lib`; so Ember always starts R through them. R is signed. A copy marked
with macOS's quarantine flag (as a browser or some unzip tools set) shows
Gatekeeper dialogs on first launch and waits for them, which stalls a worker
nobody is watching; a program that downloads R must not quarantine it, or
must clear the flag (`xattr -dr com.apple.quarantine`). `capabilities()`
without arguments warns about X11 on Macs without XQuartz; the worker doesn't
call it.

**Compilers.** Posit Package Manager serves binaries for macOS, Windows and
common Linux systems, including Bioconductor software packages since
2026.08. Source builds are still needed for GitHub packages with compiled
code, R versions outside the binary window (current minor and four before
it), and packages whose binary build failed. Before one, the engine checks
for the tools (macOS: `xcode-select -p` and the Fortran compiler R names in
`R CMD config FC`, `/opt/gfortran/bin/gfortran`; Windows: Rtools; Linux: a C
compiler) and, if missing, stops with instructions. Linux
packages also need system libraries (GDAL for sf, libxml2 for xml2). Posit
Package Manager publishes each package's system requirements, so before
installing, the engine checks for them and, if any are missing, names the
exact `apt` or `dnf` command; installing them stays with the user.

## File format

A plain `.R` file that runs top to bottom with `Rscript`:

```r
### An Ember notebook ###
# /// environment
# ember_version = "0.1.0"
# r_version = "4.5.1"
# snapshot = "2026-09-01"
# bioc_version = "3.22"
# [sources]
# mypkg = "github:lab/mypkg@3f2a1c9"
# [extra_packages]
# svglite
# ///

# %% id=6f1c9a2e-…
library(dplyr)
library(ggplot2)
options(digits = 4)

# %% id=0b7d…
#' ## Growth curves
#' Measured every 30 minutes.

# %% id=a41e…
curves <- read.csv("growth.csv")

# %% id=c93b…
load("fits.RData")

# %% id=d7e0…
## curves + 1

# /// cell order
# 6f1c9a2e-…
# 0b7d… folded
# a41e…
# c93b…
# d7e0… disabled
# ///
# /// sourced files
# helpers.R sha256:9c1e…
# ///
# /// learned definitions
# c93b… fits
# ///
# /// lock
# cli 3.6.5 CRAN
# dplyr 1.1.4 CRAN
# ggplot2 3.5.2 CRAN
# (one line per package)
# ///
```

- Cells are written in run order, so `source()` works; the display order and
  fold state are in the footer, as in Pluto. Where the graph allows several
  orders, display order breaks the tie, so small edits don't reshuffle the
  file and markdown cells stay next to their neighbours.
- `# %%` is the cell marker Positron and VS Code already understand.
- A cell whose every non-blank line starts with `#'` is text, so
  `knitr::spin` renders the file as a report; a cell mixing `#'` lines and
  code is an error. `#'` lines are matched as raw lines, as `knitr::spin`
  does, so a `#'` line inside a multi-line string makes a cell mixed too.
  `` `r expr` `` inside a text line runs reactively, like any other code;
  its value is inserted as plain text once the notebook has run. The
  `[markdown]` tag an older Ember wrote is still read (an unprefixed line
  gets a `#'` added) but never written.
- The comment lines directly above a top-level `name <- function(...)`
  definition, with no blank line between, are its docstring, shown in
  Help.
- A disabled cell, and every code cell that needs a name only it provides,
  is written with `## ` before each line, so `Rscript` skips it. The
  footer says which (`disabled`, `commented`). A text cell is never
  written this way: its `#'` lines are already comments.
- There is no setup cell. A `[setup]` tag an older Ember wrote is read and
  ignored, and the next save drops it. Settings found when a cell ran are
  kept in a `learned settings` block, written only when non-empty (see
  [settings-cells.md](settings-cells.md)).
- What the engine learned when cells ran is kept in `learned` blocks, one
  line per cell (the id, then its words), each written only when
  non-empty: `learned definitions` (names the cell created that the code
  doesn't show), `learned references` (formula terms that weren't columns
  of the data), `learned settings`, and `learned sources` (the computed
  `source()` paths the cell read; their hashes are in `sourced files`). A
  word with a space, quote or backslash is written as a quoted string. A
  file without these blocks reads as having nothing learned; a computed
  path in `sourced files` that no `learned sources` line claims stands in
  for every cell until all of them have run.
- Package names aren't repeated in the header; they come from the code,
  except the few in `[extra_packages]` that the code can't reveal.
- `ember_version` is the Ember version that last saved the file, as Pluto
  writes its version on the file's second line and marimo writes
  `__generated_with`. An older Ember opening a newer file says so and opens
  it read-only, since the file may use rules it doesn't know. A newer Ember
  converts an older file when it saves, and keeps a converter for every
  earlier format, tested against saved example files from each version.

## The UI

A hard fork of Pluto's frontend (Preact, no build step in development, about
20k lines of JavaScript), served by the engine's httpuv server.

**Protocol.** One notebook state object synced as patches over websockets,
plus about fifteen request types. It has barely changed in a year. The
server side is ported to R: state diffs (Pluto's Firebasey), msgpack
encoding through RcppMsgPack (the only maintained msgpack package on CRAN).
The spike ran Pluto's unmodified frontend (v1.0.3) against about 250 lines of
R with six message types (`connect`, `ping`, `update_notebook`,
`run_multiple_cells`, `interrupt_all`, `reset_shared_state`): editing and
running a cell took 24–33 ms end to end, and stop worked. The encoding rules
it found:

- Every JavaScript array is an unnamed `list()`, or a one-element vector
  arrives as a single value.
- An empty object is `setNames(list(), character())`; `list()` encodes as
  `[]`, which broke the page once.
- A field set to null is `x[k] <- list(NULL)`; `x[[k]] <- NULL` deletes it.
- A field keeps one type (integer or double), or every update sends a patch.
- Decoding keeps arrays as lists (`simplify = FALSE`).

The fork ships its third-party libraries as a bundle and always serves it,
so the page works where the browser has no internet (Ember on a remote
machine reached over SSH from a locked-down desktop) and downloaded exports
are self-contained. MathJax stays on the CDN, loaded only when a page has
TeX, as Pluto does. Bundle files have content-hashed names and long cache
headers, so a slow tunnel carries them once per browser.

**Remove** (about half the frontend): Julia scope analysis and syntax
plugins, the Pkg UI, Binder, upload, slider server, recording, the AI
features, the welcome page. Keep the file download (`/notebookfile`) and the
HTML export (`/notebookexport`), which Endeavor uses.

**Replace for R:**

- An R grammar for CodeMirror 6, written for Ember in Lezer, CodeMirror's
  parser system, as Pluto has one for Julia. It gives highlighting, bracket
  matching, folding and indentation, and keeps a tree for half-typed code.
  The only existing one, `lezer-r` 0.1.3, fails on `;`, `|>`, `\(x)`,
  formulas, `if (a) b else c`, unary minus and `x[1, ]` (16 of 24 installed
  vignette scripts had errors), and tree-sitter-r would need an adapter and
  lose CodeMirror's tree-based features. The hard part is R's line breaks
  (a newline ends an expression only when it is complete and outside `(` or
  `[`; `else` on the next line is valid inside braces only), handled with an
  external tokenizer as Lezer's JavaScript grammar handles semicolons. It is
  tested by comparing its expression boundaries with `getParseData()` on the
  corpus from build step 1, and may be offered back to `lezer-r`.
- Go-to-definition and variable highlighting use the server's analysis
  (each name with its exact position), sent with each cell's dependencies;
  the browser only marks the spans. Completion and help come from the
  worker, with a fallback to base R names and the notebook's definitions
  when there is no worker or it is busy, as Pluto's does.
- Autocomplete and the help panel from the worker's completion and help.
- Error display for R tracebacks. "Multiple definitions" and "Cyclic
  references" keep Pluto's rendering.
- A package status view for detected packages and install progress.
- Rich outputs: HTML (with widget files loaded once per page), PNG, SVG,
  markdown, LaTeX, the table view, the tree view for lists, and terminal
  colours in printed text.
- The worker's memory use, next to its status. R rarely returns freed
  memory to the operating system, so a long session can look large; the
  display points to "restart worker", which leaves cells not run rather
  than rerunning them.

**Familiar to R users:**

- Keys: `Cmd/Ctrl+Enter` runs the cell, `Alt+-` inserts ` <- `,
  `Cmd/Ctrl+Shift+M` inserts ` |> `.
- Markdown cells as a cell type, Quarto-style.
- Data frames shown like a tibble print or RStudio's viewer: column types,
  paging.
- Messages and warnings under the output in their own style, as in RStudio's
  chunk output.
- Plots at a fixed size (`#| fig-width`/`fig-height`), never resized by the
  window.
- "N cells not run" with a Run all button, since notebooks open without
  running.

**Interactive inputs.** Pluto's frontend already has the mechanism (bonds:
the page reports an input's value, the server sets a variable and reruns its
dependents). Ember keeps it; the R-side API is to be designed.

**Look distinct:** own colours, fonts and layout. Programs that inject
scripts into the page (Endeavor does) rely on the DOM hooks Pluto's page has
(`pluto-cell` elements with the cell ID, `.code_differs`, the add-cell
buttons, the error element) and its CSS variable names; renaming them is a
change to coordinate with them.

## Integration with Endeavor

Endeavor (`../endeavor`) is a macOS app that puts a Claude agent next to a
live notebook, through MCP tools such as `read_cell`, `edit_cell`,
`execute_cell`, `get_cell_dependencies` and `view_cell_output`. Its plan for
R is in its `docs/r-notebooks.md`; its engine interface is in
`docs/runtime-core.md`. Ember has no Endeavor code: an adapter,
`runtime-r/`, lives in Endeavor, is loaded into Ember's server process, and
answers Endeavor's calls through Ember's R API. So Ember's R API has to
cover what the adapter needs:

- **Notebooks:** open (without running), new, shut down, move the file.
- **Snapshot:** per cell, code, folded, running, queued, errored, stale (lazy
  mode), disabled and disabled_by (the disabled cell a dependent is off
  because of), last run time and duration, output (`text/plain` form and
  MIME type) or a structured error (kind, message, suggested fixes); the
  notebook's process status.
- **Graph without running:** per cell, definitions (static, and those learned
  at run time from the footer), references, direct upstream and downstream
  cells, packages; the run order and the cells that can't run (cycles,
  multiple definitions).
- **Edits:** a batch of set code (refused if the current code isn't the
  expected code), insert at an index, delete, move, fold, applied at once;
  Ember saves the file and updates its own UI.
- **Runs:** run a list of cells, marking them queued at once; interrupt;
  restart; `parse()` a cell's code to report syntax errors.
- **Events,** as Pluto's `on_event` gives: cell state changed, graph
  changed, file saved, run finished, notebook opened, notebook shut down.
- **A PNG of a cell's output** for `view_cell_output`. Plots already are
  PNGs. Other outputs have none, as with Pluto, where the tool refuses
  Markdown, HTML and text and points the agent to `read_cell`, which gets
  the `text/plain` form. So an htmlwidget chart (plotly, leaflet) is text to
  the agent.

Endeavor also relies on the page. Its injected script reads Pluto's DOM hooks
(`pluto-cell` elements with the cell UUID, `.code_differs`, `.selected`,
`pluto-output`, the error element, the add-cell buttons), its `--pluto-*` CSS
variables, the `window.editor_state` object, CodeMirror 6's internals for
inline diffs, and the URLs `/edit?id=…&secret=…`, `/notebookfile` and
`/notebookexport`. The fork keeps all of these and keeps CodeMirror 6; the
Julia-shaped parts of the state (`nbpkg`, and the package log in
`status_tree` until increment 3 removed it)
change, and Endeavor's per-backend page adapter handles them. Cell and
notebook IDs are full 36-character UUIDs.

Two Endeavor documents describe Pluto's behaviour where Ember's differs, and
need updating there: `restart` "then every cell runs" (Ember leaves cells not
run), and the snapshot has no stale state.

## Build order

0. **Spikes**, to run before committing to the design. Done on macOS
   (2026-09-29; results are folded into the sections above): server and
   worker, the frontend stub, rig, rv against renv, and package loading.
   Since then the URL secret and rich outputs in the browser are built, and
   the server and worker run on Linux in CI. Still to run: the server and
   worker, and rig, on Windows (#48, #49); whether any package overwrites a
   setting the notebook already set (#61).
   - Server and worker: httpuv serving the UI while a worker runs a long
     cell; interrupting a running cell and restarting its worker, on macOS,
     Linux and Windows. Pluto's unmodified frontend talking to a stub R
     server for one cell (state patches, msgpack, length-one vectors), since
     the protocol port is the largest risk in the UI fork.
   - rig's user-mode R on macOS and Windows: relocated R, code signing,
     packages with compiled code.
   - rv against renv for per-notebook libraries, on all three systems,
     including how each installs Bioconductor packages and whether Posit
     Package Manager has dated Bioconductor snapshots. Also where to get
     every CRAN version's release date, which the one-date lock rule needs
     to find a date, and how fast it is to query.
   - Package loading and global settings: load the 200 most-downloaded CRAN
     packages one at a time and compare options, environment variables,
     working directory and locale before and after each load. This checks
     that many packages set options in `.onLoad` (assumed, not measured) and
     whether any overwrites an existing setting, which decides whether the
     note in [Global settings](#running-cells) is needed. The same run
     counts how often knitr and repr are installed as dependencies.
1. **Cell reading and graph**, tested on a corpus of a few hundred real R
   scripts, compared against flowR (a GPL-3 R dataflow analyser, used only in
   tests, not shipped).
2. **Engine without UI:** file format, worker, scheduler, R API, tests.
   Built; the design is in [engine.md](engine.md).
3. **Packages:** detection, lock, installs. The first increment (CRAN) is
   built; the design and what follows are in [packages.md](packages.md).
4. **UI fork:** protocol in R, removals, R adaptations, theme.
   - **R grammar for the editor,** a separate track run alongside step 2:
     it depends on nothing else, and the corpus to test it exists.
5. **Interactive inputs.**

Each step ends in something that runs.
