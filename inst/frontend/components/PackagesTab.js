import { html, useState, useContext } from "../imports/Preact.js"
import { t } from "../common/lang.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"

/**
 * The sentence under a failure card's title, built from `kind`/`package`/
 * `detail`/`version` and `packages$r_version` -- R sends no prose
 * (ui-3-plan.md, "4. Notebooks and packages from the browser"). `rows` is
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
 * One failed package's card ("ui-3-plan.md": title, a sentence depending
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
                          title=${t("t_ember_install_failed_update_hint")}
                          onClick=${() => pluto_actions.ember_update_packages()}
                      >
                          ${t("t_ember_update_packages")}
                      </button>`
                    : null}
                ${can_retry ? html`<button onClick=${() => pluto_actions.ember_run_all()}>${t("t_ember_try_again")}</button>` : null}
                <button onClick=${() => set_show_error(!show_error)}>${t("t_ember_show_the_error")}</button>
            </div>
            ${show_error ? html`<pre class="ember-install-failure-log">${log}</pre>` : null}
        </div>
    `
}

/**
 * The "Packages" tab (ui-2.md, 5; ui-3-plan.md, piece 4): the snapshot
 * date and R version, the library's install status, a card per install
 * failure, and one row per locked or not-found package. Reads
 * `notebook.ember.packages` (project_ember(), pluto-state.R); `nbpkg`
 * stays filled beside it for Endeavor and isn't read here.
 *
 * @param {{ packages: import("./Editor.js").EmberPackagesData? }} props
 */
export const PackagesTab = ({ packages }) => {
    if (packages == null) return null
    const { snapshot, r_version, library, rows } = packages

    return html`
        <div id="ember-packages-tab">
            <dl class="ember-packages-meta">
                ${snapshot != null
                    ? html`<dt>${t("t_ember_packages_snapshot")}</dt>
                          <dd>${snapshot}</dd>`
                    : null}
                ${r_version != null
                    ? html`<dt>${t("t_ember_packages_r_version")}</dt>
                          <dd>${r_version}</dd>`
                    : null}
            </dl>
            <p class="ember-packages-library-status ember-packages-library-${library.status}">
                ${t(`t_ember_packages_library_status_${library.status}`)}
                ${library.progress != null ? ` (${library.progress.done}/${library.progress.total})` : ""}
                ${library.message != null ? html`<br /><span class="ember-packages-library-message">${library.message}</span>` : null}
            </p>
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
            ${rows.length === 0
                ? null
                : html`<table class="ember-packages-table">
                      <thead>
                          <tr>
                              <th>${t("t_ember_packages_column_name")}</th>
                              <th>${t("t_ember_packages_column_version")}</th>
                              <th>${t("t_ember_packages_column_source")}</th>
                              <th>${t("t_ember_packages_column_status")}</th>
                          </tr>
                      </thead>
                      <tbody>
                          ${rows.map(
                              (row) => html`<tr class="ember-package-row ember-package-${row.status}" key=${row.name}>
                                  <td>${row.name}</td>
                                  <td>${row.version ?? "—"}</td>
                                  <td>${row.source ?? "—"}</td>
                                  <td title=${row.message ?? ""}>${t(`t_ember_packages_status_${row.status}`)}</td>
                              </tr>`
                          )}
                      </tbody>
                  </table>`}
        </div>
    `
}
