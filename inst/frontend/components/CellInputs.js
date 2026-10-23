import { html, useContext, useEffect, useState } from "../imports/Preact.js"
import { PlutoActionsContext, PlutoBondsContext } from "../common/PlutoContext.js"
import { t } from "../common/lang.js"

/**
 * A cell's inputs (docs/inputs.md): the widgets of the `input_*()` calls its
 * last run made, in order, above its output. A bound input's value is
 * `bonds[name].value`, which the page changes itself with `set_bond` as the
 * widget moves and the server sets with `set_input()`; Pluto's page holds
 * new values back while cells run and sends only the latest. A dropdown's
 * or radio's value is the 0-based position of its choice (a list of them
 * for a multiple dropdown), since a choice may be any R object.
 *
 * An unbound input is drawn greyed at its default, with the note that says
 * how to bind it. Every widget is disabled while the cell is stale, edited,
 * queued or running (`input.disabled`, from the server), and when the page
 * can't change the notebook (`disabled`: an HTML export, or no
 * connection). A value off its default is marked: `Rscript` would give
 * different results. When the worker refused the page's last value, the
 * bond carries its message (`bonds[name].error`), shown under the widget.
 *
 * @param {{
 *  cell_id: string,
 *  inputs: Array<Record<string, any>>,
 *  disabled: boolean,
 * }} props
 */
export const CellInputs = ({ cell_id, inputs, disabled }) => {
    const bonds = useContext(PlutoBondsContext)
    const pluto_actions = useContext(PlutoActionsContext)
    return html`<ember-inputs>
        ${inputs.map((input, i) => {
            const bond = input.bound && input.name != null ? bonds?.[input.name] : null
            const value = bond != null ? bond.value : input.bound ? input.value : input.default
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
    if (input.type === "select" || input.type === "radio") {
        const pick = Array.isArray(v) ? v : v == null ? [] : [v]
        return pick.map((k) => input.labels?.[k] ?? "").join(", ")
    }
    if (typeof v === "boolean") return v ? "TRUE" : "FALSE"
    if (typeof v === "string") return JSON.stringify(v)
    return String(v)
}

const same = (a, b) => (Array.isArray(a) && Array.isArray(b) ? a.length === b.length && a.every((x, k) => x === b[k]) : a === b)

const InputRow = ({ group, input, value, error, send, disabled }) => {
    const changed = input.bound && !same(value, input.default)
    const label = input.label ?? input.name ?? input.type
    const note = !input.bound
        ? input.reason === "read_elsewhere"
            ? t("t_input_read_elsewhere", { name: input.name })
            : t("t_input_not_assigned")
        : null
    return html`<ember-input class=${`${input.type}${input.bound ? "" : " unbound"}${changed ? " changed" : ""}`}>
        <${Widget} group=${group} input=${input} label=${label} value=${value} send=${send} disabled=${disabled} />
        ${changed
            ? html`<span class="ember-input-changed" title=${t("t_input_changed", { value: shown(input, input.default) })}>${t("t_input_changed_short")}</span>`
            : null}
        ${note != null ? html`<span class="ember-input-note">${note}</span>` : null}
        ${error != null ? html`<span class="ember-input-error" role="alert">${error}</span>` : null}
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
                    step=${input.step ?? "any"}
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

/** Why `n` doesn't fit the number box's limits (`null` when it does), worded as the worker words it. */
const out_of_range = (input, n) => {
    const lo = input.min ?? null
    const hi = input.max ?? null
    if ((lo == null || n >= lo) && (hi == null || n <= hi)) return null
    if (lo != null && hi != null) return t("t_input_range", { min: lo, max: hi })
    return lo != null ? t("t_input_min", { min: lo }) : t("t_input_max", { max: hi })
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
        if (draft.trim() === "" || !Number.isFinite(n)) return set_problem(t("t_input_number"))
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
