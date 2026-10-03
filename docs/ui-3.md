# UI, increment 3: Ember's own design

Increment 2 (docs/ui-2.md) made the page Ember's but kept Pluto's look. This
increment gives Ember its own design, decided with the user on the design
canvas "Ember UI design" (https://claude.ai/artifact/75RiGtFN1AA65gTjDW2dWM).
Board names below refer to that canvas.

Status: design complete; implementation planned in [ui-3-plan.md](ui-3-plan.md)
(tests in [ui-3-tests.md](ui-3-tests.md)).

Goals, from the user: Ember has its own identity rather than Pluto's
appearance, but keeps what Pluto does well. It is comfortable for long
sessions, legible, and works for experienced R users and beginners alike. It
leans towards Pluto's lightness, not RStudio or Positron. Status should stay
out of the way of the data, the code and the results.

## Identity

- **Palette: Sage** (board "C · Sage", dark tokens on "Round 3 · Dark mode").
  Light: page `#f5f6f3`, panel `#fcfcfb`, code `#eceeea`, line `#dce1db`,
  text `#1b201d`, muted `#57605a`, accent teal `#22715f`. Dark: page
  `#151917`, panel `#1b201d`, code `#212723`, line `#2f3631`, text
  `#dfe5e0`, muted `#9ba59e`, accent `#6cc7b2`. Faint text (hints, "Saved", folder
  paths) is `#636c65` light and `#88928b` dark, so it passes 4.5 : 1 on every
  background (board "Round 6 · Accessibility"). The panel is a step lighter
  than the page in dark mode instead of using shadows. The logo stays orange
  (`#e8590c`, `#f07032` on dark).
- **Type** (boards "Round 2 · Sans-serif candidates", "Serif candidates"):
  Figtree for the interface and menus, Source Serif 4 for markdown prose, IBM
  Plex Mono for code. Fonts may load from the network with system fallbacks
  (ui-2.md decisions), or be bundled; decide when implementing.
- Endeavor still reads `--main-bg-color`, `--pluto-cell-spacing`,
  `--sans-serif-font-stack` and `--indented`, and Pluto's DOM hooks; keep
  them, mapped onto the new tokens.

## Layout

(Boards "Wide", "Laptop", "Phone".)

- One left-aligned reading column about 720 px wide, sized for prose line
  length, as Pluto does. Outputs sit above the code that made them.
- The side panel docks in the free space on the right when the window is
  wide, so opening it never moves the notebook. Below roughly 1200 px it
  slides over the notebook; on a phone it is a sheet from the bottom.

## Cells

(Board "Round 2 · Cells and status rails".)

- Code looks like the editor: line numbers with comfortable space before the
  code, Plex Mono (not configurable), Sage syntax colours.
- **Rail**: Pluto's status bar, flush with the cell's left edge and the full
  height of the cell, always present. Solid, soft colours:
  - grey: nothing happening (up to date, not run, stale or disabled);
  - blue: running (pulsing), faded while queued;
  - amber: edited and not run yet; the code also gets an amber outline and
    gutter, as in Pluto. Hovering the rail says "Press Shift + Enter to run
    this cell" in a small light label;
  - red: error.
  There is no "blocked" state (see Engine changes).
- **Chips** in the output area say why the output isn't current, each with an
  icon and its own tint: "Not run yet" (neutral, no output), "Stale · `x`
  changed" (amber tint; lazy mode only; the old output is greyed out on a
  grey wash), "Disabled" (solid grey; the code sits on a grey background,
  dimmed).
- **Errors** are a red-tinted box joined to the code box with no gap: the
  message in bold, "Error in `call` · line n", and a traceback that starts
  collapsed ("Show traceback (n calls)"). Opened, calls from the notebook are
  full strength and package internals faded. A cell that fails only because
  a cell it depends on failed shows Pluto's wording instead: "Another cell
  defining **x** contains errors.", with **x** linking to that cell.
