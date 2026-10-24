import { html, useContext, useEffect, useState } from "../imports/Preact.js"
import { PlutoActionsContext, PlutoBondsContext } from "../common/PlutoContext.js"
import { t } from "../common/lang.js"

/**
 * A cell's inputs (docs/inputs.md): the widgets of the `input_*()` calls its
 * last run made, in order. A bound input's value is
 * `bonds[name].value`, which the page changes itself with `set_bond` as the
 * widget moves and the server sets with `set_input()`; Pluto's page holds
 * new values back while cells run and sends only the latest. A dropdown's
 * or radio's value is the 0-based position of its choice (a list of them
 * for a multiple dropdown), since a choice may be any R object.
 *
 * Every widget is disabled while the cell is stale, edited,
 * queued or running (`input.disabled`, from the server), and when the page
 * can't change the notebook (`disabled`: an HTML export, or no
 * connection). A value off its default is marked: `Rscript` would give
 * different results. When the worker refused the page's last value, the
 * bond carries its message (`bonds[name].error`), shown under the widget.
 *
 * Where they go follows the cell's output rule: the bound input on the
 * cell's last line (`input.output`) is the cell's output, the one widget
 * in the output area (`place = "output"`). The others aren't output, so
 * they go below the cell as read-only lines (`n = 8 (slider)`), each with
 * the note that says how to make it movable: interactive widgets anywhere
 * but the output area would confuse (Jonathan, 2026-10-24). `place =
 * "below"` draws those; `"all-below"` draws every input that way, for a
 * run that failed and whose output is its error.
 *
 * @param {{
 *  cell_id: string,
 *  inputs: Array<Record<string, any>>,
 *  place: "output" | "below" | "all-below",
 *  disabled: boolean,
 * }} props
 */
export const CellInputs = ({ cell_id, inputs, place, disabled }) => {
    const bonds = useContext(PlutoBondsContext)
    const pluto_actions = useContext(PlutoActionsContext)
    const here = (input) => (place === "output" ? input.output : place === "below" ? !input.output : true)
    return html`<ember-inputs class=${place === "output" ? "output" : "below"}>
        ${inputs.map((input, i) => {
            // The position in the whole list names a radio group, so it stays the same wherever the input is drawn.
            if (!here(input)) return null
            const bond = input.bound && input.name != null ? bonds?.[input.name] : null
            const value = bond != null ? bond.value : input.bound ? input.value : input.default
            if (place !== "output") return html`<${ReadOnlyRow} key=${`${i}-${input.name ?? ""}`} input=${input} value=${value} />`
            const send = (v) => {
                if (input.bound && input.name != null) pluto_actions.set_bond(input.name, v)
            }
            return html`<${InputRow}
                key=${`${i}-${input.name ?? ""}`}
                group=${`ember-input-${cell_id}-${i}`}
                input=${input}
                value=${value}
                error=${bond?.error ?? null}
                send=${send}
                disabled=${disabled || input.disabled}
            />`
        })}
    </ember-inputs>`
}

const shown = (input, v) => {
    if (input.type === "list") return `list(${(input.parts ?? []).map((p) => `${p.name} = ${shown(p, v?.[p.name])}`).join(", ")})`
    if (input.type === "select" || input.type === "radio") {
        const pick = Array.isArray(v) ? v : v == null ? [] : [v]
        return pick.map((k) => input.labels?.[k] ?? "").join(", ")
    }
    if (typeof v === "boolean") return v ? "TRUE" : "FALSE"
    if (typeof v === "string") return JSON.stringify(v)
    return String(v)
}

const same = (a, b) => (Array.isArray(a) && Array.isArray(b) ? a.length === b.length && a.every((x, k) => x === b[k]) : a === b)

const ChangedMark = ({ input }) =>
    html`<span class="ember-input-changed" title=${t("t_input_changed", { value: shown(input, input.default) })}>${t("t_input_changed_short")}</span>`

