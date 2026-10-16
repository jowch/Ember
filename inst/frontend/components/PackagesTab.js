import { html, useState, useContext, useEffect, useRef } from "../imports/Preact.js"
import { t, getCurrentLanguage } from "../common/lang.js"
import { install_cards, cause_groups, sentence_kind, join_names } from "../common/install_cards.js"
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
    other: "t_ember_install_failed_dep_other",
}

/**
 * One sentence per kind of failure among the packages a card's package
 * needs (#91): "A package it needs, rlang 1.1.6, doesn't build on R
 * 4.6.1." Each is named with its locked version from `rows`
 * (`packages.rows`) when it has one; a missing-system sentence lists
 * every library its packages lack.
 *
 * @param {{ kind: string, failures: Array<import("./Editor.js").EmberInstallFailure> }} group
 * @param {Array<import("./Editor.js").EmberPackageRow>} rows
 * @param {string?} r_version
 */
const dep_sentence = (group, rows, r_version) => {
    const names = group.failures.map((f) => {
        const version = f.version ?? rows.find((r) => r.name === f.package)?.version
        return version == null ? f.package : `${f.package} ${version}`
    })
    const libraries = [...new Set(group.failures.flatMap((f) => (f.libraries ?? "").split(",").map((l) => l.trim()).filter((l) => l !== "")))]
    return t(DEP_SENTENCE[group.kind], {
        count: names.length,
        packages: join_names(names, getCurrentLanguage()),
        libraries: libraries.join(", "),
        r_version: r_version ?? "",
    })
}

/**
 * What to do about a missing compiler or system library
 * (R/install-checks.R), over a card's own failure and its causes. System
 * libraries: every package's row carries the same command, which
 * installs them all, so only the first card (`show_command`) shows it,
 * with the sentence for people who can't run it; without a command (not
 * Package Manager), the package-manager sentence instead. A compiler:
 * `detail` is a sentence whose `backticked` parts are commands. A package
 * with no binary for this R (#19): update the date, or use an older R.
 * Nothing for other kinds, whose `detail` is a line of the log.
 *
 * @param {Array<import("./Editor.js").EmberInstallFailure>} failures
 * @param {boolean} show_command
 */
const failure_fixes = (failures, show_command) => {
    const has_libraries = failures.some((f) => sentence_kind(f) === "missing_system")
    const command = failures.find((f) => f.kind === "missing_system" && f.detail != null)?.detail
    const compiler = failures.find((f) => f.kind === "missing_compiler" && f.detail != null)?.detail
    return html`
        ${has_libraries && show_command
            ? html`
                  ${command != null
                      ? html`<p class="ember-install-failure-fix">${t("t_ember_install_failed_system_command")}</p>
                            <pre class="ember-install-failure-command">${command}</pre>`
                      : html`<p class="ember-install-failure-fix">${t("t_ember_install_failed_system_manager")}</p>`}
                  <p class="ember-install-failure-fix">${t("t_ember_install_failed_no_admin")}</p>
              `
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
 * `ember_run_all` are plain requests (server.R); neither is this
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
    const can_retry = failures.some((f) => ["download", "unavailable", "system", "missing_system", "missing_compiler"].includes(f.kind))

    return html`
        <div class="ember-install-failure-card">
            <p class="ember-install-failure-title">${t("t_ember_install_failed_title", { package: card.package })}</p>
            ${card.own != null || card.causes.length === 0
                ? html`<p class="ember-install-failure-sentence">${own_sentence(card.own ?? { kind: "other" }, r_version)}</p>`
                : null}
            ${cause_groups(card.causes).map(
                (group) => html`<p class="ember-install-failure-sentence">${dep_sentence(group, rows, r_version)}</p>`
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
                    ? html`<button type="button" class="ember-btn" onClick=${() => pluto_actions.ember_run_all()}>${t("t_ember_try_again")}</button>`
                    : null}
                <button type="button" class="ember-btn" onClick=${() => set_show_error(!show_error)}>${t("t_ember_show_the_error")}</button>
            </div>
            ${show_error ? html`<pre class="ember-install-failure-log">${log}</pre>` : null}
        </div>
    `
}

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
    if (row.status === "failed" || row.status === "not_found" || row.status === "source_failed") {
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
 * version: "GitHub lab/mypkg@3f2a1c9". Its version isn't the snapshot
 * date's, so the date above the table doesn't speak for it; this label is
 * design.md's "marked unchecked", and its tooltip says so.
 * @param {string?} source  the lock's source, "github:<user>/<repo>@<sha>"
 */
const github_source_label = (source) => {
    const m = /^github:([^@]+)@(.+)$/.exec(source ?? "")
    if (m == null) return null
    return html`<div class="ember-package-source" title=${t("t_ember_packages_from_github_unchecked", { source })}>${t("t_ember_packages_from_github", { repo: `${m[1]}@${m[2].slice(0, 7)}` })}</div>`
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
    if (!has_spec && row.status !== "not_found") return null
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

/**
 * The "Packages" tab (ui-2.md, 5; ui-3-plan.md, piece 4 and piece 5's
 * "Packages tab"): "Versions as of <date>" with Update, a description
 * line, the library's install status, a card per package the notebook
 * loads whose install failed (`install_cards()`), and
 * one row per *direct* package (dependencies hidden), each followed by its
 * GitHub source line when it has one (`SourceDetail`). Reads
 * `notebook.ember.packages` (project_ember(), pluto-state.R); `nbpkg`
 * stays filled beside it for Endeavor and isn't read here.
 *
 * @param {{ packages: import("./Editor.js").EmberPackagesData?, read_only?: boolean }} props
 */
export const PackagesTab = ({ packages, read_only = false }) => {
    if (packages == null) return null
    const { snapshot, r_version, library, rows, update } = packages
    const direct_rows = rows.filter((row) => row.direct)
    const cards = install_cards(library.failures)
    // The one card that shows the system-library command (`failure_fixes()`).
    const command_card = cards.findIndex((card) => [card.own, ...card.causes].some((f) => f != null && sentence_kind(f) === "missing_system"))

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
            ${cards.length === 0
                ? null
                : html`<div class="ember-install-failure-cards">
                      ${cards.map(
                          (card, i) => html`<${InstallFailureCard}
                              key=${card.package}
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
        </div>
    `
}
