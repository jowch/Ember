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

Create a notebook and open it in your browser:

```r
nb <- ember::new_notebook("analysis.R")
ember::close_notebook(nb)

srv <- ember::start_server("analysis.R")   # opens the notebook in your browser
```

Click **Run notebook code** to leave safe preview, then write code in the
cells. Shift+Enter runs a cell. When you're done:

```r
srv$stop()
```

To run a saved notebook from start to finish outside the browser, with the
package versions it records:

```r
ember::run("analysis.R")
```

## What's missing

Ember is being built in steps. Not yet available:

- creating a notebook from the browser (use `new_notebook()` for now);
- rich outputs: tables, expandable lists, htmlwidgets and resizable plots
  (in progress);
- autocomplete and help pages in the editor;
- interactive inputs, like Pluto's `@bind`.

The full list of known gaps is in [docs/design-gaps.md](docs/design-gaps.md),
and the design in [docs/design.md](docs/design.md).

## Acknowledgements

Ember's browser interface is forked from [Pluto.jl](https://github.com/fonsp/Pluto.jl)
(MIT), by Fons van der Plas and the Pluto.jl authors. The logo's lettering
is drawn from [Instrument Sans](https://github.com/Instrument/instrument-sans)
(SIL Open Font License). See [inst/COPYRIGHTS](inst/COPYRIGHTS).

## License

MIT
