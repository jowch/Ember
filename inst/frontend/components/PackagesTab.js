import { html, useState, useContext, useEffect, useRef } from "../imports/Preact.js"
import { t, getCurrentLanguage } from "../common/lang.js"
import { install_cards, cause_groups, sentence_kind, reads_same, join_names } from "../common/install_cards.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"

/**
 * A card package's own sentence ("It ..."), built from `kind`/`detail`
 * and `packages$r_version` -- R sends no prose.
 *
 * @param {import("./Editor.js").EmberInstallFailure} failure
 * @param {string?} r_version
 */
const own_sentence = (failure, r_version) => {
    switch (sentence_kind(failure)) {
        case "compile":
            return t("t_ember_install_failed_compile", { r_version: r_version ?? "" })
        case "download":
            return t("t_ember_install_failed_download")
        case "unavailable":
            return t("t_ember_install_failed_unavailable")
        case "system":
            return t("t_ember_install_failed_system")
        case "missing_system":
            return t("t_ember_install_failed_missing_system", { libraries: failure.libraries ?? "" })
        case "missing_compiler":
            return t("t_ember_install_failed_missing_compiler")
        case "no_binary":
            return t("t_ember_install_failed_no_binary", { version: failure.detail ?? "", r_version: r_version ?? "" })
        case "newer_system":
            return t("t_ember_install_failed_newer_system", { versions: failure.detail ?? "", libraries: failure.libraries ?? "" })
        case "symbol_version":
            return t("t_ember_install_failed_symbol_version", { versions: failure.detail ?? "", libraries: failure.libraries ?? "" })
        case "library_version":
            return t("t_ember_install_failed_library_version", { libraries: failure.libraries ?? "", have: failure.detail ?? "" })
        default:
            return t("t_ember_install_failed_other")
    }
}

/** The sentence for packages a card's package needs, by `sentence_kind()`. */
const DEP_SENTENCE = {
    compile: "t_ember_install_failed_dep_compile",
    download: "t_ember_install_failed_dep_download",
    unavailable: "t_ember_install_failed_dep_unavailable",
    system: "t_ember_install_failed_dep_system",
    missing_system: "t_ember_install_failed_dep_missing_system",
    missing_compiler: "t_ember_install_failed_dep_missing_compiler",
    no_binary: "t_ember_install_failed_dep_no_binary",
    newer_system: "t_ember_install_failed_dep_newer_system",
    symbol_version: "t_ember_install_failed_dep_symbol_version",
    library_version: "t_ember_install_failed_dep_library_version",
    other: "t_ember_install_failed_dep_other",
}

/** The same sentences for a card naming several packages the notebook loads ("Packages they need, ..."). */
const THEY_SENTENCE = {
    compile: "t_ember_install_failed_they_compile",
    download: "t_ember_install_failed_they_download",
    unavailable: "t_ember_install_failed_they_unavailable",
    system: "t_ember_install_failed_they_system",
    missing_system: "t_ember_install_failed_they_missing_system",
    missing_compiler: "t_ember_install_failed_they_missing_compiler",
    no_binary: "t_ember_install_failed_they_no_binary",
    newer_system: "t_ember_install_failed_they_newer_system",
    symbol_version: "t_ember_install_failed_they_symbol_version",
    library_version: "t_ember_install_failed_they_library_version",
    other: "t_ember_install_failed_they_other",
}

/** A list of names for a sentence, the first few and then "and 38 more": Show the error has them all. */
const MAX_NAMES = 5
const name_list = (names) =>
    join_names(
        names.length <= MAX_NAMES ? names : [...names.slice(0, MAX_NAMES - 1), t("t_ember_install_failed_more", { count: names.length - (MAX_NAMES - 1) })],
        getCurrentLanguage()
    )

/**
 * One sentence per kind of failure among the packages a card's package
 * needs (#91): "A package it needs, rlang 1.1.6, doesn't build on R
 * 4.6.1." Each is named with its locked version from `rows`
 * (`packages.rows`); a missing-system sentence lists every library its
 * packages lack. `they`: the card names several packages the notebook
 * loads. `same`: the card's own package failed the same way, so its
 * sentence already gave the reason and the advice, and this one only
 * names the rest (`reads_same()`: never for missing system libraries).
 *
 * @param {{ kind: string, failures: Array<import("./Editor.js").EmberInstallFailure> }} group
 * @param {Array<import("./Editor.js").EmberPackageRow>} rows
 * @param {string?} r_version
 * @param {{ they?: boolean, same?: boolean }} how
 */
