import { html } from "../imports/Preact.js"
import _ from "../imports/lodash-es.js"

// This file does not use i18next because of the following reasons:
// - Depending on a library requires more maintenance.
// - The package provides a lot of additional functionality that we don't need.
// - The main funcionality we need is simple enough.

import { english } from "../imports/lang_imports.js"

/**
 * @typedef {string & keyof typeof english} TranslationKey
 */

const resources = {
    "en": english,
}

/**
 * @overload @param {TranslationKey} key @param {{ returnObjects: true, [k: string]: any }} options @returns {string | Record<string, any> | string[]}
 * @overload @param {TranslationKey} key @param {{ returnObjects?: false, [k: string]: any }=} options @returns {string}
 * @param {TranslationKey} key @param {{ returnObjects?: boolean, [k: string]: any }=} options @returns {string | Record<string, any> | string[]}
 **/
export const t = (key, options = {}) => {
    const { count, interpolation = {}, returnObjects = false, defaultValue = key, fallbackLng = true, lng, ...extra_options } = options
    const { escapeValue = false } = interpolation // not implemented

    const lang = lng ?? getCurrentLanguage()

    const find_entry = (search_lang) => {
        let keys_to_search = /** @type {string[]} */ ([key])
        if (count != null && typeof count === "number") {
            keys_to_search = [`${key}_${new Intl.PluralRules(lang).select(count)}`, key]
            if (count === 0) keys_to_search.unshift(`${key}_zero`)
        }

        for (const key of keys_to_search) {
            const entry = resources[search_lang]?.[key]
            if (entry != null) return entry
        }
        return null
    }

    /** @type {string | Record<string,any> | string[]} */
    const found =
        find_entry(lang) ??
        (fallbackLng ? find_entry("en") : null) ??
        (() => {
            console.warn(`Missing localization for key "${key}" in language "${lang}"`)
            return defaultValue
        })()

    if (returnObjects) {
        if (Object.keys(extra_options).length > 0 || count != null)
            throw new Error(`Found entry for key "${key}" in language "${lang}" is not a string, interpolate has not yet been implemented.`)

        return found
    }

    return Object.keys(options).reduce((str, interp) => {
        // Interpolate
        return str.replaceAll(`{{${interp}}}`, format_value(lang, options[interp]))
    }, String(found))
}

const format_value = (lang, value) => (typeof value === "number" ? new Intl.NumberFormat(lang).format(value) : value)

/**
 * Get current language
 * @returns {string}
 */
export const getCurrentLanguage = _.memoize(() => {
    const from_local_storage = localStorage.getItem("i18nextLng")
    const from_navigator = navigator.languages

    const to_search = [from_local_storage, ...from_navigator]
    return getLanguage(to_search)
})

export const getWritingDirection = () => {
    return t("t_language_direction") === "rtl" ? "rtl" : "ltr"
}
const getLanguage = _.memoize((to_search) => {
    for (const lang of to_search) {
        if (lang != null) {
            const only_lang_region = (code) => {
                const loc = new Intl.Locale(code)
                return `${loc.language}-${loc.region}`
            }
            const only_lang = (code) => new Intl.Locale(code).language

            const available = [...Object.keys(resources)]

            let lr = available.find((x) => only_lang_region(x) == only_lang_region(lang))
            if (lr) return lr
            let l = available.find((x) => only_lang(x) == only_lang(lang))
            if (l) return l
        }
    }
    return "en"
}, JSON.stringify)

/** Format a duration in seconds as "5 seconds" or "2 minutes". */
export const pretty_long_time = (/** @type {number} */ sec) => {
    const min = sec / 60
    const sec_r = Math.ceil(sec)
    const min_r = Math.round(min)

    if (sec < 60) {
        return new Intl.NumberFormat(getCurrentLanguage(), { style: "unit", unit: "second", unitDisplay: "long" }).format(sec_r)
    } else {
        return new Intl.NumberFormat(getCurrentLanguage(), { style: "unit", unit: "minute", unitDisplay: "long" }).format(min_r)
    }
}

/**
 * Like t, but you can interpolate Preact elements.
 * @param {TranslationKey} key
 * @param {Record<string, any>=} insertions
 * @returns {string | import("../imports/Preact.js").ReactElement}
 */
export const th = (key, insertions) => {
    const slot = (name) => `❊${name}⦿`

    const can_interpolate_directly = (value) => typeof value === "string" || typeof value === "number" || typeof value === "boolean"

    const with_slots = t(key, {
        interpolation: { escapeValue: false },
        ...Object.fromEntries(Object.entries(insertions ?? {}).map(([key, value]) => [key, can_interpolate_directly(value) ? value : slot(key)])),
    })

    const slots = find_slots(with_slots)
    const slots_extended = [{ start: 0, end: 0, name: "" }, ...slots, { start: with_slots.length, end: with_slots.length, name: "" }]

    // The strings inbetween slots, including an initial and final string (possibly empty).
    const string_parts = slots_extended.slice(1).map((slot, i) => with_slots.slice(slots_extended[i]?.end, slot.start))

    // Objects to fill the slots with.
    const to_interpolate = slots.map((slot) => insertions?.[slot.name])

    const cache_key = [key, ...Object.keys(insertions ?? {}), ...Object.values(insertions ?? {}).map((v) => (can_interpolate_directly(v) ? v : null))]
    return html(to_template_strings_array_cached(string_parts, cache_key), ...to_interpolate)
}

const find_slots = (/** @type {string} */ string) => {
    const matches = [...string.matchAll(/❊([^⦿]*?)⦿/g)]
    return matches.map((m) => ({
        start: m.index,
        end: m.index + m[0].length,
        name: m[1] ?? "asfwefasfasdf",
    }))
}

export const localized_list_htl = (elements, elements_strings, options) => {
    const keys = elements_strings.map((x) => x.toString())

    const list_format = new Intl.ListFormat(getCurrentLanguage(), options)
    const parts = list_format.formatToParts(keys)

    // Empty strings, everything is interpolated.
    const strings = Array(parts.length + 1).fill("")

    const interpolation_parts = parts.map((part) =>
        part.type === "element"
            ? // Find the matching element_string, and get the element with the same index.
              elements[keys.indexOf(part.value)]
            : // Literal string.
              part.value
    )

    return html(to_template_strings_array_cached(strings, parts.length), ...interpolation_parts)
}

/** @type {Map<string, TemplateStringsArray>} */
const template_strings_array_cache = new Map()
const to_template_strings_array_cached = (/** @type {string[]} */ strings, key) => {
    const key_string = JSON.stringify(key)
    const found = template_strings_array_cache.get(key_string)
    if (found) return found

    // @ts-ignore
    const result = /** @type {TemplateStringsArray} */ (strings)
    template_strings_array_cache.set(key_string, result) // @ts-ignore
    return result
}
