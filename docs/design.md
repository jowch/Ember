# turtleR design

turtleR (working name) is a reactive notebook for R with Pluto.jl's
guarantees: each global is defined in one cell, editing a cell reruns the
cells that depend on it, the notebook is one plain-text file with durable cell
IDs, and its package environment is detected from the code and recorded in
that file. Nothing here is built yet.

_Drafted 2026-09-26 in the Endeavor project; moved here 2026-09-27._

## Summary

No maintained R notebook works this way. Reactor (2021, abandoned) tracked
dependencies while code ran; marimo-r (a 2026 fork of marimo) wraps R cells in
Python cells with inputs declared by hand; Quarto, Shiny and learnr need
reactivity declared with `reactive()` or `input:`. marimo closed R support as
"not planned" (marimo#6620).

turtleR is an **R package written in R**, standalone, MIT-licensed. It plays
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
- **Static cell IDs, cell order and fold state in the file**, as in Pluto.
- **Open without running.** Running a cell runs its unrun ancestors first.
  "Run all" is one click. Long simulations don't start just because a
  notebook was opened.
- **Packages detected from the code** (`library()` and friends), installed
  automatically and locked inside the file, as Pluto's package manager does.
- **One definition per global, as in Pluto**, including objects modified in
  a later cell (see [Reading cells](#reading-cells)).
- **Global settings only in the setup cell**; elsewhere they are an error,
  with a scoped form for local changes.
- **Enforce only what the engine needs.** Errors are limited to what keeps
  the notebook free of hidden state: one definition per global, private
  dot-names, global settings outside the setup cell. Everything else is
  plain R. Style advice (`local()` for private work, pipelines or named
  stages, where to put `set.seed()`) goes in the user docs, never in errors.
- **Assume too many dependencies rather than too few.** An extra edge costs a
  rerun; a missing edge leaves a stale result.
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
DESCRIPTION               # imports: httpuv, later, processx, jsonlite
R/
  analysis.R              # cell reading: definitions, references, packages
  graph.R                 # topology, run order, errors
  notebook.R              # file format: read, write
  server.R                # httpuv, websocket protocol, state diffs
  worker.R                # started in the worker; base R only
  packages.R              # detection, lock, install
inst/frontend/            # forked Pluto frontend
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
  over a socket.

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
ExpressionExplorer (estimate 500–800 lines). For each cell:

- **Definitions:** names assigned at the top level (`<-`, `=`, `->`, `<<-`,
  `->>`, `%<>%`), `for` loop variables, names assigned in either branch of an
  `if`, functions.
- **References:** names read before the cell defines them, excluding
  function arguments and names local to function bodies or `local()`, and
  symbols inside formulas (`~`).
- **Packages:** `library`, `require`, `requireNamespace`, `pkg::fn`,
  `pkg:::fn`, `box::use`, `pacman::p_load`, as `renv::dependencies()` does.
- **Edges:** a reference becomes an edge only if another cell defines that
  name.
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
with the same name, and the cost is a rerun.

Not visible to static reading. These run normally; the engine only shows a
note that it can't track them:
`assign`, `get`, `eval(parse())`, `load`, `attach`, `with`, `list2env`,
`makeActiveBinding`, `setwd`.

**Code in other files.** `source("helpers.R")` with a literal path is read
like part of the cell:

- The engine parses the file and counts its top-level definitions (and its
  `library()` calls) as the cell's own, following `source()` calls inside it.
- It watches the file. When the file changes, the cell and its dependents
  are marked stale, or rerun if the user turns that on, like marimo's module
  reloader (`lazy` and `autorun`).
- A computed path (`source(file.path(dir, "helpers.R"))`, a loop over
  `list.files()`) is learned when the cell runs. The worker traces
  `base::source` and `sys.source`, which also catches `base::source()` and
  calls from packages, and sends the resolved path to the engine before the
  file's code runs. The engine parses the file, rejects it if it defines a
  name another cell defines, removes the cell's old definitions, then lets
  `source` proceed. Before the first run, the last path recorded in the
  footer stands in. This happens silently; the user sees no note.
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

## Running cells

The worker runs each cell in the global environment:

1. Remove the variables the cell defined last time.
2. Evaluate inside `withCallingHandlers`, collecting messages and warnings
   as structured items and errors with `sys.calls()` for the traceback.
3. Open a fresh plot device per cell (ragg if the notebook's library has it,
   otherwise base `png`), so `par()` settings end with the cell. Plots are
   re-rendered at a new size when the UI asks.
4. Turn the output value into a display: data frames as table data for the
   UI's table view, htmlwidgets through htmltools (already loaded if the
   value is one), everything else as printed text. Which values count as
   output is an [open question](#open-questions).

Interrupts go to the worker as SIGINT on macOS and Linux (processx). Windows
has no SIGINT; processx sends CTRL+C through a helper (to verify in the
spike). Compiled code often ignores interrupts, so "restart worker" is always
available, as in Pluto.

**Global settings.** `options()` (printed digits, `warn`, `contrasts`, which
changes model fits), `ggplot2::theme_set()`, `Sys.setenv()`, `setwd()` and
`Sys.setlocale()` change later cells' results without any variable
connecting them. Global settings go in the setup cell with the `library()`
calls, which every cell depends on. Anywhere else they are an error, caught
twice:

- **When reading the cell:** a top-level call to one of these functions.
- **After running it:** the worker compares `options()`, environment
  variables, working directory and locale before and after each cell, which
  also catches changes made inside functions.

For a change that should apply to one piece of code, the scoped form is
allowed: withr's `with_options(list(digits = 3), print(fit))`, `with_envvar`,
`with_dir`, `with_seed`, `local_options()` inside a function. These restore
the setting when the code finishes, like a Julia `do` block. withr is a common
CRAN package, detected as a dependency like any other, so the file still runs
with plain `Rscript`. `par()` needs no rule: each cell draws on its own
device.

**Deleting a cell** removes its variables. **Changing the setup cell**
restarts the worker, because attached packages can't be detached cleanly.

**Editor services** run in the worker with base R: completion through
`utils`'s completion functions (as IRkernel does), help pages through
`tools::Rd2HTML`, signatures through `args()`. These use internal `utils`
functions, so they're tested on each R release.

## Performance

Writing the engine in R costs speed only in parts that are small next to
running user code:

- **Reading cells.** Walking language objects in R takes about a
  millisecond for a typical cell (estimate). Only changed cells are re-read,
  so this matters only when opening large notebooks.
- **The server has one thread.** Anything slow in it (reading a big file,
  resolving packages) freezes the UI for every notebook it serves. Installs
  and resolution run in subprocesses; everything else must stay short.
- **State diffs and encoding.** Diffing nested R lists and encoding msgpack
  in R are slow for large payloads. Outputs are sent whole when they change,
  not diffed, and images go as raw bytes, which R writes quickly. If the
  pure-R encoder is too slow, RcppMsgPack (compiled) replaces it.
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

1. Detect the notebook's packages from the code.
2. Resolve each against CRAN and Bioconductor at the notebook's snapshot
   date. GitHub packages can't be inferred; the user records `user/repo` for
   them, and the engine prompts when a name isn't found.
3. Update the lock and install into the notebook's library in a subprocess,
   then restart the worker.

The file records the R version, the snapshot date, the explicit sources and
the full lock. The snapshot and the lock do different jobs: the snapshot
fixes which versions are available to install, the lock records which
versions the notebook uses.

**Snapshots.** Posit Package Manager freezes a repository at a date through a
dated URL (`https://packagemanager.posit.co/cran/2026-09-01`); Bioconductor
has matching snapshots. The engine sets the notebook's `repos` to those URLs
when resolving and installing. Posit's docs describe this as the supported
way to pin (https://docs.posit.co/rspm/user/get-repo-url.html). Its terms for
a tool that uses the public instance by default aren't stated; the engine
lets the repository base URL be changed, for example to an institution's own
Package Manager.

**Installs** link from a shared cache into a per-notebook library, so a
second notebook with the same packages installs in seconds. Two candidates,
settled by a spike: **rv** (Rust CLI, fast, pre-1.0) or **renv** (R, mature,
what R users know). pak copies instead of linking, so it's out.

**R itself.** The engine runs on the R it was started with. If that differs
from the notebook's recorded R version, the engine says so and records the
new version once the user runs the notebook on it. Installing a matching R
(rig, including its user mode that needs no admin rights) is up to the user
or the program driving the engine.

**Compilers.** Posit Package Manager serves binaries for macOS, Windows and
common Linux systems, including Bioconductor software packages since
2026.08. Source builds are still needed for GitHub packages with compiled
code, R versions outside the binary window (current minor and four before
it), and packages whose binary build failed. Before one, the engine checks
for the tools (macOS: `xcode-select -p` and gfortran; Windows: Rtools;
Linux: a C compiler) and, if missing, stops with instructions.

## File format

A plain `.R` file that runs top to bottom with `Rscript`:

```r
### A turtleR notebook ###
# /// environment
# r_version = "4.5.1"
# snapshot = "2026-09-01"
# [sources]
# mypkg = "github:lab/mypkg@3f2a1c9"
# ///

# %% id=6f1c9a2e-…
library(dplyr)
library(ggplot2)
options(digits = 4)

# %% id=0b7d… [markdown]
#' ## Growth curves
#' Measured every 30 minutes.

# %% id=a41e…
curves <- read.csv("growth.csv")

# /// cell order
# 6f1c9a2e-…
# 0b7d… folded
# a41e…
# ///
# /// sourced files
# helpers.R sha256:9c1e…
# ///
# /// lock
# (full lock)
# ///
```

- Cells are written in run order, so `source()` works; the display order and
  fold state are in the footer, as in Pluto.
- `# %%` is the cell marker Positron and VS Code already understand.
- Markdown lines use `#'`, so `knitr::spin` renders the file as a report.
- Package names aren't repeated in the header; they come from the code.

## The UI

A hard fork of Pluto's frontend (Preact, no build step in development, about
20k lines of JavaScript), served by the engine's httpuv server.

**Protocol.** One notebook state object synced as patches over websockets,
plus about fifteen request types. It has barely changed in a year. The
server side is ported to R: state diffs (Pluto's Firebasey), msgpack
encoding (a small pure-R encoder, or RcppMsgPack, the only maintained msgpack
package on CRAN), and care that length-one R vectors go out as single values,
not one-element arrays.

**Remove** (about half the frontend): Julia scope analysis and syntax
plugins, the Pkg UI, Binder, export and upload, slider server, recording, the
AI features, the welcome page.

**Replace for R:**

- R syntax highlighting (CodeMirror's legacy R mode). It gives no syntax
  tree, so go-to-definition and variable highlighting use the server's
  analysis, sent with each cell's dependencies.
- Autocomplete and the help panel from the worker's completion and help.
- Error display for R tracebacks. "Multiple definitions" and "Cyclic
  references" keep Pluto's rendering.
- A package status view for detected packages and install progress.

**Familiar to R users:**

- Keys: `Cmd/Ctrl+Enter` runs the cell, `Alt+-` inserts ` <- `,
  `Cmd/Ctrl+Shift+M` inserts ` |> `.
- Markdown cells as a cell type, Quarto-style.
- Data frames shown like a tibble print or RStudio's viewer: column types,
  paging.
- Messages and warnings under the output in their own style, as in RStudio's
  chunk output.
- Plots re-rendered when the cell is resized.
- "N cells not run" with a Run all button, since notebooks open without
  running.

**Interactive inputs.** Pluto's frontend already has the mechanism (bonds:
the page reports an input's value, the server sets a variable and reruns its
dependents). turtleR keeps it; the R-side API is to be designed.

**Look distinct:** own colours, fonts and layout. Programs that inject
scripts into the page (Endeavor does) rely on the DOM hooks Pluto's page has
(`pluto-cell` elements with the cell ID, `.code_differs`, the add-cell
buttons, the error element) and its CSS variable names; renaming them is a
change to coordinate with them.

## Build order

0. **Spikes**, each a few days, to run before committing to the design. They
   will be done in a separate working session.
   - Server and worker: httpuv serving the UI while a worker runs a long
     cell; interrupting a running cell and restarting its worker, on macOS,
     Linux and Windows.
   - rig's user-mode R on macOS and Windows: relocated R, code signing,
     packages with compiled code.
   - rv against renv for per-notebook libraries, on all three systems.
1. **Cell reading and graph**, tested on a corpus of a few hundred real R
   scripts, compared against flowR (a GPL-3 R dataflow analyser, used only in
   tests, not shipped).
2. **Engine without UI:** file format, worker, scheduler, R API, tests.
3. **Packages:** detection, lock, installs.
4. **UI fork:** protocol in R, removals, R adaptations, theme.
5. **Interactive inputs.**

Each step ends in something that runs.

## Open questions

- **Which values a cell shows.** R prints every visible top-level value; R
  Markdown shows all of them inline. marimo shows only the cell's last
  expression as its output, and sends `print()` and other console output to
  a console area below the cell. Pluto shows only the last value. Proposed,
  following marimo: the last visible value is the cell's output; earlier
  visible values, `print()`, `cat()`, messages and warnings go to a console
  area below it, in order.
- **Outputs on open.** Since notebooks open without running, they would open
  blank. marimo, which also opens without running by default, saves the
  session's outputs as you work to `__marimo__/session/<notebook>.json` and
  restores them on open when every cell's code still matches. Proposed: the
  same, beside the file (`.turtleR/<notebook>.json`), but per cell: restore a
  cell's output when its code and its ancestors' code match, so one edited
  cell doesn't blank the whole notebook. The notebook file itself stays code
  only.