const dep_sentence = (group, rows, r_version, { they = false, same = false } = {}) => {
    const names = group.failures.map((f) => {
        const version = f.version ?? rows.find((r) => r.name === f.package)?.version
        return version == null ? f.package : `${f.package} ${version}`
    })
    const unique_list = (field) => [...new Set(group.failures.flatMap((f) => (f[field] ?? "").split(",").map((l) => l.trim()).filter((l) => l !== "")))].join(", ")
    const key = same ? "t_ember_install_failed_dep_same" : (they ? THEY_SENTENCE : DEP_SENTENCE)[group.kind]
    return t(key, {
        count: names.length,
        packages: name_list(names),
        libraries: unique_list("libraries"),
        // newer_system, symbol_version: the symbol versions; library_version: the versions this system has.
        versions: unique_list("detail"),
        have: unique_list("detail"),
        r_version: r_version ?? "",
    })
}

/**
 * What to do about a missing compiler or system library
 * (R/install-checks.R), over a card's own failure and its causes. System
 * libraries: every covered package's row ("missing_system") carries the
 * same command, which installs them all, so only the first card
 * (`show_command`) shows it, with the sentence for people who can't run
 * it. A package the command doesn't cover ("system" with libraries: a
 * GitHub package, or no Package Manager) gets the package-manager
 * sentence on its own card (#76). A library here only as another version
 * ("library_version", #76): the command would install the version
 * already here. A binary built for a newer system ("newer_system") or
 * against another build of a library ("symbol_version"): a library from
 * conda or a module may be the cause. A compiler:
 * `detail` is a sentence whose `backticked` parts are commands. A package
 * with no binary for this R (#19): update the date, or use an older R.
 * Nothing for other kinds, whose `detail` is a line of the log.
 *
 * @param {Array<import("./Editor.js").EmberInstallFailure>} failures
 * @param {boolean} show_command
 */
const failure_fixes = (failures, show_command) => {
    const command = failures.find((f) => f.kind === "missing_system" && f.detail != null)?.detail
    const uncovered = failures.some((f) => f.kind === "system" && f.libraries != null)
    const compiler = failures.find((f) => f.kind === "missing_compiler" && f.detail != null)?.detail
    const command_shown = show_command && command != null
    return html`
        ${command_shown
            ? html`<p class="ember-install-failure-fix">${t("t_ember_install_failed_system_command")}</p>
                  <pre class="ember-install-failure-command">${command}</pre>`
            : null}
        ${uncovered
            ? html`<p class="ember-install-failure-fix">
                  ${t(command_shown ? "t_ember_install_failed_system_uncovered" : "t_ember_install_failed_system_manager")}
              </p>`
            : null}
        ${command_shown || uncovered ? html`<p class="ember-install-failure-fix">${t("t_ember_install_failed_no_admin")}</p>` : null}
        ${failures.some((f) => f.kind === "library_version")
            ? html`<p class="ember-install-failure-fix">${t("t_ember_install_failed_library_version_fix")}</p>`
            : null}
        ${failures.some((f) => f.kind === "newer_system")
            ? html`<p class="ember-install-failure-fix">${t("t_ember_install_failed_newer_system_fix")}</p>`
            : null}
        ${failures.some((f) => f.kind === "symbol_version")
            ? html`<p class="ember-install-failure-fix">${t("t_ember_install_failed_symbol_version_fix")}</p>`
            : null}
        ${failures.some((f) => f.kind === "no_binary")
            ? html`<p class="ember-install-failure-fix">${t("t_ember_install_failed_no_binary_fix")}</p>`
            : null}
        ${compiler != null
            ? html`<p class="ember-install-failure-fix">${compiler.split("`").map((part, i) => (i % 2 === 1 ? html`<code>${part}</code>` : part))}</p>`
            : null}
    `
}

