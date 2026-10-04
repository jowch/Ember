import { html, useLayoutEffect, useRef } from "../imports/Preact.js"
import { ansi_to_html } from "../imports/AnsiUp.js"
import { t, th } from "../common/lang.js"

const LOGS_VISIBLE_START = 60
const LOGS_VISIBLE_END = 20

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

export const Logs = ({ logs, line_heights, set_cm_highlighted_line, sanitize_html }) => {
    if (logs.length === 0) return null
    const entries = group_logs(logs)
    const line = (entry) => html`<${LogLine} key=${entry.id} entry=${entry} />`

    return html`
        <pluto-logs-container>
            <pluto-logs>
                ${entries.length <= LOGS_VISIBLE_END + LOGS_VISIBLE_START
                    ? entries.map(line)
                    : [
                          ...entries.slice(0, LOGS_VISIBLE_START).map(line),
                          html`<pluto-log-truncated>${t("t_logs_truncated", { count: entries.length - LOGS_VISIBLE_START - LOGS_VISIBLE_END })}</pluto-log-truncated>`,
                          ...entries.slice(-LOGS_VISIBLE_END).map(line),
                      ]}
            </pluto-logs>
        </pluto-logs-container>
    `
}
