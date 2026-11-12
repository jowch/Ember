// htmlwidgets resizes a widget only on the window's "resize" event. A widget's
// box can change without one: a host that restyles the page after the outputs
// drew (Endeavor's notebook view in Claude's desktop app narrows the column),
// or a scrollbar appearing. plotly then stays at the width it drew at, wider
// than its box. Each widget's box is watched instead, and a change in its size
// is passed on as one "resize" event, which htmlwidgets hands to each widget
// whose size changed. Every other "resize" listener on the window hears it too,
// as it would hear a real one.

/** @type {WeakMap<Element, string>} */
const sizes = new WeakMap()
let timer = /** @type {any} */ (null)

const observer =
    typeof ResizeObserver === "function"
        ? new ResizeObserver((entries) => {
              let changed = false
              for (const entry of entries) {
                  if (!entry.target.isConnected) {
                      observer?.unobserve(entry.target)
                      continue
                  }
                  const size = `${Math.round(entry.contentRect.width)}x${Math.round(entry.contentRect.height)}`
                  // The first report of a box is the size it drew at.
                  if (sizes.has(entry.target) && sizes.get(entry.target) !== size) changed = true
                  sizes.set(entry.target, size)
              }
              if (changed && timer == null) {
                  timer = setTimeout(() => {
                      timer = null
                      window.dispatchEvent(new Event("resize"))
                  }, 100)
              }
          })
        : null

/** Watch the htmlwidgets in `container` (after its scripts ran). */
export const watch_widget_sizes = (/** @type {Element} */ container) => {
    if (observer == null) return
    for (const el of container.querySelectorAll(".html-widget")) observer.observe(el)
}
