import { html, useEffect, useMemo, useState } from "../imports/Preact.js"
import _ from "../imports/lodash-es.js"

import { t } from "../common/lang.js"
import { cl } from "../common/ClassTable.js"
import { PlayIcon } from "../common/Icons.js"
import { useSettled, wait_for_on } from "../common/useSettled.js"

/**
 * The code box's run/stop button (ui-3.md, "Run button"). A 26 px accent
 * circle with a play icon; while the cell runs or is queued it becomes a
 * rail-blue stop square. Not rendered by the caller for a disabled cell or
 * one that depends on a disabled cell -- there is nothing here to run.
 */
export const RunButton = ({ running, queued, runtime, on_run, on_interrupt }) => {
    const local_time_running_ms = useMillisSinceTruthy(running)
    const local_time_running_ns = local_time_running_ms == null ? null : 1e6 * local_time_running_ms
    const busy = useSettled(running || queued, wait_for_on)
    const shown_ns = running && busy ? (local_time_running_ns ?? runtime) : runtime

    return html`
        <button
            class=${cl({ "ember-run": true, busy })}
            onClick=${busy ? on_interrupt : on_run}
            title=${busy ? t("t_stop_cell") : t("t_run_cell")}
            aria-label=${busy ? t("t_stop_cell") : t("t_run_cell")}
        >
            ${busy ? html`<span class="ember-run-stop"></span>` : html`<${PlayIcon} size=${12} />`}
        </button>
        ${shown_ns == null ? null : html`<ember-runtime>${format_runtime(shown_ns)}</ember-runtime>`}
    `
}

/**
 * The run-time chip's text (ui-3.md, "Run-time chip"): "0.04 s" under a
 * minute, "1 min 3 s" at or above it. Exported for the e2e test.
 */
export const format_runtime = (time_ns) => {
    const total_s = time_ns / 1e9
    if (total_s < 9.995) return `${total_s.toFixed(2)} s`
    const whole_s = Math.round(total_s)
    if (whole_s < 60) return `${whole_s} s`
    const mins = Math.floor(whole_s / 60)
    const secs = whole_s % 60
    return secs === 0 ? `${mins} min` : `${mins} min ${secs} s`
}

const update_interval = 50
/**
 * Returns the milliseconds passed since the argument became truthy.
 * If argument is falsy, returns undefined.
 *
 * @param {boolean} truthy
 */
export const useMillisSinceTruthy = (truthy) => {
    const [now, setNow] = useState(0)
    const [startRunning, setStartRunning] = useState(0)
    useEffect(() => {
        let interval
        if (truthy) {
            const now = +new Date()
            setStartRunning(now)
            setNow(now)
            interval = setInterval(() => setNow(+new Date()), update_interval)
        }
        return () => {
            interval && clearInterval(interval)
        }
    }, [truthy])
    return truthy ? now - startRunning : undefined
}

export const useDebouncedTruth = (truthy, delay = 5) => {
    const [mytruth, setMyTruth] = useState(truthy)
    const setMyTruthAfterNSeconds = useMemo(() => _.debounce(setMyTruth, delay * 1000), [setMyTruth])
    useEffect(() => {
        if (truthy) {
            setMyTruth(true)
            setMyTruthAfterNSeconds.cancel()
        } else {
            setMyTruthAfterNSeconds(false)
        }
        return () => {}
    }, [truthy])
    return mytruth
}
