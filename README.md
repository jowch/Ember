# ember <img src="man/figures/logo.png" align="right" height="139" alt="ember logo" />

Reactive notebooks for R. Change a cell, and every cell that depends on it
reruns, so what you see always matches the code.

Ember reads each cell's code to work out which variables it defines and
which it uses, and keeps the notebook as a dependency graph. Cells run in
the order the graph needs, not the order they appear on the page.

> **Status:** early development, not yet on CRAN. Expect rough edges; see
> [what's missing](#whats-missing).

## Why Ember

- **No hidden state.** Edit a cell and the cells downstream of it rerun.
  Delete a cell and its variables are removed.
- **Notebooks are plain R scripts.** Cells are separated by comments and
  saved in the order they run, so `Rscript analysis.R` gives the notebook's
  results (with the same package versions), the file diffs cleanly in git,
  and it opens in any editor.
- **Reproducible packages.** Each notebook records the packages its code
  uses, pinned to a snapshot date, and Ember installs exactly those
  versions with renv. Move the date forward when you choose to update.
- **Safe to open.** A notebook opens in safe preview: you can read it
  without running anything until you choose to.
- **Rich outputs.** Data frames as paged tables, lists as expandable
  trees, plots that redraw to fit, htmlwidgets such as DT, and
  coloured console output.
- **Help as you type.** Autocomplete from your session, help pages in a
  side panel, and a function's arguments shown while you type a call.
- **Runs in your browser.** The interface is a fork of
  [Pluto.jl](https://plutojl.org)'s, adapted for R.

## Installation

```r
# install.packages("pak")
pak::pak("jowch/Ember")
```

Ember includes a little C code, so installing from source needs a compiler
(Rtools on Windows, the Xcode command line tools on macOS).

## Getting started

Start Ember and open it in your browser:

```r
srv <- ember::start_server()
```

It opens the start page and prints its link:

```
Ember is running at http://127.0.0.1:4321/?secret=...
Stop it by calling $stop() on the returned server, or by quitting R.
```

The link carries a key that changes each time Ember starts. If a browser
tab says "This link needs Ember's current key", open the link printed in
the R console; Ember prints it again when that happens.

The start page lists your notebooks. Click **New
notebook**, give it a name and a folder, and it opens. To open a notebook
you already have, use the start page's file field, or pass the file to
`start_server("analysis.R")`. From inside a notebook, the flame at the top
left or ⋯ → **Open another notebook** goes back to the start page.

A notebook you open from a file starts in safe preview: click **Run this
notebook** to run it. Then write code in the cells. Shift+Enter runs a
cell, and ⋯ → **Keyboard shortcuts** lists the rest. When you're done:

```r
srv$stop()
```

Ember listens on port 4321 (or the next free port), on your machine only.
To use it on a remote machine, forward that port over SSH,
`ssh -L 4321:localhost:4321 server`, and open the address it prints. Behind
a proxy such as Posit Workbench or JupyterHub, pass the proxy's host name:
`start_server("analysis.R", allowed_hosts = "workbench.example.org")`.
A proxy that serves Ember under a path prefix should redirect the bare
prefix to one with a trailing slash, as JupyterHub's server proxy does:
Ember never sees the prefix, so its relative links resolve one level too
high against a URL without that slash.

To run a saved notebook from start to finish outside the browser, with the
package versions it records:

```r
ember::run("analysis.R")
```

## What's missing

Ember is being built in steps. Not yet available: interactive inputs, like
Pluto's `@bind`.

Known gaps are tracked as [GitHub issues](https://github.com/jowch/Ember/issues),
labelled P1 to P3 by priority, and the design is in [docs/design.md](docs/design.md).

## Acknowledgements

Ember's browser interface is forked from [Pluto.jl](https://github.com/fonsp/Pluto.jl)
(MIT), by Fons van der Plas and the Pluto.jl authors. The logo's lettering
is drawn from [Instrument Sans](https://github.com/Instrument/instrument-sans)
(SIL Open Font License). See [inst/COPYRIGHTS](inst/COPYRIGHTS).

## License

MIT
