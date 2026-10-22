/**
 * Keeps what the reader is looking at still while the notebook changes
 * size above it: outputs landing during a run, "Not run yet" chips going
 * away, the safe-preview banner leaving. The page turns the browser's own
 * scroll anchoring off (editor.css, `overflow-anchor: none`, kept from
 * Pluto, and WebKit doesn't do it everywhere), so this does the same job
 * in script, for the case Pluto's own compensation (CellOutput.js)
 * doesn't cover: no cell has focus.
 *
 * The anchor is a part of a cell (its output, code or console) near the
 * top of the view, under the sticky header (see choose()).
 * When something resizes, a ResizeObserver runs after layout and before
 * paint; if the anchor has moved and the reader hasn't scrolled, the page
 * scrolls by the same amount, so the frame paints with the anchor where it
 * was. At the very top of the page nothing is anchored, as browsers do:
 * there, what's above is what the reader is looking at.
 */
export const keep_view_anchored = () => {
    /** @type {{ cell: Element, part: string?, top: number, scroll_y: number }?} */
    let anchor = null

    const header_bottom = () => document.querySelector("header#pluto-nav")?.getBoundingClientRect().bottom ?? 0
    const cell_focused = () => document.querySelector("pluto-cell:focus-within") != null

    // A cell's parts, top to bottom, that can hold what the reader is
    // looking at. Its chip and notes come and go, so they never anchor.
    const PARTS = ["pluto-output", "pluto-input", "pluto-logs-container"]

    // The anchor is the first part that starts in view, or that reaches the
    // middle of the view (a tall output you've scrolled into). A sliver
    // peeking out from under the header isn't what the reader is looking
    // at, and anchoring on it lets the next part move.
    const choose = () => {
        anchor = null
        if (window.scrollY <= 0) return
        const line = header_bottom()
        const middle = (line + window.innerHeight) / 2
        /** @type {typeof anchor} */
        let fallback = null
        for (const cell of document.querySelectorAll("pluto-notebook > pluto-cell")) {
            const c = cell.getBoundingClientRect()
            if (c.bottom <= line) continue
            if (c.top >= window.innerHeight) break
            let found = false
            for (const part of cell.children) {
                if (!PARTS.includes(part.localName)) continue
                const r = part.getBoundingClientRect()
                if (r.height === 0 || r.bottom <= line) continue
                found = true
                const candidate = { cell, part: part.localName, top: r.top, scroll_y: window.scrollY }
                if (r.top >= line || r.bottom >= middle) {
                    anchor = candidate
                    return
                }
                fallback ??= candidate
            }
            // A cell with no part showing (its gap, its "+" button): the cell.
            if (!found) fallback ??= { cell, part: null, top: c.top, scroll_y: window.scrollY }
        }
        anchor = fallback
    }

    // The part is found again by name: a cell can swap its editor element
    // (the static stand-in for the real one) while it runs.
    const anchor_element = () =>
        anchor == null || !anchor.cell.isConnected ? null : anchor.part == null ? anchor.cell : anchor.cell.querySelector(`:scope > ${anchor.part}`)

    const on_resize = () => {
        const el = anchor_element()
        if (anchor != null && el != null && !cell_focused() && window.scrollY === anchor.scroll_y) {
            const moved = el.getBoundingClientRect().top - anchor.top
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
