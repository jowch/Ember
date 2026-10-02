import { ansi_to_html } from "../imports/AnsiUp.js"
import { html, useEffect, useRef } from "../imports/Preact.js"

export const IoniconButton = ({ icon, ...kwargs }) => {
    return html`<button ...${kwargs} data-icon=${icon} class="ionicon-icon-button"></button>`
}

const make_spinner_spin = (original_html) => original_html.replaceAll("◐", `<span class="make-me-spin">◐</span>`)

// `hide_button`'s "open in full screen" used to open BigPkgTerminal, a
// dialog with the same text at a bigger size. Ember's Packages tab
// (PackagesTab.js) now shows install progress with more detail than that
// dialog did, so the button (and BigPkgTerminal) are gone; every caller
// here passes `hide_button = true`.
const TerminalViewAnsiUp = ({ value, hide_button = true }) => {
    const node_ref = useRef(/** @type {HTMLElement?} */ (null))

    const start_time = useRef(Date.now())

    useEffect(() => {
        if (!node_ref.current) return
        node_ref.current.style.cssText = `--animation-delay: -${(Date.now() - start_time.current) % 1000}ms`
        node_ref.current.innerHTML = make_spinner_spin(ansi_to_html(value))
        const parent = node_ref.current.parentElement
        if (parent) parent.scrollTop = 1e5
    }, [node_ref.current, value])

    return !!value
        ? html`<pkg-terminal dir="ltr">
              <div class="scroller" tabindex="0"><pre ref=${node_ref} class="pkg-terminal"></pre></div></pkg-terminal
          >`
        : null
}

export const PkgTerminalView = TerminalViewAnsiUp