/** The cell's output: the one movable widget, or for `input_list()` each of its parts' widgets. */
const InputRow = ({ group, input, value, error, send, disabled }) => {
    if (input.type === "list") return html`<${ListRow} group=${group} input=${input} value=${value} error=${error} send=${send} disabled=${disabled} />`
    const changed = !same(value, input.default)
    const label = input.label ?? input.name ?? input.type
    return html`<ember-input class=${`${input.type}${changed ? " changed" : ""}`}>
        <${Widget} group=${group} input=${input} label=${label} value=${value} send=${send} disabled=${disabled} />
        ${changed ? html`<${ChangedMark} input=${input} />` : null}
        ${error != null ? html`<span class="ember-input-error" role="alert">${error}</span>` : null}
    </ember-input>`
}

/**
 * `input_list()`: one widget per part, in order, each labelled by its own
 * label or name. Moving one sends the whole list with that part changed,
 * since the list is one input with one value. A part off its default is
 * marked on its own row.
 */
const ListRow = ({ group, input, value, error, send, disabled }) => {
    const parts = input.parts ?? []
    return html`<ember-input class="list">
        ${parts.map((part, k) => {
            const v = value?.[part.name]
            const changed = !same(v, input.default?.[part.name])
            return html`<ember-input class=${`${part.type}${changed ? " changed" : ""}`} key=${part.name}>
                <${Widget}
                    group=${`${group}-${k}`}
                    input=${part}
                    label=${part.label ?? part.name}
                    value=${v}
                    send=${(x) => send({ ...value, [part.name]: x })}
                    disabled=${disabled}
                />
                ${changed ? html`<${ChangedMark} input=${{ ...part, default: input.default?.[part.name] }} />` : null}
            </ember-input>`
        })}
        ${error != null ? html`<span class="ember-input-error" role="alert">${error}</span>` : null}
    </ember-input>`
}

/** An input that isn't the cell's output: its value as text, and why it can't be moved here. */
const ReadOnlyRow = ({ input, value }) => {
    const changed = input.bound && !same(value, input.default)
    const note = !input.bound
        ? input.reason === "read_elsewhere"
            ? t("t_input_read_elsewhere", { name: input.name })
            : t("t_input_not_assigned")
        : t("t_input_not_output")
    return html`<ember-input class=${`${input.type} read-only${input.bound ? "" : " unbound"}${changed ? " changed" : ""}`}>
        <span class="ember-input-line"
            ><code>${input.name ?? input.label ?? "input"} = ${shown(input, value)}</code> <span class="ember-input-type">(${input.type})</span></span
        >
        ${changed ? html`<${ChangedMark} input=${input} />` : null}
        <span class="ember-input-note">${note}</span>
    </ember-input>`
}

const Widget = ({ group, input, label, value, send, disabled }) => {
    switch (input.type) {
        case "slider":
            return html`<label>
                <span class="ember-input-label">${label}</span>
                <input
                    type="range"
                    min=${input.min}
                    max=${input.max}
                    step=${input.step ?? (input.integer ? 1 : "any")}
                    value=${value}
                    disabled=${disabled}
                    onInput=${(e) => send(Number(e.target.value))}
                />
                <output>${shown(input, value)}</output>
            </label>`
        case "number":
            return html`<${NumberWidget} input=${input} label=${label} value=${value} send=${send} disabled=${disabled} />`
        case "checkbox":
            return html`<label>
                <input type="checkbox" checked=${value === true} disabled=${disabled} onChange=${(e) => send(e.target.checked)} />
                <span class="ember-input-label">${label}</span>
            </label>`
        case "text":
            return html`<${TextWidget} label=${label} value=${value} send=${send} disabled=${disabled} />`
        case "select":
            return html`<label>
                <span class="ember-input-label">${label}</span>
                <select
                    multiple=${input.multiple}
                    disabled=${disabled}
                    onChange=${(e) => {
                        const picked = Array.from(e.target.selectedOptions, (o) => Number(o.value))
                        send(input.multiple ? picked : picked[0])
                    }}
                >
                    ${(input.labels ?? []).map((l, k) => {
                        const on = Array.isArray(value) ? value.includes(k) : value === k
                        return html`<option value=${k} selected=${on}>${l}</option>`
                    })}
                </select>
            </label>`
        case "radio":
            return html`<fieldset disabled=${disabled}>
                <legend class="ember-input-label">${label}</legend>
                ${(input.labels ?? []).map(
                    (l, k) =>
                        html`<label>
                            <input type="radio" name=${group} checked=${value === k} onChange=${() => send(k)} />
                            <span>${l}</span>
                        </label>`
                )}
            </fieldset>`
        default:
            return null
    }
}

