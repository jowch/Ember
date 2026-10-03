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

  await page.locator(".safe-preview button").click();
  await page.getByText("run this notebook", { exact: false }).click();

  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  await page.hover(cellSelector("S"));
  await page.locator(`${cellSelector("S")} button.input_context_menu`).click();
  assert.equal(await page.locator(`${cellSelector("S")} button.disable_cell`).count(), 0,
    "the setup cell's menu has no disable item");
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
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  assertNoProblems(page);
});
