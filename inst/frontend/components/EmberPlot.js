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
    // The res last asked for, while waiting on its reply; cleared once the
    // image's own density catches up (or a new, different res is wanted).
    // Not keyed by last_run_timestamp: a successful redraw bumps that
    // timestamp too (project_output()'s rendered_at), which would
    // otherwise re-arm a check against the still-loading new image.
    const pending_res_ref = useRef(/** @type {number?} */ (null))
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
        if (!img.complete) {
            img.addEventListener("load", maybe_ask, { once: true })
            return
        }
        const natural = img.naturalWidth
        if (natural === 0) return  // a failed/broken image: nothing to measure

        const dpr = Math.min(window.devicePixelRatio || 1, 4)
        const have = natural / (figure.width * 96)
        if (have >= dpr * 0.95) {
            pending_res_ref.current = null
            return
        }
        const want_res = Math.round(96 * dpr)
        if (pending_res_ref.current === want_res) return  // already asked; still waiting
        pending_res_ref.current = want_res
        // A static export (or any page not actually connected) has no real
        // pluto_actions.ember_render_plot to call: its client is a stub
        // with no send(), which throws rather than just doing nothing.
        // There's nothing to redraw to in that case anyway.
        try {
            pluto_actions?.ember_render_plot?.(cell_id, want_res)
        } catch (_e) {
            // not connected (a static export): nothing to ask.
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

    useEffect(() => {
        if (figure == null) return
        const on_visible = () => {
            if (document.visibilityState === "visible") maybe_ask()
        }
        document.addEventListener("visibilitychange", on_visible)
        return () => document.removeEventListener("visibilitychange", on_visible)
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [figure?.width, figure?.height])

    if (figure == null) {
        return html`<div><${PlutoImage} mime=${mime} body=${body} /></div>`
    }

    return html`<div ref=${container_ref}><${PlutoImage} mime=${mime} body=${body} /></div>`
}
