# UI checklist

What the e2e suite can't judge, checked by a person before a release, and
after a PR that changes layout or CSS. The automated part is
`tests/e2e/tests/ui-sweep.test.mjs` (generic layout rules at 600/900/1440
px, both shortcut labels, light and dark) plus the rest of `tests/e2e`;
this list is only what's left. It should take about 15 minutes. Note the
Ember commit and the environment, and open an issue for each failure.

`node tests/e2e/shots.mjs --run --dark --full` gives screenshots of the
sweep notebook to compare with the last release's, if you want a
starting point.

## In Endeavor's notebook pane

Linux (WebKitGTK) and macOS (WKWebView), the pane next to the chat at its
narrowest and widest.

- [ ] Open a 30-cell notebook with plots. Scrolling, adding a cell and
      typing feel immediate, with no visible pause (#289, #288).
- [ ] Edit a cell without running it: "Save all changes" and its
      shortcut are fully visible (#290).
- [ ] A wide table: "Show N more rows" is clickable with the overlay
      scrollbar showing (#286).
- [ ] Hide a cell's code and show it again from the same spot (#287).
- [ ] The drawer's Variables / Packages / Help open the matching tab.
- [ ] Light and dark follow the system setting, switching live.

## In a browser tab

Safari and Firefox, at full width and at about 700 px.

- [ ] Open, run, edit, add, delete and reload a notebook: nothing jumps,
      flickers, or moves twice (chips holding their space, #52, #139).
- [ ] Every cell that hasn't run says so, the first one included (#284).
- [ ] Menus, tooltips and dialogs open inside the window and close with
      Escape.

## Keyboard only

- [ ] Tab through the header, a cell, its menu and the side panel. Focus
      is always visible and never lost to `<body>`.
- [ ] The shortcuts sheet's shortcuts do what it says, on Mac and on
      Linux or Windows.

## Wording and look

- [ ] No "Pluto" or "Julia" anywhere, nothing left over from removed
      features, no untranslated keys (`t_...`).
- [ ] Errors and install failures say what happened and what to do next.
