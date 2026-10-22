/**
 * Keeps what the reader is looking at still while the notebook changes
 * size above it: outputs landing during a run, "Not run yet" chips going
 * away, the safe-preview banner leaving. The page turns the browser's own
 * scroll anchoring off (editor.css, `overflow-anchor: none`, kept from
 * Pluto, and WebKit doesn't do it everywhere), so this does the same job
 * in script, for the case Pluto's own compensation (CellOutput.js)
 * doesn't cover: no cell has focus.
 *
 * The anchor is the first cell still showing under the sticky header.
 * When something resizes, a ResizeObserver runs after layout and before
 * paint; if the anchor has moved and the reader hasn't scrolled, the page
 * scrolls by the same amount, so the frame paints with the anchor where it
 * was. At the very top of the page nothing is anchored, as browsers do:
 * there, what's above is what the reader is looking at.
 */
export const keep_view_anchored = () => {
    /** @type {{ el: Element, top: number, scroll_y: number }?} */
    let anchor = null

    const header_bottom = () => document.querySelector("header#pluto-nav")?.getBoundingClientRect().bottom ?? 0
    const cell_focused = () => document.querySelector("pluto-cell:focus-within") != null

    const choose = () => {
        anchor = null
        if (window.scrollY <= 0) return
        const line = header_bottom()
        for (const cell of document.querySelectorAll("pluto-notebook > pluto-cell")) {
            const r = cell.getBoundingClientRect()
            if (r.bottom > line) {
                anchor = { el: cell, top: r.top, scroll_y: window.scrollY }
                return
            }
        }
    }

    const on_resize = () => {
        if (anchor != null && anchor.el.isConnected && !cell_focused() && window.scrollY === anchor.scroll_y) {
            const moved = anchor.el.getBoundingClientRect().top - anchor.top
            if (Math.abs(moved) >= 0.5) window.scrollBy(0, moved)
        }
        choose()
    }

    const observer = new ResizeObserver(on_resize)
    observer.observe(document.body)
    const watch_notebook = () => {
        const notebook = document.querySelector("pluto-notebook")
        if (notebook == null) return false
        observer.observe(notebook)
        return true
    }
    if (!watch_notebook()) {
        const wait = new MutationObserver(() => watch_notebook() && wait.disconnect())
        wait.observe(document.body, { childList: true, subtree: true })
    }
    // A scroll event comes a frame after the scroll. One from our own
    // scrollBy finds the anchor already recorded, and choosing again then
    // would take a layout that changed since as the new normal.
    window.addEventListener("scroll", () => anchor?.scroll_y === window.scrollY || choose(), { passive: true })
    choose()
}
