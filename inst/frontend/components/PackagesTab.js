import { html } from "../imports/Preact.js"
import { t } from "../common/lang.js"

/**
 * The "Packages" tab (ui-2.md, 5): the snapshot date and R version, the
 * library's install status, and one row per locked or not-found package.
 * Reads `notebook.ember.packages` (project_ember(), pluto-state.R); `nbpkg`
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
