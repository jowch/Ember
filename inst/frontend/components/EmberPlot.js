import { html, useRef, useEffect, useContext } from "../imports/Preact.js"
import { PlutoImage } from "./CellOutput.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"

/**
 * A plot image that re-renders at the page's width and pixel density
 * (ui-2.md, 3e). Wraps PlutoImage and watches its container's width with a
 * ResizeObserver, debounced 300ms. It asks for a render when the wanted
 * pixel width (round(width * devicePixelRatio)) differs from the image's
 * naturalWidth by more than 10%, and only while the tab is visible.
 *
 * It never asks because another tab's re-render changed the <img> alone:
 * a ResizeObserver only fires when the container's own box changes, not
 * when an image inside it is swapped, so two tabs of different widths
 * settle instead of taking turns forever.
 */
export const EmberPlot = ({ mime, body, cell_id, last_run_timestamp }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const container_ref = useRef(/** @type {HTMLElement?} */ (null))
    const requested_ref = useRef(/** @type {number?} */ (null))
    const last_run_ref = useRef(last_run_timestamp)

    const maybe_ask = () => {
        if (document.visibilityState !== "visible") return
        const container = container_ref.current
        if (container == null) return
        const img = container.querySelector("img")
        if (img == null) return
        const width = container.clientWidth
        if (width === 0) return
        const dpr = window.devicePixelRatio || 1
        const wanted_width = Math.round(width * dpr)
        const natural = img.naturalWidth
        if (natural === 0) return
        const diff = Math.abs(wanted_width - natural) / natural
        if (diff <= 0.1) return
        if (requested_ref.current === wanted_width) return
        requested_ref.current = wanted_width
        const aspect = img.naturalWidth === 0 ? 1 : img.naturalHeight / img.naturalWidth
        const wanted_height = Math.max(1, Math.round(wanted_width * aspect))
        pluto_actions.ember_render_plot(cell_id, wanted_width, wanted_height, 96 * dpr)
    }

    useEffect(() => {
        if (container_ref.current == null) return
        let timer = null
        const debounced = () => {
            if (timer != null) clearTimeout(timer)
            timer = setTimeout(maybe_ask, 300)
        }
        const observer = new ResizeObserver(debounced)
        observer.observe(container_ref.current)
        return () => {
            observer.disconnect()
            if (timer != null) clearTimeout(timer)
        }
    }, [cell_id])

    useEffect(() => {
        // A new run's image arrived: the size guard from the previous
        // image no longer applies, and this is worth a fresh check.
        if (last_run_timestamp !== last_run_ref.current) {
            last_run_ref.current = last_run_timestamp
            requested_ref.current = null
            setTimeout(maybe_ask, 0)
        }
    }, [last_run_timestamp])

    return html`<div ref=${container_ref} style="max-width: 100%;"><${PlutoImage} mime=${mime} body=${body} /></div>`
}
