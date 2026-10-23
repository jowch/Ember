# Side panel

**Reach.** Header icons: `header#pluto-nav button[aria-label="Variables"]`,
"Packages", "Help"; or `window.dispatchEvent(new
CustomEvent("open_bottom_right_panel", { detail: "<tab>" }))`, the event
Endeavor's drawer sends. The panel (`#helpbox-wrapper`, `.open` when
shown) starts open at 1440 px wide and closed below; at narrow widths it
overlays the notebook.

**Drive.** Switch tabs with `getByRole("tab", { name })`. Help: type in
`#live-docs-search`. Variables: filter with `.ember-variables-filter
input`. Status: `#ember-status-restart`.

**End state.** The icon's `aria-pressed` matches the panel; the notebook
column doesn't jump when the panel opens at 1440; at 600-900 the panel
doesn't push controls off screen. Help pages render without console
errors.
