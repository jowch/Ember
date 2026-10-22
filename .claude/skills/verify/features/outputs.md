# Outputs

**Reach.** `fixtures/ui-sweep.R` (table, plot, long text, error) or
`rich.R` (lists, models, ANSI, parse errors), with `--run`.

**Drive.** Run the notebook; scroll each output into view. Tables:
`.ember-table` holds a `table.pluto-table` and, when rows or columns are
cut, `.ember-table-more` with `button.ember-show-more` ("Show N more
rows"). Wide tables scroll sideways inside `pluto-output`. Plots are
`pluto-output img`. Errors are `jlerror`.

**End state.** Nothing is cut off or covered: the show-more button is
reachable and not under the horizontal scrollbar (#286, layout rule
`scrollbar`); long text wraps inside the column; the error names the
message and line. Check at 600 px too, where the column is narrowest.