/**
 * One card per package the notebook loads whose install failed, or that
 * needs one that failed (`install_cards()`, #91; ui-3-plan.md's "A
 * failed install"): "DESeq2 couldn't install", its own sentence if it
 * failed itself, one sentence per kind of failure among the packages it
 * needs, for a missing compiler or system library what to install, then
 * Update (build failures), Try again (downloads, packages the
 * repositories didn't list, and anything the user installs on the
 * computer) and Show the error (always). `ember_update_packages` and
 * `ember_retry_install` are plain requests (server.R); neither is this
 * component's to answer.
 *
 * @param {{
 *  card: import("../common/install_cards.js").InstallCard,
 *  rows: Array<import("./Editor.js").EmberPackageRow>,
 *  r_version: string?,
 *  log: string?,
 *  show_command: boolean,
 * }} props
 */
const InstallFailureCard = ({ card, rows, r_version, log, show_command }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const [show_error, set_show_error] = useState(false)
    const failures = card.own == null ? card.causes : [card.own, ...card.causes]
    const can_update = failures.some((f) => ["compile", "configure", "no_binary"].includes(f.kind))
    // "unavailable" is most often a repository index that couldn't be
    // read, which can be passing, so it gets Try again too.
    // The missing-piece kinds are fixed outside Ember, then retried.
    const can_retry = failures.some((f) => ["download", "unavailable", "system", "missing_system", "missing_compiler", "library_version"].includes(f.kind))

    return html`
        <div class="ember-install-failure-card">
            <p class="ember-install-failure-title">
                ${t("t_ember_install_failed_title", { package: card.package ?? name_list(card.packages ?? []) })}
            </p>
            ${card.own != null || card.causes.length === 0
                ? html`<p class="ember-install-failure-sentence">${own_sentence(card.own ?? { kind: "other" }, r_version)}</p>`
                : null}
            ${cause_groups(card.causes).map(
                (group) => html`<p class="ember-install-failure-sentence">
                    ${dep_sentence(group, rows, r_version, {
                        they: card.package == null,
                        same: reads_same(card.own, group),
                    })}
                </p>`
            )}
            ${failure_fixes(failures, show_command)}
            <div class="ember-install-failure-actions">
                ${can_update
                    ? html`<button
                          type="button"
                          class="ember-btn primary"
                          title=${t("t_ember_install_failed_update_hint")}
                          onClick=${() => pluto_actions.ember_update_packages()}
                      >
                          ${t("t_ember_update_packages")}
                      </button>`
                    : null}
                ${can_retry
                    ? html`<button type="button" class="ember-btn" onClick=${() => pluto_actions.ember_retry_install()}>${t("t_ember_try_again")}</button>`
                    : null}
                <button type="button" class="ember-btn" onClick=${() => set_show_error(!show_error)}>${t("t_ember_show_the_error")}</button>
            </div>
            ${show_error ? html`<pre class="ember-install-failure-log">${log}</pre>` : null}
        </div>
    `
}

/** A byte count in words: "2.1 GB", "640 MB", "25 MB", "2 kB". */
export const size_words = (/** @type {number} */ bytes) =>
    bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : bytes >= 1e6 ? `${Math.round(bytes / 1e6)} MB` : `${Math.max(1, Math.round(bytes / 1e3))} kB`

/**
 * The card an install shows when it stopped before a large download
 * (#37): the total, the largest packages, and Install, which says yes
 * (`ember_approve_install`, server.R). Until then the cells that use them
 * wait; removing the package from the code is the way to say no.
 *
 * @param {{ download: { bytes: number, packages: Array<{ package: string, version: string, bytes: number? }> } }} props
 */
const LargeDownloadCard = ({ download }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const named = download.packages.slice(0, MAX_NAMES).map((p) => (p.bytes != null ? `${p.package} (${size_words(p.bytes)})` : p.package))
    const rest = download.packages.length - named.length
    return html`
        <div class="ember-install-ask-card">
            <p class="ember-install-failure-title">${t("t_ember_install_ask_title", { size: size_words(download.bytes) })}</p>
            <p class="ember-install-failure-sentence">
                ${t("t_ember_install_ask_sentence", {
                    packages: rest > 0 ? `${named.join(", ")}, ${t("t_ember_install_failed_more", { count: rest })}` : named.join(", "),
                })}
            </p>
            <div class="ember-install-failure-actions">
                <button type="button" class="ember-btn primary" onClick=${() => pluto_actions.ember_approve_install()}>${t("t_ember_install_ask_install")}</button>
            </div>
        </div>
    `
}

