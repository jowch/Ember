// The header's Export menu (components/ExportMenu.js), tests 161 and 162
// of docs/ui-3-tests.md.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { readFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

async function download(page, name) {
  const [file] = await Promise.all([
    page.waitForEvent("download", { timeout: 10000 }),
    page.getByRole("menuitem", { name, exact: true }).click(),
  ]);
  const dir = mkdtempSync(path.join(tmpdir(), "ember-e2e-export-"));
  const dest = path.join(dir, file.suggestedFilename());
  await file.saveAs(dest);
  return { name: file.suggestedFilename(), text: readFileSync(dest, "utf8") };
}

test("export menu: three items, downloads, Esc returns focus (161)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "export-menu-161.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(() => document.querySelectorAll("#ember-safe-preview").length === 0, null, { timeout: 20000 });

  const button = page.locator("header#pluto-nav button.toggle_export");
  await button.click();
  const menu = page.locator('[role="menu"]');
  await menu.waitFor({ timeout: 5000 });
  assert.deepEqual(
    await menu.locator('[role="menuitem"]').evaluateAll((els) => els.map((el) => el.querySelector(".ember-menuitem-title").textContent)),
    ["Download .R file", "Download HTML", "Print or save as PDF"]);
  assert.equal(await menu.locator(".ember-menu-note").count(), 0, "no safe-preview note once the notebook runs");

  const r = await download(page, "Download .R file");
  assert.equal(r.name, "basic.R");
  assert.equal(r.text.split("\n")[0], "### An Ember notebook ###");
  await menu.waitFor({ state: "detached", timeout: 5000 });

  await button.click();
  const exported = await download(page, "Download HTML");
  assert.match(exported.text, /id="ember-modules"/, "expected the self-contained export");

  await button.click();
  await menu.waitFor({ timeout: 5000 });
  await page.keyboard.press("Escape");
  await menu.waitFor({ state: "detached", timeout: 5000 });
  assert.ok(await button.evaluate((el) => el === document.activeElement), "focus is back on the Export button");

  assertNoProblems(page);
});

test("export menu: safe preview shows the note and downloads without asking (162)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "export-menu-162.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview").waitFor({ timeout: 10000 });

  await page.locator("header#pluto-nav button.toggle_export").click();
  const menu = page.locator('[role="menu"]');
  await menu.waitFor({ timeout: 5000 });
  assert.equal(
    (await menu.locator(".ember-menu-note").innerText()).trim(),
    "This notebook hasn't run, so HTML and PDF have code but no outputs.");
  assert.deepEqual(
    await menu.locator(".ember-menuitem-desc").allInnerTexts(),
    ["The notebook itself. Runs with Rscript.", "Code only, for now.", "Code only, for now."]);

  const exported = await download(page, "Download HTML");
  assert.match(exported.text, /id="ember-modules"/);

  assertNoProblems(page);
});
