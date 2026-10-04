// The Export menu's "Static HTML" card (components/ExportBanner.js): a
// reviewer found that it dispatched a "open pluto html export" event whose
// only listener (PlutoLandUpload) is never mounted in Ember, so the click
// did nothing. The fix makes the card's own link (href=notebookexport_url,
// download="") do the work natively. This test drives the real menu instead
// of fetching /notebookexport directly (that path is covered by
// export.test.mjs), so a regression in the click handler itself would be
// caught.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { readFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

test("export menu: Static HTML downloads a self-contained export", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "export-menu-html.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // A freshly opened local notebook starts in safe preview; trust it first
  // so the Static HTML card's own `warn_if_safe_preview()` confirm (kept by
  // the fix -- see ExportBanner.js) doesn't need a native dialog handled
  // here. newPage()'s dialog handler dismisses any dialog it doesn't
  // expect, which would otherwise look just like "the click did nothing".
  await page.locator(".safe-preview button").click();
  await page.getByText("run this notebook", { exact: false }).click();
  await page.waitForFunction(() => document.querySelectorAll(".safe-preview-info").length === 0, null, { timeout: 20000 });

  await page.locator('header#pluto-nav button[aria-label="Export"]').click();
  await page.waitForSelector("dialog#export[open]", { timeout: 5000 });

  const [download] = await Promise.all([
    page.waitForEvent("download", { timeout: 10000 }),
    page.locator('dialog#export a.export_card:has-text("Static HTML")').click(),
  ]);

  const dir = mkdtempSync(path.join(tmpdir(), "ember-export-menu-"));
  const file = path.join(dir, "export.html");
  await download.saveAs(file);
  const html = readFileSync(file, "utf8");
  assert.match(html, /id="ember-modules"/, "expected the downloaded file to be the self-contained export");

  assertNoProblems(page);
});

test("export menu: Notebook file opens the source in a new tab", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "export-menu-file.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.locator('header#pluto-nav button[aria-label="Export"]').click();
  await page.waitForSelector("dialog#export[open]", { timeout: 5000 });

  const [popup] = await Promise.all([
    page.context().waitForEvent("page", { timeout: 10000 }),
    page.locator('dialog#export a.export_card:has-text("Notebook file")').click(),
  ]);
  await popup.waitForLoadState();
  const text = await popup.locator("body").innerText();
  assert.match(text, /# %%/, "expected the notebook file's own cell-boundary marker");
  await popup.close();

  assertNoProblems(page);
});