/** `round()` as R does it: a half goes to the even neighbour (IEC 60559), so 10.5 is 10. */
const round_r = (x) => {
    const f = Math.floor(x)
    const d = x - f
    return d > 0.5 || (d === 0.5 && f % 2 !== 0) ? f + 1 : f
}

/**
 * Why `n` doesn't fit the number box's limits (`null` when it does), worded
 * as the worker words it. An integer input rounds first, as R does, so the
 * rounded value is the one checked.
 */
const out_of_range = (input, n) => {
    const lo = input.min ?? null
    const hi = input.max ?? null
    const x = input.integer ? round_r(n) : n
    if ((lo == null || x >= lo) && (hi == null || x <= hi)) return null
    const whole = input.integer
    if (lo != null && hi != null) return t(whole ? "t_input_range_whole" : "t_input_range", { min: lo, max: hi })
    if (lo != null) return t(whole ? "t_input_min_whole" : "t_input_min", { min: lo })
    return t(whole ? "t_input_max_whole" : "t_input_max", { max: hi })
}

/**
 * Sends a number when the field changes (Enter, the arrows, or leaving it:
 * the `change` event), and only one that fits its limits: anything else
 * stays in the box with a note saying what the input allows, rather than
 * snapping back with no word.
 */
const NumberWidget = ({ input, label, value, send, disabled }) => {
    const [draft, set_draft] = useState(String(value))
    const [problem, set_problem] = useState(/** @type {string?} */ (null))
    useEffect(() => {
        set_draft(String(value))
        set_problem(null)
    }, [value])
    const commit = () => {
        const n = Number(draft)
        if (draft.trim() === "" || !Number.isFinite(n)) return set_problem(t(input.integer ? "t_input_whole" : "t_input_number"))
        const why = out_of_range(input, n)
        if (why != null) return set_problem(why)
        set_problem(null)
        if (n !== value) send(n)
    }
    return html`<label>
            <span class="ember-input-label">${label}</span>
            <input
                type="number"
                min=${input.min}
                max=${input.max}
                step=${input.step ?? "any"}
                value=${draft}
                disabled=${disabled}
                aria-invalid=${problem != null ? "true" : undefined}
                onInput=${(e) => set_draft(e.target.value)}
                onChange=${commit}
            />
        </label>
        ${problem != null ? html`<span class="ember-input-error" role="alert">${problem}</span>` : null}`
}

/** Sends the text when the user presses Enter or leaves the box (the `change` event), not on every key (docs/inputs.md). */
const TextWidget = ({ label, value, send, disabled }) => {
    const [draft, set_draft] = useState(value ?? "")
    useEffect(() => set_draft(value ?? ""), [value])
    const commit = () => {
        if (draft !== value) send(draft)
    }
    return html`<label>
        <span class="ember-input-label">${label}</span>
        <input
            type="text"
            value=${draft}
            disabled=${disabled}
            spellcheck="false"
            onInput=${(e) => set_draft(e.target.value)}
            onChange=${commit}
        />
    </label>`
}
