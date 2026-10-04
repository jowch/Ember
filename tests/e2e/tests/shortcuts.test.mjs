// The keyboard shortcuts sheet (components/ShortcutsSheet.js) and F1 as R
// help, tests 164 and 165 of docs/ui-3-tests.md.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector, runCell } from "../browser.mjs";

/** userAgentData, where the browser has it, wins over navigator.platform in
 * is_mac_keyboard, so both are set. */
async function pageOn(browser, platform) {
  const page = await newPage(browser);
  await page.addInitScript((p) => {
    Object.defineProperty(navigator, "platform", { get: () => p });
    Object.defineProperty(navigator, "userAgentData", { get: () => ({ platform: p }) });
  }, platform);
  return page;
}

async function openSheet(page) {
  await page.getByRole("button", { name: "More", exact: true }).click();
  await page.getByRole("menuitem", { name: "Keyboard shortcuts", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "Keyboard shortcuts", exact: true });
  await dialog.waitFor({ timeout: 5000 });
  return dialog;
}

/** The sheet as text: each group's heading and its rows' label and keys. */
function readSheet(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll("dialog.ember-shortcuts[open] section")].map((s) => ({
      group: s.querySelector("h3").textContent,
      rows: [...s.querySelectorAll(".ember-shortcuts-row")].map((r) => [
        r.firstElementChild.textContent,
        ...[...r.querySelectorAll("kbd")].map((k) => k.textContent),
      ]),
    })));
}

/** What the sheet's data table says it should show on this page. */
function expectedSheet(page) {
  return page.evaluate(async () => {
    const { SHORTCUT_GROUPS } = await import(new URL("components/ShortcutsSheet.js", location.href).href);
    const { t } = await import(new URL("common/lang.js", location.href).href);
    const { is_mac_keyboard } = await import(new URL("common/KeyboardShortcuts.js", location.href).href);
    return SHORTCUT_GROUPS.map(({ group, rows }) => ({
      group: t(group),
      rows: rows.map((r) => [t(r.label), ...(is_mac_keyboard ? r.mac : r.keys).map((k) => (typeof k === "string" ? k : t(k.t)))]),
    }));
  });
}

test("shortcuts: the sheet opens from ⋯ with this computer's keys, Esc closes it, F1 and Ctrl + ? don't open it (164)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "shortcuts-164.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await pageOn(browser, "Linux x86_64");
  await openNotebook(page, server.origin, server.secret, notebook);
  const dialog = await openSheet(page);
  const text = await dialog.innerText();
  assert.ok(text.includes("Run this cell"), text);
  assert.ok(text.includes("Ctrl"), text);

  const sheet = await readSheet(page);
  assert.deepEqual(sheet.map((g) => g.group), ["Running", "Cells", "Editing code", "Moving around"]);
  assert.deepEqual(sheet[0].rows, [
    ["Run this cell", "Shift", "Enter"],
    ["Run it and add a cell below", "Ctrl", "Enter"],
    ["Run every edited cell", "Ctrl", "S"],
    ["Stop running", "Ctrl", "Q"],
  ]);
  assert.deepEqual(sheet, await expectedSheet(page));
  assert.ok(!sheet.flatMap((g) => g.rows).some((r) => r.includes("⌘") || r.includes("⌥")), "no Mac keys off a Mac");

  await page.keyboard.press("Escape");
  await dialog.waitFor({ state: "detached", timeout: 5000 });
  await page.waitForFunction(() => document.activeElement?.getAttribute("aria-label") === "More", null, { timeout: 2000 });

  await page.locator("body").click({ position: { x: 5, y: 300 } });
  await page.keyboard.press("F1");
  await page.keyboard.press("Control+?");
  await page.keyboard.press("Control+Shift+Slash");
  await page.waitForTimeout(300);
  assert.equal(await page.locator("dialog[open]").count(), 0, "neither F1 nor Ctrl + ? opens a dialog");
  assertNoProblems(page);

  const mac = await pageOn(browser, "MacIntel");
  await openNotebook(mac, server.origin, server.secret, notebook);
  await openSheet(mac);
  const mac_sheet = await readSheet(mac);
  assert.deepEqual(mac_sheet[0].rows, [
    ["Run this cell", "Shift", "Enter"],
    ["Run it and add a cell below", "⌘", "Enter"],
    ["Run every edited cell", "⌘", "S"],
    ["Stop running", "Ctrl", "Q"],
  ]);
  assert.deepEqual(mac_sheet, await expectedSheet(mac));
  assertNoProblems(mac);
});

test("shortcuts: F1 in a cell opens Help on the name at the cursor (165)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "shortcuts-165.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  // Help pages come from the worker, so R must be running.
  await runCell(page, "A");
  await page.waitForFunction(() => {
    const nb = window.editor_state?.notebook;
    return nb?.process_status === "ready" && nb.cell_results?.A?.runtime != null &&
      Object.values(nb.cell_results).every((r) => !r.running && !r.queued);
  }, null, { timeout: 30000 });
  assert.equal(await page.locator("#helpbox-wrapper.open").count(), 0, "Help starts closed");

  const content = page.locator(`${cellSelector("B")} .cm-editor:not(.cm-ssr-fake) .cm-content`);
  await content.click();
  await page.keyboard.press("Home");
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("F1");

  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper.open")?.innerText.includes("Sum of Vector Elements"),
    null, { timeout: 15000 });
  assert.equal(await page.locator("dialog[open]").count(), 0, "F1 opens no dialog");
  assertNoProblems(page);
});