/** One locked package a step back changes (#311): "name from → to", or
 * one it no longer needs. The packages it adds aren't listed: they are
 * what the user asked for, and for a Bioconductor package that is a long
 * list of dependencies. */
const step_back_change = (c) =>
    c.to != null ? `${c.name} ${c.from} → ${c.to}` : t("t_ember_packages_step_back_dropped", { name: c.name, version: c.from })

/**
 * The header's Update button and, once `update` fills in, what it found:
 * "Checking…" while fetching, the in-tab restart question when applying
 * would restart a loaded package (the engine applies the update itself
 * when nothing would restart, so the page never has to ask then), or
 * the failure sentence. When the engine applies a no-restart update on
 * its own, `update` goes straight from "checking" to `null` with nothing
 * in between (the wire never shows an intermediate "ready": the proposal
 * is applied and cleared in the same step) -- including when there was
 * nothing to change at all, which would otherwise look to someone who
 * just clicked Update like nothing happened. `justFinished` tracks that
 * transition locally and shows a short "Already up to date" note for it,
 * unless the library went on to install something (a real update).
 *
 * The same place asks about a step back (`update.back`, #311): the
 * notebook's date isn't published for Bioconductor yet, and the newest
 * date that is would change a locked version. Ember moves back on its own
 * when nothing locked would change, so this shows only then.
 *
 * @param {{ update: import("./Editor.js").EmberPackagesUpdate?, library_status: string }} props
 */
const PackagesUpdate = ({ update, library_status }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const [justFinished, set_just_finished] = useState(false)
    const was_checking_ref = useRef(false)

    useEffect(() => {
        if (update?.status === "checking") {
            was_checking_ref.current = true
            set_just_finished(false)
        } else if (was_checking_ref.current && update == null) {
            was_checking_ref.current = false
            if (library_status !== "installing" && library_status !== "missing") {
                set_just_finished(true)
                const timer = setTimeout(() => set_just_finished(false), 4000)
                return () => clearTimeout(timer)
            }
        } else if (update != null) {
            was_checking_ref.current = false
        }
    }, [update, library_status])

    return html`
        <div class="ember-packages-update">
            <button
                type="button"
                class="ember-btn"
                onClick=${() => {
                    set_just_finished(false)
                    pluto_actions.ember_update_packages()
                }}
            >
                ${t("t_ember_update_packages")}
            </button>
            ${update == null
                ? justFinished && html`<span class="ember-packages-update-noop">${t("t_ember_packages_already_up_to_date")}</span>`
                : update.status === "checking"
                ? html`<span class="ember-packages-update-checking">${t("t_ember_packages_update_checking")}</span>`
                : update.status === "failed"
                ? html`<span class="ember-packages-update-failed"
                      >${t("t_ember_packages_update_failed", { reason: update.message ?? "" })}</span
                  >`
                : update.back != null
                ? html`<div class="ember-packages-update-question">
                      <p>
                          ${t("t_ember_packages_step_back_question", {
                              from: update.back.from,
                              date: update.date,
                              changes: update.back.changes
                                  .filter((c) => c.from != null)
                                  .map(step_back_change)
                                  .join(", "),
                          })}
                          ${update.restart.length > 0
                              ? " " + t("t_ember_packages_step_back_restart", { names: update.restart.join(", ") })
                              : ""}
                      </p>
                      <button type="button" class="ember-btn primary" onClick=${() => pluto_actions.ember_apply_update(update.date)}>
                          ${t("t_ember_packages_step_back_apply", { date: update.date })}
                      </button>
                      <button type="button" class="ember-btn" onClick=${() => pluto_actions.ember_cancel_update()}>${t("t_cancel")}</button>
                  </div>`
                : update.restart.length > 0
                ? html`<div class="ember-packages-update-question">
                      <p>${t("t_ember_packages_update_restart_question", { names: update.restart.join(", ") })}</p>
                      <button type="button" class="ember-btn primary" onClick=${() => pluto_actions.ember_apply_update(update.date)}>
                          ${t("t_ember_update_packages")}
                      </button>
                      <button type="button" class="ember-btn" onClick=${() => pluto_actions.ember_cancel_update()}>${t("t_cancel")}</button>
                  </div>`
                : null}
        </div>
    `
}

