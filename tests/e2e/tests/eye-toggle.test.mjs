// #287: a one-click show/hide code toggle (Pluto's eye) that stays in the
// same place whether the code is shown or hidden, so a second click where
// the first one was undoes it. It sits with the ⋯ at the cell's top right;
// the menu's Hide/Show code item stays as a second way in.

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
      const eye = `${cellSelector(id)} button.ember-eye`;
      const more = `${cellSelector(id)} button.input_context_menu`;
      await page.locator(cellSelector(id)).scrollIntoViewIfNeeded();
      await page.hover(cellSelector(id));
      assert.deepEqual(await state(page, eye), { label: "Hide code", pressed: "false", title: "Hide code" });
      const eye0 = await rect(page, eye);
      const more0 = await rect(page, more);

      await page.mouse.click(eye0.x + eye0.w / 2, eye0.y + eye0.h / 2);
      await folded(page, id, true);
      assert.equal(await page.locator(`${cellSelector(id)} .cm-editor`).isVisible(), false, `${id}'s code is hidden`);
      assert.deepEqual(await state(page, eye), { label: "Hide code", pressed: "true", title: "Show code" });
      same(await rect(page, eye), eye0, `${id} at ${width} px: the eye stays put when the code hides`);
      same(await rect(page, more), more0, `${id} at ${width} px: the ⋯ stays put when the code hides`);

      await page.mouse.click(eye0.x + eye0.w / 2, eye0.y + eye0.h / 2);
      await folded(page, id, false);
      await page.locator(`${cellSelector(id)} .cm-editor`).waitFor({ state: "visible", timeout: 5000 });
      same(await rect(page, eye), eye0, `${id} at ${width} px: the eye is back where it started`);
    }
  }

  // The file records the fold, as with the menu's Hide code.
  await page.locator(`${cellSelector("A")} button.ember-eye`).click({ force: true });
  await folded(page, "A", true);
  const deadline = Date.now() + 10000;
  while (!savedFolded(notebook, "A") && Date.now() < deadline) await new Promise((r) => setTimeout(r, 100));
  assert.ok(savedFolded(notebook, "A"), "the cell order footer marks A folded");

  assertNoProblems(page);
});

test("eye: reachable by Tab from a selected cell, toggled with Enter, focus stays on it", async (t) => {
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
  await page.locator(`${cellSelector("A")} .cm-content`).click();
  await page.keyboard.press("Escape");
  const active = () => page.evaluate(() => {
    const el = document.activeElement;
    return { cell: el?.closest("pluto-cell")?.id, cls: el?.className.trim(), label: el?.getAttribute("aria-label") };
  });
  // From the selected cell, Tab goes to the run button, then the eye.
  await page.keyboard.press("Tab");
  assert.match((await active()).cls, /ember-run/);
  await page.keyboard.press("Tab");
  assert.deepEqual(await active(), { cell: "A", cls: "ember-eye", label: "Hide code" });
  // Shown while it has keyboard focus (after the 0.15 s fade in).
  await page.waitForFunction(() => getComputedStyle(document.querySelector('pluto-cell[id="A"] button.ember-eye')).opacity === "1",
    null, { timeout: 3000 });

  await page.keyboard.press("Enter");
  await folded(page, "A", true);
  const after = await active();
  assert.equal(after.cell, "A", "focus stays in A");
  assert.match(after.cls, /\bember-eye\b/, "focus stays on the eye");
  assert.match(after.cls, /\bcode-hidden\b/, "the eye shows the hidden state");
  await page.keyboard.press("Enter");
  await folded(page, "A", false);

  // With the code hidden there's no run button: Tab from the selected cell
  // reaches the eye first.
  await page.keyboard.press("Enter");
  await folded(page, "A", true);
  await page.evaluate(() => document.querySelector('pluto-cell[id="A"]').focus());
  await page.keyboard.press("Tab");
  assert.equal((await active()).cell, "A");
  assert.match((await active()).cls, /ember-eye/);

  assertNoProblems(page);
});