- **Run button**: a small round button on the code box's top-left corner,
  overlapping the rail, shown on hover or focus (always on the focused cell
  on touch screens). It becomes Stop while the cell runs. The last run time
  is a small chip on the code's bottom-right corner, also on hover or focus.
- **Cell menu** (⋯ at the code's top right, in the interface font): Hide
  code, Disable cell, Copy output, Move up, Move down, Delete cell.
- **Disable cell** (any code cell but the setup cell): the cell and the
  cells that depend on it stop running, keep their last output dimmed, and
  their variables are removed from R. A disabled cell does not count as
  defining its variables (as Pluto): disabling one of two cells that define
  `x` clears "Multiple definitions", and cells reading `x` then use the
  other one. A cell that needs a name only a disabled cell provides depends
  on it ("Depends on a disabled cell. Go to it"). In the file, the disabled
  cell and those dependents are written with `## ` before each line, so
  `Rscript` skips them; the cell-order footer marks them `disabled` or
  `commented`. Packages used only in disabled cells stay installed and
  locked. Enabling runs the cell.
- **Adding cells**: Pluto's small "+" with a thin line, shown when hovering
  the gap between cells, above the first and below the last. It is laid over
  the gap, so nothing moves. Ctrl + Enter runs a cell and adds one below.
- **Empty notebook**: one cell ("Type R code here") and three hints:
  Shift + Enter runs a cell; Ctrl + Enter runs it and adds one below; start a
  line with `#'` to write text.

## Text cells

(Board "Round 5 · Adding cells; text is just #' lines".)

- There is one kind of cell. A cell made only of `#'` lines (knitr's spin
  convention for prose in R scripts) is text: rendered in Source Serif 4,
  folded, and opened for editing by clicking it. Typing `#'` and pressing
  Enter continues the next line with `#'`.
- A cell mixing `#'` lines and code is an error, as Pluto treats several
  expressions in one cell: nothing runs, and a button splits the cell at each
  change between text and code.
- **Inline values**: R Markdown's `` `r expr` `` works in `#'` lines. Each
  value is shown on a light accent tint (a trial; may be dropped). The tint
  must be background only, so copying gives plain text. A failing expression
  is a normal error: the error box replaces the text and the source opens
  below it.

## Outputs

(Board "Round 4 · Outputs".)

- Data frames: size in words ("32 rows × 11 columns"), column types under the
  names, row names in the interface font, values in mono, `NA` greyed, "Show
  N more rows" and "Show N more columns".
- Lists: a collapsible tree; long vectors show their first values and a count.
- Anything else: exactly what R prints, in mono, with no box.
- Console output below the code, as in Pluto, with no dark box: `message()`
  muted, cli/ANSI colours from a palette checked for contrast in both themes,
  warnings on an amber wash.
- **Figures** (board "Figure size: #| lines in the cell"): a fixed size that
  the window never changes, so what you see is the figure you would paste
  into slides. Default 7.5 × 5 in (3:2, the column width). A cell sets its own
  size with Quarto's comment lines, in inches:
  `#| fig-width: 8` and `#| fig-height: 4`. Ember draws at that size, shows a
  wider figure scaled to the column and a narrower one at its real size. No
  card or frame; plots in dark mode stay exactly as R draws them. No size
  label or copy/save buttons: the browser's right-click covers that. Plain
  `Rscript` ignores the `#|` lines; scripts use `ggsave()` for sized files.

## Header

(Board "Round 3 · Header and notebook controls".)

- Logo, file name (click: rename or move, see Notebooks), "Saved", "Run N not
  run" only while something can run, the R status as a button that opens
  Status, icons for Variables, Help and Packages (each opens the panel at that
  tab, or closes it), Export, and ⋯ (Keyboard shortcuts, Settings, Open
  another notebook). See Menus and Settings below.
- While R is busy: "Running 2 of 5 cells" and Stop.
- Safe preview is one banner with "Run this notebook", not a label on every
  cell.
- Restart R lives only in Status: restarting shouldn't become a habit.

## Side panel

(Board "Round 3 · Side panel tabs".)

- **Variables**: one table sorted alphabetically: Name, Type, Value. Clicking
  a name goes to the cell that defines it; that is the main use. No cell
  numbers (cells are identified by id, not position). Value shows real short
  values in normal text (R's formatting), Ember's description of common
  shapes in grey ("21 rows × 3 columns"), and R's one-line `str()` summary in
  grey italic for anything else. Variables from stale cells are greyed.
- **Help**: R's own help page for the symbol at the cursor (as now), with
  back/forward and search; description and arguments in serif, usage and
  examples in mono. For a function the notebook defines: its signature, its
  docstring, "Defined in a cell · Go to it", and its code folded below. The
  docstring is the `#` comment lines directly above a top-level
  `name <- function(...)` or `name <- \(x) ...` (also `=`), with no blank
  line between, written in Markdown. A blank line makes it an ordinary
  comment. It is a plain comment, so `Rscript` is unaffected; `#'` stays
  for text cells only.
- **Packages**: "Versions as of <date>" with an **Update** button (to
  today's snapshot; there is no date picker), the packages the notebook
  loads (dependencies hidden), and their status. A failed install shows a
  card naming the package and the real cause in one sentence, with
  **Update** ("Updating usually fixes this") and **Show the error**.
- **Status**: R's state, memory, version and uptime; Interrupt and Restart R;
  counts of not-run cells and errors with links; the autorun/lazy setting as
  "When a cell changes: rerun the cells that depend on it / mark them stale
  and let me run them".

## Menus and Settings

(Board "Round 6 · Export menu and Settings".)

- **Export** is a menu under the header's download icon: Download .R file
  ("The notebook itself. Runs with Rscript."), Download HTML ("One file with
  every output. Opens offline."), Print or save as PDF. In safe preview the
  menu says the HTML and PDF will have code but no outputs. It replaces the
  export banner; "Edit frontmatter" and "Start presentation" go (neither works
  in Ember today), as does the June message card.
- **Settings** (per browser; changes apply at once, no reload prompt):
  Theme (Match system / Light / Dark); Indent with (2 spaces, the default /
  4 spaces / Tab); Suggest completions as I type; Check spelling in text
  cells; Tab key in code (Indents / Moves focus); Ask before long runs
  (seconds, from the last run times); Notify me when a long run finishes;
  Reset to defaults. Removed: motivational stickers, the custom code font (a
  user can't know which fonts exist), and the Dark mode row without a
  control. Autorun or lazy belongs to the notebook file and stays in Status.

## Keyboard shortcuts

(Board "Round 6 · Keyboard shortcuts".)

An in-page sheet from the ⋯ menu, replacing today's alert(). It shows the
keys for the computer it's on (⌘ and ⌥ on a Mac).

- Running: Shift + Enter run; Ctrl + Enter run and add a cell below;
  Ctrl + S run every edited cell; Ctrl + Q stop (Ctrl on Mac too).
- Cells: Alt + ↑/↓ move; Ctrl + click a name to go to its definition;
  Ctrl + Shift + [ / ] hide or show code; Ctrl + C / V copy or paste selected
  cells; Backspace deletes selected cells.
- Editing: Ctrl + Space completions; Ctrl + ] / [ indent and outdent;
  Tab / Shift + Tab indent and outdent while the Tab setting is Indents;
  Ctrl + / comment; Ctrl + D next match; undo and redo; Enter on a `#'` line
  continues it.
- Moving around: Page Up / Down between cells; Esc leaves the code and keeps
  the cell selected; Esc then Tab to the next control.
- **F1 opens R help** for the name at the cursor in the side panel, as in
  RStudio (today it opens the shortcut list).
- Ctrl + M ("toggle markdown") is dropped: it is listed today but bound to
  nothing, and its text is repeated on the two fold lines.

## Accessibility

(Board "Round 6 · Accessibility".)

- One focus ring: 2 px accent outline, 2 px offset, on :focus-visible only.
  Nothing removes an outline without it (today the Help search box does).
- Keyboard path: a "Skip to the notebook" link; the header left to right;
  then cells. In a cell, Esc selects the cell (ringed); ↑/↓ move between
  cells, Enter edits, Tab reaches the run button, ⋯ and the "+" below. The
  side panel follows the last cell; Esc closes it and returns focus to its
  icon. Menus and dialogs take focus, use ↑/↓, Enter and Esc, and return
  focus to their button; dialogs keep Tab inside.
- Every icon button has a name matching its tooltip. Colour is never the only
  signal: a cell's name includes what it defines and its state ("Cell
  defining fit, error"), chips and errors carry words.
- One polite announcement when a run you started ends ("Finished: 3 cells",
  "fit: error"). Inline values read as plain text.
- Reduced motion: the running rail is solid, menus don't slide. 200% zoom
  without horizontal scrolling.
- Every alert() and confirm() becomes an in-page dialog.

## Wording

(Board "Round 6 · Wording", which lists each string's old and new text.)

- Words R users already use (R, traceback, package, Restart R); no Julia or
  Pluto terms (Pkg, Project.toml, binder, `begin ... end`).
- Sentence case; no shouting (UNDO), no "!!", no jokes in errors.
- What happened, then what to do, in one or two sentences.
- Buttons name their action (Delete, Run, Restart R), not Yes/No; toggles say
  what the click does (Hide code).
- Every string goes through the translation file. Unreachable Pluto strings
  (binder, pluto.land, Project.toml editor, language picker, AI helpers,
  rewriters for Julia-only error text) are deleted.

## Dark mode

Sage dark tokens throughout (board "Round 3 · Dark mode"). Rails, chips,
error boxes and the ANSI palette have dark variants. Figures are not themed.

## Notebooks

(Boards "Round 5 · Start page, compact", "Rename or move from the header".)

- Start page modelled on Pluto's, compact: small logo, one "My notebooks"
  list (New notebook, running notebooks with a stop button, recent ones with
  Forget), each row one line with the folder beside the name, and an "Open a
  file" field under the list.
- New notebook expands in place into a name and a folder and creates the file
  there. The folder defaults to where Ember was started. (Pluto's
  create-in-a-temporary-place-then-move was judged unintuitive.)
- Clicking the file name in the header opens Name and Folder to rename or
  move the .R file; the notebook stays open and R keeps running. The form
  warns that relative paths will resolve from the new folder.

## Engine and file-format changes this design needs

1. **Dependents of a failed cell run anyway**, as in Pluto, and error on
   their own; the page shows "Another cell defining x contains errors". A
   failed cell's variables are removed so the downstream error is reliable.
   Replaces today's blocked state (`blocked_by`, not_run_ids()).
2. **Text cells are inferred from content** (only `#'` lines) instead of the
   `[markdown]` flag on the cell header; files with the flag still read. A
   mixed cell is an error with a split action.
3. **Inline `` `r expr` ``** in text cells: evaluated in the worker, part of
   the dependency graph, rerun reactively; errors as normal cell errors.
4. **Fixed figure sizes**: the plot device is opened at the cell's `#|`
   size or the 7.5 × 5 in default; no re-render on window resize (only for
   pixel density). The file reader recognises `#|` lines.
5. **Notebooks from the browser**: create (name and folder), rename, move;
   a remembered list of recent notebooks with Forget.
6. **Packages**: Update to today's snapshot from the page; failed installs
   report the real error (today the log is empty; design-gaps.md).
7. **Variables**: the worker reports each global's type and a one-line value
   summary, and the engine knows which cell defines it.
8. **Disable cell**: a `disabled` flag per cell, kept in the cell-order
   footer (`disabled`, and `commented` for its dependents); their code
   written behind `## `; disabled cells left out of the definitions the
   graph resolves; the scheduler skipping them and their dependents.
9. **Function docstrings**: the comment block above a top-level function
   definition, read from the cell's source by the server for Help. No file
   format change.
