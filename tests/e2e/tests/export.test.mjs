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

    // Code highlighted as R, not Julia (ui-2-tests.md 20's own wording):
    // a code cell's editor tokenizes with CodeMirror's R grammar (any
    // highlighted span at all is evidence the bundled grammar loaded and
    // ran offline, which increment 1's CDN-pointed bundle couldn't do from
    // file://), and MD's fenced block is tagged "language-r" by the R
    // grammar's markdown embedding (CellOutput.js switched this from
    // "language-julia"), not left generic or wrong.
    // A cell first shows a static fake editor (.cm-ssr-fake, no highlighting);
    // the real one replaces it when the cell scrolls into view, which can be
    // after TBL's table shows. So wait for the real editor's spans rather than
    // count them once (#340).
    await page.locator(cellSelector("DF")).scrollIntoViewIfNeeded();
    await page.locator(`${cellSelector("DF")} .cm-editor:not(.cm-ssr-fake) .cm-content span[class]`).first().waitFor({ timeout: 20000 })
      .catch(() => assert.fail("expected the DF cell's code to have highlighted spans"));
    const mdCodeClass = await page.locator(`${cellSelector("MD")} pre code`).first().getAttribute("class");
    assert.match(mdCodeClass, /\blanguage-r\b/);

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
  await livePage.locator("#ember-safe-preview button").click();

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

// #122: a notebook exported while still in safe preview keeps
// `process_waiting_for_permission` in its state, but the exported page is
// static and can't run anything, so it shows no safe-preview banner.
test("export: a notebook exported in safe preview shows no safe-preview banner", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "export-safe-preview.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const livePage = await newPage(browser);
  const id = await openNotebook(livePage, server.origin, server.secret, notebook);
  await livePage.waitForSelector("#ember-safe-preview button", { timeout: 20000 });
  await livePage.close();

  const html = await fetchExport(server, id);
  const file = saveExport(html, "safe-preview-export.html");

  const page = await openFileOffline(browser, file);
  await page.waitForSelector("pluto-cell", { timeout: 20000 });
  // The flag the banner used to key on is still in the exported state.
  assert.equal(await page.evaluate(() => window.editor_state.notebook.process_status), "waiting_for_permission");
  assert.equal(await page.locator("#ember-safe-preview").count(), 0, "a static export shows no safe-preview banner");

  assertNoProblems(page);
  await page.close();
});
