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
        default:
            return t("t_ember_install_failed_other")
    }
}

/**
 * One failed package's card: title, a sentence depending
 * on `kind`, then Update (build failures), Try again (downloads) and
 * Show the error (always). `ember_update_packages` and `ember_run_all`
 * are plain requests (server.R); neither is this component's to answer.
 *
 * @param {{
 *  failure: import("./Editor.js").EmberInstallFailure,
 *  rows: Array<import("./Editor.js").EmberPackageRow>,
 *  r_version: string?,
 *  log: string?,
 * }} props
 */
const InstallFailureCard = ({ failure, rows, r_version, log }) => {
    const pluto_actions = useContext(PlutoActionsContext)
    const [show_error, set_show_error] = useState(false)
    const can_update = failure.kind === "compile" || failure.kind === "configure"
    const can_retry = failure.kind === "download"

    return html`
        <div class="ember-install-failure-card">
            <p class="ember-install-failure-title">${t("t_ember_install_failed_title", { package: failure.package })}</p>
            <p class="ember-install-failure-sentence">${failure_sentence(failure, rows, r_version)}</p>
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
                      ${library.message != null ? html`<br /><span class="ember-packages-library-message">${library.message}</span>` : null}
                  </p>`}
            ${library.failures.length === 0
                ? null
                : html`<div class="ember-install-failure-cards">
                      ${library.failures.map(
                          (failure) => html`<${InstallFailureCard}
                              key=${failure.package}
                              failure=${failure}
                              rows=${rows}
                              r_version=${r_version}
                              log=${library.log}
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
                                  <td class="ember-mono">${row.version ?? "—"}</td>
                                  <td title=${row.message ?? ""}><${PackageStatus} row=${row} /></td>
                              </tr>`
                          )}
                      </tbody>
                  </table>`}
        </div>
    `
}
