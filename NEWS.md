# ember 0.1.0

The first release.

* Reactive notebooks for R. Ember reads each cell's code into a dependency
  graph, so editing a cell reruns the cells that depend on it, and deleting
  one removes its variables.
* A notebook is a plain `.R` file. Its cells are saved in the order they run,
  so `Rscript` gives the notebook's results.
* Each notebook records its packages at a snapshot date and installs exactly
  those versions into its own library, from CRAN, Bioconductor, GitHub or an
  r-universe. `preview_date()` and `set_date()` move the date when you choose.
  `run()` runs a saved notebook from start to finish with those versions.
* A notebook opens in safe preview and runs nothing until you allow it.
* The browser interface (`start_server()`) is a fork of Pluto.jl's. It shows
  data frames as paged tables, lists as trees, plots at a fixed size that stay
  sharp on high-density screens, and htmlwidgets.
* Interactive inputs bound to variables, from the emberui package: a slider,
  number box, checkbox, text box, dropdown or radio buttons, or several in
  one with `input_list()`. Moving one reruns the cells that read it.
* An R API for driving notebooks from code: `open_notebook()`,
  `edit_notebook()`, `run_cells()`, `notebook_snapshot()` and the rest.
