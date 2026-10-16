import { html, useState, useContext, useEffect, useRef } from "../imports/Preact.js"
import { t } from "../common/lang.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"

/**
 * The sentence under a failure card's title, built from `kind`/`package`/
 * `detail`/`version` and `packages$r_version` -- R sends no prose.
 * `rows` is
 * `packages.rows`, used to look up a named dependency's own locked
 * version for the "dependency" sentence.
 *
 * @param {import("./Editor.js").EmberInstallFailure} failure
 * @param {Array<import("./Editor.js").EmberPackageRow>} rows
 * @param {string?} r_version
 */
const failure_sentence = (failure, rows, r_version) => {
    switch (failure.kind) {
        case "dependency": {
            const dep_version = rows.find((r) => r.name === failure.detail)?.version
            return t("t_ember_install_failed_compile_dependency", {
                dep: failure.detail,
                version: dep_version ?? "",
                r_version: r_version ?? "",
            })
        }
        case "compile":
            return t("t_ember_install_failed_compile", { r_version: r_version ?? "" })
        case "configure":
            return t("t_ember_install_failed_configure", { r_version: r_version ?? "" })
        case "download":
            return t("t_ember_install_failed_download")
        case "unavailable":
            return t("t_ember_install_failed_unavailable")
        case "system":
            return failure.libraries == null
                ? t("t_ember_install_failed_system")
                : t("t_ember_install_failed_missing_system", { libraries: failure.libraries })
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

/**
 * What to do about a missing compiler or system library
 * (R/install-checks.R). System libraries: every package's row carries the
 * same command, which installs them all, so only the first card
 * (`show_command`) shows it, with the sentence for people who can't run
 * it; without a command (not Package Manager), the package-manager
 * sentence instead. A compiler: `detail` is a sentence whose
 * `backticked` parts are commands. A package with no binary for this R
 * (#19): update the date, or use an older R. Nothing for other kinds,
 * whose `detail` is a line of the log.
 *
 * @param {import("./Editor.js").EmberInstallFailure} failure
 * @param {boolean} show_command
 */
const failure_fix = (failure, show_command) => {
    if (failure.kind === "missing_system" || (failure.kind === "system" && failure.libraries != null)) {
        if (!show_command) return null
        return html`
            ${failure.kind === "missing_system" && failure.detail != null
                ? html`<p class="ember-install-failure-fix">${t("t_ember_install_failed_system_command")}</p>
                      <pre class="ember-install-failure-command">${failure.detail}</pre>`
                : html`<p class="ember-install-failure-fix">${t("t_ember_install_failed_system_manager")}</p>`}
            <p class="ember-install-failure-fix">${t("t_ember_install_failed_no_admin")}</p>
        `
    }
    if (failure.kind === "no_binary") {
        return html`<p class="ember-install-failure-fix">${t("t_ember_install_failed_no_binary_fix")}</p>`
    }
    if (failure.detail == null) return null
    if (failure.kind === "missing_compiler") {
        const parts = failure.detail.split("`")
        return html`<p class="ember-install-failure-fix">${parts.map((part, i) => (i % 2 === 1 ? html`<code>${part}</code>` : part))}</p>`
    }
    return null
}

/**
 * One failed package's card: title, a sentence depending
 * on `kind` (and for a missing compiler or system library, what to
 * install), then Update (build failures), Try again (downloads, packages
 * the repositories didn't list, and anything the user installs on the
 * computer) and
 * Show the error (always). `ember_update_packages` and `ember_run_all`
 * are plain requests (server.R); neither is this component's to answer.
 *
 * @param {{
 *  failure: import("./Editor.js").EmberInstallFailure,
 *  rows: Array<import("./Editor.js").EmberPackageRow>,
 *  r_version: string?,
 *  log: string?,
 *  show_command: boolean,
 * }} props
 */
const InstallFailureCard = ({ failure, rows, r_version, log, show_command }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const [show_error, set_show_error] = useState(false)
    const can_update = ["compile", "configure", "no_binary"].includes(failure.kind)
    // "unavailable" is most often a repository index that couldn't be
    // read, which can be passing, so it gets Try again too.
    // The missing-piece kinds are fixed outside Ember, then retried.
    const can_retry = ["download", "unavailable", "system", "missing_system", "missing_compiler"].includes(failure.kind)

    return html`
        <div class="ember-install-failure-card">
            <p class="ember-install-failure-title">${t("t_ember_install_failed_title", { package: failure.package })}</p>
            <p class="ember-install-failure-sentence">${failure_sentence(failure, rows, r_version)}</p>
            ${failure_fix(failure, show_command)}
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
    if (row.status === "failed" || row.status === "not_found") return html`<span class="ember-pill ember-pill-red">${text}</span>`
    if (row.status === "installing") {
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

/**
 * The "Packages" tab (ui-2.md, 5; ui-3-plan.md, piece 4 and piece 5's
 * "Packages tab"): "Versions as of <date>" with Update, a description
 * line, the library's install status, a card per install failure, and
 * one row per *direct* package (dependencies hidden). Reads
 * `notebook.ember.packages` (project_ember(), pluto-state.R); `nbpkg`
 * stays filled beside it for Endeavor and isn't read here.
 *
 * @param {{ packages: import("./Editor.js").EmberPackagesData? }} props
 */
export const PackagesTab = ({ packages }) => {
    if (packages == null) return null
    const { snapshot, r_version, library, rows, update } = packages
    const direct_rows = rows.filter((row) => row.direct)

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
            ${library.failures.length === 0
                ? null
                : html`<div class="ember-install-failure-cards">
                      ${library.failures.map(
                          (failure, i) => html`<${InstallFailureCard}
                              key=${failure.package}
                              failure=${failure}
                              rows=${rows}
                              r_version=${r_version}
                              log=${library.log}
                              show_command=${i === library.failures.findIndex((f) => f.libraries != null)}
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
                              </tr>`
                          )}
                      </tbody>
                  </table>`}
        </div>
    `
}