/** A status cell per Panel3: a coloured pill for installed/failed, a
 * progress bar for installing, plain faint text otherwise. */
const PackageStatus = ({ row }) => {
    const text = t(`t_ember_packages_status_${row.status}`)
    if (row.status === "installed") return html`<span class="ember-pill ember-pill-accent">${text}</span>`
    if (row.status === "failed" || row.status === "not_found" || row.status === "lookup_failed" || row.status === "source_failed") {
        return html`<span class="ember-pill ember-pill-red">${text}</span>`
    }
    if (row.status === "installing" || row.status === "looking_up") {
        return html`<div class="ember-package-progress-status">
            <span>${text}</span>
            <div class="ember-package-progress ember-package-progress-indeterminate"></div>
        </div>`
    }
    return html`<span class="ember-faint-text">${text}</span>`
}

/**
 * Where a package from the header's `[sources]` comes from, under its
 * version: "GitHub lab/mypkg@3f2a1c9", or "r-universe jowch@b56942e" for
 * a universe's build. Its version isn't the snapshot date's, so the date
 * above the table doesn't speak for it; this label is design.md's "marked
 * unchecked", and its tooltip says so.
 * @param {string?} source  the lock's source, "github:<user>/<repo>@<sha>"
 *   or "universe:<name>/<host>/<path>[//<subdir>]@<sha>"
 */
const github_source_label = (source) => {
    const m = /^github:([^@]+)@(.+)$/.exec(source ?? "")
    if (m != null) {
        return html`<div class="ember-package-source" title=${t("t_ember_packages_from_github_unchecked", { source })}>${t("t_ember_packages_from_github", { repo: `${m[1]}@${m[2].slice(0, 7)}` })}</div>`
    }
    const u = /^universe:([^/]+)\/.*@([0-9a-f]+)$/.exec(source ?? "")
    if (u == null) return null
    return html`<div class="ember-package-source" title=${t("t_ember_packages_from_universe_unchecked", { source })}>${t("t_ember_packages_from_universe", { universe: u[1], sha: u[2].slice(0, 7) })}</div>`
}

/** A `[sources]` spec as the form shows it and takes it: "user/repo[@ref]". */
const spec_text = (/** @type {string?} */ spec) => (spec ?? "").replace(/^github:/, "")

/**
 * The form that sets a package's GitHub source (#78): "user/repo",
 * optionally with @ and a branch, tag or commit, sent as the
 * `set_package_source` edit op (`ember_set_package_source`, server.R).
 * Ember's refusal, if any, shows under the field and the form stays open;
 * otherwise it closes, and the row goes on to say "looking up".
 *
 * @param {{ name: string, spec: string?, on_close: () => void }} props
 */
const SourceForm = ({ name, spec, on_close }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const [value, set_value] = useState(spec_text(spec))
    const [error, set_error] = useState(/** @type {string?} */ (null))
    const [saving, set_saving] = useState(false)
    const input_ref = useRef(/** @type {HTMLInputElement?} */ (null))
    useEffect(() => input_ref.current?.focus(), [])
    const input_id = `ember-package-source-input-${name}`

    return html`
        <form
            class="ember-package-source-form"
            onSubmit=${async (/** @type {SubmitEvent} */ e) => {
                e.preventDefault()
                set_saving(true)
                set_error(null)
                try {
                    const response = await pluto_actions.ember_set_package_source(name, value.trim())
                    if (response?.message?.error != null) {
                        set_error(response.message.error)
                    } else {
                        on_close()
                    }
                } finally {
                    set_saving(false)
                }
            }}
            onKeyDown=${(/** @type {KeyboardEvent} */ e) => {
                if (e.key === "Escape") {
                    e.stopPropagation()
                    on_close()
                }
            }}
        >
            <label for=${input_id}>${t("t_ember_packages_source_label", { package: name })}</label>
            <div class="ember-package-source-form-row">
                <input
                    id=${input_id}
                    ref=${input_ref}
                    class="ember-mono"
                    type="text"
                    spellcheck="false"
                    autocomplete="off"
                    placeholder=${t("t_ember_packages_source_placeholder")}
                    value=${value}
                    disabled=${saving}
                    aria-invalid=${error != null}
                    onInput=${(/** @type {InputEvent} */ e) => set_value(/** @type {HTMLInputElement} */ (e.target).value)}
                />
                <button type="submit" class="ember-btn primary" disabled=${saving || !value.trim()}>
                    ${spec == null ? t("t_ember_packages_source_add") : t("t_ember_packages_source_save")}
                </button>
                <button type="button" class="ember-btn" disabled=${saving} onClick=${on_close}>${t("t_cancel")}</button>
            </div>
            ${error != null ? html`<p class="ember-package-source-error" role="alert">${error}</p>` : null}
        </form>
    `
}

