// The Settings dialog (components/Settings.js), test 163 of
// docs/ui-3-tests.md: opened from ⋯, Tab stays inside, and every change
// applies at once, with no reload.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, setCellCode, cellSelector } from "../browser.mjs";

async function openSettings(page) {
  await page.getByRole("button", { name: "More", exact: true }).click();
  await page.getByRole("menuitem", { name: "Settings", exact: true }).click();
  const dialog = page.locator("dialog.psettings[open]");
  await dialog.waitFor({ timeout: 5000 });
  return dialog;
}

async function pick(dialog, group, option) {
  await dialog.getByRole("radiogroup", { name: group, exact: true }).getByRole("radio", { name: option, exact: true }).click();
}

async function closeSettings(page, dialog) {
  await dialog.getByRole("button", { name: "Done", exact: true }).click();
  await page.locator("dialog.psettings").waitFor({ state: "detached", timeout: 5000 });
}

/** Type `f <- function() {` and Enter in cell A; returns the new line's text. */
async function indentAfterBrace(page) {
  await setCellCode(page, "A", "f <- function() {");
  await page.keyboard.press("Enter");
  return page.locator(`${cellSelector("A")} .cm-line`).nth(1).evaluate((el) => el.textContent);
}

test("settings: opens from ⋯, traps Tab, applies theme, indent and Tab key live (163)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "settings-163.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.emulateMedia({ colorScheme: "light" });
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.evaluate(() => { window.__same_page = true; });

  await page.evaluate(() => {
    window.__dialog_focus = [];
    document.addEventListener("focusin", (e) => {
      if (e.target.closest("dialog.psettings") != null) window.__dialog_focus.push(e.target.textContent.trim() || e.target.className);
    });
  });
  let dialog = await openSettings(page);
  await page.waitForFunction(() => document.activeElement?.closest("dialog.psettings") != null, null, { timeout: 2000 });
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  assert.deepEqual(await page.evaluate(() => window.__dialog_focus), ["Done"], "the dialog puts focus on Done in one step");

  // Chromium rests on <body> for one Tab while wrapping from the last
  // control back to the first; any other element outside fails.
  const seen = [];
  for (let i = 0; i < 14; i++) {
    await page.keyboard.press("Tab");
    seen.push(await page.evaluate(() => {
      const el = document.activeElement;
      if (el === document.body) return "body";
      if (el?.closest("dialog.psettings") == null) return "outside";
      return el.getAttribute("aria-checked") != null && el.getAttribute("role") === "radio" ? `radio:${el.textContent.trim()}` : el.textContent.trim() || el.className;
    }));
  }
  assert.ok(!seen.includes("outside"), `Tab left the dialog: ${seen.join(", ")}`);
  assert.ok(seen.indexOf("radio:Match system", seen.indexOf("Done")) > 0, `Tab came round from Done to the first control: ${seen.join(", ")}`);
  for (let i = 0; i < 14 && !(await page.evaluate(() => document.activeElement?.getAttribute("role") === "radio")); i++) await page.keyboard.press("Tab");
  const ring = await page.evaluate(() => {
    const el = document.activeElement;
    const s = getComputedStyle(el);
    return { radio: el.getAttribute("role"), visible: el.matches(":focus-visible"), style: s.outlineStyle, offset: s.outlineOffset };
  });
  assert.deepEqual(ring, { radio: "radio", visible: true, style: "solid", offset: "2px" }, "a segment's focus ring sits 2 px out");

  const before = await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--main-bg-color").trim());
  await pick(dialog, "Theme", "Dark");
  await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "dark", null, { timeout: 2000 });
  const after = await page.evaluate(() => ({
    bg: getComputedStyle(document.documentElement).getPropertyValue("--main-bg-color").trim(),
    navigations: performance.getEntriesByType("navigation").length,
    same_page: window.__same_page === true,
  }));
  assert.notEqual(after.bg, before, "--main-bg-color changed");
  assert.deepEqual({ navigations: after.navigations, same_page: after.same_page }, { navigations: 1, same_page: true });

  await pick(dialog, "Indent with", "4 spaces");
  await closeSettings(page, dialog);
  assert.match(await indentAfterBrace(page), /^ {4}(?! )/);

  dialog = await openSettings(page);
  await dialog.getByRole("button", { name: "Reset to defaults", exact: true }).click();
  await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "light", null, { timeout: 2000 });
  assert.equal(await page.locator("dialog.psettings[open]").count(), 1, "Reset to defaults leaves Settings open");
  await closeSettings(page, dialog);
  assert.match(await indentAfterBrace(page), /^ {2}(?! )/);

  dialog = await openSettings(page);
  await pick(dialog, "Tab key in code", "Moves focus");
  await pick(dialog, "Theme", "Dark");
  await closeSettings(page, dialog);
  await page.locator(`${cellSelector("A")} .cm-content`).click();
  await page.keyboard.press("Tab");
  assert.equal(await page.evaluate(() => document.activeElement?.closest(".cm-content") == null), true, "Tab moved focus out of the code");

  // Back to the saved code, so leaving the page doesn't ask about edits.
  await setCellCode(page, "A", "x <- 1:10");
  await page.keyboard.press("Escape");
  await page.reload();
  await page.waitForSelector("pluto-cell", { timeout: 30000 });
  assert.equal(await page.evaluate(() => document.documentElement.getAttribute("data-theme")), "dark");

  assertNoProblems(page);
});
