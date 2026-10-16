// ui-3-tests.md test 37 (piece 1b, "Disable cell"): the cell menu disables
// and re-enables a cell; a disabled cell and its dependent dim and keep
// their last output; the file is written with "## " and "disabled"; the
// classes and file survive a reload.

import { test } from "node:test";
import path from "node:path";
import fs from "node:fs";
import assert from "node:assert/strict";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector } from "../browser.mjs";

test("disable cell: toggling off then on, with the file and classes surviving a reload (37)", async (t) => {
  const notebook = tempNotebook("disabled.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "disabled.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.locator("#ember-safe-preview button").click();

  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  await page.hover(cellSelector("S"));
  await page.locator(`${cellSelector("S")} button.input_context_menu`).click();
  assert.equal(await page.locator(`${cellSelector("S")} button.disable_cell`).count(), 1,
    "the first cell's menu has a disable item: no cell is special");
  await page.keyboard.press("Escape");

  await page.hover(cellSelector("A"));
  await page.locator(`${cellSelector("A")} button.input_context_menu`).click();
  const disableItem = page.locator(`${cellSelector("A")} button.disable_cell`);
  assert.equal(await disableItem.innerText(), "Disable cell");
  await disableItem.click();

  await page.waitForSelector(`${cellSelector("A")}.running_disabled`, { timeout: 20000 });
  await page.waitForSelector(`${cellSelector("B")}.depends_on_disabled_cells`, { timeout: 20000 });
  assert.equal(await page.locator(`${cellSelector("C")}.running_disabled`).count(), 0);
  assert.equal(await page.locator(`${cellSelector("C")}.depends_on_disabled_cells`).count(), 0);

  const deadline = Date.now() + 15000;
  let onDisk = "";
  while (Date.now() < deadline) {
    onDisk = fs.readFileSync(notebook, "utf8");
    if (onDisk.includes("## x <- 1")) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  assert.match(onDisk, /## x <- 1/);
  assert.match(onDisk, /# A disabled/);

  await page.reload();
  await page.waitForSelector("pluto-cell", { timeout: 30000 });
  await page.waitForFunction(
    () => !document.querySelector("pluto-editor")?.classList.contains("loading"),
    null, { timeout: 30000 });

  await page.waitForSelector(`${cellSelector("A")}.running_disabled`, { timeout: 20000 });
  assert.equal(await page.locator(`${cellSelector("B")}.depends_on_disabled_cells`).count(), 1);

  const beforeEnable = await page.evaluate(() => {
    const cr = window.editor_state.notebook.cell_results;
    return { aTs: cr["A"]?.output?.last_run_timestamp ?? 0, bTs: cr["B"]?.output?.last_run_timestamp ?? 0 };
  });

  await page.hover(cellSelector("A"));
  await page.locator(`${cellSelector("A")} button.input_context_menu`).click();
  const enableItem = page.locator(`${cellSelector("A")} button.disable_cell`);
  assert.equal(await enableItem.innerText(), "Enable cell");
  await enableItem.click();

  await page.waitForFunction(
    (sel) => !document.querySelector(sel)?.classList.contains("running_disabled"),
    cellSelector("A"), { timeout: 20000 });
  await page.waitForFunction(
    (sel) => !document.querySelector(sel)?.classList.contains("depends_on_disabled_cells"),
    cellSelector("B"), { timeout: 20000 });

  // B's dimmed/stale state genuinely clears (not just the CSS class driven
  // by depends_on_disabled_cells), and A really reran -- its own run
  // timestamp moved on, not merely its disabled flag flipping -- which in
  // turn is what reruns B in autorun.
  await page.waitForFunction(
    (before) => {
      const cr = window.editor_state.notebook.cell_results;
      const aTs = cr["A"]?.output?.last_run_timestamp ?? 0;
      const bTs = cr["B"]?.output?.last_run_timestamp ?? 0;
      return cr["B"]?.ember?.stale === false && aTs > before.aTs && bTs > before.bTs;
    },
    beforeEnable, { timeout: 20000 });

  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  assertNoProblems(page);
});

test("undo delete of a disabled cell brings it back disabled, under its short id (#26, #27)", async (t) => {
  const notebook = tempNotebook("disabled.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "disabled-undo.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  // The page marks a cell queued itself when it asks to run it (after a
  // disable, and after an undo); the server's answer clears it. Count the
  // acknowledged run requests for A, then wait for A to be idle.
  await page.evaluate(() => {
    window.__a_acks = 0;
    window.addEventListener("ember_run_acknowledged", (e) => { if (e.detail.cell_ids.includes("A")) window.__a_acks++; });
  });
  const idleAfterAck = (n) => page.waitForFunction((n) => {
    const r = window.editor_state.notebook.cell_results["A"];
    return window.__a_acks >= n && r && !r.running && !r.queued;
  }, n, { timeout: 20000 });

  await page.hover(cellSelector("A"));
  await page.locator(`${cellSelector("A")} button.input_context_menu`).click();
  await page.locator(`${cellSelector("A")} button.disable_cell`).click();
  await page.waitForSelector(`${cellSelector("A")}.running_disabled`, { timeout: 20000 });
  await page.keyboard.press("Escape");   // close the cell menu
  await idleAfterAck(1);   // else the delete asks to stop A first

  await page.evaluate(() => document.getElementById("A").focus());
  await page.evaluate(() => window.editor_state_set({ selected_cells: ["A"] }));
  await page.keyboard.press("Backspace");
  await page.waitForFunction(() => !window.editor_state.notebook.cell_order.includes("A"), null, { timeout: 10000 });
  await page.waitForSelector("nav#undo_delete:not(.hidden)", { timeout: 5000 });
  const fileSays = async (re, want) => {
    const deadline = Date.now() + 15000;
    let text = "";
    while (Date.now() < deadline) {
      text = fs.readFileSync(notebook, "utf8");
      if (re.test(text) === want) return text;
      await new Promise((r) => setTimeout(r, 100));
    }
    return text;
  };
  assert.doesNotMatch(await fileSays(/# %% id=A\n/, false), /# %% id=A\n/, "the delete was saved");
  await page.locator("#undo_delete a").click();

  // Back under its own id, disabled, and its dependent off again; the
  // page's run request after the undo doesn't run it.
  await page.waitForSelector(`${cellSelector("A")}.running_disabled`, { timeout: 20000 });
  await page.waitForSelector(`${cellSelector("B")}.depends_on_disabled_cells`, { timeout: 20000 });
  assert.deepEqual(await page.evaluate(() => window.editor_state.notebook.cell_order), ["S", "A", "B", "C"]);
  const onDisk = await fileSays(/# %% id=A\n/, true);
  assert.match(onDisk, /# %% id=A\n## x <- 1/);
  assert.match(onDisk, /# A disabled/);
  await idleAfterAck(2);
  const a = await page.evaluate(() => window.editor_state.notebook.cell_results["A"]);
  assert.ok(!a?.output?.last_run_timestamp, "A never ran after the undo");
  // No "cell id must be a UUID" refusal logged by the page (#27).
  assertNoProblems(page);
});