/**
 * The line under a package's row for its GitHub source (#78), or `null`
 * when it has none to show: a not-found package offers to add one; a
 * package with a `[sources]` entry offers to change or remove it, and says
 * why its source failed (a failed lookup, a repository holding another
 * package). Nothing to click in a read-only notebook, whose edits Ember
 * refuses.
 *
 * @param {{ row: import("./Editor.js").EmberPackageRow, read_only: boolean }} props
 */
const SourceDetail = ({ row, read_only }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const [editing, set_editing] = useState(false)
    const [error, set_error] = useState(/** @type {string?} */ (null))
    const [removing, set_removing] = useState(false)
    const has_spec = row.spec != null
    const failed_message = has_spec && row.message != null ? row.message : null
    if (!has_spec && row.status !== "not_found" && row.status !== "lookup_failed") return null
    if (read_only && failed_message == null) return null

    return html`
        <tr class="ember-package-detail" key=${`${row.name} source`}>
            <td colspan="3">
                ${failed_message != null ? html`<p class="ember-package-source-failed">${failed_message}</p>` : null}
                ${read_only
                    ? null
                    : editing
                    ? html`<${SourceForm} name=${row.name} spec=${row.spec} on_close=${() => set_editing(false)} />`
                    : html`<div class="ember-package-source-actions">
                          <button
                              type="button"
                              class="ember-btn"
                              onClick=${() => {
                                  set_error(null)
                                  set_editing(true)
                              }}
                          >
                              ${has_spec ? t("t_ember_packages_source_change") : t("t_ember_packages_source_add_from_github")}
                          </button>
                          ${has_spec
                              ? html`<button
                                    type="button"
                                    class="ember-btn"
                                    disabled=${removing}
                                    onClick=${async () => {
                                        set_error(null)
                                        set_removing(true)
                                        try {
                                            const response = await pluto_actions.ember_remove_package_source(row.name)
                                            if (response?.message?.error != null) set_error(response.message.error)
                                        } finally {
                                            set_removing(false)
                                        }
                                    }}
                                >
                                    ${t("t_ember_packages_source_remove")}
                                </button>`
                              : null}
                      </div>`}
                ${error != null ? html`<p class="ember-package-source-error" role="alert">${error}</p>` : null}
            </td>
        </tr>
    `
}

/** Bytes as "512 KB", "3.4 MB", "1.2 GB" (powers of 1000, as file managers show them). */
export const format_bytes = (bytes, lang = getCurrentLanguage()) => {
    const units = ["B", "KB", "MB", "GB", "TB"]
    let value = bytes
    let unit = 0
    while (value >= 1000 && unit < units.length - 1) {
        value /= 1000
        unit += 1
    }
    const digits = unit === 0 || value >= 10 ? 0 : 1
    return `${new Intl.NumberFormat(lang, { maximumFractionDigits: digits, minimumFractionDigits: digits }).format(value)} ${units[unit]}`
}

