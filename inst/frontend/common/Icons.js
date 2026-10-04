import { html } from "../imports/Preact.js"

/**
 * Inline SVG icons for the header and the side panel (ui-3.md's Header and
 * Round 3 "Header and notebook controls" board): `stroke="currentColor"`,
 * so each one takes the button's text colour, no separate light/dark
 * assets.
 */

export const FlameLogo = ({ size = 22 }) => html`
    <svg width=${size} height=${size} viewBox="5 4 90 90" aria-hidden="true">
        <g fill="var(--ember-logo)" transform="translate(-5.5 0.5)">
            <path
                fill-rule="evenodd"
                d="M50 92 C34 92 24 81 24 66 C24 54 31 46 36 34 C42 42 43 50 42 56 C48 46 50 30 57 11 C62 24 77 40 76 64 C76 80 66 92 50 92 Z M49 85 C41 84 38 78 41 71 C44 64 52 60 50 50 C59 57 62 66 59 74 C57 80 55 85 49 85 Z"
            ></path>
            <circle cx="71" cy="25" r="3.4"></circle>
            <circle cx="79" cy="17" r="2.6"></circle>
            <circle cx="85" cy="9" r="2.0"></circle>
        </g>
    </svg>
`

const icon = (size, body) => html`
    <svg width=${size} height=${size} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" aria-hidden="true">${body}</svg>
`

export const VariablesIcon = ({ size = 18 }) => icon(size, html`<path d="M4 6h16M4 12h16M4 18h10"></path>`)

export const HelpIcon = ({ size = 18 }) => icon(
    size,
    html`<circle cx="12" cy="12" r="9"></circle><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.6V14M12 17.5v.01"></path>`
)

export const PackagesIcon = ({ size = 18 }) => icon(
    size,
    html`<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"></path><path d="M12 12l8-4.5M12 12v9M12 12L4 7.5"></path>`
)

export const ExportIcon = ({ size = 18 }) => icon(size, html`<path d="M12 4v11M7 10l5 5 5-5M5 20h14"></path>`)

export const SidePanelIcon = ({ size = 18 }) => icon(size, html`<rect x="3" y="4" width="18" height="16" rx="2"></rect><path d="M3 14h18"></path>`)

export const BackIcon = ({ size = 16 }) => icon(size, html`<path d="M15 6l-6 6 6 6"></path>`)
export const ForwardIcon = ({ size = 16 }) => icon(size, html`<path d="M9 6l6 6-6 6"></path>`)

export const MoreIcon = ({ size = 18 }) => html`
    <svg width=${size} height=${size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
        <circle cx="5" cy="12" r="1.8"></circle><circle cx="12" cy="12" r="1.8"></circle><circle cx="19" cy="12" r="1.8"></circle>
    </svg>
`

// components/RunButton.js's play icon (ui-3-plan.md 6.2).
export const PlayIcon = ({ size = 13 }) => html`
    <svg width=${size} height=${size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
        <path d="M6 4l15 8-15 8z"></path>
    </svg>
`

// Cell chip icons (ui-3-plan.md 6.3): not-run (circle), stale (clock),
// disabled (slashed circle).
export const CircleIcon = ({ size = 12 }) => icon(size, html`<circle cx="12" cy="12" r="8"></circle>`)

export const ClockIcon = ({ size = 12 }) => icon(size, html`<circle cx="12" cy="12" r="8"></circle><path d="M12 8v4l3 2"></path>`)

export const SlashCircleIcon = ({ size = 12 }) => icon(size, html`<circle cx="12" cy="12" r="8"></circle><path d="M7 7l10 10"></path>`)
