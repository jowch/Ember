import { useEffect, useRef, useState } from "../imports/Preact.js"

/** How long a passing state must last before the page shows it. */
export const SETTLE_MS = 250

/**
 * `value` as it should be shown, given that some changes are passing states
 * (queued, running, "Not run yet", "Run N not run", ...) that a quick run
 * goes through in a few milliseconds. A change for which
 * `wait(value, shown)` is true is shown only once the value has differed
 * from the shown one for `delay` ms without a change that doesn't wait;
 * until then the last shown value stays. Any other change shows at once.
 * The first value shows at once.
 *
 * @template T
 * @param {T} value
 * @param {(value: T, shown: T) => boolean} wait
 * @param {number} [delay]
 * @returns {T}
 */
export const useSettled = (value, wait, delay = SETTLE_MS) => {
    const shown = useRef(value)
    const pending_since = useRef(/** @type {number?} */ (null))
    const [, rerender] = useState(0)

    if (Object.is(value, shown.current) || !wait(value, shown.current)) {
        shown.current = value
        pending_since.current = null
    } else if (pending_since.current == null) {
        pending_since.current = performance.now()
        // A timer can fire a fraction of a millisecond before
        // performance.now() agrees the delay has passed; the 1 ms slack
        // keeps that from needing a second timer.
    } else if (performance.now() - pending_since.current >= delay - 1) {
        shown.current = value
        pending_since.current = null
    }

    const since = pending_since.current
    useEffect(() => {
        if (since == null) return
        const timer = setTimeout(() => rerender((n) => n + 1), Math.max(0, delay - (performance.now() - since)))
        return () => clearTimeout(timer)
    }, [since, delay])

    return shown.current
}

/** Waits when a flag turns on; shows it turning off at once. */
export const wait_for_on = (/** @type {boolean} */ value, /** @type {boolean} */ shown) => value && !shown