/**
 * How much disk the libraries, the package cache and the indexes use
 * (#38; design.md's "The package view shows disk use"). Measured by the
 * server in a subprocess (`ember_disk_use`, server.R) each time the tab
 * opens, and again after a clean-up; shared by every notebook, so it
 * says so. Ember deletes unused libraries on its own after 60 days.
 *
 * "Clean up…" (#128) frees space now. It first asks the server what it
 * would delete (`ember_clean_up`, a dry run: libraries no open notebook
 * holds and unused for 30 days, and the cache entries no other library
 * lists) and shows that with Delete and Cancel. Nothing is deleted until
 * Delete, and Delete judges at the preview's time. After the result the
 * button comes back.
 */
const DiskUse = () => {
    const pluto_actions = useContext(PlutoActionsContext)
    const [use, set_use] = useState(/** @type {{ libraries: number, cache: number, indexes: number, exact: boolean }?} */ (null))
    const [failed, set_failed] = useState(false)
    // null, "checking", "deleting", or the dry run's or the deletion's reply.
    const [clean, set_clean] = useState(/** @type {any} */ (null))
    const live = useRef(true)
    useEffect(
        () => () => {
            live.current = false
        },
        []
    )
    const measure = () => {
        Promise.resolve(pluto_actions.ember_disk_use?.())
            .then((response) => {
                if (!live.current) return
                const message = response?.message
                if (message == null || message.error != null || message.cache == null) set_failed(true)
                else set_use(message)
            })
            .catch(() => live.current && set_failed(true))
    }
    useEffect(measure, [])
    // `as_of` is the preview's time, sent back with Delete so the deletion
    // is judged then and removes nothing the preview didn't count.
    const clean_up = (dry_run, as_of) => {
        set_clean(dry_run ? "checking" : "deleting")
        Promise.resolve(pluto_actions.ember_clean_up?.(dry_run, as_of))
            .then((response) => {
                if (!live.current) return
                const message = response?.message
                set_clean(message == null || message.cache == null ? { error: message?.error ?? "" } : message)
                if (!dry_run) {
                    set_use(null)
                    set_failed(false)
                    measure()
                }
            })
            .catch(() => live.current && set_clean({ error: "" }))
    }

    const nothing = clean != null && typeof clean === "object" && clean.error == null && clean.libraries === 0 && clean.cache === 0
    // After a result (done, nothing, failed) the button comes back, for another go.
    const button = html`<button type="button" class="ember-btn" onClick=${() => clean_up(true)}>${t("t_ember_packages_clean_up")}</button>`
    return html`<div class="ember-packages-disk">
        <p class="ember-packages-disk-use">
            ${failed
                ? t("t_ember_packages_disk_use_failed")
                : use == null
                  ? t("t_ember_packages_disk_use_measuring")
                  : t(use.exact ? "t_ember_packages_disk_use" : "t_ember_packages_disk_use_estimate", {
                        libraries: format_bytes(use.libraries),
                        cache: format_bytes(use.cache),
                        indexes: format_bytes(use.indexes),
                    })}
        </p>
        ${clean == null
            ? button
            : clean === "checking"
              ? html`<p>${t("t_ember_packages_clean_up_checking")}</p>`
              : clean === "deleting"
                ? html`<p>${t("t_ember_packages_clean_up_deleting")}</p>`
                : clean.error != null
                  ? html`<p class="ember-packages-update-failed">${t("t_ember_packages_clean_up_failed")}</p>
                        ${button}`
                  : nothing
                    ? html`<p>${t("t_ember_packages_clean_up_nothing")}</p>
                          ${button}`
                    : clean.dry_run
                      ? html`<div class="ember-packages-update-question ember-packages-clean-up-question">
                            <p>
                                ${t("t_ember_packages_clean_up_question", {
                                    libraries: t("t_ember_packages_clean_up_libraries", { count: clean.libraries }),
                                    cache: t("t_ember_packages_clean_up_entries", { count: clean.cache }),
                                    bytes: format_bytes(clean.bytes),
                                })}
                            </p>
                            <button type="button" class="ember-btn primary" onClick=${() => clean_up(false, clean.as_of)}>${t("t_ember_packages_clean_up_delete")}</button>
                            <button type="button" class="ember-btn" onClick=${() => set_clean(null)}>${t("t_cancel")}</button>
                        </div>`
                      : html`<p>
                            ${t("t_ember_packages_clean_up_done", {
                                libraries: t("t_ember_packages_clean_up_libraries", { count: clean.libraries }),
                                cache: t("t_ember_packages_clean_up_entries", { count: clean.cache }),
                                bytes: format_bytes(clean.bytes),
                            })}
                        </p>
                        ${button}`}
    </div>`
}

