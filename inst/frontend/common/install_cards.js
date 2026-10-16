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
 * package it waited on, so a card follows that chain to a cause. What
 * is still left over goes to the card of the package the notebook loads,
 * or one card for several (`direct`). Only without `direct` does a failed
 * cause that no card covers keep a card of its own, as before #91; a
 * "dependency" row only when its chain ends where no card says.
 *
 * @typedef {import("../components/Editor.js").EmberInstallFailure} Failure
 * @typedef {{ package: string?, packages?: Array<string>, own: Failure?, causes: Array<Failure> }} InstallCard
 * `own`: the card's package's own failure when it isn't "dependency"
 * (its sentence starts "It ..."); `causes`: the failed packages it needs,
 * in `failures` order, without `own`. A card for several packages the
 * notebook loads at once has `package` null and `packages` their names
 * (its sentences start "Packages they need").
 */

/**
 * @param {Array<Failure>} failures
 * @param {Array<string>} direct the packages the notebook loads
 *   (`packages.rows` with `direct`)
 * @returns {Array<InstallCard>}
 */
export const install_cards = (failures, direct = []) => {
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

    // A failure no card covers, of a package the notebook doesn't load
    // itself, is still needed by one it does: `needed_by` is empty only
    // because the index it walks hasn't come, or can't (#91's offline
    // case, where every package fails as "unavailable"). With one such
    // package to name, its card takes them all; with several, one card
    // names them together rather than a card per failure.
    const leftover = failures.filter((f) => !covered.has(f.package) && !direct.includes(f.package))
    if (direct.length > 0 && leftover.length > 0) {
        const extra = []
        for (const f of leftover) {
            covered.add(f.package)
            const { cause, links } = is_cause(f) ? { cause: f, links: [] } : follow(f)
            for (const l of links) covered.add(l)
            if (cause != null && !extra.includes(cause)) extra.push(cause)
        }
        // Which of several needs which isn't known, so the shared card
        // names them all, a package with a card of its own too.
        if (direct.length === 1) {
            let card = cards.find((c) => c.package === direct[0])
            if (card == null) {
                card = card_for(direct[0])
                cards.push(card)
            }
            for (const f of extra) {
                if (f !== card.own && !card.causes.includes(f)) card.causes.push(f)
            }
        } else {
            cards.push({ package: null, packages: direct, own: null, causes: extra })
        }
    }
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

/**
 * Whether a cause group's sentence can just say "failed the same way":
 * the card's own failure is of the same kind, so its sentence already
 * gave the reason and the advice. Never for missing system libraries,
 * whose own sentence lists only the package's own libraries: the
 * group's would drop off the card (#75's sf, lacking libgdal, with units,
 * lacking libudunits2).
 *
 * @param {Failure?} own
 * @param {{ kind: string }} group
 */
export const reads_same = (own, group) => own != null && group.kind !== "missing_system" && sentence_kind(own) === group.kind

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
