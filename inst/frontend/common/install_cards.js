/**
 * How the Packages tab groups a failed install into cards (#91,
 * ui-3-plan.md's "one card per package the notebook loads"). Pure, so a
 * plain `node --test` can check it (tests/e2e/tests/install-cards.test.mjs).
 *
 * `failures` is `library.failures` (install_failures(), R/packages-core.R),
 * each with `needed_by`, the packages the notebook loads whose dependencies
 * reach it. Every package named in a `needed_by` gets one card, titled with
 * its name, whether it failed itself or only something it needs did. A
 * "dependency" row (a package never built because one it needs failed) is
 * a consequence, not a cause, so a card names the causes under it: the
 * failures it reaches whose kind isn't "dependency".
 *
 * Until `needed_by` fills in (the index the walk reads is still being
 * fetched, or can't be), a "dependency" row's `detail` still names the
 * package it waited on, so a card follows that chain to a cause. A
 * failed cause that no card covers keeps a card of its own, as before
 * #91; a "dependency" row only when its chain ends where no card says.
 *
 * @typedef {import("../components/Editor.js").EmberInstallFailure} Failure
 * @typedef {{ package: string, own: Failure?, causes: Array<Failure> }} InstallCard
 * `own`: the card's package's own failure when it isn't "dependency"
 * (its sentence starts "It ..."); `causes`: the failed packages it needs,
 * in `failures` order, without `own`.
 */

/**
 * @param {Array<Failure>} failures
 * @returns {Array<InstallCard>}
 */
export const install_cards = (failures) => {
    const by_name = new Map(failures.map((f) => [f.package, f]))
    const is_cause = (f) => f.kind !== "dependency"

    /**
     * A "dependency" row's chain, through `detail`, to its first cause:
     * `{ cause, links }`, `links` the "dependency" rows passed on the way.
     * A chain that ends at a package that isn't among the failures names
     * that package anyway, with nothing more to say about why.
     */
    const follow = (f) => {
        const links = []
        let cur = f
        while (cur != null && !is_cause(cur) && !links.includes(cur.package)) {
            links.push(cur.package)
            const next = cur.detail == null ? null : by_name.get(cur.detail)
            if (next == null && cur.detail != null) {
                return { cause: { package: cur.detail, version: null, kind: "other", detail: null, libraries: null, needed_by: [] }, links }
            }
            cur = next
        }
        return { cause: cur != null && is_cause(cur) ? cur : null, links }
    }

    const roots = []
    for (const f of failures) {
        for (const name of f.needed_by ?? []) if (!roots.includes(name)) roots.push(name)
    }

    const covered = new Set()
    /** @param {string} name */
    const card_for = (name) => {
        const self = by_name.get(name) ?? null
        const own = self != null && is_cause(self) ? self : null
        const reached = failures.filter((f) => f.package !== name && (f.needed_by ?? []).includes(name))
        let causes = reached.filter(is_cause)
        covered.add(name)
        for (const f of reached) covered.add(f.package)
        if (own == null && causes.length === 0) {
            const start = self ?? reached[0]
            if (start != null) {
                const { cause, links } = follow(start)
                for (const l of links) covered.add(l)
                if (cause != null) {
                    causes = [cause]
                    covered.add(cause.package)
                }
            }
        }
        return { package: name, own, causes }
    }

    const cards = roots.map(card_for)
    // What no card covers: each failed cause gets its own card first, then
    // a "dependency" row only when its chain leads somewhere no card says.
    for (const f of failures) {
        if (is_cause(f) && !covered.has(f.package)) cards.push(card_for(f.package))
    }
    for (const f of failures) {
        if (covered.has(f.package)) continue
        const { cause, links } = follow(f)
        if (cause != null && covered.has(cause.package)) for (const l of links) covered.add(l)
        else cards.push(card_for(f.package))
    }
    return cards
}

/**
 * The causes of a card grouped by what went wrong, in first-seen order:
 * one sentence each ("A package it needs, rlang 1.1.6, doesn't build",
 * "Packages it needs, a and b, ..."). "configure" reads as "compile";
 * a "system" row that names its libraries reads as "missing_system".
 *
 * @param {Array<Failure>} causes
 * @returns {Array<{ kind: string, failures: Array<Failure> }>}
 */
export const cause_groups = (causes) => {
    const groups = []
    for (const f of causes) {
        const kind = sentence_kind(f)
        const group = groups.find((g) => g.kind === kind)
        if (group == null) groups.push({ kind, failures: [f] })
        else group.failures.push(f)
    }
    return groups
}

/** @param {Failure} f */
export const sentence_kind = (f) => {
    if (f.kind === "configure") return "compile"
    if (f.kind === "system" && f.libraries != null) return "missing_system"
    if (["compile", "download", "unavailable", "system", "missing_system", "missing_compiler", "no_binary"].includes(f.kind)) return f.kind
    return "other"
}

/**
 * "a", "a and b", "a, b, and c", in the page's language.
 * @param {Array<string>} names
 * @param {string} lang
 */
export const join_names = (names, lang = "en") => new Intl.ListFormat(lang, { type: "conjunction" }).format(names)
