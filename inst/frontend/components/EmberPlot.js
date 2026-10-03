import { html, useRef, useEffect, useState, useContext } from "../imports/Preact.js"
import { PlutoImage } from "./CellOutput.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"

/**
 * A plot image at a fixed size (ui-3.md: figures never change with the
 * window). `figure` (inches, from `cell_results[id].ember.figure`) sets
 * the `<img>`'s CSS size directly; the image scales down, never up, below
 * that width. The only redraw this component ever asks for is a higher
 * pixel density than the current image has -- never a resize.
 *
 * Without `figure` (an older export, or an `image/png` from `knit_print`)
 * it renders a plain `PlutoImage`, with no size or density logic.
 */
export const EmberPlot = ({ mime, body, cell_id, last_run_timestamp, figure }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const container_ref = useRef(/** @type {HTMLElement?} */ (null))
    const checked_ref = useRef(/** @type {string?} */ (null))
    const [dpr_tick, set_dpr_tick] = useState(0)

    const maybe_ask = () => {
        if (figure == null) return
        const container = container_ref.current
        if (container == null) return
        const img = container.querySelector("img")
        if (img == null) return
        img.style.width = `${figure.width * 96}px`
        img.style.maxWidth = "100%"
        img.style.height = "auto"

        if (document.visibilityState !== "visible") return
        const natural = img.naturalWidth
        if (natural === 0) {
            img.addEventListener("load", maybe_ask, { once: true })
            return
        }
        const dpr = Math.min(window.devicePixelRatio || 1, 4)
        const key = `${last_run_timestamp}:${dpr}`
        if (checked_ref.current === key) return
        checked_ref.current = key
        const have = natural / (figure.width * 96)
        if (have < dpr * 0.95) {
            pluto_actions.ember_render_plot(cell_id, Math.round(96 * dpr))
        }
    }

    useEffect(() => {
        maybe_ask()
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [last_run_timestamp, figure?.width, figure?.height])

    useEffect(() => {
        if (figure == null) return
        const dpr = window.devicePixelRatio || 1
        const mq = matchMedia(`(resolution: ${dpr}dppx)`)
        const on_change = () => {
            maybe_ask()
            // The threshold above is fixed at the dpr it was created with;
            // re-register against the new one so a later change is still seen.
            set_dpr_tick((t) => t + 1)
        }
        mq.addEventListener("change", on_change)
        return () => mq.removeEventListener("change", on_change)
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [figure?.width, figure?.height, dpr_tick])

    if (figure == null) {
        return html`<div><${PlutoImage} mime=${mime} body=${body} /></div>`
    }

    return html`<div ref=${container_ref}><${PlutoImage} mime=${mime} body=${body} /></div>`
}
