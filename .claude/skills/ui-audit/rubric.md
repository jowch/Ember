# UI rubric

What to look for in each screenshot and while exploring. Ember is a
reactive R notebook; its people are R users who may be new to notebooks,
and it often runs inside Endeavor's narrow WebKit pane next to a chat.

## Status and feedback
- Can you tell at a glance whether R is running, idle, stopped or
  starting (`#ember-r-status`), and which cells are running, queued,
  stale, errored or not run (chips)?
- Does every action show a response within about 100 ms (a pressed
  state, a spinner, a chip), even when the result takes longer?
- Is the save state clear ("Saved", "Save all changes")?

## Consistency
- Do cells in the same state look the same, the first and last cells
  included?
- Do light and dark show the same things, with readable contrast in
  both?
- Do ⌘ and Ctrl labels both fit, and do the shortcuts sheet and menus
  agree with what the keys do?
- Do similar controls (menus, dialogs, buttons) look and behave alike?

## Layout
- Nothing clipped, overlapping, off screen, or under a scrollbar; text
  doesn't overflow its box.
- No unexplained blank space; alignment along the cell column is clean.
- Nothing jumps: content stays put while cells run, outputs arrive and
  chips change (layout shift).
- At 600 and 900 px, every feature is still reachable.

## Errors and recovery
- Do error messages say what happened and what to do next, in R terms?
- Can destructive actions be undone, or are they confirmed?
- Can a person change code by accident (keys, drags, focus moves)?
- Does a failure (install, worker crash, lost connection) leave a clear
  way forward?

## Keyboard and accessibility
- Everything reachable with Tab; focus always visible; never lost to the
  page body; no trap without a stated way out.
- Every control has a name; images (plots) have text alternatives.
- Motion respects reduced-motion; nothing relies on hover alone.

## Speed
- Opening, adding a cell, typing and running feel immediate in a 30-50
  cell notebook with plots.

## Wording and identity
- Says Ember, never Pluto or Julia; no untranslated `t_...` keys.
- Plain, short, consistent words for the same thing everywhere.

## Endeavor
- Works at the pane's widths, in WebKit, with the events Endeavor sends
  (`open_bottom_right_panel`), and with overlay scrollbars.
