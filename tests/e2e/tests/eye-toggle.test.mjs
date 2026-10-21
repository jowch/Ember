// #287: a one-click show/hide code toggle (Pluto's eye) that stays in the
// same place whether the code is shown or hidden, so a second click where
// the first one was undoes it. It sits where Pluto has it, in the left
// shoulder, beside the run button's corner, at every width; the menu's
// Hide/Show code item stays as a second way in.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector } from "../browser.mjs";

const rect = (page, sel) => page.locator(sel).evaluate((el) => {
  const r = el.getBoundingClientRect();
  return { x: r.x, y: r.y, w: r.width, h: r.height };
});
const same = (a, b, what) => assert.ok(Math.abs(a.x - b.x) < 0.6 && Math.abs(a.y - b.y) < 0.6, `${what}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
const state = (page, sel) => page.locator(sel).evaluate((b) => ({
  label: b.getAttribute("aria-label"), pressed: b.getAttribute("aria-pressed"), title: b.title,
}));
const folded = (page, id, want) => page.waitForFunction(([sel, want]) =>
  document.querySelector(sel)?.classList.contains("code_folded") === want, [cellSelector(id), want], { timeout: 10000 });
const savedFolded = (notebook, id) => new RegExp(`^# ${id} .*folded`, "m").test(fs.readFileSync(notebook, "utf8"));

test("eye: one click hides the code, a second click in the same place shows it", async (t) => {
  const notebook = tempNotebook("ui-sweep.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "eye-toggle.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForSelector(`${cellSelector("PLT")} pluto-output img`, { timeout: 60000 });

  for (const width of [600, 1200]) {
    await page.setViewportSize({ width, height: 800 });
    // A, with a short output, and PLT, with a plot.
    for (const id of ["A", "PLT"]) {
      const eye = `${cellSelector(id)} pluto-shoulder > button.foldcode`;
      await page.locator(cellSelector(id)).scrollIntoViewIfNeeded();
      await page.hover(cellSelector(id));
      assert.deepEqual(await state(page, eye), { label: "Hide code", pressed: "false", title: "Hide code" });
      const eye0 = await rect(page, eye);
      // Left of the cell, clear of the run button's corner and on the page.
      const cell0 = await rect(page, cellSelector(id));
      const run0 = await rect(page, `${cellSelector(id)} button.ember-run`);
      assert.ok(eye0.x >= 0 && eye0.x + eye0.w <= cell0.x, `${id} at ${width} px: the eye is in the left gutter: ${JSON.stringify(eye0)}`);
      assert.ok(eye0.x + eye0.w <= run0.x, `${id} at ${width} px: the eye is left of the run button`);

      await page.mouse.click(eye0.x + eye0.w / 2, eye0.y + eye0.h / 2);
      await folded(page, id, true);
      assert.equal(await page.locator(`${cellSelector(id)} .cm-editor`).isVisible(), false, `${id}'s code is hidden`);
      assert.deepEqual(await state(page, eye), { label: "Hide code", pressed: "true", title: "Show code" });
      same(await rect(page, eye), eye0, `${id} at ${width} px: the eye stays put when the code hides`);

      await page.mouse.click(eye0.x + eye0.w / 2, eye0.y + eye0.h / 2);
      await folded(page, id, false);
      await page.locator(`${cellSelector(id)} .cm-editor`).waitFor({ state: "visible", timeout: 5000 });
      same(await rect(page, eye), eye0, `${id} at ${width} px: the eye is back where it started`);
    }
  }

  // The file records the fold, as with the menu's Hide code.
  await page.locator(`${cellSelector("A")} pluto-shoulder > button.foldcode`).click({ force: true });
  await folded(page, "A", true);
  const deadline = Date.now() + 10000;
  while (!savedFolded(notebook, "A") && Date.now() < deadline) await new Promise((r) => setTimeout(r, 100));
  assert.ok(savedFolded(notebook, "A"), "the cell order footer marks A folded");

  assertNoProblems(page);
});

test("eye: reached by Tab on the way into a cell, toggled with Enter, focus stays on it", async (t) => {
  const notebook = tempNotebook("ui-sweep.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "eye-toggle-keys.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  // Run it first: in safe preview a hidden cell's code still shows.
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(() => document.querySelectorAll("pluto-cell.running, pluto-cell.queued").length === 0
    && document.getElementById("A")?.classList.contains("no_output_yet") === false, null, { timeout: 60000 });
  const active = () => page.evaluate(() => {
    const el = document.activeElement;
    return { cell: el?.closest("pluto-cell")?.id, cls: el?.className.trim(), label: el?.getAttribute("aria-label") };
  });
  // Tab from the cell above (MD's ⋯) walks into A: its eye leads it.
  const tabToEye = async () => {
    await page.locator(`${cellSelector("MD")} button.input_context_menu`).focus();
    for (let i = 0; i < 4; i++) {
      await page.keyboard.press("Tab");
      const a = await active();
      if (a.cell === "A") return a;
    }
    return active();
  };
  assert.deepEqual(await tabToEye(), { cell: "A", cls: "foldcode", label: "Hide code" }, "the eye is the first stop in A");
  // Shown while it has keyboard focus (after the 0.15 s fade in).
  await page.waitForFunction(() => getComputedStyle(document.querySelector('pluto-cell[id="A"] pluto-shoulder > button.foldcode')).opacity === "1",
    null, { timeout: 3000 });

  await page.keyboard.press("Enter");
  await folded(page, "A", true);
  assert.deepEqual(await active(), { cell: "A", cls: "foldcode", label: "Hide code" }, "focus stays on the eye");
  assert.equal(await page.locator(`${cellSelector("A")} pluto-shoulder > button.foldcode`).getAttribute("aria-pressed"), "true");
  await page.keyboard.press("Enter");
  await folded(page, "A", false);
  assert.equal(await page.locator(`${cellSelector("A")} pluto-shoulder > button.foldcode`).getAttribute("aria-pressed"), "false");

  // With the code hidden, Tab still reaches the eye on the way in.
  await page.keyboard.press("Enter");
  await folded(page, "A", true);
  assert.deepEqual(await tabToEye(), { cell: "A", cls: "foldcode", label: "Hide code" });

  assertNoProblems(page);
});
