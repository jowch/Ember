import { html, useLayoutEffect, useMemo, useRef, useState } from "../imports/Preact.js"
import { ansi_to_html } from "../imports/AnsiUp.js"
import { t, th } from "../common/lang.js"

// The console shows its first 60 and last 20 lines, as Pluto shows its first
// 60 and last 20 logs; a line is a message, a warning or one line of stdout.
// "Show more" reveals the hidden middle 500 lines at a time, so the page only
// holds a long console when someone asks for it (#350).
const LOGS_VISIBLE_START = 60
const LOGS_VISIBLE_END = 20
const LOGS_SHOW_MORE_STEP = 500

const STDOUT_LOG_LEVEL = "LogLevel(-555)"
const ANSI_PATTERN = /\x1b\[[0-9;]*m/

const kind_of = (log) => (log.level === STDOUT_LOG_LEVEL ? "stdout" : log.level === "Warn" ? "warning" : "message")

const text_of = (log) => {
    const [body, mime] = log.msg ?? []
    return mime === "text/plain" || typeof body === "string" ? String(body ?? "") : ""
}

/** Consecutive stdout entries joined into one, so an ANSI style that spans two writes stays whole. */
const group_logs = (logs) =>
    logs.reduce((grouped, log) => {
        const kind = kind_of(log)
        const last = grouped[grouped.length - 1]
        if (kind === "stdout" && last?.kind === "stdout") {
            last.text += text_of(log)
        } else {
            grouped.push({ id: log.id, kind, text: text_of(log), call: log.ember?.call ?? null })
        }
        return grouped
    }, [])

/** One row per message or warning and one per line of stdout, so a long print is cut like many messages are. */
const rows_of = (entries) =>
    entries.flatMap((entry) =>
        entry.kind === "stdout"
            ? entry.text
                  .replace(/\n$/, "")
                  .split("\n")
                  .map((text, i) => ({ id: `${entry.id}:${i}`, kind: "stdout", text, call: null }))
            : [entry]
    )

/** Consecutive stdout rows joined back into one entry, so a run of lines is one block, as before the cut. */
const join_stdout = (rows) =>
    rows.reduce((joined, row) => {
        const last = joined[joined.length - 1]
        if (row.kind === "stdout" && last?.kind === "stdout") {
            last.text += `\n${row.text}`
        } else {
            joined.push({ ...row })
        }
        return joined
    }, [])

const AnsiText = ({ text }) => {
    const node_ref = useRef(/** @type {HTMLElement?} */ (null))
    useLayoutEffect(() => {
        if (node_ref.current) node_ref.current.innerHTML = ansi_to_html(text)
    }, [text])
    return html`<span ref=${node_ref}></span>`
}

const LogLine = ({ entry }) => {
    const text = entry.text.replace(/\n$/, "")
    if (entry.kind === "warning") {
        const warning = html`<b>${t("t_warning_word")}</b>`
        const message = html`<${AnsiText} text=${text} />`
        return html`<ember-log class="warning"
            >${entry.call == null ? th("t_warning", { warning, message }) : th("t_warning_in", { warning, call: html`<code>${entry.call}</code>`, message })}</ember-log
        >`
    }
    const styled = entry.kind === "message" && ANSI_PATTERN.test(text)
    return html`<ember-log class=${styled ? `${entry.kind} styled` : entry.kind}><${AnsiText} text=${text} /></ember-log>`
}

/**
 * `run` changes when the cell starts or finishes a run (Cell.js passes
 * "running" or the last run's timestamp): the console starts over, so the
 * cut does too. A fast run may never be seen as running, hence the timestamp.
 */
export const Logs = ({ logs, run = null, line_heights, set_cm_highlighted_line, sanitize_html }) => {
    const rows = useMemo(() => rows_of(group_logs(logs)), [logs])
    // Lines revealed by "Show more", on top of the first LOGS_VISIBLE_START.
    const [revealed, set_revealed] = useState(0)
    useLayoutEffect(() => set_revealed(0), [run])

    if (logs.length === 0) return null
    const line = (entry) => html`<${LogLine} key=${entry.id} entry=${entry} />`
    const head = LOGS_VISIBLE_START + revealed
    const hidden = rows.length - head - LOGS_VISIBLE_END

    return html`
        <pluto-logs-container>
            <pluto-logs>
                ${hidden <= 0
                    ? join_stdout(rows).map(line)
                    : [
                          ...join_stdout(rows.slice(0, head)).map(line),
                          html`<pluto-log-truncated key="truncated"
                              >${t("t_logs_truncated", { count: hidden })}
                              <button type="button" class="ember-show-more" onClick=${() => set_revealed((n) => n + LOGS_SHOW_MORE_STEP)}>
                                  ${t("t_show_more_items", { count: Math.min(hidden, LOGS_SHOW_MORE_STEP) })}
                              </button></pluto-log-truncated
                          >`,
                          ...join_stdout(rows.slice(-LOGS_VISIBLE_END)).map(line),
                      ]}
            </pluto-logs>
        </pluto-logs-container>
    `
}
