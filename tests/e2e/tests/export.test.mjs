// Piece 2 (docs/ui-2.md, "Offline bundle"), scenario 20 of
// docs/ui-2-tests.md: a downloaded export is one self-contained HTML file
// that opens from disk, offline, with code highlighted as R and widgets
// working. rich.R has no htmlwidget output (DT isn't a dependency), so
// export-widget.R (an htmltools tag with a local htmlDependency) stands in
// for "the DT widget renders rows".

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

/** `html` with every `<script>...</script>`/`<style>...</style>` element's
 * text content blanked (tags kept): real `src=`/`href=`/`url()` attributes
 * can only appear in the surrounding markup, never inside the embedded
 * `#ember-modules` JSON or the loader script, where an original frontend
 * file's own source text (a comment, an error page's literal `<a
 * href="./">`) can otherwise read like a match without being one. Mirrors
 * tests/testthat/test-export.R's `strip_script_and_style_content()`. */
function stripScriptAndStyleContent(html) {
  html = html.replace(/(<script\b[^>]*>)[\s\S]*?(<\/script>)/g, "$1$2");
  return html.replace(/(<style\b[^>]*>)[\s\S]*?(<\/style>)/g, "$1$2");
}

async function fetchExport(server, id, { offlineBundle = false } = {}) {
  const url = `${server.origin}notebookexport?id=${id}&secret=${server.secret}${offlineBundle ? "&offline_bundle=true" : ""}`;
  const res = await fetch(url);
  assert.equal(res.status, 200);
  return await res.text();
}

function saveExport(html, name) {
  const dir = mkdtempSync(path.join(tmpdir(), "ember-export-"));
  const file = path.join(dir, name);
  writeFileSync(file, html, "utf8");
  return file;
}

/** Open `file`, aborting every network request except MathJax. */
async function openFileOffline(browser, file) {
  const page = await newPage(browser);
  page.route("**/*", (route) => {
    const url = route.request().url();
    if (url.startsWith("file://") || url.includes("mathjax")) return route.continue();
    return route.abort();
  });
  await page.goto(`file://${file}`);
  return page;
}

for (const offlineBundle of [false, true]) {
  test(`export: rich.R's export is self-contained (offline_bundle=${offlineBundle}) (20)`, async (t) => {
    const notebook = tempNotebook("rich.R");
    const server = await startServer([notebook], { logFile: path.join(artifactsDir(), `export-rich-${offlineBundle}.server.log`) });
    const browser = await launchBrowser();
    t.after(async () => { await browser.close(); server.stop(); });

    const livePage = await newPage(browser);
    const id = await openNotebook(livePage, server.origin, server.secret, notebook);
    await runCell(livePage, "DF");
    await runCell(livePage, "TBL");
    await livePage.waitForSelector(`${cellSelector("TBL")} table.pluto-table`, { timeout: 20000 });
    await livePage.close();

    const html = await fetchExport(server, id, { offlineBundle });
    const skeleton = stripScriptAndStyleContent(html);
    assert.doesNotMatch(skeleton, /src="\.\//);
    assert.doesNotMatch(skeleton, /href="\.\//);
    assert.doesNotMatch(skeleton, /url\(\.\//);
    const file = saveExport(html, "rich-export.html");

    const page = await openFileOffline(browser, file);
    await page.waitForSelector("pluto-cell", { timeout: 20000 });

    const cellIds = ["S", "DF", "TBL", "FIT", "LST", "PLT", "ANSI", "MD"];
    for (const cid of cellIds) {
      const count = await page.locator(cellSelector(cid)).count();
      assert.ok(count > 0, `expected cell ${cid} to be present in the export`);
    }

    await page.waitForSelector(`${cellSelector("TBL")} table.pluto-table`, { timeout: 20000 });

    assertNoProblems(page);
    await page.close();
  });
}

// Installing htmltools into the notebook's own library needs CRAN's index
// (network), same as widget.R's install scenario (ui-2-tests.md's new
// fixtures note); gated the same way.
test("export: an htmlwidget's dependency files are inlined and run (20)", {
  skip: !process.env.EMBER_E2E_INSTALLS && "set EMBER_E2E_INSTALLS=1 (needs network to resolve the lock)",
  timeout: 150000,
}, async (t) => {
  const notebook = tempNotebook("export-widget.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "export-widget.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const livePage = await newPage(browser);
  const id = await openNotebook(livePage, server.origin, server.secret, notebook);

  // htmltools needs installing into the notebook's own library: accept the
  // safe-preview prompt before running, as packages.R's scenario does.
  await livePage.locator(".safe-preview button").click();

  await runCell(livePage, "WIDGET");
  await livePage.waitForSelector(`${cellSelector("WIDGET")} #widget-marker`, { timeout: 120000 });
  await livePage.close();

  const html = await fetchExport(server, id);
  assert.doesNotMatch(stripScriptAndStyleContent(html), /src="\.\//);
  const file = saveExport(html, "widget-export.html");

  const page = await openFileOffline(browser, file);
  await page.waitForFunction(
    () => document.querySelector("#widget-marker")?.textContent === "widget-ran",
    null, { timeout: 20000 });

  assertNoProblems(page);
  await page.close();
});
