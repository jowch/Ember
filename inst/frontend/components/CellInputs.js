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
 * different results.
 *
 * @param {{
 *  inputs: Array<Record<string, any>>,
 *  disabled: boolean,
 * }} props
 */
export const CellInputs = ({ inputs, disabled }) => {
    const bonds = useContext(PlutoBondsContext)
    const pluto_actions = useContext(PlutoActionsContext)
    return html`<ember-inputs>
        ${inputs.map((input, i) => {
            const bond = input.bound && input.name != null ? bonds?.[input.name] : null
            const value = bond != null ? bond.value : input.bound ? input.value : input.default
            const send = (v) => {
                if (input.bound && input.name != null) pluto_actions.set_bond(input.name, v)
            }
            return html`<${InputRow} key=${`${i}-${input.name ?? ""}`} input=${input} value=${value} send=${send} disabled=${disabled || input.disabled} />`
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

const InputRow = ({ input, value, send, disabled }) => {
    const changed = input.bound && !same(value, input.default)
    const label = input.label ?? input.name ?? input.type
    const note = !input.bound
        ? input.reason === "read_elsewhere"
            ? t("t_input_read_elsewhere", { name: input.name })
            : t("t_input_not_assigned")
        : null
    return html`<ember-input class=${`${input.type}${input.bound ? "" : " unbound"}${changed ? " changed" : ""}`}>
        <${Widget} input=${input} label=${label} value=${value} send=${send} disabled=${disabled} />
        ${changed
            ? html`<span class="ember-input-changed" title=${t("t_input_changed", { value: shown(input, input.default) })}>${t("t_input_changed_short")}</span>`
            : null}
        ${note != null ? html`<span class="ember-input-note">${note}</span>` : null}
    </ember-input>`
}

const Widget = ({ input, label, value, send, disabled }) => {
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
                            <input type="radio" name=${`ember-input-${input.name ?? label}`} checked=${value === k} onChange=${() => send(k)} />
                            <span>${l}</span>
                        </label>`
                )}
            </fieldset>`
        default:
            return null
    }
}

/** Sends a number when the field changes (Enter, the arrows, or leaving it: the `change` event), and only a number. */
const NumberWidget = ({ input, label, value, send, disabled }) => {
    const [draft, set_draft] = useState(String(value))
    useEffect(() => set_draft(String(value)), [value])
    const commit = () => {
        const n = Number(draft)
        if (draft.trim() !== "" && Number.isFinite(n) && n !== value) send(n)
        else set_draft(String(value))
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
            onInput=${(e) => set_draft(e.target.value)}
            onChange=${commit}
        />
    </label>`
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
