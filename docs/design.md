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
  same package versions (`ember::run()` supplies them from the lock) and
  every interactive input at its default (see [inputs.md](inputs.md)). So
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
  cell runs its stale ancestors first, and so does running a cell whose
  ancestor was edited: every ancestor between the edited one and the cell
  run runs too, since each goes stale once the edited one runs (#169).
  The dependents autorun queues follow the same rule: a dependent that
  also reads a stale cell (one a delete, a rename or an interrupt left
  stale) runs after it, not with its stale value (#176). Autorun doesn't
  restart an ancestor that failed or was interrupted while it ran, so a
  dependent that needs one ends as an error until that ancestor is run.
  A cell edited but not yet run still holds what its old code made, so
  until it runs, its edges are both its old code's and its new code's:
  rerunning a cell its old code read marks it stale, and its going stale
  marks stale the readers of what its old code defined (#175), and in a
  run it goes before the cells that read what its old code defined (#174).
  Pluto's safe preview shows editing without running is workable.
- **Open without running.** Running a cell runs its unrun ancestors first.
  "Run all" is one click. Long simulations don't start just because a
  notebook was opened.
- **Every notebook opened from a file starts in safe preview**, as in Pluto,
  even one that ran before: no worker and no installs. This protects against unfamiliar code
  (installing detected packages runs their install scripts, and loading runs
  their `.onLoad`) and against a crash loop, where code that crashed the last
  session crashes the next one as soon as it opens. The user can read and
  edit cells; edits are staged, not run. A banner says what running will do
  ("starts R, installs 3 packages"). The first run the user asks for, a cell
  or "Run all", allows execution for the session: it starts the worker,
  installs what's missing, then runs. Nothing is remembered between sessions.
  A notebook made with the start page's New notebook skips safe preview: it
  was written just now, by the person looking at it, so it opens ready to
  run, as a new notebook does in Pluto (`SessionActions.new()` runs it).
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
  are in scope. The proposed design is in [inputs.md](inputs.md).
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
- **Worker** (the notebook's library): an R process running a loop
  written in base R plus the packages that ship with R (utils, tools,
  grDevices, codetools). It exchanges `serialize()`d messages with the server
  over a socket. Its code is `inst/worker.R`, found with
  `system.file("worker.R", package = "ember")`: files in `R/` are built into
  Ember's namespace at install, so the worker couldn't read them without
  loading Ember. It starts as an interactive R (`R --interactive --vanilla`,
  `Rterm --ess --vanilla` on Windows) that reads one boot line from its
  stdin, which is then closed (#186; see "Prompts" under Running cells), with `R_LIBS_USER` set to
  the notebook's library and `R_LIBS` and `R_LIBS_SITE` unset, which leaves
  exactly the notebook's library and R's own (measured: the user's personal
  library, where rig puts pak, is hidden). A worker starts and connects in
  about 115 ms; package loading comes on top.

  The worker loads a byte-compiled image of `worker.R` when there is one
  (#229). R's JIT compiles a function the second time it's called, so a
  worker running `worker.R` as source paid for compiling its own run code
  on its second run: 0.35 to 0.57 s on Linux, and over 5 s on a slow
  Windows runner. From the image, that run takes 0.09 s. The first notebook
  opened in a process compiles the image in a separate `Rscript`
  (`compiler::cmpfile()`, about 1.5 s, nothing waits on it). The image goes
  in the cache under `worker/`, named by R's version and `worker.R`'s MD5.
  Workers started before it's ready, or with an image that won't load,
  source `worker.R` as before. Turning the JIT off instead would make the
  user's own code slower than in plain R.

The server resets SIGINT to its default before starting workers. A process
started in the background by a shell (`&`) inherits SIGINT as ignored, R then
never installs its interrupt handler, and interrupts silently do nothing
(measured: a 10 s loop ran to the end; with the reset, it stopped in 10 ms).
The reset is a few lines of C, so the server package has compiled code from
the start. The server polls the worker socket from its `later` loop: every 5 ms while
it waits on the worker (a run, a query, or traffic in the last second),
every 250 ms while an install or index job runs, and every 2 s otherwise. A
crash during a run is noticed within 5 ms, and an edit to a watched file
within about 2 s. At 250 ms an idle notebook cost the server 0.7% of a core
and 4 wake-ups a second; at 2 s it is about 0.12% (#46). On macOS and Linux
the server also waits on the worker's stdout pipe (`later::later_fd()`), which
closes when the worker ends, so a crash while idle is noticed at once too
(#209). The slow poll stays: a process a cell started with `system()` holds
the pipe open after the worker has gone, and watched files need it. On
Windows a crash while idle is noticed within about 2 s, since its pipes can't
be waited on. An idle worker sends nothing on its socket, so that needs no
wake of its own.
It must read a large worker message in pieces rather than all at once, so a
big output can't stall it.

Workers and jobs (installs, index fetches) end when the server does. They
start with processx's supervisor, a separate process that sends them SIGTERM
once the server is gone, even after a SIGKILL (#141, #147). A job also takes
its own children with it: on Unix through `sh`; on Windows because R's
`system()` ends a child it started once the R that started it ends
(docs/packages.md, #148). For a worker, a small `sh` outside its process
group waits on a pipe from the server and ends the group once the server is
gone (#150), since the worker itself can't run under a wrapper: the server
interrupts a cell with SIGINT to the worker's own process. So what a cell
starts with `system()` or a fork ends with the server, as it already did
when the notebook restarts. A process a cell starts in a session of its own
(processx, callr) is outside the group and outlives both a restart and a
killed server.

Windows has no process groups, and gets the same result another way (#208).
What a cell starts with `system()` ends with the worker there, since R puts
each such child in a job object that ends it once the worker ends. processx
(and so callr) puts its children in a job object of its own that does the
same, so the worker clears that one setting on processx's job after every
run, before it says the run is done, and from a thread every half second
for a cell still running (src/children.c). processx makes that job only as
it starts its first child, so when processx loads in the worker, the worker
has it start one that only exits (System32's `cmd /d /c exit`) and
releases the job at once (#235). A processx or callr child then outlives a
restart and a killed server, as on Unix, the first one included.

On every system the worker also drops the `PROCESSX_<id>` marker it
inherits as the server's process tree (`cleanup_tree`). Otherwise a cell's
children inherit it, and when the server collects the old worker's process
object after a restart, its finalizer ends them all (#232).

A stopped worker is killed, so R never removes its temp folder itself. The
worker names its `tempdir()` in its hello, and the server removes that
folder once the worker has stopped (closed, restarted, failed or crashed),
#166. A worker whose server was killed outright leaves its folder to the
OS's temp cleaner.

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
  error that suggests dropping the dot. `.x` and `.y` count too; only
  inside a `~` lambda (`map(xs, ~ .x + 1)`) are they the lambda's own
  arguments (#507). `.data` and `.env` are the exception: Ember never
  reads them as notebook objects, since in dplyr code they are rlang's
  pronouns, so a cell that assigns one at top level is an error that
  suggests dropping the dot (#509). That holds even for a cell that only
  reads its own `.data`: a read such as `nrow(.data)` is a call argument,
  which is where the pronoun lives too, so it can't be told apart. The
  user docs also recommend
  `local({ … })`, R's equivalent of Julia's `let`, for a block of private
  work; the engine already treats it as its own scope.

R's own behaviour doesn't change: a plain `for (i in …)` still defines `i`,
so two cells looping over `i` conflict, and the error suggests `.i`.

Non-standard evaluation (dplyr columns, ggplot's `aes`) makes column names
look like references; that only adds an edge when some cell defines a global
with the same name. The cost is a rerun, or a false cycle when that cell also
reads the result (`df |> mutate(z = x * 2)`, then a later cell defines `x`
from it); the error suggests renaming the global.

Base R's own data-masking calls follow R exactly (#107). `subset(df, x > 1)`,
`transform()`, `with()` and `within()` look `x` up in `df` first and take
the global only when `df` has no such column, so the edge does the same.
The worker reports the names of each data frame or list a cell creates,
and the graph reads a masked `x` by the columns `df` had when the one cell
that defines it last ran:

- `df` had `x`: no edge. Editing the cell that defines a global `x` reruns
  nothing, as under `Rscript`, and the false cycle above can't happen.
- `df` had no `x`: an ordinary edge.
- `df`'s cell hasn't run in this session, or its last run failed: a soft
  edge, kept unless it would close a cycle. The cell runs after `df`'s cell
  (it reads `df`), so `df`'s report settles the name before it runs; a cell
  that defines its own `df` settles it on its first run.
- Anything the columns can't decide is an ordinary edge: data that isn't a
  bare name (`subset(df[rows, ], x > 1)`), a `df` from a package or defined
  by several cells, a value that isn't a data frame (`subset()` and
  `transform()`) or a plain list (`with()`, `within()` also), and a
  notebook that defines `subset()` itself or a method of it.

A call's head (`f` in `subset(df, f(x))`) is never masked, as R skips a
column that isn't a function, and assignments inside `with()` and
`within()` define no global. Edges can now appear when an upstream cell
runs, after a run was asked for: a cell whose result came from a stale
cell the run didn't include is left stale, so running it again runs that
cell first. dplyr's verbs keep the behaviour above; they mask through
rlang, with its own pronouns, and aren't covered.

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
(`get(paste0("fit_", i))`), `get` passed as a function
(`lapply(site_names, get)`), a call with `envir` or `pos`, and
`eval(parse())` run normally, and the cell shows a note that Ember can't
tell which variables it reads through them, so it doesn't rerun when they
change (#357). The note comes from reading the code, so it shows before
the cell runs, and the snapshot carries it as `untracked_reads`.

When the read is inside a function (`load_site <- function(s) get(s)`),
the note goes on each cell that calls the function, and names it
(`load_site()`): that cell is the one showing old values. The cell that
only defines the function gets no note, because running it reads nothing.
A call by a string name counts (`sapply(nms, "load_site")`, `do.call()`),
and `args(load_site)` doesn't. A function that calls such a function passes
the note on to its own callers. When no cell calls the function by a name
Ember can see, the note stays on the cell that defines it (#365).

**Code in other files.** `source("helpers.R")` with a literal path is read
like part of the cell:

- The engine parses the file and counts its top-level definitions (and its
  `library()` calls) as the cell's own, following `source()` calls inside it.
- It watches the file. When the file changes, the cell and its dependents
  rerun or are marked stale, following the notebook's autorun or lazy
  setting, like marimo's module reloader. A change while the cell runs,
  after its `source()` read the file, counts too: the result built from the
  old text arrives stale, and autorun runs the cell again (#485).
- A computed path (`source(file.path(dir, "helpers.R"))`, a loop over
  `list.files()`) is learned when the cell runs. The worker traces
  `base::source` and `sys.source`, which also catches `base::source()` and
  calls from packages, and sends the resolved path to the engine before the
  file's code runs. The engine parses the file, rejects it if it defines a
  name another cell defines, removes the cell's old definitions, then lets
  `source` proceed. Before the cell's first run, the paths the footer's
  `learned sources` block records for that cell stand in, until the cell
  runs again. This happens silently; the user sees no note. A file under
  the worker's own `tempdir()` isn't learned: the session wrote it (Rcpp's
  `cppFunction()` sources the wrapper it generates there), and the next
  session's is somewhere else (#165).
- The notebook's footer records each sourced file's path and hash, so a
  changed or missing helper is reported on open. The helper's code stays in
  its own file; the notebook alone is no longer the whole record, and the
  UI says so.

**Data files a cell reads (#276).** A cell that reads a file, such as
`read.csv("data/survey.csv")`, `readRDS(file.path(dir, "fit.rds"))` or
`load("e.RData")`, depends on that file the way it depends on a sourced
helper. However the path is built, Ember learns the file when the read runs:
the worker traces base R's file connections (`file()`, `gzfile()` and the
other compressed ones, `unz()`), which every base reader opens, and a fixed
list of readers (`data_readers` in `rules.R`, `data_reader_args` in the
worker): base R and utils, readr, vroom, data.table's `fread`, readxl, arrow,
nanoparquet, haven, jsonlite, qs2, xml2, sf's `st_read()` and `read_sf()`,
and foreign's `read.dta()`, `read.spss()` and `read.xport()`. A package's
readers are traced when its namespace loads. A shapefile read with sf is
watched with the files beside it that hold its attributes, index,
projection and encoding (`.dbf`, `.shx`, `.prj`, `.cpg`).
So a read inside a helper function, `lapply(files, read.csv)`, a sourced
file's read, and any reader built on R connections (`jsonlite::read_json`,
`Matrix::readMM`) count too. A literal path is also known from the code
before the cell runs.

- Each run replaces the files the last one read, so a path that changes
  between runs (`file.path(dir, input$file)`) is followed. A file inside
  the notebook's folder is named relative to it, as a literal path is.
- A file a run tried to read and found missing is watched too, so the cell
  reruns once it appears. A reader that takes the "file" for something
  else isn't watched: `fread()` takes an `input` with a space as a shell
  command, and xml2 takes text with `<` or `>` as XML. A read of R's own
  files (the libraries, R itself, the session's `tempdir()`) isn't
  watched.
- A folder a run lists with `list.files()` or `dir()` is watched by what
  the listing returns (#514). So `lapply(list.files("data", "csv$",
  full.names = TRUE), read.csv)` reruns when a CSV is added to `data/`
  or removed, and not when another file there changes, such as the lock
  file Excel writes beside a workbook it opens. The listing's version is
  taken as the run ends, so files the cell writes there itself don't wake
  it, and the worker lists each such folder once more then: about 140 ms
  for 20,000 files. The engine lists the folder again only when its
  modified time moves (with `recursive`, any folder under it), checking
  the time in well under 1 ms. It also lists again for 2 s after a move,
  since a coarse clock (FAT's 2 s) can hide a second change in the same
  tick, and every 10 s or 100 times the listing's own time, whichever is
  longer, for a file system that doesn't move a folder's time. These
  times are the engine's own clock, never a network drive's.
  `Sys.glob()`, `list.dirs()` and `fs::dir_ls()` aren't watched yet
  (#595).
- The cost, measured in the worker on a cloud container, is about 15 µs
  for each read of a file the run already read and about 0.2 ms the first
  time (`lapply()` over 2000 small CSVs: 1.3 s, against 0.74 s in plain R).
  Code that reads no file pays nothing. After each top-level expression
  the worker checks every file the run has read so far, in one
  `file.info()` call: about 7 ms for 2000 files. The worker hooks the connections
  and readers by putting a call first in their bodies, not with `trace()`,
  and leaves alone the readers whose body has a loop (read.table() and
  read.fwf(), which reach a connection through `file()` or `isOpen()`, and
  read.dcf() and scan() given a connection made in another cell, which
  Ember doesn't see).

- The engine watches each such file. When its contents change, the reader
  and its dependents rerun or are marked stale, following the autorun or
  lazy setting. So a cell that writes a file and a cell that reads it stay
  in step, though no variable connects them.
- A reader's result records the version of each file it reads (modified
  time and size) when the result arrives. Only a change to another version
  counts, so a cell that writes the file it reads doesn't wake itself, and
  a reader that ran after the writer isn't run twice. Comparing versions,
  not times, holds however coarse the file system's clock is. A reader
  that is queued is marked stale with its dependents, and nothing more is
  queued: its run reads the new file, and if a stop empties the queue
  first, its old result doesn't look current (#472).
- The engine checks the files again as each run's result arrives, before
  the notebook can look finished. So running a writer and waiting for the
  notebook (`run_cells(wait = TRUE)`, an agent's execute-and-wait) returns
  with its readers already rerun, or marked stale in lazy mode.
- A reader that reruns because its file changed runs its stale ancestors
  first, as a cell run by hand does, so it never reads their old values
  (#437). In lazy mode, a reader is also rerun when a cell still queued in
  the same run reads from it, with the cells between them. An example is a
  run of every cell that reaches the writer after the reader. The queued
  cell would otherwise read the reader's old value and show it as current.
  A cell of that run that read from the reader before the write stays
  stale, as the reader does when nothing queued reads from it.
- A cell edited to stop reading a file still shows a result that came
  from it until it runs again. So the file stays watched until then, and a
  change marks that result stale, with what reads from it (#439).
- A change while the reader runs is checked by the worker. It knows which
  top-level expressions of the cell read or write each file: the
  expression it was reading in, literal paths given to a fixed list of
  writers (`data_writers`, such as `write.csv` and `saveRDS`; a writer
  with a computed path counts for every file), and a write through a file
  connection it sees open. After each expression it compares each file's
  version. A change during an expression that neither reads nor writes the file,
  after the cell first read it, is someone else's: the result is marked
  stale, and autorun runs it again. A change before the cell reads the
  file is read with it, and the cell's own writes don't count.
- A write Ember can't see, such as readr's `write_csv()` (compiled code,
  no R connection) inside a helper function, looks
  like someone else's, and costs one extra run, which repeats the cell's
  side effects (an append, a download). A run that sees such a change
  right after a run that saw one keeps its result as it is, so the cell
  doesn't run forever. The writers list covers base R's `cat`, `write`,
  `writeLines`, `writeBin`, `writeChar`, `sink`, `capture.output`,
  `file.append`, `file.copy`, `file.rename` and `download.file`, besides
  the table and serialization writers.
- The check is per top-level expression. For a literal path, an
  expression that reads the file and then works for a long time
  (`d <- read.csv("d.csv") |> slow_step()`) treats a change during that
  work as read with it. A file the run learns has its version taken as it
  is read, so a change after that, even in the same expression, is someone
  else's unless the expression writes the file.
- A file saved with the same bytes isn't a change. The shell compares sizes
  first and hashes a file only when a rewrite keeps its size; the first
  such rewrite after opening counts as a change, since there is no earlier
  hash to compare with. Opening a notebook reads no data file. The hash
  runs on the shell's own loop, so a writer that rewrites a large file
  with the same size makes the page wait while it is read.
- A listed reader given something that names no file Ember can watch,
  such as a connection of a kind it doesn't know, gets a note after the
  run: Ember can't tell which file the cell read, so it doesn't rerun when
  the file changes. The snapshot carries it as `untracked_files`. Text
  (`read.csv(text = …)`, readr's `I()`), URLs, `textConnection()` and
  `pipe()` read no file, and get no note.
- Ember can't see a read in compiled code by a reader not on the list
  (terra, hdf5), or by another process (`system("python prep.py")`).
  Those get no note: Ember doesn't know they read a file. terra's `rast()`
  and `vect()` are S4 generics, and a call put first in a generic's body
  breaks its dispatch (#563). Nor does Ember watch a folder: a file added
  to a folder a cell lists (`list.files("data")`) is read only when the
  cell runs again.
- Reads through a database connection (DBI, for SQLite, DuckDB or a
  server) aren't watched either. A cell that writes a table doesn't rerun
  or mark stale the cells that query it, so run those again by hand. DBI's
  functions are S4 generics too, and hooking them with `trace()` would
  stop working, without a word, after a user's own `trace()` on one of
  them (#563).
- A connection opened with no mode and then written (`con <- file(p);
  writeLines(x, con)`) counts as a read when the file exists. Its own write
  is in the same expression, so it doesn't rerun itself.
- Writes aren't tracked: the writer doesn't become an upstream of the
  reader, so running the reader alone doesn't run the writer first. The
  reader reruns once the file has changed.
- A literal path is resolved against the notebook's folder, where the
  worker starts. A file the run learns is the one it actually read, so a
  cell that calls `setwd()` is watched correctly once it has run.

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
classes, data.table's `:=` and `set*()`, and a closure's environment, such
as a function factory's counter or a memoised function's cache). Those stay untracked, as mutation
is in Pluto and marimo; the user docs say so and the engine warns when a
cell modifies one defined elsewhere. Before each run the worker keeps a
fingerprint of every environment another cell defines (its bindings, and
those of the environments inside it, three levels down, which reaches an
R6 object's private fields), and of the environment each function another
cell defines was made in, unless that is the global environment or a
package's (#333). An S4 generic is skipped: it caches the methods it
dispatched to in its own environment. If a run changes one without rebinding its
name, the cell shows a note: "Changed `cnt` in place, which another cell
defines, so the cells that read it don't rerun." Taking the fingerprint
forces no promise and calls no active binding. Namespaces are skipped, and
so is any one environment with more than 1,000 bindings; the others are
still checked, up to 10,000 bindings a run. A reticulate object is read
by identity only. Its state lives in Python, and the first `py_to_r()`
caches a binding in its R environment, which isn't a change (#259). A
data.table another cell
defines is fingerprinted by its shape: column names, each column's
address, its spare column slots and its key. So `dt[, z := x * 2]`,
`setnames()`, `setkey()`, `setorder()` and dropping a column are noted. A
write to some rows of an existing column (`dt[i, x := 0]`, `set(dt, i,
"x", v)`) keeps the column where it was, so the shape can't show it. A
hash of the table's contents does (#201). Hashing costs about 3.5 ms a
megabyte, so a run hashes only another cell's tables its code could write:
the table of a `[` with `:=`, `let()` or `set*()` in it, an argument of
data.table's `set*()` (under any name, or through `do.call()`), and a
table passed to one of the notebook's own functions (`add_b(dt)`,
`lapply(list(dt), add_b)`), or to a function not defined yet. The body of
each notebook function the cell calls is read the same way, so a helper
that writes the global itself (`zero_dt <- function() dt[1L, x := 0]`)
counts where it's called. A table can also sit in a list or an
environment another cell defines, up to three levels down
(`tabs$flights[1L, x := 0]`, an R6 object's field); the note then names
the list or environment, and so does `with(tabs, flights[1L, x := 0])`.
Code run from text (`eval(parse(text = ...))`,
`source()`) can't be read, so such a run hashes every other cell's table.
A write found is noted under every name another cell binds the table to,
and every list or environment another cell defines that holds it, so
after `alias <- dt` or `held <- list(t = dt)`, a write through `dt` names
`alias` and `held` too (#216). A table two globals hold is hashed once.
Showing the table, reading it with `[` or `$`, and passing it to a
package's function (`nrow(dt)`, `lm(y ~ x, dt)`, `ggplot(dt)`) hash
nothing. Such a run
hashes the table twice, before its code and after; no hash is kept between
runs, so a write that was missed is never blamed on a later cell. That cost
grows with the table and has no cap, on purpose: a cap would bring the
silent miss back. A 36 MB table adds about 0.17 s to each cell that could
write it, and a 1 GB table would add about 7 s. A table the code reaches
only through `get()` or `assign()` by name, or through a package's
function that writes a global, isn't hashed, and its write isn't noted.
Before R 4.5,
`tools::md5sum()` can't hash bytes, so row writes aren't noted there.

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
  generic, which always count, and `setReplaceMethod("r", …)`, a method
  of `` `r<-` ``. `setGeneric("area")` defines `area`.
- **Replacement functions.** R runs `r(x) <- v` as
  `` x <- `r<-`(x, value = v) ``, so the cell reads `` `r<-` ``: it depends
  on a cell that defines `` `r<-` `` (a function or a generic) and on the
  cells that define methods of it. A nested target reads every setter and
  the getters inside it (`names(x)[i] <- v` reads `` `[<-` ``,
  `` `names<-` `` and `names`). `x$a <- v` reads `` `$<-` `` (and
  `$` when nested), so a `` `$<-.rec` `` method orders before it, and
  `x@a <- v` reads `` `@<-` `` the same way.
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
- **Classes named as strings.** R keeps class `Circle` in the global
  binding `.__C__Circle`, so `setClass("Circle")`, `setClassUnion()`,
  `setRefClass()` and `setOldClass()` with a literal name define that name
  (`setOldClass(c("lm2", "lm"))` defines `lm2` and reads `lm`), and a string in a
  class position reads it: `new()`'s class, a `setMethod()` signature,
  `contains =`, slot and field classes, `setValidity()`, `is()`, `as()`,
  `setAs()` and `getClass()`. These edges are ordinary definition edges,
  not soft ones: `new("Circle")` can't run before the class exists. Slot
  and field classes (`representation(r = "Shape")`, `slots =`, `fields =`)
  are the exception: R only warns about an undefined slot class and checks
  it at `new()`, so two classes whose slots name each other run under
  `Rscript`, and their edges are soft like method edges. A subclass or
  union rewriting its superclass's binding (R records the subclass there)
  is not "changing a global defined elsewhere". A class
  exported by a package (`.__C__X` in its exports) resolves to the cell
  that attaches it. Class bindings are the one public dot-name. The same
  class in two cells is a "Multiple definitions" error, and messages call
  it "class Circle". When the worker removes a cell's globals (the cell is
  removed, disabled, rerun or failed), it removes a class with
  `removeClass()`: dropping the binding alone leaves the class in the
  methods package's cache, and `new("Circle")` would go on working.
- **Group generics.** A method of a group generic (`Ops.money`,
  `Math.interval`, `setMethod("Arith", …)`) is read through any member of
  the group (`?groupGeneric`, `?S4groupGeneric`): `a + b` reads
  `Ops.money` and `Arith`'s methods, `sqrt(a)` reads `Math`'s. The table
  is in `R/rules.R`.
- **`$` and `@` methods.** `x$a` reads `$` as `x[1]` reads `[`, so a
  cell using `$` depends on the cells that define `` `$.rec` ``. `@` is
  an S3 generic too since R 4.3 (S7 uses it), so `x@a` reads `@`. The
  field or slot name is never read.
- **More class readers.** `slotNames()`, `getSlots()`, `extends()`,
  `isVirtualClass()` and the signatures of `existsMethod()`,
  `hasMethod()`, `getMethod()` and `selectMethod()` read a class named as
  a string, like `new()`.

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
isn't, the engine adds the edge and shows a note. The check runs no code
of the notebook's: it reads a name or a `$`/`[[` path's value, and for a
call that only filters, sorts or adds named columns (`subset(df, x > 1)`,
`head()`, `df[rows, ]`, `transform(df, w = …)`, dplyr's `filter()`,
`mutate()` and the like, `column_keeping_calls` in the worker) it takes
the columns of the data the call is given plus the names it adds. Running
the call again could repeat a slow data step or a notebook's own S3
method. Any other call (a join, a notebook's own function, `read.csv()`)
leaves its formula unchecked. The footer's `learned
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
   Its messages and warnings go to the console too, after the cell's own:
   ggplot2 builds a plot only when it's printed, so its "Removed n rows"
   warning comes from this step. The value is shown by one call of its
   print method or renderer, so each shows once, though the text form and
   the table's cells run the same methods again. A `knit_print()` that
   prints the value and returns nothing to show (rmarkdown's, for a data
   frame) holds its warnings back while the next step prints the value
   again; any the next step doesn't raise again, such as a warning that
   fires once a session, show after it. One that prints nothing is only
   Ember trying it, which plain R never does, so its warnings are dropped.

**Which values a cell shows** follows Pluto: the value of the cell's last
top-level expression is its output. When that expression is an assignment
(`<-`, `=` or `->`), the assigned value is shown even though R returns it
invisibly, so `cars <- mtcars` shows the table. As in Pluto, the value is
the right-hand side: `df$z <- df$x * 2` shows the new column, not `df`. A
plot the cell drew still wins over an assigned value, so `h <- hist(x)`
shows the histogram. A bound interactive input is the exception: `n <-
input_slider(1, 10)` shows the widget, not the number, since moving the
widget changes `n` without rerunning the cell (inputs.md). Any other invisible value
shows nothing: `invisible()`, `library()`, a function that returns
invisibly. So `invisible(x <- big)`, or a last line of `invisible()`, is
how a cell hides its output (Pluto's trailing `;` has no meaning in R).
`<<-` and `assign()` stay hidden, as does an assigned function (its
printed form is the cell's code again) or a plain environment (its
printed form is an address; an R6 object, which has a class, still
prints). A data.table `:=` or `set*()` call shows nothing, as at the R
console, although R returns the table visibly: data.table marks the table
it returned, Ember reads the mark, and `dt[, z := 1][]` shows it (#185).
The mark is cleared before each top-level expression, so one left by a
`:=` that wasn't shown (`invisible(dt[, z := 1])`, or a helper's) doesn't
blank a later cell that shows the table, as it would at the console.
Earlier visible values, `print()`,
`cat()`, messages and warnings go to a console area below the output, in
order. They show while the cell runs, as in an R console: messages and
warnings at once, and printed text a few times a second (#470). The line
still being written shows as it stands and is redrawn in place, so a
progress bar drawn with `"\r"` moves (#483); each read starts at the line's last `"\r"`, so a
bar redrawn many times costs no more per read. The worker reads what the cell printed from R's event
processing, which R reaches wherever it checks for an interrupt; a cell
inside C code that doesn't check shows its text when that code returns.
On Windows, where R exports no such hook, a timer that R's event
processing dispatches does the same (#482). A
plot drawn with no visible value after it is the output. R
Markdown instead shows every visible value inline.

**Prompts** (#186). A cell runs as R code does in an R console:
`interactive()` is `TRUE`, so a package that asks before it acts ("Do you
want to download...?") asks. Under `Rscript` it would fail ("menu() cannot
be used non-interactively") or take its default. The question waits under
the cell's console, with a field for the answer; `menu()`'s choices are
buttons too. The answer goes back to R, and the console then shows the
question and the answer, as R's console does. Interrupting the cell stops
the wait. The worker replaces `readline()` (which `askYesNo()` and most
packages use), `menu()` and `select.list()` with versions that ask the
server over the socket. R's own console reads have no input, since the
worker's stdin is closed, so `scan("")` and `readLines(stdin())` return at
once, as under `Rscript`, and `browser()` carries on. The API answers with
`answer_input()`, and the snapshot shows the waiting question as the
running cell's `prompt`; an answer can name the prompt's `id`, so one
typed for a question that has since gone (`menu()` asking again, another
tab's answer first) is refused, not given to the next question. Two
settings stay as under `Rscript`: the default graphics device is `pdf`
(an interactive R picks X11, quartz or windows), and rlang's
`check_installed()` errors instead of offering to install into the
notebook's shared library (`rlib_restart_package_not_found = FALSE`; see
packages.md, "Install calls"). `run()` still runs a file under `Rscript`,
so there a cell that asks gets "" or fails.

Measured before this was built (10-17): shapes.R, penguins.R and deseq.R
give the same status, output, plots and messages with `interactive()`
`TRUE`; a cli progress bar updates more often, and lifecycle adds its
"displayed once per session" footer. Measured since (10-23):
`keep.source` is `TRUE`, so a function from a `source()`d file keeps its
srcref and its error frames name that file; the page shows only the
notebook's cells, so nothing there changes. Ember's own installs run in a
separate non-interactive `Rscript`, so they never ask. `Rscript -e` can't
be made interactive: R reading its code from a file never is, whatever the
flags, so the worker reads its boot line from stdin instead.

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
output". When `print()` gives nothing (an htmlwidget) or gives the HTML
source itself (gt, an HTML kable), the text form is the HTML's own text
instead: style and script blocks dropped, a table row per line, cells split
by tabs. HTML with no text at all, such as a plotly or leaflet chart whose
data is in a script, gets a line naming what it is, so the agent knows a
chart is there. The UI accepts HTML, PNG, SVG, markdown and LaTeX. Steps 2 and 3
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
has no SIGINT, and processx's CTRL+C helper needs the worker to have a
console, which it lacks whenever the server does: the interrupt was then
lost, while processx said it sent it. So on Windows the worker waits on a
named event of its own, on a thread of its own, and the server sets it; the
thread sets R's `UserBreak`, as R's own CTRL+C handler does, and R raises
the interrupt as for CTRL+C (src/interrupt.c, #48). If the server can't set
the event, it offers the restart at once and says the interrupt couldn't
reach R. Compiled code often ignores interrupts, so "restart worker" is always
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
option or variable, only added new ones. Set beforehand, a package's own
options are a different story (#61, 383 packages): 33 reset one of their
own options, or a dependency's, when they load (mgcv's `mgcv.vc.logrange`,
lme4, `spam.*`, fixest and others), and keras and modeltime reset an
environment variable. None touched a common setting such as `digits`,
`warn` or `TZ`. So a settings cell that sets `mgcv.vc.logrange` keeps its
value in the notebook, which applies settings cells before each run, but
under `Rscript` the settings cells come first in the file and
`library(mgcv)` resets it. The cell that loads the package gets a note:
"Loading mgcv resets mgcv.vc.logrange, which a settings cell sets. Under
Rscript the setting is lost, because settings cells come first in the
file. Move it into this cell, after mgcv loads." Moved there, the loading
cell becomes the one settings cell for that option (leaving it in both
would be the "set in two cells" conflict), and within one cell the
notebook and `Rscript` keep the order as written. The note shows on the
run that loads the package. None changed the working directory or
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
functions, so they're tested on each R release. Inside a call, utils looks
up the arguments of the function and each of its S3 methods by listing
every attached package per name, which takes seconds for `print(` with a
large package stack. The worker finds the same names with `exists()` and
puts them in utils' argument table for that one completion, so the items
don't change (#288).

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
  version restarts the worker. A cell's packages keep the order plain R
  attached them in, and the worker calls `library()` as the notebook's own
  code would find it on the search path, so a package that wraps
  `library()` to keep its own environment in step (conflicted's
  `.conflicts`) still does.
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
   to that list. It offers the same when rlang's `check_installed()` names
   the packages, and when an error's message says a package is needed and
   marks one in the snapshot that isn't installed (quoted, styled, or just
   before "package"): tidymodels names its engines only as strings
   (`set_engine("glmnet")`). That last one matches the message's text, so a
   translated message gets no offer. The engine
   never installs such a package by itself.
2. Resolve each against CRAN and Bioconductor at the notebook's snapshot
   date. GitHub and r-universe packages can't be inferred. The code names
   them the way R users already do, with an install call
   (`remotes::install_github("user/repo")`, `install.packages("pkg", repos
   = "https://name.r-universe.dev")`), and Ember records the source in the
   header's `[sources]` as `github:user/repo` or `universe:name`; the user
   can also add one there, and the Packages tab offers to on a name that
   isn't found. Install calls don't run in Ember: the lock answers them
   (packages.md, "Install calls").
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
already consistent with each other. GitHub and r-universe packages have no
date; they sit outside the rule and are marked unchecked. The lock records
the git commit for both (an r-universe serves only its latest build).

- **Adding a package** resolves it at the notebook's date, with its
  dependencies. On open, packages already in the lock install at exactly the
  locked versions; only new ones are resolved.
- **Removing a package** from the code removes it, and dependencies nothing
  else needs, from the lock when the file is saved, as Pluto does.
- **Updating one package** ("update dplyr to 1.2.0", as Pluto offers per
  package) moves the notebook to the earliest date on which that version was
  current, so the other packages move only as far as they must. **Update
  all** moves the date to today. **Pinning an older version** moves the date
  back to the last day it was current, so the other packages move back as
  little as they can. Package Manager takes its snapshots at a set time, so
  each date is checked against that day's snapshot, and a snapshot that
  doesn't have the version yet (or, for a pin, already has the next one) is
  passed over for the next day's. Each shows every version that changes
  before applying (`preview_update()`). On the Packages tab, a row whose
  package CRAN has a newer version of offers that update; pinning back is
  an R call.
- **No solver is needed.** Each package version was current for one span of
  time, from its release to the next. Versions that were all current at one
  moment form a valid lock, and for spans of time, overlapping pairwise
  already means overlapping at one moment; so finding a lock is finding a
  date. The data is every CRAN version's release date, which CRAN gives
  itself: its `src/contrib/Meta/archive.rds` and `current.rds` list every
  tarball with the time it was published (about 6 MB together, on any CRAN
  mirror). Ember fetches them in a subprocess and caches the table for a
  day. crandb.r-pkg.org has the same dates, but it is a community service
  Ember would depend on. CRAN's files do add one host,
  cloud.r-project.org (`ember_repos(cran_meta)`), in place of crandb's:
  Package Manager serves `archive.rds` but not `current.rds`. A machine
  that reaches only Package Manager gets "couldn't fetch CRAN's release
  dates" and can still move the whole date. The installer only
  ever sees one dated repository URL.

CRAN's checks aren't a guarantee (a package can be broken or archived on
some date), but they are much stronger than minimum versions. Moving the date
can move many packages when a notebook is old; the preview shows it.

**The lock in the file** is one line per package: name, version and source
(`CRAN`, `Bioc`, a GitHub commit, or an r-universe build and its commit). Ember converts it to an `renv.lock`
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
size threshold (500 MB) the engine shows the download size and waits for the
user before installing (built, #37: packages.md, "Large downloads").

**Installs** link from a shared cache into a per-notebook library, so a
second notebook with the same packages installs in seconds. A library is
named by a hash of the lock, not by the notebook's path: moving or renaming a
notebook doesn't orphan it, notebooks with the same lock share one, and
Ember never has to track where notebooks live.

**Cleanup.** Ember records when each library was last used and, when the
server starts, deletes those unused for 60 days; they hold only links, so a
returning notebook's library is rebuilt from the cache in seconds, or from
the lock. The shared cache is what grows, since it keeps every version ever
installed. The package view shows disk use (libraries, cache and indexes,
measured when the tab opens; built, #38) and a "Clean up…" button (built,
#128) that frees space now: it deletes libraries no notebook open in this
server uses and that weren't used in the last 30 days (Jonathan's pick,
half the startup sweep's 60; every Ember process
touches its open notebooks' library markers hourly, and `ember::run()`
touches its own, so a notebook open elsewhere stays fresh), then the cache
entries no other library lists, except those made in the last day or
linked from an install still running. It shows the counts and
an estimate of the space first, and deletes nothing until Delete, judged
at the preview's time. The cost
of a wrong guess: a notebook whose library was deleted installs its lock
again when it next opens, downloading what the cache no longer holds. With
binaries (macOS, Windows, Linux with Package Manager binaries) that is a
download; on Linux without them, or for Bioconductor packages pinned to
another R, it builds from source, which for a Bioconductor set takes far
longer. Indexes are left to the startup sweep. `ember::clean()` does the same from R with any
age; hosts such as Endeavor call it through the R API.

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

Measured with rig 0.11.0 user mode on Windows 10 (#49), from an account
without admin rights: `rig add --user release` installs R into
`%APPDATA%\rig\data\r\<version>`, and `rig add --user rtools` installs
Rtools into `%APPDATA%\rig\data\rtools\<version>` and sets `RTOOLS45_HOME`
for the user. Neither goes on the PATH. A copy of the R tree runs from its
own `bin\Rscript.exe`, with PNG, Cairo and HTTPS working, and builds a
package with compiled code from source. CRAN's installers are signed, but
the files they install aren't, and rig's downloads carry no "downloaded
from the internet" mark, so nothing asks before R first runs. Rtools' gcc
is on the PATH only inside `R CMD` (R's Rcmd_environ), so the compiler
check asks `R CMD` (install-checks.R's `has_compiler()`); it looked on the
installer's own PATH, found no gcc, and stopped every source build with
"Install Rtools" on a machine that had it.

**Compilers.** Posit Package Manager serves binaries for macOS, Windows and
common Linux systems, including Bioconductor software packages since
2026.08. Source builds are still needed for GitHub packages with compiled
code, R versions outside the binary window (current minor and four before
it), snapshot dates from before the running R came out (no binaries were
built for it then), and packages whose binary build failed. Old versions
often don't build on a newer R. While such packages build, the engine
says which ones have no binary for this R; when a build fails, it says
the package had no binary for this R and offers a newer date or an older
R (#19). Before one, the engine checks
for the tools (macOS: `xcode-select -p`; Windows: Rtools; Linux: the C
compiler R names in `R CMD config CC`) and, if missing, stops with
instructions. The Fortran compiler (macOS: `/opt/gfortran/bin/gfortran`) is
needed by only some packages, and nothing says which before their source is
unpacked, so its absence is read from the build's output instead. Linux
packages also need system libraries (GDAL for sf, libxml2 for xml2). A
binary installs without them and fails when loaded, so once renv has
installed the packages, and before the library is used, the engine asks
the system's loader (`ldd`) whether every package finds its libraries. For
the ones that don't, it names the exact `apt` or `dnf` command from Posit
Package Manager's published system requirements; installing them stays
with the user. Asking the loader rather than the package manager's database
gets libraries from elsewhere (an HPC module, conda) right, and doesn't ask
for a `-dev` package a binary doesn't need. See packages.md, "Install
checks".

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
- Ember never folds a cell for you, text cells included: a text cell
  shows its source above the rendered text until you fold it. A fold set
  by hand is kept in the footer like any other.
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
dependents). Ember keeps it; the R-side API is proposed in
[inputs.md](inputs.md).

**Look distinct:** own colours, fonts and layout. Programs that inject
scripts into the page (Endeavor does) rely on the DOM hooks Pluto's page has
(`pluto-cell` elements with the cell ID, `.code_differs`, the add-cell
buttons, the error element) and the CSS variable names they read; renaming
them is a change to coordinate with them. The variable names kept for them
are the ones Endeavor reads (tests/testthat/fixtures/endeavor-css-variables.txt)
and the ones in pluto-css-variables.txt that Ember's own frontend reads. The
themes define only variables that something reads (#57), and a test checks it.

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
  the `text/plain` form. So an htmlwidget chart (plotly, leaflet) reaches
  the agent only as a line naming it.

Endeavor also relies on the page. Its injected script reads Pluto's DOM hooks
(`pluto-cell` elements with the cell UUID, `.code_differs`, `.selected`,
`pluto-output`, the error element, the add-cell buttons), its `--pluto-*` CSS
variables, the `window.editor_state` object, CodeMirror 6's internals for
inline diffs, and the URLs `/edit?id=…&secret=…`, `/notebookfile` and
`/notebookexport`. The fork keeps all of these and keeps CodeMirror 6; the
Julia-shaped parts of the state (`nbpkg`, and the package log in
`status_tree` until increment 3 removed it)
change, and Endeavor's per-backend page adapter handles them. Notebook IDs
are full 36-character UUIDs, and so are the cell IDs Ember generates. A
hand-written file may use short cell IDs (1 to 64 of `[A-Za-z0-9._-]`);
Ember keeps them, and Endeavor's tools take them. An ID outside that set
(`cell:1`) gets a fresh UUID when the file is read, with its lines in the
footer read under the new ID, and the next save writes that UUID (#82).

Two Endeavor documents describe Pluto's behaviour where Ember's differs, and
need updating there: `restart` "then every cell runs" (Ember leaves cells not
run), and the snapshot has no stale state.

## Build order

0. **Spikes**, to run before committing to the design. Done on macOS
   (2026-09-29; results are folded into the sections above): server and
   worker, the frontend stub, rig, rv against renv, and package loading.
   Since then the URL secret and rich outputs in the browser are built, and
   the server and worker run on Linux in CI. The server and worker were run
   on Windows 10 in 2026-10, started both with a console and without one:
   interrupts needed a way of their own there (#48, see [Running
   cells](#running-cells)). Rig's user mode was run on Windows in 2026-10
   too (#49, see [Package environments](#package-environments)). Whether any
   package overwrites a
   setting the notebook already set (#61) was run on Linux in 2026-10: see
   [Global settings](#running-cells).
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