/**
 * The "Packages" tab (ui-2.md, 5; ui-3-plan.md, piece 4 and piece 5's
 * "Packages tab"): "Versions as of <date>" with Update, a description
 * line, the library's install status, a card per package the notebook
 * loads whose install failed (`install_cards()`), and
 * one row per *direct* package (dependencies hidden), each followed by its
 * GitHub source line when it has one (`SourceDetail`), then the disk use
 * of every notebook's libraries and the shared cache (`DiskUse`; not in
 * a read-only export, which has no server to ask). Reads
 * `notebook.ember.packages` (project_ember(), pluto-state.R); `nbpkg`
 * stays filled beside it for Endeavor and isn't read here.
 *
 * @param {{ packages: import("./Editor.js").EmberPackagesData?, read_only?: boolean }} props
 */
export const PackagesTab = ({ packages, read_only = false }) => {
    if (packages == null) return null
    const { snapshot, r_version, library, rows, update } = packages
    const direct_rows = rows.filter((row) => row.direct)
    const cards = install_cards(library.failures, direct_rows.map((row) => row.name))
    // The one card that shows the system-library command (`failure_fixes()`).
    const command_card = cards.findIndex((card) => [card.own, ...card.causes].some((f) => f != null && f.kind === "missing_system" && f.detail != null))

    return html`
        <div id="ember-packages-tab">
            <div class="ember-packages-head">
                <div class="ember-packages-head-row">
                    <span class="ember-packages-title">
                        ${snapshot != null ? `${t("t_ember_packages_versions_as_of")} ${snapshot}` : t("t_panel_packages")}
                    </span>
                    <${PackagesUpdate} update=${update ?? null} library_status=${library.status} />
                </div>
                <span class="ember-packages-description">${t("t_ember_packages_tab_description")}</span>
            </div>
            ${library.status === "unknown"
                ? null
                : html`<p class="ember-packages-library-status ember-packages-library-${library.status}">
                      ${t(`t_ember_packages_library_status_${library.status}`)}
                      ${library.progress != null ? ` (${library.progress.done}/${library.progress.total})` : ""}
                      ${library.message != null && library.failures.length === 0
                          ? html`<br /><span class="ember-packages-library-message">${library.message}</span>`
                          : null}
                  </p>`}
            ${library.status === "asking" && library.download != null
                ? html`<div class="ember-install-failure-cards"><${LargeDownloadCard} download=${library.download} /></div>`
                : null}
            ${cards.length === 0
                ? null
                : html`<div class="ember-install-failure-cards">
                      ${cards.map(
                          (card, i) => html`<${InstallFailureCard}
                              key=${card.package ?? "(several)"}
                              card=${card}
                              rows=${rows}
                              r_version=${r_version}
                              log=${library.log}
                              show_command=${i === command_card}
                          />`
                      )}
                  </div>`}
            ${direct_rows.length === 0
                ? null
                : html`<table class="ember-packages-table">
                      <thead>
                          <tr>
                              <th>${t("t_ember_packages_column_name")}</th>
                              <th>${t("t_ember_packages_column_version")}</th>
                              <th>${t("t_ember_packages_column_status")}</th>
                          </tr>
                      </thead>
                      <tbody>
                          ${direct_rows.map(
                              (row) => html`<tr class="ember-package-row ember-package-${row.status}" key=${row.name}>
                                      <td class="ember-mono">${row.name}</td>
                                      <td class="ember-mono">${row.version ?? "—"}${github_source_label(row.source)}</td>
                                      <td title=${row.message ?? ""}><${PackageStatus} row=${row} /></td>
                                  </tr>
                                  <${SourceDetail} key=${`${row.name} source`} row=${row} read_only=${read_only} />`
                          )}
                      </tbody>
                  </table>`}
            ${read_only ? null : html`<${DiskUse} />`}
        </div>
    `
}
